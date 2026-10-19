--!strict
--------------------------------------------------------------------------------
-- InventoryManager.server.luau
-- Server-authoritative inventory system for Not Gonna Make It.
--
-- Responsibilities:
--   • Maintain per-player inventory (4 slots)
--   • Handle item pickup, use, drop with full server validation
--   • Spawn interactable item models at ItemSpawn tagged locations
--   • Fire InventoryUpdated to clients on any state change
--   • Item effects: deodorant spray, energy bar buff, flashlight toggle
--------------------------------------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")

local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

-- Remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PickupItem = Remotes:WaitForChild("PickupItem") :: RemoteEvent
local UseItem = Remotes:WaitForChild("UseItem") :: RemoteEvent
local DropItem = Remotes:WaitForChild("DropItem") :: RemoteEvent
local InventoryUpdated = Remotes:WaitForChild("InventoryUpdated") :: RemoteEvent
local DeodorantSpray = Remotes:WaitForChild("DeodorantSpray") :: RemoteEvent
local FlashlightRecharge = Remotes:WaitForChild("FlashlightRecharge") :: RemoteEvent
local EnergyRefilled = Remotes:WaitForChild("EnergyRefilled") :: RemoteEvent
local EquipItem = Remotes:WaitForChild("EquipItem") :: RemoteEvent

-- Server bus: announce a weapon use so QuestManager (Poop Monster fight) can
-- react to deodorant/plunger swings without the fragile client-targeting path.
local ServerStorage = game:GetService("ServerStorage")
local serverComm = ServerStorage:FindFirstChild("ServerComm")
if not serverComm then
	serverComm = Instance.new("Folder")
	serverComm.Name = "ServerComm"
	serverComm.Parent = ServerStorage
end
local WeaponUsedBus: BindableEvent
do
	local found = serverComm:FindFirstChild("WeaponUsed")
	if found and found:IsA("BindableEvent") then
		WeaponUsedBus = found
	else
		WeaponUsedBus = Instance.new("BindableEvent")
		WeaponUsedBus.Name = "WeaponUsed"
		WeaponUsedBus.Parent = serverComm
	end
end

-- Server bus: let other systems (quest rewards, etc.) drop items straight into a
-- player's inventory. Fire with (player, itemId, count).
local GrantItemBus: BindableEvent
do
	local found = serverComm:FindFirstChild("GrantItem")
	if found and found:IsA("BindableEvent") then
		GrantItemBus = found
	else
		GrantItemBus = Instance.new("BindableEvent")
		GrantItemBus.Name = "GrantItem"
		GrantItemBus.Parent = serverComm
	end
end

-- Server bus: announce that a player actually picked a world item up, so quest
-- systems can count it. (Pickups happen through the prompt's server-side Triggered
-- handler, NOT the PickupItem remote, so listeners must use this bus.) (player, itemId)
local ItemPickedUpBus: BindableEvent
do
	local found = serverComm:FindFirstChild("ItemPickedUp")
	if found and found:IsA("BindableEvent") then
		ItemPickedUpBus = found
	else
		ItemPickedUpBus = Instance.new("BindableEvent")
		ItemPickedUpBus.Name = "ItemPickedUp"
		ItemPickedUpBus.Parent = serverComm
	end
end

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

type InventorySlot = {
	itemId: string,
	count: number,
	ammo: number?, -- current ammo for ammo-based items (nil = not applicable)
}

type PlayerInventory = { InventorySlot? } -- 4 slots, nil = empty

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

-- 4 as specified in the game design (GameConfig has 6 but design says 4)
local MAX_SLOTS = 4

-- Server-side pacing for weapon uses. Each accepted use fires WeaponUsed (boss
-- damage, NGMI hit confirmation) and a DeodorantSpray broadcast to every
-- client, so a forged UseItem loop must not be able to repeat it faster than a
-- real swing or spray. Melee matches the plunger slash (0.08 s in, 0.2 s back)
-- plus a beat; sprays are also bounded by ammo.
local WEAPON_COOLDOWN: { [string]: number } = { melee = 0.5, spray = 0.4 }
local lastWeaponUse: { [Player]: number } = {}

local playerInventories: { [Player]: PlayerInventory } = {}

-- Track active speed buff threads so we can cancel on death/leave
local activeBuffs: { [Player]: { thread } } = {}

-- World item references for cleanup
local worldItems: { [string]: Model } = {} -- keyed by unique item instance id
local nextItemId = 0

--------------------------------------------------------------------------------
-- Inventory API
--------------------------------------------------------------------------------

--- Notify client of full inventory state
local function syncInventory(player: Player)
	local inv = playerInventories[player]
	if not inv then return end
	InventoryUpdated:FireClient(player, inv)
end

--- Initialize empty inventory for a player
local function initInventory(player: Player)
	local inv: PlayerInventory = table.create(MAX_SLOTS)
	for i = 1, MAX_SLOTS do
		inv[i] = nil
	end
	playerInventories[player] = inv
	activeBuffs[player] = {}
end

--- Get the item definition from ItemConfig
local function getItemDef(itemId: string): ItemConfig.ItemDefinition?
	return ItemConfig.items[itemId]
end

--- Find first empty slot index, or nil if full
local function findEmptySlot(inv: PlayerInventory): number?
	for i = 1, MAX_SLOTS do
		if inv[i] == nil then
			return i
		end
	end
	return nil
end

--- Find a slot with the same item that can stack
local function findStackableSlot(inv: PlayerInventory, itemId: string): number?
	local def = getItemDef(itemId)
	if not def or def.maxStack <= 1 then return nil end

	for i = 1, MAX_SLOTS do
		local slot = inv[i]
		if slot and slot.itemId == itemId and slot.count < def.maxStack then
			return i
		end
	end
	return nil
end

--- Add an item to a player's inventory. Returns true on success.
local function addItem(player: Player, itemId: string): boolean
	local inv = playerInventories[player]
	if not inv then return false end

	local def = getItemDef(itemId)
	if not def then
		warn("[InventoryManager] Unknown item:", itemId)
		return false
	end

	-- Try to stack first
	local stackSlot = findStackableSlot(inv, itemId)
	if stackSlot then
		local slot = inv[stackSlot] :: InventorySlot
		slot.count += 1
		syncInventory(player)
		return true
	end

	-- Try to find empty slot
	local emptySlot = findEmptySlot(inv)
	if not emptySlot then
		-- Inventory full
		return false
	end

	-- Create new slot
	local newSlot: InventorySlot = {
		itemId = itemId,
		count = 1,
		ammo = def.ammoCapacity, -- nil for non-ammo items
	}
	inv[emptySlot] = newSlot

	syncInventory(player)
	return true
end

--- Remove an item from a specific slot. Returns true on success.
local function removeItem(player: Player, slotIndex: number): boolean
	local inv = playerInventories[player]
	if not inv then return false end
	if slotIndex < 1 or slotIndex > MAX_SLOTS then return false end

	local slot = inv[slotIndex]
	if not slot then return false end

	if slot.count > 1 then
		slot.count -= 1
	else
		inv[slotIndex] = nil
	end

	syncInventory(player)
	return true
end

--------------------------------------------------------------------------------
-- Held plunger (server-side, replicated to everyone)
-- The plunger is a classic-sword melee weapon. While a player has it selected
-- (the client tells us via EquipItem) we weld a plunger model into their right
-- hand so EVERY client sees it. Using it (click/tap) swings it forward, and the
-- swing is server-driven so it replicates too. Once the Poop Monster dies, every
-- plunger is wiped from the game.
--------------------------------------------------------------------------------

local heldPlungers: { [Player]: Model } = {}
local plungerWelds: { [Player]: Weld } = {}
local plungerSwinging: { [Player]: boolean } = {}
local equippedPlunger: { [Player]: boolean } = {}
local plungersBanished = false -- set once the boss dies; no plunger may reappear

local PLUNGER_GRIP = CFrame.new(0, -0.1, -1.0) * CFrame.Angles(math.rad(-95), 0, 0)
local PLUNGER_SLASH = CFrame.new(0, 0.25, -1.1) * CFrame.Angles(math.rad(-172), 0, 0)

local function hasPlunger(player: Player): boolean
	local inv = playerInventories[player]
	if not inv then
		return false
	end
	for i = 1, MAX_SLOTS do
		local slot = inv[i]
		if slot and slot.itemId == "plunger" then
			return true
		end
	end
	return false
end

local function buildPlungerModel(): Model
	local model = Instance.new("Model")
	model.Name = "HeldPlunger"

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.18, 2.1, 0.18)
	handle.Color = Color3.fromRGB(120, 80, 45)
	handle.Material = Enum.Material.Wood
	handle.CanCollide = false
	handle.CanQuery = false
	handle.CanTouch = false
	handle.Massless = true
	handle.Parent = model

	local cup = Instance.new("Part")
	cup.Name = "Cup"
	cup.Shape = Enum.PartType.Ball
	cup.Size = Vector3.new(0.9, 0.8, 0.9)
	cup.Color = Color3.fromRGB(150, 45, 45)
	cup.Material = Enum.Material.SmoothPlastic
	cup.CanCollide = false
	cup.CanQuery = false
	cup.CanTouch = false
	cup.Massless = true
	cup.Parent = model

	local cupWeld = Instance.new("Weld")
	cupWeld.Part0 = handle
	cupWeld.Part1 = cup
	cupWeld.C0 = CFrame.new(0, 1.0, 0)
	cupWeld.Parent = cup

	model.PrimaryPart = handle
	return model
end

local function getRightHand(char: Model): BasePart?
	local h = char:FindFirstChild("RightHand") or char:FindFirstChild("Right Arm")
	return h :: BasePart?
end

local function detachPlunger(player: Player)
	local model = heldPlungers[player]
	if model then
		model:Destroy()
	end
	heldPlungers[player] = nil
	plungerWelds[player] = nil
	plungerSwinging[player] = nil
end

local function attachPlunger(player: Player)
	if plungersBanished or heldPlungers[player] then
		return
	end
	if not hasPlunger(player) then
		return
	end
	local char = player.Character
	if not char then
		return
	end
	local hand = getRightHand(char)
	if not hand then
		return
	end

	local model = buildPlungerModel()
	local handle = model.PrimaryPart :: BasePart
	local weld = Instance.new("Weld")
	weld.Part0 = hand
	weld.Part1 = handle
	weld.C0 = PLUNGER_GRIP
	weld.Parent = handle
	model.Parent = char

	heldPlungers[player] = model
	plungerWelds[player] = weld
end

--- Show or stow the plunger based on what the player currently has selected.
local function refreshPlunger(player: Player)
	if equippedPlunger[player] and not plungersBanished and hasPlunger(player) then
		attachPlunger(player)
	else
		detachPlunger(player)
	end
end

--- Server-driven forward slash (replicates to every client).
local function swingPlunger(player: Player)
	local weld = plungerWelds[player]
	if not weld or plungerSwinging[player] then
		return
	end
	plungerSwinging[player] = true
	local swing = TweenService:Create(weld, TweenInfo.new(0.08, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
		C0 = PLUNGER_SLASH,
	})
	swing:Play()
	swing.Completed:Once(function()
		local recover = TweenService:Create(weld, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			C0 = PLUNGER_GRIP,
		})
		recover:Play()
		recover.Completed:Once(function()
			plungerSwinging[player] = false
		end)
	end)
end

--- Wipe every plunger from the game once the Poop Monster is defeated.
local function banishAllPlungers()
	if plungersBanished then
		return
	end
	plungersBanished = true
	for _, plr in Players:GetPlayers() do
		detachPlunger(plr)
		local inv = playerInventories[plr]
		if inv then
			local changed = false
			for i = 1, MAX_SLOTS do
				local slot = inv[i]
				if slot and slot.itemId == "plunger" then
					inv[i] = nil
					changed = true
				end
			end
			if changed then
				syncInventory(plr)
			end
		end
	end
	-- Sweep any plunger pickups still lying in the world.
	for id, model in worldItems do
		local part = model.PrimaryPart
		if part and part:GetAttribute("ItemId") == "plunger" then
			model:Destroy()
			worldItems[id] = nil
		end
	end
end

-- The client tells us which item it currently has selected. Each change can
-- rebuild the held plunger, so changes are applied at most every
-- EQUIP_INTERVAL; one arriving sooner is deferred (never dropped), so the
-- server always ends on the client's latest selection.
local EQUIP_INTERVAL = 0.15
local lastEquipApply: { [Player]: number } = {}
local pendingEquip: { [Player]: boolean } = {}

local function applyEquip(player: Player)
	local wantsPlunger = pendingEquip[player]
	pendingEquip[player] = nil
	if wantsPlunger == nil or not player.Parent then
		return
	end
	lastEquipApply[player] = os.clock()
	equippedPlunger[player] = wantsPlunger
	refreshPlunger(player)
end

EquipItem.OnServerEvent:Connect(function(player: Player, data: any)
	local itemId = typeof(data) == "table" and data.itemId or nil
	local alreadyQueued = pendingEquip[player] ~= nil
	pendingEquip[player] = (itemId == "plunger")
	if alreadyQueued then
		return
	end
	local wait = EQUIP_INTERVAL - (os.clock() - (lastEquipApply[player] or 0))
	if wait <= 0 then
		applyEquip(player)
	else
		task.delay(wait, applyEquip, player)
	end
end)

-- React to the Poop Monster dying (QuestManager fires this on ServerComm).
do
	local found = serverComm:FindFirstChild("PoopMonsterDefeated")
	local bus: BindableEvent
	if found and found:IsA("BindableEvent") then
		bus = found
	else
		bus = Instance.new("BindableEvent")
		bus.Name = "PoopMonsterDefeated"
		bus.Parent = serverComm
	end
	bus.Event:Connect(banishAllPlungers)
end

--------------------------------------------------------------------------------
-- Item Use Effects
--------------------------------------------------------------------------------

--- Handle deodorant / axe spray usage
local function useSprayItem(player: Player, slotIndex: number, slot: InventorySlot, def: ItemConfig.ItemDefinition)
	if not def.sprayCost then return end
	local ammo = slot.ammo or 0
	if ammo < def.sprayCost then
		-- Not enough ammo
		return
	end

	-- Decrement ammo
	slot.ammo = ammo - def.sprayCost

	-- If ammo reaches 0, remove the item
	if (slot.ammo :: number) <= 0 then
		local inv = playerInventories[player]
		if inv then
			inv[slotIndex] = nil
		end
	end

	-- Fire spray event to all clients for VFX + NGMI stun logic
	DeodorantSpray:FireAllClients({
		playerId = player.UserId,
		itemId = def.id,
		stunDuration = def.stunDuration or 2,
		stunRadius = def.stunRadius or 12,
		position = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			and (player.Character.HumanoidRootPart :: Part).Position or Vector3.zero,
	})

	-- Let the Poop Monster fight react to the spray (staggers the boss).
	WeaponUsedBus:Fire(player, def.id, "spray")

	syncInventory(player)
end

--- Handle energy bar usage — refills the player's sprint energy.
--- WalkSpeed itself is owned by the client-side StaminaController (which manages
--- the hold-Shift sprint), so the server just consumes the item and tells the
--- client to top its energy bar back up to full.
local function useEnergyBar(player: Player, slotIndex: number, _slot: InventorySlot, _def: ItemConfig.ItemDefinition)
	-- Remove from inventory (consumable)
	removeItem(player, slotIndex)

	-- Tell the client to refill its sprint energy
	EnergyRefilled:FireClient(player)
end

--- Handle battery — recharges the phone flashlight to a full 80s charge.
local function useBattery(player: Player, slotIndex: number, _slot: InventorySlot, _def: ItemConfig.ItemDefinition)
	-- Consume the battery and tell the client to top its flashlight up.
	removeItem(player, slotIndex)
	FlashlightRecharge:FireClient(player)
end

--- Handle melee weapon (chair leg / plunger)
local function useMeleeItem(player: Player, _slotIndex: number, _slot: InventorySlot, def: ItemConfig.ItemDefinition)
	-- Fire stun event (similar to spray but melee range)
	DeodorantSpray:FireAllClients({
		playerId = player.UserId,
		itemId = def.id,
		stunDuration = def.stunDuration or 1.5,
		stunRadius = def.stunRadius or 6,
		position = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			and (player.Character.HumanoidRootPart :: Part).Position or Vector3.zero,
		isMelee = true,
	})

	-- Let the Poop Monster fight react to the swing (the plunger's damage).
	WeaponUsedBus:Fire(player, def.id, "melee")

	-- The plunger swings like a sword; server-driven so every client sees it.
	if def.id == "plunger" then
		swingPlunger(player)
	end
end

--- Main use item handler
local function useItem(player: Player, slotIndex: number)
	local inv = playerInventories[player]
	if not inv then return end
	if slotIndex < 1 or slotIndex > MAX_SLOTS then return end

	local slot = inv[slotIndex]
	if not slot then return end

	local def = getItemDef(slot.itemId)
	if not def or not def.isUsable then return end

	local effect = def.useEffect
	local cooldown = effect and WEAPON_COOLDOWN[effect]
	if cooldown then
		local now = os.clock()
		if now - (lastWeaponUse[player] or -math.huge) < cooldown then
			return
		end
		lastWeaponUse[player] = now
	end

	if effect == "spray" then
		useSprayItem(player, slotIndex, slot, def)
	elseif effect == "speed_buff" then
		useEnergyBar(player, slotIndex, slot, def)
	elseif effect == "recharge_flashlight" then
		useBattery(player, slotIndex, slot, def)
	elseif effect == "melee" then
		useMeleeItem(player, slotIndex, slot, def)
	else
		warn("[InventoryManager] Unknown use effect:", effect)
	end
end

--------------------------------------------------------------------------------
-- Item Drop — spawn a world model at player's feet
--------------------------------------------------------------------------------

local function dropItem(player: Player, slotIndex: number)
	local inv = playerInventories[player]
	if not inv then return end
	if slotIndex < 1 or slotIndex > MAX_SLOTS then return end

	local slot = inv[slotIndex]
	if not slot then return end

	local def = getItemDef(slot.itemId)
	if not def then return end

	-- Get player position
	local character = player.Character
	if not character then return end
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: Part?
	if not rootPart then return end

	-- Remove from inventory
	local itemId = slot.itemId
	local droppedAmmo = slot.ammo
	removeItem(player, slotIndex)

	-- Spawn world item at player's feet
	local dropPos = rootPart.Position + rootPart.CFrame.LookVector * ItemConfig.dropOffset.Z
		+ Vector3.new(0, ItemConfig.dropOffset.Y, 0)

	spawnWorldItem(itemId, dropPos, droppedAmmo)
end

--------------------------------------------------------------------------------
-- World Item Spawning
-- Builds a small, recognizable model for each pickup (instead of a labelled box)
-- with a ProximityPrompt for pickup.
--------------------------------------------------------------------------------

-- Shapes the interactable `part` into the item's main body and welds on a couple
-- of accent parts so a pickup actually looks like what it is. `part` stays the
-- ItemPart (prompt + attributes); accents are decorative, non-colliding children.
local function styleItemPickup(model: Model, part: BasePart, itemId: string, position: Vector3)
	local upright = CFrame.Angles(0, 0, math.rad(90)) -- stands a Cylinder part on its end
	local function accent(name: string, shape: Enum.PartType, size: Vector3, dy: number, color: Color3, mat: Enum.Material, stand: boolean?): BasePart
		local p = Instance.new("Part")
		p.Name = name
		p.Shape = shape
		p.Size = size
		p.Color = color
		p.Material = mat
		p.Anchored = true
		p.CanCollide = false
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.CFrame = CFrame.new(position + Vector3.new(0, dy, 0)) * (stand and upright or CFrame.new())
		p.Parent = model
		return p
	end

	if itemId == "deodorant" or itemId == "axe_spray" then
		local tall = itemId == "axe_spray"
		local bodyH = tall and 2.0 or 1.6
		local dia = tall and 1.2 or 1.0
		part.Shape = Enum.PartType.Cylinder
		part.Size = Vector3.new(bodyH, dia, dia)
		part.Material = Enum.Material.SmoothPlastic
		part.CFrame = CFrame.new(position) * upright
		accent("Band", Enum.PartType.Cylinder, Vector3.new(0.45, dia * 1.03, dia * 1.03), 0, tall and Color3.fromRGB(180, 30, 30) or Color3.fromRGB(235, 235, 240), Enum.Material.SmoothPlastic, true)
		accent("Cap", Enum.PartType.Cylinder, Vector3.new(0.5, dia * 0.9, dia * 0.9), bodyH / 2 + 0.22, Color3.fromRGB(40, 40, 45), Enum.Material.SmoothPlastic, true)
		accent("Nozzle", Enum.PartType.Block, Vector3.new(0.28, 0.28, 0.28), bodyH / 2 + 0.52, Color3.fromRGB(225, 225, 230), Enum.Material.SmoothPlastic)
	elseif itemId == "battery" then
		local h = 1.4
		part.Shape = Enum.PartType.Cylinder
		part.Size = Vector3.new(h, 0.7, 0.7)
		part.Color = Color3.fromRGB(60, 175, 85)
		part.Material = Enum.Material.SmoothPlastic
		part.CFrame = CFrame.new(position) * upright
		accent("Plus", Enum.PartType.Cylinder, Vector3.new(0.16, 0.34, 0.34), h / 2 + 0.07, Color3.fromRGB(180, 180, 185), Enum.Material.Metal, true)
		accent("Band", Enum.PartType.Cylinder, Vector3.new(0.32, 0.72, 0.72), h * 0.16, Color3.fromRGB(28, 28, 30), Enum.Material.SmoothPlastic, true)
	elseif itemId == "plunger" then
		part.Shape = Enum.PartType.Cylinder
		part.Size = Vector3.new(2.6, 0.28, 0.28)
		part.Color = Color3.fromRGB(120, 80, 45)
		part.Material = Enum.Material.Wood
		part.CFrame = CFrame.new(position + Vector3.new(0, 0.6, 0)) * upright
		accent("Cup", Enum.PartType.Cylinder, Vector3.new(0.9, 1.5, 1.5), -0.7, Color3.fromRGB(150, 45, 45), Enum.Material.SmoothPlastic, true)
	elseif itemId == "energy_bar" then
		part.Shape = Enum.PartType.Block
		part.Size = Vector3.new(1.6, 0.45, 0.8)
		part.Color = Color3.fromRGB(70, 50, 35)
		part.Material = Enum.Material.SmoothPlastic
		accent("Wrapper", Enum.PartType.Block, Vector3.new(0.55, 0.5, 0.85), 0, Color3.fromRGB(200, 60, 60), Enum.Material.SmoothPlastic)
	elseif itemId == "chair_leg" then
		part.Shape = Enum.PartType.Cylinder
		part.Size = Vector3.new(3, 0.4, 0.4)
		part.Color = Color3.fromRGB(160, 120, 80)
		part.Material = Enum.Material.Metal
		part.CFrame = CFrame.new(position) * upright
	end
end

function spawnWorldItem(itemId: string, position: Vector3, ammo: number?): Model?
	local def = getItemDef(itemId)
	if not def then return nil end

	nextItemId += 1
	local instanceId = "item_" .. tostring(nextItemId)

	-- Create item model
	local model = Instance.new("Model")
	model.Name = instanceId

	-- Main pickup Part — the interactable body (prompt + attributes live here).
	local part = Instance.new("Part")
	part.Name = "ItemPart"
	part.Size = def.modelSize
	part.Color = def.modelColor
	part.Material = Enum.Material.SmoothPlastic
	part.Anchored = true
	part.CanCollide = true
	part.CFrame = CFrame.new(position)
	part.Parent = model

	part:SetAttribute("ItemId", itemId)
	part:SetAttribute("InstanceId", instanceId)
	if ammo then
		part:SetAttribute("Ammo", ammo)
	end

	-- Shape it into a recognizable little model (can, battery, plunger, …).
	styleItemPickup(model, part, itemId, position)

	-- BillboardGui so the item's name floats above it, visible from any angle
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "ItemBillboard"
	billboard.Adornee = part
	billboard.Size = UDim2.new(0, 150, 0, 30)
	billboard.StudsOffset = Vector3.new(0, 2, 0)
	billboard.AlwaysOnTop = false
	billboard.MaxDistance = 20
	billboard.Parent = part

	local billboardLabel = Instance.new("TextLabel")
	billboardLabel.Size = UDim2.new(1, 0, 1, 0)
	billboardLabel.BackgroundTransparency = 1
	billboardLabel.Text = def.icon .. " " .. def.displayName
	billboardLabel.TextColor3 = Color3.new(1, 1, 1)
	billboardLabel.TextStrokeTransparency = 0.3
	billboardLabel.Font = Enum.Font.GothamBold
	billboardLabel.TextScaled = true
	billboardLabel.Parent = billboard

	-- ProximityPrompt for pickup
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "PickupPrompt"
	prompt.ActionText = "Pick up " .. def.displayName
	prompt.ObjectText = def.displayName
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = ItemConfig.pickupProximityDistance
	-- No line-of-sight requirement: the item's own accent parts (e.g. the
	-- deodorant's label band wrapping the body) sit between the camera and the
	-- ItemPart, which would otherwise block the pickup prompt entirely.
	prompt.RequiresLineOfSight = false
	prompt.Parent = part

	-- Tag for InteractionManager
	CollectionService:AddTag(part, GameConfig.TAGS.ITEM_SPAWN)

	-- Wire up pickup
	prompt.Triggered:Connect(function(triggerPlayer: Player)
		handlePickup(triggerPlayer, instanceId)
	end)

	model.PrimaryPart = part
	model.Parent = workspace

	worldItems[instanceId] = model
	return model
end

--------------------------------------------------------------------------------
-- Pickup Handler (with server-side validation)
--------------------------------------------------------------------------------

function handlePickup(player: Player, instanceId: string)
	-- Validate world item exists
	local model = worldItems[instanceId]
	if not model or not model.Parent then return end

	local part = model:FindFirstChild("ItemPart") :: Part?
	if not part then return end

	local itemId = part:GetAttribute("ItemId") :: string?
	if not itemId then return end

	-- Validate player proximity
	local character = player.Character
	if not character then return end
	local rootPart = character:FindFirstChild("HumanoidRootPart") :: Part?
	if not rootPart then return end

	local distance = (rootPart.Position - part.Position).Magnitude
	if distance > ItemConfig.pickupProximityDistance + 2 then -- small tolerance
		return
	end

	-- Attempt to add to inventory
	-- Pass ammo if the item had it
	local success = addItem(player, itemId)
	if not success then
		-- Inventory full — could fire a notification to client
		return
	end

	-- If item had custom ammo (e.g. partially used spray), restore it
	local savedAmmo = part:GetAttribute("Ammo") :: number?
	if savedAmmo then
		local inv = playerInventories[player]
		if inv then
			-- Find the slot we just added to
			for i = 1, MAX_SLOTS do
				local slot = inv[i]
				if slot and slot.itemId == itemId then
					slot.ammo = savedAmmo
					break
				end
			end
			syncInventory(player)
		end
	end

	-- Destroy world item
	model:Destroy()
	worldItems[instanceId] = nil

	-- Tell quest systems an item was actually scavenged.
	ItemPickedUpBus:Fire(player, itemId)
end

--------------------------------------------------------------------------------
-- Remote Event Handlers
--------------------------------------------------------------------------------

-- GrantItem: another server system (e.g. a quest reward) drops items straight
-- into the player's inventory.
GrantItemBus.Event:Connect(function(player: Player, itemId: string, count: number?)
	if typeof(player) ~= "Instance" or typeof(itemId) ~= "string" then
		return
	end
	for _ = 1, math.max(1, count or 1) do
		addItem(player, itemId)
	end
end)

-- PickupItem: client requests to pick up a specific world item
PickupItem.OnServerEvent:Connect(function(player: Player, data: any)
	if typeof(data) ~= "table" then return end
	local instanceId = data.instanceId :: string?
	if not instanceId then return end

	handlePickup(player, instanceId)
end)

-- UseItem: client requests to use item in a specific slot
UseItem.OnServerEvent:Connect(function(player: Player, data: any)
	if typeof(data) ~= "table" then return end
	local slotIndex = data.slotIndex :: number?
	if not slotIndex then return end

	useItem(player, math.floor(slotIndex))
end)

-- DropItem: client requests to drop item from a specific slot
DropItem.OnServerEvent:Connect(function(player: Player, data: any)
	if typeof(data) ~= "table" then return end
	local slotIndex = data.slotIndex :: number?
	if not slotIndex then return end

	dropItem(player, math.floor(slotIndex))
end)

--------------------------------------------------------------------------------
-- Player Lifecycle
--------------------------------------------------------------------------------

Players.PlayerAdded:Connect(function(player: Player)
	initInventory(player)

	-- Send initial empty inventory
	-- (delayed slightly to ensure client is ready)
	task.delay(1, function()
		syncInventory(player)
	end)

	-- Re-weld the held plunger onto each fresh character (the old model dies with
	-- the old one). equippedPlunger persists across respawns.
	player.CharacterAdded:Connect(function(char)
		detachPlunger(player)
		task.spawn(function()
			char:WaitForChild("HumanoidRootPart", 10)
			task.wait(0.2)
			refreshPlunger(player)
		end)
	end)
end)

Players.PlayerRemoving:Connect(function(player: Player)
	-- Cancel active buff threads
	local buffs = activeBuffs[player]
	if buffs then
		for _, buffThread in buffs do
			task.cancel(buffThread)
		end
	end
	detachPlunger(player)
	equippedPlunger[player] = nil
	lastWeaponUse[player] = nil
	lastEquipApply[player] = nil
	pendingEquip[player] = nil
	activeBuffs[player] = nil
	playerInventories[player] = nil
end)

-- Handle players already in game (studio testing)
for _, existingPlayer in Players:GetPlayers() do
	if not playerInventories[existingPlayer] then
		initInventory(existingPlayer)
	end
end

--------------------------------------------------------------------------------
-- Item Spawn Point Initialization
-- Finds all parts tagged with 'ItemSpawn' and spawns items at their positions.
-- ItemSpawn parts should have an "ItemId" attribute specifying which item.
--------------------------------------------------------------------------------

local function initializeItemSpawnPoints()
	local spawnPoints = CollectionService:GetTagged(GameConfig.TAGS.ITEM_SPAWN)
	local spawnCount = 0

	for _, spawnPart in spawnPoints do
		if not spawnPart:IsA("BasePart") then continue end

		local itemId = spawnPart:GetAttribute("ItemId") :: string?
		if not itemId then continue end

		-- Don't double-spawn if part already has a prompt (already processed)
		if spawnPart:FindFirstChild("PickupPrompt") then continue end

		-- Use the spawn part's position, then make the spawn marker invisible
		spawnWorldItem(itemId, spawnPart.Position, nil)
		spawnPart.Transparency = 1
		spawnPart.CanCollide = false

		spawnCount += 1
	end

	-- Also listen for new spawn points added at runtime
	CollectionService:GetInstanceAddedSignal(GameConfig.TAGS.ITEM_SPAWN):Connect(function(instance: Instance)
		if not instance:IsA("BasePart") then return end
		local itemId = instance:GetAttribute("ItemId") :: string?
		if not itemId then return end
		if instance:FindFirstChild("PickupPrompt") then return end

		spawnWorldItem(itemId, instance.Position, nil)
		instance.Transparency = 1
		instance.CanCollide = false
	end)

	print("[InventoryManager] Spawned items at", spawnCount, "spawn points")
end

-- Initialize on a slight delay to allow map to load
task.delay(2, initializeItemSpawnPoints)

print("[InventoryManager] Initialized — server-authoritative inventory system ready")
