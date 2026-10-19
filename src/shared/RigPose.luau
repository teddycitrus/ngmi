--!strict
--------------------------------------------------------------------------------
-- RigPose.luau
-- Procedural posing for R15 rigs through their Motor6D C0s. Shared by every
-- scripted performance: the opening speaker and crowd, the night transition
-- cast, and the gameplay NGMIs.
--
-- A Pose is a table of joint key -> Vector3 of Euler angles in DEGREES
-- (X pitch, Y yaw, Z roll), applied on top of each joint's captured base C0.
-- The special key "rootPos" is a translation in studs on the Root joint, used
-- for hip drops, bobs and lunges.
--
-- Authoring conventions (what a Pose means):
--   waist  X+ leans forward,   Y+ twists left,  Z+ bends left
--   neck   X+ nods down,       Y+ turns left,   Z+ tilts left
--   rS/lS  X+ raises the arm forward; rS Z+ / lS Z- swings it out sideways
--   rE/lE  X- flexes the elbow
--   rH/lH  X- swings the thigh forward
--   rK/lK  X+ bends the knee
--
-- On a real R15 rig a +X rotation swings a hanging limb forward but tips an
-- upright segment BACK, so the raw axis is the opposite of the above for the
-- spine, elbows and legs (measured on a CreateHumanoidModelFromDescription
-- rig: Waist +30 tips the torso back, RightElbow -90 hyperextends). FLIP_X
-- converts, so every pose can be written the intuitive way.
--
-- Two kinds of joint are driven. Classic rigs (and the legacy block NGMI)
-- use Motor6Ds, posed through C0. Rigs from CreateHumanoidModelFromDescription
-- have NO Motor6Ds: each joint is a kinematic AnimationConstraint between two
-- RigAttachments, posed here by rotating its parent-side attachment, which is
-- the exact counterpart of C0 (measured: same hand positions either way).
-- Either edit made on a client never replicates, so client-side posing is free.
--------------------------------------------------------------------------------

local RigPose = {}

export type Pose = { [string]: Vector3 }
export type Key = { t: number, pose: Pose, ease: string? }
export type Clip = { length: number, loop: boolean?, keys: { Key } }

export type Rig = {
	model: Model,
	root: BasePart?,
	J: { [string]: Instance }, -- a Motor6D, or an AnimationConstraint's Attachment0
	base: { [string]: CFrame },
	far: { [string]: CFrame }, -- C1 / Attachment1.CFrame, for joint maths
	cur: Pose,
	apply: (self: Rig, pose: Pose, dt: number?, sharpness: number?) -> (),
	write: (self: Rig, pose: Pose) -> (),
	rebase: (self: Rig, pose: Pose) -> (),
	reset: (self: Rig) -> (),
	seatOffset: (self: Rig) -> number,
}

-- key -> { part that owns the motor, motor name }
RigPose.JOINTS = {
	root = { "LowerTorso", "Root" },
	waist = { "UpperTorso", "Waist" },
	neck = { "Head", "Neck" },
	rS = { "RightUpperArm", "RightShoulder" },
	lS = { "LeftUpperArm", "LeftShoulder" },
	rE = { "RightLowerArm", "RightElbow" },
	lE = { "LeftLowerArm", "LeftElbow" },
	rW = { "RightHand", "RightWrist" },
	lW = { "LeftHand", "LeftWrist" },
	rH = { "RightUpperLeg", "RightHip" },
	lH = { "LeftUpperLeg", "LeftHip" },
	rK = { "RightLowerLeg", "RightKnee" },
	lK = { "LeftLowerLeg", "LeftKnee" },
	rA = { "RightFoot", "RightAnkle" },
	lA = { "LeftFoot", "LeftAnkle" },
}

-- For a rig that has neither kind of joint for a slot (a stripped clone), a
-- Motor6D can be built from the RigAttachments.
local JOINT_DEFS = {
	{ "Root", "HumanoidRootPart", "LowerTorso", "RootRigAttachment" },
	{ "Waist", "LowerTorso", "UpperTorso", "WaistRigAttachment" },
	{ "Neck", "UpperTorso", "Head", "NeckRigAttachment" },
	{ "RightShoulder", "UpperTorso", "RightUpperArm", "RightShoulderRigAttachment" },
	{ "RightElbow", "RightUpperArm", "RightLowerArm", "RightElbowRigAttachment" },
	{ "RightWrist", "RightLowerArm", "RightHand", "RightWristRigAttachment" },
	{ "LeftShoulder", "UpperTorso", "LeftUpperArm", "LeftShoulderRigAttachment" },
	{ "LeftElbow", "LeftUpperArm", "LeftLowerArm", "LeftElbowRigAttachment" },
	{ "LeftWrist", "LeftLowerArm", "LeftHand", "LeftWristRigAttachment" },
	{ "RightHip", "LowerTorso", "RightUpperLeg", "RightHipRigAttachment" },
	{ "RightKnee", "RightUpperLeg", "RightLowerLeg", "RightKneeRigAttachment" },
	{ "RightAnkle", "RightLowerLeg", "RightFoot", "RightAnkleRigAttachment" },
	{ "LeftHip", "LowerTorso", "LeftUpperLeg", "LeftHipRigAttachment" },
	{ "LeftKnee", "LeftUpperLeg", "LeftLowerLeg", "LeftKneeRigAttachment" },
	{ "LeftAnkle", "LeftLowerLeg", "LeftFoot", "LeftAnkleRigAttachment" },
}

local ZERO = Vector3.zero

--- Build a Motor6D for any R15 joint that has neither a Motor6D nor an
--- AnimationConstraint.
function RigPose.ensureMotors(model: Model)
	for _, j in JOINT_DEFS do
		local p0 = model:FindFirstChild(j[2])
		local p1 = model:FindFirstChild(j[3])
		if not (p0 and p1 and p0:IsA("BasePart") and p1:IsA("BasePart")) then
			continue
		end
		local existing = p1:FindFirstChild(j[1])
		if existing and (existing:IsA("Motor6D") or existing:IsA("AnimationConstraint")) then
			continue
		end
		local a0 = p0:FindFirstChild(j[4])
		local a1 = p1:FindFirstChild(j[4])
		if a0 and a1 and a0:IsA("Attachment") and a1:IsA("Attachment") then
			local m = Instance.new("Motor6D")
			m.Name = j[1]
			m.Part0 = p0
			m.Part1 = p1
			m.C0 = a0.CFrame
			m.C1 = a1.CFrame
			m.Parent = p1
		end
	end
end

--- The poseable handle for a joint, its base CFrame and its far-side CFrame.
--- A Motor6D wins when both kinds share the name.
local function jointIn(model: Model, partName: string, jointName: string): (Instance?, CFrame?, CFrame?)
	local part = model:FindFirstChild(partName)
	if not part then
		return nil, nil, nil
	end
	local constraint: AnimationConstraint? = nil
	for _, c in part:GetChildren() do
		if c.Name == jointName then
			if c:IsA("Motor6D") then
				return c, c.C0, c.C1
			elseif c:IsA("AnimationConstraint") then
				constraint = c
			end
		end
	end
	if constraint and constraint.Attachment0 and constraint.Attachment1 then
		local a0 = constraint.Attachment0 :: Attachment
		return a0, a0.CFrame, (constraint.Attachment1 :: Attachment).CFrame
	end
	return nil, nil, nil
end

local FLIP_X: { [string]: boolean } = {
	root = true,
	waist = true,
	neck = true,
	rE = true,
	lE = true,
	rH = true,
	lH = true,
	rK = true,
	lK = true,
	rA = true,
	lA = true,
}

function RigPose.angles(v: Vector3): CFrame
	return CFrame.Angles(math.rad(v.X), math.rad(v.Y), math.rad(v.Z))
end

--- Joint-space rotation for an authored Euler on `key`.
function RigPose.jointAngles(key: string, v: Vector3): CFrame
	local x = if FLIP_X[key] then -v.X else v.X
	return CFrame.Angles(math.rad(x), math.rad(v.Y), math.rad(v.Z))
end

local function offsetFor(key: string, v: Vector3, pos: Vector3?): CFrame
	local cf = RigPose.jointAngles(key, v)
	if key == "root" and pos then
		return CFrame.new(pos) * cf
	end
	return cf
end

local function writeJoint(rig: Rig, key: string, v: Vector3, pos: Vector3?)
	local j = rig.J[key]
	if not (j and j.Parent) then
		return
	end
	local cf = rig.base[key] * offsetFor(key, v, pos)
	if j:IsA("Motor6D") then
		j.C0 = cf
	elseif j:IsA("Attachment") then
		j.CFrame = cf
	end
end

--- Wrap a model in a poser. Captures every joint's current pose as its base.
function RigPose.new(model: Model): Rig
	local rig = {
		model = model,
		root = model:FindFirstChild("HumanoidRootPart") :: BasePart?,
		J = {},
		base = {},
		far = {},
		cur = {},
	} :: any
	for key, names in RigPose.JOINTS do
		local j, base, far = jointIn(model, names[1], names[2])
		if j and base and far then
			rig.J[key] = j
			rig.base[key] = base
			rig.far[key] = far
		end
	end

	--- Ease every joint toward `pose`. Joints the pose leaves out relax back to
	--- base. `sharpness` is an exponential rate (higher = snappier); nil or a
	--- nil dt writes the pose exactly.
	function rig.apply(self: Rig, pose: Pose, dt: number?, sharpness: number?)
		local k = 1
		if dt and sharpness then
			k = 1 - math.exp(-sharpness * dt)
		end
		for key in self.J do
			local target = pose[key] or ZERO
			local now = self.cur[key] or ZERO
			local v = now:Lerp(target, k)
			self.cur[key] = v
		end
		local targetPos = pose.rootPos or ZERO
		local nowPos = self.cur.rootPos or ZERO
		self.cur.rootPos = nowPos:Lerp(targetPos, k)
		for key, v in self.cur do
			if key ~= "rootPos" then
				writeJoint(self, key, v, self.cur.rootPos)
			end
		end
	end

	function rig.write(self: Rig, pose: Pose)
		self:apply(pose)
	end

	--- Fold a pose permanently into the base, so later poses layer over it.
	function rig.rebase(self: Rig, pose: Pose)
		for key, v in pose do
			if self.base[key] and key ~= "rootPos" then
				self.base[key] = self.base[key] * RigPose.jointAngles(key, v)
			end
		end
		self:apply(self.cur)
	end

	function rig.reset(self: Rig)
		self.cur = {}
		self:apply({})
	end

	--- Distance from the root down to the underside of the thighs when seated
	--- (hips at -90), solved from the joint offsets rather than read back from
	--- part positions, which lag a step behind a C0 change.
	function rig.seatOffset(self: Rig): number
		local leg = self.model:FindFirstChild("RightUpperLeg")
		if not (self.base.root and self.base.rH and leg and leg:IsA("BasePart")) then
			return 1.5
		end
		local lower = self.base.root * self.far.root:Inverse()
		local hipPos = (lower * self.base.rH).Position
		return -hipPos.Y + leg.Size.Z * 0.5
	end

	return rig :: Rig
end

--------------------------------------------------------------------------------
-- Pose maths
--------------------------------------------------------------------------------

local function ease(kind: string?, u: number): number
	if kind == "linear" then
		return u
	elseif kind == "snap" then
		return 1 - (1 - u) ^ 4
	elseif kind == "hold" then
		return 0
	elseif kind == "in" then
		return u * u * u
	end
	return u * u * (3 - 2 * u) -- smoothstep
end

--- Sum of poses, each optionally weighted: add(a, b, 0.5) = a + b * 0.5.
function RigPose.add(a: Pose, b: Pose, w: number?): Pose
	local out: Pose = table.clone(a)
	local k = w or 1
	for key, v in b do
		out[key] = (out[key] or ZERO) + v * k
	end
	return out
end

--- Linear blend from a to b.
function RigPose.blend(a: Pose, b: Pose, w: number): Pose
	local out: Pose = {}
	for key, v in a do
		out[key] = v:Lerp(b[key] or ZERO, w)
	end
	for key, v in b do
		if not a[key] then
			out[key] = v * w
		end
	end
	return out
end

function RigPose.scale(a: Pose, w: number): Pose
	local out: Pose = {}
	for key, v in a do
		out[key] = v * w
	end
	return out
end

--- Sample a keyframed clip at time t. Each key's ease shapes the move INTO it.
function RigPose.sample(clip: Clip, t: number): Pose
	local keys = clip.keys
	if clip.loop then
		t = t % clip.length
	else
		t = math.clamp(t, 0, clip.length)
	end
	if t <= keys[1].t then
		return keys[1].pose
	end
	for i = 2, #keys do
		local b = keys[i]
		if t <= b.t then
			local a = keys[i - 1]
			local u = (t - a.t) / math.max(b.t - a.t, 1e-4)
			return RigPose.blend(a.pose, b.pose, ease(b.ease, u))
		end
	end
	return keys[#keys].pose
end

--- Deterministic smooth noise in [-1, 1].
function RigPose.noise(seed: number, channel: number, t: number): number
	return math.clamp(math.noise(t, seed, channel) * 2, -1, 1)
end

return RigPose
