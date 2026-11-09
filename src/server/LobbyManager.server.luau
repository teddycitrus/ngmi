--!strict
--[[
	LobbyManager.server.luau
	Parties and matchmaking on the lobby server.

	Every player in the lobby is in a party (see Lobby/Parties). This script:
	  1. Handles menu actions from LobbyUI (PlayerJoinedLobby remote): mode,
	     privacy, fill, ready, start, cancel, join by list or code, leave,
	     kick, promote, rejoin.
	  2. Runs matchmaking for searching parties and hands full groups to
	     Lobby/Launcher (countdown, then teleport to a reserved match server).
	  3. Brings players into the right party when they arrive (Lobby/Arrivals):
	     from an invite, a join code typed on another lobby server, or home
	     from a match with their team.
	  4. Pushes each player their menu state whenever something changes.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")

--------------------------------------------------------------------------------
-- Server role
--------------------------------------------------------------------------------
-- Matchmaking only happens on the public LOBBY server. On a reserved MATCH
-- server the party is already here to play, so this whole system stays dormant
-- and GameStateManager takes over.
local ServerRole = require(script.Parent:WaitForChild("ServerRole"))
if ServerRole.isMatchServer then
	-- Replicates to clients so LobbyUI never builds the mode menu here.
	ReplicatedStorage:SetAttribute("IsMatchServer", true)
	print("[LobbyManager] Reserved match server, matchmaking disabled.")
	return
end

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local ServerComm = require(script.Parent:WaitForChild("ServerComm"))
local LobbyFolder = script.Parent:WaitForChild("Lobby")
local Parties = require(LobbyFolder:WaitForChild("Parties"))
local Matchmaker = require(LobbyFolder:WaitForChild("Matchmaker"))
local Launcher = require(LobbyFolder:WaitForChild("Launcher"))
local Presence = require(LobbyFolder:WaitForChild("Presence"))
local Net = require(LobbyFolder:WaitForChild("Net"))
local Arrivals = require(LobbyFolder:WaitForChild("Arrivals"))

type Party = Parties.Party

local ACTION_COOLDOWN = 0.2
local CODE_LOOKUP_COOLDOWN = 2
local FLUSH_INTERVAL = 0.15
local RESYNC_INTERVAL = 3
local MATCHMAKE_INTERVAL = 0.5
local PRESENCE_REFRESH = 20 * 60
local MAX_OPEN_LISTED = 12

--------------------------------------------------------------------------------
-- Friends (who can see and join a friends-only party)
--------------------------------------------------------------------------------

local friendCache: { [string]: boolean } = {}

local function pairKey(a: number, b: number): string
	return math.min(a, b) .. ":" .. math.max(a, b)
end

local function isFriend(a: Player, b: Player): boolean
	return friendCache[pairKey(a.UserId, b.UserId)] == true
end

local function checkFriend(a: Player, b: Player)
	local key = pairKey(a.UserId, b.UserId)
	if friendCache[key] ~= nil then
		return
	end
	local ok, result = pcall(function()
		return a:IsFriendsWith(b.UserId)
	end)
	friendCache[key] = ok and result == true
	if friendCache[key] then
		Parties.dirty = true
	end
end

local function canSee(viewer: Player, party: Party): boolean
	if party.privacy == "public" then
		return true
	elseif party.privacy == "friends" then
		return isFriend(viewer, party.leader)
	end
	return false
end

--------------------------------------------------------------------------------
-- Menu state
--------------------------------------------------------------------------------

local rejoinable: { [Player]: Presence.Rejoin } = {}

local function currentPhase(): number
	local value = ReplicatedStorage:FindFirstChild("CurrentPhase")
	return if value and value:IsA("IntValue") then value.Value else GameConfig.Phase.LOBBY
end

local function partyView(party: Party)
	local members = {}
	for _, m in party.members do
		table.insert(members, {
			userId = m.UserId,
			name = m.Name,
			displayName = m.DisplayName,
			leader = m == party.leader,
			ready = m == party.leader or party.ready[m] == true,
		})
	end
	return {
		id = party.id,
		code = party.code,
		leaderId = party.leader.UserId,
		mode = party.mode,
		privacy = party.privacy,
		fill = party.fill,
		status = party.status,
		searchSeconds = if party.searchSince then math.floor(os.clock() - party.searchSince) else nil,
		members = members,
	}
end

local function stateFor(player: Player)
	local mine = Parties.of(player)
	local open = {}
	for _, party in Parties.all() do
		if party ~= mine and Parties.isOpen(party) and #party.members < party.mode and canSee(player, party) then
			table.insert(open, {
				id = party.id,
				leaderName = party.leader.DisplayName,
				leaderId = party.leader.UserId,
				mode = party.mode,
				count = #party.members,
				privacy = party.privacy,
				searching = party.status == "searching",
			})
		end
	end
	table.sort(open, function(a, b)
		return a.count > b.count
	end)
	while #open > MAX_OPEN_LISTED do
		table.remove(open)
	end
	return {
		type = "state",
		party = if mine then partyView(mine) else nil,
		open = open,
		searching = Matchmaker.counts(),
		rejoin = rejoinable[player] ~= nil,
		matchRunning = currentPhase() ~= GameConfig.Phase.LOBBY,
		jobId = game.JobId,
	}
end

local function flush()
	Parties.dirty = false
	for _, player in Players:GetPlayers() do
		Net.send(player, stateFor(player))
	end
end

task.spawn(function()
	local sinceResync = 0
	while true do
		task.wait(FLUSH_INTERVAL)
		sinceResync += FLUSH_INTERVAL
		if Parties.dirty or sinceResync >= RESYNC_INTERVAL then
			sinceResync = 0
			flush()
		end
	end
end)

--------------------------------------------------------------------------------
-- Matchmaking
--------------------------------------------------------------------------------

local function matchmake()
	for _, party in Parties.all() do
		-- A searching party that filled up on its own goes straight in.
		if party.status == "searching" and #party.members >= party.mode then
			task.spawn(Launcher.begin, { party })
		end
	end
	for _, mode in { 1, 2, 4 } do
		while true do
			local group = Matchmaker.form(mode)
			if not group then
				break
			end
			-- Launcher.begin locks the parties before its first yield, so the
			-- next Matchmaker.form can't pick them again.
			task.spawn(Launcher.begin, group)
		end
	end
end

task.spawn(function()
	while true do
		task.wait(MATCHMAKE_INTERVAL)
		matchmake()
	end
end)

local function checkRejoin(player: Player)
	local info = Arrivals.findRejoin(player)
	if info and player.Parent then
		rejoinable[player] = info
		Parties.dirty = true
	end
end

--------------------------------------------------------------------------------
-- Menu actions
--------------------------------------------------------------------------------

local function targetOf(payload: any): Player?
	local id = payload.userId
	return if typeof(id) == "number" then Players:GetPlayerByUserId(id) else nil
end

local function leaderOnly(player: Player, party: Party): boolean
	if party.leader ~= player then
		Net.toast(player, "Only the party leader can do that", "warn")
		return false
	end
	return true
end

local function report(player: Player, ok: boolean, err: string?)
	if not ok and err then
		Net.toast(player, err, "warn")
	end
end

local handlers: { [string]: (Player, Party, any) -> () } = {}

handlers.mode = function(player, party, payload)
	if leaderOnly(player, party) and typeof(payload.mode) == "number" then
		report(player, Parties.setMode(party, payload.mode))
	end
end

handlers.privacy = function(player, party, payload)
	if leaderOnly(player, party) and typeof(payload.privacy) == "string" then
		Parties.setPrivacy(party, payload.privacy)
	end
end

handlers.fill = function(player, party, payload)
	if leaderOnly(player, party) and typeof(payload.fill) == "boolean" then
		report(player, Parties.setFill(party, payload.fill))
	end
end

handlers.ready = function(player, _party, payload)
	if typeof(payload.ready) == "boolean" then
		report(player, Parties.setReady(player, payload.ready))
	end
end

handlers.start = function(player, party, _payload)
	if not leaderOnly(player, party) or party.status ~= "idle" then
		return
	end
	if not Parties.allReady(party) then
		Net.toast(player, "Waiting for everyone to ready up", "warn")
		return
	end
	if currentPhase() ~= GameConfig.Phase.LOBBY then
		Net.toast(player, "A match is already running on this server", "warn")
		return
	end
	if #party.members >= party.mode or not party.fill then
		task.spawn(Launcher.begin, { party })
	else
		Matchmaker.enqueue(party)
	end
end

-- Stop searching and play with whoever is in the party now.
handlers.startNow = function(player, party, _payload)
	if leaderOnly(player, party) and party.status == "searching" then
		Matchmaker.dequeue(party)
		task.spawn(Launcher.begin, { party })
	end
end

handlers.cancel = function(player, party, _payload)
	if leaderOnly(player, party) then
		Matchmaker.dequeue(party)
	end
end

handlers.join = function(player, _party, payload)
	local target = if typeof(payload.partyId) == "string" then Parties.byId(payload.partyId) else nil
	if not target or not canSee(player, target) then
		Net.toast(player, "That party isn't open to you", "warn")
		return
	end
	local ok, err = Parties.join(player, target)
	Net.toast(player, if ok then "Joined " .. target.leader.DisplayName .. "'s party" else err or "Couldn't join", if ok then "good" else "warn")
end

local lastCodeLookup: { [Player]: number } = {}
handlers.code = function(player, _party, payload)
	if typeof(payload.code) ~= "string" then
		return
	end
	local now = os.clock()
	if now - (lastCodeLookup[player] or -math.huge) < CODE_LOOKUP_COOLDOWN then
		return
	end
	lastCodeLookup[player] = now
	Arrivals.joinByCode(player, payload.code, false)
end

handlers.leave = function(player, party, _payload)
	if #party.members <= 1 then
		return
	end
	if party.status == "launching" then
		Net.toast(player, "Too late, the match is starting", "warn")
		return
	end
	Parties.leave(player)
end

handlers.kick = function(player, _party, payload)
	local target = targetOf(payload)
	if target then
		local ok, err = Parties.kick(player, target)
		report(player, ok, err)
		if ok then
			Net.toast(target, "You were removed from the party", "warn")
		end
	end
end

handlers.promote = function(player, _party, payload)
	local target = targetOf(payload)
	if target then
		report(player, Parties.promote(player, target))
	end
end

handlers.rejoin = function(player, party, _payload)
	local info = rejoinable[player]
	if not info or party.status == "countdown" or party.status == "launching" then
		return
	end
	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = info.code
	options:SetTeleportData({ matchId = info.matchId, rejoin = true })
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(game.PlaceId, { player }, options)
	end)
	if not ok then
		warn("[LobbyManager] Rejoin failed:", err)
		Net.toast(player, "Couldn't get back into that match", "bad")
	end
end

handlers.dismissRejoin = function(player, _party, _payload)
	if rejoinable[player] then
		rejoinable[player] = nil
		Parties.dirty = true
		task.spawn(Presence.clearRejoin, player.UserId)
	end
end

local lastAction: { [Player]: number } = {}

Net.Action.OnServerEvent:Connect(function(player: Player, payload: any)
	if typeof(payload) ~= "table" or typeof(payload.action) ~= "string" then
		return
	end
	local handler = handlers[payload.action]
	if not handler then
		return
	end
	local now = os.clock()
	if now - (lastAction[player] or -math.huge) < ACTION_COOLDOWN then
		return
	end
	lastAction[player] = now
	local party = Parties.of(player) or Parties.create(player)
	handler(player, party, payload)
	Parties.dirty = true
end)

--------------------------------------------------------------------------------
-- Players coming and going
--------------------------------------------------------------------------------

local function onPlayerAdded(player: Player)
	if not Parties.of(player) then
		Parties.create(player)
	end
	for _, other in Players:GetPlayers() do
		if other ~= player then
			task.spawn(checkFriend, player, other)
		end
	end
	task.spawn(Arrivals.handle, player)
	task.spawn(checkRejoin, player)
	task.defer(function()
		Net.send(player, stateFor(player))
		Net.GameStateChanged:FireClient(player, { phase = GameConfig.Phase.LOBBY })
	end)
end

local function onPlayerRemoving(player: Player)
	Parties.remove(player)
	rejoinable[player] = nil
	lastAction[player] = nil
	lastCodeLookup[player] = nil
	local id = player.UserId
	for key in friendCache do
		local a, b = string.match(key, "^(%d+):(%d+)$")
		if tonumber(a) == id or tonumber(b) == id then
			friendCache[key] = nil
		end
	end
end

for _, player in Players:GetPlayers() do
	task.spawn(onPlayerAdded, player)
end
Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

-- A player whose teleport failed is still here: put their party back in the menu.
TeleportService.TeleportInitFailed:Connect(function(player: Player, _result: Enum.TeleportResult, message: string)
	local party = Parties.of(player)
	if party and party.status == "launching" then
		Parties.setStatus(party, "idle")
		task.spawn(Presence.clearRejoin, player.UserId)
		Net.send(player, { type = "cancelled", reason = "Teleport failed: " .. message })
	elseif player.Parent then
		Net.toast(player, "Teleport failed: " .. message, "bad")
	end
end)

-- Studio runs the match on this server; when it ends, everyone is back in the menu.
ServerComm.bus("PhaseChanged").Event:Connect(function(phase: number)
	if phase == GameConfig.Phase.LOBBY then
		for _, party in Parties.all() do
			if party.status == "launching" then
				Parties.setStatus(party, "idle")
			end
		end
	end
	Parties.dirty = true
end)

task.spawn(function()
	while true do
		task.wait(PRESENCE_REFRESH)
		Parties.refreshPresence()
	end
end)

print("[LobbyManager] Parties and matchmaking ready")
