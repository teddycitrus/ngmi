--!strict
--[[
	CursorManager.luau

	Centralised free/restore of the mouse cursor for GUI scenes.

	Gameplay runs in LockFirstPerson, which pins the mouse to screen-centre and
	hides it, so any clickable GUI (wire puzzle, coding terminal, dialogue, admin
	panel, ...) is impossible to use. Rather than every GUI script rolling its own
	unlock/relock (and getting the relock subtly wrong), each scene calls:

		CursorManager.push()   -- when it opens:  frees + shows the cursor
		CursorManager.pop()    -- when it closes: restores the previous state

	It is reference-counted, so overlapping scenes behave, and it records the EXACT
	prior cursor state on the FIRST push and restores it on the LAST pop, so it
	works whether we opened from gameplay (LockFirstPerson) or anywhere else,
	without hard-coding which mode to return to.

	Robustness (this is what makes the wire puzzle etc. reliably clickable):
	  * The free-cursor state is re-applied on EVERY push, not only the first. A
	    single leaked/unbalanced push elsewhere used to make the next scene's push
	    a no-op, leaving its GUI with a trapped, hidden cursor.
	  * A per-frame guard re-asserts the free state for as long as ANY scene is
	    open. Gameplay forces first person, and CameraController.lockFirstPerson()
	    (fired on every phase change and at the end of every cutscene) slams the
	    camera back to 0.5 zoom + LockFirstPerson, which re-pins the mouse. The
	    guard makes "a scene is open" authoritative: the cursor stays free until
	    the last pop, no matter what tries to re-lock it underneath.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

local CursorManager = {}

-- Third-person zoom range used while a scene is open. Gameplay pins zoom at
-- first-person (0.5); at that distance Roblox hard-locks the mouse to screen
-- centre regardless of CameraMode/MouseBehavior, so we MUST widen the zoom to
-- actually free the cursor. The GUI covers the screen, so the pulled-back view
-- behind it is never seen.
local FREE_MIN_ZOOM = 10
local FREE_MAX_ZOOM = 16

local openCount = 0
local savedCameraMode: Enum.CameraMode? = nil
local savedMouseBehavior: Enum.MouseBehavior? = nil
local savedMouseIcon: boolean? = nil
local savedMinZoom: number? = nil
local savedMaxZoom: number? = nil
local guardConn: RBXScriptConnection? = nil

--- Force the camera/mouse into the free-cursor state. Idempotent and cheap, so
--- it is safe to call every frame from the guard below.
local function applyFreeCursor()
	if player.CameraMode ~= Enum.CameraMode.Classic then
		player.CameraMode = Enum.CameraMode.Classic
	end
	if player.CameraMinZoomDistance < FREE_MIN_ZOOM then
		player.CameraMinZoomDistance = FREE_MIN_ZOOM
	end
	if player.CameraMaxZoomDistance < FREE_MAX_ZOOM then
		player.CameraMaxZoomDistance = FREE_MAX_ZOOM
	end
	if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
	if not UserInputService.MouseIconEnabled then
		UserInputService.MouseIconEnabled = true
	end
end

-- Scenes that free the mouse themselves, in first person, through Modal
-- buttons (NPC conversations): they only need the arrow shown, not the
-- camera pulled back.
local iconHolds = 0

--- True while at least one GUI scene currently owns a free cursor.
function CursorManager.isOpen(): boolean
	return openCount > 0 or iconHolds > 0
end

--- Show the arrow while Modal buttons free the mouse, without leaving first
--- person (HUDController shows it whenever isOpen()). Pair with
--- releaseIcon().
function CursorManager.holdIcon()
	iconHolds += 1
end

function CursorManager.releaseIcon()
	iconHolds = math.max(0, iconHolds - 1)
end

--- Free and show the cursor. Call once when a GUI scene opens.
function CursorManager.push()
	openCount += 1

	-- Snapshot the real pre-scene state, but only on the FIRST push so nested
	-- scenes can't overwrite it with an already-freed state.
	if openCount == 1 then
		savedCameraMode = player.CameraMode
		savedMouseBehavior = UserInputService.MouseBehavior
		savedMouseIcon = UserInputService.MouseIconEnabled
		savedMinZoom = player.CameraMinZoomDistance
		savedMaxZoom = player.CameraMaxZoomDistance
	end

	-- Always (re)apply the free state, even for nested scenes, so a leaked count
	-- or a first-person re-lock underneath can never leave a scene with a trapped
	-- cursor.
	applyFreeCursor()

	-- Keep re-asserting it for as long as any scene is open.
	if not guardConn then
		guardConn = RunService.Heartbeat:Connect(function()
			if openCount > 0 then
				applyFreeCursor()
			end
		end)
	end
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

	-- Last scene closed: stop the guard FIRST so it can't re-free the cursor a
	-- frame after we restore the gameplay state below.
	if guardConn then
		guardConn:Disconnect()
		guardConn = nil
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
