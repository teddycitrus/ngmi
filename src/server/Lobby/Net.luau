--!strict
--------------------------------------------------------------------------------
-- Lobby/Net.luau
-- The lobby's remotes and the messages it sends on them (LobbyUI reads them):
--   QueueUpdate  { type = "state", ... }      full menu state (LobbyManager)
--                { type = "toast", text, tone } one-line notice
--                { type = "countdown", remaining, names }
--                { type = "cancelled", reason }
--                { type = "launching" }
--   MatchFound   { matchId, players, countdownSeconds, queueSize }
--   StartGame    same-server start (Studio only)
--------------------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local Net = {}

Net.Action = Remotes:WaitForChild("PlayerJoinedLobby") :: RemoteEvent
Net.QueueUpdate = Remotes:WaitForChild("QueueUpdate") :: RemoteEvent
Net.MatchFound = Remotes:WaitForChild("MatchFound") :: RemoteEvent
Net.StartGame = Remotes:WaitForChild("StartGame") :: RemoteEvent
Net.GameStateChanged = Remotes:WaitForChild("GameStateChanged") :: RemoteEvent

function Net.send(player: Player, payload: { [string]: any })
	if player.Parent then
		Net.QueueUpdate:FireClient(player, payload)
	end
end

function Net.sendAll(players: { Player }, payload: { [string]: any })
	for _, p in players do
		Net.send(p, payload)
	end
end

export type Tone = "info" | "good" | "warn" | "bad"

function Net.toast(player: Player, text: string, tone: Tone?)
	Net.send(player, { type = "toast", text = text, tone = tone or "info" })
end

return Net
