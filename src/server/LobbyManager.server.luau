--!strict
--[[
	LobbyManager.server.luau
	Server Script — Lobby orchestration and matchmaking
	
	Responsibilities:
	  1. Place newly-joined players in the LOBBY phase
	  2. Route queue join/leave requests through QueueManager
	  3. When a queue fills, create a match → countdown → start game
	  4. Track active matches (matchId → match data)
	  5. Handle disconnects mid-queue and mid-countdown
	  6. Broadcast queue counts to all lobby players so the UI stays current
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")
local TeleportService = game:GetService("TeleportService")

--------------------------------------------------------------------------------
-- Server role
--------------------------------------------------------------------------------
-- Matchmaking only happens on the public LOBBY server. On a reserved MATCH
-- server the party is already here to play, so this whole system stays dormant
-- and GameStateManager takes over.
local ServerRole = require(script.Parent:WaitForChild("ServerRole"))
if ServerRole.isMatchServer then
	print("[LobbyManager] Reserved match server — matchmaking disabled.")
	return
end

--------------------------------------------------------------------------------
-- Remote Events
--------------------------------------------------------------------------------

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PlayerJoinedLobbyRemote = Remotes:WaitForChild("PlayerJoinedLobby") :: RemoteEvent
local QueueUpdateRemote       = Remotes:WaitForChild("QueueUpdate") :: RemoteEvent
local MatchFoundRemote        = Remotes:WaitForChild("MatchFound") :: RemoteEvent
local StartGameRemote         = Remotes:WaitForChild("StartGame") :: RemoteEvent
local GameStateChangedRemote  = Remotes:WaitForChild("GameStateChanged") :: RemoteEvent

--------------------------------------------------------------------------------
-- Dependencies
--------------------------------------------------------------------------------

local QueueManager = require(script.Parent:WaitForChild("QueueManager"))

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

type MatchData = {
	matchId: string,
	players: { Player },
	phase: string,       -- "LOBBY" | "COUNTDOWN" | "PLAYING" | "ENDED"
	startTime: number,
	queueSize: number,
}

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local COUNTDOWN_SECONDS: number = 5
local QUEUE_BROADCAST_INTERVAL: number = 1.0 -- Seconds between queue count broadcasts

-- Spawn points for matched players (offsets from arena center).
-- In production these would reference actual SpawnLocation parts in the workspace.
-- Drop matched players just inside the main hall entrance (the map is built
-- around world origin by MapBuilder; the old -200 value was out in the void).
local ARENA_CENTER = Vector3.new(0, 8, -40)
local SPAWN_OFFSETS: { Vector3 } = {
	Vector3.new(-10, 0, 0),
	Vector3.new(10, 0, 0),
	Vector3.new(0, 0, -10),
	Vector3.new(0, 0, 10),
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

-- All active matches indexed by their unique ID
local activeMatches: { [string]: MatchData } = {}

-- Reverse lookup: playerId → matchId (so we can find a player's match quickly)
local playerMatchMap: { [number]: string } = {}

-- Set of players currently in the lobby (not in a match yet)
local lobbyPlayers: { [number]: boolean } = {}

-- Players currently in a countdown (can still disconnect and cancel)
local countdownPlayers: { [number]: boolean } = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

--[[
	Generates a short unique match ID using HttpService.
]]
local function generateMatchId(): string
	-- Use first 8 chars of a GUID for readability
	local guid = HttpService:GenerateGUID(false)
	return "MATCH-" .. string.sub(guid, 1, 8)
end

--[[
	Teleports a player's character to the given world position.
	Safely handles missing character / HumanoidRootPart.
]]
local function teleportCharacter(player: Player, position: Vector3): ()
	local character = player.Character
	if not character then
		return
	end
	local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		root.CFrame = CFrame.new(position)
	end
end

--[[
	Broadcasts the latest queue counts to every player in the lobby.
]]
local function broadcastQueueCounts(): ()
	local counts = QueueManager.getQueueCounts()
	for userId, _ in lobbyPlayers do
		local player = Players:GetPlayerByUserId(userId)
		if player then
			QueueUpdateRemote:FireClient(player, {
				type = "counts",
				counts = counts,
			})
		end
	end
end

--[[
	Notifies remaining queue members when someone leaves, so the UI
	can update the player list / count in real time.
]]
local function notifyQueueChange(queueSize: number): ()
	local queuePlayers = QueueManager.getQueuePlayers(queueSize)
	local counts = QueueManager.getQueueCounts()

	for _, player in queuePlayers do
		QueueUpdateRemote:FireClient(player, {
			type = "queueChanged",
			queueSize = queueSize,
			currentCount = counts[queueSize],
		})
	end

	-- Also broadcast updated counts to all lobby players
	broadcastQueueCounts()
end

--------------------------------------------------------------------------------
-- Match Lifecycle
--------------------------------------------------------------------------------

--[[
	Fallback start: run the match on THIS server (used in Studio, or if the
	teleport to a reserved server fails). Teleports characters to arena spawns,
	tells clients the game is starting, and hands the roster to GameStateManager.
]]
local function startMatchLocally(matchData: MatchData, playerNames: { string }): ()
	for i, player in matchData.players do
		local offset = SPAWN_OFFSETS[((i - 1) % #SPAWN_OFFSETS) + 1]
		teleportCharacter(player, ARENA_CENTER + offset)
	end

	for _, player in matchData.players do
		StartGameRemote:FireClient(player, {
			matchId = matchData.matchId,
			players = playerNames,
			queueSize = matchData.queueSize,
		})
	end

	local serverComm = ServerStorage:WaitForChild("ServerComm")
	local startMatchBus = serverComm:WaitForChild("StartMatch") :: BindableEvent
	startMatchBus:Fire(matchData.players)
end

--[[
	Preferred start: reserve a brand-new isolated server for this place and send
	the whole party there together. Returns true if the teleport was dispatched.

	ReserveServer + TeleportAsync(ReservedServerAccessCode) is the standard way to
	create per-match dedicated servers without needing a second place — each call
	yields a fresh server instance only this party can reach.
]]
local function teleportPartyToMatchServer(matchData: MatchData): boolean
	local reserveOk, accessCode = pcall(function()
		return TeleportService:ReserveServer(game.PlaceId)
	end)
	if not reserveOk or typeof(accessCode) ~= "string" then
		warn("[LobbyManager] ReserveServer failed:", accessCode)
		return false
	end

	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = accessCode
	options:SetTeleportData({
		matchId = matchData.matchId,
		queueSize = matchData.queueSize,
	})

	local teleportOk, err = pcall(function()
		TeleportService:TeleportAsync(game.PlaceId, matchData.players, options)
	end)
	if not teleportOk then
		warn("[LobbyManager] TeleportAsync failed:", err)
		return false
	end

	print("[LobbyManager] Teleporting", #matchData.players, "player(s) to a reserved match server.")
	return true
end

--[[
	Creates a match from a set of matched players, runs the countdown,
	then starts the game. The entire flow is:
	  1. Register match in activeMatches
	  2. Fire MatchFound to all participants
	  3. 5-second countdown (with disconnect handling)
	  4. Fire StartGame & teleport players
	  5. Initialize GameStateManager for this match
]]
local function createMatch(matchedPlayers: { Player }, queueSize: number): ()
	local matchId = generateMatchId()

	-- Build match data
	local matchData: MatchData = {
		matchId = matchId,
		players = matchedPlayers,
		phase = "COUNTDOWN",
		startTime = tick(),
		queueSize = queueSize,
	}
	activeMatches[matchId] = matchData

	-- Map players to this match and remove them from lobby pool
	for _, player in matchedPlayers do
		playerMatchMap[player.UserId] = matchId
		lobbyPlayers[player.UserId] = nil
		countdownPlayers[player.UserId] = true
	end

	-- Notify clients: match found!
	local playerNames: { string } = {}
	for _, player in matchedPlayers do
		table.insert(playerNames, player.DisplayName)
	end

	for _, player in matchedPlayers do
		MatchFoundRemote:FireClient(player, {
			matchId = matchId,
			players = playerNames,
			countdownSeconds = COUNTDOWN_SECONDS,
			queueSize = queueSize,
		})
	end

	-- Broadcast updated queue counts since players left the queues
	broadcastQueueCounts()

	-- Countdown phase — check for disconnects each second
	for i = COUNTDOWN_SECONDS, 1, -1 do
		task.wait(1)

		-- Verify all players are still connected
		local allPresent = true
		local remaining: { Player } = {}

		for _, player in matchData.players do
			if player.Parent ~= nil and countdownPlayers[player.UserId] then
				table.insert(remaining, player)
			else
				-- Player disconnected during countdown
				allPresent = false
				countdownPlayers[player.UserId] = nil
				playerMatchMap[player.UserId] = nil
			end
		end

		if not allPresent then
			-- Cancel match — put remaining players back in lobby
			matchData.phase = "ENDED"
			for _, player in remaining do
				countdownPlayers[player.UserId] = nil
				playerMatchMap[player.UserId] = nil
				lobbyPlayers[player.UserId] = true

				QueueUpdateRemote:FireClient(player, {
					type = "matchCancelled",
					reason = "A player disconnected during countdown",
				})
			end
			activeMatches[matchId] = nil
			broadcastQueueCounts()
			return
		end

		-- Send countdown tick to clients
		for _, player in matchData.players do
			QueueUpdateRemote:FireClient(player, {
				type = "countdown",
				remaining = i - 1, -- seconds left after this tick
				matchId = matchId,
			})
		end
	end

	-- ── Start Game ──────────────────────────────────────────────────────

	matchData.phase = "PLAYING"
	matchData.startTime = tick()

	for _, player in matchData.players do
		countdownPlayers[player.UserId] = nil
	end

	-- Preferred path: send the party to a brand-new reserved server that runs
	-- only their match. Falls back to a same-server start in Studio or if the
	-- teleport can't be performed (e.g. the place isn't published yet).
	local teleported = false
	if not ServerRole.isStudio then
		teleported = teleportPartyToMatchServer(matchData)
	end

	if not teleported then
		startMatchLocally(matchData, playerNames)
	end
end

--------------------------------------------------------------------------------
-- Queue Processing
--------------------------------------------------------------------------------

--[[
	After adding a player to a queue, check if the queue is now full.
	If so, kick off match creation in a new thread.
]]
local function processQueue(queueSize: number): ()
	local matched = QueueManager.checkQueue(queueSize)
	if matched and #matched > 0 then
		-- Spawn match creation on a separate thread so we don't block
		task.spawn(createMatch, matched, queueSize)
	end
end

--------------------------------------------------------------------------------
-- Client → Server Event Handlers
--------------------------------------------------------------------------------

--[[
	Player requests to join a queue.
	Payload: { action = "join", queueSize = number }
	         { action = "leave" }
]]
PlayerJoinedLobbyRemote.OnServerEvent:Connect(function(player: Player, payload: any)
	if typeof(payload) ~= "table" then
		return
	end

	local action = payload.action

	if action == "join" then
		local queueSize = payload.queueSize
		if typeof(queueSize) ~= "number" then
			return
		end

		-- Must be in the lobby to join a queue
		if not lobbyPlayers[player.UserId] and not QueueManager.isPlayerQueued(player) then
			-- They might have just joined — add them to lobby first
			lobbyPlayers[player.UserId] = true
		end

		local success, state, message = QueueManager.addToQueue(player, queueSize)

		-- Send personal feedback
		QueueUpdateRemote:FireClient(player, {
			type = "joinResult",
			success = success,
			message = message,
			queueSize = if state then state.queueSize else nil,
			currentCount = if state then state.currentCount else nil,
		})

		if success then
			lobbyPlayers[player.UserId] = nil -- They're now "in queue", not plain lobby
			notifyQueueChange(queueSize)
			processQueue(queueSize)
		end

	elseif action == "leave" then
		local success, queueSize, message = QueueManager.removeFromQueue(player)

		QueueUpdateRemote:FireClient(player, {
			type = "leaveResult",
			success = success,
			message = message,
		})

		if success then
			lobbyPlayers[player.UserId] = true -- Back to lobby
			notifyQueueChange(queueSize)
		end
	end
end)

--------------------------------------------------------------------------------
-- Player Connection / Disconnection
--------------------------------------------------------------------------------

--[[
	When a player joins the game, place them into the lobby and send
	initial state.
]]
local function onPlayerAdded(player: Player): ()
	lobbyPlayers[player.UserId] = true

	-- Send them the current queue counts so the UI can populate immediately
	task.defer(function()
		local counts = QueueManager.getQueueCounts()
		QueueUpdateRemote:FireClient(player, {
			type = "counts",
			counts = counts,
		})

		-- Notify client that they're in the lobby (phase is numeric — the client
		-- compares against GameConfig.Phase.* which are numbers).
		GameStateChangedRemote:FireClient(player, {
			phase = 0, -- GameConfig.Phase.LOBBY
		})
	end)
end

--[[
	When a player leaves, clean them out of queues, countdowns, and matches.
]]
local function onPlayerRemoving(player: Player): ()
	local userId = player.UserId

	-- Remove from queue (bypass cooldown)
	local wasQueued, queueSize = QueueManager.forceRemovePlayer(player)
	if wasQueued then
		notifyQueueChange(queueSize)
	end

	-- Remove from lobby set
	lobbyPlayers[userId] = nil
	countdownPlayers[userId] = nil

	-- If they were in an active match, clean up
	local matchId = playerMatchMap[userId]
	if matchId then
		playerMatchMap[userId] = nil
		local matchData = activeMatches[matchId]
		if matchData then
			-- Remove the disconnected player from the match's player list
			for i, p in matchData.players do
				if p.UserId == userId then
					table.remove(matchData.players, i)
					break
				end
			end
			-- If no players left, remove the match entirely
			if #matchData.players == 0 then
				activeMatches[matchId] = nil
			end
		end
	end
end

-- Hook up to existing players (in case script loads late) and future players
for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end
Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

--------------------------------------------------------------------------------
-- Periodic Queue Count Broadcast
--------------------------------------------------------------------------------

--[[
	Every QUEUE_BROADCAST_INTERVAL seconds, push the latest queue counts
	to all lobby players. This keeps the UI in sync even if an event
	was somehow missed.
]]
task.spawn(function()
	while true do
		task.wait(QUEUE_BROADCAST_INTERVAL)
		broadcastQueueCounts()
	end
end)

--------------------------------------------------------------------------------
-- Public API (for other server scripts)
--------------------------------------------------------------------------------

-- Expose active matches for debugging or external systems
-- Note: this is a server script, not a module, but we keep the reference
-- accessible via a BindableFunction if needed in the future.

print("[LobbyManager] Lobby & matchmaking system initialized ✓")
