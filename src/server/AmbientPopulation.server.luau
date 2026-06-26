--!strict
--------------------------------------------------------------------------------
-- AmbientPopulation.server.luau
-- Fills the venue with ambience: real Roblox avatar rigs seated at desks (in a
-- variety of postures), hackers sitting against hallway walls with a laptop on
-- their lap, and a few crashed out asleep — on lounge couches and in sleeping
-- bags on the floor.
--
-- These are NOT the dialogue NPCs (those live in NPCManager). They are anchored,
-- AI-less avatar rigs created by RigFactory. Total count is capped for
-- performance. They clear out when Night 2 begins (the labs empty as the
-- outbreak starts).
--------------------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local ServerStorage      = game:GetService("ServerStorage")
local RunService         = game:GetService("RunService")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local RigFactory = require(script.Parent.RigFactory)
local AssetLibrary = require(script.Parent.AssetLibrary)

local PHASE_NIGHT2 = GameConfig.Phase.NIGHT2

-- Performance cap: real rigs are far heavier than the old block models, so we
-- limit how many we place. Lower these if the server struggles.
local MAX_SEATED = 80
local MAX_LEANERS = 10
local MAX_COUCH_SLEEPERS = 4
local MAX_BAG_SLEEPERS = 4

local folder = Instance.new("Folder")
folder.Name = "AmbientPeople"
folder.Parent = workspace

local spawned: { Model } = {}
local processed: { [Instance]: boolean } = {}
local seatedCount = 0
local leanerCount = 0
local couchSleeperCount = 0
local bagSleeperCount = 0

-- Laptops come from the shared, editable AssetLibrary "Laptop" template. The
-- template's user side (where the screen faces) is +Z, so a laptop placed with
-- the same orientation as a rig's HumanoidRootPart has its screen facing back
-- toward that rig.

--------------------------------------------------------------------------------
-- Desk activities — give each seated hacker something to "do": typing, smashing
-- their desk in rage, slumped resting their head, or leaning back. Poses are set
-- once via Motor6D C0 offsets (layered over the sit animation); the type/smash
-- variants also get a subtle looping motion from the shared loop below.
--------------------------------------------------------------------------------

local ACTIVITIES = { "type", "type", "type", "rest", "recline", "smash", "headhand" }

type SeatedAnim = {
	kind: string,
	rS: Motor6D,
	lS: Motor6D,
	baseR: CFrame,
	baseL: CFrame,
	phase: number,
	speed: number,
}
local animatedSeated: { SeatedAnim } = {}

local function motorIn(model: Model, partName: string, motorName: string): Motor6D?
	local part = model:FindFirstChild(partName)
	if not part then
		return nil
	end
	local m = part:FindFirstChild(motorName)
	if m and m:IsA("Motor6D") then
		return m
	end
	return nil
end

local function setupSeatedActivity(model: Model)
	local kind = ACTIVITIES[math.random(#ACTIVITIES)]
	local waist = motorIn(model, "UpperTorso", "Waist")
	local neck = motorIn(model, "Head", "Neck")
	local rS = motorIn(model, "RightUpperArm", "RightShoulder")
	local lS = motorIn(model, "LeftUpperArm", "LeftShoulder")

	if kind == "rest" then
		-- passed out: slumped right forward, head down on the desk, arms folded
		-- under it as a pillow
		if waist then
			waist.C0 = waist.C0 * CFrame.Angles(math.rad(48), 0, 0)
		end
		if neck then
			neck.C0 = neck.C0 * CFrame.Angles(math.rad(28), 0, 0)
		end
		if rS then
			rS.C0 = rS.C0 * CFrame.Angles(math.rad(72), 0, 0)
		end
		if lS then
			lS.C0 = lS.C0 * CFrame.Angles(math.rad(72), 0, 0)
		end
	elseif kind == "recline" then
		-- leaned back in the chair, hands behind the head-ish (arms up a little)
		if waist then
			waist.C0 = waist.C0 * CFrame.Angles(math.rad(-14), 0, 0)
		end
		if neck then
			neck.C0 = neck.C0 * CFrame.Angles(math.rad(-8), 0, 0)
		end
	elseif kind == "headhand" then
		-- bored: chin propped on one hand, elbow on the desk, gazing at the screen
		if waist then
			waist.C0 = waist.C0 * CFrame.Angles(math.rad(18), 0, 0)
		end
		if neck then
			neck.C0 = neck.C0 * CFrame.Angles(math.rad(10), 0, math.rad(8))
		end
		if rS then
			rS.C0 = rS.C0 * CFrame.Angles(math.rad(98), 0, math.rad(-16))
		end
		if lS then
			lS.C0 = lS.C0 * CFrame.Angles(math.rad(34), 0, 0)
		end
	elseif (kind == "type" or kind == "smash") and rS and lS then
		-- arms forward toward the keyboard, glancing down, then animated by the loop
		rS.C0 = rS.C0 * CFrame.Angles(math.rad(42), 0, 0)
		lS.C0 = lS.C0 * CFrame.Angles(math.rad(42), 0, 0)
		if neck then
			neck.C0 = neck.C0 * CFrame.Angles(math.rad(12), 0, 0)
		end
		table.insert(animatedSeated, {
			kind = kind,
			rS = rS,
			lS = lS,
			baseR = rS.C0,
			baseL = lS.C0,
			phase = math.random() * math.pi * 2,
			speed = 0.8 + math.random() * 0.6,
		})
	end
end

-- One shared, throttled loop drives the typing/smashing motion for all rigs.
local animAccum = 0
RunService.Heartbeat:Connect(function(dt: number)
	animAccum += dt
	if animAccum < 0.12 then -- ~8 Hz is plenty for ambient motion
		return
	end
	animAccum = 0
	local t = os.clock()
	for i = #animatedSeated, 1, -1 do
		local a = animatedSeated[i]
		if not a.rS.Parent then
			table.remove(animatedSeated, i)
		elseif a.kind == "type" then
			local bob = math.sin(t * 9 * a.speed + a.phase) * math.rad(7)
			a.rS.C0 = a.baseR * CFrame.Angles(bob, 0, 0)
			a.lS.C0 = a.baseL * CFrame.Angles(-bob, 0, 0)
		else -- smash: periodic angry slam
			local hit = math.sin(t * 3 * a.speed + a.phase) > 0.65 and math.rad(32) or 0
			a.rS.C0 = a.baseR * CFrame.Angles(hit, 0, 0)
			a.lS.C0 = a.baseL * CFrame.Angles(hit, 0, 0)
		end
	end
end)

local function spawnSeated(seat: Part)
	if seatedCount >= MAX_SEATED then
		return
	end
	seatedCount += 1
	local pos = seat.Position
	local faceZ = (seat:GetAttribute("FaceZ") :: number?) or -1

	local model, hum = RigFactory.create()
	-- Sit on the chair facing the desk
	model:PivotTo(CFrame.lookAt(pos + Vector3.new(0, 2.6, 0), pos + Vector3.new(0, 2.6, faceZ)))
	model.Parent = folder
	RigFactory.sit(model, hum)
	setupSeatedActivity(model)

	-- The vast majority of coders work off a LAPTOP, not the desktop monitor.
	-- For those, hide the workstation's monitor + screen glow and set a laptop on
	-- the desk in front of them (screen toward the seated worker). The station is
	-- the seat's parent model, so we can place the laptop in its local space and
	-- it inherits the desk's rotation/jitter.
	local station = seat.Parent
	if math.random() < 0.85 and station and station:IsA("Model") and station.PrimaryPart then
		for _, n in { "Monitor", "Screen" } do
			local m = station:FindFirstChild(n)
			if m then m:Destroy() end
		end
		local lap = AssetLibrary.clone("Laptop", station:GetPivot() * CFrame.new(0, 3.35, -0.3) * CFrame.Angles(0, math.rad(180), 0))
		if lap then
			lap.Parent = model -- cleared with the rig on Night 2
		end
	end

	table.insert(spawned, model)
end

local function spawnLeaning(spot: Part)
	if leanerCount >= MAX_LEANERS then
		return
	end
	leanerCount += 1
	local pos = spot.Position
	local sitY = pos.Y + 1.6
	local origin = Vector3.new(pos.X, sitY, pos.Z)

	-- Find the NEAREST wall in any cardinal direction and sit with the back flush
	-- against it (facing into the room). We do NOT trust the marker's exact position
	-- or a baked "Face" attribute — those left rigs floating in the middle of the
	-- hall whenever a marker was off-centre or the hall ran the other way. Casting
	-- to the real nearest wall guarantees the rig ends up against an actual surface.
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	local ignore: { Instance } = { folder }
	for _, m in CollectionService:GetTagged(GameConfig.TAGS.LEAN_SPOT) do
		table.insert(ignore, m)
	end
	rayParams.FilterDescendantsInstances = ignore

	local DIRS = { Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1) }
	local bestDist = math.huge
	local wallDir: Vector3? = nil
	local wallPos: Vector3? = nil
	for _, d in DIRS do
		local hit = workspace:Raycast(origin, d * 30, rayParams)
		if hit and hit.Distance < bestDist then
			bestDist = hit.Distance
			wallDir = d
			wallPos = hit.Position
		end
	end

	local face: Vector3
	local seatXZ: Vector2
	if wallDir and wallPos then
		face = -wallDir                   -- face AWAY from the wall, into the room
		local seat = wallPos + face * 0.6 -- back flush against the wall
		seatXZ = Vector2.new(seat.X, seat.Z)
	else
		-- truly no wall within range — keep the marker spot + its baked Face
		face = (spot:GetAttribute("Face") :: Vector3?) or Vector3.new(1, 0, 0)
		face = Vector3.new(face.X, 0, face.Z)
		if face.Magnitude < 0.01 then face = Vector3.new(1, 0, 0) end
		face = face.Unit
		seatXZ = Vector2.new(pos.X, pos.Z)
	end
	local seatPos = Vector3.new(seatXZ.X, sitY, seatXZ.Y)
	local model, hum = RigFactory.create()
	model:PivotTo(CFrame.lookAt(seatPos, seatPos + face))
	model.Parent = folder
	RigFactory.sit(model, hum)

	-- Head down + slight forward lean so they're looking at the laptop on their lap.
	local neck = motorIn(model, "Head", "Neck")
	if neck then
		neck.C0 = neck.C0 * CFrame.Angles(math.rad(30), 0, 0)
	end
	local waist = motorIn(model, "UpperTorso", "Waist")
	if waist then
		waist.C0 = waist.C0 * CFrame.Angles(math.rad(12), 0, 0)
	end
	-- Hands forward to hold the laptop.
	local rS = motorIn(model, "RightUpperArm", "RightShoulder")
	local lS = motorIn(model, "LeftUpperArm", "LeftShoulder")
	if rS then
		rS.C0 = rS.C0 * CFrame.Angles(math.rad(46), 0, 0)
	end
	if lS then
		lS.C0 = lS.C0 * CFrame.Angles(math.rad(46), 0, 0)
	end

	-- Laptop open on their lap with the screen facing them. The template's neon
	-- screen faces its local -Z, so (like the desk laptops) we spin it 180° to point
	-- the screen back at the seated rig — placed just in front of and below the root.
	local root = model.PrimaryPart
	if root then
		local laptop = AssetLibrary.clone("Laptop", root.CFrame * CFrame.new(0, -0.35, -1.05) * CFrame.Angles(0, math.rad(180), 0))
		if laptop then
			laptop.Parent = model
		end
	end

	table.insert(spawned, model)
end

--- A hacker asleep sitting up on a lounge couch — slumped to one side, head lolled.
local function spawnCouchSleeper(seat: Part)
	if couchSleeperCount >= MAX_COUCH_SLEEPERS then
		return
	end
	couchSleeperCount += 1

	-- The cushion Seat faces the way the couch faces (its LookVector), so sit them
	-- looking out into the room.
	local face = seat.CFrame.LookVector
	face = Vector3.new(face.X, 0, face.Z)
	if face.Magnitude < 0.01 then
		face = Vector3.new(0, 0, 1)
	end
	face = face.Unit

	-- Cushion top sits ~0.85 below where a seated rig's root wants to be.
	local sitPos = seat.Position + Vector3.new(0, 0.85, 0)
	local model, hum = RigFactory.create()
	model:PivotTo(CFrame.lookAt(sitPos, sitPos + face))
	-- Anchor BEFORE parenting so the cushion Seat (a real Seat) doesn't auto-weld
	-- the rig and yank it out of our slumped pose.
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		root.Anchored = true
	end
	model.Parent = folder
	RigFactory.sit(model, hum)

	-- Slumped sideways, head lolled back and to the side — fast asleep.
	local lean = (math.random() < 0.5) and 1 or -1
	local waist = motorIn(model, "UpperTorso", "Waist")
	if waist then
		waist.C0 = waist.C0 * CFrame.Angles(math.rad(-6), 0, math.rad(12 * lean))
	end
	local neck = motorIn(model, "Head", "Neck")
	if neck then
		neck.C0 = neck.C0 * CFrame.Angles(math.rad(-16), 0, math.rad(20 * lean))
	end

	table.insert(spawned, model)
end

--- A hacker crashed out in a sleeping bag on the floor. The bag's quilt hides the
--- lower body, so we just lay the rig on its back with its arms tucked in.
local function spawnSleepingBag(spot: Part)
	if bagSleeperCount >= MAX_BAG_SLEEPERS then
		return
	end
	bagSleeperCount += 1

	local pos = spot.Position
	local yaw = (spot:GetAttribute("Yaw") :: number?) or 0
	local bagCF = CFrame.new(pos.X, pos.Y, pos.Z) * CFrame.Angles(0, math.rad(yaw), 0)

	local bag = AssetLibrary.clone("SleepingBag", bagCF)
	if bag then
		bag.Parent = folder
		table.insert(spawned, bag)
	end

	-- Lay the rig flat along the bag, head/face toward the pillow end (-Z of the
	-- bag). -90° about the bag's local X tips the standing rig down onto its front;
	-- the quilt covers the body and the face rests on the pillow.
	local model = RigFactory.create()
	local lieCF = bagCF * CFrame.new(0, 1.0, -1.4) * CFrame.Angles(math.rad(-90), 0, 0)
	model:PivotTo(lieCF)
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		root.Anchored = true
	end
	-- Arms down by the sides instead of the default A-pose.
	local rS = motorIn(model, "RightUpperArm", "RightShoulder")
	local lS = motorIn(model, "LeftUpperArm", "LeftShoulder")
	if rS then
		rS.C0 = rS.C0 * CFrame.Angles(0, 0, math.rad(-76))
	end
	if lS then
		lS.C0 = lS.C0 * CFrame.Angles(0, 0, math.rad(76))
	end
	model.Parent = folder

	table.insert(spawned, model)
end

local function populate()
	-- shuffle desk seats so the cap spreads people across all floors
	local seats = {}
	for _, s in CollectionService:GetTagged(GameConfig.TAGS.DESK_SEAT) do
		if s:IsA("BasePart") then
			table.insert(seats, s)
		end
	end
	for i = #seats, 2, -1 do
		local j = math.random(i)
		seats[i], seats[j] = seats[j], seats[i]
	end
	for _, s in seats do
		if not processed[s] then
			processed[s] = true
			spawnSeated(s)
		end
	end

	for _, spot in CollectionService:GetTagged(GameConfig.TAGS.LEAN_SPOT) do
		if spot:IsA("BasePart") and not processed[spot] then
			processed[spot] = true
			if math.random() < 0.45 then
				spawnLeaning(spot)
			end
		end
	end

	-- A few hackers crashed out asleep: on lounge couches and in floor sleeping bags.
	for _, seat in CollectionService:GetTagged(GameConfig.TAGS.COUCH_SEAT) do
		if seat:IsA("BasePart") and not processed[seat] then
			processed[seat] = true
			if math.random() < 0.7 then
				spawnCouchSleeper(seat)
			end
		end
	end
	for _, spot in CollectionService:GetTagged(GameConfig.TAGS.SLEEP_SPOT) do
		if spot:IsA("BasePart") and not processed[spot] then
			processed[spot] = true
			spawnSleepingBag(spot)
		end
	end

	print(string.format(
		"[AmbientPopulation] Placed %d seated + %d leaning + %d couch-sleepers + %d bag-sleepers",
		seatedCount, leanerCount, couchSleeperCount, bagSleeperCount
	))
end

local function clearAll()
	for _, m in spawned do
		if m.Parent then
			m:Destroy()
		end
	end
	table.clear(spawned)
	table.clear(animatedSeated)
	print("[AmbientPopulation] Cleared ambient hackers (Night 2)")
end

task.delay(2, populate)

task.spawn(function()
	local serverComm = ServerStorage:WaitForChild("ServerComm")
	local phaseBus = serverComm:WaitForChild("PhaseChanged") :: BindableEvent
	phaseBus.Event:Connect(function(phase: number)
		if phase == PHASE_NIGHT2 then
			clearAll()
		end
	end)
end)
