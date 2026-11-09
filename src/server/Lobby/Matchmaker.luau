--!strict
--------------------------------------------------------------------------------
-- Lobby/Matchmaker.luau
-- Fills matches from searching parties. A party searches when its leader
-- starts with open slots and "fill" on. For each mode it looks for a set of
-- searching parties whose sizes add up to exactly the mode, always keeping
-- the longest-waiting party in the group, so nobody is skipped forever.
--------------------------------------------------------------------------------

local Parties = require(script.Parent:WaitForChild("Parties"))

type Party = Parties.Party

local MAX_SCAN = 32 -- parties considered per search pass

local Matchmaker = {}

local function searching(mode: number): { Party }
	local list = {}
	for _, party in Parties.all() do
		if party.status == "searching" and party.mode == mode then
			table.insert(list, party)
		end
	end
	table.sort(list, function(a, b)
		return (a.searchSince or 0) < (b.searchSince or 0)
	end)
	return list
end

function Matchmaker.enqueue(party: Party)
	if party.status == "searching" then
		return
	end
	Parties.setStatus(party, "searching")
	party.searchSince = os.clock()
	-- Joining a searching party commits you, so everyone in it is ready.
	for _, m in party.members do
		party.ready[m] = true
	end
end

function Matchmaker.dequeue(party: Party)
	if party.status == "searching" then
		Parties.setStatus(party, "idle")
	end
end

--- Depth-first pick of parties (in queue order) that sum to `target` players.
local function pick(list: { Party }, start: number, target: number, chosen: { Party }): boolean
	if target == 0 then
		return true
	end
	for i = start, math.min(#list, MAX_SCAN) do
		local size = #list[i].members
		if size <= target then
			table.insert(chosen, list[i])
			if pick(list, i + 1, target - size, chosen) then
				return true
			end
			table.remove(chosen)
		end
	end
	return false
end

--- One group of parties that exactly fills `mode`, or nil. Anchors are tried
--- oldest first, so the longest wait is matched whenever it can be.
function Matchmaker.form(mode: number): { Party }?
	local list = searching(mode)
	for i = 1, math.min(#list, MAX_SCAN) do
		local anchor = list[i]
		local chosen = { anchor }
		if pick(list, i + 1, mode - #anchor.members, chosen) then
			return chosen
		end
	end
	return nil
end

--- Players searching per mode, as a list the client can read.
function Matchmaker.counts(): { { mode: number, players: number } }
	local totals = { [1] = 0, [2] = 0, [4] = 0 }
	for _, party in Parties.all() do
		if party.status == "searching" and totals[party.mode] then
			totals[party.mode] += #party.members
		end
	end
	return {
		{ mode = 1, players = totals[1] },
		{ mode = 2, players = totals[2] },
		{ mode = 4, players = totals[4] },
	}
end

return Matchmaker
