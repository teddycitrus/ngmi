--!strict
--------------------------------------------------------------------------------
-- Lobby/Parties.luau
-- The party model for the lobby server. Every player in the lobby is always
-- in exactly one party; a fresh player leads a party of one. The leader picks
-- the mode (its size cap: 1, 2 or 4), who may join (public, friends of the
-- leader, or private: code or invite only) and whether matchmaking may fill
-- empty slots with other players.
--
-- Status: idle (in the menu), searching (in matchmaking), countdown (match
-- found, counting down), launching (being sent into the match). Membership
-- only changes while idle or searching.
--
-- This module only holds state and enforces its rules. LobbyManager wires it
-- to remotes and reads `Parties.dirty` to know when to resend the menu state.
--------------------------------------------------------------------------------

local Presence = require(script.Parent:WaitForChild("Presence"))

export type Privacy = "public" | "friends" | "private"
export type Status = "idle" | "searching" | "countdown" | "launching"

export type Party = {
	id: string,
	code: string,
	leader: Player,
	members: { Player },
	ready: { [Player]: boolean },
	mode: number,
	privacy: Privacy,
	fill: boolean,
	status: Status,
	searchSince: number?,
	matchId: string?,
}

local MODES = { [1] = true, [2] = true, [4] = true }
local PRIVACY = { public = true, friends = true, private = true }
local CODE_CHARS = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"
local CODE_LENGTH = 5

local Parties = {}
Parties.MAX_SIZE = 4
-- Set whenever anything a menu shows changes; LobbyManager clears it.
Parties.dirty = false

local byId: { [string]: Party } = {}
local byCode: { [string]: Party } = {}
local ofPlayer: { [Player]: Party } = {}
local nextId = 0

local function touch()
	Parties.dirty = true
end

local function newCode(): string
	for _ = 1, 50 do
		local chars = table.create(CODE_LENGTH, "")
		for i = 1, CODE_LENGTH do
			local n = math.random(#CODE_CHARS)
			chars[i] = string.sub(CODE_CHARS, n, n)
		end
		local code = table.concat(chars)
		if not byCode[code] then
			return code
		end
	end
	return tostring(math.random(10000, 99999))
end

local function dissolve(party: Party)
	byId[party.id] = nil
	byCode[party.code] = nil
	task.spawn(Presence.unregisterParty, party.code)
end

--- Take a player out of whatever party they are in. The next member leads if
--- the leader left; an empty party is dissolved.
local function detach(player: Player)
	local party = ofPlayer[player]
	if not party then
		return
	end
	ofPlayer[player] = nil
	local idx = table.find(party.members, player)
	if idx then
		table.remove(party.members, idx)
	end
	party.ready[player] = nil
	if #party.members == 0 then
		dissolve(party)
	elseif party.leader == player then
		party.leader = party.members[1]
		party.ready[party.leader] = nil
	end
	touch()
end

--- A new party of one, led by `player`.
function Parties.create(player: Player): Party
	detach(player)
	nextId += 1
	local party: Party = {
		id = "P" .. nextId,
		code = newCode(),
		leader = player,
		members = { player },
		ready = {},
		mode = 4,
		privacy = "friends",
		fill = true,
		status = "idle",
		searchSince = nil,
		matchId = nil,
	}
	byId[party.id] = party
	byCode[party.code] = party
	ofPlayer[player] = party
	task.spawn(Presence.registerParty, party.code)
	touch()
	return party
end

function Parties.of(player: Player): Party?
	return ofPlayer[player]
end

function Parties.byId(id: string): Party?
	return byId[id]
end

function Parties.byCode(code: string): Party?
	return byCode[code]
end

function Parties.all(): { Party }
	local list = {}
	for _, party in byId do
		table.insert(list, party)
	end
	return list
end

function Parties.isLeader(player: Player): boolean
	local party = ofPlayer[player]
	return party ~= nil and party.leader == player
end

function Parties.isOpen(party: Party): boolean
	return party.status == "idle" or party.status == "searching"
end

--- Everyone except the leader has readied up.
function Parties.allReady(party: Party): boolean
	for _, m in party.members do
		if m ~= party.leader and not party.ready[m] then
			return false
		end
	end
	return true
end

--- Move `player` into `party`. Privacy is the caller's call (a code or an
--- invite skips it); size and status are checked here.
function Parties.join(player: Player, party: Party): (boolean, string?)
	if ofPlayer[player] == party then
		return false, "You're already in that party"
	end
	if not byId[party.id] then
		return false, "That party is gone"
	end
	if not Parties.isOpen(party) then
		return false, "That party is starting a match"
	end
	if #party.members >= party.mode then
		return false, "That party is full"
	end
	local current = ofPlayer[player]
	if current and not Parties.isOpen(current) then
		return false, "Your match is starting"
	end
	detach(player)
	table.insert(party.members, player)
	ofPlayer[player] = party
	-- Joining a party that is already searching means you are in.
	party.ready[player] = party.status == "searching"
	touch()
	return true, nil
end

--- Leave the current party for a fresh party of one.
function Parties.leave(player: Player): Party
	return Parties.create(player)
end

--- Disconnect: drop the player without making a new party.
function Parties.remove(player: Player)
	detach(player)
end

function Parties.kick(leader: Player, target: Player): (boolean, string?)
	local party = ofPlayer[leader]
	if not party or party.leader ~= leader then
		return false, "Only the leader can do that"
	end
	if target == leader or ofPlayer[target] ~= party then
		return false, nil
	end
	if not Parties.isOpen(party) then
		return false, "Can't change the party now"
	end
	Parties.create(target)
	return true, nil
end

function Parties.promote(leader: Player, target: Player): (boolean, string?)
	local party = ofPlayer[leader]
	if not party or party.leader ~= leader then
		return false, "Only the leader can do that"
	end
	if target == leader or ofPlayer[target] ~= party then
		return false, nil
	end
	party.leader = target
	party.ready[target] = nil
	party.ready[leader] = true
	touch()
	return true, nil
end

function Parties.setMode(party: Party, mode: number): (boolean, string?)
	if not MODES[mode] then
		return false, nil
	end
	if party.status ~= "idle" then
		return false, "Cancel the search first"
	end
	if #party.members > mode then
		return false, string.format("Your party has %d players", #party.members)
	end
	party.mode = mode
	touch()
	return true, nil
end

function Parties.setPrivacy(party: Party, privacy: string): boolean
	if not PRIVACY[privacy] then
		return false
	end
	party.privacy = privacy :: Privacy
	touch()
	return true
end

function Parties.setFill(party: Party, fill: boolean): (boolean, string?)
	if party.status ~= "idle" then
		return false, "Cancel the search first"
	end
	party.fill = fill
	touch()
	return true, nil
end

function Parties.setReady(player: Player, ready: boolean): (boolean, string?)
	local party = ofPlayer[player]
	if not party or party.leader == player then
		return false, nil
	end
	if party.status ~= "idle" then
		return false, "Leave the party to back out"
	end
	party.ready[player] = ready
	touch()
	return true, nil
end

function Parties.setStatus(party: Party, status: Status)
	party.status = status
	if status ~= "searching" then
		party.searchSince = nil
	end
	if status == "idle" or status == "searching" then
		party.matchId = nil
	end
	touch()
end

--- Keep every party code registered past its TTL.
function Parties.refreshPresence()
	for _, party in byId do
		Presence.registerParty(party.code)
	end
end

return Parties
