--!strict
--------------------------------------------------------------------------------
-- LightingController.client.luau
-- Drives all dynamic lighting, atmosphere and post-processing per phase.
--
-- Phase signal
--   The server publishes phase changes on ServerStorage.ServerComm.PhaseChanged,
--   but ServerStorage is not replicated, a LocalScript can never read it. The
--   client-visible mirror of that same bus is ReplicatedStorage.CurrentPhase
--   (an IntValue GameStateManager writes in publishPhase), so that is the
--   authoritative signal here. The GameStateChanged RemoteEvent is kept wired as
--   a secondary trigger so nothing regresses if the IntValue is missing, and
--   both paths funnel through one debounced handler.
--
-- Design notes:
--   • Tweens Lighting + Atmosphere + post-processing to a LightingProfile
--   • Phase transitions run at TRANSITION_SECONDS (2.5s); the DAY2 corruption
--     creep runs at CORRUPTION_SECONDS (10s)
--   • Owns exactly three effect instances, named GameColorCorrection / GameBloom
--     / GameBlur. Other systems layer their OWN separately-named effects on top
--     (NGMIProximityCC, DamageColorCorrection, VFXGlitchCC), never reuse these.
--   • Emergency strobe + glitch loops during corruption and NIGHT2
--   • Ceiling lights off / emergency lights on for NIGHT2
--------------------------------------------------------------------------------

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

-- Shared lighting presets
local LightingProfiles = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LightingProfiles"))
local VenueLights = require(script.Parent:WaitForChild("Lighting"):WaitForChild("VenueLights"))
local Blackout = require(script.Parent:WaitForChild("Lighting"):WaitForChild("Blackout"))

-- Remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local GameStateChanged = Remotes:WaitForChild("GameStateChanged") :: RemoteEvent
local CorruptionStarted = Remotes:WaitForChild("CorruptionStarted") :: RemoteEvent

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

-- Phase ids this script branches on (full map lives in LightingProfiles.PHASE_PROFILE)
local PHASE_LOBBY = 0
local PHASE_DAY2 = 2
local PHASE_NIGHT2 = 3

-- Transition timings
local TRANSITION_SECONDS = 2.5 -- every normal phase change
local CORRUPTION_SECONDS = 10 -- the DAY2 corruption creep
local BOOT_SECONDS = 0 -- initial apply, no tween

-- Effect instance names. CutsceneManager resolves these by name, do not rename.
local NAME_COLOR_CORRECTION = "GameColorCorrection"
local NAME_BLOOM = "GameBloom"
local NAME_BLUR = "GameBlur"
local NAME_ATMOSPHERE = "GameAtmosphere"

-- Glitch effect timing
local GLITCH_MIN_INTERVAL = 5
local GLITCH_MAX_INTERVAL = 20

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local currentPhase: number = PHASE_LOBBY
local corruptionActive: boolean = false
local glitchToken: number = 0
local activeTweens: { Tween } = {}

-- Post-processing effect instances (created once, reused)
local colorCorrection: ColorCorrectionEffect
local bloomEffect: BloomEffect
local blurEffect: BlurEffect
local atmosphere: Atmosphere

--------------------------------------------------------------------------------
-- Instance setup
--------------------------------------------------------------------------------

--- Fetch a uniquely-named child of Lighting, creating it if absent.
--- Deliberately resolves by NAME, never by class: several systems park their own
--- ColorCorrectionEffect under Lighting, and a class lookup would adopt whichever
--- happened to load first and then fight it every frame.
local function ensureEffect<T>(className: string, name: string): T
	local existing = Lighting:FindFirstChild(name)
	if existing and existing:IsA(className) then
		return existing :: any
	end
	local created = Instance.new(className)
	created.Name = name
	created.Parent = Lighting
	return created :: any
end

--- Name prefixes used by every post-processing effect this codebase creates:
--- Game* (this script), VFX* (VFXManager), NGMI* (NGMIClient), Cutscene*/Sleep*
--- (CutsceneManager), Damage* (HUDController). Anything under Lighting without
--- one of these came from the place file, not from code.
local OWNED_PREFIXES = { "Game", "VFX", "NGMI", "Cutscene", "Sleep", "Damage" }

local function isOwnedEffect(name: string): boolean
	for _, prefix in OWNED_PREFIXES do
		if string.sub(name, 1, #prefix) == prefix then
			return true
		end
	end
	return false
end

--- Destroy post-processing and atmosphere instances that were saved into the
--- place by hand. They are invisible in source but stack on top of the profile
--- stack at runtime: a stray BloomEffect at Intensity 1 or a second Atmosphere
--- competing with GameAtmosphere quietly washes every profile out, and no
--- amount of tuning the numbers below can win against them. Sky is left alone
--- (MapBuilder expects one) and so is anything a script owns.
local function sweepForeignEffects()
	local removed = {}

	for _, child in Lighting:GetChildren() do
		if (child:IsA("PostEffect") or child:IsA("Atmosphere")) and not isOwnedEffect(child.Name) then
			table.insert(removed, string.format("%s (%s)", child.Name, child.ClassName))
			child:Destroy()
		end
	end

	if #removed > 0 then
		print("[LightingController] Removed place-file lighting effects: " .. table.concat(removed, ", "))
	end
end

local function ensureInstances()
	colorCorrection = ensureEffect("ColorCorrectionEffect", NAME_COLOR_CORRECTION)
	bloomEffect = ensureEffect("BloomEffect", NAME_BLOOM)
	blurEffect = ensureEffect("BlurEffect", NAME_BLUR)
	atmosphere = ensureEffect("Atmosphere", NAME_ATMOSPHERE)
end

--- Future is set in default.project.json. Lighting.Technology is neither
--- script-assignable nor script-readable at runtime (a normal LocalScript
--- reading it throws "lacking capability RobloxScript"). The read is wrapped in
--- a pcall so this sanity check can never take the controller down with it: an
--- unguarded read used to abort the script before the boot profile was applied,
--- leaving Lighting on the raw place defaults and washing the game out white.
local function assertFutureLighting()
	local ok, technology = pcall(function(): Enum.Technology
		return Lighting.Technology
	end)
	if not ok then
		return -- restricted property, nothing verifiable from a LocalScript
	end

	if technology ~= LightingProfiles.TECHNOLOGY then
		warn(
			string.format(
				"[LightingController] Lighting.Technology is %s, expected %s. "
					.. "Set it in default.project.json under Lighting.$properties, "
					.. "it cannot be assigned from a script.",
				technology.Name,
				LightingProfiles.TECHNOLOGY.Name
			)
		)
	end
end

--------------------------------------------------------------------------------
-- Tween helpers
--------------------------------------------------------------------------------

--- Cancel all currently running lighting tweens so they don't fight new ones.
local function cancelActiveTweens()
	for _, tween in activeTweens do
		tween:Cancel()
	end
	table.clear(activeTweens)
end

local function playTween(target: Instance, tweenInfo: TweenInfo, goals: { [string]: any })
	local tween = TweenService:Create(target, tweenInfo, goals)
	tween:Play()
	table.insert(activeTweens, tween)
end

--- Apply a full lighting profile over `duration` seconds.
--- A duration of 0 sets every property directly, which avoids spawning six
--- one-frame tweens during boot.
local function applyProfile(profile: LightingProfiles.LightingProfile, duration: number)
	cancelActiveTweens()

	local pp = profile.PostProcessing
	local cc = pp.ColorCorrection
	local bloom = pp.Bloom
	local atmo = profile.Atmosphere

	local lightingGoals = {
		Ambient = profile.Ambient,
		Brightness = profile.Brightness,
		ClockTime = profile.ClockTime,
		ColorShift_Bottom = profile.ColorShift_Bottom,
		ColorShift_Top = profile.ColorShift_Top,
		ExposureCompensation = profile.ExposureCompensation,
		FogColor = profile.FogColor,
		FogEnd = profile.FogEnd,
		FogStart = profile.FogStart,
		OutdoorAmbient = profile.OutdoorAmbient,
		ShadowSoftness = profile.ShadowSoftness,
		EnvironmentDiffuseScale = profile.EnvironmentDiffuseScale,
		EnvironmentSpecularScale = profile.EnvironmentSpecularScale,
	}
	local atmosphereGoals = {
		Density = atmo.Density,
		Offset = atmo.Offset,
		Color = atmo.Color,
		Decay = atmo.Decay,
		Glare = atmo.Glare,
		Haze = atmo.Haze,
	}
	local colorCorrectionGoals = {
		Brightness = cc.Brightness,
		Contrast = cc.Contrast,
		Saturation = cc.Saturation,
		TintColor = cc.TintColor,
	}
	local bloomGoals = {
		Intensity = bloom.Intensity,
		Size = bloom.Size,
		Threshold = bloom.Threshold,
	}

	if duration <= 0 then
		for property, value in lightingGoals do
			(Lighting :: any)[property] = value
		end
		for property, value in atmosphereGoals do
			(atmosphere :: any)[property] = value
		end
		for property, value in colorCorrectionGoals do
			(colorCorrection :: any)[property] = value
		end
		for property, value in bloomGoals do
			(bloomEffect :: any)[property] = value
		end
		blurEffect.Size = pp.BlurSize
		return
	end

	local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
	playTween(Lighting, tweenInfo, lightingGoals)
	playTween(atmosphere, tweenInfo, atmosphereGoals)
	playTween(colorCorrection, tweenInfo, colorCorrectionGoals)
	playTween(bloomEffect, tweenInfo, bloomGoals)
	playTween(blurEffect, tweenInfo, { Size = pp.BlurSize })
end

--- Apply the profile bound to a phase id.
local function applyPhaseProfile(phase: number, duration: number)
	applyProfile(LightingProfiles.getProfileForPhase(phase), duration)
end

--------------------------------------------------------------------------------
-- Screen glitch effect
-- During corruption and NIGHT2, randomly flash visual distortion.
-- Token-guarded: bumping the token retires any in-flight loop, so a fast phase
-- change (the admin phase-skip does exactly this) can't leave two loops running
-- and stomping each other's restore values.
--------------------------------------------------------------------------------

local function stopGlitchLoop()
	glitchToken += 1
end

local function runGlitchLoop()
	glitchToken += 1
	local token = glitchToken

	task.spawn(function()
		while token == glitchToken do
			local interval = math.random() * (GLITCH_MAX_INTERVAL - GLITCH_MIN_INTERVAL) + GLITCH_MIN_INTERVAL
			task.wait(interval)
			if token ~= glitchToken then
				break
			end

			local glitchType = math.random(1, 3)

			if glitchType == 1 then
				local original = colorCorrection.Saturation
				colorCorrection.Saturation = -1
				task.wait(0.1)
				if token == glitchToken then
					colorCorrection.Saturation = original
				end
			elseif glitchType == 2 then
				local original = blurEffect.Size
				blurEffect.Size = 10
				task.wait(0.15)
				if token == glitchToken then
					blurEffect.Size = original
				end
			else
				local original = colorCorrection.TintColor
				colorCorrection.TintColor = Color3.fromRGB(255, 0, 0)
				task.wait(0.05)
				if token == glitchToken then
					colorCorrection.TintColor = original
				end
			end
		end
	end)
end

--------------------------------------------------------------------------------
-- Phase transition handler
--------------------------------------------------------------------------------

local function onPhaseChanged(phase: number)
	-- Both signal paths fire for one change, so a repeat is normally a no-op.
	-- A repeat while the corruption creep is applied still resets it (an admin
	-- setPhase back to DAY2), so the creep can run again.
	if phase == currentPhase and not corruptionActive then
		return
	end
	currentPhase = phase
	corruptionActive = false

	stopGlitchLoop()
	VenueLights.stopStrobe()

	applyPhaseProfile(phase, TRANSITION_SECONDS)

	local night = phase == PHASE_NIGHT2
	VenueLights.setCeiling(not night)
	VenueLights.setEmergency(night)
	Blackout.set(night)
	if night then
		runGlitchLoop()
		VenueLights.startStrobe()
	end

	print(string.format("[LightingController] Phase %d → profile %s", phase, LightingProfiles.getProfileName(phase)))
end

--------------------------------------------------------------------------------
-- Corruption handler
-- Mid-DAY2 event: a 10-second creep into the desaturated, hazed-out profile.
--------------------------------------------------------------------------------

local function onCorruptionStarted()
	if currentPhase ~= PHASE_DAY2 or corruptionActive then
		return
	end
	corruptionActive = true

	local profile = LightingProfiles.getProfile("CORRUPTION")
	if not profile then
		warn("[LightingController] CORRUPTION profile missing")
		return
	end

	applyProfile(profile, CORRUPTION_SECONDS)
	runGlitchLoop()

	print("[LightingController] Corruption creep started (" .. CORRUPTION_SECONDS .. "s)")
end

--------------------------------------------------------------------------------
-- Initialisation
--------------------------------------------------------------------------------

sweepForeignEffects()
ensureInstances()
assertFutureLighting()

-- Boot straight into the lobby look; no tween from Studio's default lighting.
applyPhaseProfile(PHASE_LOBBY, BOOT_SECONDS)

--------------------------------------------------------------------------------
-- Phase signal wiring
--------------------------------------------------------------------------------

-- Primary: the replicated mirror of ServerComm.PhaseChanged.
task.spawn(function()
	local phaseValue = ReplicatedStorage:WaitForChild("CurrentPhase", 30)
	if not (phaseValue and phaseValue:IsA("IntValue")) then
		warn(
			"[LightingController] ReplicatedStorage.CurrentPhase unavailable, "
				.. "falling back to GameStateChanged only"
		)
		return
	end

	local intValue = phaseValue :: IntValue
	intValue.Changed:Connect(onPhaseChanged)

	-- Catch a phase that was already set before this script finished loading.
	if intValue.Value ~= currentPhase then
		onPhaseChanged(intValue.Value)
	end
end)

-- Secondary: the existing remote. Debounced against the primary by the
-- guard at the top of onPhaseChanged.
GameStateChanged.OnClientEvent:Connect(function(data: any)
	local phase: number = PHASE_LOBBY

	if type(data) == "table" then
		phase = data.phase or PHASE_LOBBY
	elseif type(data) == "number" then
		phase = data
	end

	onPhaseChanged(phase)
end)

CorruptionStarted.OnClientEvent:Connect(onCorruptionStarted)

print("[LightingController] Initialised, Future lighting, atmosphere and post-processing ready")
