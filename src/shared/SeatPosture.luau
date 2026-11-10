--!strict
--------------------------------------------------------------------------------
-- SeatPosture.luau
-- Seated postures built for each body, instead of offsets layered over the
-- stock sit animation (made for blocky avatars, it leaves these realistic
-- bodies' hands hanging in the air beside their thighs).
--
-- A style names where the hands go (on the thighs, folded across the chest,
-- on a desk, at the chin...). The hand targets are measured off the posed body
-- itself (its thighs, chest, head) or the desk in front of it, and each arm is
-- solved to reach them through its own joint frames, so a long-armed body and
-- a short one both land their hands in the same place. The legs are fitted
-- too: thighs level on the seat, shins angled until the feet reach the floor.
--
-- Everything is a plain RigPose.Pose, written with rig:apply(). No animation
-- may play on a rig posed this way: an animation's joint transforms would
-- stack on top.
--------------------------------------------------------------------------------

local RigPose = require(script.Parent.RigPose)

local V = Vector3.new
local ZERO = Vector3.zero
local jointAngles = RigPose.jointAngles

local SeatPosture = {}

export type Context = {
	floor: number?, -- floor height in root space (root Y = 0); nil keeps knees at 90
	desk: number?, -- desk top height in root space, for the desk styles
	deskAt: Vector3?, -- middle of the keys, on their surface, root space
	mouseAt: Vector3?, -- the mouse or trackpad, on its surface, root space
}

-- joint key, parent part, child part, in parent-first order
local TREE = {
	{ "root", "HumanoidRootPart", "LowerTorso" },
	{ "waist", "LowerTorso", "UpperTorso" },
	{ "neck", "UpperTorso", "Head" },
	{ "rS", "UpperTorso", "RightUpperArm" },
	{ "rE", "RightUpperArm", "RightLowerArm" },
	{ "rW", "RightLowerArm", "RightHand" },
	{ "lS", "UpperTorso", "LeftUpperArm" },
	{ "lE", "LeftUpperArm", "LeftLowerArm" },
	{ "lW", "LeftLowerArm", "LeftHand" },
	{ "rH", "LowerTorso", "RightUpperLeg" },
	{ "rK", "RightUpperLeg", "RightLowerLeg" },
	{ "rA", "RightLowerLeg", "RightFoot" },
	{ "lH", "LowerTorso", "LeftUpperLeg" },
	{ "lK", "LeftUpperLeg", "LeftLowerLeg" },
	{ "lA", "LeftLowerLeg", "LeftFoot" },
}

--- Every part's CFrame in HumanoidRootPart space under `pose`, solved through
--- the joint frames (part positions lag a step behind a pose change).
function SeatPosture.frames(rig: RigPose.Rig, pose: RigPose.Pose): { [string]: CFrame }
	local f: { [string]: CFrame } = { HumanoidRootPart = CFrame.identity }
	for _, j in TREE do
		local key, p0, p1 = j[1], j[2], j[3]
		local base, far, parent = rig.base[key], rig.far[key], f[p0]
		if base and far and parent then
			local off = jointAngles(key, pose[key] or ZERO)
			if key == "root" and pose.rootPos then
				off = CFrame.new(pose.rootPos) * off
			end
			f[p1] = parent * base * off * far:Inverse()
		end
	end
	return f
end

local function size(model: Model, name: string, fallback: Vector3): Vector3
	local p = model:FindFirstChild(name)
	return if p and p:IsA("BasePart") then p.Size else fallback
end

--------------------------------------------------------------------------------
-- Arm solver
--------------------------------------------------------------------------------

type Goal = {
	hand: Vector3, -- hand centre, root space
	elbow: Vector3?, -- where the elbow should rest, if anywhere
	elbowW: number?,
	palm: Vector3?, -- direction the palm should face, root space
	fingers: Vector3?, -- direction the fingers should point, root space
}

-- The palm is the hand's inner side at rest (arms hanging, palms to the
-- thighs): -X on the right hand, +X on the left.
local PALM = { r = V(-1, 0, 0), l = V(1, 0, 0) }
local FINGERS = V(0, -1, 0) -- hanging at rest, the fingers point down

local function chain(rig: RigPose.Rig, side: string, torso: CFrame, s: Vector3, e: Vector3, w: Vector3): (CFrame, Vector3)
	local kS, kE, kW = side .. "S", side .. "E", side .. "W"
	local upper = torso * rig.base[kS] * jointAngles(kS, s) * rig.far[kS]:Inverse()
	local elbowAt = upper * rig.base[kE]
	local lower = elbowAt * jointAngles(kE, e) * rig.far[kE]:Inverse()
	local hand = lower * rig.base[kW] * jointAngles(kW, w) * rig.far[kW]:Inverse()
	return hand, elbowAt.Position
end

-- Pattern search over a few joint angles: cheap, needs no Jacobian, and with
-- a pull toward the authored seed it keeps the natural elbow direction.
local function search(q: { number }, lo: { number }, hi: { number }, cost: ({ number }) -> number)
	local best = cost(q)
	local step = 8
	local iter = 0
	while step >= 0.25 and iter < 300 do
		iter += 1
		local improved = false
		for i = 1, #q do
			for _, d in { step, -step } do
				local old = q[i]
				q[i] = math.clamp(old + d, lo[i], hi[i])
				local c = cost(q)
				if c < best - 1e-7 then
					best = c
					improved = true
				else
					q[i] = old
				end
			end
		end
		if not improved then
			step /= 2
		end
	end
end

local REG = 2e-5 -- stud^2 per degree^2 off the seed: 10 degrees ~ 0.045 stud^2

--- Shoulder, elbow and wrist angles that put this side's hand on `goal`.
local function solveArm(rig: RigPose.Rig, side: string, torso: CFrame, goal: Goal, seedS: Vector3, seedE: number): (Vector3, Vector3, Vector3)
	local kS, kE, kW = side .. "S", side .. "E", side .. "W"
	if not (rig.base[kS] and rig.base[kE] and rig.base[kW]) then
		return seedS, V(seedE, 0, 0), ZERO
	end
	local w = ZERO
	local q = { seedS.X, seedS.Y, seedS.Z, seedE }
	local armCost = function(p: { number }): number
		local hand, elbow = chain(rig, side, torso, V(p[1], p[2], p[3]), V(p[4], 0, 0), w)
		local c = (hand.Position - goal.hand).Magnitude ^ 2
		if goal.elbow then
			c += (goal.elbowW or 0.3) * (elbow - goal.elbow).Magnitude ^ 2
		end
		local r = (p[1] - seedS.X) ^ 2 + (p[2] - seedS.Y) ^ 2 + (p[3] - seedS.Z) ^ 2 + (p[4] - seedE) ^ 2
		return c + r * REG
	end
	local LO = { -60, -90, -95, -150 }
	local HI = { 170, 90, 95, 0 }
	search(q, LO, HI, armCost)

	if goal.palm or goal.fingers then
		-- turn the hand, then let the arm take up the shift that caused
		local wq = { 0, 0, 0 }
		local palm, fingers = goal.palm, goal.fingers
		search(wq, { -80, -80, -80 }, { 80, 80, 80 }, function(p: { number }): number
			local hand = chain(rig, side, torso, V(q[1], q[2], q[3]), V(q[4], 0, 0), V(p[1], p[2], p[3]))
			local c = (p[1] ^ 2 + p[2] ^ 2 + p[3] ^ 2) * 2e-6
			if palm then
				c += 1 - hand:VectorToWorldSpace(PALM[side]):Dot(palm)
			end
			if fingers then
				c += 1 - hand:VectorToWorldSpace(FINGERS):Dot(fingers)
			end
			return c
		end)
		w = V(wq[1], wq[2], wq[3])
		search(q, LO, HI, armCost)
	end
	return V(q[1], q[2], q[3]), V(q[4], 0, 0), w
end

--------------------------------------------------------------------------------
-- Legs
--------------------------------------------------------------------------------

local function fitLegs(rig: RigPose.Rig, pose: RigPose.Pose, floor: number?)
	pose.rH = V(-90, 0, 3)
	pose.lH = V(-90, 0, -3)
	pose.rK = V(90, 0, 0)
	pose.lK = V(90, 0, 0)
	if not floor then
		return
	end
	-- how high the ankle joint stands off the floor, from the rest pose
	local rest = SeatPosture.frames(rig, {})
	local footSize = size(rig.model, "RightFoot", V(0.6, 0.4, 1))
	local restFoot = rest.RightFoot
	if not (restFoot and rig.base.rA) then
		return
	end
	local ankleRest = (rest.RightLowerLeg * rig.base.rA).Position.Y
	local ankleUp = ankleRest - (restFoot.Position.Y - footSize.Y / 2)
	-- open or close the knees until the ankles sit that high off the floor;
	-- a seat too high for the legs leaves the feet hanging, as it would
	local bestK, bestErr = 90, math.huge
	for k = 55, 100 do
		pose.rK = V(k, 0, 0)
		local f = SeatPosture.frames(rig, pose)
		local ankle = (f.RightLowerLeg * rig.base.rA).Position.Y
		local err = math.abs(ankle - (floor + ankleUp))
		if err < bestErr then
			bestK, bestErr = k, err
		end
	end
	-- then flatten the foot on the floor
	pose.rK = V(bestK, 0, 0)
	local bestA, bestFlat = 0, -math.huge
	for a = -50, 50, 2 do
		pose.rA = V(a, 0, 0)
		local f = SeatPosture.frames(rig, pose)
		local flat = f.RightFoot.UpVector.Y
		if flat > bestFlat then
			bestA, bestFlat = a, flat
		end
	end
	pose.rA = V(bestA, 0, 0)
	pose.lK = pose.rK
	pose.lA = pose.rA
end

--------------------------------------------------------------------------------
-- Styles
--------------------------------------------------------------------------------

type Dims = {
	torso: Vector3,
	head: Vector3,
	thigh: Vector3,
	hand: Vector3,
}

type Style = {
	body: RigPose.Pose, -- spine and head
	seedS: Vector3, -- right arm seeds; the left mirrors them
	seedE: number,
	desk: boolean?, -- needs ctx.desk, else falls back to "lap"
	fit: ((rig: RigPose.Rig, pose: RigPose.Pose, d: Dims, ctx: Context) -> ())?, -- adjusts the body first
	goals: (f: { [string]: CFrame }, d: Dims, ctx: Context, rig: RigPose.Rig) -> (Goal, Goal),
}

local DOWN = V(0, -1, 0)

--- A point on top of a thigh, `along` of the way from hip to knee, `inward`
--- studs toward the midline.
local function onThigh(f: { [string]: CFrame }, rig: RigPose.Rig, side: string, d: Dims, along: number, inward: number): Vector3
	local leg = f[if side == "r" then "RightUpperLeg" else "LeftUpperLeg"]
	local hipAt = (leg * rig.far[side .. "H"]).Position
	local kneeAt = (leg * rig.base[side .. "K"]).Position
	local p = hipAt:Lerp(kneeAt, along)
	local toward = if p.X > 0 then -1 else 1 -- the root-space midline is X = 0
	return p + V(toward * inward, d.thigh.Z / 2 + d.hand.X / 2 + 0.02, 0)
end

local function mirror(g: Goal): Goal
	return {
		hand = V(-g.hand.X, g.hand.Y, g.hand.Z),
		elbow = if g.elbow then V(-g.elbow.X, g.elbow.Y, g.elbow.Z) else nil,
		elbowW = g.elbowW,
		palm = if g.palm then V(-g.palm.X, g.palm.Y, g.palm.Z) else nil,
		fingers = if g.fingers then V(-g.fingers.X, g.fingers.Y, g.fingers.Z) else nil,
	}
end

SeatPosture.STYLES = {} :: { [string]: Style }
local S = SeatPosture.STYLES

-- hands resting on the thighs, palms down
S.lap = {
	body = { waist = V(2, 0, 0), neck = V(4, 0, 0) },
	seedS = V(26, 0, -4),
	seedE = -50,
	goals = function(f, d, _ctx, rig)
		return { hand = onThigh(f, rig, "r", d, 0.6, 0.05), palm = DOWN },
			{ hand = onThigh(f, rig, "l", d, 0.6, 0.05), palm = DOWN }
	end,
}

-- leaned back, hands loosely together in the lap
S.clasped = {
	body = { waist = V(-6, 0, 0), neck = V(2, 0, 0) },
	seedS = V(20, 0, -10),
	seedE = -60,
	goals = function(f, d, _ctx, rig)
		local r = onThigh(f, rig, "r", d, 0.45, 0)
		local y = r.Y + 0.05
		local z = r.Z
		local half = d.hand.Z * 0.45
		return { hand = V(half, y, z), palm = V(-0.5, -0.85, 0).Unit }, { hand = V(-half, y, z), palm = V(0.5, -0.85, 0).Unit }
	end,
}

-- arms folded across the chest: forearms level across the lower ribs, the
-- right one in front, each hand tucked against the opposite upper arm
S.crossed = {
	body = { waist = V(-8, 0, 0), neck = V(2, 0, 0) },
	seedS = V(30, 0, -30),
	seedE = -112,
	goals = function(f, d)
		local t = f.UpperTorso
		local X, Y, front = d.torso.X, d.torso.Y, d.torso.Z / 2
		-- elbows forward of the ribs, forearms angled in: a forearm spans
		-- only about two thirds of the chest
		-- the hands curl back around the opposite upper arms, fingers out of sight
		local r: Goal = {
			hand = t * V(-X * 0.4, -Y * 0.18, -(front + 0.08)),
			elbow = t * V(X * 0.3, -Y * 0.45, -(front + 0.42)),
			elbowW = 0.4,
			fingers = t:VectorToWorldSpace(V(-0.35, 0.1, 1).Unit),
		}
		local l: Goal = {
			hand = t * V(X * 0.42, -Y * 0.12, -(front - 0.04)),
			elbow = t * V(-X * 0.3, -Y * 0.5, -(front + 0.3)),
			elbowW = 0.4,
			fingers = t:VectorToWorldSpace(V(0.35, 0.1, 1).Unit),
		}
		return r, l
	end,
}

-- a phone held in both hands in front of the stomach, eyes down on it
S.phone = {
	body = { waist = V(8, 0, 0), neck = V(30, 0, 0) },
	seedS = V(20, 0, -10),
	seedE = -95,
	goals = function(f, d)
		local t = f.UpperTorso
		local X, Y, front = d.torso.X, d.torso.Y, d.torso.Z / 2
		local half = d.hand.Z * 0.55
		local r: Goal = {
			hand = t * V(half, -Y * 0.62, -(front + 0.6)),
			elbow = t * V(X * 0.5, -Y * 0.6, -front * 0.2),
			elbowW = 0.25,
			palm = V(-0.5, 0.85, 0.15).Unit, -- screen tipped up toward the face
		}
		return r, mirror(r)
	end,
}

-- hunched forward, elbows on the knees, hands together between them
S.knees = {
	body = { waist = V(30, 0, 0), neck = V(-12, 0, 0) },
	seedS = V(50, 0, -6),
	seedE = -70,
	goals = function(f, d, _ctx, rig)
		local rk = onThigh(f, rig, "r", d, 0.85, 0)
		local y = rk.Y - d.thigh.Z * 0.6
		local z = rk.Z - 0.35
		local half = d.hand.Z * 0.45
		local r: Goal = { hand = V(half, y, z), elbow = onThigh(f, rig, "r", d, 0.75, 0.05), elbowW = 0.5 }
		return r, mirror(r)
	end,
}

-- one hand on a thigh, the other up mid-sentence
S.talking = {
	body = { waist = V(4, 0, 0), neck = V(2, 0, 8) },
	seedS = V(36, 0, -16),
	seedE = -85,
	goals = function(f, d, _ctx, rig)
		local t = f.UpperTorso
		local r = t * V(d.torso.X * 0.55, -d.torso.Y * 0.25, -(d.torso.Z / 2 + 0.9))
		return { hand = r, palm = V(-0.3, 0.6, -0.7).Unit }, { hand = onThigh(f, rig, "l", d, 0.6, 0.05), palm = DOWN }
	end,
}

--- Where the hands work on the desk: ctx.deskAt is the middle of the keys
--- (root space, on their surface); without it, a spot in front of the chest.
local function keys(f: { [string]: CFrame }, d: Dims, ctx: Context): Vector3
	return ctx.deskAt or V(0, ctx.desk :: number, f.UpperTorso.Position.Z - d.torso.Z / 2 - 1.2)
end

-- typing: fingers on the keys, palms down, elbows in at the sides
S.typing = {
	body = { waist = V(6, 0, 0), neck = V(14, 0, 0) },
	seedS = V(30, 0, -6),
	seedE = -70,
	desk = true,
	goals = function(f, d, ctx)
		local k = keys(f, d, ctx)
		-- the hand's centre sits behind the fingertips on the keys
		local r: Goal = { hand = V(k.X + 0.4, k.Y + d.hand.X / 2 + 0.02, k.Z + d.hand.Y * 0.3), palm = DOWN }
		local l: Goal = { hand = V(k.X - 0.4, k.Y + d.hand.X / 2 + 0.02, k.Z + d.hand.Y * 0.3), palm = DOWN }
		return r, l
	end,
}

-- right hand on the mouse (or trackpad), left resting on the keys
S.mouse = {
	body = { waist = V(5, 0, 0), neck = V(12, 0, 0) },
	seedS = V(30, 0, -10),
	seedE = -70,
	desk = true,
	goals = function(f, d, ctx)
		local k = keys(f, d, ctx)
		local m = ctx.mouseAt or (k + V(0.9, 0, 0.3))
		local r: Goal = { hand = V(m.X, m.Y + d.hand.X / 2 + 0.03, m.Z + d.hand.Y * 0.2), palm = DOWN }
		local l: Goal = { hand = V(k.X - 0.45, k.Y + d.hand.X / 2 + 0.02, k.Z + d.hand.Y * 0.35), palm = DOWN }
		return r, l
	end,
}

-- leaned back from the desk, reading, forearms resting on its front edge
S.deskRest = {
	body = { waist = V(-7, 0, 0), neck = V(4, 0, 0) },
	seedS = V(26, 0, -8),
	seedE = -75,
	desk = true,
	goals = function(f, d, ctx)
		local k = keys(f, d, ctx)
		local y = (ctx.desk :: number) + d.hand.X / 2 + 0.02
		local z = k.Z + d.hand.Y * 0.9
		return { hand = V(0.55, y, z), palm = DOWN }, { hand = V(-0.55, y, z), palm = DOWN }
	end,
}

-- chin propped on the right hand, elbow on the desk; the left hand on it
S.chin = {
	body = { waist = V(18, 0, 0), neck = V(6, 0, 8) },
	seedS = V(70, 0, -14),
	seedE = -120,
	desk = true,
	goals = function(f, d, ctx)
		local desk = ctx.desk :: number
		local h = f.Head
		local chin = h * V(0.05, -d.head.Y * 0.5 - d.hand.Y * 0.25, -d.head.Z * 0.3)
		local elbow = V(chin.X + 0.15, desk + 0.15, chin.Z + 0.1)
		local z = f.UpperTorso.Position.Z - d.torso.Z / 2 - 1.1
		return { hand = chin, elbow = elbow, elbowW = 0.25 },
			{ hand = V(-0.45, desk + d.hand.X / 2 + 0.03, z), palm = DOWN }
	end,
}

-- head in both hands, elbows on the desk
S.headHands = {
	body = { waist = V(24, 0, 0), neck = V(22, 0, 0) },
	seedS = V(76, 0, -18),
	seedE = -122,
	desk = true,
	goals = function(f, d, ctx)
		local desk = ctx.desk :: number
		local h = f.Head
		local r = h * V(d.head.X * 0.5 + d.hand.X * 0.5, -d.head.Y * 0.05, -d.head.Z * 0.05)
		local g: Goal = {
			hand = r,
			elbow = V(r.X + 0.1, desk + 0.15, r.Z + 0.15),
			elbowW = 0.5,
		}
		return g, mirror(g)
	end,
}

-- asleep on the desk, head down on folded arms
S.asleep = {
	body = { waist = V(46, 0, 0), neck = V(30, 0, 0) },
	seedS = V(78, 0, -10),
	seedE = -100,
	desk = true,
	goals = function(f, d, ctx)
		-- on top of whatever is on the desk (a laptop's keys)
		local desk = math.max(ctx.desk :: number, if ctx.deskAt then ctx.deskAt.Y else -math.huge)
		local h = f.Head
		local y = desk + d.hand.X / 2 + 0.03
		local z = h.Position.Z - 0.1
		-- forearms crossed flat under the head
		return { hand = V(-0.45, y, z + 0.05), elbow = V(0.75, desk + 0.12, z + 0.2), elbowW = 0.6, palm = DOWN },
			{ hand = V(0.45, y + 0.04, z - 0.05), elbow = V(-0.75, desk + 0.12, z + 0.2), elbowW = 0.6, palm = DOWN }
	end,
	-- bow forward until the face rests on the forearms
	fit = function(rig, pose, d, ctx)
		local surface = math.max(ctx.desk :: number, if ctx.deskAt then ctx.deskAt.Y else -math.huge)
		local want = surface + d.hand.X + 0.25
		local best, bestErr = 46, math.huge
		for w = 20, 75 do
			pose.waist = V(w, 0, 0)
			local f = SeatPosture.frames(rig, pose)
			local err = math.abs(f.Head.Position.Y - d.head.Y * 0.35 - want)
			if err < bestErr then
				best, bestErr = w, err
			end
		end
		pose.waist = V(best, 0, 0)
	end,
}

-- dozing on a couch: slumped back, head lolled to one side, hands in the lap
S.dozing = {
	body = { waist = V(-12, 0, 8), neck = V(-14, 0, 22) },
	seedS = V(18, 0, -10),
	seedE = -60,
	goals = function(f, d, _ctx, rig)
		return { hand = onThigh(f, rig, "r", d, 0.4, 0.12), palm = V(-0.4, -0.9, 0).Unit },
			{ hand = onThigh(f, rig, "l", d, 0.45, 0.1), palm = V(0.4, -0.9, 0).Unit }
	end,
}

--- The knee joint's distance forward of the root when seated (studs, root
--- space -Z), for sliding a sitter forward on a deep seat.
function SeatPosture.kneeReach(rig: RigPose.Rig): number
	local f = SeatPosture.frames(rig, { rH = V(-90, 0, 0), lH = V(-90, 0, 0) })
	local leg = f.RightUpperLeg
	if not (leg and rig.base.rK) then
		return 1.4
	end
	return -(leg * rig.base.rK).Position.Z
end

--- The seated pose for `style` on this rig. Desk styles without a desk in
--- `ctx` sit back with their hands in their lap. `body` replaces the style's
--- spine and head pose, for callers that animate those themselves.
function SeatPosture.build(rig: RigPose.Rig, style: string, ctx: Context?, body: RigPose.Pose?): RigPose.Pose
	local c: Context = ctx or {}
	local st = S[style] or S.lap
	if st.desk and not c.desk then
		st = S.lap
	end
	local pose: RigPose.Pose = table.clone(body or st.body)
	fitLegs(rig, pose, c.floor)

	local model = rig.model
	local d: Dims = {
		torso = size(model, "UpperTorso", V(2, 1.6, 1)),
		head = size(model, "Head", V(1.2, 1.2, 1.2)),
		thigh = size(model, "RightUpperLeg", V(0.8, 1.6, 0.8)),
		hand = size(model, "RightHand", V(0.3, 0.6, 0.6)),
	}
	if st.fit then
		st.fit(rig, pose, d, c)
	end
	local f = SeatPosture.frames(rig, pose)
	if not f.UpperTorso then
		return pose
	end
	local gr, gl = st.goals(f, d, c, rig)
	local seedL = V(st.seedS.X, -st.seedS.Y, -st.seedS.Z)
	pose.rS, pose.rE, pose.rW = solveArm(rig, "r", f.UpperTorso, gr, st.seedS, st.seedE)
	pose.lS, pose.lE, pose.lW = solveArm(rig, "l", f.UpperTorso, gl, seedL, st.seedE)
	return pose
end

--- How far the hands miss their targets under `pose` (studs, worst side), for
--- checking a fit.
function SeatPosture.miss(rig: RigPose.Rig, style: string, ctx: Context?, pose: RigPose.Pose): number
	local c: Context = ctx or {}
	local st = S[style] or S.lap
	if st.desk and not c.desk then
		st = S.lap
	end
	local model = rig.model
	local d: Dims = {
		torso = size(model, "UpperTorso", V(2, 1.6, 1)),
		head = size(model, "Head", V(1.2, 1.2, 1.2)),
		thigh = size(model, "RightUpperLeg", V(0.8, 1.6, 0.8)),
		hand = size(model, "RightHand", V(0.3, 0.6, 0.6)),
	}
	local f = SeatPosture.frames(rig, pose)
	local gr, gl = st.goals(f, d, c, rig)
	return math.max((f.RightHand.Position - gr.hand).Magnitude, (f.LeftHand.Position - gl.hand).Magnitude)
end

return SeatPosture
