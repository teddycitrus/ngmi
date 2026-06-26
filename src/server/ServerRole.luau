--!strict
--------------------------------------------------------------------------------
-- ServerRole.luau
-- Tells the rest of the server which kind of server instance this is.
--
-- A published Code Red experience runs two kinds of server:
--   • LOBBY server  — a normal public server where players pick a party size
--                     and queue. No match runs here.
--   • MATCH server  — a brand-new *reserved* server created on demand (via
--                     TeleportService:ReserveServer) that a matched party is
--                     teleported into. The actual game (DAY1 → … → DAY3) runs
--                     here, isolated from everyone else.
--
-- Detection:
--   • A reserved server has a non-empty PrivateServerId AND a PrivateServerOwnerId
--     of 0 (VIP/private servers have a non-zero owner id; public servers have an
--     empty PrivateServerId). That combination uniquely identifies the reserved
--     match servers we create.
--
-- In Studio, PrivateServerId is empty, so we always behave as a LOBBY server and
-- fall back to starting matches on the same server (TeleportService can't move
-- players between servers in Studio).
--------------------------------------------------------------------------------

local RunService = game:GetService("RunService")

local isReserved = (game.PrivateServerId ~= "") and (game.PrivateServerOwnerId == 0)

local ServerRole = {
	-- This instance hosts an actual match (reserved server).
	isMatchServer = isReserved,
	-- This instance is the matchmaking lobby (public / VIP / Studio).
	isLobbyServer = not isReserved,
	-- Running inside Roblox Studio (teleports unavailable → use local fallback).
	isStudio = RunService:IsStudio(),
}

return table.freeze(ServerRole)
