--!strict
--------------------------------------------------------------------------------
-- VFX/Shake.luau
-- Procedural 3D Perlin-noise camera shake for VFXManager. Trauma is 0..1 and
-- the applied magnitude is trauma^2, so small knocks stay subtle while a
-- jumpscare genuinely throws the camera.
--------------------------------------------------------------------------------

local RunService = game:GetService("RunService")

local camera = workspace.CurrentCamera

local SHAKE_DECAY = 1.1 -- trauma lost per second
local SHAKE_FREQUENCY = 14 -- noise samples per second
local SHAKE_MAX_TRANSLATION = 0.6 -- studs at full trauma
local SHAKE_MAX_ROTATION = 4 -- degrees at full trauma
local SHAKE_RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 10

-- Independent Perlin channels. Sampling one noise field at well-separated
-- offsets gives uncorrelated motion per axis without three separate fields.
local NOISE_SEED_X = 0
local NOISE_SEED_Y = 137.13
local NOISE_SEED_PITCH = 291.7
local NOISE_SEED_YAW = 419.31
local NOISE_SEED_ROLL = 613.57

local Shake = {}

local trauma = 0
local noiseTime = 0
local bound = false

--- Sample Roblox's Perlin field and normalise to roughly -1..1.
local function sampleNoise(seed: number): number
	return math.noise(noiseTime, seed, 0) * 2
end

--- Per-frame shake. Applied as a RELATIVE multiply onto the camera CFrame so it
--- composes with CameraController's sway and head-bob instead of overwriting
--- them. Bound after Camera priority so it lands on the finished camera pose.
local function update(deltaTime: number)
	trauma = math.max(0, trauma - SHAKE_DECAY * deltaTime)

	if trauma <= 0 then
		-- Unbind while idle: a permanently bound render step costs every frame
		-- for nothing.
		if bound then
			RunService:UnbindFromRenderStep("VFXCameraShake")
			bound = false
		end
		return
	end

	noiseTime += deltaTime * SHAKE_FREQUENCY

	-- Quadratic falloff: gentle knocks stay gentle, jumpscares hit hard.
	local magnitude = trauma * trauma

	local offsetX = sampleNoise(NOISE_SEED_X) * magnitude * SHAKE_MAX_TRANSLATION
	local offsetY = sampleNoise(NOISE_SEED_Y) * magnitude * SHAKE_MAX_TRANSLATION
	local pitch = sampleNoise(NOISE_SEED_PITCH) * magnitude * SHAKE_MAX_ROTATION
	local yaw = sampleNoise(NOISE_SEED_YAW) * magnitude * SHAKE_MAX_ROTATION
	local roll = sampleNoise(NOISE_SEED_ROLL) * magnitude * SHAKE_MAX_ROTATION

	camera.CFrame = camera.CFrame
		* CFrame.new(offsetX, offsetY, 0)
		* CFrame.Angles(math.rad(pitch), math.rad(yaw), math.rad(roll))
end

--- Add trauma. Additive and clamped, so overlapping events build up to a cap
--- rather than the loudest one winning outright.
function Shake.add(amount: number)
	trauma = math.clamp(trauma + amount, 0, 1)

	if trauma > 0 and not bound then
		bound = true
		RunService:BindToRenderStep("VFXCameraShake", SHAKE_RENDER_PRIORITY, update)
	end
end

function Shake.get(): number
	return trauma
end

return Shake
