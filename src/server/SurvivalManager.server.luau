--!strict
--[[
	SurvivalManager.server.luau
	===========================
	Server-side Night 2 survival orchestrator for "Not Gonna Make It".

	Responsibilities:
	  1. Health System     – track per-player HP, handle damage/death/respawn
	  2. Hiding System     – validate hiding spots, toggle player visibility
	  3. Sabotage Events   – periodic zone power outages + repair flow
	  4. Deodorant Combat  – server-authoritative spray validation & NGMI stun

	Activates exclusively during the NIGHT2 phase and cleans up on phase change.
	All gameplay-critical state lives here; clients are purely presentational.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local ItemConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ItemConfig"))

----------------------------------------------------------------------
-- Remote references
----------------------------------------------------------------------
local Remotes = ReplicatedStorage:WaitForChild("Remotes") :: Folder

local GameStateChanged   = Remotes:WaitForChild("GameStateChanged") :: RemoteEvent
local PlayerDamaged      = Remotes:WaitForChild("PlayerDamaged") :: RemoteEvent
local PlayerDied         = Remotes:WaitForChild("PlayerDied") :: RemoteEvent
local PlayerRespawn      = Remotes:WaitForChild("PlayerRespawn") :: RemoteEvent
local HidingStateChanged = Remotes:WaitForChild("HidingStateChanged") :: RemoteEvent
local SabotageEvent      = Remotes:WaitForChild("SabotageEvent") :: RemoteEvent
local PanelRepaired      = Remotes:WaitForChild("PanelRepaired") :: RemoteEvent
local DeodorantSpray     = Remotes:WaitForChild("DeodorantSpray") :: RemoteEvent
local NGMIStunned        = Remotes:WaitForChild("NGMIStunned") :: RemoteEvent
local InventoryUpdated   = Remotes:WaitForChild("InventoryUpdated") :: RemoteEvent

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------
local MAX_HEALTH: number       = GameConfig.Player.maxHealth     -- 100
local RESPAWN_DELAY: number    = GameConfig.RESPAWN_DELAY        -- 3 seconds
local SABOTAGE_MIN: number     = GameConfig.Sabotage.intervalMin -- 180s
local SABOTAGE_MAX: number     = GameConfig.Sabotage.intervalMax -- 240s
local DEODORANT_RANGE: number  = GameConfig.Deodorant.range      -- 15 studs
local HIDING_SPOT_TAG: string  = GameConfig.TAGS.HIDING_SPOT
local ELECTRICAL_TAG: string   = GameConfig.TAGS.ELECTRICAL_PANEL
local CEILING_LIGHT_TAG: string = GameConfig.TAGS.CEILING_LIGHT
local PLAYER_DESK_TAG: string  = GameConfig.TAGS.PLAYER_DESK
local HIDING_PROXIMITY: number = 10  -- max studs from a HidingSpot to enter hiding

-- Night2 spawn position — players respawn here after death
local NIGHT2_SPAWN_POSITION: Vector3 = Vector3.new(0, 5, 0)

----------------------------------------------------------------------
-- Types
----------------------------------------------------------------------
export type PlayerSurvivalState = {
	health: number,
	isHiding: boolean,
	isDead: boolean,
}

export type SabotageState = {
	zoneIndex: number,
	zoneName: string,
	active: boolean,
	affectedLights: { PointLight },
	affectedDesks: { Model },
	originalBrightness: { [PointLight]: number },
}

----------------------------------------------------------------------
-- Module State
----------------------------------------------------------------------
-- Whether the survival systems are currently running (NIGHT2 active)
local isActive: boolean = false

-- Per-player survival data, keyed by UserId
local playerStates: { [number]: PlayerSurvivalState } = {}

-- Inventory data shadow — the authoritative inventory lives in
-- InventoryManager (server), but we keep a lightweight mirror here
-- so we can validate deodorant ammo without cross-module require.
-- Updated via the InventoryUpdated remote (server→client, but we
-- also write to this table when we deduct ammo).
local playerInventories: { [number]: { [string]: number } } = {}

-- Active sabotage events
local activeSabotages: { [number]: SabotageState } = {} -- zoneIndex → state

-- Electrical zone definitions. Each zone is a named region; lights
-- and desks are dynamically associated by proximity to zone center.
local ELECTRICAL_ZONES: { { name: string, center: Vector3, radius: number } } = {
	{ name = "Zone A - East Wing",   center = Vector3.new(60, 5, 0),   radius = 50 },
	{ name = "Zone B - West Wing",   center = Vector3.new(-60, 5, 0),  radius = 50 },
	{ name = "Zone C - Main Hall",   center = Vector3.new(0, 5, -30),  radius = 50 },
}

-- Thread reference for the sabotage timer so we can cancel it on deactivate
local sabotageThread: thread? = nil

----------------------------------------------------------------------
-- Utility
----------------------------------------------------------------------

--[[
	Returns the character model for a player, or nil if not spawned.
]]
local function getCharacter(player: Player): Model?
	return player.Character
end

--[[
	Returns the HumanoidRootPart of a player, or nil.
]]
local function getRootPart(player: Player): BasePart?
	local character = getCharacter(player)
	if character then
		return character:FindFirstChild("HumanoidRootPart") :: BasePart?
	end
	return nil
end

--[[
	Returns the Humanoid of a player, or nil.
]]
local function getHumanoid(player: Player): Humanoid?
	local character = getCharacter(player)
	if character then
		return character:FindFirstChildOfClass("Humanoid")
	end
	return nil
end

--[[
	Calculates a random sabotage interval between min and max.
]]
local function randomSabotageInterval(): number
	return SABOTAGE_MIN + math.random() * (SABOTAGE_MAX - SABOTAGE_MIN)
end

----------------------------------------------------------------------
-- Health System
----------------------------------------------------------------------

--[[
	Initializes survival state for a player at the start of Night 2.
	Health is set to max; hiding and death states are reset.
]]
local function initPlayerState(player: Player): ()
	playerStates[player.UserId] = {
		health = MAX_HEALTH,
		isHiding = false,
		isDead = false,
	}

	-- Initialize empty inventory shadow if not present
	if playerInventories[player.UserId] == nil then
		playerInventories[player.UserId] = {}
	end
end

--[[
	Applies damage to a player. Fires PlayerDamaged back to the client
	so the HUD can update. If health drops to 0, triggers death flow.

	Called when NGMIController detects a hit and fires PlayerDamaged
	from the server side (server→server call or direct invocation).
]]
local function applyDamage(player: Player, amount: number, sourceId: string?): ()
	if not isActive then return end

	local state = playerStates[player.UserId]
	if state == nil or state.isDead then return end

	-- Players cannot take damage while hiding
	if state.isHiding then return end

	state.health = math.max(0, state.health - amount)

	-- Notify the damaged client of their current health
	PlayerDamaged:FireClient(player, state.health, amount, sourceId or "unknown")

	if state.health <= 0 then
		state.isDead = true
		handlePlayerDeath(player)
	end
end

--[[
	Handles the death sequence: notify all clients, wait, then respawn.

	Respawn preserves:
	  - Inventory carried from Day 2
	  - Project completion progress from Day 2
	  - Quest progress

	Respawn resets:
	  - Health to 100
	  - Position to Night2 spawn
]]
function handlePlayerDeath(player: Player): ()
	-- Inform all clients so they can show death effects
	PlayerDied:FireAllClients(player.UserId)

	-- Make character invisible / ragdoll during respawn wait
	local character = getCharacter(player)
	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.Health = 0 -- trigger Roblox death animation
		end
	end

	-- Wait for respawn delay then bring them back
	task.delay(RESPAWN_DELAY, function()
		if not isActive then return end
		if not player.Parent then return end -- player left the game

		local state = playerStates[player.UserId]
		if state == nil then return end

		-- Reset health, clear death flag
		state.health = MAX_HEALTH
		state.isDead = false
		state.isHiding = false

		-- Respawn the character at Night2 spawn position
		-- Using LoadCharacter preserves Backpack / PlayerGui state
		player:LoadCharacter()

		-- Wait a frame for the character to load
		task.wait(0.1)

		local rootPart = getRootPart(player)
		if rootPart then
			rootPart.CFrame = CFrame.new(NIGHT2_SPAWN_POSITION)
		end

		-- Notify the respawned client
		PlayerRespawn:FireClient(player, MAX_HEALTH, NIGHT2_SPAWN_POSITION)
	end)
end

----------------------------------------------------------------------
-- Hiding System
----------------------------------------------------------------------

--[[
	Finds the nearest HidingSpot part to a given world position.
	Returns nil if no spot is within HIDING_PROXIMITY studs.
]]
local function findNearestHidingSpot(position: Vector3): BasePart?
	local hidingSpots = CollectionService:GetTagged(HIDING_SPOT_TAG)
	local nearest: BasePart? = nil
	local nearestDist: number = HIDING_PROXIMITY

	for _, part in hidingSpots do
		if part:IsA("BasePart") then
			local dist = (part.Position - position).Magnitude
			if dist < nearestDist then
				nearestDist = dist
				nearest = part :: BasePart
			end
		end
	end

	return nearest
end

--[[
	Sets character visibility by adjusting Transparency on all BaseParts.
	Used to make players invisible while hiding and visible when exiting.
]]
local function setCharacterVisible(character: Model, visible: boolean): ()
	local transparency: number = if visible then 0 else 1

	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			-- Preserve the HumanoidRootPart's default transparency
			if descendant.Name ~= "HumanoidRootPart" then
				descendant.Transparency = transparency
			end
		elseif descendant:IsA("Decal") or descendant:IsA("Texture") then
			descendant.Transparency = transparency
		end
	end

	-- Also hide accessories (hats, hair, etc.)
	for _, accessory in character:GetChildren() do
		if accessory:IsA("Accessory") then
			local handle = accessory:FindFirstChild("Handle")
			if handle and handle:IsA("BasePart") then
				handle.Transparency = transparency
			end
		end
	end
end

--[[
	Handles a client requesting to enter or exit a hiding spot.
	Validates proximity to a HidingSpot-tagged part before allowing.
]]
local function onHidingStateChanged(player: Player, wantsToHide: boolean): ()
	if not isActive then return end

	local state = playerStates[player.UserId]
	if state == nil or state.isDead then return end

	local character = getCharacter(player)
	if character == nil then return end

	local rootPart = getRootPart(player)
	if rootPart == nil then return end

	if wantsToHide then
		-- Validate proximity to a HidingSpot
		local spot = findNearestHidingSpot(rootPart.Position)
		if spot == nil then
			-- Not close enough to any hiding spot — reject silently
			return
		end

		state.isHiding = true
		setCharacterVisible(character, false)

		-- Anchor the character so they don't slide around while hiding
		rootPart.Anchored = true

		-- Broadcast hiding state so NGMIController can adjust detection
		HidingStateChanged:FireAllClients(player.UserId, true)
	else
		-- Exit hiding
		state.isHiding = false
		setCharacterVisible(character, true)

		-- Unanchor so the player can move again
		if rootPart then
			rootPart.Anchored = false
		end

		HidingStateChanged:FireAllClients(player.UserId, false)
	end
end

----------------------------------------------------------------------
-- Sabotage Events
----------------------------------------------------------------------

--[[
	Collects all PointLights in parts tagged with CeilingLight that
	fall within a zone's radius of its center.
]]
local function getLightsInZone(zoneCenter: Vector3, zoneRadius: number): { PointLight }
	local lights: { PointLight } = {}
	local taggedParts = CollectionService:GetTagged(CEILING_LIGHT_TAG)

	for _, part in taggedParts do
		if part:IsA("BasePart") then
			if (part.Position - zoneCenter).Magnitude <= zoneRadius then
				-- Collect all PointLights inside this part
				for _, child in part:GetDescendants() do
					if child:IsA("PointLight") then
						table.insert(lights, child :: PointLight)
					end
				end
				-- Also check if the part itself has a direct PointLight child
				local directLight = part:FindFirstChildOfClass("PointLight")
				-- Already caught by GetDescendants above, so skip duplication
			end
		end
	end

	return lights
end

--[[
	Collects all PlayerDesk models within a zone's radius.
]]
local function getDesksInZone(zoneCenter: Vector3, zoneRadius: number): { Model }
	local desks: { Model } = {}
	local taggedParts = CollectionService:GetTagged(PLAYER_DESK_TAG)

	for _, part in taggedParts do
		local position: Vector3
		if part:IsA("Model") then
			local primary = part.PrimaryPart
			if primary then
				position = primary.Position
			else
				-- Fallback to model origin
				position = part:GetPivot().Position
			end
		elseif part:IsA("BasePart") then
			position = (part :: BasePart).Position
		else
			continue
		end

		if (position - zoneCenter).Magnitude <= zoneRadius then
			if part:IsA("Model") then
				table.insert(desks, part :: Model)
			end
		end
	end

	return desks
end

--[[
	Triggers a sabotage event in a randomly chosen zone:
	  - Dims all PointLights (Brightness → 0)
	  - Disables laptop/desk functionality (sets "Sabotaged" attribute)
	  - Fires SabotageEvent remote to all clients with zone info
]]
local function triggerSabotage(): ()
	if not isActive then return end

	-- Pick a random zone that isn't already sabotaged
	local availableZones: { number } = {}
	for i, _ in ELECTRICAL_ZONES do
		if activeSabotages[i] == nil then
			table.insert(availableZones, i)
		end
	end

	if #availableZones == 0 then
		-- All zones already sabotaged — skip this cycle
		return
	end

	local zoneIndex = availableZones[math.random(1, #availableZones)]
	local zone = ELECTRICAL_ZONES[zoneIndex]

	-- Gather affected lights and desks
	local lights = getLightsInZone(zone.center, zone.radius)
	local desks = getDesksInZone(zone.center, zone.radius)

	-- Store original brightness values so we can restore them
	local originalBrightness: { [PointLight]: number } = {}
	for _, light in lights do
		originalBrightness[light] = light.Brightness
		light.Brightness = 0
	end

	-- Mark desks as sabotaged so CodingManager blocks progress
	for _, desk in desks do
		desk:SetAttribute("Sabotaged", true)
	end

	-- Record the sabotage state for repair resolution
	local sabotageState: SabotageState = {
		zoneIndex = zoneIndex,
		zoneName = zone.name,
		active = true,
		affectedLights = lights,
		affectedDesks = desks,
		originalBrightness = originalBrightness,
	}
	activeSabotages[zoneIndex] = sabotageState

	-- Notify all clients (UI alerts, zone markers, etc.)
	SabotageEvent:FireAllClients("sabotage_start", zoneIndex, zone.name)

	print("[SurvivalManager] Sabotage triggered in " .. zone.name)
end

--[[
	Resolves a sabotage event when a player repairs the corresponding
	ElectricalPanel. Restores lights and desk functionality.
]]
local function onPanelRepaired(player: Player, panelZoneIndex: number): ()
	if not isActive then return end
	if typeof(panelZoneIndex) ~= "number" then return end

	local sabotage = activeSabotages[panelZoneIndex]
	if sabotage == nil or not sabotage.active then return end

	-- Restore light brightness
	for light, brightness in sabotage.originalBrightness do
		if light and light.Parent then
			light.Brightness = brightness
		end
	end

	-- Clear sabotage flag on desks
	for _, desk in sabotage.affectedDesks do
		if desk and desk.Parent then
			desk:SetAttribute("Sabotaged", false)
		end
	end

	sabotage.active = false
	activeSabotages[panelZoneIndex] = nil

	-- Notify all clients that power is restored
	SabotageEvent:FireAllClients("sabotage_repaired", panelZoneIndex, sabotage.zoneName)
	print("[SurvivalManager] " .. player.Name .. " repaired " .. sabotage.zoneName)
end

--[[
	Main sabotage loop — runs on a background thread during NIGHT2.
	Fires sabotage events at random intervals.
]]
local function sabotageLoop(): ()
	while isActive do
		local interval = randomSabotageInterval()
		task.wait(interval)

		if isActive then
			triggerSabotage()
		end
	end
end

----------------------------------------------------------------------
-- Deodorant Combat
----------------------------------------------------------------------

--[[
	Handles a client requesting to spray deodorant.
	Server-authoritative: validates equipped weapon, ammo count, performs
	raycast, and triggers stun on hit NGMI entities.
]]
local function onDeodorantSpray(player: Player, direction: Vector3): ()
	if not isActive then return end

	local state = playerStates[player.UserId]
	if state == nil or state.isDead or state.isHiding then return end

	-- Validate direction vector (anti-cheat: must be a unit vector)
	if typeof(direction) ~= "Vector3" then return end
	local dirMagnitude = direction.Magnitude
	if dirMagnitude < 0.5 or dirMagnitude > 1.5 then return end
	direction = direction.Unit

	local rootPart = getRootPart(player)
	if rootPart == nil then return end

	-- Check if player has a spray weapon equipped with ammo
	-- We look for deodorant or axe_spray in their inventory
	local inventory = playerInventories[player.UserId]
	if inventory == nil then return end

	local weaponId: string? = nil
	local weaponAmmo: number = 0

	-- Determine which spray weapon the player has
	for itemId, ammo in inventory do
		local itemDef = ItemConfig.items[itemId]
		if itemDef and itemDef.isWeapon and itemDef.useEffect == "spray" then
			if ammo > 0 then
				weaponId = itemId
				weaponAmmo = ammo
				break
			end
		end
	end

	if weaponId == nil then return end -- no valid spray weapon with ammo

	local itemDef = ItemConfig.items[weaponId]
	if itemDef == nil then return end

	-- Determine spray range (axe_spray has 3x range)
	local sprayRange: number = DEODORANT_RANGE
	if weaponId == "axe_spray" then
		sprayRange = DEODORANT_RANGE * 3
	end

	-- Deduct ammo cost
	local sprayCost: number = itemDef.sprayCost or 10
	local newAmmo = math.max(0, weaponAmmo - sprayCost)
	inventory[weaponId] = newAmmo

	-- Notify client of updated ammo
	InventoryUpdated:FireClient(player, weaponId, newAmmo)

	-- Server-side raycast from player's position in the specified direction
	local origin = rootPart.Position
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { player.Character :: Instance }

	local result = workspace:Raycast(origin, direction * sprayRange, raycastParams)

	if result and result.Instance then
		-- Walk up the ancestry to find an NGMI-tagged model
		local hitPart = result.Instance
		local current: Instance? = hitPart

		while current ~= nil and current ~= workspace do
			if CollectionService:HasTag(current :: Instance, "NGMI") then
				-- Hit an NGMI! Fire stun event to all clients
				local ngmiModel = current :: Model
				local stunDuration: number = itemDef.stunDuration or GameConfig.NGMI.stunDuration

				NGMIStunned:FireAllClients(
					ngmiModel.Name,
					stunDuration,
					player.UserId
				)

				print("[SurvivalManager] " .. player.Name .. " stunned NGMI: " .. ngmiModel.Name)
				break
			end
			current = (current :: Instance).Parent
		end
	end
end

----------------------------------------------------------------------
-- Player Connection / Disconnection
----------------------------------------------------------------------

--[[
	Handles a player requesting damage (from NGMIController on server).
	The remote is used as a server→server signal bridge: NGMIController
	fires it from the server with the target player and damage amount.
]]
local function onPlayerDamagedFromNGMI(_sourcePlayer: Player, targetUserId: number, amount: number): ()
	if not isActive then return end
	if typeof(targetUserId) ~= "number" or typeof(amount) ~= "number" then return end

	-- Find the target player
	local targetPlayer = Players:GetPlayerByUserId(targetUserId)
	if targetPlayer == nil then return end

	applyDamage(targetPlayer, amount, "NGMI")
end

--[[
	Clean up player state when they leave the game.
]]
local function onPlayerRemoving(player: Player): ()
	playerStates[player.UserId] = nil
	playerInventories[player.UserId] = nil
end

----------------------------------------------------------------------
-- Phase Lifecycle
----------------------------------------------------------------------

--[[
	Activates all Night 2 survival systems:
	  - Initializes per-player health tracking
	  - Starts the sabotage timer
]]
local function activate(): ()
	if isActive then return end
	isActive = true
	print("[SurvivalManager] NIGHT2 activated — survival systems online")

	-- Initialize state for all current players
	for _, player in Players:GetPlayers() do
		initPlayerState(player)
	end

	-- Clear any leftover sabotage state
	activeSabotages = {}

	-- Start sabotage loop on a background thread
	sabotageThread = task.spawn(sabotageLoop)
end

--[[
	Deactivates all survival systems and cleans up state.
	Called when the phase changes away from NIGHT2.
]]
local function deactivate(): ()
	if not isActive then return end
	isActive = false
	print("[SurvivalManager] Survival systems deactivated")

	-- Cancel sabotage thread
	if sabotageThread then
		task.cancel(sabotageThread)
		sabotageThread = nil
	end

	-- Restore any active sabotages
	for zoneIndex, sabotage in activeSabotages do
		if sabotage.active then
			for light, brightness in sabotage.originalBrightness do
				if light and light.Parent then
					light.Brightness = brightness
				end
			end
			for _, desk in sabotage.affectedDesks do
				if desk and desk.Parent then
					desk:SetAttribute("Sabotaged", false)
				end
			end
		end
	end
	activeSabotages = {}

	-- Restore visibility for any hidden players
	for userId, state in playerStates do
		if state.isHiding then
			local player = Players:GetPlayerByUserId(userId)
			if player then
				local character = getCharacter(player)
				if character then
					setCharacterVisible(character, true)
					local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
					if rootPart then
						rootPart.Anchored = false
					end
				end
			end
		end
	end

	-- Clear all player survival states
	playerStates = {}
end

--[[
	Responds to phase changes. Activates on NIGHT2, deactivates on anything else.
]]
local function onGameStateChanged(_player: Player, phaseId: number): ()
	if phaseId == GameConfig.Phase.NIGHT2 then
		activate()
	else
		deactivate()
	end
end

----------------------------------------------------------------------
-- Public API (for other server modules to call directly)
----------------------------------------------------------------------

-- Expose applyDamage so NGMIController can call it directly
-- without going through a remote round-trip.
local SurvivalAPI = {}

function SurvivalAPI.damage(player: Player, amount: number, sourceId: string?): ()
	applyDamage(player, amount, sourceId)
end

function SurvivalAPI.isPlayerHiding(player: Player): boolean
	local state = playerStates[player.UserId]
	if state then
		return state.isHiding
	end
	return false
end

function SurvivalAPI.isPlayerDead(player: Player): boolean
	local state = playerStates[player.UserId]
	if state then
		return state.isDead
	end
	return false
end

function SurvivalAPI.getPlayerHealth(player: Player): number
	local state = playerStates[player.UserId]
	if state then
		return state.health
	end
	return 0
end

-- Store the API module in a shared location so other server scripts
-- can require it. We use a BindableFunction as a getter pattern.
local apiBindable = Instance.new("BindableFunction")
apiBindable.Name = "SurvivalManagerAPI"
apiBindable.Parent = game:GetService("ServerStorage")
apiBindable.OnInvoke = function(action: string, ...): any
	if action == "damage" then
		local args = { ... }
		SurvivalAPI.damage(args[1] :: Player, args[2] :: number, args[3] :: string?)
		return true
	elseif action == "isHiding" then
		return SurvivalAPI.isPlayerHiding((...) :: Player)
	elseif action == "isDead" then
		return SurvivalAPI.isPlayerDead((...) :: Player)
	elseif action == "getHealth" then
		return SurvivalAPI.getPlayerHealth((...) :: Player)
	end
	return nil
end

----------------------------------------------------------------------
-- Event Wiring
----------------------------------------------------------------------

-- Phase transitions — driven by the server phase bus, not a client remote.
do
	local ServerStorage = game:GetService("ServerStorage")
	local serverComm = ServerStorage:WaitForChild("ServerComm")
	local phaseBus = serverComm:WaitForChild("PhaseChanged") :: BindableEvent
	phaseBus.Event:Connect(function(phaseId: number)
		onGameStateChanged((nil :: any) :: Player, phaseId)
	end)
end

-- Player combat & hiding
PlayerDamaged.OnServerEvent:Connect(onPlayerDamagedFromNGMI)
HidingStateChanged.OnServerEvent:Connect(onHidingStateChanged)
DeodorantSpray.OnServerEvent:Connect(onDeodorantSpray)
PanelRepaired.OnServerEvent:Connect(onPanelRepaired)

-- New players during NIGHT2 get initialized
Players.PlayerAdded:Connect(function(player: Player)
	if isActive then
		initPlayerState(player)
	end
end)

-- Clean up on disconnect
Players.PlayerRemoving:Connect(onPlayerRemoving)

print("[SurvivalManager] Loaded — waiting for NIGHT2 phase")
