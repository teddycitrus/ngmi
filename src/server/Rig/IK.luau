--!strict
--------------------------------------------------------------------------------
-- Rig/IK.luau
-- IKControl helpers for RigFactory rigs (re-exported as
-- RigFactory.enableHeadTracking and RigFactory.enableFootPlacement).
--------------------------------------------------------------------------------

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local IK = {}

--------------------------------------------------------------------------------
-- Head tracking (IKControl, Type = LookAt)
--------------------------------------------------------------------------------
-- One shared Heartbeat loop drives EVERY registered rig. The venue can hold ~100
-- ambient rigs, and a thread or RenderStep each would be untenable; a single
-- throttled pass with an early distance reject costs almost nothing.
--------------------------------------------------------------------------------

local HEAD_TRACK_RANGE = 26 -- studs; beyond this the head returns to neutral
local HEAD_TRACK_INTERVAL = 0.1 -- seconds between solver updates (10 Hz)
local HEAD_TRACK_LERP = 0.18 -- weight easing per update, so heads never snap

type HeadTracker = {
	model: Model,
	control: IKControl,
	target: Attachment,
	root: BasePart,
}

local headTrackers: { HeadTracker } = {}
local headLoopStarted = false

--- Nearest position from a prepared list, within `range`. The list is gathered
--- once per tick by the loop below rather than per rig: with ~90 tracked rigs,
--- re-walking Players:GetPlayers() for each one is two orders of magnitude more
--- work for the same answer.
local function nearestFrom(positions: { Vector3 }, origin: Vector3, range: number): Vector3?
	local best: Vector3? = nil
	local bestDist = range
	for _, position in positions do
		local dist = (position - origin).Magnitude
		if dist < bestDist then
			bestDist = dist
			best = position
		end
	end
	return best
end

local function startHeadTrackLoop()
	if headLoopStarted then
		return
	end
	headLoopStarted = true

	local accumulator = 0
	RunService.Heartbeat:Connect(function(deltaTime: number)
		accumulator += deltaTime
		if accumulator < HEAD_TRACK_INTERVAL then
			return
		end
		accumulator = 0

		-- Gather eye-height targets once for the whole pass.
		local eyePositions: { Vector3 } = {}
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				-- Aim at head height rather than the root, or NPCs stare at chests.
				table.insert(eyePositions, (root :: BasePart).Position + Vector3.new(0, 1.5, 0))
			end
		end

		-- Nobody in the venue: let every head settle back to neutral and skip the
		-- per-rig work entirely.
		local anyone = #eyePositions > 0

		for i = #headTrackers, 1, -1 do
			local tracker = headTrackers[i]

			-- Reap rigs that have been despawned.
			if not tracker.model.Parent or not tracker.root.Parent then
				table.remove(headTrackers, i)
				continue
			end

			local targetPos = if anyone then nearestFrom(eyePositions, tracker.root.Position, HEAD_TRACK_RANGE) else nil
			if targetPos then
				tracker.target.WorldPosition = targetPos
				tracker.control.Enabled = true
				tracker.control.Weight += (1 - tracker.control.Weight) * HEAD_TRACK_LERP
			else
				tracker.control.Weight += (0 - tracker.control.Weight) * HEAD_TRACK_LERP
				if tracker.control.Weight < 0.02 then
					tracker.control.Weight = 0
					tracker.control.Enabled = false
				end
			end
		end
	end)
end

--- Make a rig glance at the nearest player. Safe to call on anchored rigs (the
--- seated ambient crowd), LookAt only drives the neck chain, so it layers over
--- a sit animation and the hand-set shoulder poses without fighting them.
function IK.enableHeadTracking(model: Model, hum: Humanoid): IKControl?
	local head = model:FindFirstChild("Head")
	local torso = model:FindFirstChild("UpperTorso")
	local root = model:FindFirstChild("HumanoidRootPart")
	if
		not (head and head:IsA("BasePart"))
		or not (torso and torso:IsA("BasePart"))
		or not (root and root:IsA("BasePart"))
	then
		return nil -- R6 fallback rig has no UpperTorso; nothing to drive
	end

	-- Parented to the rig's own root so it is destroyed along with the rig
	-- instead of leaking an attachment when the NPC despawns.
	local target = Instance.new("Attachment")
	target.Name = "HeadTrackTarget"
	target.Parent = root

	local control = Instance.new("IKControl")
	control.Name = "HeadLookAt"
	control.Type = Enum.IKControlType.LookAt
	control.ChainRoot = torso
	control.EndEffector = head
	control.Target = target
	control.Weight = 0
	control.Enabled = false
	control.Parent = hum

	table.insert(headTrackers, {
		model = model,
		control = control,
		target = target,
		root = root :: BasePart,
	})
	startHeadTrackLoop()

	return control
end

--------------------------------------------------------------------------------
-- Foot placement (IKControl, Type = Position)
--------------------------------------------------------------------------------
-- Plants each foot on whatever surface is actually under it, so NPCs walking the
-- venue's stairwell stop floating a few studs above the treads.
--
-- Only worth enabling on rigs that MOVE. The ambient crowd is anchored and
-- seated, so it gets head tracking only.
--------------------------------------------------------------------------------

local FOOT_PROBE_HEIGHT = 3 -- studs above the foot to start the down-ray
local FOOT_PROBE_DEPTH = 5 -- studs below the foot to search
local FOOT_INTERVAL = 0.08 -- seconds between solver updates

local LEGS = {
	{ upper = "LeftUpperLeg", foot = "LeftFoot", name = "LeftFootIK" },
	{ upper = "RightUpperLeg", foot = "RightFoot", name = "RightFootIK" },
}

--- Plant a walking rig's feet on the ground beneath them.
function IK.enableFootPlacement(model: Model, hum: Humanoid): ()
	local root = model:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return
	end
	local rootPart = root :: BasePart

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { model }
	params.IgnoreWater = true

	type FootChain = { control: IKControl, target: Attachment, foot: BasePart }
	local chains: { FootChain } = {}

	for _, leg in LEGS do
		local upper = model:FindFirstChild(leg.upper)
		local foot = model:FindFirstChild(leg.foot)
		if upper and upper:IsA("BasePart") and foot and foot:IsA("BasePart") then
			local target = Instance.new("Attachment")
			target.Name = leg.name .. "Target"
			target.Parent = rootPart

			local control = Instance.new("IKControl")
			control.Name = leg.name
			control.Type = Enum.IKControlType.Position
			control.ChainRoot = upper
			control.EndEffector = foot
			control.Target = target
			control.Weight = 0
			control.Enabled = false
			control.Parent = hum

			table.insert(chains, { control = control, target = target, foot = foot :: BasePart })
		end
	end

	if #chains == 0 then
		return -- R6 fallback rig
	end

	task.spawn(function()
		while model.Parent and rootPart.Parent do
			task.wait(FOOT_INTERVAL)

			for _, chain in chains do
				if not chain.foot.Parent then
					continue
				end

				local origin = chain.foot.Position + Vector3.new(0, FOOT_PROBE_HEIGHT, 0)
				local hit =
					workspace:Raycast(origin, Vector3.new(0, -(FOOT_PROBE_HEIGHT + FOOT_PROBE_DEPTH), 0), params)

				if hit then
					-- Half the foot's height keeps the sole on the surface rather
					-- than sinking its centre into it.
					chain.target.WorldPosition = hit.Position + Vector3.new(0, chain.foot.Size.Y * 0.5, 0)
					chain.control.Enabled = true
					chain.control.Weight = 1
				else
					chain.control.Enabled = false
					chain.control.Weight = 0
				end
			end
		end

		-- Rig despawned; drop the solver so it can't hold a stale pose.
		for _, chain in chains do
			chain.control.Enabled = false
		end
	end)

	-- Foot IK fights the walk animation's own foot placement at speed, so fade it
	-- out while running and back in when the NPC settles.
	hum.Running:Connect(function(speed: number)
		local moving = speed > 0.5
		for _, chain in chains do
			chain.control.Weight = if moving then 0.35 else 1
		end
	end)
end

return IK
