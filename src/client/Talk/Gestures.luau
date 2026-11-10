--!strict
--------------------------------------------------------------------------------
-- Talk/Gestures.luau
-- What a named NPC does with their body while you talk to them. Each gesture
-- names where the hands go (a fist under the chin, palms up in front, a hand
-- on the back of the neck...); the arms are solved to those spots through this
-- body's own joints (Shared.SeatPosture.reach), once per NPC and gesture, so
-- every build lands its hands in the same place.
--
-- NPCDialogue drives it: say() plays a node's gestures in order across the
-- time its line takes to type, with beat gestures and nods while the words
-- come out; listen() holds a pose (often the thinker) while you choose. The
-- result is blended into NPCPosture's standing pose every frame (apply), and
-- eased back out when the conversation ends.
--------------------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RigPose = require(Shared:WaitForChild("RigPose"))
local SeatPosture = require(Shared:WaitForChild("SeatPosture"))

local V = Vector3.new
local ZERO = Vector3.zero
local REST_ATTRIBUTE = "RestFrame"

local EASE = 4.5 -- 1/s, how quickly the body moves between gestures
local FADE = 3 -- 1/s, how quickly the whole thing blends in and out

type Goal = SeatPosture.Goal
type Frames = { [string]: CFrame }
type Dims = { torso: Vector3, head: Vector3, hand: Vector3, hips: Vector3 }
type GoalFn = (f: Frames, d: Dims, rig: RigPose.Rig) -> Goal

type Def = {
	body: RigPose.Pose, -- waist and neck, added to the standing pose
	seedS: Vector3, -- right shoulder seed; the left mirrors it unless seedSL
	seedE: number,
	seedSL: Vector3?,
	seedEL: number?,
	right: GoalFn?,
	-- solved after the right arm, so its frames include the right arm: it can
	-- reach for it (the thinker's supporting hand)
	left: GoalFn?,
	mirror: boolean?, -- the left goal is the right one mirrored
	-- extra right-arm seeds {shoulder, elbow} to start the solve from; the
	-- closest result wins (a lone seed can settle with the arm twisted wrong)
	starts: { { any } }?,
}

local UP = V(0, 1, 0)
local FORWARD = V(0, 0, -1)

local DEFS: { [string]: Def } = {}

--- Where the elbow goes for the hand to reach `hand`, bending toward `bend`
--- (root space): two-link geometry on this arm's own segment lengths, so the
--- elbow goal never asks for more reach than the arm has.
local function elbowFor(f: Frames, rig: RigPose.Rig, side: string, hand: Vector3, bend: Vector3): Vector3
	local kS, kE, kW = side .. "S", side .. "E", side .. "W"
	local shoulder = (f.UpperTorso * rig.base[kS]).Position
	local upper = (rig.base[kE].Position - rig.far[kS].Position).Magnitude
	local fore = (rig.base[kW].Position - rig.far[kE].Position).Magnitude
	local span = hand - shoulder
	local dist = math.clamp(span.Magnitude, 0.05, upper + fore - 0.01)
	local u = span.Unit
	local along = (upper * upper - fore * fore + dist * dist) / (2 * dist)
	local out = math.sqrt(math.max(upper * upper - along * along, 0))
	local perp = bend - u * bend:Dot(u)
	perp = if perp.Magnitude > 1e-3 then perp.Unit else V(0, -1, 0)
	return shoulder + u * along + perp * out
end

-- hands loosely together in front of the hips: the default listening pose
DEFS.rest = {
	body = {},
	seedS = V(18, 0, -4),
	seedE = -55,
	mirror = true,
	right = function(f, d)
		return {
			hand = f.LowerTorso * V(d.hand.Z * 0.45, d.hips.Y * 0.15, -(d.hips.Z / 2 + d.hand.X / 2 + 0.28)),
			palm = V(-1, 0, 0),
		}
	end,
}

-- the thinker: fist under the chin, the other forearm across the stomach
-- propping that elbow up
DEFS.ponder = {
	body = { waist = V(6, 0, 0), neck = V(13, 0, -6) },
	seedS = V(30, 0, 12),
	seedE = -140,
	starts = { { V(60, -40, 0), -140 }, { V(45, -70, 10), -130 }, { V(80, 0, 20), -145 }, { V(20, -30, 30), -150 } },
	seedSL = V(22, 0, 12),
	seedEL = -100,
	right = function(f, d, rig)
		local t = f.UpperTorso
		-- the fist's knuckles under the chin: the hand lies across, so its
		-- thickness, not its length, sits below the jaw
		local hand = f.Head * V(0.03, -(d.head.Y * 0.47 + d.hand.X * 0.5), -d.head.Z * 0.42)
		return {
			hand = hand,
			-- forearm near upright, the elbow down in front of the ribs
			elbow = elbowFor(f, rig, "r", hand, t:VectorToWorldSpace(V(0.15, -1, -0.35))),
			elbowW = 0.5,
			fingers = t:VectorToWorldSpace(V(0, 0.75, 0.65).Unit),
		}
	end,
	left = function(f, d, rig)
		local t = f.UpperTorso
		local elbow = (f.RightUpperArm * rig.base.rE).Position
		local hand = elbow + t:VectorToWorldSpace(V(-0.05, -(d.hand.X / 2 + 0.12), 0))
		return {
			hand = hand,
			elbow = elbowFor(f, rig, "l", hand, t:VectorToWorldSpace(V(-1, -0.6, -0.2))),
			elbowW = 0.3,
			palm = UP,
			fingers = t:VectorToWorldSpace(V(1, 0, 0)),
		}
	end,
}

-- explaining: forearms forward, palms up and open
DEFS.explain = {
	body = { waist = V(3, 0, 0) },
	seedS = V(35, 0, -10),
	seedE = -80,
	mirror = true,
	right = function(f, d)
		local t = f.UpperTorso
		return {
			hand = t * V(d.torso.X * 0.45, -d.torso.Y * 0.62, -(d.torso.Z / 2 + 0.8)),
			palm = V(-0.45, 0.89, 0).Unit,
			fingers = t:VectorToWorldSpace(V(0.25, -0.1, -1).Unit),
		}
	end,
}

-- pointing at you (or the way to go), the other hand at rest
DEFS.point = {
	body = { waist = V(4, 0, 0), neck = V(-2, 0, 0) },
	seedS = V(80, 0, -6),
	seedE = -20,
	seedSL = V(18, 0, 4),
	seedEL = -55,
	right = function(f, d)
		local t = f.UpperTorso
		return {
			hand = t * V(d.torso.X * 0.2, -d.torso.Y * 0.08, -(d.torso.Z / 2 + 1.55)),
			fingers = t:VectorToWorldSpace(FORWARD),
			palm = t:VectorToWorldSpace(V(-1, 0, 0)),
		}
	end,
	left = function(f, d)
		return {
			hand = f.LowerTorso * V(-d.hand.Z * 0.2, -d.hips.Y * 0.4, -(d.hips.Z / 2 + d.hand.X / 2 + 0.16)),
			palm = V(1, 0, 0),
		}
	end,
}

-- shrug: palms up out to the sides, head tipped
DEFS.shrug = {
	body = { waist = V(-3, 0, 0), neck = V(-4, 0, 10) },
	seedS = V(18, 0, -28),
	seedE = -85,
	mirror = true,
	right = function(f, d)
		local t = f.UpperTorso
		return {
			hand = t * V(d.torso.X * 0.9, -d.torso.Y * 0.8, -(d.torso.Z / 2 + 0.55)),
			palm = UP,
			fingers = t:VectorToWorldSpace(V(0.55, 0, -0.85).Unit),
		}
	end,
}

-- arms folded across the chest (SeatPosture's crossed arms, standing)
DEFS.crossed = {
	body = { waist = V(-4, 0, 0), neck = V(2, 0, 0) },
	seedS = V(30, 0, -30),
	seedE = -112,
}

-- rubbing the back of the neck, eyes down
DEFS.neck = {
	body = { waist = V(3, 0, 0), neck = V(12, 0, 4) },
	seedS = V(125, 0, -40),
	seedE = -140,
	right = function(f, d)
		local t = f.UpperTorso
		return {
			hand = f.Head * V(0.12, -d.head.Y * 0.42, d.head.Z * 0.55),
			elbow = t * V(d.torso.X * 0.95, d.torso.Y * 0.55, -(d.torso.Z / 2 + 0.25)),
			elbowW = 0.3,
			palm = t:VectorToWorldSpace(FORWARD),
			fingers = UP,
		}
	end,
}

-- hands on hips, elbows out
DEFS.hips = {
	body = { waist = V(-4, 0, 0), neck = V(-3, 0, 0) },
	seedS = V(5, 0, 30),
	seedE = -95,
	starts = { { V(-10, -40, 40), -90 }, { V(0, -70, 50), -100 }, { V(10, 30, 45), -80 }, { V(-20, -20, 60), -110 } },
	mirror = true,
	right = function(f, d, rig)
		local t = f.UpperTorso
		-- the side of the waist, just under the ribs
		local hand = t * V(d.torso.X * 0.5 + d.hand.X * 0.7, -d.torso.Y * 0.5, 0.02)
		return {
			hand = hand,
			elbow = elbowFor(f, rig, "r", hand, t:VectorToWorldSpace(V(1, 0, 0.45))),
			elbowW = 0.6,
			palm = t:VectorToWorldSpace(V(-1, 0, 0)),
			fingers = t:VectorToWorldSpace(V(0, -0.5, -0.85).Unit),
		}
	end,
}

-- a finger to the lips: shh
DEFS.hush = {
	body = { waist = V(6, 0, 0), neck = V(4, 0, 0) },
	seedS = V(70, 0, -5),
	seedE = -140,
	right = function(f, d)
		local t = f.UpperTorso
		return {
			hand = f.Head * V(0, -d.head.Y * 0.2, -(d.head.Z / 2 + d.hand.X / 2 + 0.06)),
			elbow = t * V(d.torso.X * 0.35, -d.torso.Y * 0.4, -(d.torso.Z / 2 + 0.3)),
			elbowW = 0.3,
			fingers = UP,
			palm = t:VectorToWorldSpace(V(-1, 0, 0)),
		}
	end,
}

-- hands clutching the sides of the head
DEFS.clutch = {
	body = { waist = V(10, 0, 0), neck = V(14, 0, 0) },
	seedS = V(110, 0, -40),
	seedE = -130,
	mirror = true,
	right = function(f, d)
		local t = f.UpperTorso
		return {
			hand = f.Head * V(d.head.X / 2 + d.hand.X / 2 + 0.02, 0.05, 0.05),
			elbow = t * V(d.torso.X * 0.75, d.torso.Y * 0.35, -(d.torso.Z / 2 + 0.6)),
			elbowW = 0.3,
			palm = V(-1, 0, 0),
			fingers = t:VectorToWorldSpace(V(0, 0.8, 0.6).Unit),
		}
	end,
}

-- a hand raised beside the head, palm out (waved by the overlay)
DEFS.wave = {
	body = { neck = V(-2, 0, -4) },
	seedS = V(40, 0, -60),
	seedE = -100,
	right = function(f, d)
		local t = f.UpperTorso
		return {
			hand = t * V(d.torso.X * 0.85, d.torso.Y * 0.85, -(d.torso.Z / 2 + 0.25)),
			elbow = t * V(d.torso.X * 1.0, d.torso.Y * 0.05, -(d.torso.Z / 2 + 0.1)),
			elbowW = 0.3,
			palm = t:VectorToWorldSpace(FORWARD),
			fingers = UP,
		}
	end,
}

--------------------------------------------------------------------------------
-- Solving
--------------------------------------------------------------------------------

local ARM_KEYS = { "rS", "rE", "rW", "lS", "lE", "lW" }
local KEYS = { "waist", "neck", "rS", "rE", "rW", "lS", "lE", "lW" }

local function mirrorSeed(s: Vector3): Vector3
	return V(s.X, -s.Y, -s.Z)
end

local function size(model: Model, name: string, fallback: Vector3): Vector3
	local p = model:FindFirstChild(name)
	return if p and p:IsA("BasePart") then p.Size else fallback
end

--- A rig whose base frames are the joints' rest frames (the frames the
--- standing pose is written against).
local function restRig(model: Model): RigPose.Rig
	local rig = RigPose.new(model)
	for key, names in RigPose.JOINTS do
		local part = model:FindFirstChild(names[1])
		local c = part and part:FindFirstChild(names[2])
		if c and c:IsA("AnimationConstraint") and c.Attachment0 then
			local rest = c.Attachment0:GetAttribute(REST_ATTRIBUTE)
			if typeof(rest) == "CFrame" then
				rig.base[key] = rest
			end
		elseif c and c:IsA("Motor6D") then
			local rest = c:GetAttribute(REST_ATTRIBUTE)
			if typeof(rest) == "CFrame" then
				rig.base[key] = rest
			end
		end
	end
	return rig
end

local function solve(rig: RigPose.Rig, d: Dims, name: string): RigPose.Pose
	local def = DEFS[name] or DEFS.rest
	local pose: RigPose.Pose = table.clone(def.body)
	local f = SeatPosture.frames(rig, pose)
	local t = f.UpperTorso
	if not t then
		return pose
	end
	local right: Goal?, left: Goal? = nil, nil
	if name == "crossed" then
		local cr = SeatPosture.STYLES.crossed
		right, left = cr.goals(f, { torso = d.torso, head = d.head, hand = d.hand, thigh = d.hips }, {}, rig)
	elseif def.right then
		right = def.right(f, d, rig)
	end
	local seedSL = def.seedSL or mirrorSeed(def.seedS)
	local seedEL = def.seedEL or def.seedE
	if right then
		pose.rS, pose.rE, pose.rW = SeatPosture.reach(rig, "r", t, right, def.seedS, def.seedE)
		if def.starts then
			local goal = right
			local function miss(): number
				local g = SeatPosture.frames(rig, pose)
				local m = (g.RightHand.Position - goal.hand).Magnitude
				if goal.elbow then
					m += 0.5 * ((g.RightUpperArm * rig.base.rE).Position - goal.elbow).Magnitude
				end
				return m
			end
			local best = miss()
			local keep = { pose.rS, pose.rE, pose.rW }
			for _, st in def.starts do
				pose.rS, pose.rE, pose.rW = SeatPosture.reach(rig, "r", t, goal, st[1], st[2])
				local m = miss()
				if m < best then
					best = m
					keep = { pose.rS, pose.rE, pose.rW }
				end
			end
			pose.rS, pose.rE, pose.rW = keep[1], keep[2], keep[3]
		end
		if def.mirror then
			left = SeatPosture.mirror(right)
		end
	end
	if not left and def.left then
		left = def.left(SeatPosture.frames(rig, pose), d, rig)
	end
	if left then
		pose.lS, pose.lE, pose.lW = SeatPosture.reach(rig, "l", t, left, seedSL, seedEL)
	end
	return pose
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

type State = {
	rig: RigPose.Rig,
	dims: Dims,
	poses: { [string]: RigPose.Pose },
	seq: { string },
	seqStart: number,
	seqDur: number,
	speaking: boolean,
	listen: string,
	laughUntil: number,
	cur: { [string]: Vector3 }, -- eased gesture values (offsets for waist/neck)
	w: number,
	goalW: number,
	seed: number,
	shown: string?,
}

local states: { [Model]: State } = {}

local Gestures = {}

local function poseOf(s: State, name: string): RigPose.Pose
	local p = s.poses[name]
	if not p then
		p = solve(s.rig, s.dims, name)
		s.poses[name] = p
	end
	return p
end

--- Start holding a conversation pose on `model` (blends in).
function Gestures.begin(model: Model)
	local s = states[model]
	if s then
		s.goalW = 1
		return
	end
	local rig = restRig(model)
	states[model] = {
		rig = rig,
		dims = {
			torso = size(model, "UpperTorso", V(2, 1.6, 1)),
			head = size(model, "Head", V(1.2, 1.2, 1.2)),
			hand = size(model, "RightHand", V(0.3, 0.6, 0.6)),
			hips = size(model, "LowerTorso", V(2, 0.6, 1)),
		},
		poses = {},
		seq = { "rest" },
		seqStart = os.clock(),
		seqDur = 1,
		speaking = false,
		listen = "rest",
		laughUntil = 0,
		cur = {},
		w = 0,
		goalW = 1,
		seed = math.random() * 100,
	}
end

--- Play `seq` across the next `duration` seconds of speech, then hold
--- `listen`. `laugh` shakes the shoulders for a moment.
function Gestures.say(model: Model, seq: { string }, duration: number, listen: string, laugh: boolean?)
	Gestures.begin(model)
	local s = states[model]
	s.seq = if #seq > 0 then seq else { "explain" }
	s.seqStart = os.clock()
	s.seqDur = math.max(duration, 0.5)
	s.speaking = true
	s.listen = listen
	s.laughUntil = if laugh then os.clock() + 1.6 else 0
	-- solve the first one now; the rest as they come up
	poseOf(s, s.seq[1])
end

--- The line has been said (or skipped): hold the listening pose.
function Gestures.listen(model: Model)
	local s = states[model]
	if s then
		s.speaking = false
	end
end

--- End the conversation: ease back to the standing pose.
function Gestures.finish(model: Model)
	local s = states[model]
	if s then
		s.speaking = false
		s.goalW = 0
	end
end

local function damp(rate: number, dt: number): number
	return 1 - math.exp(-rate * dt)
end

--- Blend the conversation into `pose` (NPCPosture's standing pose, written in
--- place). Returns true while it owns the arms.
function Gestures.apply(model: Model, pose: RigPose.Pose, now: number, dt: number): boolean
	local s = states[model]
	if not s then
		return false
	end
	s.w += (s.goalW - s.w) * damp(FADE, dt)
	if s.goalW == 0 and s.w < 0.01 then
		states[model] = nil
		model:SetAttribute("TalkGesture", nil)
		return false
	end

	-- which gesture now
	local name = s.listen
	local elapsed = now - s.seqStart
	if s.speaking and elapsed < s.seqDur then
		local i = math.clamp(math.floor(elapsed / s.seqDur * #s.seq) + 1, 1, #s.seq)
		name = s.seq[i]
	end
	if s.shown ~= name then
		-- client-local, for debugging which gesture a model is in
		s.shown = name
		model:SetAttribute("TalkGesture", name)
	end
	local target = poseOf(s, name)
	local k = damp(EASE, dt)
	for _, key in KEYS do
		local goal = target[key] or ZERO
		if key ~= "waist" and key ~= "neck" and not target[key] then
			-- an arm the gesture leaves free hangs as in the standing pose
			goal = pose[key] or ZERO
		end
		local c = s.cur[key] or (if key == "waist" or key == "neck" then ZERO else pose[key] or ZERO)
		s.cur[key] = c:Lerp(goal, k)
	end

	-- overlays
	local t = now + s.seed
	local talking = s.speaking and elapsed < s.seqDur
	-- words come in bursts; beats and nods ride on them
	local burst = if talking then math.max(0, math.sin(t * 1.7) + 0.35) * math.max(0, math.sin(t * 0.83 + 1) + 0.6) else 0
	local add: { [string]: Vector3 } = {}
	add.neck = V(2.2 * math.sin(t * 5.3) * burst, 3 * math.sin(t * 0.7), 0)
	if not talking then
		-- listening: a slow nod now and then
		add.neck += V(4 * math.max(0, math.sin(t * 1.9)) * math.max(0, math.sin(t * 0.31)), 0, 0)
	end
	if name == "explain" or name == "shrug" or name == "point" then
		add.rS = V(5 * math.sin(t * 4.3) * burst, 0, 0)
		add.lS = V(5 * math.sin(t * 3.6 + 1.3) * burst, 0, 0)
		add.rE = V(-7 * math.sin(t * 4.3 + 0.6) * burst, 0, 0)
		add.lE = V(-7 * math.sin(t * 3.6 + 1.9) * burst, 0, 0)
	elseif name == "wave" then
		add.rS = V(0, 14 * math.sin(t * 8), 0)
		add.rW = V(0, 0, 10 * math.sin(t * 8 + 0.8))
	elseif name == "clutch" and talking then
		add.neck += V(0, 9 * math.sin(t * 6.5), 0)
	elseif name == "ponder" then
		add.neck += V(0, 0, 2.5 * math.sin(t * 0.6))
	end
	if now < s.laughUntil then
		local shake = math.abs(math.sin(t * 11)) * (s.laughUntil - now) / 1.6
		add.waist = V(-4 * shake, 0, 0)
		add.neck += V(-6 * shake, 0, 0)
		add.rS = (add.rS or ZERO) + V(0, 0, -2 * shake)
		add.lS = (add.lS or ZERO) + V(0, 0, 2 * shake)
	end

	local w = s.w
	for _, key in KEYS do
		local base = pose[key] or ZERO
		local g = s.cur[key] :: Vector3
		local out
		if key == "waist" or key == "neck" then
			out = base + g * w
		else
			out = base:Lerp(g, w)
		end
		local a = add[key]
		if a then
			out += a * w
		end
		pose[key] = out
	end
	return true
end

--- Whether `model` has a conversation pose (blending in, held or easing out).
function Gestures.active(model: Model): boolean
	return states[model] ~= nil
end

Gestures.NAMES = DEFS
Gestures.ARM_KEYS = ARM_KEYS

return Gestures
