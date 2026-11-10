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
-- Head glance
--------------------------------------------------------------------------------
-- The glance itself runs on each client (client/HeadGlance): a slow, capped
-- turn of the neck alone, toward that client's own player, only when they pass
-- close in front. The server only marks which rigs take part. (It used to be a
-- server LookAt IKControl rooted at the UpperTorso, which bent the whole spine
-- and swung heads up to 180 degrees at players 26 studs away.)
--------------------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")

IK.GLANCE_TAG = "HeadGlance"
-- Boolean attribute on the rig's model that holds its head at rest.
IK.SUSPEND_ATTRIBUTE = "HeadTrackSuspended"

--- Let a rig glance at players who pass close in front of it.
function IK.enableHeadTracking(model: Model, _hum: Humanoid?): ()
	CollectionService:AddTag(model, IK.GLANCE_TAG)
end

--------------------------------------------------------------------------------
-- Body turn (named NPCs standing still)
--------------------------------------------------------------------------------
-- Someone hanging around right behind a standing NPC gets noticed: after a
-- moment the NPC turns, slowly, on the spot to face them. Walking, anchored
-- (seated, posed for a cutscene) and suspended NPCs never turn.
--------------------------------------------------------------------------------

local TURN_RANGE = 7 -- studs
local TURN_BEHIND = math.rad(110) -- off their facing before it counts as behind
local TURN_DWELL = 1.2 -- seconds someone has to stay there first
local TURN_RATE = math.rad(110) -- per second
local TURN_INTERVAL = 0.05

type Turner = { model: Model, hum: Humanoid, root: BasePart, since: number?, goal: Vector3? }
local turners: { Turner } = {}
local turnLoop = false

local function nearestPlayerRoot(origin: Vector3): Vector3?
	local best, bestDist = nil, TURN_RANGE
	for _, p in Players:GetPlayers() do
		local r = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
		if r and r:IsA("BasePart") then
			local d = (r.Position - origin).Magnitude
			if d < bestDist then
				best, bestDist = r.Position, d
			end
		end
	end
	return best
end

local function startTurnLoop()
	if turnLoop then
		return
	end
	turnLoop = true
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < TURN_INTERVAL then
			return
		end
		local step = acc
		acc = 0
		local now = os.clock()
		for i = #turners, 1, -1 do
			local t = turners[i]
			if not t.model.Parent or not t.root.Parent then
				table.remove(turners, i)
				continue
			end
			local root = t.root
			local v = root.AssemblyLinearVelocity
			local idle = not root.Anchored
				and Vector3.new(v.X, 0, v.Z).Magnitude < 0.5
				and t.hum.MoveDirection.Magnitude < 0.1
				and not t.model:GetAttribute(IK.SUSPEND_ATTRIBUTE)
				and not t.model:GetAttribute("CutsceneControlled")
			if not idle then
				t.since, t.goal = nil, nil
				continue
			end

			if not t.goal then
				local target = nearestPlayerRoot(root.Position)
				local behind = false
				if target then
					local to = Vector3.new(target.X - root.Position.X, 0, target.Z - root.Position.Z)
					local fwd = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
					if to.Magnitude > 0.5 and fwd.Magnitude > 0.1 then
						behind = math.acos(math.clamp(to.Unit:Dot(fwd.Unit), -1, 1)) > TURN_BEHIND
					end
				end
				if behind and target then
					t.since = t.since or now
					if now - t.since >= TURN_DWELL then
						t.goal = target
					end
				else
					t.since = nil
				end
			end

			local goal = t.goal
			if goal then
				local to = Vector3.new(goal.X - root.Position.X, 0, goal.Z - root.Position.Z)
				local fwd = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
				if to.Magnitude < 0.5 or fwd.Magnitude < 0.1 then
					t.goal, t.since = nil, nil
					continue
				end
				local cur = math.atan2(-fwd.X, -fwd.Z)
				local want = math.atan2(-to.X, -to.Z)
				local diff = (want - cur + math.pi) % (2 * math.pi) - math.pi
				local turn = math.clamp(diff, -TURN_RATE * step, TURN_RATE * step)
				root.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, cur + turn, 0)
				if math.abs(diff) < math.rad(3) then
					t.goal, t.since = nil, nil
				end
			end
		end
	end)
end

--- Let a free-standing NPC turn round to face someone lingering behind it.
function IK.enableBodyTurn(model: Model, hum: Humanoid): ()
	local root = model:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return
	end
	table.insert(turners, { model = model, hum = hum, root = root })
	startTurnLoop()
end

--------------------------------------------------------------------------------
-- Foot placement (IKControl, Type = Position)
--------------------------------------------------------------------------------
-- Plants each foot on whatever surface is actually under it, so NPCs walking the
-- venue's stairwell stop floating a few studs above the treads. On level floor
-- the legs already reach the ground and the solver stays off: aimed even a
-- little high it folds the knees.
--
-- Only worth enabling on rigs that MOVE. The ambient crowd is anchored and
-- seated, so it gets head tracking only.
--------------------------------------------------------------------------------

local FOOT_PROBE_HEIGHT = 3 -- studs above the foot to start the down-ray
local FOOT_PROBE_DEPTH = 5 -- studs below the foot to search
local FOOT_INTERVAL = 0.08 -- seconds between solver updates
local FOOT_UNEVEN = 0.2 -- studs a foot's ground must differ from level to engage

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

	type FootChain = { control: IKControl, target: Attachment, foot: BasePart, rest: number }
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

			-- How high this body's foot centre sits above the ground when standing
			-- straight. Read now, while the fresh clone is still in its rest pose;
			-- realistic feet are not a box resting on the floor, so half the
			-- part's height is no good.
			local footPart = foot :: BasePart
			local level = rootPart.Position.Y - hum.HipHeight - rootPart.Size.Y / 2
			local rest = math.clamp(footPart.Position.Y - level, 0.05, 1)
			table.insert(chains, { control = control, target = target, foot = footPart, rest = rest })
		end
	end

	if #chains == 0 then
		return -- R6 fallback rig
	end

	-- Weight a planted foot gets; Running below lowers it while walking.
	local plantedWeight = 1

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

				local level = rootPart.Position.Y - hum.HipHeight - rootPart.Size.Y / 2
				if hit and math.abs(hit.Position.Y - level) > FOOT_UNEVEN then
					chain.target.WorldPosition = hit.Position + Vector3.new(0, chain.rest, 0)
					chain.control.Enabled = true
					chain.control.Weight = plantedWeight
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
		plantedWeight = if speed > 0.5 then 0.35 else 1
		for _, chain in chains do
			if chain.control.Enabled then
				chain.control.Weight = plantedWeight
			end
		end
	end)
end

return IK
