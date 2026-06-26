--!strict
--------------------------------------------------------------------------------
-- CameraController.client.luau
-- Manages camera modes (3rd-person, 1st-person, cutscene) and effects
-- (head-bob, screen shake) driven by game phase transitions.
--
-- Design notes:
--   • 3rd person (Day 1/2/3) uses Roblox's Classic camera with zoom limits
--   • 1st person (Night 2) smoothly tweens zoom → 0.5 then locks, adds head-bob
--   • Cutscene mode uses Scriptable camera with CFrame waypoint tweening
--   • Screen shake is additive CFrame noise, usable from any system
--------------------------------------------------------------------------------

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

-- Remotes (created by Rojo from default.project.json)
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local GameStateChanged = Remotes:WaitForChild("GameStateChanged") :: RemoteEvent
local CutsceneTrigger = Remotes:WaitForChild("CutsceneTrigger") :: RemoteEvent

local localPlayer = Players.LocalPlayer
local camera = workspace.CurrentCamera

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

-- Default (non-horror) field of view
local DEFAULT_FOV = 70

-- 1st person (the game is always first-person)
local FIRST_PERSON_ZOOM = 0.5
local HORROR_FOV = 55 -- claustrophobic FOV used during Night 2
local FOV_TWEEN_DURATION = 1.5

-- Camera sway parameters.
-- The motion is a slow side-to-side sway (lateral drift + a gentle lean/roll),
-- NOT an up-and-down step bob. The vertical component is kept tiny — just a
-- faint bounce so it doesn't feel perfectly rigid. Sprinting swings wider and
-- faster. These are *target* values that the live sway lerps toward, so the
-- transition between walking and sprinting feels smooth rather than snapping.
local WALK_SWAY_FREQUENCY = 0.4 -- side-to-side cycles per second while walking (very slow)
local WALK_SWAY_AMPLITUDE_X = 0.035 -- lateral drift (studs) — the main motion
local WALK_SWAY_AMPLITUDE_Y = 0.004 -- vertical bounce (studs) — barely there
local WALK_SWAY_ROLL = 0.8 -- camera lean into the sway (degrees)

-- Sprinting keeps the SAME amplitude as walking, just twice the speed.
local SPRINT_SWAY_FREQUENCY = WALK_SWAY_FREQUENCY * 2
local SPRINT_SWAY_AMPLITUDE_X = WALK_SWAY_AMPLITUDE_X
local SPRINT_SWAY_AMPLITUDE_Y = WALK_SWAY_AMPLITUDE_Y
local SPRINT_SWAY_ROLL = WALK_SWAY_ROLL

local SWAY_LERP_SPEED = 6 -- how quickly sway eases between walk/sprint states

-- Screen shake
local SHAKE_FREQUENCY = 25 -- how rapidly the camera vibrates

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

type CameraMode = "Lobby" | "FirstPerson" | "Cutscene"

local currentMode: CameraMode = "Lobby"
local currentPhase: number = 0 -- LOBBY

-- Sway state (persists for the whole session; the game is always first-person)
local swayConnection: RBXScriptConnection? = nil
local swayPhase: number = 0 -- accumulated oscillation phase
-- Live sway values, lerped toward the walk/sprint targets each frame
local curFreq: number = WALK_SWAY_FREQUENCY
local curAmpY: number = WALK_SWAY_AMPLITUDE_Y
local curAmpX: number = WALK_SWAY_AMPLITUDE_X
local curRoll: number = 0

-- Screen shake state
local shakeIntensity: number = 0
local shakeDuration: number = 0
local shakeElapsed: number = 0
local shakeConnection: RBXScriptConnection? = nil

-- Cutscene state
local cutsceneActive: boolean = false
local preCutsceneCameraType: Enum.CameraType = Enum.CameraType.Custom
local preCutsceneCFrame: CFrame = CFrame.new()

--------------------------------------------------------------------------------
-- Helper: get the player's humanoid safely
--------------------------------------------------------------------------------

local function getHumanoid(): Humanoid?
	local character = localPlayer.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

--------------------------------------------------------------------------------
-- First Person Lock (always on)
-- The game is permanently first-person. Forcing min == max zoom == 0.5 and
-- CameraMode = LockFirstPerson keeps the player pinned to the head with no way
-- to scroll out. These are Player properties, so they survive respawns.
--------------------------------------------------------------------------------

local function lockFirstPerson()
	currentMode = "FirstPerson"

	localPlayer.CameraMinZoomDistance = FIRST_PERSON_ZOOM
	localPlayer.CameraMaxZoomDistance = FIRST_PERSON_ZOOM
	localPlayer.CameraMode = Enum.CameraMode.LockFirstPerson

	-- Ensure camera is Custom (not Scriptable left over from a cutscene)
	camera.CameraType = Enum.CameraType.Custom
end

--------------------------------------------------------------------------------
-- Lobby Camera (LOBBY phase only)
-- The matchmaking / queue screen needs a FREE mouse cursor so the player can
-- click the queue UI. LockFirstPerson pins the mouse to screen-centre, which
-- would make the menu unclickable — so in the lobby we use a normal Classic
-- third-person camera and explicitly release the mouse.
--------------------------------------------------------------------------------

local function enterLobbyCamera()
	currentMode = "Lobby"

	localPlayer.CameraMode = Enum.CameraMode.Classic
	localPlayer.CameraMinZoomDistance = 8
	localPlayer.CameraMaxZoomDistance = 16
	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = DEFAULT_FOV

	-- Release the cursor so the queue UI is clickable
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
end

--------------------------------------------------------------------------------
-- Camera Sway
-- A single persistent RenderStepped loop. Sway intensity scales with how fast
-- the player is actually moving (zero when standing still) and ramps up sharply
-- while sprinting. The current sway parameters ease toward the walk/sprint
-- targets so toggling sprint doesn't cause a visible snap.
--------------------------------------------------------------------------------

local function startSway()
	if swayConnection then
		return
	end

	swayConnection = RunService.RenderStepped:Connect(function(dt: number)
		if currentMode ~= "FirstPerson" then
			return -- suspended during cutscenes
		end

		local humanoid = getHumanoid()
		if not humanoid then
			return
		end

		-- 0 when standing still, ~1 when moving under player control
		local moveRatio = math.clamp(humanoid.MoveDirection.Magnitude, 0, 1)

		-- The StaminaController sets this attribute while the player sprints
		local sprinting = (localPlayer:GetAttribute("Sprinting") == true) and moveRatio > 0.01

		-- Pick the target sway profile for this frame
		local targetFreq = if sprinting then SPRINT_SWAY_FREQUENCY else WALK_SWAY_FREQUENCY
		local targetAmpY = if sprinting then SPRINT_SWAY_AMPLITUDE_Y else WALK_SWAY_AMPLITUDE_Y
		local targetAmpX = if sprinting then SPRINT_SWAY_AMPLITUDE_X else WALK_SWAY_AMPLITUDE_X
		local targetRoll = if sprinting then SPRINT_SWAY_ROLL else WALK_SWAY_ROLL

		-- Ease the live values toward the target
		local alpha = math.clamp(dt * SWAY_LERP_SPEED, 0, 1)
		curFreq += (targetFreq - curFreq) * alpha
		curAmpY += (targetAmpY - curAmpY) * alpha
		curAmpX += (targetAmpX - curAmpX) * alpha
		curRoll += (targetRoll - curRoll) * alpha

		-- Only advance the oscillation while actually moving
		swayPhase += dt * curFreq * moveRatio

		-- Side-to-side is the primary motion: lateral drift + a matching lean/roll
		-- both ride the base frequency, so the camera gently rocks left↔right.
		local lateral = math.sin(swayPhase * math.pi * 2)
		local swayX = lateral * curAmpX * moveRatio
		local roll = lateral * curRoll * moveRatio

		-- Vertical is a tiny secondary bounce at double frequency (one dip per
		-- footfall) so the sway doesn't feel perfectly flat — but stays subtle.
		local swayY = math.sin(swayPhase * math.pi * 4) * curAmpY * moveRatio

		camera.CFrame = camera.CFrame * CFrame.new(swayX, swayY, 0) * CFrame.Angles(0, 0, math.rad(roll))
	end)
end

--------------------------------------------------------------------------------
-- Screen Shake
-- Additive random CFrame noise. Call from anywhere for jump scares, explosions.
--------------------------------------------------------------------------------

local function shakeCamera(intensity: number, duration: number)
	shakeIntensity = intensity
	shakeDuration = duration
	shakeElapsed = 0

	-- Only create one connection; if already shaking, the new params take over
	if shakeConnection then
		return
	end

	shakeConnection = RunService.RenderStepped:Connect(function(dt: number)
		shakeElapsed += dt

		if shakeElapsed >= shakeDuration then
			-- Shake finished
			if shakeConnection then
				shakeConnection:Disconnect()
				shakeConnection = nil
			end
			return
		end

		-- Intensity fades out linearly over the duration
		local remaining = 1 - (shakeElapsed / shakeDuration)
		local currentIntensity = shakeIntensity * remaining

		-- Random rotational + translational offset
		local rng = Random.new()
		local offsetX = rng:NextNumber(-1, 1) * currentIntensity
		local offsetY = rng:NextNumber(-1, 1) * currentIntensity
		local roll = rng:NextNumber(-1, 1) * currentIntensity * 0.5

		camera.CFrame = camera.CFrame * CFrame.new(offsetX * 0.1, offsetY * 0.1, 0)
			* CFrame.Angles(0, 0, math.rad(roll))
	end)
end

--------------------------------------------------------------------------------
-- Cutscene Mode
-- Scriptable camera that tweens between CFrame waypoints. Player input disabled.
--------------------------------------------------------------------------------

--- Disables/enables player character controls.
local function setPlayerControlsEnabled(enabled: boolean)
	-- Attempt to get the PlayerModule that Roblox injects into PlayerScripts
	local playerScripts = localPlayer:FindFirstChild("PlayerScripts")
	if not playerScripts then
		return
	end

	local playerModule = playerScripts:FindFirstChild("PlayerModule")
	if not playerModule then
		return
	end

	-- PlayerModule is a ModuleScript, require it to access controls
	local ok, mod = pcall(function()
		return require(playerModule :: ModuleScript)
	end)

	if ok and mod then
		local controls = (mod :: any):GetControls()
		if controls then
			if enabled then
				controls:Enable()
			else
				controls:Disable()
			end
		end
	end
end

--- Play a scripted camera path through a series of CFrame waypoints.
--- @param keyframes — ordered list of CFrame positions/orientations
--- @param durations — time (seconds) to tween from keyframe[i] to keyframe[i+1]
local function playCameraPath(keyframes: { CFrame }, durations: { number })
	if #keyframes < 2 then
		warn("[CameraController] playCameraPath needs at least 2 keyframes")
		return
	end

	if #durations < #keyframes - 1 then
		warn("[CameraController] Not enough durations for keyframes")
		return
	end

	cutsceneActive = true

	-- Save pre-cutscene state
	preCutsceneCameraType = camera.CameraType
	preCutsceneCFrame = camera.CFrame

	-- Switch to scriptable camera
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = keyframes[1]

	-- Disable player movement
	setPlayerControlsEnabled(false)

	-- Tween through each keyframe pair sequentially
	for i = 1, #keyframes - 1 do
		if not cutsceneActive then
			break -- cutscene was cancelled (e.g., phase change)
		end

		local targetCF = keyframes[i + 1]
		local duration = durations[i]

		local tweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
		local tween = TweenService:Create(camera, tweenInfo, { CFrame = targetCF })
		tween:Play()
		tween.Completed:Wait()
	end

	-- Cutscene finished — restore camera
	restoreCameraAfterCutscene()
end

--- Restore the camera back to gameplay mode after a cutscene.
function restoreCameraAfterCutscene()
	cutsceneActive = false

	-- Re-enable player controls
	setPlayerControlsEnabled(true)

	-- Always return to first-person gameplay
	applyCameraForPhase(currentPhase)
end

--------------------------------------------------------------------------------
-- Phase Transition Handler
-- Listens to the server's GameStateChanged remote to switch camera modes.
--------------------------------------------------------------------------------

--- Apply the (always first-person) camera setup appropriate for a phase.
--- Only the FOV and ambient effects differ between phases now.
function applyCameraForPhase(phase: number)
	-- LOBBY (phase 0) is the matchmaking menu — keep the cursor free.
	if phase == 0 then
		enterLobbyCamera()
		return
	end

	lockFirstPerson()

	-- Night 2 narrows the FOV for a claustrophobic horror feel; every other
	-- phase uses the comfortable default.
	local targetFov = if phase == 3 then HORROR_FOV else DEFAULT_FOV
	TweenService:Create(camera, TweenInfo.new(FOV_TWEEN_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut), {
		FieldOfView = targetFov,
	}):Play()

	if phase == 3 then -- NIGHT2
		-- Slight screen shake as the power goes out
		task.delay(0.5, function()
			shakeCamera(0.6, 1.5)
		end)
	end
end

local function onPhaseChanged(phaseData: { [string]: any })
	local phase = phaseData.phase
	if type(phase) ~= "number" then
		phase = 0 -- default to LOBBY
	end

	currentPhase = phase :: number

	-- Cancel any active cutscene on phase change
	if cutsceneActive then
		cutsceneActive = false
		setPlayerControlsEnabled(true)
	end

	applyCameraForPhase(currentPhase)
end

--------------------------------------------------------------------------------
-- Cutscene Remote Handler
-- Server sends cutscene data with keyframes and durations.
--------------------------------------------------------------------------------

local function onCutsceneTrigger(data: { [string]: any })
	local keyframes = data.keyframes :: { CFrame }?
	local durations = data.durations :: { number }?

	if keyframes and durations then
		task.spawn(function()
			playCameraPath(keyframes, durations)
		end)
	end
end

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

-- Start in the correct camera for the current phase. We begin in the LOBBY
-- (free cursor for the queue menu); gameplay phases lock to first person.
applyCameraForPhase(currentPhase)
startSway()

-- Re-assert the first-person lock whenever the character respawns, just in case
-- another system briefly changes camera settings during the respawn.
localPlayer.CharacterAdded:Connect(function()
	task.wait(0.1)
	if currentMode == "FirstPerson" then
		lockFirstPerson()
	end
end)

-- Wire up remote events
GameStateChanged.OnClientEvent:Connect(function(...)
	-- The server may send phase info as a table or positional args
	local args = { ... }
	if type(args[1]) == "table" then
		onPhaseChanged(args[1])
	else
		onPhaseChanged({ phase = args[1] })
	end
end)

CutsceneTrigger.OnClientEvent:Connect(function(...)
	local args = { ... }
	if type(args[1]) == "table" then
		onCutsceneTrigger(args[1])
	else
		onCutsceneTrigger({ keyframes = args[1], durations = args[2] })
	end
end)

-- Expose public API so other client scripts can trigger effects
-- (They can require this if needed via shared reference, or we use BindableEvents)
local ShakeEvent = Instance.new("BindableEvent")
ShakeEvent.Name = "CameraShake"
ShakeEvent.Parent = script

ShakeEvent.Event:Connect(function(intensity: number, duration: number)
	shakeCamera(intensity, duration)
end)

print("[CameraController] Initialized — mode:", currentMode)
