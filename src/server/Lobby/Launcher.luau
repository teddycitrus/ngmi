--!strict
--------------------------------------------------------------------------------
-- Lobby/Launcher.luau
-- Takes a group of parties that make up one match from "match found" to
-- in-game:
--   1. Lock the parties (status countdown) and tell everyone who they are
--      playing with.
--   2. Count down. If anyone leaves the server or their party, cancel: parties
--      that were matchmaking go back to searching, the rest back to the menu.
--   3. Published game: reserve a fresh server and teleport the whole group in
--      together (one retry), leaving a rejoin ticket for each player. If the
--      teleport never happens the parties are released after LAUNCH_TIMEOUT.
--      Studio: start the match on this server (teleports don't work there).
--------------------------------------------------------------------------------

local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")

local Parties = require(script.Parent:WaitForChild("Parties"))
local Presence = require(script.Parent:WaitForChild("Presence"))
local Net = require(script.Parent:WaitForChild("Net"))
local ServerRole = require(script.Parent.Parent:WaitForChild("ServerRole"))
local ServerComm = require(script.Parent.Parent:WaitForChild("ServerComm"))

type Party = Parties.Party

local COUNTDOWN_SECONDS = 5
local LAUNCH_TIMEOUT = 45
local TELEPORT_RETRY_DELAY = 2

-- Studio spawn: just inside the main hall entrance, spread out.
local ARENA_CENTER = Vector3.new(0, 8, -40)
local SPAWN_OFFSETS = {
	Vector3.new(-10, 0, 0),
	Vector3.new(10, 0, 0),
	Vector3.new(0, 0, -10),
	Vector3.new(0, 0, 10),
}

local Launcher = {}

local function newMatchId(): string
	return "MATCH-" .. string.sub(HttpService:GenerateGUID(false), 1, 8)
end

local function playersOf(group: { Party }): { Player }
	local list = {}
	for _, party in group do
		for _, m in party.members do
			table.insert(list, m)
		end
	end
	return list
end

--- Name of someone who dropped out of the group since `roster` was taken,
--- or nil while everyone is still in place.
local function whoLeft(group: { Party }, roster: { [Party]: { Player } }): string?
	for _, party in group do
		local before = roster[party]
		if not Parties.byId(party.id) then
			return before[1] and before[1].DisplayName or "A player"
		end
		for _, m in before do
			if m.Parent == nil or Parties.of(m) ~= party then
				return m.DisplayName
			end
		end
		if #party.members ~= #before then
			return "A player"
		end
	end
	return nil
end

--- Put the group's parties back where they were before the match was found.
local function release(group: { Party }, wasSearching: { [Party]: number? }, matchId: string)
	for _, party in group do
		if Parties.byId(party.id) and party.matchId == matchId then
			local since = wasSearching[party]
			if since and party.fill and #party.members < party.mode then
				Parties.setStatus(party, "searching")
				party.searchSince = since -- keep their place in line
			else
				Parties.setStatus(party, "idle")
			end
		end
	end
end

local function startLocally(players: { Player }, matchId: string, mode: number)
	for i, player in players do
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			root.CFrame = CFrame.new(ARENA_CENTER + SPAWN_OFFSETS[((i - 1) % #SPAWN_OFFSETS) + 1])
		end
	end
	local names = {}
	for _, p in players do
		table.insert(names, p.DisplayName)
	end
	for _, p in players do
		Net.StartGame:FireClient(p, { matchId = matchId, players = names, queueSize = mode })
	end
	ServerComm.bus("StartMatch"):Fire(players)
end

--- Reserve a server and send the group there. Returns false if it could not
--- be done after one retry.
local function teleport(players: { Player }, matchId: string, mode: number): boolean
	local reserved, accessCode = pcall(function()
		return TeleportService:ReserveServer(game.PlaceId)
	end)
	if not reserved or typeof(accessCode) ~= "string" then
		warn("[Launcher] ReserveServer failed:", accessCode)
		return false
	end

	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = accessCode
	options:SetTeleportData({ matchId = matchId, queueSize = #players, mode = mode })

	for attempt = 1, 2 do
		local present = {}
		for _, p in players do
			if p.Parent then
				table.insert(present, p)
			end
		end
		if #present == 0 then
			return true
		end
		for _, p in present do
			task.spawn(Presence.setRejoin, p.UserId, accessCode, matchId)
		end
		local ok, err = pcall(function()
			TeleportService:TeleportAsync(game.PlaceId, present, options)
		end)
		if ok then
			print(string.format("[Launcher] %s: teleporting %d player(s)", matchId, #present))
			return true
		end
		warn(string.format("[Launcher] TeleportAsync failed (attempt %d): %s", attempt, tostring(err)))
		if attempt == 1 then
			task.wait(TELEPORT_RETRY_DELAY)
		end
	end
	for _, p in players do
		task.spawn(Presence.clearRejoin, p.UserId)
	end
	return false
end

--- Run one group from countdown to launch. Yields; call with task.spawn.
function Launcher.begin(group: { Party })
	local matchId = newMatchId()
	local mode = group[1].mode
	local roster: { [Party]: { Player } } = {}
	local wasSearching: { [Party]: number? } = {}
	for _, party in group do
		roster[party] = table.clone(party.members)
		wasSearching[party] = if party.status == "searching" then party.searchSince else nil
		Parties.setStatus(party, "countdown")
		party.matchId = matchId
	end

	local players = playersOf(group)
	local names = {}
	for _, p in players do
		table.insert(names, p.DisplayName)
	end
	for _, p in players do
		Net.MatchFound:FireClient(p, {
			matchId = matchId,
			players = names,
			countdownSeconds = COUNTDOWN_SECONDS,
			queueSize = #players,
		})
	end

	for remaining = COUNTDOWN_SECONDS, 1, -1 do
		Net.sendAll(players, { type = "countdown", remaining = remaining, names = names })
		task.wait(1)
		local gone = whoLeft(group, roster)
		if gone then
			release(group, wasSearching, matchId)
			Net.sendAll(players, { type = "cancelled", reason = gone .. " left. Match cancelled." })
			return
		end
	end

	for _, party in group do
		Parties.setStatus(party, "launching")
		party.matchId = matchId
	end
	Net.sendAll(players, { type = "launching" })

	if ServerRole.isStudio then
		startLocally(players, matchId, mode)
		return
	end

	if not teleport(players, matchId, mode) then
		release(group, {}, matchId)
		Net.sendAll(players, { type = "cancelled", reason = "Couldn't reach a match server. Try again." })
		return
	end

	-- Anyone still here long after the teleport was sent didn't make it.
	task.delay(LAUNCH_TIMEOUT, function()
		for _, party in group do
			if Parties.byId(party.id) and party.status == "launching" and party.matchId == matchId then
				Parties.setStatus(party, "idle")
				for _, m in party.members do
					task.spawn(Presence.clearRejoin, m.UserId)
					Net.send(m, { type = "cancelled", reason = "The teleport didn't go through. Try again." })
				end
			end
		end
	end)
end

return Launcher
