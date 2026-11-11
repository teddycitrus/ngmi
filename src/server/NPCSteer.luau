--!strict
--------------------------------------------------------------------------------
-- NPCSteer.luau
-- Straight-line walking for the named NPCs with personal space. A character
-- (player or NPC) ahead of the walker and inside its lane makes it step a
-- little to the side; once the lane is clear it heads back to its goal, so it
-- rejoins the line it was on.
--
-- Also puts every NPC in the "NPC" collision group, which does not collide
-- with itself: two NPCs that still brush past each other slide through
-- instead of stepping up onto one another's heads and launching skyward.
--------------------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")

local NPCSteer = {}

local AVOID_RANGE = 7 -- studs ahead that are watched
local AVOID_LANE = 3.5 -- half-width of the walker's lane
local SIDESTEP = 3.5
local TICK = 0.1
local ARRIVE = 2 -- flat studs that count as arrived
local STALL_SECONDS = 3

NPCSteer.GROUP = "NPC"
PhysicsService:RegisterCollisionGroup(NPCSteer.GROUP)
PhysicsService:CollisionGroupSetCollidable(NPCSteer.GROUP, NPCSteer.GROUP, false)

--- Put every part of `model` (and any added later, like accessories) in the
--- NPC collision group.
function NPCSteer.claim(model: Model)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CollisionGroup = NPCSteer.GROUP
		end
	end
	model.DescendantAdded:Connect(function(d)
		if d:IsA("BasePart") then
			d.CollisionGroup = NPCSteer.GROUP
		end
	end)
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

--- Root parts of every other walking character: players and the other NPCs.
local function otherRoots(self: Model): { BasePart }
	local out = {}
	for _, p in Players:GetPlayers() do
		local r = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
		if r and r:IsA("BasePart") then
			table.insert(out, r)
		end
	end
	for _, m in CollectionService:GetTagged("NPC") do
		if m ~= self and m:IsA("Model") then
			local r = m:FindFirstChild("HumanoidRootPart")
			if r and r:IsA("BasePart") then
				table.insert(out, r)
			end
		end
	end
	return out
end

--- Where to head this tick: a sidestep point when someone is in the lane
--- ahead, the current spot when both sides are walled off (wait for them to
--- pass), or nil when the lane is clear.
local function detour(model: Model, root: BasePart, goal: Vector3): Vector3?
	local pos = root.Position
	local toGoal = flat(goal - pos)
	if toGoal.Magnitude < 0.5 then
		return nil
	end
	local dir = toGoal.Unit
	local others = otherRoots(model)
	local nearest: Vector3?, nearestAhead = nil, math.huge
	for _, r in others do
		local off = flat(r.Position - pos)
		local ahead = off:Dot(dir)
		if ahead > 0 and ahead < math.min(AVOID_RANGE, toGoal.Magnitude + 1) and ahead < nearestAhead then
			if (off - dir * ahead).Magnitude < AVOID_LANE then
				nearest, nearestAhead = off, ahead
			end
		end
	end
	if not nearest then
		return nil
	end
	-- step to the side the other character is not on; if it is walled off,
	-- try the other side
	local right = Vector3.new(-dir.Z, 0, dir.X)
	local sides = if nearest:Dot(right) > 0 then { -right, right } else { right, -right }
	local ignore: { Instance } = { model }
	for _, r in others do
		if r.Parent then
			table.insert(ignore, r.Parent)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	for _, side in sides do
		local step = side * SIDESTEP + dir * math.max(nearestAhead, 2)
		if not workspace:Raycast(pos, step, params) then
			return pos + step
		end
	end
	return pos
end

--- Walk to `goal` in a straight leg, sidestepping anyone in the way. Returns
--- false if the walker makes no headway for a few seconds or `timeout` runs out.
function NPCSteer.walkTo(humanoid: Humanoid, root: BasePart, goal: Vector3, timeout: number?): boolean
	local model = humanoid.Parent :: Model
	local deadline = if timeout then os.clock() + timeout else math.huge
	local best = flat(goal - root.Position).Magnitude
	local lastGain = os.clock()
	while humanoid.Health > 0 and root.Parent and os.clock() < deadline do
		local dist = flat(goal - root.Position).Magnitude
		if dist <= ARRIVE then
			return true
		end
		if dist < best - 0.5 then
			best, lastGain = dist, os.clock()
		elseif os.clock() - lastGain > STALL_SECONDS then
			return false
		end
		humanoid:MoveTo(detour(model, root, goal) or goal)
		task.wait(TICK)
	end
	return false
end

return NPCSteer
