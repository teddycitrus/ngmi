--!strict
--------------------------------------------------------------------------------
-- LobbyReturn.server.luau
-- Handles the "Return to Lobby" buttons on the ending screens (CutsceneManager)
-- and the death screen (HUD/DeathScreen). Both send
-- GameStateChanged:FireServer({ requestLobby = true }).
--
-- A client can send that at any time, so it only counts when leaving can't
-- hurt anyone but the sender: the match is over (DAY3, the ending), or the
-- sender is dead. It only ever moves the sender.
--   * On a reserved match server the player is teleported back to a public
--     (lobby) server of this place.
--   * On a lobby server or in Studio, where the match runs on the same server,
--     GameStateManager drops the player from the match over the
--     PlayerLeftMatch bus and sends them the lobby phase; the last player out
--     ends the match.
--------------------------------------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local TeleportService = game:GetService("TeleportService")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local ServerRole = require(script.Parent:WaitForChild("ServerRole"))

local GameStateChanged = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("GameStateChanged") :: RemoteEvent

local REQUEST_COOLDOWN = 2 -- seconds; a held or spammed button counts once

local lastRequest: { [Player]: number } = {}

local function leftMatchBus(): BindableEvent
	local serverComm = ServerStorage:FindFirstChild("ServerComm")
	if not serverComm then
		serverComm = Instance.new("Folder")
		serverComm.Name = "ServerComm"
		serverComm.Parent = ServerStorage
	end
	local found = serverComm:FindFirstChild("PlayerLeftMatch")
	if found and found:IsA("BindableEvent") then
		return found
	end
	local bus = Instance.new("BindableEvent")
	bus.Name = "PlayerLeftMatch"
	bus.Parent = serverComm
	return bus
end

local PlayerLeftMatch = leftMatchBus()

local function currentPhase(): number
	local value = ReplicatedStorage:FindFirstChild("CurrentPhase")
	return if value and value:IsA("IntValue") then value.Value else GameConfig.Phase.LOBBY
end

local function isDead(player: Player): boolean
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	return humanoid == nil or humanoid.Health <= 0
end

--- Teleport to a public server of this place. True if it was dispatched.
local function teleportToLobby(player: Player): boolean
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(game.PlaceId, { player })
	end)
	if not ok then
		warn("[LobbyReturn] Teleport to lobby failed, returning locally:", err)
	end
	return ok
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
		return -- mid-match and alive: the button can't be on screen
	end

	print("[LobbyReturn]", player.Name, "returning to the lobby from phase", phase)
	if ServerRole.isMatchServer and teleportToLobby(player) then
		return
	end
	PlayerLeftMatch:Fire(player)
end)

Players.PlayerRemoving:Connect(function(player: Player)
	lastRequest[player] = nil
end)
