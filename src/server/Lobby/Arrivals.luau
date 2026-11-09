--!strict
--------------------------------------------------------------------------------
-- Lobby/Arrivals.luau
-- Getting a player into the right party, wherever they came from:
--   * a join code: this server's party, or a teleport to the lobby server
--     that hosts it (Lobby/Presence)
--   * a game invite: LaunchData carries the inviter's server and party code
--   * home from a match: the first teammate back becomes the meeting point,
--     the rest follow (LobbyReturn sends them here with the party code)
-- A code or invite always skips the party's privacy; it is the invitation.
--------------------------------------------------------------------------------

local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")

local Parties = require(script.Parent:WaitForChild("Parties"))
local Presence = require(script.Parent:WaitForChild("Presence"))
local Net = require(script.Parent:WaitForChild("Net"))

local Arrivals = {}

--- Send a player to another lobby server to join the party with `code` there.
function Arrivals.sendToPartyServer(player: Player, jobId: string, code: string)
	local options = Instance.new("TeleportOptions")
	options.ServerInstanceId = jobId
	options:SetTeleportData({ partyCode = code })
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(game.PlaceId, { player }, options)
	end)
	if not ok then
		warn("[Arrivals] Party server teleport failed:", err)
		Net.toast(player, "Couldn't reach that party's server", "bad")
	end
end

--- Join the party with this code. `viaTeleport` means the player was already
--- sent here for it, so don't look it up on other servers again.
function Arrivals.joinByCode(player: Player, raw: string, viaTeleport: boolean): boolean
	local code = string.upper((string.gsub(raw, "%W", "")))
	if #code < 4 or #code > 6 then
		Net.toast(player, "That code doesn't look right", "warn")
		return false
	end
	local party = Parties.byCode(code)
	if party then
		local ok, err = Parties.join(player, party)
		if ok then
			Net.toast(player, "Joined " .. party.leader.DisplayName .. "'s party", "good")
		else
			Net.toast(player, err or "Couldn't join", "warn")
		end
		return ok
	end
	if not viaTeleport then
		local jobId = Presence.findPartyServer(code)
		if jobId and jobId ~= game.JobId then
			Net.toast(player, "Heading to your party's server")
			Arrivals.sendToPartyServer(player, jobId, code)
			return true
		end
	end
	Net.toast(player, "No party with that code", "warn")
	return false
end

local function regroup(player: Player, matchId: string)
	local entry = Presence.getRegroup(matchId)
	if entry and entry.jobId == game.JobId then
		local party = Parties.byCode(entry.code)
		if party and Parties.join(player, party) then
			Net.toast(player, "Back with your team", "good")
			return
		end
	end
	local mine = Parties.of(player)
	if mine then
		Presence.setRegroup(matchId, mine.code)
	end
end

--- Read how the player got here and put them in the matching party. Yields.
function Arrivals.handle(player: Player)
	local ok, joinData = pcall(function()
		return player:GetJoinData()
	end)
	if not ok or typeof(joinData) ~= "table" then
		return
	end
	local data = joinData :: any
	local teleportData = data.TeleportData
	if typeof(teleportData) == "table" then
		local joined = false
		if typeof(teleportData.partyCode) == "string" then
			joined = Arrivals.joinByCode(player, teleportData.partyCode, true)
		end
		if not joined and typeof(teleportData.fromMatch) == "string" then
			regroup(player, teleportData.fromMatch)
		end
		return
	end
	local launch = data.LaunchData
	if typeof(launch) == "string" and launch ~= "" then
		local decoded, invite = pcall(function()
			return HttpService:JSONDecode(launch)
		end)
		if decoded and typeof(invite) == "table" and typeof(invite.c) == "string" then
			if typeof(invite.j) == "string" and invite.j ~= "" and invite.j ~= game.JobId then
				Arrivals.sendToPartyServer(player, invite.j, invite.c)
			else
				Arrivals.joinByCode(player, invite.c, true)
			end
		end
	end
end

--- The player's rejoin ticket, if their last match is still running. Yields.
function Arrivals.findRejoin(player: Player): Presence.Rejoin?
	local info = Presence.getRejoin(player.UserId)
	if info and Presence.isMatchAlive(info.matchId) then
		return info
	end
	return nil
end

return Arrivals
