--!strict
--------------------------------------------------------------------------------
-- Lobby/Presence.luau
-- Cross-server lobby bookkeeping, kept in one MemoryStore sorted map:
--
--   party:<code>      lobby server (JobId) hosting the party with that code,
--                     so a join code or invite works from any lobby server
--   rejoin:<userId>   reserved-server access code of the match a player was
--                     sent to, so they can get back in after a disconnect
--   alive:<matchId>   heartbeat from a running match server; rejoin is only
--                     offered while it is fresh
--   regroup:<matchId> lobby server and party code the first player home from
--                     a match landed in, so the rest of the team follows
--
-- Every call yields and is pcall-wrapped. Without MemoryStore (Studio with no
-- API access, throttling) reads return nil and writes return false, and the
-- lobby still works within a single server.
--------------------------------------------------------------------------------

local MemoryStoreService = game:GetService("MemoryStoreService")

local MAP_NAME = "NGMI_Lobby_v1"
local PARTY_TTL = 60 * 60
local REJOIN_TTL = 20 * 60
local ALIVE_TTL = 90
local REGROUP_TTL = 10 * 60

local Presence = {}

local map: MemoryStoreSortedMap? = nil
do
	local ok, result = pcall(function()
		return MemoryStoreService:GetSortedMap(MAP_NAME)
	end)
	if ok then
		map = result
	else
		warn("[Presence] MemoryStore unavailable:", result)
	end
end

local function set(key: string, value: any, ttl: number): boolean
	local m = map
	if not m then
		return false
	end
	local ok, err = pcall(function()
		m:SetAsync(key, value, ttl)
	end)
	if not ok then
		warn("[Presence] SetAsync", key, "failed:", err)
	end
	return ok
end

local function get(key: string): any
	local m = map
	if not m then
		return nil
	end
	local ok, result = pcall(function()
		return m:GetAsync(key)
	end)
	return if ok then result else nil
end

local function remove(key: string)
	local m = map
	if not m then
		return
	end
	pcall(function()
		m:RemoveAsync(key)
	end)
end

-- Parties ---------------------------------------------------------------------

function Presence.registerParty(code: string)
	set("party:" .. code, game.JobId, PARTY_TTL)
end

function Presence.unregisterParty(code: string)
	remove("party:" .. code)
end

--- JobId of the lobby server hosting this party code, if any.
function Presence.findPartyServer(code: string): string?
	local jobId = get("party:" .. code)
	return if typeof(jobId) == "string" and jobId ~= "" then jobId else nil
end

-- Rejoin ----------------------------------------------------------------------

export type Rejoin = { code: string, matchId: string }

function Presence.setRejoin(userId: number, accessCode: string, matchId: string)
	set("rejoin:" .. userId, { code = accessCode, matchId = matchId }, REJOIN_TTL)
end

function Presence.getRejoin(userId: number): Rejoin?
	local value = get("rejoin:" .. userId)
	if typeof(value) == "table" and typeof(value.code) == "string" and typeof(value.matchId) == "string" then
		return { code = value.code, matchId = value.matchId }
	end
	return nil
end

function Presence.clearRejoin(userId: number)
	remove("rejoin:" .. userId)
end

-- Match heartbeat -------------------------------------------------------------

function Presence.markMatchAlive(matchId: string)
	set("alive:" .. matchId, true, ALIVE_TTL)
end

function Presence.clearMatch(matchId: string)
	remove("alive:" .. matchId)
end

function Presence.isMatchAlive(matchId: string): boolean
	return get("alive:" .. matchId) == true
end

-- Regroup after a match -------------------------------------------------------

export type Regroup = { jobId: string, code: string }

function Presence.setRegroup(matchId: string, code: string)
	set("regroup:" .. matchId, { jobId = game.JobId, code = code }, REGROUP_TTL)
end

function Presence.getRegroup(matchId: string): Regroup?
	local value = get("regroup:" .. matchId)
	if typeof(value) == "table" and typeof(value.jobId) == "string" and typeof(value.code) == "string" then
		return { jobId = value.jobId, code = value.code }
	end
	return nil
end

return Presence
