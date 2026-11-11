--!strict
--------------------------------------------------------------------------------
-- NGMIFit.luau
-- Fits the NGMI choreography (Shared.NGMIChoreo, client/NGMI/Poses) to the
-- body it plays on. Those poses were first written as plain joint angles for
-- the old blocky R15, whose arms hang straight and whose proportions are
-- fixed. The realistic bodies have longer arms, narrower chests and their own
-- head heights, so the same angles splay the arms at rest and miss every
-- contact (hands over the mouth, face in the hands, arms around the body).
--
--   armsIn(rig)    folds a per-body shoulder roll into the rig's base so the
--                  arms hang at the thighs; every authored pose then reads
--                  the way it was written
--   solve(rig)     solves the contact poses against this body's own head,
--                  torso and hands (Shared.SeatPosture.reach), once per rig
--   prepare(rig)   both; returns the Fit the choreography reads
--
-- A Fit maps a contact name to arm angles { rS, rE, rW, lS, lE, lW }. Each
-- contact is solved with the body pose it is played in (the lean and head
-- angle), since those move the head and torso the hands are reaching for.
--------------------------------------------------------------------------------

local RigPose = require(script.Parent:WaitForChild("RigPose"))
local SeatPosture = require(script.Parent:WaitForChild("SeatPosture"))

type Pose = RigPose.Pose
type Goal = SeatPosture.Goal

export type Fit = { [string]: Pose }

local NGMIFit = {}

local V = Vector3.new

local HAND_CLEAR = 0.06 -- studs between the hanging hand and the thigh
local ARM_IN_MAX = 30 -- degrees of roll the arms-in search may use

local function size(model: Model, name: string): Vector3
	local p = model:FindFirstChild(name)
	return if p and p:IsA("BasePart") then p.Size else V(1, 1, 1)
end

--- Fold a shoulder roll into the base that brings each hanging hand to the
--- outside of its thigh. Returns the roll used.
function NGMIFit.armsIn(rig: RigPose.Rig): number
	local model = rig.model
	local torso = model:FindFirstChild("UpperTorso")
	local leg = model:FindFirstChild("LeftUpperLeg")
	if not (torso and torso:IsA("BasePart") and leg and leg:IsA("BasePart") and rig.base.lS and rig.base.rS) then
		return 0
	end
	local thighOuter = math.abs(torso.CFrame:PointToObjectSpace(leg.Position).X) + leg.Size.X / 2
	local want = thighOuter + size(model, "LeftHand").X / 2 + HAND_CLEAR
	local roll = 0
	for z = 0, ARM_IN_MAX do
		local h = rig:handIn("l", { lS = V(0, 0, z) })
		if not h then
			return 0
		end
		roll = z
		if math.abs(h.X) <= want then
			break
		end
	end
	if roll > 0 then
		-- lS Z+ swings the left arm in, rS Z- the right
		rig:rebase({ lS = V(0, 0, roll), rS = V(0, 0, -roll) })
	end
	return roll
end

type Contact = {
	body: Pose, -- the lean and head angle the contact is played in
	seedS: Vector3,
	seedE: number,
	seedSL: Vector3?,
	seedEL: number?,
	goals: (f: { [string]: CFrame }, d: { [string]: Vector3 }) -> (Goal, Goal),
}

local CONTACTS: { [string]: Contact } = {}

-- Both hands clamped over the mouth, the left over the right: the witness.
CONTACTS.mouth = {
	body = { waist = V(-12, 0, 0), neck = V(-8, 0, 0) },
	seedS = V(60, 0, -60),
	seedE = -110,
	goals = function(f, d)
		local h, head = d.head, f.Head
		local back = head:VectorToWorldSpace(V(0, 0, 1))
		local front = -(h.Z / 2 + d.hand.X * 0.55)
		return {
			hand = head * V(h.X * 0.04, -h.Y * 0.3, front),
			palm = back,
			fingers = head:VectorToWorldSpace(V(-0.55, 0.85, 0).Unit),
		}, {
			hand = head * V(-h.X * 0.04, -h.Y * 0.33, front - d.hand.X * 0.9),
			palm = back,
			fingers = head:VectorToWorldSpace(V(0.55, 0.85, 0).Unit),
		}
	end,
}

-- Face buried in both hands, elbows down: the seated "no, no, no".
CONTACTS.face = {
	body = { waist = V(30, 0, 0), neck = V(22, 0, 0) },
	seedS = V(110, 0, -14),
	seedE = -110,
	goals = function(f, d)
		local h, head = d.head, f.Head
		local back = head:VectorToWorldSpace(V(0, 0, 1))
		local up = head:VectorToWorldSpace(V(0, 1, 0))
		local front = -(h.Z / 2 + d.hand.X * 0.55)
		return {
			hand = head * V(h.X * 0.26, -h.Y * 0.04, front),
			palm = back,
			fingers = up,
		}, {
			hand = head * V(-h.X * 0.26, -h.Y * 0.04, front),
			palm = back,
			fingers = up,
		}
	end,
}

-- Arms wrapped round the body, the right over the left, hands gripping the
-- opposite upper arm and flank: rocking before the turn.
CONTACTS.hug = {
	body = { waist = V(18, 0, 0), neck = V(27, 0, 0) },
	seedS = V(70, 0, -40),
	seedE = -100,
	goals = function(f, d)
		local t, ts = f.UpperTorso, d.torso
		local arm = d.arm.X
		return {
			hand = t * V(-(ts.X * 0.5 + arm * 0.35), ts.Y * 0.12, -ts.Z * 0.12),
			elbow = t * V(ts.X * 0.12, -ts.Y * 0.22, -(ts.Z * 0.5 + arm * 1.3)),
			elbowW = 0.4,
			palm = t:VectorToWorldSpace(V(1, 0, 0)),
		}, {
			hand = t * V(ts.X * 0.5 + arm * 0.3, -ts.Y * 0.18, -ts.Z * 0.05),
			elbow = t * V(-ts.X * 0.14, -ts.Y * 0.36, -(ts.Z * 0.5 + arm * 0.8)),
			elbowW = 0.4,
			palm = t:VectorToWorldSpace(V(-1, 0, 0)),
		}
	end,
}

-- Forearms thrown up across the face against an attack from the left.
CONTACTS.guard = {
	body = { waist = V(-16, 22, -10), neck = V(-24, 30, 0) },
	seedS = V(118, 0, -20),
	seedE = -110,
	goals = function(f, d)
		local h, head = d.head, f.Head
		local out = head:VectorToWorldSpace(V(0, 0, -1))
		return {
			hand = head * V(h.X * 0.55, h.Y * 0.42, -(h.Z * 0.5 + 0.55)),
			elbow = head * V(h.X * 0.9, -h.Y * 0.55, -(h.Z * 0.5 + 0.45)),
			elbowW = 0.3,
			palm = out,
		}, {
			hand = head * V(-h.X * 0.45, h.Y * 0.25, -(h.Z * 0.5 + 0.75)),
			elbow = head * V(-h.X * 0.85, -h.Y * 0.7, -(h.Z * 0.5 + 0.6)),
			elbowW = 0.3,
			palm = out,
		}
	end,
}

local function mirrorSeed(s: Vector3): Vector3
	return V(s.X, -s.Y, -s.Z)
end

--- Arm angles for every contact, solved on this rig (after armsIn, if used).
function NGMIFit.solve(rig: RigPose.Rig): Fit
	local model = rig.model
	local d = {
		head = size(model, "Head"),
		torso = size(model, "UpperTorso"),
		hand = size(model, "RightHand"),
		arm = size(model, "RightUpperArm"),
	}
	local fit: Fit = {}
	for name, c in CONTACTS do
		local f = SeatPosture.frames(rig, c.body)
		local t = f.UpperTorso
		if not (t and f.Head) then
			continue
		end
		local right, left = c.goals(f, d)
		local pose: Pose = {}
		pose.rS, pose.rE, pose.rW = SeatPosture.reach(rig, "r", t, right, c.seedS, c.seedE)
		pose.lS, pose.lE, pose.lW =
			SeatPosture.reach(rig, "l", t, left, c.seedSL or mirrorSeed(c.seedS), c.seedEL or c.seedE)
		fit[name] = pose
	end
	return fit
end

--- Arms in, then the contacts. What every NGMI performer runs once.
function NGMIFit.prepare(rig: RigPose.Rig): Fit
	NGMIFit.armsIn(rig)
	return NGMIFit.solve(rig)
end

--- The arms of a contact (or `fallback` when the rig has no fit for it).
function NGMIFit.arms(fit: Fit?, name: string, fallback: Pose): Pose
	return (fit and fit[name]) or fallback
end

return NGMIFit
