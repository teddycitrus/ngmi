--!strict
--------------------------------------------------------------------------------
-- NightBodies.server.luau
-- The ones who did not make it. As the last night goes on, more hackers turn
-- up lying on the floor around the building: venue avatars that dropped
-- where they were caught, unresponsive, a dark pool under them.
--
-- Each is a RigFactory rig turned into a ragdoll (every joint swapped for a
-- limited ball socket), dropped off balance so it falls into its own heap,
-- then frozen once it has settled so it costs nothing and never twitches.
-- They are always placed somewhere no player can see at that moment, so a
-- body is only ever found, never seen appearing.
--------------------------------------------------------------------------------

local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local RigFactory = require(script.Parent:WaitForChild("RigFactory"))
local Layout = require(script.Parent:WaitForChild("Venue"):WaitForChild("Layout"))

local phaseBus = ServerStorage:WaitForChild("ServerComm"):WaitForChild("PhaseChanged") :: BindableEvent

local NIGHT2 = 3
local FIRST_AFTER = 35 -- seconds after the NGMIs are released
local GAP_MIN, GAP_MAX = 40, 75
local MAX_BODIES = 12
local MIN_PLAYER_DIST = 45
local SETTLE = 5 -- seconds of physics before a body is frozen

local folder: Folder? = nil
local token = 0

local function params(exclude: { Instance }): RaycastParams
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	p.FilterDescendantsInstances = exclude
	p.IgnoreWater = true
	return p
end

local function characters(): { Instance }
	local out: { Instance } = {}
	for _, plr in Players:GetPlayers() do
		if plr.Character then
			table.insert(out, plr.Character)
		end
	end
	return out
end

--- A floor spot in a room or side hall that no player is near or can see.
local function findSpot(): Vector3?
	local exclude = characters()
	if folder then
		table.insert(exclude, folder)
	end
	local p = params(exclude)
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = exclude
	for _ = 1, 40 do
		local level = math.random(0, Layout.FLOORS - 1)
		local cells = Layout.cells(level)
		local c = cells[math.random(#cells)]
		local x = c.minX + 3 + math.random() * math.max(c.maxX - c.minX - 6, 0)
		local z = c.minZ + 3 + math.random() * math.max(c.maxZ - c.minZ - 6, 0)
		local top = Vector3.new(x, Layout.floorY(level) + 6, z)
		local hit = workspace:Raycast(top, Vector3.new(0, -9, 0), p)
		if not hit or math.abs(hit.Position.Y - Layout.floorY(level)) > 1.5 then
			continue
		end
		local spot = hit.Position
		-- room for a body lying down, no furniture in the way
		local blocked = false
		for _, part in workspace:GetPartBoundsInBox(CFrame.new(spot + Vector3.new(0, 1.6, 0)), Vector3.new(5, 2.6, 5), overlap) do
			if part.CanCollide then
				blocked = true
				break
			end
		end
		if blocked then
			continue
		end
		local seen = false
		for _, plr in Players:GetPlayers() do
			local head = plr.Character and plr.Character:FindFirstChild("Head")
			if head and head:IsA("BasePart") then
				local to = spot + Vector3.new(0, 1, 0) - head.Position
				if to.Magnitude < MIN_PLAYER_DIST or workspace:Raycast(head.Position, to, p) == nil then
					seen = true
					break
				end
			end
		end
		if not seen then
			return spot
		end
	end
	return nil
end

--- Swap every joint for a loose, limited ball socket.
local function ragdoll(model: Model, hum: Humanoid)
	hum.PlatformStand = true
	hum.EvaluateStateMachine = false
	hum.RequiresNeck = false
	for _, d in model:GetDescendants() do
		local isJoint = d:IsA("AnimationConstraint") or d:IsA("Motor6D")
		if isJoint then
			local a0: Attachment?, a1: Attachment? = nil, nil
			if d:IsA("AnimationConstraint") then
				a0, a1 = d.Attachment0, d.Attachment1
			elseif d:IsA("Motor6D") and d.Part0 and d.Part1 then
				local name = d.Name .. "RigAttachment"
				local f0 = d.Part0:FindFirstChild(name)
				local f1 = d.Part1:FindFirstChild(name)
				a0 = if f0 and f0:IsA("Attachment") then f0 else nil
				a1 = if f1 and f1:IsA("Attachment") then f1 else nil
			end
			if a0 and a1 then
				local bs = Instance.new("BallSocketConstraint")
				bs.Attachment0 = a0
				bs.Attachment1 = a1
				bs.LimitsEnabled = true
				bs.UpperAngle = if d.Name == "Neck" then 35 else 60
				bs.TwistLimitsEnabled = true
				bs.TwistLowerAngle = -25
				bs.TwistUpperAngle = 25
				bs.Parent = a1.Parent
				d:Destroy()
			end
		elseif d:IsA("BasePart") then
			local root = d.Name == "HumanoidRootPart"
			d.CanCollide = not root
			d.Massless = root
			d.Anchored = false
		end
	end
end

local function spawnBody()
	local spot = findSpot()
	if not (spot and folder) then
		return
	end
	local model, hum = RigFactory.create()
	model.Name = "Body"
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	-- the dead do not keep their colour
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Color = d.Color:Lerp(Color3.fromRGB(70, 70, 76), 0.35)
		end
	end
	ragdoll(model, hum)

	-- Dropped off balance: tipped well past upright, a random way.
	local yaw = math.random() * math.pi * 2
	local tip = math.rad(55 + math.random() * 25) * (if math.random() < 0.5 then 1 else -1)
	model:PivotTo(CFrame.new(spot + Vector3.new(0, 3.2, 0)) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(tip, 0, math.rad(math.random(-20, 20))))
	model.Parent = folder
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			pcall(function()
				d:SetNetworkOwner(nil)
			end)
		end
	end

	task.delay(SETTLE, function()
		if not model.Parent then
			return
		end
		local torso = model:FindFirstChild("UpperTorso") or model:FindFirstChild("Torso")
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") then
				d.Anchored = true
				d.CanCollide = false
			end
		end
		-- a dark pool spreading from under the torso
		if torso and torso:IsA("BasePart") and folder then
			local p = params({ model })
			local hit = workspace:Raycast(torso.Position, Vector3.new(0, -5, 0), p)
			if hit then
				local pool = Instance.new("Part")
				pool.Name = "BloodPool"
				pool.Shape = Enum.PartType.Cylinder
				pool.Anchored, pool.CanCollide, pool.CanQuery, pool.CanTouch = true, false, false, false
				pool.CastShadow = false
				pool.Material = Enum.Material.Glass
				pool.Color = Color3.fromRGB(58, 4, 8)
				pool.Reflectance = 0.08
				local r = 3 + math.random() * 2
				-- clear of the floor plane so the two faces never coincide
				pool.Size = Vector3.new(0.04, r, r * (0.8 + math.random() * 0.3))
				pool.CFrame = CFrame.new(hit.Position + Vector3.new(0, 0.04, 0)) * CFrame.Angles(0, math.random() * math.pi, math.rad(90))
				pool.Parent = model
			end
		end
	end)
end

local function run(t: number)
	while token == t and not workspace:GetAttribute("NightReleased") do
		task.wait(1)
	end
	task.wait(FIRST_AFTER)
	local count = 0
	while token == t and count < MAX_BODIES do
		local ok, err = pcall(spawnBody)
		if not ok then
			warn("[NightBodies] " .. tostring(err))
		end
		count += 1
		task.wait(GAP_MIN + math.random() * (GAP_MAX - GAP_MIN))
	end
end

phaseBus.Event:Connect(function(phase: number)
	token += 1
	if folder then
		folder:Destroy()
		folder = nil
	end
	if phase == NIGHT2 then
		local f = Instance.new("Folder")
		f.Name = "Bodies"
		f.Parent = workspace
		folder = f
		task.spawn(run, token)
	end
end)
