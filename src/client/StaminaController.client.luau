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
--   • Press C to toggle crouch: slower walk, no sprint. Publishes "Crouching"
--     on the LocalPlayer and replicates it to the character via the
--     CrouchState remote so CharacterAnimator can pose the body for everyone
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
local UITheme = require(ReplicatedStorage.Shared.UITheme)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local EnergyRefilled = Remotes:WaitForChild("EnergyRefilled") :: RemoteEvent
local CrouchState = Remotes:WaitForChild("CrouchState") :: RemoteEvent

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
local CROUCH_WALK = 6

local CROUCH_KEY = Enum.KeyCode.C
-- Standing up needs this much free space above the head, or the player stays
-- down (no popping up through a desk).
local STAND_CLEARANCE = 2.2

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local energy: number = MAX_ENERGY
local sprintHeld: boolean = false
local isSprinting: boolean = false
local timeSinceSprint: number = 0
local isCrouching: boolean = false

--------------------------------------------------------------------------------
-- Energy Bar UI (bottom-left corner)
--------------------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "StaminaHUD"
gui.DisplayOrder = 15
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.Parent = playerGui

-- Hairline meter in the bottom-left corner; FlashlightController stacks its
-- battery meter directly above this one.
local meter = UITheme.meter(gui, "Energy", 180)
local frame = meter.root
frame.Name = "EnergyFrame"
frame.AnchorPoint = Vector2.new(0, 1)
frame.Position = UDim2.new(0, UITheme.Margin, 1, -UITheme.Margin)
local barFill = meter.fill

--------------------------------------------------------------------------------
-- UI update
--------------------------------------------------------------------------------

local FULL_COLOR = UITheme.Color.Text
local LOW_COLOR = UITheme.Color.Danger
local SPRINT_COLOR = UITheme.Color.Warn

local shownPct: number? = nil -- last value written to the fill and the attribute

local function updateBar()
	local pct = math.clamp(energy / MAX_ENERGY, 0, 1)
	if pct ~= shownPct then
		shownPct = pct
		barFill.Size = UDim2.new(pct, 0, 1, 0)

		-- Publish alongside the existing "Sprinting" attribute so other client systems
		-- (HUDController's heartbeat vignette) can read exhaustion without duplicating
		-- the sprint model or reaching into this script.
		player:SetAttribute("Energy", pct)
	end

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
			humanoid.WalkSpeed = if isCrouching then CROUCH_WALK else BASE_WALK
		end
	end
end

--- True when there is room above the character to stand back up.
local function hasStandClearance(): boolean
	local character = player.Character
	local head = character and character:FindFirstChild("Head") :: BasePart?
	if not head then
		return true
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character :: Model }
	return workspace:Raycast(head.Position, Vector3.new(0, STAND_CLEARANCE, 0), params) == nil
end

--- Enter or leave crouch. Writes WalkSpeed under the same freeze rule as sprint.
local function setCrouchState(on: boolean)
	if on == isCrouching then
		return
	end
	if not on and not hasStandClearance() then
		return
	end
	isCrouching = on
	if on and isSprinting then
		setSprintState(false)
	end
	player:SetAttribute("Crouching", on)
	CrouchState:FireServer(on)

	local humanoid = getHumanoid()
	if humanoid and humanoid.WalkSpeed > 0 and not isSprinting then
		humanoid.WalkSpeed = if on then CROUCH_WALK else BASE_WALK
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

	local wantSprint = sprintHeld and moving and energy > 0 and humanoid ~= nil and not frozen and not isCrouching

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
	elseif input.KeyCode == CROUCH_KEY then
		setCrouchState(not isCrouching)
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
	-- A fresh character always spawns standing.
	isCrouching = false
	player:SetAttribute("Crouching", false)
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
	barFill.BackgroundColor3 = UITheme.Color.Good
	TweenService:Create(barFill, TweenInfo.new(0.4, Enum.EasingStyle.Quad), {
		BackgroundColor3 = prevColor,
	}):Play()
end)

-- Initialize
player:SetAttribute("Sprinting", false)
updateBar()

print("[StaminaController] Initialized — hold Shift to sprint")
