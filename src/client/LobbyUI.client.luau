--!strict
--[[
	LobbyUI.client.luau
	LocalScript. Full-screen lobby menu for Not Gonna Make It.

	Laid out on a 1600x900 stage that is scaled to fill the screen, so it
	reads the same size on every display:
	  * left: title, mode rows (the party leader picks one), open parties
	  * right: the party (Lobby/PartyPanel)
	  * on top: match countdown, notices, rejoin bar (Lobby/Overlay)

	Only shown on the lobby server. Talks to LobbyManager over
	PlayerJoinedLobby (actions, client -> server) and QueueUpdate, MatchFound,
	StartGame (server -> client); see server Lobby/Net for the messages.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")

local LobbyFolder = script.Parent:WaitForChild("Lobby")
local Backdrop = require(LobbyFolder:WaitForChild("Backdrop"))
local Parts = require(LobbyFolder:WaitForChild("Parts"))
local PartyPanel = require(LobbyFolder:WaitForChild("PartyPanel"))
local Browser = require(LobbyFolder:WaitForChild("Browser"))
local Overlay = require(LobbyFolder:WaitForChild("Overlay"))

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local ActionRemote = Remotes:WaitForChild("PlayerJoinedLobby") :: RemoteEvent
local QueueUpdateRemote = Remotes:WaitForChild("QueueUpdate") :: RemoteEvent
local MatchFoundRemote = Remotes:WaitForChild("MatchFound") :: RemoteEvent
local StartGameRemote = Remotes:WaitForChild("StartGame") :: RemoteEvent
local GameStateChangedRemote = Remotes:WaitForChild("GameStateChanged") :: RemoteEvent

local INK, MUTED = Parts.INK, Parts.MUTED
local tween = Parts.tween

local STAGE_W, STAGE_H = 1600, 900
local BACKGROUND = Color3.fromRGB(8, 8, 10)
local MODES = {
	{ size = 1, name = "Solo" },
	{ size = 2, name = "Duo" },
	{ size = 4, name = "Team" },
}

type State = PartyPanel.State

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local gui: ScreenGui? = nil
local stopBackdrop: (() -> ())? = nil
local restoreHud: (() -> ())? = nil -- gameplay HUD held off while the menu is open
local panel: PartyPanel.Panel? = nil
local browser: Browser.List? = nil
local overlay: Overlay.Overlay? = nil
local rows: { [number]: Parts.Row } = {}
local lastState: State? = nil
local viewportConn: RBXScriptConnection? = nil

local function send(action: string, payload: { [string]: any }?)
	local data = payload or {}
	data.action = action
	ActionRemote:FireServer(data)
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

--- A 1600x900 frame centred on screen and scaled to fit it.
local function stage(parent: Instance, z: number): (Frame, UIScale)
	local frame = Instance.new("Frame")
	frame.Name = "Stage"
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromOffset(STAGE_W, STAGE_H)
	frame.BackgroundTransparency = 1
	frame.ZIndex = z
	frame.Parent = parent
	local scale = Instance.new("UIScale")
	scale.Parent = frame
	return frame, scale
end

local function applyState(s: State)
	local party = s.party
	if panel then
		panel.update(s)
	end
	if browser then
		browser.update(s.open :: any)
	end
	if not party then
		return
	end
	local leader = party.leaderId == LocalPlayer.UserId
	local idle = party.status == "idle"
	for size, row in rows do
		local active = party.mode == size
		tween(row.marker, { BackgroundTransparency = if active then 0 else 1 })
		tween(row.name, { TextTransparency = if active then 0 else Parts.NAME_IDLE })
		tween(row.line, { BackgroundTransparency = if active then Parts.LINE_HOVER else Parts.LINE_IDLE })
		local searching = 0
		for _, entry in s.searching do
			if entry.mode == size then
				searching = entry.players
			end
		end
		row.count.Text = if searching > 0 then string.format("%d searching", searching) else ""
		row.count.TextColor3 = if active then INK else MUTED
		row.setEnabled(leader and idle and #party.members <= size)
	end
	if overlay then
		overlay.setRejoin(s.rejoin and (idle or party.status == "searching"))
		if idle or party.status == "searching" then
			overlay.hideCountdown()
		end
	end
end

local function build()
	if gui then
		return
	end
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "LobbyGui"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 100
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local bg = Instance.new("Frame")
	bg.Name = "Background"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = BACKGROUND
	bg.BorderSizePixel = 0
	bg.ZIndex = 1
	bg.Parent = screenGui

	-- Translucent foreground over the backdrop shots: dense behind both menu
	-- columns so the type reads over rain and signage, thinner in the middle
	-- where the scene shows through
	local shade = Instance.new("UIGradient")
	shade.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.04),
		NumberSequenceKeypoint.new(0.36, 0.12),
		NumberSequenceKeypoint.new(0.5, 0.45),
		NumberSequenceKeypoint.new(0.64, 0.12),
		NumberSequenceKeypoint.new(1, 0.04),
	})
	shade.Parent = bg
	stopBackdrop = Backdrop.start(bg)

	local menu, menuScale = stage(screenGui, 2)
	local dim = Instance.new("Frame")
	dim.Name = "Dim"
	dim.Size = UDim2.fromScale(1, 1)
	dim.BorderSizePixel = 0
	dim.ZIndex = 10
	dim.Parent = screenGui
	local top, topScale = stage(screenGui, 11)

	local function rescale()
		local camera = workspace.CurrentCamera
		if camera then
			local v = camera.ViewportSize
			local s = math.clamp(math.min(v.X / STAGE_W, v.Y / STAGE_H), 0.3, 3)
			menuScale.Scale = s
			topScale.Scale = s
		end
	end
	rescale()
	if workspace.CurrentCamera then
		viewportConn = workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
	end

	-- Left column: title, modes, open parties
	local left = Instance.new("Frame")
	left.Name = "Left"
	left.Position = UDim2.fromOffset(60, 36)
	left.Size = UDim2.fromOffset(680, STAGE_H - 72)
	left.BackgroundTransparency = 1
	left.Parent = menu
	Parts.vlist(left, 8)

	local eyebrow = Parts.text(left, "VESPERHACKS  /  48 HOURS", 22, Parts.BOLD, Parts.RED)
	eyebrow.LayoutOrder = 1

	-- TextSize stops at 100; TextScaled lets the title fill its box.
	local title = Parts.text(left, "Not Gonna\nMake It", 100, Parts.SERIF, INK)
	title.LayoutOrder = 2
	title.TextYAlignment = Enum.TextYAlignment.Top
	title.TextScaled = true
	title.Size = UDim2.fromOffset(520, 222)
	title.LineHeight = 0.86

	local caption = Parts.text(left, "SELECT MODE", 20, Parts.BOLD, MUTED)
	caption.LayoutOrder = 3

	for i, m in MODES do
		rows[m.size] = Parts.row(left, 3 + i, m.size, m.name, function()
			local s = lastState
			return s ~= nil and s.party ~= nil and s.party.mode == m.size
		end, function()
			send("mode", { mode = m.size })
		end)
	end

	Parts.box(left, 10, 6)
	browser = Browser.build(left, 11, 196, send)

	-- Right column: the party
	local right = Instance.new("Frame")
	right.Name = "Right"
	right.AnchorPoint = Vector2.new(1, 0)
	right.Position = UDim2.new(1, -60, 0, 36)
	right.Size = UDim2.fromOffset(620, STAGE_H - 72)
	right.BackgroundTransparency = 1
	right.Parent = menu
	panel = PartyPanel.build(right, send)

	local footer = Parts.text(menu, "v0.2.0 alpha", 18, Parts.BODY, MUTED)
	footer.AnchorPoint = Vector2.new(0, 1)
	footer.Position = UDim2.new(0, 60, 1, -10)
	footer.Size = UDim2.fromOffset(200, 20)
	footer.TextTransparency = 0.4

	overlay = Overlay.build(top, dim, send)

	gui = screenGui
	screenGui.Parent = PlayerGui
	restoreHud = Parts.holdHud(PlayerGui, { LobbyGui = true, AdminPanel = true })

	if lastState then
		applyState(lastState)
	end
end

--- Fade the menu out and destroy it (destroying, not disabling, means nothing
--- can switch it back on behind the match, e.g. a cutscene restoring GUIs).
local function hide()
	local screenGui = gui
	if not screenGui then
		return
	end
	gui = nil
	panel, browser, overlay = nil, nil, nil
	table.clear(rows)
	if viewportConn then
		viewportConn:Disconnect()
		viewportConn = nil
	end
	if restoreHud then
		restoreHud()
		restoreHud = nil
	end
	if stopBackdrop then
		stopBackdrop()
		stopBackdrop = nil
	end
	for _, child in screenGui:GetDescendants() do
		if child:IsA("TextLabel") or child:IsA("TextButton") or child:IsA("TextBox") then
			tween(child, { TextTransparency = 1, BackgroundTransparency = 1 }, 0.8)
		elseif child:IsA("Frame") or child:IsA("ScrollingFrame") then
			tween(child, { BackgroundTransparency = 1 }, 0.8)
		elseif child:IsA("ImageLabel") then
			tween(child, { ImageTransparency = 1, BackgroundTransparency = 1 }, 0.8)
		elseif child:IsA("UIStroke") then
			tween(child, { Transparency = 1 }, 0.8)
		end
	end
	task.delay(1.0, function()
		screenGui:Destroy()
	end)
end

--------------------------------------------------------------------------------
-- Server messages (connected before the menu exists so none are missed)
--------------------------------------------------------------------------------

QueueUpdateRemote.OnClientEvent:Connect(function(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local kind = payload.type
	if kind == "state" then
		lastState = payload :: State
		if gui then
			applyState(payload :: State)
		end
	elseif kind == "toast" and overlay then
		overlay.toast(tostring(payload.text or ""), payload.tone)
	elseif kind == "countdown" and overlay then
		overlay.countdown(tonumber(payload.remaining) or 0, if typeof(payload.names) == "table" then payload.names else {})
	elseif kind == "launching" and overlay then
		overlay.launching()
	elseif kind == "cancelled" and overlay then
		overlay.hideCountdown()
		overlay.toast(tostring(payload.reason or "Match cancelled"), "warn")
	end
end)

MatchFoundRemote.OnClientEvent:Connect(function(payload: any)
	if typeof(payload) == "table" and overlay then
		local names = if typeof(payload.players) == "table" then payload.players else {}
		overlay.countdown(tonumber(payload.countdownSeconds) or 5, names)
	end
end)

StartGameRemote.OnClientEvent:Connect(function()
	hide()
end)

GameStateChangedRemote.OnClientEvent:Connect(function(payload: any)
	local phase = if typeof(payload) == "table" then payload.phase else payload
	if typeof(phase) == "number" and phase ~= 0 then -- 0 == LOBBY
		hide()
	end
end)

--------------------------------------------------------------------------------
-- Initialize
--------------------------------------------------------------------------------

-- LocalScripts can start before the initial snapshot lands, so the
-- IsMatchServer attribute and CurrentPhase may not be visible yet.
if not game:IsLoaded() then
	game.Loaded:Wait()
end

-- The mode was already picked if we arrived on a reserved match server (the
-- lobby teleports the party here with a matchId) or a match is already running.
local function isMatchServer(): boolean
	if ReplicatedStorage:GetAttribute("IsMatchServer") == true then
		return true
	end
	local ok, data = pcall(function()
		return TeleportService:GetLocalPlayerTeleportData()
	end)
	return ok and typeof(data) == "table" and (data :: any).matchId ~= nil
end

if isMatchServer() then
	print("[LobbyUI] Match server, skipping mode menu")
	return
end

-- Late safety net: if the match-server flag shows up after the menu was
-- built, take it down instead of leaving a dead menu over the match.
ReplicatedStorage:GetAttributeChangedSignal("IsMatchServer"):Connect(function()
	if ReplicatedStorage:GetAttribute("IsMatchServer") == true then
		hide()
	end
end)

-- The menu is up whenever this server is in the LOBBY phase. CurrentPhase is
-- replicated state, so unlike the remote it can't be missed.
local phaseValue = ReplicatedStorage:WaitForChild("CurrentPhase", 30)
if phaseValue and phaseValue:IsA("IntValue") then
	if phaseValue.Value == 0 then
		build()
	end
	phaseValue.Changed:Connect(function(value: number)
		if value == 0 then
			task.delay(1.2, function()
				if phaseValue.Value == 0 then
					build()
				end
			end)
		else
			hide()
		end
	end)
else
	build()
end

-- Keep the search timer ticking between server updates.
task.spawn(function()
	while true do
		task.wait(0.5)
		if panel then
			panel.tick()
		end
	end
end)

print("[LobbyUI] Lobby interface loaded")
