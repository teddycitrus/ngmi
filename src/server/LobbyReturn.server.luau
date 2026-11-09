--!strict
--------------------------------------------------------------------------------
-- LobbyReturn.server.luau
-- Handles the "Return to Lobby" buttons on the ending screens (CutsceneManager)
-- and the death screen (HUD/DeathScreen). Both send
-- GameStateChanged:FireServer({ requestLobby = true }).
--
-- A client can send that at any time, so it only counts when the sender could
-- be looking at one of those screens: the match is over (DAY3), or the sender
-- has a character that is actually dead.
--   * Reserved match server: the player is teleported to a public (lobby)
--     server of this place, one retry on failure. There is no lobby on a match
--     server, so a failed teleport just leaves them where they are (the death
--     screen closes on respawn, the ending stays until the next phase).
--     The team stays together: the first player home becomes the meeting
--     point (Lobby/Presence regroup entry) and the rest are sent to that
--     lobby server and into that party. Leaving on purpose also drops the
--     player's rejoin ticket, and the match server's heartbeat stops at DAY3
--     so nobody is offered a rejoin into a finished match.
--   * Lobby server or Studio, where the match runs on the same server: the
--     request goes to GameStateManager on the RequestLobby bus, which ends the
--     match for everyone when it is over or nobody in it is left alive.
--------------------------------------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TeleportService = game:GetService("TeleportService")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local ServerRole = require(script.Parent:WaitForChild("ServerRole"))
local ServerComm = require(script.Parent:WaitForChild("ServerComm"))
local Presence = require(script.Parent:WaitForChild("Lobby"):WaitForChild("Presence"))

local GameStateChanged = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("GameStateChanged") :: RemoteEvent
local RequestLobby = ServerComm.bus("RequestLobby")

local REQUEST_COOLDOWN = 2 -- seconds; a held or spammed button counts once
local TELEPORT_RETRY_DELAY = 2

local lastRequest: { [Player]: number } = {}

local function currentPhase(): number
	local value = ReplicatedStorage:FindFirstChild("CurrentPhase")
	return if value and value:IsA("IntValue") then value.Value else GameConfig.Phase.LOBBY
end

--- A loaded character whose humanoid is at 0 health. No character (between
--- loads, or a lobby-only player) is not dead.
local function isDead(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health <= 0
end

-- The match this reserved server is running (from the players' teleport data).
local matchId: string? = nil

local function teleportOptions(): TeleportOptions?
	if not matchId then
		return nil
	end
	local options = Instance.new("TeleportOptions")
	local regroup = Presence.getRegroup(matchId)
	if regroup then
		options.ServerInstanceId = regroup.jobId
		options:SetTeleportData({ partyCode = regroup.code, fromMatch = matchId })
	else
		options:SetTeleportData({ fromMatch = matchId })
	end
	return options
end

local function teleportToLobby(player: Player)
	task.spawn(Presence.clearRejoin, player.UserId)
	for attempt = 1, 2 do
		-- First try follows the team; the retry goes to any lobby server in
		-- case the team's server is full or gone.
		local options = if attempt == 1 then teleportOptions() else nil
		local ok, err = pcall(function()
			if options then
				TeleportService:TeleportAsync(game.PlaceId, { player }, options)
			elseif matchId then
				local plain = Instance.new("TeleportOptions")
				plain:SetTeleportData({ fromMatch = matchId })
				TeleportService:TeleportAsync(game.PlaceId, { player }, plain)
			else
				TeleportService:TeleportAsync(game.PlaceId, { player })
			end
		end)
		if ok then
			return
		end
		warn(string.format("[LobbyReturn] Teleport to lobby failed (attempt %d): %s", attempt, tostring(err)))
		task.wait(TELEPORT_RETRY_DELAY)
		if not player.Parent then
			return
		end
	end
end

if ServerRole.isMatchServer then
	local function readMatchId(player: Player)
		if matchId then
			return
		end
		local ok, joinData = pcall(function()
			return player:GetJoinData()
		end)
		local data = if ok and typeof(joinData) == "table" then (joinData :: any).TeleportData else nil
		if typeof(data) == "table" and typeof(data.matchId) == "string" then
			matchId = data.matchId
		end
	end
	Players.PlayerAdded:Connect(readMatchId)
	for _, p in Players:GetPlayers() do
		readMatchId(p)
	end

	-- Heartbeat for the lobby's rejoin offer, until the match reaches its end.
	task.spawn(function()
		while true do
			local id = matchId
			if id then
				if currentPhase() == GameConfig.Phase.DAY3 then
					Presence.clearMatch(id)
					break
				end
				Presence.markMatchAlive(id)
			end
			task.wait(if id then 30 else 2)
		end
	end)
end

GameStateChanged.OnServerEvent:Connect(function(player: Player, data: unknown)
	if typeof(data) ~= "table" or (data :: any).requestLobby ~= true then
		return -- phases are server-driven; nothing else from clients is acted on
	end

	local now = os.clock()
	if now - (lastRequest[player] or -math.huge) < REQUEST_COOLDOWN then
		return
	end
	lastRequest[player] = now

	local phase = currentPhase()
	if phase == GameConfig.Phase.LOBBY then
		return -- already there
	end
	if phase ~= GameConfig.Phase.DAY3 and not isDead(player) then
		return -- mid-match and alive: neither screen can be up
	end

	print("[LobbyReturn]", player.Name, "asked for the lobby in phase", phase)
	if ServerRole.isMatchServer then
		teleportToLobby(player)
	else
		RequestLobby:Fire(player)
	end
end)

Players.PlayerRemoving:Connect(function(player: Player)
	lastRequest[player] = nil
end)
