--!strict
--------------------------------------------------------------------------------
-- LightingController.client.luau
-- Drives all dynamic lighting, post-processing, and visual effects per phase.
--
-- Design notes:
--   • Tweens ALL Lighting properties to match LightingProfiles on phase change
--   • Creates/manages ColorCorrectionEffect, BloomEffect, BlurEffect
--   • Screen glitch effects (corruption + Night2): random saturation/blur/tint flashes
--   • Emergency strobe lights via CollectionService tags during Night2
--   • Ceiling lights toggled off, red emergency lights toggled on for Night2
--------------------------------------------------------------------------------

local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Shared lighting presets
local LightingProfiles = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LightingProfiles"))

-- Remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local GameStateChanged = Remotes:WaitForChild("GameStateChanged") :: RemoteEvent
local CorruptionStarted = Remotes:WaitForChild("CorruptionStarted") :: RemoteEvent

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

-- CollectionService tags for lights in the map
local TAG_CEILING_LIGHT = "CeilingLight"
local TAG_EMERGENCY_LIGHT = "EmergencyLight"

-- Glitch effect timing
local GLITCH_MIN_INTERVAL = 5
local GLITCH_MAX_INTERVAL = 20

-- Strobe timing (Night2 emergency lights)
local STROBE_MIN_INTERVAL = 0.5
local STROBE_MAX_INTERVAL = 2.0

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local currentPhase: number = 0 -- LOBBY
local glitchEnabled: boolean = false
local strobeEnabled: boolean = false
local activeTweens: { Tween } = {}

-- Post-processing effect instances (created once, reused)
local colorCorrection: ColorCorrectionEffect = nil :: any
local bloomEffect: BloomEffect = nil :: any
local blurEffect: BlurEffect = nil :: any

--------------------------------------------------------------------------------
-- Post-processing effect setup
-- Creates the effect instances under Lighting if they don't already exist.
--------------------------------------------------------------------------------

local function ensurePostProcessing()
	-- ColorCorrectionEffect
	local existing_cc = Lighting:FindFirstChildOfClass("ColorCorrectionEffect")
	if existing_cc then
		colorCorrection = existing_cc
	else
		colorCorrection = Instance.new("ColorCorrectionEffect")
		colorCorrection.Name = "GameColorCorrection"
		colorCorrection.Parent = Lighting
	end

	-- BloomEffect
	local existing_bloom = Lighting:FindFirstChildOfClass("BloomEffect")
	if existing_bloom then
		bloomEffect = existing_bloom
	else
		bloomEffect = Instance.new("BloomEffect")
		bloomEffect.Name = "GameBloom"
		bloomEffect.Parent = Lighting
	end

	-- BlurEffect
	local existing_blur = Lighting:FindFirstChildOfClass("BlurEffect")
	if existing_blur then
		blurEffect = existing_blur
	else
		blurEffect = Instance.new("BlurEffect")
		blurEffect.Name = "GameBlur"
		blurEffect.Parent = Lighting
	end
end

--------------------------------------------------------------------------------
-- Tween Helpers
--------------------------------------------------------------------------------

--- Cancel all currently running lighting tweens so they don't fight new ones.
local function cancelActiveTweens()
	for _, tween in activeTweens do
		tween:Cancel()
	end
	table.clear(activeTweens)
end

--- Tween Lighting service properties to match a profile.
local function tweenLightingProperties(profile: any, duration: number)
	local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

	local lightingTween = TweenService:Create(Lighting, tweenInfo, {
		Ambient = profile.Ambient,
		Brightness = profile.Brightness,
		ClockTime = profile.ClockTime,
		ColorShift_Bottom = profile.ColorShift_Bottom,
		ColorShift_Top = profile.ColorShift_Top,
		FogColor = profile.FogColor,
		FogEnd = profile.FogEnd,
		FogStart = profile.FogStart,
		OutdoorAmbient = profile.OutdoorAmbient,
	})
	lightingTween:Play()
	table.insert(activeTweens, lightingTween)

	return lightingTween
end

--- Tween post-processing effects to match a profile's PostProcessing table.
local function tweenPostProcessing(pp: any, duration: number)
	local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)

	-- ColorCorrection
	local cc = pp.ColorCorrection
	local ccTween = TweenService:Create(colorCorrection, tweenInfo, {
		Brightness = cc.Brightness,
		Contrast = cc.Contrast,
		Saturation = cc.Saturation,
		TintColor = cc.TintColor,
	})
	ccTween:Play()
	table.insert(activeTweens, ccTween)

	-- Bloom
	local bloom = pp.Bloom
	local bloomTween = TweenService:Create(bloomEffect, tweenInfo, {
		Intensity = bloom.Intensity,
		Size = bloom.Size,
		Threshold = bloom.Threshold,
	})
	bloomTween:Play()
	table.insert(activeTweens, bloomTween)

	-- Blur
	local blurTween = TweenService:Create(blurEffect, tweenInfo, {
		Size = pp.BlurSize or 0,
	})
	blurTween:Play()
	table.insert(activeTweens, blurTween)
end

--- Apply a full lighting profile with the given tween duration.
local function applyProfile(profileName: string, duration: number)
	local profile = LightingProfiles.getProfile(profileName)
	if not profile then
		warn("[LightingController] Unknown profile:", profileName)
		return
	end

	cancelActiveTweens()
	tweenLightingProperties(profile, duration)
	tweenPostProcessing(profile.PostProcessing, duration)
end

--------------------------------------------------------------------------------
-- Screen Glitch Effect
-- During corruption and Night2, randomly flash visual distortion.
--------------------------------------------------------------------------------

local function runGlitchLoop()
	glitchEnabled = true

	task.spawn(function()
		while glitchEnabled do
			-- Wait a random interval before the next glitch
			local interval = math.random() * (GLITCH_MAX_INTERVAL - GLITCH_MIN_INTERVAL) + GLITCH_MIN_INTERVAL
			task.wait(interval)

			if not glitchEnabled then
				break
			end

			-- Randomly pick which glitch effect(s) to apply
			local glitchType = math.random(1, 3)

			if glitchType == 1 then
				-- Flash saturation to -1 (full desaturation)
				local origSat = colorCorrection.Saturation
				colorCorrection.Saturation = -1
				task.wait(0.1)
				if glitchEnabled then
					colorCorrection.Saturation = origSat
				end

			elseif glitchType == 2 then
				-- Brief blur spike
				local origBlur = blurEffect.Size
				blurEffect.Size = 10
				task.wait(0.15)
				if glitchEnabled then
					blurEffect.Size = origBlur
				end

			elseif glitchType == 3 then
				-- Red tint flash
				local origTint = colorCorrection.TintColor
				colorCorrection.TintColor = Color3.fromRGB(255, 0, 0)
				task.wait(0.05)
				if glitchEnabled then
					colorCorrection.TintColor = origTint
				end
			end
		end
	end)
end

local function stopGlitchLoop()
	glitchEnabled = false
end

--------------------------------------------------------------------------------
-- Emergency Strobe Lights (Night2)
-- Cycles red PointLights on/off at random intervals for that horror flicker.
--------------------------------------------------------------------------------

local function runStrobeLoop()
	strobeEnabled = true

	task.spawn(function()
		while strobeEnabled do
			local interval = math.random() * (STROBE_MAX_INTERVAL - STROBE_MIN_INTERVAL) + STROBE_MIN_INTERVAL
			task.wait(interval)

			if not strobeEnabled then
				break
			end

			-- Toggle all emergency lights
			local emergencyLights = CollectionService:GetTagged(TAG_EMERGENCY_LIGHT)
			for _, lightInstance in emergencyLights do
				local pointLight = lightInstance:FindFirstChildOfClass("PointLight")
					or lightInstance:FindFirstChildOfClass("SpotLight")
				if pointLight then
					pointLight.Enabled = not pointLight.Enabled
				end
			end
		end
	end)
end

local function stopStrobeLoop()
	strobeEnabled = false
end

--------------------------------------------------------------------------------
-- Light Toggle Helpers
-- Uses CollectionService tags to find ceiling and emergency light fixtures.
--------------------------------------------------------------------------------

--- Disable all ceiling lights (normal overhead lights).
local function disableCeilingLights()
	local ceilingLights = CollectionService:GetTagged(TAG_CEILING_LIGHT)
	for _, lightInstance in ceilingLights do
		-- Disable all light sources inside the fixture
		for _, child in lightInstance:GetDescendants() do
			if child:IsA("PointLight") or child:IsA("SpotLight") or child:IsA("SurfaceLight") then
				child.Enabled = false
			end
		end
		-- Also dim any neon parts
		if lightInstance:IsA("BasePart") and lightInstance.Material == Enum.Material.Neon then
			lightInstance.Material = Enum.Material.SmoothPlastic
		end
	end
end

--- Enable all ceiling lights (restore normal lighting).
local function enableCeilingLights()
	local ceilingLights = CollectionService:GetTagged(TAG_CEILING_LIGHT)
	for _, lightInstance in ceilingLights do
		for _, child in lightInstance:GetDescendants() do
			if child:IsA("PointLight") or child:IsA("SpotLight") or child:IsA("SurfaceLight") then
				child.Enabled = true
			end
		end
		if lightInstance:IsA("BasePart") then
			-- Restore neon material for glowing fixtures
			lightInstance.Material = Enum.Material.Neon
		end
	end
end

--- Enable emergency red lights.
local function enableEmergencyLights()
	local emergencyLights = CollectionService:GetTagged(TAG_EMERGENCY_LIGHT)
	for _, lightInstance in emergencyLights do
		for _, child in lightInstance:GetDescendants() do
			if child:IsA("PointLight") or child:IsA("SpotLight") then
				child.Enabled = true
				child.Color = Color3.fromRGB(255, 30, 30) -- Deep red
			end
		end
	end
end

--- Disable emergency lights.
local function disableEmergencyLights()
	local emergencyLights = CollectionService:GetTagged(TAG_EMERGENCY_LIGHT)
	for _, lightInstance in emergencyLights do
		for _, child in lightInstance:GetDescendants() do
			if child:IsA("PointLight") or child:IsA("SpotLight") then
				child.Enabled = false
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Phase Transition Handler
--------------------------------------------------------------------------------

local function onPhaseChanged(phase: number)
	local previousPhase = currentPhase
	currentPhase = phase

	-- Stop effects from previous phase
	stopGlitchLoop()
	stopStrobeLoop()

	if phase == 1 then -- DAY1
		-- Bright optimistic morning — instant apply (no need to tween from lobby)
		applyProfile("Day1_Bright", 0.5)
		enableCeilingLights()
		disableEmergencyLights()

	elseif phase == 2 then -- DAY2
		-- Normal afternoon light — smooth 3-second tween
		applyProfile("Day2_Normal", 3)
		enableCeilingLights()
		disableEmergencyLights()

	elseif phase == 3 then -- NIGHT2
		-- Horror mode — harsh 1-second cut to near-darkness
		applyProfile("Night2_Horror", 1)

		-- Kill overhead lights, activate emergency red strobes
		disableCeilingLights()
		enableEmergencyLights()

		-- Start visual effects
		runGlitchLoop()
		runStrobeLoop()

	elseif phase == 4 then -- DAY3
		-- Dawn — beautiful 5-second sunrise tween (relief after the horror)
		applyProfile("Day3_Dawn", 5)

		-- Restore normal lights
		enableCeilingLights()
		disableEmergencyLights()

	elseif phase == 0 then -- LOBBY
		-- Reset to Day1 defaults for lobby
		applyProfile("Day1_Bright", 1)
		enableCeilingLights()
		disableEmergencyLights()
	end
end

--------------------------------------------------------------------------------
-- Corruption Handler
-- Mid-Day2 event: slow 30-second creep toward sickly green lighting.
--------------------------------------------------------------------------------

local function onCorruptionStarted()
	if currentPhase ~= 2 then -- only during DAY2
		return
	end

	-- 30-second gradual shift to the corruption profile
	applyProfile("Day2_Corruption", 30)

	-- Start glitch effects during corruption
	runGlitchLoop()
end

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

-- Create post-processing effects
ensurePostProcessing()

-- Apply initial lobby/Day1 lighting
applyProfile("Day1_Bright", 0)

-- Wire up remote events
GameStateChanged.OnClientEvent:Connect(function(data: any)
	local phase: number = 0

	if type(data) == "table" then
		phase = data.phase or 0
	elseif type(data) == "number" then
		phase = data
	end

	onPhaseChanged(phase)
end)

CorruptionStarted.OnClientEvent:Connect(function()
	onCorruptionStarted()
end)

print("[LightingController] Initialized — post-processing effects created")
