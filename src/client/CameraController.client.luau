--!strict
--------------------------------------------------------------------------------
-- CameraController.client.luau
-- Manages camera modes (lobby, 1st-person, cutscene) and procedural camera
-- feel (movement sway, turn lean, corner peek, screen shake) driven by game
-- phase transitions.
--
-- Design notes:
--   • Lobby uses Roblox's Classic camera with a free cursor for the queue menu
--   • Every gameplay phase is LockFirstPerson
--   • Sway, turn lean and peek are applied in one RenderStepped pass and are
--     skipped whenever the camera is not Custom, so they never fight a cutscene
--   • Cutscene playback is delegated to Shared.CinematicCamera
--   • Screen shake is additive CFrame noise, usable from any system
--------------------------------------------------------------------------------

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local CinematicCamera = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CinematicCamera"))
local Sway = require(script.Parent:WaitForChild("Camera"):WaitForChild("Sway"))

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

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

type CameraMode = "Lobby" | "FirstPerson" | "Cutscene"

local currentMode: CameraMode = "Lobby"
local currentPhase: number = 0 -- LOBBY

-- Screen shake state
local shakeIntensity: number = 0
local shakeDuration: number = 0
local shakeElapsed: number = 0
local shakeConnection: RBXScriptConnection? = nil
local shakeRng = Random.new()

-- Cutscene state
local cutsceneActive: boolean = false

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

		-- a cutscene camera holds still, so a relative nudge would pile up
		if camera.CameraType == Enum.CameraType.Scriptable then
			return
		end

		-- Intensity fades out linearly over the duration
		local remaining = 1 - (shakeElapsed / shakeDuration)
		local currentIntensity = shakeIntensity * remaining

		-- Random rotational + translational offset
		local offsetX = shakeRng:NextNumber(-1, 1) * currentIntensity
		local offsetY = shakeRng:NextNumber(-1, 1) * currentIntensity
		local roll = shakeRng:NextNumber(-1, 1) * currentIntensity * 0.5

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
local restoreCameraAfterCutscene: () -> ()

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

	-- CinematicCamera drives the camera absolutely every frame (so shake layered
	-- on top never accumulates) and locks / unlocks controls itself.
	local handle = CinematicCamera.play({
		shots = CinematicCamera.fromKeyframes(keyframes, durations),
		letterbox = true,
	})
	handle.Completed:Wait()

	-- A phase change may already have cancelled and restored it.
	if cutsceneActive then
		restoreCameraAfterCutscene()
	end
end

--- Restore the camera back to gameplay mode after a cutscene.
restoreCameraAfterCutscene = function()
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

local waitingForCutscene = false

--- Apply the (always first-person) camera setup appropriate for a phase.
--- Only the FOV and ambient effects differ between phases now.
function applyCameraForPhase(phase: number)
	-- A cutscene that holds the camera Scriptable (CutsceneManager's night
	-- transition spans the switch to NIGHT2) owns it until it hands back.
	-- Switching to Custom here, even for the one frame before the cutscene
	-- reclaimed it, let the default camera snap to the player's head, and the
	-- shot then stayed on the player's POV until the next cut. Apply the
	-- current phase's setup once the cutscene restores the camera instead.
	if camera.CameraType == Enum.CameraType.Scriptable and not cutsceneActive then
		if not waitingForCutscene then
			waitingForCutscene = true
			task.spawn(function()
				while camera.CameraType == Enum.CameraType.Scriptable do
					camera:GetPropertyChangedSignal("CameraType"):Wait()
				end
				waitingForCutscene = false
				applyCameraForPhase(currentPhase)
			end)
		end
		return
	end
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
		CinematicCamera.cancel()
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
Sway.start(function()
	return currentMode == "FirstPerson"
end)


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
