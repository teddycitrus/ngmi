--!strict
--------------------------------------------------------------------------------
-- Rig/Articulation.luau
-- The corruption mutation pose for RigFactory rigs (re-exported as
-- RigFactory.articulate, resetArticulation and rampArticulation).
--------------------------------------------------------------------------------

local Articulation = {}

--------------------------------------------------------------------------------
-- Joint helpers
--------------------------------------------------------------------------------

-- R15 parents each Motor6D under the CHILD part it drives, so the elbow motor
-- lives in RightLowerArm, not RightUpperArm. Modern rigs may also carry an
-- AnimationConstraint sharing the joint's name, so match the class explicitly.
local function motorIn(model: Model, partName: string, motorName: string): Motor6D?
	local part = model:FindFirstChild(partName)
	if not part then
		return nil
	end
	local motor = part:FindFirstChild(motorName)
	if motor and motor:IsA("Motor6D") then
		return motor :: Motor6D
	end
	return nil
end

--------------------------------------------------------------------------------
-- Corruption articulation
--------------------------------------------------------------------------------
-- The mutation pose, driven by one 0..1 dial so it can be ramped over the
-- corruption window or snapped to a value for a cutscene frame.
--
-- This is Motor6D articulation, NOT skinned-mesh deformation: rigs built by
-- CreateHumanoidModelFromDescription are jointed MeshParts with no bones, so
-- there is nothing to deform. Real deformation would need a skinned rig with a
-- bone hierarchy authored in Blender and uploaded. Articulating the elbows,
-- shoulders and neck is what actually sells the NGMI silhouette here.
--------------------------------------------------------------------------------

local ARTICULATION_JOINTS = {
	{ part = "RightLowerArm", motor = "RightElbow" },
	{ part = "LeftLowerArm", motor = "LeftElbow" },
	{ part = "RightUpperArm", motor = "RightShoulder" },
	{ part = "LeftUpperArm", motor = "LeftShoulder" },
	{ part = "Head", motor = "Neck" },
	{ part = "UpperTorso", motor = "Waist" },
}

-- Base C0s, captured the first time a rig is articulated so the pose can be
-- rolled back exactly. Weak keys: an entry disappears when its rig is collected.
local baseC0: { [Model]: { [string]: CFrame } } = setmetatable({}, { __mode = "k" }) :: any

--- Pose a rig along the human → NGMI axis. `amount` is 0 (untouched) to 1 (full
--- mutation): elbows crank up and inward, shoulders roll forward, the neck cocks
--- and the waist hunches.
function Articulation.articulate(model: Model, amount: number)
	local t = math.clamp(amount, 0, 1)

	local cached = baseC0[model]
	if not cached then
		cached = {}
		baseC0[model] = cached
	end

	for _, joint in ARTICULATION_JOINTS do
		local motor = motorIn(model, joint.part, joint.motor)
		if motor then
			local base = cached[joint.motor]
			if not base then
				base = motor.C0
				cached[joint.motor] = base
			end

			local offset: CFrame
			if joint.motor == "RightElbow" then
				offset = CFrame.Angles(math.rad(-75 * t), 0, math.rad(-20 * t))
			elseif joint.motor == "LeftElbow" then
				offset = CFrame.Angles(math.rad(-75 * t), 0, math.rad(20 * t))
			elseif joint.motor == "RightShoulder" then
				offset = CFrame.Angles(math.rad(25 * t), 0, math.rad(18 * t))
			elseif joint.motor == "LeftShoulder" then
				offset = CFrame.Angles(math.rad(25 * t), 0, math.rad(-18 * t))
			elseif joint.motor == "Neck" then
				offset = CFrame.Angles(math.rad(22 * t), 0, math.rad(12 * t))
			else -- Waist
				offset = CFrame.Angles(math.rad(18 * t), 0, 0)
			end

			motor.C0 = base * offset
		end
	end
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
