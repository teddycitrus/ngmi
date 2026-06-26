--!strict
--------------------------------------------------------------------------------
-- StaminaController.client.luau
-- Sprint + energy system for Not Gonna Make It.
--
-- Responsibilities:
--   • Draw an energy bar in the bottom-left corner of the screen
--   • Hold Left/Right Shift to sprint while energy remains (drains energy)
--   • Regenerate energy when not sprinting (after a short delay)
--   • Drive the player's WalkSpeed between the walk / sprint values
--   • Publish a "Sprinting" attribute on the LocalPlayer so CameraController can
--     switch its sway from gentle (walk) to rapid (sprint)
--   • Refill energy to full when the server reports an energy bar was eaten
--
-- Design notes:
--   • This script is the authority on the local character's WalkSpeed for normal
--     movement. It only writes WalkSpeed on sprint-state transitions, and never
--     overrides an external freeze (e.g. NPCDialogue sets WalkSpeed = 0), so
--     scripted cutscene/dialogue locks keep working.
--   • WalkSpeed set on the client replicates to the server, which is exactly how
--     the NGMI AI "hears" sprinting players (it checks WalkSpeed > base).
--------------------------------------------------------------------------------

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local EnergyRefilled = Remotes:WaitForChild("EnergyRefilled") :: RemoteEvent

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

--------------------------------------------------------------------------------
-- Tunables
--------------------------------------------------------------------------------

local MAX_ENERGY = 100
local DRAIN_PER_SEC = 22 -- ~4.5 seconds of sprint from full
local REGEN_PER_SEC = 14
local REGEN_DELAY = 0.8 -- seconds after sprinting before energy starts refilling
local MIN_ENERGY_TO_START = 8 -- must have at least this much to begin sprinting again

local BASE_WALK = GameConfig.Player.walkSpeed -- 16
local SPRINT_WALK = GameConfig.Player.sprintSpeed -- 24

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local energy: number = MAX_ENERGY
local sprintHeld: boolean = false
local isSprinting: boolean = false
local timeSinceSprint: number = 0

--------------------------------------------------------------------------------
-- Energy Bar UI (bottom-left corner)
--------------------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "StaminaHUD"
gui.DisplayOrder = 15
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = playerGui

local frame = Instance.new("Frame")
frame.Name = "EnergyFrame"
frame.Size = UDim2.new(0, 220, 0, 44)
frame.Position = UDim2.new(0, 16, 1, -16)
frame.AnchorPoint = Vector2.new(0, 1)
frame.BackgroundColor3 = Color3.fromRGB(15, 18, 25)
frame.BackgroundTransparency = 0.2
frame.BorderSizePixel = 0
frame.Parent = gui

local frameCorner = Instance.new("UICorner")
frameCorner.CornerRadius = UDim.new(0, 8)
frameCorner.Parent = frame

local frameStroke = Instance.new("UIStroke")
frameStroke.Color = Color3.fromRGB(50, 55, 70)
frameStroke.Thickness = 1
frameStroke.Parent = frame

-- Label row: lightning icon + ENERGY text
local label = Instance.new("TextLabel")
label.Name = "Label"
label.Size = UDim2.new(1, -16, 0, 14)
label.Position = UDim2.new(0, 10, 0, 4)
label.BackgroundTransparency = 1
label.Text = "⚡ ENERGY"
label.TextSize = 11
label.Font = Enum.Font.GothamBold
label.TextXAlignment = Enum.TextXAlignment.Left
label.TextColor3 = Color3.fromRGB(180, 190, 210)
label.Parent = frame

-- Bar background
local barBg = Instance.new("Frame")
barBg.Name = "BarBg"
barBg.Size = UDim2.new(1, -20, 0, 14)
barBg.Position = UDim2.new(0, 10, 1, -8)
barBg.AnchorPoint = Vector2.new(0, 1)
barBg.BackgroundColor3 = Color3.fromRGB(20, 24, 32)
barBg.BorderSizePixel = 0
barBg.Parent = frame

local barBgCorner = Instance.new("UICorner")
barBgCorner.CornerRadius = UDim.new(0, 4)
barBgCorner.Parent = barBg

-- Bar fill
local barFill = Instance.new("Frame")
barFill.Name = "BarFill"
barFill.Size = UDim2.new(1, 0, 1, 0)
barFill.BackgroundColor3 = Color3.fromRGB(80, 220, 255)
barFill.BorderSizePixel = 0
barFill.Parent = barBg

local barFillCorner = Instance.new("UICorner")
barFillCorner.CornerRadius = UDim.new(0, 4)
barFillCorner.Parent = barFill

local barGradient = Instance.new("UIGradient")
barGradient.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(120, 235, 255)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(40, 170, 230)),
})
barGradient.Parent = barFill

--------------------------------------------------------------------------------
-- UI update
--------------------------------------------------------------------------------

local FULL_COLOR = Color3.fromRGB(80, 220, 255)
local LOW_COLOR = Color3.fromRGB(255, 90, 70)
local SPRINT_COLOR = Color3.fromRGB(255, 210, 80)

local function updateBar()
	local pct = math.clamp(energy / MAX_ENERGY, 0, 1)
	barFill.Size = UDim2.new(pct, 0, 1, 0)

	if pct < 0.25 then
		barFill.BackgroundColor3 = LOW_COLOR
	elseif isSprinting then
		barFill.BackgroundColor3 = SPRINT_COLOR
	else
		barFill.BackgroundColor3 = FULL_COLOR
	end
end

--------------------------------------------------------------------------------
-- Character / humanoid helpers
--------------------------------------------------------------------------------

local function getHumanoid(): Humanoid?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChildOfClass("Humanoid")
end

--- Apply (or release) the sprint state, writing WalkSpeed and the shared attribute.
local function setSprintState(on: boolean)
	isSprinting = on
	player:SetAttribute("Sprinting", on)

	local humanoid = getHumanoid()
	if not humanoid then
		return
	end

	if on then
		humanoid.WalkSpeed = SPRINT_WALK
	else
		-- Never override an external freeze (dialogue/cutscene sets WalkSpeed = 0)
		if humanoid.WalkSpeed > 0 then
			humanoid.WalkSpeed = BASE_WALK
		end
	end
end

--------------------------------------------------------------------------------
-- Per-frame sprint / energy logic
--------------------------------------------------------------------------------

RunService.Heartbeat:Connect(function(dt: number)
	local humanoid = getHumanoid()
	local moving = humanoid ~= nil and humanoid.MoveDirection.Magnitude > 0.1
	-- Detect an external freeze: WalkSpeed pinned to 0 while we aren't sprinting
	local frozen = humanoid ~= nil and humanoid.WalkSpeed <= 0 and not isSprinting

	local wantSprint = sprintHeld and moving and energy > 0 and humanoid ~= nil and not frozen

	-- Once depleted, require a small buffer before sprint can re-engage
	if not isSprinting and energy < MIN_ENERGY_TO_START then
		wantSprint = false
	end

	if wantSprint then
		if not isSprinting then
			setSprintState(true)
		end
		energy = math.max(0, energy - DRAIN_PER_SEC * dt)
		timeSinceSprint = 0
		if energy <= 0 then
			setSprintState(false)
		end
	else
		if isSprinting then
			setSprintState(false)
		end
		timeSinceSprint += dt
		if timeSinceSprint >= REGEN_DELAY and energy < MAX_ENERGY then
			energy = math.min(MAX_ENERGY, energy + REGEN_PER_SEC * dt)
		end
	end

	updateBar()
end)

--------------------------------------------------------------------------------
-- Input: hold Shift to sprint
--------------------------------------------------------------------------------

local function isSprintKey(input: InputObject): boolean
	return input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift
end

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if isSprintKey(input) then
		sprintHeld = true
	end
end)

UserInputService.InputEnded:Connect(function(input: InputObject)
	-- Always clear on key-up (even if gameProcessed) so sprint never sticks
	if isSprintKey(input) then
		sprintHeld = false
	end
end)

--------------------------------------------------------------------------------
-- Character lifecycle — reset base speed and sprint state on (re)spawn
--------------------------------------------------------------------------------

local function onCharacterAdded(character: Model)
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.WalkSpeed = BASE_WALK
	isSprinting = false
	player:SetAttribute("Sprinting", false)
end

if player.Character then
	task.spawn(onCharacterAdded, player.Character)
end
player.CharacterAdded:Connect(onCharacterAdded)

--------------------------------------------------------------------------------
-- Energy bar consumed → refill stamina to full
--------------------------------------------------------------------------------

EnergyRefilled.OnClientEvent:Connect(function()
	energy = MAX_ENERGY
	updateBar()

	-- Quick green flash on the bar as feedback
	local prevColor = barFill.BackgroundColor3
	barFill.BackgroundColor3 = Color3.fromRGB(120, 255, 140)
	TweenService:Create(barFill, TweenInfo.new(0.4, Enum.EasingStyle.Quad), {
		BackgroundColor3 = prevColor,
	}):Play()
end)

-- Initialize
player:SetAttribute("Sprinting", false)
updateBar()

print("[StaminaController] Initialized — hold Shift to sprint")
