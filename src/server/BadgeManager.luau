--!strict
--------------------------------------------------------------------------------
-- BadgeManager.luau
-- Thin wrapper around BadgeService for awarding the game's ending / achievement
-- badges. Server-only — BadgeService:AwardBadge cannot run on a client.
--
-- Badge IDs live in GameConfig.BADGES; an unconfigured ID (0) is treated as a
-- no-op so the game runs fine before the badges are created on the Creator
-- Dashboard. Fill the real IDs into GameConfig.BADGES once they exist.
--------------------------------------------------------------------------------

local BadgeService = game:GetService("BadgeService")

local BadgeManager = {}

--- Award a badge to a player by its numeric badge id. Safe to call repeatedly:
--- unconfigured (0) and already-owned badges are skipped, and every BadgeService
--- call is pcall-guarded so a web hiccup can never break the caller. Runs on its
--- own thread so the (yielding) web calls don't stall gameplay code.
function BadgeManager.award(player: Player, badgeId: number)
	if not player or not player.Parent then
		return
	end
	if not badgeId or badgeId == 0 then
		return -- unconfigured — silently skip
	end

	task.spawn(function()
		-- Skip if they already own it (avoids redundant awards / analytics noise).
		local okHas, hasBadge = pcall(function()
			return BadgeService:UserHasBadgeAsync(player.UserId, badgeId)
		end)
		if okHas and hasBadge then
			return
		end

		local okAward, err = pcall(function()
			BadgeService:AwardBadge(player.UserId, badgeId)
		end)
		if not okAward then
			warn("[BadgeManager] Failed to award badge " .. tostring(badgeId) .. " to " .. player.Name .. " — " .. tostring(err))
		end
	end)
end

return BadgeManager
