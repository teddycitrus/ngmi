--!strict
--------------------------------------------------------------------------------
-- HeadGlance.client.luau
-- Venue people glance at you when you pass close by: the head turns, nothing
-- else. Runs on each client for its own player only, so every player gets
-- their own eye contact and nothing replicates.
--
-- Rigs opt in with the "HeadGlance" tag (RigFactory.enableHeadTracking). The
-- glance is the Neck joint alone, rotated on top of whatever pose the server
-- set (a desk slump, a phone check), with these limits:
--   * only within GLANCE_RANGE studs
--   * only when you are in front of them (within NOTICE_ANGLE of their facing);
--     someone behind them is simply not noticed
--   * head yaw capped at MAX_YAW, pitch at MAX_PITCH
--   * eased at no more than TURN_SPEED, so a sprint past is a slow look over,
--     never a snap
-- A model with the HeadTrackSuspended attribute (a corrupting NPC) is left
-- alone, as is everyone while a cutscene owns the camera.
--------------------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local TAG = "HeadGlance"
local SUSPEND = "HeadTrackSuspended"

local GLANCE_RANGE = 11 -- studs
local NOTICE_ANGLE = math.rad(100) -- off their facing; beyond this they don't notice
local MAX_YAW = math.rad(50)
local MAX_PITCH = math.rad(18)
local TURN_SPEED = math.rad(70) -- per second, the most a neck moves
local EASE = 3.5 -- 1/s, how quickly the neck closes on its goal
local SCAN_INTERVAL = 0.25 -- seconds between range checks over every tagged rig

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

type Glance = {
	model: Model,
	torso: BasePart,
	head: BasePart,
	handle: Instance, -- Motor6D or the AnimationConstraint's Attachment0
	isMotor: boolean,
	base: CFrame,
	yaw: number,
	pitch: number,
}

local active: { [Model]: Glance } = {}

--- The Neck joint's poseable handle: a Motor6D's C0, or an AnimationConstraint's
--- Attachment0 (rigs from CreateHumanoidModelFromDescription have no Motor6Ds).
local function neckOf(model: Model): (Instance?, boolean)
	local head = model:FindFirstChild("Head")
	if not head then
		return nil, false
	end
	local constraint: AnimationConstraint? = nil
	for _, c in head:GetChildren() do
		if c.Name == "Neck" then
			if c:IsA("Motor6D") then
				return c, true
			elseif c:IsA("AnimationConstraint") then
				constraint = c
			end
		end
	end
	if constraint and constraint.Attachment0 then
		return constraint.Attachment0, false
	end
	return nil, false
end

local function getCF(g: Glance): CFrame
	return if g.isMotor then (g.handle :: Motor6D).C0 else (g.handle :: Attachment).CFrame
end

local function setCF(g: Glance, cf: CFrame)
	if g.isMotor then
		(g.handle :: Motor6D).C0 = cf
	else
		(g.handle :: Attachment).CFrame = cf
	end
end

local function begin(model: Model): Glance?
	local torso = model:FindFirstChild("UpperTorso")
	local head = model:FindFirstChild("Head")
	local handle, isMotor = neckOf(model)
	if not (torso and torso:IsA("BasePart") and head and head:IsA("BasePart") and handle) then
		return nil
	end
	local g: Glance = {
		model = model,
		torso = torso,
		head = head,
		handle = handle,
		isMotor = isMotor,
		base = CFrame.new(),
		yaw = 0,
		pitch = 0,
	}
	g.base = getCF(g)
	return g
end

local function eyePosition(): Vector3?
	local char = player.Character
	local head = char and char:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head.Position
	end
	return nil
end

-- Range scan: cheap, a few times a second, over every tagged rig.
local scanAcc = 0
local function scan(eye: Vector3)
	for _, inst in CollectionService:GetTagged(TAG) do
		if inst:IsA("Model") and not active[inst] and inst:IsDescendantOf(workspace) then
			local root = inst:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") and (root.Position - eye).Magnitude < GLANCE_RANGE + 2 then
				local g = begin(inst)
				if g then
					active[inst] = g
				end
			end
		end
	end
end

local function approach(current: number, goal: number, dt: number): number
	local step = (goal - current) * math.min(1, dt * EASE)
	local cap = TURN_SPEED * dt
	return current + math.clamp(step, -cap, cap)
end

RunService.RenderStepped:Connect(function(dt: number)
	local eye = eyePosition()
	local cutscene = camera.CameraType == Enum.CameraType.Scriptable

	scanAcc += dt
	if eye and not cutscene and scanAcc >= SCAN_INTERVAL then
		scanAcc = 0
		scan(eye)
	end

	for model, g in active do
		if not model.Parent or not g.torso.Parent or not g.handle.Parent then
			active[model] = nil
			continue
		end
		-- A cutscene or a corruption takes the neck over: let go at once rather
		-- than easing out on top of its pose.
		if cutscene or model:GetAttribute(SUSPEND) then
			setCF(g, g.base)
			active[model] = nil
			continue
		end

		local goalYaw, goalPitch = 0, 0
		if eye then
			local toEye = eye - g.head.Position
			if toEye.Magnitude < GLANCE_RANGE then
				-- direction in the torso's frame: -Z forward, +X right
				local d = g.torso.CFrame:VectorToObjectSpace(toEye)
				local flat = Vector3.new(d.X, 0, d.Z)
				local off = math.atan2(-d.X, -d.Z) -- + = to their left
				if flat.Magnitude > 0.1 and math.abs(off) < NOTICE_ANGLE then
					goalYaw = math.clamp(off, -MAX_YAW, MAX_YAW)
					-- Neck +X tips the head back on these rigs, so looking up is +X.
					goalPitch = math.clamp(math.atan2(d.Y, flat.Magnitude), -MAX_PITCH, MAX_PITCH)
				end
			end
		end

		g.yaw = approach(g.yaw, goalYaw, dt)
		g.pitch = approach(g.pitch, goalPitch, dt)

		if goalYaw == 0 and goalPitch == 0 and math.abs(g.yaw) < 0.003 and math.abs(g.pitch) < 0.003 then
			-- settled back at rest: hand the joint back exactly as it was
			setCF(g, g.base)
			active[model] = nil
		else
			setCF(g, g.base * CFrame.Angles(g.pitch, g.yaw, 0))
		end
	end
end)
