--!strict
--[[
	SurvivalManager.server.luau
	===========================
	Server-side Night 2 health for "Not Gonna Make It": per-player HP, damage,
	death and respawn.

	Hiding (InteractionManager), sprays (NGMIController), panel repairs
	(PowerManager) and sabotage (GameStateManager) live elsewhere. This script
	reads the "Hiding" player attribute and handles no client remotes.

	Activates exclusively during the NIGHT2 phase and cleans up on phase change.
	All gameplay-critical state lives here; clients are purely presentational.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))

----------------------------------------------------------------------
-- Remote references
----------------------------------------------------------------------
local Remotes = ReplicatedStorage:WaitForChild("Remotes") :: Folder

local PlayerDamaged = Remotes:WaitForChild("PlayerDamaged") :: RemoteEvent
local PlayerDied = Remotes:WaitForChild("PlayerDied") :: RemoteEvent
local PlayerRespawn = Remotes:WaitForChild("PlayerRespawn") :: RemoteEvent

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------
local MAX_HEALTH: number = GameConfig.Player.maxHealth -- 100
local RESPAWN_DELAY: number = GameConfig.RESPAWN_DELAY -- 3 seconds

-- Night2 spawn position — players respawn here after death
local NIGHT2_SPAWN_POSITION: Vector3 = Vector3.new(0, 5, 0)

----------------------------------------------------------------------
-- Types
----------------------------------------------------------------------
export type PlayerSurvivalState = {
	health: number,
	isDead: boolean,
}

----------------------------------------------------------------------
-- Module State
----------------------------------------------------------------------
-- Whether the survival systems are currently running (NIGHT2 active)
local isActive: boolean = false

-- Per-player survival data, keyed by UserId
local playerStates: { [number]: PlayerSurvivalState } = {}

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
	True while the player is in a hiding spot. InteractionManager owns hiding
	(server-side prompts) and publishes it as the "Hiding" player attribute.
]]
local function isHiding(player: Player): boolean
	return player:GetAttribute("Hiding") == true
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
		isDead = false,
	}
end

local handlePlayerDeath: (Player) -> ()

--[[
	Applies damage to a player. Fires PlayerDamaged back to the client
	so the HUD can update. If health drops to 0, triggers death flow.

	Reached only from the server, through the SurvivalManagerAPI
	BindableFunction ("damage"). Clients have no way in.
]]
local function applyDamage(player: Player, amount: number, sourceId: string?): ()
	if not isActive then
		return
	end

	local state = playerStates[player.UserId]
	if state == nil or state.isDead then
		return
	end

	-- Players cannot take damage while hiding
	if isHiding(player) then
		return
	end

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
handlePlayerDeath = function(player: Player): ()
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
		if not isActive then
			return
		end
		if not player.Parent then
			return
		end -- player left the game

		local state = playerStates[player.UserId]
		if state == nil then
			return
		end

		-- Reset health, clear death flag
		state.health = MAX_HEALTH
		state.isDead = false

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
-- Player Connection / Disconnection
----------------------------------------------------------------------

--[[
	Clean up player state when they leave the game.
]]
local function onPlayerRemoving(player: Player): ()
	playerStates[player.UserId] = nil
end

----------------------------------------------------------------------
-- Phase Lifecycle
----------------------------------------------------------------------

--[[
	Activates all Night 2 survival systems:
	  - Initializes per-player health tracking
]]
local function activate(): ()
	if isActive then
		return
	end
	isActive = true
	print("[SurvivalManager] NIGHT2 activated — survival systems online")

	-- Initialize state for all current players
	for _, player in Players:GetPlayers() do
		initPlayerState(player)
	end
end

--[[
	Deactivates all survival systems and cleans up state.
	Called when the phase changes away from NIGHT2.
]]
local function deactivate(): ()
	if not isActive then
		return
	end
	isActive = false
	print("[SurvivalManager] Survival systems deactivated")

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
	return isHiding(player)
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

-- No client remotes are handled here. Damage comes from server systems, hiding
-- from InteractionManager's prompts (the "Hiding" player attribute), sprays from
-- NGMIController and panel repairs from PowerManager, each validated there.

-- New players during NIGHT2 get initialized
Players.PlayerAdded:Connect(function(player: Player)
	if isActive then
		initPlayerState(player)
	end
end)

-- Clean up on disconnect
Players.PlayerRemoving:Connect(onPlayerRemoving)

print("[SurvivalManager] Loaded — waiting for NIGHT2 phase")
