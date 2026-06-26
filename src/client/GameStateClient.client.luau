--!strict
--------------------------------------------------------------------------------
-- GameStateClient.client.luau
-- Client-side state listener for "Code Red: The Hackathon Horror"
--
-- Listens to server remotes (GameStateChanged, PhaseTimerSync, EndingTrigger,
-- CorruptionStarted), maintains a local copy of the current phase and time,
-- and dispatches BindableEvents so other client systems (Camera, Lighting,
-- Audio, HUD) can react independently.
--
-- Also manages the in-game clock display and the Day1→Day2 sleep transition.
--------------------------------------------------------------------------------

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService      = game:GetService("TweenService")
local Lighting          = game:GetService("Lighting")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

--------------------------------------------------------------------------------
-- Remote references
--------------------------------------------------------------------------------
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local GameStateChanged  = Remotes:WaitForChild("GameStateChanged")  :: RemoteEvent
local PhaseTimerSync    = Remotes:WaitForChild("PhaseTimerSync")    :: RemoteEvent
local EndingTrigger     = Remotes:WaitForChild("EndingTrigger")     :: RemoteEvent
local CorruptionStartedRemote = Remotes:WaitForChild("CorruptionStarted") :: RemoteEvent
local CutsceneTrigger   = Remotes:WaitForChild("CutsceneTrigger")  :: RemoteEvent

--------------------------------------------------------------------------------
-- Local BindableEvents — created under this script so other client modules
-- can :WaitForChild() and connect to them.
--------------------------------------------------------------------------------
local function createBindable(name: string): BindableEvent
	local be = Instance.new("BindableEvent")
	be.Name = name
	be.Parent = script
	return be
end

local PhaseChanged      = createBindable("PhaseChanged")
local CorruptionStarted = createBindable("CorruptionStarted")
local TimeUpdated       = createBindable("TimeUpdated")

-- Expose for other client modules
local GameStateClient = {}
GameStateClient.PhaseChanged      = PhaseChanged
GameStateClient.CorruptionStarted = CorruptionStarted
GameStateClient.TimeUpdated       = TimeUpdated

--------------------------------------------------------------------------------
-- Local state
--------------------------------------------------------------------------------
local currentPhase: number = 0 -- LOBBY
local timeRemaining: number = 0
local gameClockTime: number = 18 -- default 6 PM
local isTransitioning: boolean = false

GameStateClient.currentPhase   = currentPhase
GameStateClient.timeRemaining  = timeRemaining
GameStateClient.gameClockTime  = gameClockTime

--------------------------------------------------------------------------------
-- Clock formatting — converts a float hour to "HH:MM AM/PM"
--------------------------------------------------------------------------------
local function formatGameClock(hour: number): string
	local h = math.floor(hour) % 24
	local m = math.floor((hour % 1) * 60)
	local period = "AM"
	local displayHour = h

	if h == 0 then
		displayHour = 12
		period = "AM"
	elseif h < 12 then
		displayHour = h
		period = "AM"
	elseif h == 12 then
		displayHour = 12
		period = "PM"
	else
		displayHour = h - 12
		period = "PM"
	end

	return string.format("%d:%02d %s", displayHour, m, period)
end

GameStateClient.formatGameClock = formatGameClock

--------------------------------------------------------------------------------
-- Transition overlay GUI — used for fades
-- Creates a simple full‑screen black frame on demand.
--------------------------------------------------------------------------------
local transitionGui: ScreenGui? = nil
local transitionFrame: Frame? = nil

local function ensureTransitionGui(): (ScreenGui, Frame)
	if transitionGui and transitionFrame then
		return transitionGui, transitionFrame
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "TransitionOverlay"
	gui.DisplayOrder = 100  -- on top of everything
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.Parent = playerGui

	local frame = Instance.new("Frame")
	frame.Name = "Overlay"
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.new(0, 0, 0)
	frame.BackgroundTransparency = 1 -- start invisible
	frame.BorderSizePixel = 0
	frame.ZIndex = 100
	frame.Parent = gui

	-- Optional "sleeping…" label
	local label = Instance.new("TextLabel")
	label.Name = "SleepText"
	label.Size = UDim2.fromScale(1, 0.1)
	label.Position = UDim2.fromScale(0, 0.45)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextTransparency = 1
	label.Text = ""
	label.ZIndex = 101
	label.Parent = frame

	transitionGui = gui
	transitionFrame = frame
	return gui, frame
end

--- Fade the screen to black over `fadeTime` seconds
local function fadeToBlack(fadeTime: number): ()
	local _, frame = ensureTransitionGui()
	local tween = TweenService:Create(frame, TweenInfo.new(fadeTime, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		BackgroundTransparency = 0,
	})
	tween:Play()
	tween.Completed:Wait()
end

--- Fade the screen from black back to clear over `fadeTime` seconds
local function fadeFromBlack(fadeTime: number): ()
	local _, frame = ensureTransitionGui()
	local tween = TweenService:Create(frame, TweenInfo.new(fadeTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundTransparency = 1,
	})
	tween:Play()
	tween.Completed:Wait()
end

--- Show text during the overlay (e.g. "Sleeping…")
local function showOverlayText(text: string, fadeTime: number): ()
	local _, frame = ensureTransitionGui()
	local label = frame:FindFirstChild("SleepText") :: TextLabel?
	if not label then return end

	label.Text = text
	local tween = TweenService:Create(label, TweenInfo.new(fadeTime), { TextTransparency = 0 })
	tween:Play()
	tween.Completed:Wait()
end

--- Hide the overlay text
local function hideOverlayText(fadeTime: number): ()
	local _, frame = ensureTransitionGui()
	local label = frame:FindFirstChild("SleepText") :: TextLabel?
	if not label then return end

	local tween = TweenService:Create(label, TweenInfo.new(fadeTime), { TextTransparency = 1 })
	tween:Play()
	tween.Completed:Wait()
end

--------------------------------------------------------------------------------
-- Phase change handler
--------------------------------------------------------------------------------
local function onPhaseChanged(newPhase: number)
	local previousPhase = currentPhase
	currentPhase = newPhase
	GameStateClient.currentPhase = newPhase

	print("[GameStateClient] Phase changed:", previousPhase, "→", newPhase)

	-- Dispatch to all listeners via BindableEvent
	PhaseChanged:Fire(newPhase, previousPhase)

	--------------------------------------------------------------------
	-- DAY1 → DAY2: Sleep transition
	-- The server fires CutsceneTrigger with cutsceneId="Day1Sleep"
	-- but we also handle the phase change here for redundancy.
	--------------------------------------------------------------------
	if previousPhase == GameConfig.Phase.DAY1 and newPhase == GameConfig.Phase.DAY2 and not isTransitioning then
		task.spawn(function()
			isTransitioning = true
			-- The fade is primarily driven by the CutsceneTrigger handler,
			-- but if it hasn't fired yet we do a quick fade here.
			task.wait(0.1) -- small buffer
			isTransitioning = false
		end)
	end

	-- (Per-phase Lighting is owned entirely by LightingController, which uses the
	-- tuned LightingProfiles. We don't set lighting here — a second source just
	-- fights it and washed the night out.)
end

--------------------------------------------------------------------------------
-- Remote event connections
--------------------------------------------------------------------------------

-- GameStateChanged: { phase: string, matchId: string }
GameStateChanged.OnClientEvent:Connect(function(data: { [string]: any })
	local newPhase = data.phase :: number
	if newPhase ~= nil and newPhase ~= currentPhase then
		onPhaseChanged(newPhase)
	end
end)

-- PhaseTimerSync: { currentPhase: string, timeRemaining: number, gameClockTime: number }
PhaseTimerSync.OnClientEvent:Connect(function(data: { [string]: any })
	local serverPhase = data.currentPhase :: number
	timeRemaining = data.timeRemaining :: number
	gameClockTime = data.gameClockTime :: number

	GameStateClient.timeRemaining = timeRemaining
	GameStateClient.gameClockTime = gameClockTime

	-- Dispatch TimeUpdated for HUD clock display
	TimeUpdated:Fire(gameClockTime, timeRemaining, serverPhase)

	-- Safety: if server says we're in a different phase, catch up
	if serverPhase and serverPhase ~= currentPhase then
		onPhaseChanged(serverPhase)
	end
end)

-- CorruptionStarted: no payload (or empty table)
CorruptionStartedRemote.OnClientEvent:Connect(function()
	print("[GameStateClient] Corruption has begun!")
	CorruptionStarted:Fire()
end)

-- CutsceneTrigger: { cutsceneId: string, duration: number }
CutsceneTrigger.OnClientEvent:Connect(function(data: { [string]: any })
	local cutsceneId = data.cutscene :: string
	local duration   = (data.duration :: number) or 3

	print("[GameStateClient] Cutscene triggered:", cutsceneId)

	-- The Day1→Day2 "sleep" cinematic is owned by CutsceneManager now; this
	-- legacy fade-to-black is removed so the two don't overlap.
end)

-- EndingTrigger: { endingType: string, projectCompletion: number }
EndingTrigger.OnClientEvent:Connect(function(data: { [string]: any })
	local endingType = data.ending :: string
	print("[GameStateClient] Ending triggered:", endingType)

	-- Dispatch to CutsceneManager via PhaseChanged (DAY3 phase already set)
	local endingEvent = script:FindFirstChild("EndingTriggered") :: BindableEvent?
	if not endingEvent then
		endingEvent = Instance.new("BindableEvent")
		endingEvent.Name = "EndingTriggered"
		endingEvent.Parent = script
	end
	endingEvent:Fire(endingType, data.projectCompletion)

	-- Show a quick overlay with the ending type for now
	task.spawn(function()
		fadeToBlack(1.5)

		local endingText = "The End"
		if endingType == "true" then
			endingText = "🏆 Project shipped! You survived the hackathon!"
		elseif endingType == "bad" then
			endingText = "💀 Your project was incomplete... NGMI."
		end

		showOverlayText(endingText, 1)
		task.wait(5)
		hideOverlayText(1)
		fadeFromBlack(1.5)
	end)
end)

--------------------------------------------------------------------------------
-- Public accessor API for other client modules
--------------------------------------------------------------------------------

function GameStateClient.getPhase(): number
	return currentPhase
end

function GameStateClient.getTimeRemaining(): number
	return timeRemaining
end

function GameStateClient.getGameClock(): number
	return gameClockTime
end

function GameStateClient.getFormattedClock(): string
	return formatGameClock(gameClockTime)
end

function GameStateClient.isNight(): boolean
	return currentPhase == GameConfig.Phase.NIGHT2
end

return GameStateClient
