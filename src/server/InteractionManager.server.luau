--!strict
--------------------------------------------------------------------------------
-- InteractionManager.server.luau
-- Unified interaction routing for Not Gonna Make It.
--
-- Responsibilities:
--   • Set up ProximityPrompts on all tagged interactable objects
--   • Manage which prompts are active based on current game phase
--   • Route interactions to appropriate handlers
--   • Tags: ItemSpawn, PlayerDesk, HidingSpot, ElectricalPanel, QuestChair
--   • ProximityPrompts work natively on mobile via tap
--------------------------------------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local ServerStorage = game:GetService("ServerStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

-- Remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local CodingProgress = Remotes:WaitForChild("CodingProgress") :: RemoteEvent
local HidingStateChanged = Remotes:WaitForChild("HidingStateChanged") :: RemoteEvent
local OpenPanelPuzzle = Remotes:WaitForChild("OpenPanelPuzzle") :: RemoteEvent

local function serverBus(name: string): BindableEvent
	local serverComm = ServerStorage:FindFirstChild("ServerComm")
	if not serverComm then
		serverComm = Instance.new("Folder")
		serverComm.Name = "ServerComm"
		serverComm.Parent = ServerStorage
	end
	local found = serverComm:FindFirstChild(name)
	if found and found:IsA("BindableEvent") then
		return found
	end
	local bus = Instance.new("BindableEvent")
	bus.Name = name
	bus.Parent = serverComm
	return bus
end

-- Server bus to QuestManager: a player picked up a quest item. (player, questId)
-- Quest progress must come from here, never from a client remote.
local QuestItemCollectedBus = serverBus("QuestItemCollected")

-- Server bus to PowerManager: this player was handed the rewiring puzzle for
-- this panel. (player, panelPart) PowerManager only accepts a PanelRepaired
-- from that player, for that panel, after this.
local PanelPuzzleOpenedBus = serverBus("PanelPuzzleOpened")

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

type InteractionType = "item_pickup" | "desk_coding" | "hiding_spot" | "electrical_panel" | "quest_item"

type PromptRecord = {
	prompt: ProximityPrompt,
	interactionType: InteractionType,
	instance: Instance, -- the tagged object
	connection: RBXScriptConnection,
}

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local PROMPT_SETTINGS = {
	MaxActivationDistance = 8,
	RequiresLineOfSight = true,
}

-- Which interaction types are allowed in each phase
local PHASE_INTERACTIONS: { [number]: { InteractionType } } = {
	[0] = {},                                                                      -- LOBBY
	[1] = { "item_pickup", "desk_coding" },                                        -- DAY1
	[2] = { "item_pickup", "desk_coding", "quest_item" },                          -- DAY2
	[3] = { "item_pickup", "desk_coding", "quest_item", "hiding_spot", "electrical_panel" }, -- NIGHT2
	[4] = {}, -- DAY3: cutscene, no interactions
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local currentPhase: number = 0 -- LOBBY
local registeredPrompts: { PromptRecord } = {}

-- Track players currently hiding
local hidingPlayers: { [Player]: Instance } = {} -- player → hiding spot

-- Track players at desks
local codingPlayers: { [Player]: Instance } = {} -- player → desk

--------------------------------------------------------------------------------
-- Prompt Creation Helpers
--------------------------------------------------------------------------------

--- Create a ProximityPrompt with standard settings on a Part
local function createPrompt(parent: Instance, actionText: string, objectText: string, holdDuration: number?): ProximityPrompt
	-- Check if prompt already exists (avoid duplicates)
	local existing = parent:FindFirstChildOfClass("ProximityPrompt")
	if existing then
		return existing
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = actionText
	prompt.ObjectText = objectText
	prompt.HoldDuration = holdDuration or 0
	prompt.MaxActivationDistance = PROMPT_SETTINGS.MaxActivationDistance
	prompt.RequiresLineOfSight = PROMPT_SETTINGS.RequiresLineOfSight
	prompt.Enabled = false -- start disabled, enabled by phase check
	prompt.Parent = parent

	return prompt
end

--- Register a prompt so we can manage its enabled state per phase
local function registerPrompt(prompt: ProximityPrompt, interactionType: InteractionType, instance: Instance, handler: (Player) -> ())
	local connection = prompt.Triggered:Connect(function(player: Player)
		-- Double-check phase allows this interaction
		local allowed = PHASE_INTERACTIONS[currentPhase]
		if not allowed then return end

		local isAllowed = false
		for _, t in allowed do
			if t == interactionType then
				isAllowed = true
				break
			end
		end

		if not isAllowed then return end
		handler(player)
	end)

	local record: PromptRecord = {
		prompt = prompt,
		interactionType = interactionType,
		instance = instance,
		connection = connection,
	}

	table.insert(registeredPrompts, record)

	-- Apply current phase state immediately
	updatePromptState(record)
end

--- Update a single prompt's enabled state based on current phase
function updatePromptState(record: PromptRecord)
	local allowed = PHASE_INTERACTIONS[currentPhase]
	if not allowed then
		record.prompt.Enabled = false
		return
	end

	local isAllowed = false
	for _, t in allowed do
		if t == record.interactionType then
			isAllowed = true
			break
		end
	end

	record.prompt.Enabled = isAllowed and not record.instance:GetAttribute("Collected")
end

--- Update all registered prompts when phase changes
local function updateAllPromptStates()
	for _, record in registeredPrompts do
		-- Verify the instance still exists
		if record.instance.Parent then
			updatePromptState(record)
		end
	end
end

--------------------------------------------------------------------------------
-- Interaction Handlers
--------------------------------------------------------------------------------

--- PlayerDesk — coding mini-game interaction
local function handleDeskInteraction(player: Player, deskInstance: Instance)
	if currentPhase == GameConfig.Phase.NIGHT2 then
		-- At night the "recompile" terminal rotates between desks. It only becomes
		-- available once all power + servers are restored (CodingGameServer starts the
		-- rotation then and highlights one desk at a time). Until a desk is highlighted
		-- nothing opens; after that, only the highlighted one opens, so the player has
		-- to chase the highlight around.
		local activeId = workspace:GetAttribute("NightTerminalDeskId")
		local thisId = deskInstance:GetAttribute("DeskId") or deskInstance.Name
		if activeId == nil or thisId ~= activeId then
			return
		end
	else
		-- Day: each player is assigned one desk (GameStateManager.assignDesks); only
		-- the owner may code at it — ignore interactions on anyone else's desk.
		local owner = deskInstance:GetAttribute("OwnerUserId") :: number?
		if owner ~= nil and owner ~= player.UserId then
			return
		end
	end

	-- Toggle coding state
	if codingPlayers[player] then
		-- Player is leaving the desk
		codingPlayers[player] = nil
		-- Unlock movement (client handles this)
		CodingProgress:FireClient(player, {
			action = "stop_coding",
			deskId = deskInstance:GetAttribute("DeskId") or deskInstance.Name,
		})
	else
		-- Player starts coding
		codingPlayers[player] = deskInstance
		CodingProgress:FireClient(player, {
			action = "start_coding",
			deskId = deskInstance:GetAttribute("DeskId") or deskInstance.Name,
		})
	end
end

--- HidingSpot — hide/unhide during Night2
local function handleHidingSpot(player: Player, spotInstance: Instance)
	if hidingPlayers[player] then
		-- Player is already hiding — unhide
		hidingPlayers[player] = nil
		player:SetAttribute("Hiding", nil)

		-- Restore visibility
		local character = player.Character
		if character then
			for _, part in character:GetDescendants() do
				if part:IsA("BasePart") then
					part.Transparency = 0
				end
			end
			-- Restore humanoid root part transparency (always invisible)
			local rootPart = character:FindFirstChild("HumanoidRootPart")
			if rootPart and rootPart:IsA("BasePart") then
				rootPart.Transparency = 1
			end
		end

		HidingStateChanged:FireClient(player, {
			isHiding = false,
			spotName = spotInstance.Name,
		})

		-- Broadcast to all clients for NGMI AI awareness
		HidingStateChanged:FireAllClients({
			playerId = player.UserId,
			isHiding = false,
		})
	else
		-- Check if spot is already occupied
		for _, otherSpot in hidingPlayers do
			if otherSpot == spotInstance then
				-- Spot is taken
				return
			end
		end

		-- Hide the player. The attribute is what NGMIController and
		-- SurvivalManager read; only the server can set it.
		hidingPlayers[player] = spotInstance
		player:SetAttribute("Hiding", true)

		-- Make character semi-invisible
		local character = player.Character
		if character then
			for _, part in character:GetDescendants() do
				if part:IsA("BasePart") then
					part.Transparency = 0.8
				end
			end
		end

		-- Move player to hiding position
		if character and character.PrimaryPart and spotInstance:IsA("BasePart") then
			character:PivotTo(spotInstance.CFrame)
		end

		HidingStateChanged:FireClient(player, {
			isHiding = true,
			spotName = spotInstance.Name,
		})

		-- Broadcast to all clients
		HidingStateChanged:FireAllClients({
			playerId = player.UserId,
			isHiding = true,
		})
	end
end

--- Is the straight line from `player` to `panelPart` interrupted by a wall? Used
--- to stop players reaching THROUGH an exterior wall to trigger a panel that's on
--- the far side. We only treat actual wall parts as blockers (parts named "Wall"
--- or anything under the building shell / "Perimeter") so room clutter — shelves,
--- server racks — never falsely blocks the legitimate in-room interaction.
local function wallBetween(player: Player, panelPart: BasePart): boolean
	local char = player.Character
	local origin = char and (char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart"))
	if not origin or not origin:IsA("BasePart") then
		return false
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { char }
	local result = workspace:Raycast(origin.Position, panelPart.Position - origin.Position, params)
	if result and result.Instance ~= panelPart then
		local hit = result.Instance
		if hit.Name == "Wall" or hit:FindFirstAncestor("Perimeter") then
			return true -- a wall is in the way → not actually reachable
		end
	end
	return false
end

--- ElectricalPanel — opens the rewiring puzzle (the actual repair only happens once
--- the player SOLVES it and the client fires PanelRepaired back; see PowerManager).
local function handleElectricalPanel(player: Player, panelInstance: Instance)
	if not panelInstance:IsA("BasePart") then return end
	-- Already repaired? Nothing to do.
	if panelInstance:GetAttribute("IsRepaired") then return end
	-- Can't reach a panel through an exterior wall.
	if wallBetween(player, panelInstance) then return end

	-- Hand off to the client to run the wire-reconnection mini-game.
	PanelPuzzleOpenedBus:Fire(player, panelInstance)
	OpenPanelPuzzle:FireClient(player, { panelId = panelInstance.Name })
end

--- Show or hide a quest item. Its decorative parts (chair legs, back) are
--- children of the tagged part, so hiding walks the descendants.
local function setQuestItemShown(item: Instance, shown: boolean)
	if item:IsA("BasePart") then
		item.Transparency = if shown then 0 else 1
		item.CanCollide = shown
	end
	for _, d in item:GetDescendants() do
		if d:IsA("BasePart") then
			d.Transparency = if shown then 0 else 1
		end
	end
end

--- QuestChair — quest item pickup
local function handleQuestItem(player: Player, chairInstance: Instance)
	local questId = chairInstance:GetAttribute("QuestId") :: string?
	if not questId then
		questId = "unknown_quest"
	end

	-- Mark as collected
	local alreadyCollected = chairInstance:GetAttribute("Collected") :: boolean?
	if alreadyCollected then return end

	chairInstance:SetAttribute("Collected", true)
	setQuestItemShown(chairInstance, false)

	-- Disable prompt
	local prompt = chairInstance:FindFirstChildOfClass("ProximityPrompt")
	if prompt then
		prompt.Enabled = false
	end

	QuestItemCollectedBus:Fire(player, questId)
	print("[InteractionManager] Quest item collected:", questId, "by", player.Name)
end

--- A new match puts every collected quest item back. The map is built once per
--- server, so without this the chairs stay gone after the first match.
local function resetQuestItems()
	for _, item in CollectionService:GetTagged(GameConfig.TAGS.QUEST_CHAIR) do
		if item:GetAttribute("Collected") then
			item:SetAttribute("Collected", nil)
			setQuestItemShown(item, true)
		end
	end
end

--------------------------------------------------------------------------------
-- Tag Processing
-- Finds all tagged objects and sets up ProximityPrompts + handlers.
--------------------------------------------------------------------------------

local function setupTaggedObject(instance: Instance, tag: string)
	if tag == GameConfig.TAGS.PLAYER_DESK then
		-- PlayerDesk — coding interaction
		if instance:IsA("BasePart") or instance:IsA("Model") then
			local target = if instance:IsA("Model") then (instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart"))
				else instance
			if target then
				local prompt = createPrompt(target :: Instance, "Code", "Desk", 0.5)
				registerPrompt(prompt, "desk_coding", instance, function(plr: Player)
					handleDeskInteraction(plr, instance)
				end)
			end
		end

	elseif tag == GameConfig.TAGS.HIDING_SPOT then
		-- HidingSpot — hide interaction (Night2 only)
		if instance:IsA("BasePart") then
			local prompt = createPrompt(instance, "Hide", "Hiding Spot", 0.3)
			registerPrompt(prompt, "hiding_spot", instance, function(plr: Player)
				handleHidingSpot(plr, instance)
			end)
		end

	elseif tag == GameConfig.TAGS.ELECTRICAL_PANEL then
		-- ElectricalPanel — opens the rewiring puzzle (Night2 only). Line-of-sight is
		-- ON so the prompt itself stays hidden when a wall is between you and the
		-- panel; the server-side wallBetween raycast on trigger is the authoritative
		-- backstop against reaching through a wall. No hold — the puzzle is the effort.
		if instance:IsA("BasePart") then
			local prompt = createPrompt(instance, "Rewire", "Electrical Panel")
			prompt.RequiresLineOfSight = true
			prompt.MaxActivationDistance = 8
			registerPrompt(prompt, "electrical_panel", instance, function(plr: Player)
				handleElectricalPanel(plr, instance)
			end)
		end

	elseif tag == GameConfig.TAGS.QUEST_CHAIR then
		-- QuestChair — quest item pickup
		if instance:IsA("BasePart") then
			local itemName = instance:GetAttribute("ItemName") :: string? or "Quest Item"
			local prompt = createPrompt(instance, "Pick up", itemName)
			registerPrompt(prompt, "quest_item", instance, function(plr: Player)
				handleQuestItem(plr, instance)
			end)
		end
	end
end

local function processAllTaggedObjects()
	-- NOTE: ITEM_SPAWN is intentionally NOT handled here. InventoryManager owns
	-- the full item lifecycle (spawning a real pickup model with a working
	-- prompt at every ItemSpawn marker). Handling it here too produced duplicate
	-- "Pick up" prompts — including on the invisible marker parts — that did
	-- nothing when triggered.
	local tags = {
		GameConfig.TAGS.PLAYER_DESK,
		GameConfig.TAGS.HIDING_SPOT,
		GameConfig.TAGS.ELECTRICAL_PANEL,
		GameConfig.TAGS.QUEST_CHAIR,
	}

	local totalProcessed = 0

	for _, tag in tags do
		local instances = CollectionService:GetTagged(tag)
		for _, instance in instances do
			setupTaggedObject(instance, tag)
			totalProcessed += 1
		end

		-- Listen for new instances tagged at runtime
		CollectionService:GetInstanceAddedSignal(tag):Connect(function(instance: Instance)
			setupTaggedObject(instance, tag)
		end)

		-- Clean up when instances are removed
		CollectionService:GetInstanceRemovedSignal(tag):Connect(function(instance: Instance)
			-- Remove from registered prompts
			for i = #registeredPrompts, 1, -1 do
				local record = registeredPrompts[i]
				if record.instance == instance then
					record.connection:Disconnect()
					if record.prompt.Parent then
						record.prompt:Destroy()
					end
					table.remove(registeredPrompts, i)
				end
			end
		end)
	end

	print("[InteractionManager] Processed", totalProcessed, "tagged interactable objects")
end

--------------------------------------------------------------------------------
-- Phase Change Handling
-- Listens for phase changes to enable/disable appropriate prompts.
--------------------------------------------------------------------------------

local function onPhaseChanged(newPhase: number)
	currentPhase = newPhase
	if newPhase == GameConfig.Phase.DAY1 then
		resetQuestItems()
	end
	updateAllPromptStates()

	-- Clear hiding state on phase change (players auto-unhide)
	if newPhase ~= 3 then -- not NIGHT2
		for player, _ in hidingPlayers do
			player:SetAttribute("Hiding", nil)
			-- Restore visibility
			local character = player.Character
			if character then
				for _, part in character:GetDescendants() do
					if part:IsA("BasePart") then
						part.Transparency = 0
					end
				end
				local rootPart = character:FindFirstChild("HumanoidRootPart")
				if rootPart and rootPart:IsA("BasePart") then
					rootPart.Transparency = 1
				end
			end

			HidingStateChanged:FireClient(player, {
				isHiding = false,
				spotName = "phase_change",
			})
		end
		table.clear(hidingPlayers)
	end

	-- Clear coding state on phase change to DAY3 (cutscene)
	if newPhase == 4 then -- DAY3
		for player, _ in codingPlayers do
			CodingProgress:FireClient(player, {
				action = "stop_coding",
				deskId = "phase_end",
			})
		end
		table.clear(codingPlayers)
	end

	print("[InteractionManager] Phase changed to:", newPhase, "- updated", #registeredPrompts, "prompts")
end

-- Listen for phase changes via BindableEvent (from GameLoop)
local function setupPhaseListener()
	-- Look for ServerComm folder (created by NPCManager or GameLoop)
	local serverComm = ServerStorage:FindFirstChild("ServerComm")
	if not serverComm then
		serverComm = Instance.new("Folder")
		serverComm.Name = "ServerComm"
		serverComm.Parent = ServerStorage
	end

	local phaseChanged = serverComm:FindFirstChild("PhaseChanged")
	if not phaseChanged then
		phaseChanged = Instance.new("BindableEvent")
		phaseChanged.Name = "PhaseChanged"
		phaseChanged.Parent = serverComm
	end

	if phaseChanged:IsA("BindableEvent") then
		phaseChanged.Event:Connect(function(phase: number)
			onPhaseChanged(phase)
		end)
	end
end

--------------------------------------------------------------------------------
-- Player cleanup
--------------------------------------------------------------------------------

-- HeartbeatMinigame reports how its rhythm game ended. Hiding is decided here,
-- by the prompt, never by the client: the only report acted on is
-- "discovered", which pulls the sender OUT of their spot (it can only ever
-- cost them their own cover). "Safe" leaves them hidden.
HidingStateChanged.OnServerEvent:Connect(function(player: Player, data: any)
	if typeof(data) == "table" and data.discovered == true then
		local spot = hidingPlayers[player]
		if spot then
			handleHidingSpot(player, spot)
		end
	end
end)

Players.PlayerRemoving:Connect(function(player: Player)
	hidingPlayers[player] = nil
	codingPlayers[player] = nil
end)

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

setupPhaseListener()

-- Process tagged objects on a slight delay to allow map generation
task.delay(2, function()
	processAllTaggedObjects()
end)

print("[InteractionManager] Initialized — unified interaction routing ready")
