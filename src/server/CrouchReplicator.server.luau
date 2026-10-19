--!strict
--------------------------------------------------------------------------------
-- CrouchReplicator.server.luau
-- Mirrors each player's crouch state onto their character as the "Crouching"
-- attribute, so every client's CharacterAnimator can bend that body's knees.
--
-- The owning client lowers its own HipHeight locally (physics ownership makes
-- the root drop replicate on its own); only the boolean needs a remote. Input
-- is validated as a boolean and rate-limited so the remote can't be spammed.
--------------------------------------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CrouchState = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("CrouchState") :: RemoteEvent

local MIN_INTERVAL = 0.1 -- seconds between accepted toggles per player

local lastApply: { [Player]: number } = {}
-- Latest requested value per player. A toggle that arrives inside the rate
-- window is deferred, never dropped, so the server can't drift out of sync
-- with what the client is actually doing.
local pending: { [Player]: boolean } = {}

local function apply(player: Player)
	local on = pending[player]
	pending[player] = nil
	if on == nil then
		return
	end
	lastApply[player] = os.clock()
	local character = player.Character
	if character then
		character:SetAttribute("Crouching", on)
	end
end

CrouchState.OnServerEvent:Connect(function(player: Player, on: unknown)
	if type(on) ~= "boolean" then
		return
	end
	local alreadyQueued = pending[player] ~= nil
	pending[player] = on
	if alreadyQueued then
		return
	end
	local wait = MIN_INTERVAL - (os.clock() - (lastApply[player] or 0))
	if wait <= 0 then
		apply(player)
	else
		task.delay(wait, apply, player)
	end
end)

Players.PlayerRemoving:Connect(function(player: Player)
	lastApply[player] = nil
	pending[player] = nil
end)
