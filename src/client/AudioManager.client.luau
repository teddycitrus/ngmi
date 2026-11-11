--!strict
--------------------------------------------------------------------------------
-- AudioManager.client.luau
-- Centralised audio system handling BGM, SFX, ambient, and dynamic horror audio.
--
-- Design notes:
--   • All Sound instances are pre-created in SoundGroups for volume control
--   • BGM crossfades: fade out current over 2s, fade in new over 2s
--   • Night2 dynamic audio: heartbeat + static buzz scale with NGMI proximity
--   • The Night2 storm (rain, rumble, thunder) is StormAmbience's
--   • Public SFX functions are callable by other client scripts via BindableEvents
--------------------------------------------------------------------------------

local Players = game:GetService("Players")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

-- Remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local GameStateChanged = Remotes:WaitForChild("GameStateChanged") :: RemoteEvent
local CorruptionStarted = Remotes:WaitForChild("CorruptionStarted") :: RemoteEvent
local CutsceneTrigger = Remotes:WaitForChild("CutsceneTrigger") :: RemoteEvent
local EndingTrigger = Remotes:WaitForChild("EndingTrigger") :: RemoteEvent

local localPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Asset IDs
--------------------------------------------------------------------------------

-- All IDs below are from Roblox's OFFICIAL free/licensed audio libraries, verified
-- by MarketplaceService:GetProductInfo (creator is Roblox, APM Music, or Pro Sound
-- Effects) AND verified to load. These are safe to use in a published experience.
--   • BGM  → "APMOfficial" (APM Music — Roblox's free background-music library)
--   • most SFX → "Roblox" (first-party .wav library)
--   • heartbeat/breathing → "ProSoundEffects" (Roblox's free SFX library)
-- Roblox has no true "breathing" sound in its free libraries, so the NGMI dread
-- layer reuses ProSoundEffects' deep distant thumping. To get authentic distorted
-- breathing, upload your own audio (Roblox moderates it on upload) and drop the ID
-- into SFX_Breathing.
local ASSET_IDS = {
	-- Background music (APM Music — long licensed tracks, mood-matched)
	BGM_Day1       = "rbxassetid://1838030000", -- "Neon Lights" — synthy hackathon energy
	BGM_Day2       = "rbxassetid://1845695000", -- "Bright And Carefree" — daytime coding
	BGM_Night2     = "rbxassetid://1847725000", -- "Disturbed Mind" — dark/tense horror
	BGM_Day3       = "rbxassetid://1840515000", -- "Glory" — triumphant ending

	-- Sound effects (Roblox first-party unless noted)
	SFX_Thunder    = "rbxassetid://12222030",    -- Roblox HalloweenThunder
	SFX_Heartbeat  = "rbxassetid://9125402735",  -- ProSoundEffects deep distant thumping
	SFX_Footstep   = "rbxassetid://12221962",    -- Roblox minifig footsteps
	SFX_Spray      = "rbxassetid://12222095",    -- Roblox rocket whoosh (aerosol hiss)
	SFX_Scream     = "rbxassetid://12222242",    -- Roblox vocal "uuhhh"
	SFX_PowerDown  = "rbxassetid://11984254",    -- Roblox CinematicBoom
	SFX_StaticBuzz = "rbxassetid://12222019",    -- Roblox HalloweenLightning crackle
	SFX_Click      = "rbxassetid://12221967",    -- Roblox button.wav
	SFX_FlashlightClick = "rbxassetid://12221967", -- button.wav pitched per press; swap for a dedicated switch click
	SFX_Achievement = "rbxassetid://12222253",   -- Roblox victory.wav
	SFX_Breathing  = "rbxassetid://9125402735",  -- ProSoundEffects deep thumping (NGMI dread)
}

--------------------------------------------------------------------------------
-- Sound Group Configuration
--------------------------------------------------------------------------------

local SOUND_GROUPS = {
	Music   = { Volume = 0.4 },
	SFX     = { Volume = 0.7 },
	Ambient = { Volume = 0.5 },
	Voice   = { Volume = 0.8 },
}

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local BGM_CROSSFADE_DURATION = 2 -- seconds to fade in/out during crossfade

-- Night2 dynamic audio
local HEARTBEAT_MIN_VOLUME = 0 -- when NGMIs are far away
local HEARTBEAT_MAX_VOLUME = 1 -- when an NGMI is right on top of you
local STATIC_MIN_VOLUME = 0
local STATIC_MAX_VOLUME = 0.8
local PROXIMITY_MAX_DISTANCE = 80 -- studs; beyond this, no heartbeat/static
local PROXIMITY_MIN_DISTANCE = 5 -- studs; at this distance, max intensity

-- Heavy distorted breathing kicks in only when an NGMI is genuinely close.
local BREATHING_NEAR_DISTANCE = 26 -- studs; breathing starts fading in here
local BREATHING_MAX_VOLUME = 1.0

-- Night2 random SFX intervals
local SCREAM_MIN_INTERVAL = 60
local SCREAM_MAX_INTERVAL = 120

-- NGMI tag for CollectionService (used to find nearby NGMI entities)
local TAG_NGMI = "NGMI"

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local currentPhase: number = 0 -- LOBBY
local soundGroups: { [string]: SoundGroup } = {}
local sounds: { [string]: Sound } = {}

-- Currently playing BGM track name (or nil)
local currentBGMName: string? = nil
-- The night transition cutscene is running (set on its trigger, cleared at NIGHT2).
local nightIntroPlaying = false

-- Night2 loop control flags
local nightAudioActive: boolean = false
local screamLoopActive: boolean = false
local screamLoopGen = 0
local proximityConnection: RBXScriptConnection? = nil

-- Corruption distortion state
local corruptionDistortionActive: boolean = false
local distortionEffect: DistortionSoundEffect? = nil

--------------------------------------------------------------------------------
-- Sound Group & Sound Creation
--------------------------------------------------------------------------------

--- Create SoundGroup instances under SoundService.
local function createSoundGroups()
	for groupName, config in SOUND_GROUPS do
		local group = Instance.new("SoundGroup")
		group.Name = groupName
		group.Volume = config.Volume
		group.Parent = SoundService
		soundGroups[groupName] = group
	end
end

--- Create a Sound instance, assign it to a SoundGroup, and store it.
local function createSound(name: string, assetId: string, groupName: string, looped: boolean?): Sound
	local sound = Instance.new("Sound")
	sound.Name = name
	sound.SoundId = assetId
	sound.Looped = looped or false
	sound.Volume = 1 -- group controls master volume
	sound.SoundGroup = soundGroups[groupName]
	sound.Parent = SoundService
	sounds[name] = sound
	return sound
end

--- Initialize all sound instances.
local function createAllSounds()
	-- BGM (looped)
	createSound("BGM_Day1", ASSET_IDS.BGM_Day1, "Music", true)
	createSound("BGM_Day2", ASSET_IDS.BGM_Day2, "Music", true)
	createSound("BGM_Night2", ASSET_IDS.BGM_Night2, "Music", true)
	createSound("BGM_Day3", ASSET_IDS.BGM_Day3, "Music", true)

	-- SFX (one-shot)
	createSound("SFX_Thunder", ASSET_IDS.SFX_Thunder, "SFX", false)
	createSound("SFX_Spray", ASSET_IDS.SFX_Spray, "SFX", false)
	createSound("SFX_Scream", ASSET_IDS.SFX_Scream, "SFX", false)
	createSound("SFX_PowerDown", ASSET_IDS.SFX_PowerDown, "SFX", false)
	createSound("SFX_Click", ASSET_IDS.SFX_Click, "SFX", false)
	createSound("SFX_FlashlightClick", ASSET_IDS.SFX_FlashlightClick, "SFX", false)
	createSound("SFX_Achievement", ASSET_IDS.SFX_Achievement, "SFX", false)
	createSound("SFX_Footstep", ASSET_IDS.SFX_Footstep, "SFX", false)

	-- Ambient / looped SFX
	createSound("SFX_Heartbeat", ASSET_IDS.SFX_Heartbeat, "Ambient", true)
	createSound("SFX_StaticBuzz", ASSET_IDS.SFX_StaticBuzz, "Ambient", true)
	createSound("SFX_Breathing", ASSET_IDS.SFX_Breathing, "Ambient", true)
end

--------------------------------------------------------------------------------
-- BGM Crossfade System
-- Fades out the current track over 2s, then fades in the new one over 2s.
--------------------------------------------------------------------------------

--- Fade a sound's volume to a target over a given duration.
local function fadeVolume(sound: Sound, targetVolume: number, duration: number): Tween
	local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
	local tween = TweenService:Create(sound, tweenInfo, { Volume = targetVolume })
	tween:Play()
	return tween
end

--- Crossfade from the current BGM to a new track.
local function crossfadeBGM(newTrackName: string)
	if currentBGMName == newTrackName then
		return -- already playing this track
	end

	-- Fade out current BGM
	if currentBGMName then
		local oldSound = sounds[currentBGMName]
		if oldSound and oldSound.IsPlaying then
			local fadeTween = fadeVolume(oldSound, 0, BGM_CROSSFADE_DURATION)
			-- Stop the sound after fade completes
			local oldTrackName = currentBGMName
			task.spawn(function()
				fadeTween.Completed:Wait()
				-- Only stop if we haven't switched back to this track
				if currentBGMName ~= oldTrackName then
					oldSound:Stop()
					oldSound.Volume = 1 -- reset for next play
				end
			end)
		end
	end

	-- Fade in new BGM
	local newSound = sounds[newTrackName]
	if newSound then
		currentBGMName = newTrackName
		newSound.Volume = 0
		newSound:Play()
		fadeVolume(newSound, 1, BGM_CROSSFADE_DURATION)
	else
		warn("[AudioManager] Unknown BGM track:", newTrackName)
		currentBGMName = nil
	end
end

--- Stop all BGM tracks immediately.
local function stopAllBGM()
	for _, name in { "BGM_Day1", "BGM_Day2", "BGM_Night2", "BGM_Day3" } do
		local sound = sounds[name]
		if sound and sound.IsPlaying then
			sound:Stop()
			sound.Volume = 1
		end
	end
	currentBGMName = nil
end

--------------------------------------------------------------------------------
-- Night2 Dynamic Horror Audio
-- Heartbeat + static buzz scale with nearest NGMI distance.
-- Distant screams every 60-120s (thunder is StormAmbience).
--------------------------------------------------------------------------------

local function getPlayerPosition(): Vector3?
	local character = localPlayer.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return nil
	end
	return root.Position
end

-- Live mirror of GetTagged(TAG_NGMI), so the per-frame proximity check does
-- not allocate a fresh array every frame.
local ngmiSet: { [Instance]: true } = {}
for _, entity in CollectionService:GetTagged(TAG_NGMI) do
	ngmiSet[entity] = true
end
CollectionService:GetInstanceAddedSignal(TAG_NGMI):Connect(function(entity)
	ngmiSet[entity] = true
end)
CollectionService:GetInstanceRemovedSignal(TAG_NGMI):Connect(function(entity)
	ngmiSet[entity] = nil
end)

--- Find the nearest NGMI entity and return its distance, or nil if none found.
local function getNearestNGMIDistance(): number?
	local playerPos = getPlayerPosition()
	if not playerPos then
		return nil
	end

	local nearestDist: number? = nil

	for entity in ngmiSet do
		if entity:IsA("Model") then
			local root = entity:FindFirstChild("HumanoidRootPart") :: BasePart?
				or entity.PrimaryPart
			if root then
				local dist = (root.Position - playerPos).Magnitude
				if nearestDist == nil or dist < (nearestDist :: number) then
					nearestDist = dist
				end
			end
		end
	end

	return nearestDist
end

--- Start the proximity-based heartbeat and static buzz system.
local function startProximityAudio()
	local heartbeat = sounds["SFX_Heartbeat"]
	local staticBuzz = sounds["SFX_StaticBuzz"]

	if not heartbeat or not staticBuzz then
		return
	end

	-- Start both looping sounds at zero volume
	heartbeat.Volume = 0
	heartbeat:Play()
	staticBuzz.Volume = 0
	staticBuzz:Play()

	-- Heavy, distorted breathing that swells as an NGMI closes in.
	local breathing = sounds["SFX_Breathing"]
	if breathing then
		breathing.Volume = 0
		if not breathing:FindFirstChildOfClass("DistortionSoundEffect") then
			local distort = Instance.new("DistortionSoundEffect")
			distort.Name = "BreathDistortion"
			distort.Level = 0.45 -- "heavy/distorted" — raspy and inhuman
			distort.Parent = breathing
		end
		breathing:Play()
	end

	-- Update volumes every frame based on NGMI proximity. A second start (two
	-- NIGHT2 signals inside the 1 s delay) would otherwise orphan the old
	-- connection, which only ever wrote the same values.
	if proximityConnection then
		proximityConnection:Disconnect()
	end
	proximityConnection = RunService.Heartbeat:Connect(function(_dt: number)
		if not nightAudioActive then
			return
		end

		local dist = getNearestNGMIDistance()

		if dist == nil then
			-- No NGMIs found, keep volumes at minimum
			heartbeat.Volume = HEARTBEAT_MIN_VOLUME
			staticBuzz.Volume = STATIC_MIN_VOLUME
			if breathing then
				breathing.Volume = 0
			end
			return
		end

		-- Distorted breathing — only audible inside BREATHING_NEAR_DISTANCE, and
		-- it ramps up hard (and breathes faster) the closer the NGMI gets.
		if breathing then
			local bt = 1 - math.clamp(
				(dist - PROXIMITY_MIN_DISTANCE) / (BREATHING_NEAR_DISTANCE - PROXIMITY_MIN_DISTANCE),
				0, 1
			)
			local bIntensity = bt * bt
			breathing.Volume = BREATHING_MAX_VOLUME * bIntensity
			breathing.PlaybackSpeed = 0.85 + bIntensity * 0.45
		end

		-- Calculate intensity: 1.0 at min distance, 0.0 at max distance
		local t = 1 - math.clamp(
			(dist - PROXIMITY_MIN_DISTANCE) / (PROXIMITY_MAX_DISTANCE - PROXIMITY_MIN_DISTANCE),
			0, 1
		)

		-- Apply with easing for more dramatic ramp-up at close range
		local intensity = t * t -- quadratic for more punch when close

		heartbeat.Volume = HEARTBEAT_MIN_VOLUME + (HEARTBEAT_MAX_VOLUME - HEARTBEAT_MIN_VOLUME) * intensity
		staticBuzz.Volume = STATIC_MIN_VOLUME + (STATIC_MAX_VOLUME - STATIC_MIN_VOLUME) * intensity

		-- Also adjust heartbeat playback speed based on proximity (faster = more panic)
		heartbeat.PlaybackSpeed = 0.8 + (intensity * 0.7) -- 0.8x to 1.5x
	end)
end

--- Stop proximity audio.
local function stopProximityAudio()
	if proximityConnection then
		proximityConnection:Disconnect()
		proximityConnection = nil
	end

	local heartbeat = sounds["SFX_Heartbeat"]
	local staticBuzz = sounds["SFX_StaticBuzz"]

	if heartbeat and heartbeat.IsPlaying then
		fadeVolume(heartbeat, 0, 1)
		task.delay(1.1, function()
			heartbeat:Stop()
		end)
	end

	if staticBuzz and staticBuzz.IsPlaying then
		fadeVolume(staticBuzz, 0, 1)
		task.delay(1.1, function()
			staticBuzz:Stop()
		end)
	end

	local breathing = sounds["SFX_Breathing"]
	if breathing and breathing.IsPlaying then
		fadeVolume(breathing, 0, 1)
		task.delay(1.1, function()
			breathing:Stop()
		end)
	end
end

--- Random distant scream SFX every 60-120 seconds during Night2.
local function startScreamLoop()
	if screamLoopActive then
		return
	end
	screamLoopActive = true
	-- A stop and restart inside one wait must not leave the old loop running.
	screamLoopGen += 1
	local gen = screamLoopGen

	task.spawn(function()
		while screamLoopActive and screamLoopGen == gen do
			local interval = math.random() * (SCREAM_MAX_INTERVAL - SCREAM_MIN_INTERVAL) + SCREAM_MIN_INTERVAL
			task.wait(interval)

			if not screamLoopActive or screamLoopGen ~= gen then
				break
			end

			local scream = sounds["SFX_Scream"]
			if scream then
				-- Play at lower volume to sound distant
				scream.Volume = 0.15 + math.random() * 0.25
				scream:Play()
			end
		end
	end)
end

local function stopScreamLoop()
	screamLoopActive = false
end

--- Start all Night2 horror audio systems.
local function startNightAudio()
	nightAudioActive = true
	startProximityAudio()
	startScreamLoop()
end

--- Stop all Night2 horror audio systems.
local function stopNightAudio()
	nightAudioActive = false
	stopProximityAudio()
	stopScreamLoop()
end

--------------------------------------------------------------------------------
-- Corruption Distortion (Day2)
-- Layers a DistortionSoundEffect onto the BGM during corruption.
--------------------------------------------------------------------------------

local function applyCorruptionDistortion()
	if corruptionDistortionActive then
		return
	end
	corruptionDistortionActive = true

	local bgmSound = sounds["BGM_Day2"]
	if not bgmSound then
		return
	end

	-- Create a distortion effect and ramp it in slowly
	distortionEffect = Instance.new("DistortionSoundEffect")
	distortionEffect.Name = "CorruptionDistortion"
	distortionEffect.Level = 0 -- start clean
	distortionEffect.Parent = bgmSound

	-- Slowly increase distortion over 30 seconds to match lighting corruption
	task.spawn(function()
		local elapsed = 0
		local targetLevel = 0.4 -- subtle but noticeable
		local rampDuration = 30

		while corruptionDistortionActive and elapsed < rampDuration do
			local dt = task.wait(0.5)
			elapsed += dt

			if distortionEffect then
				distortionEffect.Level = math.clamp(
					(elapsed / rampDuration) * targetLevel,
					0, 1
				)
			end
		end
	end)
end

local function removeCorruptionDistortion()
	corruptionDistortionActive = false

	if distortionEffect then
		distortionEffect:Destroy()
		distortionEffect = nil
	end
end

--------------------------------------------------------------------------------
-- Public SFX Functions
-- Exposed via BindableEvents so other client scripts can trigger them.
--------------------------------------------------------------------------------

local function playSpray()
	local s = sounds["SFX_Spray"]
	if s then
		s.Volume = 1
		s:Play()
	end
end

local function playPowerDown()
	local s = sounds["SFX_PowerDown"]
	if s then
		s.Volume = 1
		s:Play()
	end
end

local function playScream()
	local s = sounds["SFX_Scream"]
	if s then
		s.Volume = 0.8
		s:Play()
	end
end

local function playAchievement()
	local s = sounds["SFX_Achievement"]
	if s then
		s.Volume = 1
		s:Play()
	end
end

local function playClick()
	local s = sounds["SFX_Click"]
	if s then
		s.Volume = 0.7
		s:Play()
	end
end

-- Short tactile switch click. Pressing in sits a little higher than releasing,
-- like the two halves of a real clicky tail switch.
local function playFlashlightClick(isOn: boolean?)
	local s = sounds["SFX_FlashlightClick"]
	if s then
		s.TimePosition = 0
		s.Volume = 0.55 + math.random() * 0.1
		s.PlaybackSpeed = (if isOn then 1.25 else 1.05) + (math.random() - 0.5) * 0.06
		s:Play()
	end
end

local function playFootstep()
	local s = sounds["SFX_Footstep"]
	if s then
		-- Slight volume + pitch randomization for natural feel
		s.Volume = 0.5 + math.random() * 0.3
		s.PlaybackSpeed = 0.9 + math.random() * 0.2
		s:Play()
	end
end

--------------------------------------------------------------------------------
-- Phase Transition Handler
--------------------------------------------------------------------------------

local function onPhaseChanged(phase: number)
	local previousPhase = currentPhase
	currentPhase = phase

	-- Clean up previous phase audio
	if previousPhase == 3 then -- NIGHT2
		stopNightAudio()
	end
	if previousPhase == 2 then -- DAY2
		removeCorruptionDistortion()
	end

	if phase == 1 then -- DAY1
		crossfadeBGM("BGM_Day1")

	elseif phase == 2 then -- DAY2
		crossfadeBGM("BGM_Day2")

	elseif phase == 3 then -- NIGHT2
		-- Power-down boom, unless the night transition cutscene is still
		-- playing: NIGHT2 starts mid-scene and the scene has its own strike.
		if not nightIntroPlaying then
			playPowerDown()
		end
		nightIntroPlaying = false

		-- Short delay then start horror BGM
		task.delay(1, function()
			if currentPhase == 3 then -- NIGHT2
				crossfadeBGM("BGM_Night2")
				startNightAudio()
			end
		end)

	elseif phase == 4 then -- DAY3
		crossfadeBGM("BGM_Day3")

	elseif phase == 0 then -- LOBBY
		stopAllBGM()
		stopNightAudio()
		removeCorruptionDistortion()
	end
end

--------------------------------------------------------------------------------
-- Corruption Handler
--------------------------------------------------------------------------------

local function onCorruptionStarted()
	if currentPhase ~= 2 then -- only during DAY2
		return
	end
	applyCorruptionDistortion()
end

--------------------------------------------------------------------------------
-- BindableEvent API for other client scripts
-- Other LocalScripts can fire these to trigger SFX.
--------------------------------------------------------------------------------

local function createBindableAPI()
	local function makeBindable(name: string, handler: (...any) -> ())
		local event = Instance.new("BindableEvent")
		event.Name = name
		event.Parent = script
		event.Event:Connect(handler)
	end

	makeBindable("PlaySpray", playSpray)
	makeBindable("PlayPowerDown", playPowerDown)
	makeBindable("PlayScream", playScream)
	makeBindable("PlayAchievement", playAchievement)
	makeBindable("PlayClick", playClick)
	makeBindable("PlayFootstep", playFootstep)
	makeBindable("PlayFlashlightClick", playFlashlightClick)
end

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

-- Set up all sound infrastructure
createSoundGroups()
createAllSounds()
createBindableAPI()

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

-- The music follows the story, not just the phase. The night transition
-- cutscene starts while DAY2's cheerful track is still up, so the horror
-- track takes over the moment it begins; and the bad ending trades DAY3's
-- triumphant track for the horror one.
CutsceneTrigger.OnClientEvent:Connect(function(data: any)
	if type(data) == "table" and data.cutscene == "nightTransition" then
		nightIntroPlaying = true
		removeCorruptionDistortion()
		crossfadeBGM("BGM_Night2")
	end
end)
EndingTrigger.OnClientEvent:Connect(function(data: any)
	if type(data) == "table" and data.ending == "bad" then
		crossfadeBGM("BGM_Night2")
	end
end)

-- Also listen for spray remote to auto-play spray SFX
local sprayRemote = Remotes:FindFirstChild("DeodorantSpray") :: RemoteEvent?
if sprayRemote then
	sprayRemote.OnClientEvent:Connect(function()
		playSpray()
	end)
end

print("[AudioManager] Initialized —", #sounds, "sounds created across", #soundGroups, "groups")
