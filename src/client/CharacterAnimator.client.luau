--!strict
--------------------------------------------------------------------------------
-- CharacterAnimator.client.luau
-- Procedural layer on top of the default Roblox animations for every player
-- character (local and remote):
--
--   • Crouch: knees, hips and ankles fold smoothly, the torso tips forward.
--     The local player also lowers HipHeight, which drops the root (and the
--     first-person camera with it); physics ownership replicates that drop.
--     Remote players are posed from the "Crouching" character attribute that
--     CrouchReplicator mirrors from the server.
--   • Movement lean: the upper body leans into acceleration direction and rolls
--     into strafes, eased so starts and stops read as weight, not snaps.
--
-- Posing writes Motor6D.C0 = base * offset. The default Animator owns
-- Transform, so the two layers compose instead of fighting, and C0 edits made
-- on a client never replicate (no bandwidth, no server cost).
--
-- R15 only for the joint work. R6 rigs still get the HipHeight crouch.
--------------------------------------------------------------------------------

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local localPlayer = Players.LocalPlayer

--------------------------------------------------------------------------------
-- Tunables
--------------------------------------------------------------------------------

local CROUCH_HIP_FACTOR = 0.6 -- crouched HipHeight as a share of standing
local CROUCH_SMOOTH = 9
local CROUCH_TORSO_TIP = math.rad(14)

local LEAN_SMOOTH = 6
local LEAN_FORWARD_PER_STUD = math.rad(0.45) -- per stud/s of forward speed
local LEAN_FORWARD_MAX = math.rad(9)
local LEAN_ROLL_PER_STUD = math.rad(0.6) -- per stud/s of strafe speed
local LEAN_ROLL_MAX = math.rad(7)

local CULL_DISTANCE = 120 -- remote characters beyond this are not posed

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

type Body = {
	character: Model,
	humanoid: Humanoid,
	root: BasePart,
	isLocal: boolean,
	motors: { [string]: Motor6D },
	base: { [string]: CFrame },
	crouch: number, -- 0..1 smoothed
	leanPitch: number,
	leanRoll: number,
	standHip: number,
	hipWritten: boolean,
}

local JOINTS = {
	Waist = "UpperTorso",
	LeftHip = "LeftUpperLeg",
	RightHip = "RightUpperLeg",
	LeftKnee = "LeftLowerLeg",
	RightKnee = "RightLowerLeg",
	LeftAnkle = "LeftFoot",
	RightAnkle = "RightFoot",
}

local bodies: { [Model]: Body } = {}

--------------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------------

local function register(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if not (humanoid and humanoid:IsA("Humanoid") and root and root:IsA("BasePart")) then
		return
	end

	local motors: { [string]: Motor6D } = {}
	local base: { [string]: CFrame } = {}
	if humanoid.RigType == Enum.HumanoidRigType.R15 then
		for motorName, partName in JOINTS do
			local part = character:WaitForChild(partName, 5)
			local motor = part and part:FindFirstChild(motorName)
			if motor and motor:IsA("Motor6D") then
				motors[motorName] = motor
				base[motorName] = motor.C0
			end
		end
	end

	bodies[character] = {
		character = character,
		humanoid = humanoid,
		root = root,
		isLocal = player == localPlayer,
		motors = motors,
		base = base,
		crouch = 0,
		leanPitch = 0,
		leanRoll = 0,
		standHip = humanoid.HipHeight,
		hipWritten = false,
	}

	character.AncestryChanged:Connect(function()
		if not character:IsDescendantOf(workspace) then
			bodies[character] = nil
		end
	end)
end

local function watchPlayer(player: Player)
	if player.Character then
		task.spawn(register, player, player.Character)
	end
	player.CharacterAdded:Connect(function(character)
		register(player, character)
	end)
end

--------------------------------------------------------------------------------
-- Posing
--------------------------------------------------------------------------------

local function pose(body: Body, name: string, offset: CFrame)
	local motor = body.motors[name]
	if motor and motor.Parent then
		motor.C0 = body.base[name] * offset
	end
end

local function updateBody(body: Body, dt: number)
	local wantCrouch = if body.isLocal
		then localPlayer:GetAttribute("Crouching") == true
		else body.character:GetAttribute("Crouching") == true

	body.crouch += ((if wantCrouch then 1 else 0) - body.crouch) * (1 - math.exp(-CROUCH_SMOOTH * dt))
	local c = body.crouch

	-- Local HipHeight. Only written while a crouch is in play; when fully
	-- standing it is handed back and re-read, so avatar rescaling that changes
	-- the standing height is respected.
	if body.isLocal then
		if c > 0.001 then
			body.humanoid.HipHeight = body.standHip * (1 - (1 - CROUCH_HIP_FACTOR) * c)
			body.hipWritten = true
		elseif body.hipWritten then
			body.humanoid.HipHeight = body.standHip
			body.hipWritten = false
		else
			body.standHip = body.humanoid.HipHeight
		end
	end

	if next(body.motors) == nil then
		return
	end

	-- Leg fold. With two equal segments the root drops by L * (1 - cos(theta)),
	-- so theta is solved from the target drop: thigh forward by theta, shin
	-- back by 2 * theta, foot forward by theta to stay flat.
	local drop = (1 - CROUCH_HIP_FACTOR) * c
	local theta = math.acos(math.clamp(1 - drop, -1, 1))

	-- Lean from velocity in the character's own frame.
	local vel = body.root.CFrame:VectorToObjectSpace(body.root.AssemblyLinearVelocity)
	local forward = -vel.Z
	local strafe = vel.X
	local targetPitch = -math.clamp(forward * LEAN_FORWARD_PER_STUD, -LEAN_FORWARD_MAX, LEAN_FORWARD_MAX)
	local targetRoll = -math.clamp(strafe * LEAN_ROLL_PER_STUD, -LEAN_ROLL_MAX, LEAN_ROLL_MAX)
	local leanAlpha = 1 - math.exp(-LEAN_SMOOTH * dt)
	body.leanPitch += (targetPitch - body.leanPitch) * leanAlpha
	body.leanRoll += (targetRoll - body.leanRoll) * leanAlpha

	pose(body, "Waist", CFrame.Angles(body.leanPitch - CROUCH_TORSO_TIP * c, 0, body.leanRoll))
	local fold = CFrame.Angles(theta, 0, 0)
	local knee = CFrame.Angles(-2 * theta, 0, 0)
	pose(body, "LeftHip", fold)
	pose(body, "RightHip", fold)
	pose(body, "LeftKnee", knee)
	pose(body, "RightKnee", knee)
	pose(body, "LeftAnkle", fold)
	pose(body, "RightAnkle", fold)
end

RunService.RenderStepped:Connect(function(dt: number)
	local camPos = workspace.CurrentCamera.CFrame.Position
	for character, body in bodies do
		if not body.root.Parent then
			bodies[character] = nil
		elseif body.isLocal or (body.root.Position - camPos).Magnitude <= CULL_DISTANCE then
			updateBody(body, dt)
		end
	end
end)

for _, player in Players:GetPlayers() do
	watchPlayer(player)
end
Players.PlayerAdded:Connect(watchPlayer)

print("[CharacterAnimator] Initialised - procedural crouch and movement lean ready")
