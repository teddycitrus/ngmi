--!strict
--------------------------------------------------------------------------------
-- InventoryUI.client.luau
-- Client-side inventory hotbar for Not Gonna Make It.
--
-- Responsibilities:
--   • Display 4-slot hotbar at bottom-center of screen
--   • Show item icons (emoji), stack counts, ammo bars
--   • Keybinds: 1-4 to select, E or Click to use
--   • Mobile: tap to select, tap again or USE button to use
--   • Circular ammo meter for spray weapons
--   • Smooth tween animations on item changes
--   • Listen to InventoryUpdated remote for state sync
--------------------------------------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)

-- Remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local InventoryUpdated = Remotes:WaitForChild("InventoryUpdated") :: RemoteEvent
local UseItem = Remotes:WaitForChild("UseItem") :: RemoteEvent
local DropItem = Remotes:WaitForChild("DropItem") :: RemoteEvent

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local SLOT_COUNT = 4
local SLOT_SIZE = 60
local SLOT_PADDING = 8
local SLOT_CORNER_RADIUS = 8
local HOTBAR_BOTTOM_OFFSET = 30

-- Colors
local SLOT_BG_COLOR = Color3.fromRGB(30, 30, 40)
local SLOT_BG_SELECTED = Color3.fromRGB(45, 30, 30)
local SLOT_BORDER_COLOR = Color3.fromRGB(60, 60, 70)
local SLOT_BORDER_SELECTED = Color3.fromRGB(220, 50, 50) -- bright red glow
local SLOT_NUMBER_COLOR = Color3.fromRGB(150, 150, 160)
local STACK_COUNT_COLOR = Color3.new(1, 1, 1)
local AMMO_BAR_BG_COLOR = Color3.fromRGB(20, 20, 20)
local AMMO_BAR_FILL_COLOR = Color3.fromRGB(80, 200, 80)
local AMMO_BAR_LOW_COLOR = Color3.fromRGB(220, 60, 60)
local USE_BUTTON_COLOR = Color3.fromRGB(200, 50, 50)
local USE_BUTTON_TEXT_COLOR = Color3.new(1, 1, 1)

-- Animation
local TWEEN_QUICK = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local TWEEN_BOUNCE = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)

-- Mobile detection
local IS_MOBILE = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

type InventorySlot = {
	itemId: string,
	count: number,
	ammo: number?,
}

type SlotUI = {
	frame: Frame,
	iconLabel: TextLabel,
	stackLabel: TextLabel,
	numberLabel: TextLabel,
	ammoBarBg: Frame,
	ammoBarFill: Frame,
	stroke: UIStroke,
	ammoMeterBg: Frame?, -- circular meter background
	ammoMeterFrames: { Frame }?, -- segments of circular meter
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local selectedSlot: number = 1
local currentInventory: { InventorySlot? } = {}
local slotUIs: { SlotUI } = {}
local screenGui: ScreenGui
local hotbarFrame: Frame
local useButton: TextButton? = nil

--------------------------------------------------------------------------------
-- GUI Construction
--------------------------------------------------------------------------------

local function createHotbarGui()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "InventoryHotbarGui"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 50
	screenGui.IgnoreGuiInset = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = playerGui

	-- Hotbar container centered at bottom
	local totalWidth = SLOT_COUNT * SLOT_SIZE + (SLOT_COUNT - 1) * SLOT_PADDING
	hotbarFrame = Instance.new("Frame")
	hotbarFrame.Name = "Hotbar"
	hotbarFrame.Size = UDim2.new(0, totalWidth, 0, SLOT_SIZE)
	hotbarFrame.Position = UDim2.new(0.5, 0, 1, -HOTBAR_BOTTOM_OFFSET)
	hotbarFrame.AnchorPoint = Vector2.new(0.5, 1)
	hotbarFrame.BackgroundTransparency = 1
	hotbarFrame.Parent = screenGui

	-- Layout for horizontal slot arrangement
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, SLOT_PADDING)
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = hotbarFrame

	-- Create slots
	for i = 1, SLOT_COUNT do
		local slotUI = createSlot(i)
		table.insert(slotUIs, slotUI)
	end

	-- Mobile USE button (only on touch devices)
	if IS_MOBILE then
		createUseButton()
	end
end

function createSlot(index: number): SlotUI
	local frame = Instance.new("Frame")
	frame.Name = "Slot_" .. tostring(index)
	frame.Size = UDim2.new(0, SLOT_SIZE, 0, SLOT_SIZE)
	frame.BackgroundColor3 = SLOT_BG_COLOR
	frame.BackgroundTransparency = 0.15
	frame.LayoutOrder = index
	frame.Parent = hotbarFrame

	-- Rounded corners
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, SLOT_CORNER_RADIUS)
	corner.Parent = frame

	-- Border stroke (changes color when selected)
	local stroke = Instance.new("UIStroke")
	stroke.Color = SLOT_BORDER_COLOR
	stroke.Thickness = 2
	stroke.Transparency = 0.3
	stroke.Parent = frame

	-- Slot number label (top-left corner)
	local numberLabel = Instance.new("TextLabel")
	numberLabel.Name = "SlotNumber"
	numberLabel.Size = UDim2.new(0, 16, 0, 16)
	numberLabel.Position = UDim2.new(0, 3, 0, 2)
	numberLabel.BackgroundTransparency = 1
	numberLabel.Text = tostring(index)
	numberLabel.TextColor3 = SLOT_NUMBER_COLOR
	numberLabel.Font = Enum.Font.GothamBold
	numberLabel.TextSize = 11
	numberLabel.TextXAlignment = Enum.TextXAlignment.Left
	numberLabel.TextYAlignment = Enum.TextYAlignment.Top
	numberLabel.Parent = frame

	-- Item icon (emoji text in center)
	local iconLabel = Instance.new("TextLabel")
	iconLabel.Name = "ItemIcon"
	iconLabel.Size = UDim2.new(1, -8, 1, -16)
	iconLabel.Position = UDim2.new(0.5, 0, 0.45, 0)
	iconLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	iconLabel.BackgroundTransparency = 1
	iconLabel.Text = ""
	iconLabel.TextColor3 = Color3.new(1, 1, 1)
	iconLabel.Font = Enum.Font.GothamBold
	iconLabel.TextScaled = true
	iconLabel.Parent = frame

	-- Stack count (bottom-right corner)
	local stackLabel = Instance.new("TextLabel")
	stackLabel.Name = "StackCount"
	stackLabel.Size = UDim2.new(0, 20, 0, 16)
	stackLabel.Position = UDim2.new(1, -3, 1, -3)
	stackLabel.AnchorPoint = Vector2.new(1, 1)
	stackLabel.BackgroundTransparency = 1
	stackLabel.Text = ""
	stackLabel.TextColor3 = STACK_COUNT_COLOR
	stackLabel.TextStrokeTransparency = 0.3
	stackLabel.Font = Enum.Font.GothamBold
	stackLabel.TextSize = 13
	stackLabel.TextXAlignment = Enum.TextXAlignment.Right
	stackLabel.TextYAlignment = Enum.TextYAlignment.Bottom
	stackLabel.Visible = false
	stackLabel.Parent = frame

	-- Ammo bar (thin bar at bottom of slot)
	local ammoBarBg = Instance.new("Frame")
	ammoBarBg.Name = "AmmoBarBg"
	ammoBarBg.Size = UDim2.new(0.85, 0, 0, 4)
	ammoBarBg.Position = UDim2.new(0.5, 0, 1, -6)
	ammoBarBg.AnchorPoint = Vector2.new(0.5, 1)
	ammoBarBg.BackgroundColor3 = AMMO_BAR_BG_COLOR
	ammoBarBg.BackgroundTransparency = 0.3
	ammoBarBg.Visible = false
	ammoBarBg.Parent = frame

	local ammoBarCorner = Instance.new("UICorner")
	ammoBarCorner.CornerRadius = UDim.new(0, 2)
	ammoBarCorner.Parent = ammoBarBg

	local ammoBarFill = Instance.new("Frame")
	ammoBarFill.Name = "AmmoFill"
	ammoBarFill.Size = UDim2.new(1, 0, 1, 0)
	ammoBarFill.BackgroundColor3 = AMMO_BAR_FILL_COLOR
	ammoBarFill.Parent = ammoBarBg

	local ammoFillCorner = Instance.new("UICorner")
	ammoFillCorner.CornerRadius = UDim.new(0, 2)
	ammoFillCorner.Parent = ammoBarFill

	-- Click handler (mobile: tap to select, tap again to use)
	local clickButton = Instance.new("TextButton")
	clickButton.Name = "ClickTarget"
	clickButton.Size = UDim2.new(1, 0, 1, 0)
	clickButton.BackgroundTransparency = 1
	clickButton.Text = ""
	clickButton.Parent = frame

	clickButton.Activated:Connect(function()
		if selectedSlot == index then
			-- Already selected — use the item (mobile behavior)
			if IS_MOBILE then
				useSelectedItem()
			end
		else
			selectSlot(index)
		end
	end)

	return {
		frame = frame,
		iconLabel = iconLabel,
		stackLabel = stackLabel,
		numberLabel = numberLabel,
		ammoBarBg = ammoBarBg,
		ammoBarFill = ammoBarFill,
		stroke = stroke,
		ammoMeterBg = nil,
		ammoMeterFrames = nil,
	}
end

function createUseButton()
	local btn = Instance.new("TextButton")
	btn.Name = "UseButton"
	btn.Size = UDim2.new(0, 80, 0, 44)
	btn.Position = UDim2.new(0.5, 0, 1, -(HOTBAR_BOTTOM_OFFSET + SLOT_SIZE + 12))
	btn.AnchorPoint = Vector2.new(0.5, 1)
	btn.BackgroundColor3 = USE_BUTTON_COLOR
	btn.BackgroundTransparency = 0.1
	btn.Text = "USE"
	btn.TextColor3 = USE_BUTTON_TEXT_COLOR
	btn.Font = Enum.Font.GothamBold
	btn.TextSize = 18
	btn.Visible = false -- hidden until usable item selected
	btn.Parent = screenGui

	local btnCorner = Instance.new("UICorner")
	btnCorner.CornerRadius = UDim.new(0, 10)
	btnCorner.Parent = btn

	local btnStroke = Instance.new("UIStroke")
	btnStroke.Color = Color3.fromRGB(255, 100, 100)
	btnStroke.Thickness = 2
	btnStroke.Transparency = 0.3
	btnStroke.Parent = btn

	btn.Activated:Connect(function()
		useSelectedItem()
	end)

	useButton = btn
end

--------------------------------------------------------------------------------
-- Circular Ammo Meter (shown around selected slot for spray weapons)
-- Creates a visual ring of small segments around the slot frame.
--------------------------------------------------------------------------------

local METER_SEGMENTS = 20
local METER_RADIUS = SLOT_SIZE / 2 + 6

local ammoMeterContainer: Frame? = nil
local ammoMeterSegments: { Frame } = {}

local function createAmmoMeter()
	if ammoMeterContainer then return end

	local container = Instance.new("Frame")
	container.Name = "AmmoMeter"
	container.Size = UDim2.new(0, SLOT_SIZE + 16, 0, SLOT_SIZE + 16)
	container.AnchorPoint = Vector2.new(0.5, 0.5)
	container.BackgroundTransparency = 1
	container.Visible = false
	container.Parent = screenGui

	for i = 1, METER_SEGMENTS do
		local angle = (i - 1) / METER_SEGMENTS * math.pi * 2 - math.pi / 2
		local x = math.cos(angle) * METER_RADIUS
		local y = math.sin(angle) * METER_RADIUS

		local seg = Instance.new("Frame")
		seg.Name = "Seg_" .. tostring(i)
		seg.Size = UDim2.new(0, 4, 0, 8)
		seg.Position = UDim2.new(0.5, x, 0.5, y)
		seg.AnchorPoint = Vector2.new(0.5, 0.5)
		seg.Rotation = math.deg(angle) + 90
		seg.BackgroundColor3 = AMMO_BAR_FILL_COLOR
		seg.Parent = container

		local segCorner = Instance.new("UICorner")
		segCorner.CornerRadius = UDim.new(0, 2)
		segCorner.Parent = seg

		table.insert(ammoMeterSegments, seg)
	end

	ammoMeterContainer = container
end

local function updateAmmoMeter(ammoPercent: number)
	if not ammoMeterContainer then return end

	local filledSegments = math.ceil(ammoPercent * METER_SEGMENTS)

	for i, seg in ammoMeterSegments do
		if i <= filledSegments then
			seg.BackgroundTransparency = 0
			-- Color: green → yellow → red based on percentage
			if ammoPercent > 0.5 then
				seg.BackgroundColor3 = AMMO_BAR_FILL_COLOR
			elseif ammoPercent > 0.2 then
				seg.BackgroundColor3 = Color3.fromRGB(220, 180, 40)
			else
				seg.BackgroundColor3 = AMMO_BAR_LOW_COLOR
			end
		else
			seg.BackgroundTransparency = 0.7
			seg.BackgroundColor3 = AMMO_BAR_BG_COLOR
		end
	end
end

local function positionAmmoMeter(slotIndex: number)
	if not ammoMeterContainer then return end
	if slotIndex < 1 or slotIndex > #slotUIs then return end

	local slotFrame = slotUIs[slotIndex].frame
	local absPos = slotFrame.AbsolutePosition
	local absSize = slotFrame.AbsoluteSize

	ammoMeterContainer.Position = UDim2.new(
		0, absPos.X + absSize.X / 2,
		0, absPos.Y + absSize.Y / 2
	)
end

--------------------------------------------------------------------------------
-- Slot Selection
--------------------------------------------------------------------------------

function selectSlot(index: number)
	if index < 1 or index > SLOT_COUNT then return end

	local prevSlot = selectedSlot
	selectedSlot = index

	-- Deselect previous
	if prevSlot >= 1 and prevSlot <= #slotUIs then
		local prevUI = slotUIs[prevSlot]
		TweenService:Create(prevUI.stroke, TWEEN_QUICK, {
			Color = SLOT_BORDER_COLOR,
			Thickness = 2,
		}):Play()
		TweenService:Create(prevUI.frame, TWEEN_QUICK, {
			BackgroundColor3 = SLOT_BG_COLOR,
			Size = UDim2.new(0, SLOT_SIZE, 0, SLOT_SIZE),
		}):Play()
	end

	-- Select new
	local newUI = slotUIs[index]
	TweenService:Create(newUI.stroke, TWEEN_QUICK, {
		Color = SLOT_BORDER_SELECTED,
		Thickness = 3,
	}):Play()
	TweenService:Create(newUI.frame, TWEEN_BOUNCE, {
		BackgroundColor3 = SLOT_BG_SELECTED,
		Size = UDim2.new(0, SLOT_SIZE + 4, 0, SLOT_SIZE + 4),
	}):Play()

	-- Update ammo meter visibility
	updateAmmoMeterForSlot(index)

	-- Update USE button visibility (mobile)
	updateUseButtonVisibility()
end

function updateAmmoMeterForSlot(slotIndex: number)
	createAmmoMeter() -- ensure it exists

	local slot = currentInventory[slotIndex]
	if not slot then
		if ammoMeterContainer then
			ammoMeterContainer.Visible = false
		end
		return
	end

	local def = ItemConfig.items[slot.itemId]
	if not def or not def.ammoCapacity or not slot.ammo then
		if ammoMeterContainer then
			ammoMeterContainer.Visible = false
		end
		return
	end

	-- Show ammo meter for spray weapons
	if def.isWeapon and def.sprayCost then
		if ammoMeterContainer then
			ammoMeterContainer.Visible = true
			positionAmmoMeter(slotIndex)
			updateAmmoMeter(slot.ammo / def.ammoCapacity)
		end
	else
		if ammoMeterContainer then
			ammoMeterContainer.Visible = false
		end
	end
end

function updateUseButtonVisibility()
	if not useButton then return end

	local slot = currentInventory[selectedSlot]
	if slot then
		local def = ItemConfig.items[slot.itemId]
		if def and def.isUsable then
			useButton.Visible = true
			return
		end
	end
	useButton.Visible = false
end

--------------------------------------------------------------------------------
-- Use Selected Item
--------------------------------------------------------------------------------

function useSelectedItem()
	local slot = currentInventory[selectedSlot]
	if not slot then return end

	local def = ItemConfig.items[slot.itemId]
	if not def or not def.isUsable then return end

	UseItem:FireServer({ slotIndex = selectedSlot })
end

--------------------------------------------------------------------------------
-- Inventory Display Update
-- Called when InventoryUpdated fires from server.
--------------------------------------------------------------------------------

local function updateSlotDisplay(index: number, slot: InventorySlot?)
	if index < 1 or index > #slotUIs then return end
	local ui = slotUIs[index]

	if not slot then
		-- Empty slot
		ui.iconLabel.Text = ""
		ui.stackLabel.Visible = false
		ui.ammoBarBg.Visible = false

		-- Fade out animation
		TweenService:Create(ui.iconLabel, TWEEN_QUICK, {
			TextTransparency = 1,
		}):Play()
		return
	end

	local def = ItemConfig.items[slot.itemId]
	if not def then
		ui.iconLabel.Text = "?"
		return
	end

	-- Item icon
	local previousText = ui.iconLabel.Text
	ui.iconLabel.Text = def.icon

	-- Bounce animation when item changes
	if previousText ~= def.icon then
		ui.iconLabel.TextTransparency = 0.5
		TweenService:Create(ui.iconLabel, TWEEN_BOUNCE, {
			TextTransparency = 0,
		}):Play()

		-- Scale bounce on the frame
		local originalSize = (index == selectedSlot)
			and UDim2.new(0, SLOT_SIZE + 4, 0, SLOT_SIZE + 4)
			or UDim2.new(0, SLOT_SIZE, 0, SLOT_SIZE)

		ui.frame.Size = UDim2.new(0, SLOT_SIZE - 6, 0, SLOT_SIZE - 6)
		TweenService:Create(ui.frame, TWEEN_BOUNCE, {
			Size = originalSize,
		}):Play()
	else
		ui.iconLabel.TextTransparency = 0
	end

	-- Stack count (only if > 1)
	if slot.count > 1 then
		ui.stackLabel.Text = tostring(slot.count)
		ui.stackLabel.Visible = true
	else
		ui.stackLabel.Visible = false
	end

	-- Ammo bar (for weapon items with ammo)
	if def.ammoCapacity and slot.ammo then
		ui.ammoBarBg.Visible = true
		local ammoPercent = slot.ammo / def.ammoCapacity

		TweenService:Create(ui.ammoBarFill, TWEEN_QUICK, {
			Size = UDim2.new(math.clamp(ammoPercent, 0, 1), 0, 1, 0),
			BackgroundColor3 = if ammoPercent > 0.3 then AMMO_BAR_FILL_COLOR else AMMO_BAR_LOW_COLOR,
		}):Play()
	else
		ui.ammoBarBg.Visible = false
	end

	-- Update ammo meter if this is the selected slot
	if index == selectedSlot then
		updateAmmoMeterForSlot(index)
	end
end

local function refreshInventoryDisplay(inventory: { any })
	for i = 1, SLOT_COUNT do
		local slot = inventory[i]
		currentInventory[i] = slot :: InventorySlot?
		updateSlotDisplay(i, slot)
	end

	-- Update USE button visibility
	updateUseButtonVisibility()
end

--------------------------------------------------------------------------------
-- Input Handling
--------------------------------------------------------------------------------

-- Key number map
local KEY_SLOT_MAP: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
}

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then return end

	-- Number keys to select slots
	local slotIndex = KEY_SLOT_MAP[input.KeyCode]
	if slotIndex then
		selectSlot(slotIndex)
		return
	end

	-- E key to use selected item
	if input.KeyCode == Enum.KeyCode.E then
		useSelectedItem()
		return
	end

	-- Q key to drop selected item
	if input.KeyCode == Enum.KeyCode.Q then
		local slot = currentInventory[selectedSlot]
		if slot then
			DropItem:FireServer({ slotIndex = selectedSlot })
		end
		return
	end

	-- Left click to use (when not over GUI): weapons spray, consumables (e.g. the
	-- energy bar) get eaten. Batteries are excluded so a stray click doesn't waste
	-- one — press E to consume a battery deliberately.
	if input.UserInputType == Enum.UserInputType.MouseButton1 then
		local slot = currentInventory[selectedSlot]
		if slot then
			local def = ItemConfig.items[slot.itemId]
			if def and def.isUsable and def.useEffect ~= "recharge_flashlight" then
				useSelectedItem()
			end
		end
	end
end)

--------------------------------------------------------------------------------
-- Remote Event Listener
--------------------------------------------------------------------------------

InventoryUpdated.OnClientEvent:Connect(function(inventory: any)
	if typeof(inventory) ~= "table" then return end
	refreshInventoryDisplay(inventory)
end)

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

createHotbarGui()
createAmmoMeter()
selectSlot(1) -- start with slot 1 selected

-- Reposition ammo meter after a frame (AbsolutePosition needs a render cycle)
task.defer(function()
	positionAmmoMeter(selectedSlot)

	-- Also reposition on window resize
	hotbarFrame:GetPropertyChangedSignal("AbsolutePosition"):Connect(function()
		if ammoMeterContainer and ammoMeterContainer.Visible then
			positionAmmoMeter(selectedSlot)
		end
	end)
end)

print("[InventoryUI] Client hotbar initialized —", if IS_MOBILE then "mobile mode" else "desktop mode")
