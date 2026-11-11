--!strict
--------------------------------------------------------------------------------
-- Rig/Articulation.luau
-- The corruption mutation pose for RigFactory rigs (re-exported as
-- RigFactory.articulate, resetArticulation and rampArticulation).
--------------------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RigPose = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RigPose"))

local Articulation = {}

--------------------------------------------------------------------------------
-- Corruption articulation
--------------------------------------------------------------------------------
-- The mutation pose, driven by one 0..1 dial so it can be ramped over the
-- corruption window or snapped to a value for a cutscene frame.
--
-- This is joint articulation, NOT skinned-mesh deformation: rigs built by
-- CreateHumanoidModelFromDescription are jointed MeshParts with no bones, so
-- there is nothing to deform. Articulating the elbows, shoulders and neck is
-- what actually sells the NGMI silhouette here. Those rigs have no Motor6Ds
-- (AnimationConstraints instead), so the pose goes through Shared.RigPose,
-- which drives either kind of joint and layers under the playing animation.
--------------------------------------------------------------------------------

-- Full mutation in RigPose conventions: elbows crank up and inward, shoulders
-- roll forward, the neck cocks and the waist hunches.
local MUTATION: RigPose.Pose = {
	rE = Vector3.new(-75, 0, -20),
	lE = Vector3.new(-75, 0, 20),
	rS = Vector3.new(25, 0, 18),
	lS = Vector3.new(25, 0, -18),
	neck = Vector3.new(22, 0, 12),
	waist = Vector3.new(18, 0, 0),
}

-- Posers, created the first time a rig is articulated so its neutral joints
-- are captured as the base. Weak keys: an entry disappears with its rig.
local posers: { [Model]: RigPose.Rig } = setmetatable({}, { __mode = "k" }) :: any

--- Pose a rig along the human -> NGMI axis. `amount` is 0 (untouched) to 1
--- (full mutation).
function Articulation.articulate(model: Model, amount: number)
	local t = math.clamp(amount, 0, 1)
	local rig = posers[model]
	if not rig then
		if t == 0 then
			return -- never posed, already neutral
		end
		rig = RigPose.new(model)
		posers[model] = rig
	end
	rig:apply(RigPose.scale(MUTATION, t))
end

--- Restore a rig to its captured neutral pose.
function Articulation.resetArticulation(model: Model)
	Articulation.articulate(model, 0)
end

--- Ramp a rig from its current pose to full mutation over `duration` seconds,
--- with a shudder riding on top so it reads as a body losing control rather than
--- a smooth tween. Returns the thread so callers can cancel it.
function Articulation.rampArticulation(model: Model, duration: number): thread
	return task.spawn(function()
		local elapsed = 0
		while elapsed < duration and model.Parent do
			task.wait(0.05)
			elapsed += 0.05

			local progress = math.clamp(elapsed / duration, 0, 1)
			-- Convulsion: a fast tremor whose amplitude grows with progress.
			local shudder = math.sin(elapsed * 18) * 0.08 * progress
			Articulation.articulate(model, progress + shudder)
		end

		if model.Parent then
			Articulation.articulate(model, 1)
		end
	end)
end

return Articulation
