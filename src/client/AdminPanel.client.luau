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
local COL_BG      = Color3.fromRGB(15, 18, 25)
local COL_STROKE  = Color3.fromRGB(50, 55, 70)
local COL_HEADER  = Color3.fromRGB(255, 80, 80)
local COL_PHASE   = Color3.fromRGB(60, 90, 160)
local COL_OFF     = Color3.fromRGB(45, 50, 62)
local COL_ON      = Color3.fromRGB(50, 150, 70)
local COL_TEXT    = Color3.fromRGB(230, 233, 240)
local COL_SUBTEXT = Color3.fromRGB(150, 160, 200)

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
	if free then
		localPlayer.CameraMode = Enum.CameraMode.Classic
		-- Min zoom must be > first-person distance, otherwise the camera stays pinned
		-- in first person and the mouse re-locks no matter the MouseBehavior. Forcing
		-- it out to third person is what actually frees the cursor.
		localPlayer.CameraMinZoomDistance = 10
		localPlayer.CameraMaxZoomDistance = 20
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	else
		localPlayer.CameraMinZoomDistance = 0.5
		localPlayer.CameraMaxZoomDistance = 0.5
		localPlayer.CameraMode = Enum.CameraMode.LockFirstPerson
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
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

-- Root panel, anchored to the right edge, vertically centred.
local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(1, 0.5)
panel.Position = UDim2.new(1, -8, 0.5, 0)
panel.Size = UDim2.new(0, 190, 0, 430)
panel.BackgroundColor3 = COL_BG
panel.BackgroundTransparency = 0.05
panel.BorderSizePixel = 0
panel.Parent = gui

local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0, 10)
panelCorner.Parent = panel

local panelStroke = Instance.new("UIStroke")
panelStroke.Color = COL_STROKE
panelStroke.Thickness = 1
panelStroke.Parent = panel

local pad = Instance.new("UIPadding")
pad.PaddingTop = UDim.new(0, 8)
pad.PaddingBottom = UDim.new(0, 8)
pad.PaddingLeft = UDim.new(0, 8)
pad.PaddingRight = UDim.new(0, 8)
pad.Parent = panel

local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Vertical
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Padding = UDim.new(0, 5)
layout.Parent = panel

local order = 0
local function nextOrder(): number
	order += 1
	return order
end

local function makeLabel(text: string, color: Color3, size: number, height: number): TextLabel
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0, height)
	label.Font = Enum.Font.GothamBold
	label.Text = text
	label.TextSize = size
	label.TextColor3 = color
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.LayoutOrder = nextOrder()
	label.Parent = panel
	return label
end

local function makeButton(text: string, color: Color3, height: number, onClick: () -> ()): TextButton
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, 0, 0, height)
	btn.BackgroundColor3 = color
	btn.BorderSizePixel = 0
	btn.AutoButtonColor = true
	btn.Font = Enum.Font.GothamMedium
	btn.Text = text
	btn.TextSize = 13
	btn.TextColor3 = COL_TEXT
	btn.LayoutOrder = nextOrder()
	btn.Parent = panel

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = btn

	btn.Activated:Connect(onClick)
	return btn
end

--------------------------------------------------------------------------------
-- Header (with a minimize toggle)
--------------------------------------------------------------------------------
local headerRow = Instance.new("Frame")
headerRow.Name = "HeaderRow"
headerRow.Size = UDim2.new(1, 0, 0, 22)
headerRow.BackgroundTransparency = 1
headerRow.LayoutOrder = nextOrder()
headerRow.Parent = panel

local headerLabel = Instance.new("TextLabel")
headerLabel.BackgroundTransparency = 1
headerLabel.Size = UDim2.new(1, -26, 1, 0)
headerLabel.Font = Enum.Font.GothamBold
headerLabel.Text = "🛠  ADMIN  ·  testing"
headerLabel.TextSize = 14
headerLabel.TextColor3 = COL_HEADER
headerLabel.TextXAlignment = Enum.TextXAlignment.Left
headerLabel.Parent = headerRow

local minimizeBtn = Instance.new("TextButton")
minimizeBtn.AnchorPoint = Vector2.new(1, 0.5)
minimizeBtn.Position = UDim2.new(1, 0, 0.5, 0)
minimizeBtn.Size = UDim2.new(0, 22, 0, 22)
minimizeBtn.BackgroundColor3 = COL_OFF
minimizeBtn.BorderSizePixel = 0
minimizeBtn.Font = Enum.Font.GothamBold
minimizeBtn.Text = "▾"
minimizeBtn.TextSize = 14
minimizeBtn.TextColor3 = COL_TEXT
minimizeBtn.Parent = headerRow
local mbCorner = Instance.new("UICorner")
mbCorner.CornerRadius = UDim.new(0, 6)
mbCorner.Parent = minimizeBtn

--------------------------------------------------------------------------------
-- Phase skip section ("jump to different times")
--------------------------------------------------------------------------------
makeLabel("SKIP TO PHASE", COL_SUBTEXT, 11, 16)

local PHASES = {
	{ name = "Lobby",            id = GameConfig.Phase.LOBBY },
	{ name = "Day 1 · dusk",     id = GameConfig.Phase.DAY1 },
	{ name = "Day 2 · daytime",  id = GameConfig.Phase.DAY2 },
	{ name = "Night 2 · 12 AM",  id = GameConfig.Phase.NIGHT2 },
	{ name = "Day 3 · ending",   id = GameConfig.Phase.DAY3 },
}

for _, phase in PHASES do
	makeButton(phase.name, COL_PHASE, 26, function()
		AdminCommand:FireServer({ cmd = "setPhase", phase = phase.id })
	end)
end

--------------------------------------------------------------------------------
-- Movement section
--------------------------------------------------------------------------------
makeLabel("MOVEMENT", COL_SUBTEXT, 11, 16)

local flyBtn: TextButton
flyBtn = makeButton("Fly: OFF", COL_OFF, 26, function()
	setFlying(not flying)
	flyBtn.Text = "Fly: " .. (flying and "ON" or "OFF")
	flyBtn.BackgroundColor3 = flying and COL_ON or COL_OFF
end)
onFlyReset = function()
	flyBtn.Text = "Fly: OFF"
	flyBtn.BackgroundColor3 = COL_OFF
end

local noclipBtn: TextButton
noclipBtn = makeButton("Noclip: OFF", COL_OFF, 26, function()
	setNoclip(not noclip)
	noclipBtn.Text = "Noclip: " .. (noclip and "ON" or "OFF")
	noclipBtn.BackgroundColor3 = noclip and COL_ON or COL_OFF
end)
onNoclipReset = function()
	noclipBtn.Text = "Noclip: OFF"
	noclipBtn.BackgroundColor3 = COL_OFF
end

-- Fly speed stepper: [ -  speed  + ]
local speedRow = Instance.new("Frame")
speedRow.Size = UDim2.new(1, 0, 0, 26)
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
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(0, 30, 1, 0)
	btn.BackgroundColor3 = COL_OFF
	btn.BorderSizePixel = 0
	btn.Font = Enum.Font.GothamBold
	btn.Text = text
	btn.TextSize = 16
	btn.TextColor3 = COL_TEXT
	btn.Parent = speedRow
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = btn
	btn.Activated:Connect(function()
		flySpeed = math.clamp(flySpeed + delta, 10, 400)
		speedLabel.Text = "Speed " .. flySpeed
	end)
	return btn
end

local minusBtn = makeStepBtn("−", -20)
minusBtn.LayoutOrder = 1

speedLabel = Instance.new("TextLabel")
speedLabel.Size = UDim2.new(1, -68, 1, 0)
speedLabel.BackgroundTransparency = 1
speedLabel.Font = Enum.Font.GothamMedium
speedLabel.Text = "Speed " .. flySpeed
speedLabel.TextSize = 13
speedLabel.TextColor3 = COL_TEXT
speedLabel.LayoutOrder = 2
speedLabel.Parent = speedRow

local plusBtn = makeStepBtn("+", 20)
plusBtn.LayoutOrder = 3

--------------------------------------------------------------------------------
-- Cursor section
--------------------------------------------------------------------------------
makeLabel("CURSOR", COL_SUBTEXT, 11, 16)

local cursorBtn: TextButton
cursorBtn = makeButton("Cursor: LOCKED  [V]", COL_OFF, 26, function()
	setCursorFree(not cursorFree)
end)

updateCursorLabel = function()
	cursorBtn.Text = "Cursor: " .. (cursorFree and "FREE" or "LOCKED") .. "  [V]"
	cursorBtn.BackgroundColor3 = cursorFree and COL_ON or COL_OFF
end

makeLabel("Press V to click these buttons.", COL_SUBTEXT, 10, 14)

--------------------------------------------------------------------------------
-- Minimize / expand — collapse to just the header bar to get it out of the way.
--------------------------------------------------------------------------------
local EXPANDED_SIZE = panel.Size
local minimized = false
local function setMinimized(m: boolean)
	minimized = m
	for _, child in panel:GetChildren() do
		if child:IsA("GuiObject") and child ~= headerRow then
			child.Visible = not m
		end
	end
	panel.Size = if m then UDim2.new(0, 190, 0, 38) else EXPANDED_SIZE
	minimizeBtn.Text = if m then "▸" else "▾"
end
minimizeBtn.Activated:Connect(function()
	setMinimized(not minimized)
end)

print("[AdminPanel] Debug tools ready — press V to free the cursor.")
