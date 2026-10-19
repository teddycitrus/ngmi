--!strict
--------------------------------------------------------------------------------
-- AdminPanel.client.luau
-- A lightweight, testing-only admin/debug overlay.
--
-- Features:
--   • Side panel (collapsible) with buttons to skip the match to any phase
--     (LOBBY → DAY1 → DAY2 → NIGHT2 → DAY3), i.e. "jump to different times".
--   • Fly toggle    — anchors the HumanoidRootPart and flies via WASD + Space/Ctrl.
--   • Noclip toggle — walk through walls without flying.
--   • Speed control — adjusts fly speed.
--   • Press V to free / lock the mouse cursor (so you can click these buttons
--     while the game is in its normal first-person mouse-lock).
--
-- Only drawn for admins (see DebugConfig — always on in Studio, allowlist on a
-- live server). Phase skips are validated again server-side, so this panel
-- existing on a non-admin client would still do nothing.
--------------------------------------------------------------------------------

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local UserInputService  = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig  = require(ReplicatedStorage.Shared.GameConfig)
local DebugConfig = require(ReplicatedStorage.Shared.DebugConfig)
local CursorManager = require(ReplicatedStorage.Shared.CursorManager)
local UITheme = require(ReplicatedStorage.Shared.UITheme)

local localPlayer = Players.LocalPlayer

-- Bail out entirely (don't even build the UI) for non-admins.
if not DebugConfig.isAdmin(localPlayer) then
	return
end

local playerGui = localPlayer:WaitForChild("PlayerGui")
local Remotes   = ReplicatedStorage:WaitForChild("Remotes")
local AdminCommand = Remotes:WaitForChild("AdminCommand") :: RemoteEvent

--------------------------------------------------------------------------------
-- Theme
--------------------------------------------------------------------------------
local COL_HEADER  = UITheme.Color.Danger
local COL_SUBTEXT = UITheme.Color.Faint
local COL_TEXT    = UITheme.Color.Text
local PANEL_WIDTH = 176
local ROW_HEIGHT  = 24

--- Toggle buttons tint green while on; everything else stays neutral.
local function setToggleLook(btn: TextButton, on: boolean)
	btn.BackgroundColor3 = if on then UITheme.Color.Good else UITheme.Color.Line
	local alpha = if on then 0.75 else 0.95
	btn:SetAttribute("BaseTransparency", alpha)
	btn.BackgroundTransparency = alpha
end

--------------------------------------------------------------------------------
-- Character state / movement
--------------------------------------------------------------------------------
local flying = false
local noclip = false
local flySpeed = 60 -- studs / second

local cursorFree = false

local function getCharacter(): Model?
	return localPlayer.Character
end

local function getRoot(): BasePart?
	local char = getCharacter()
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart? or nil
end

local function getHumanoid(): Humanoid?
	local char = getCharacter()
	return char and char:FindFirstChildOfClass("Humanoid") or nil
end

--- Force every body part collidable / non-collidable. Used by noclip (and while
--- flying, as a belt-and-braces measure on top of anchoring the root).
local function setCharacterCanCollide(canCollide: boolean)
	local char = getCharacter()
	if not char then return end
	for _, part in char:GetDescendants() do
		if part:IsA("BasePart") then
			-- The HumanoidRootPart is non-collidable by default; leave it that way
			-- when restoring so we don't introduce odd standing jitter.
			if canCollide and part.Name == "HumanoidRootPart" then
				part.CanCollide = false
			else
				part.CanCollide = canCollide
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Fly
--------------------------------------------------------------------------------
local function setFlying(on: boolean)
	flying = on
	local root = getRoot()
	local humanoid = getHumanoid()

	if on then
		if root then
			root.AssemblyLinearVelocity = Vector3.zero
			root.Anchored = true -- anchored = no gravity, no collision, rock-solid fly
		end
		if humanoid then
			humanoid.PlatformStand = true
		end
	else
		if root then
			root.Anchored = false
		end
		if humanoid then
			humanoid.PlatformStand = false
		end
	end
end

-- Per-frame fly movement (WASD relative to camera, Space up, LeftCtrl down).
RunService.RenderStepped:Connect(function(dt: number)
	if not flying then return end
	local root = getRoot()
	if not root then return end

	local cam = workspace.CurrentCamera
	if not cam then return end

	local dir = Vector3.zero
	local function held(key: Enum.KeyCode): boolean
		return UserInputService:IsKeyDown(key)
	end

	if held(Enum.KeyCode.W) then
		dir += cam.CFrame.LookVector
	end
	if held(Enum.KeyCode.S) then
		dir -= cam.CFrame.LookVector
	end
	if held(Enum.KeyCode.D) then
		dir += cam.CFrame.RightVector
	end
	if held(Enum.KeyCode.A) then
		dir -= cam.CFrame.RightVector
	end
	if held(Enum.KeyCode.Space) then
		dir += Vector3.yAxis
	end
	if held(Enum.KeyCode.LeftControl) then
		dir -= Vector3.yAxis
	end

	if dir.Magnitude > 0 then
		dir = dir.Unit
		-- `CFrame + Vector3` translates while preserving orientation.
		root.CFrame = root.CFrame + dir * flySpeed * dt
	end
	root.AssemblyLinearVelocity = Vector3.zero
end)

--------------------------------------------------------------------------------
-- Noclip — re-assert CanCollide=false every step while active (the Humanoid
-- keeps trying to turn collisions back on).
--------------------------------------------------------------------------------
RunService.Stepped:Connect(function()
	if noclip then
		setCharacterCanCollide(false)
	end
end)

local function setNoclip(on: boolean)
	noclip = on
	if not on then
		setCharacterCanCollide(true)
	end
end

--------------------------------------------------------------------------------
-- Cursor lock / unlock (V)
-- The game normally runs first-person with the mouse locked to centre, which
-- makes UI un-clickable. Freeing the cursor pops the camera out of the hard
-- LockFirstPerson mode so the mouse is usable; re-locking restores it.
--------------------------------------------------------------------------------
local updateCursorLabel: () -> () = function() end -- assigned once the UI exists

local function setCursorFree(free: boolean)
	cursorFree = free
	-- The shared CursorManager owns the free/relock (and its per-frame guard keeps
	-- the cursor free while open); pop restores whatever the pre-toggle state was.
	if free then
		CursorManager.push()
	else
		CursorManager.pop()
	end
	updateCursorLabel()
end

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.V then
		setCursorFree(not cursorFree)
	end
end)

--------------------------------------------------------------------------------
-- Reset movement toggles on respawn (the fresh character isn't anchored).
--------------------------------------------------------------------------------
local onFlyReset: () -> () = function() end
local onNoclipReset: () -> () = function() end

localPlayer.CharacterAdded:Connect(function()
	task.wait(0.1)
	if flying then
		setFlying(false)
		onFlyReset()
	end
	if noclip then
		setNoclip(false)
		onNoclipReset()
	end
end)

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "AdminPanel"
gui.DisplayOrder = 200 -- above HUD / overlays
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = playerGui

-- Root panel on the left edge, vertically centred, so it stays clear of the
-- objectives list on the right. Height follows its contents.
local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0, 0.5)
panel.Position = UDim2.new(0, UITheme.Margin, 0.5, 0)
panel.Size = UDim2.fromOffset(PANEL_WIDTH, 0)
panel.AutomaticSize = Enum.AutomaticSize.Y
panel.BackgroundColor3 = UITheme.Color.Surface
panel.BackgroundTransparency = 0.25
panel.BorderSizePixel = 0
panel.Parent = gui
UITheme.corner(panel, 6)
UITheme.outline(panel)
UITheme.padding(panel, 10)

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Vertical
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 4)
layout.Parent = panel

local order = 0
local function nextOrder(): number
	order += 1
	return order
end

local function makeLabel(text: string, color: Color3, size: number, height: number): TextLabel
	local label = UITheme.label(panel, {
		text = text,
		size = size,
		font = UITheme.Font.Bold,
		color = color,
		shadow = false,
	})
	label.Size = UDim2.new(1, 0, 0, height)
	label.TextYAlignment = Enum.TextYAlignment.Bottom
	label.LayoutOrder = nextOrder()
	return label
end

local function makeButton(text: string, height: number, onClick: () -> ()): TextButton
	local btn = UITheme.button(panel, text, height)
	btn.TextSize = 12
	btn.LayoutOrder = nextOrder()
	btn.Activated:Connect(onClick)
	return btn
end

--------------------------------------------------------------------------------
-- Header (with a minimize toggle)
--------------------------------------------------------------------------------
local headerRow = Instance.new("Frame")
headerRow.Name = "HeaderRow"
headerRow.Size = UDim2.new(1, 0, 0, 18)
headerRow.BackgroundTransparency = 1
headerRow.LayoutOrder = nextOrder()
headerRow.Parent = panel

local headerLabel = UITheme.label(headerRow, {
	text = "ADMIN",
	size = 11,
	font = UITheme.Font.Bold,
	color = COL_HEADER,
	shadow = false,
})
headerLabel.Size = UDim2.new(1, -26, 1, 0)

local minimizeBtn = UITheme.button(headerRow, "-", 18)
minimizeBtn.AnchorPoint = Vector2.new(1, 0.5)
minimizeBtn.Position = UDim2.new(1, 0, 0.5, 0)
minimizeBtn.Size = UDim2.fromOffset(18, 18)
minimizeBtn.FontFace = UITheme.Font.Mono
minimizeBtn.TextSize = 12

--------------------------------------------------------------------------------
-- Phase skip section ("jump to different times")
--------------------------------------------------------------------------------
makeLabel("PHASE", COL_SUBTEXT, 10, 18)

local PHASES = {
	{ name = "Lobby",            id = GameConfig.Phase.LOBBY },
	{ name = "Day 1, dusk",      id = GameConfig.Phase.DAY1 },
	{ name = "Day 2, daytime",   id = GameConfig.Phase.DAY2 },
	{ name = "Night 2, 12 AM",   id = GameConfig.Phase.NIGHT2 },
	{ name = "Day 3, ending",    id = GameConfig.Phase.DAY3 },
}

for _, phase in PHASES do
	makeButton(phase.name, ROW_HEIGHT, function()
		AdminCommand:FireServer({ cmd = "setPhase", phase = phase.id })
	end)
end

--------------------------------------------------------------------------------
-- Movement section
--------------------------------------------------------------------------------
makeLabel("MOVEMENT", COL_SUBTEXT, 10, 18)

local flyBtn: TextButton
flyBtn = makeButton("Fly: OFF", ROW_HEIGHT, function()
	setFlying(not flying)
	flyBtn.Text = "Fly: " .. (flying and "ON" or "OFF")
	setToggleLook(flyBtn, flying)
end)
onFlyReset = function()
	flyBtn.Text = "Fly: OFF"
	setToggleLook(flyBtn, false)
end

local noclipBtn: TextButton
noclipBtn = makeButton("Noclip: OFF", ROW_HEIGHT, function()
	setNoclip(not noclip)
	noclipBtn.Text = "Noclip: " .. (noclip and "ON" or "OFF")
	setToggleLook(noclipBtn, noclip)
end)
onNoclipReset = function()
	noclipBtn.Text = "Noclip: OFF"
	setToggleLook(noclipBtn, false)
end

-- Fly speed stepper: [ -  speed  + ]
local speedRow = Instance.new("Frame")
speedRow.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
speedRow.BackgroundTransparency = 1
speedRow.LayoutOrder = nextOrder()
speedRow.Parent = panel

local speedLayout = Instance.new("UIListLayout")
speedLayout.FillDirection = Enum.FillDirection.Horizontal
speedLayout.SortOrder = Enum.SortOrder.LayoutOrder
speedLayout.Padding = UDim.new(0, 4)
speedLayout.Parent = speedRow

local speedLabel: TextLabel
local function makeStepBtn(text: string, delta: number): TextButton
	local btn = UITheme.button(speedRow, text, ROW_HEIGHT)
	btn.Size = UDim2.new(0, ROW_HEIGHT, 1, 0)
	btn.FontFace = UITheme.Font.Mono
	btn.TextSize = 13
	btn.Activated:Connect(function()
		flySpeed = math.clamp(flySpeed + delta, 10, 400)
		speedLabel.Text = "Speed " .. flySpeed
	end)
	return btn
end

local minusBtn = makeStepBtn("-", -20)
minusBtn.LayoutOrder = 1

speedLabel = Instance.new("TextLabel")
speedLabel.Size = UDim2.new(1, -(ROW_HEIGHT * 2 + 8), 1, 0)
speedLabel.BackgroundTransparency = 1
speedLabel.FontFace = UITheme.Font.Mono
speedLabel.Text = "Speed " .. flySpeed
speedLabel.TextSize = 12
speedLabel.TextColor3 = COL_TEXT
speedLabel.LayoutOrder = 2
speedLabel.Parent = speedRow

local plusBtn = makeStepBtn("+", 20)
plusBtn.LayoutOrder = 3

--------------------------------------------------------------------------------
-- Cursor section
--------------------------------------------------------------------------------
makeLabel("CURSOR", COL_SUBTEXT, 10, 18)

local cursorBtn: TextButton
cursorBtn = makeButton("Cursor: LOCKED  [V]", ROW_HEIGHT, function()
	setCursorFree(not cursorFree)
end)

updateCursorLabel = function()
	cursorBtn.Text = "Cursor: " .. (cursorFree and "FREE" or "LOCKED") .. "  [V]"
	setToggleLook(cursorBtn, cursorFree)
end

local hint = makeLabel("Press V to click these buttons.", COL_SUBTEXT, 10, 16)
hint.FontFace = UITheme.Font.Regular

--------------------------------------------------------------------------------
-- Minimize / expand — collapse to just the header bar to get it out of the way.
--------------------------------------------------------------------------------
local minimized = false
local function setMinimized(m: boolean)
	minimized = m
	for _, child in panel:GetChildren() do
		if child:IsA("GuiObject") and child ~= headerRow then
			child.Visible = not m
		end
	end
	minimizeBtn.Text = if m then "+" else "-"
end
minimizeBtn.Activated:Connect(function()
	setMinimized(not minimized)
end)

print("[AdminPanel] Debug tools ready — press V to free the cursor.")
