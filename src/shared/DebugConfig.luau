--!strict
--------------------------------------------------------------------------------
-- DebugConfig.luau
-- Gating for the in-game testing / admin tools (AdminPanel + admin commands).
--
-- The rule is intentionally simple:
--   • In Roblox Studio the tools are ALWAYS available (this is where you test).
--   • On a live server they are only available to the UserIds listed below.
--
-- Both the client (to decide whether to draw the panel) and the server (to
-- decide whether to honour an AdminCommand) require this module, so the gate
-- lives in exactly one place.
--------------------------------------------------------------------------------

local RunService = game:GetService("RunService")

-- Roblox UserIds allowed to use the admin tools on a published server.
-- Add your own UserId here to test live: [123456789] = true,
local ADMIN_USER_IDS: { [number]: boolean } = {
	-- [0] = true,
}

local DebugConfig = {}

DebugConfig.ADMIN_USER_IDS = ADMIN_USER_IDS

--- True if the given player may use the testing tools.
--- In Studio everyone is an admin; on live servers only the allowlist is.
function DebugConfig.isAdmin(player: Player?): boolean
	if RunService:IsStudio() then
		return true
	end
	if player and ADMIN_USER_IDS[player.UserId] then
		return true
	end
	return false
end

return table.freeze(DebugConfig)
