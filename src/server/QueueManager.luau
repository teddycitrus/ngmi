--!strict
--[[
	QueueManager.luau
	ModuleScript — Queue logic for lobby matchmaking
	
	Manages three separate queues (solo, duo, full-stack) and provides
	thread-safe operations with anti-spam cooldowns. Required by LobbyManager.
	
	Queue sizes: 1 (solo), 2 (duo), 4 (full stack team)
]]

local Players = game:GetService("Players")

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

export type QueueState = {
	queueSize: number,
	currentCount: number,
	players: { Player },
}

export type QueueCounts = {
	[number]: number, -- queueSize → count
}

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local VALID_QUEUE_SIZES: { number } = { 1, 2, 4 }
local COOLDOWN_SECONDS: number = 1.5 -- Anti-spam cooldown between queue join/leave

--------------------------------------------------------------------------------
-- Module
--------------------------------------------------------------------------------

local QueueManager = {}

-- Internal queue storage: queueSize → list of queued players
local queues: { [number]: { Player } } = {
	[1] = {},
	[2] = {},
	[4] = {},
}

-- Tracks which queue each player is currently in (playerId → queueSize)
local playerQueueMap: { [number]: number } = {}

-- Anti-spam cooldown tracking (playerId → last action tick)
local cooldowns: { [number]: number } = {}

--------------------------------------------------------------------------------
-- Private Helpers
--------------------------------------------------------------------------------

--[[
	Validates that the given queue size is one of the allowed sizes (1, 2, 4).
]]
local function isValidQueueSize(queueSize: number): boolean
	for _, valid in VALID_QUEUE_SIZES do
		if queueSize == valid then
			return true
		end
	end
	return false
end

--[[
	Checks if a player is on cooldown. Returns true if they must wait.
]]
local function isOnCooldown(player: Player): boolean
	local lastAction = cooldowns[player.UserId]
	if lastAction == nil then
		return false
	end
	return (tick() - lastAction) < COOLDOWN_SECONDS
end

--[[
	Records the current tick as the player's last queue action (for cooldown).
]]
local function setCooldown(player: Player): ()
	cooldowns[player.UserId] = tick()
end

--[[
	Finds and removes a player from a specific queue table by reference.
	Returns true if the player was found and removed.
]]
local function removePlayerFromTable(queue: { Player }, player: Player): boolean
	for i, queuedPlayer in queue do
		if queuedPlayer == player then
			table.remove(queue, i)
			return true
		end
	end
	return false
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--[[
	Adds a player to the specified queue (1, 2, or 4 player).
	
	Returns:
	  - success: whether the player was added
	  - state: the current queue state after the operation (or nil on failure)
	  - message: human-readable status message
]]
function QueueManager.addToQueue(player: Player, queueSize: number): (boolean, QueueState?, string)
	-- Validate queue size
	if not isValidQueueSize(queueSize) then
		return false, nil, "Invalid queue size: " .. tostring(queueSize)
	end

	-- Anti-spam check
	if isOnCooldown(player) then
		return false, nil, "Please wait before joining a queue again"
	end

	-- Check if already queued somewhere
	if playerQueueMap[player.UserId] ~= nil then
		return false, nil, "Already in a queue, leave first"
	end

	-- Add to queue
	local queue = queues[queueSize]
	table.insert(queue, player)
	playerQueueMap[player.UserId] = queueSize
	setCooldown(player)

	local state: QueueState = {
		queueSize = queueSize,
		currentCount = #queue,
		players = table.clone(queue),
	}

	return true, state, "Joined queue"
end

--[[
	Removes a player from whatever queue they are currently in.
	
	Returns:
	  - success: whether the player was removed
	  - queueSize: which queue they were in (or 0 if none)
	  - message: human-readable status message
]]
function QueueManager.removeFromQueue(player: Player): (boolean, number, string)
	-- Anti-spam check
	if isOnCooldown(player) then
		return false, 0, "Please wait before leaving the queue"
	end

	local queueSize = playerQueueMap[player.UserId]
	if queueSize == nil then
		return false, 0, "Not currently in any queue"
	end

	local queue = queues[queueSize]
	local removed = removePlayerFromTable(queue, player)

	if removed then
		playerQueueMap[player.UserId] = nil
		setCooldown(player)
		return true, queueSize, "Left queue"
	end

	-- Inconsistent state — clean up the map anyway
	playerQueueMap[player.UserId] = nil
	return false, queueSize, "Failed to remove from queue (state recovered)"
end

--[[
	Checks if a queue of the given size is full and ready to start a match.
	
	If the queue has enough players, it pops them out and returns the matched
	group. Otherwise returns nil (no match yet).
]]
function QueueManager.checkQueue(queueSize: number): { Player }?
	if not isValidQueueSize(queueSize) then
		return nil
	end

	local queue = queues[queueSize]

	if #queue < queueSize then
		return nil
	end

	-- Pop the first `queueSize` players from the front of the queue
	local matched: { Player } = {}
	for _ = 1, queueSize do
		local player = table.remove(queue, 1)
		if player then
			table.insert(matched, player)
			playerQueueMap[player.UserId] = nil
		end
	end

	return matched
end

--[[
	Returns the current player count for every queue size.
]]
function QueueManager.getQueueCounts(): QueueCounts
	return {
		[1] = #queues[1],
		[2] = #queues[2],
		[4] = #queues[4],
	}
end

--[[
	Checks if a player is currently in any queue.
	
	Returns:
	  - isQueued: boolean
	  - queueSize: the queue they are in (0 if not queued)
]]
function QueueManager.isPlayerQueued(player: Player): (boolean, number)
	local queueSize = playerQueueMap[player.UserId]
	if queueSize ~= nil then
		return true, queueSize
	end
	return false, 0
end

--[[
	Force-removes a player from all queues (used on disconnect).
	Bypasses cooldown checks since the player is leaving the game.
]]
function QueueManager.forceRemovePlayer(player: Player): (boolean, number)
	local queueSize = playerQueueMap[player.UserId]
	if queueSize == nil then
		-- Clean up cooldown data anyway
		cooldowns[player.UserId] = nil
		return false, 0
	end

	local queue = queues[queueSize]
	removePlayerFromTable(queue, player)
	playerQueueMap[player.UserId] = nil
	cooldowns[player.UserId] = nil

	return true, queueSize
end

--[[
	Returns a snapshot of players currently in a given queue.
	Useful for broadcasting queue membership updates.
]]
function QueueManager.getQueuePlayers(queueSize: number): { Player }
	if not isValidQueueSize(queueSize) then
		return {}
	end
	return table.clone(queues[queueSize])
end

return QueueManager
