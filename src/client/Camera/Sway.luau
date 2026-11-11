--!strict
--------------------------------------------------------------------------------
-- Camera/Sway.luau
-- First-person camera motion for CameraController: a slow walk/sprint sway, a
-- lean into fast turns, and the Z / X corner peek. Applied as a relative
-- offset on top of the camera every frame, only while gameplay owns it.
--------------------------------------------------------------------------------

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local localPlayer = Players.LocalPlayer
local camera = workspace.CurrentCamera

-- Camera sway parameters.
-- The motion is a slow side-to-side sway (lateral drift + a gentle lean/roll),
-- NOT an up-and-down step bob. The vertical component is kept tiny, just a
-- faint bounce so it doesn't feel perfectly rigid. Sprinting swings wider and
-- faster. These are *target* values that the live sway lerps toward, so the
-- transition between walking and sprinting feels smooth rather than snapping.
local WALK_SWAY_FREQUENCY = 0.4 -- side-to-side cycles per second while walking (very slow)
local WALK_SWAY_AMPLITUDE_X = 0.035 -- lateral drift (studs), the main motion
local WALK_SWAY_AMPLITUDE_Y = 0.004 -- vertical bounce (studs), barely there
local WALK_SWAY_ROLL = 0.8 -- camera lean into the sway (degrees)

-- Sprinting keeps the SAME amplitude as walking, just twice the speed.
local SPRINT_SWAY_FREQUENCY = WALK_SWAY_FREQUENCY * 2
local SPRINT_SWAY_AMPLITUDE_X = WALK_SWAY_AMPLITUDE_X
local SPRINT_SWAY_AMPLITUDE_Y = WALK_SWAY_AMPLITUDE_Y
local SPRINT_SWAY_ROLL = WALK_SWAY_ROLL

local SWAY_LERP_SPEED = 6 -- how quickly sway eases between walk/sprint states

-- Turn lean: the camera rolls slightly into fast mouse turns, like a head
-- following the eyes. Driven by yaw rate, smoothed, and hard-capped.
local TURN_LEAN_PER_RAD = 0.9 -- degrees of roll per rad/s of yaw
local TURN_LEAN_MAX = 2.5 -- degrees
local TURN_LEAN_SMOOTH = 8 -- exponential smoothing rate

-- Corner peek: hold Z / X to lean left / right around cover. Q and E are taken
-- by the inventory (drop / use). The offset is raycast-clamped so a peek can
-- never push the camera through a wall.
local PEEK_LEFT_KEY = Enum.KeyCode.Z
local PEEK_RIGHT_KEY = Enum.KeyCode.X
local PEEK_OFFSET = 1.3 -- studs of lateral head travel
local PEEK_DROP = 0.15 -- studs the head dips as it leans out
local PEEK_ROLL = 11 -- degrees
local PEEK_SMOOTH = 10
local PEEK_WALL_MARGIN = 0.4 -- studs kept between camera and wall

local Sway = {}

-- Sway state (persists for the whole session; the game is always first-person)
local swayConnection: RBXScriptConnection? = nil
local swayPhase: number = 0 -- accumulated oscillation phase
-- Live sway values, lerped toward the walk/sprint targets each frame
local curFreq: number = WALK_SWAY_FREQUENCY
local curAmpY: number = WALK_SWAY_AMPLITUDE_Y
local curAmpX: number = WALK_SWAY_AMPLITUDE_X
local curRoll: number = 0

-- Turn lean / peek state
local lastYaw: number? = nil
local turnLean: number = 0 -- degrees, smoothed
local peekInput: number = 0 -- -1 left, 0 none, 1 right
local peekAmount: number = 0 -- smoothed -1..1
local peekKeys = { left = false, right = false }
local peekParams = RaycastParams.new()
peekParams.FilterType = Enum.RaycastFilterType.Exclude
peekParams.IgnoreWater = true
local peekFilterChar: Model? = nil -- character the filter list was last built for

--------------------------------------------------------------------------------
-- Camera Sway
-- A single persistent RenderStepped loop. Sway intensity scales with how fast
-- the player is actually moving (zero when standing still) and ramps up sharply
-- while sprinting. The current sway parameters ease toward the walk/sprint
-- targets so toggling sprint doesn't cause a visible snap.
--------------------------------------------------------------------------------

--- Start the loop. `isActive` says whether gameplay owns the camera right now.
function Sway.start(isActive: () -> boolean)
	if swayConnection then
		return
	end

	swayConnection = RunService.RenderStepped:Connect(function(dt: number)
		-- Suspended outside gameplay and whenever anything else owns the camera
		-- (CinematicCamera and CutsceneManager both switch it to Scriptable).
		if not isActive() or camera.CameraType ~= Enum.CameraType.Custom then
			lastYaw = nil
			return
		end

		local character = localPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			return
		end

		-- 0 when standing still, ~1 when moving under player control
		local moveRatio = math.clamp(humanoid.MoveDirection.Magnitude, 0, 1)

		-- The StaminaController sets this attribute while the player sprints
		local sprinting = (localPlayer:GetAttribute("Sprinting") == true) and moveRatio > 0.01

		-- Pick the target sway profile for this frame
		local targetFreq = if sprinting then SPRINT_SWAY_FREQUENCY else WALK_SWAY_FREQUENCY
		local targetAmpY = if sprinting then SPRINT_SWAY_AMPLITUDE_Y else WALK_SWAY_AMPLITUDE_Y
		local targetAmpX = if sprinting then SPRINT_SWAY_AMPLITUDE_X else WALK_SWAY_AMPLITUDE_X
		local targetRoll = if sprinting then SPRINT_SWAY_ROLL else WALK_SWAY_ROLL

		-- Ease the live values toward the target
		local alpha = math.clamp(dt * SWAY_LERP_SPEED, 0, 1)
		curFreq += (targetFreq - curFreq) * alpha
		curAmpY += (targetAmpY - curAmpY) * alpha
		curAmpX += (targetAmpX - curAmpX) * alpha
		curRoll += (targetRoll - curRoll) * alpha

		-- Only advance the oscillation while actually moving
		swayPhase += dt * curFreq * moveRatio

		-- Side-to-side is the primary motion: lateral drift + a matching lean/roll
		-- both ride the base frequency, so the camera gently rocks left↔right.
		local lateral = math.sin(swayPhase * math.pi * 2)
		local swayX = lateral * curAmpX * moveRatio
		local roll = lateral * curRoll * moveRatio

		-- Vertical is a tiny secondary bounce at double frequency (one dip per
		-- footfall) so the sway doesn't feel perfectly flat, but stays subtle.
		local swayY = math.sin(swayPhase * math.pi * 4) * curAmpY * moveRatio

		-- Turn lean: roll into the yaw rate. Yaw is unwrapped across the +/-pi seam.
		local camCF = camera.CFrame
		local look = camCF.LookVector
		local yaw = math.atan2(-look.X, -look.Z)
		local yawRate = 0
		if lastYaw and dt > 0 then
			local delta = yaw - lastYaw
			if delta > math.pi then
				delta -= 2 * math.pi
			elseif delta < -math.pi then
				delta += 2 * math.pi
			end
			yawRate = delta / dt
		end
		lastYaw = yaw
		local targetLean = math.clamp(yawRate * TURN_LEAN_PER_RAD, -TURN_LEAN_MAX, TURN_LEAN_MAX)
		turnLean += (targetLean - turnLean) * (1 - math.exp(-TURN_LEAN_SMOOTH * dt))

		-- Corner peek, clamped by a sideways ray so it stops short of walls.
		peekAmount += (peekInput - peekAmount) * (1 - math.exp(-PEEK_SMOOTH * dt))
		local peekX = peekAmount * PEEK_OFFSET
		if math.abs(peekX) > 0.01 then
			if character ~= peekFilterChar then
				peekFilterChar = character
				peekParams.FilterDescendantsInstances = if character then { character } else {}
			end
			local side = camCF.RightVector * math.sign(peekX)
			local hit = workspace:Raycast(camCF.Position, side * (math.abs(peekX) + PEEK_WALL_MARGIN), peekParams)
			if hit then
				peekX = math.sign(peekX) * math.max(0, hit.Distance - PEEK_WALL_MARGIN)
			end
		end
		local peekY = -math.abs(peekAmount) * PEEK_DROP
		local peekRoll = -peekAmount * PEEK_ROLL

		camera.CFrame = camCF
			* CFrame.new(swayX + peekX, swayY + peekY, 0)
			* CFrame.Angles(0, 0, math.rad(roll + turnLean + peekRoll))
	end)
end

-- Corner peek input. Key-up always clears, even when gameProcessed, so a lean
-- can never stick if a menu opened mid-press.
local function refreshPeek()
	peekInput = (if peekKeys.right then 1 else 0) - (if peekKeys.left then 1 else 0)
end

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.KeyCode == PEEK_LEFT_KEY then
		peekKeys.left = true
		refreshPeek()
	elseif input.KeyCode == PEEK_RIGHT_KEY then
		peekKeys.right = true
		refreshPeek()
	end
end)

UserInputService.InputEnded:Connect(function(input: InputObject)
	if input.KeyCode == PEEK_LEFT_KEY then
		peekKeys.left = false
		refreshPeek()
	elseif input.KeyCode == PEEK_RIGHT_KEY then
		peekKeys.right = false
		refreshPeek()
	end
end)

return Sway
