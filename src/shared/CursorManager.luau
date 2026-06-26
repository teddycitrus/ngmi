--!strict
--[[
    CursorManager.luau

    Centralised free/restore of the mouse cursor for GUI scenes.

    Gameplay runs in LockFirstPerson, which pins the mouse to screen-centre and
    hides it — that makes any clickable GUI (wire puzzle, coding terminal, dialogue,
    admin panel, …) impossible to use. Rather than every GUI script rolling its own
    unlock/relock (and getting the relock subtly wrong), each scene calls:

        CursorManager.push()   -- when it opens   → frees + shows the cursor
        CursorManager.pop()    -- when it closes  → restores the previous state

    It is reference-counted, so overlapping scenes behave, and it records the EXACT
    prior cursor state on the first push and restores it on the last pop — so it
    works whether we opened from gameplay (LockFirstPerson) or anywhere else,
    without hard-coding which mode to return to.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

local CursorManager = {}

local openCount = 0
local savedCameraMode: Enum.CameraMode? = nil
local savedMouseBehavior: Enum.MouseBehavior? = nil
local savedMouseIcon: boolean? = nil
local savedMinZoom: number? = nil
local savedMaxZoom: number? = nil

--- True while at least one GUI scene currently owns a free cursor.
function CursorManager.isOpen(): boolean
	return openCount > 0
end

--- Free and show the cursor. Call once when a GUI scene opens.
function CursorManager.push()
	openCount += 1
	if openCount > 1 then
		return -- already freed by an earlier scene
	end

	-- Remember exactly how the cursor / camera were set up so we can put it back.
	savedCameraMode = player.CameraMode
	savedMouseBehavior = UserInputService.MouseBehavior
	savedMouseIcon = UserInputService.MouseIconEnabled
	savedMinZoom = player.CameraMinZoomDistance
	savedMaxZoom = player.CameraMaxZoomDistance

	-- IMPORTANT: gameplay pins the camera at first-person zoom (min == max == 0.5).
	-- At that zoom Roblox hard-locks the mouse to screen centre no matter what
	-- CameraMode/MouseBehavior we set — so just switching to Classic ISN'T enough,
	-- the cursor stays trapped. We have to let the camera pull back out of first
	-- person; widening the zoom range forces it to a third-person distance where the
	-- mouse is genuinely free. (The GUI scene covers the screen, so the pulled-back
	-- view behind it doesn't matter.)
	player.CameraMode = Enum.CameraMode.Classic
	player.CameraMinZoomDistance = 10
	player.CameraMaxZoomDistance = 16
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	UserInputService.MouseIconEnabled = true
end

--- Restore the cursor to its pre-push state. Call once when a GUI scene closes.
function CursorManager.pop()
	if openCount == 0 then
		return -- nothing to restore (defensive: unmatched pop)
	end

	openCount -= 1
	if openCount > 0 then
		return -- another scene still wants the cursor free
	end

	-- Restore the zoom clamp first so the camera snaps back to first person, then
	-- re-apply the saved camera mode / mouse state.
	if savedMinZoom ~= nil then
		player.CameraMinZoomDistance = savedMinZoom
	end
	if savedMaxZoom ~= nil then
		player.CameraMaxZoomDistance = savedMaxZoom
	end
	if savedCameraMode ~= nil then
		player.CameraMode = savedCameraMode
	end
	if savedMouseBehavior ~= nil then
		UserInputService.MouseBehavior = savedMouseBehavior
	end
	if savedMouseIcon ~= nil then
		UserInputService.MouseIconEnabled = savedMouseIcon
	end

	savedCameraMode = nil
	savedMouseBehavior = nil
	savedMouseIcon = nil
	savedMinZoom = nil
	savedMaxZoom = nil
end

return CursorManager
