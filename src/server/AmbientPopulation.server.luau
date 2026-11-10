--!strict
--------------------------------------------------------------------------------
-- AmbientPopulation.server.luau
-- Fills the venue with ambience: real Roblox avatar rigs seated at desks (in a
-- variety of postures), hackers leaning against hallway walls, and a few
-- crashed out asleep on lounge couches and in sleeping bags on the floor.
--
-- These are NOT the dialogue NPCs (those live in NPCManager). They are anchored,
-- AI-less avatar rigs created by RigFactory. About 85% of seats are
-- filled (Ambient/Seats covers the non-desk seating). They clear out when Night 2 begins (the labs empty as the
-- outbreak starts).
--
-- Postures go through Shared.RigPose. These rigs have no Motor6Ds (each joint
-- is an AnimationConstraint), so editing C0s, as this script used to, did
-- nothing at all. RigPose offsets the joints underneath whatever animation is
-- playing, and the change replicates because the server makes it.
--------------------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local RigPose = require(ReplicatedStorage.Shared.RigPose)
local RigFactory = require(script.Parent.RigFactory)
local AssetLibrary = require(script.Parent.AssetLibrary)
local Seats = require(script.Parent:WaitForChild("Ambient"):WaitForChild("Seats"))

local PHASE_NIGHT2 = GameConfig.Phase.NIGHT2

-- Share of desk seats with a typist; the rest stay free. Lounge seating,
-- stools, benches, beanbags and meeting chairs are filled by Ambient/Seats.
local DESK_FILL = 0.85
local MAX_LEANERS = 10
local MAX_COUCH_SLEEPERS = 4
local MAX_BAG_SLEEPERS = 4

local V = Vector3.new

local folder = Instance.new("Folder")
folder.Name = "AmbientPeople"
folder.Parent = workspace

local spawned: { Model } = {}
local processed: { [Instance]: boolean } = {}
local seatedCount = 0
local maxSeated = 0
local disabledSeats: { Seat } = {}
local leanerCount = 0
local couchSleeperCount = 0
local bagSleeperCount = 0

--------------------------------------------------------------------------------
-- Postures (RigPose conventions: waist/neck X+ forward, shoulders X+ raise
-- forward, elbows X- flex)
--------------------------------------------------------------------------------

local DESK_POSES: { RigPose.Pose } = {
	-- typing: forearms out to the keyboard, eyes on the screen
	{ neck = V(12, 0, 0), rS = V(42, 0, -6), lS = V(42, 0, 6), rE = V(-58, 0, 0), lE = V(-58, 0, 0) },
	{ neck = V(12, 0, 0), rS = V(42, 0, -6), lS = V(42, 0, 6), rE = V(-58, 0, 0), lE = V(-58, 0, 0) },
	{ waist = V(8, 0, 0), neck = V(16, 0, 0), rS = V(46, 0, -8), lS = V(46, 0, 8), rE = V(-52, 0, 0), lE = V(-52, 0, 0) },
	-- passed out on the desk, arms folded under the head
	{ waist = V(44, 0, 0), neck = V(26, 0, 0), rS = V(78, 0, -10), lS = V(78, 0, 10), rE = V(-96, 0, 0), lE = V(-96, 0, 0) },
	-- leaned back, staring at the ceiling
	{ waist = V(-14, 0, 0), neck = V(-12, 0, 0), rS = V(12, 0, 4), lS = V(12, 0, -4) },
	-- chin propped on one hand
	{ waist = V(16, 0, 0), neck = V(8, 0, 9), rS = V(70, 0, -14), rE = V(-118, 0, 0), lS = V(38, 0, 6), lE = V(-60, 0, 0) },
	-- head in both hands
	{ waist = V(24, 0, 0), neck = V(22, 0, 0), rS = V(76, 0, -18), lS = V(76, 0, 18), rE = V(-122, 0, 0), lE = V(-122, 0, 0) },
}

local LEAN_POSES: { RigPose.Pose } = {
	-- scrolling a phone held at the chest
	{ neck = V(30, 0, 0), rS = V(30, 0, -8), rE = V(-104, 0, 0), lS = V(6, 0, 6) },
	-- arms folded
	{ neck = V(4, 0, 0), rS = V(28, 0, -30), lS = V(28, 0, 30), rE = V(-112, 0, 0), lE = V(-112, 0, 0) },
	-- hands in pockets, head tipped back against the wall
	{ neck = V(-10, 0, 0), rS = V(-6, 0, 10), lS = V(-6, 0, -10), rE = V(-28, 0, 0), lE = V(-28, 0, 0) },
}

--- Offset a rig's joints into a posture (layered under its animation).
local function pose(model: Model, p: RigPose.Pose)
	RigPose.new(model):rebase(p)
end

--------------------------------------------------------------------------------
-- Desk workers
--------------------------------------------------------------------------------

local function spawnSeated(seat: Part)
	if seatedCount >= maxSeated then
		return
	end
	seatedCount += 1
	local pos = seat.Position
	local faceZ = (seat:GetAttribute("FaceZ") :: number?) or -1

	local model, hum = RigFactory.create()
	RigFactory.applyHair(model, math.random(0, 999999))
	-- Sit on the chair facing the desk
	model:PivotTo(CFrame.lookAt(pos + V(0, 2.6, 0), pos + V(0, 2.6, faceZ)))
	model.Parent = folder
	RigFactory.sit(model, hum)
	local deskPose = DESK_POSES[math.random(#DESK_POSES)]
	pose(model, deskPose)

	-- Glance up from the screen at whoever walks past (anyone not passed out
	-- face-down on the desk). Foot IK is for rigs that actually walk.
	local slumped = deskPose.waist ~= nil and deskPose.waist.X >= 40
	if not slumped then
		RigFactory.enableHeadTracking(model, hum)
	end

	-- Most coders work off a laptop: hide the workstation's monitor and set a
	-- laptop on the desk in front of them. The station is the seat's parent
	-- model, so the laptop goes in its local space and inherits its rotation.
	-- The template's user side is +Z, the same side as the station's chair, so
	-- it takes the station's orientation unrotated. (It used to be spun 180
	-- degrees, which turned every screen away from its user.)
	local station = seat.Parent
	if math.random() < 0.85 and station and station:IsA("Model") and station.PrimaryPart then
		local monitor = station:FindFirstChild("Monitor")
		if monitor then
			monitor:Destroy()
		end
		local lap = AssetLibrary.clone("Laptop", station:GetPivot() * CFrame.new(0, 3.35, -0.1))
		if lap then
			lap.Parent = model -- cleared with the rig on Night 2
		end
	end

	table.insert(spawned, model)
end

--------------------------------------------------------------------------------
-- Hallway leaners
--------------------------------------------------------------------------------

local LEAN_TILT = math.rad(8) -- how far the body tips back onto the wall
local FEET_OUT = 1.2 -- feet distance from the wall face; puts the shoulder blades on it
local WALL_PROBE = 4.2 -- probe height: above the chair rail, below the posters

local wallParams = RaycastParams.new()
wallParams.FilterType = Enum.RaycastFilterType.Exclude

--- Distance along `dir` to a true wall face, skipping things in front of it
--- (banners, bins, people). Returns the hit position and the distance of the
--- nearest skipped thing, or nil when no wall is in reach.
local function castToWall(origin: Vector3, dir: Vector3): (Vector3?, number, number)
	local params = wallParams
	local ignore: { Instance } = { folder }
	params.FilterDescendantsInstances = ignore
	local lastClutter = 0
	for _ = 1, 10 do
		local hit = workspace:Raycast(origin, dir * 24, params)
		if not hit then
			return nil, 0, 0
		end
		if hit.Instance.Name == "Wall" then
			return hit.Position, hit.Distance, lastClutter
		end
		-- Trim, posters and signs are flat on the wall and don't collide; only
		-- solid furniture (lockers, benches, fountains) is in the way.
		if hit.Instance.CanCollide then
			lastClutter = hit.Distance
		end
		table.insert(ignore, hit.Instance)
		params.FilterDescendantsInstances = ignore
	end
	return nil, 0, 0
end

-- Clear depth needed in front of the wall for a leaning body.
local LEAN_CLEARANCE = FEET_OUT + 1.4
local WALL_DIRS = { V(1, 0, 0), V(-1, 0, 0), V(0, 0, 1), V(0, 0, -1) }
local SPOT_OFFSETS = { V(0, 0, 0), V(4, 0, 0), V(-4, 0, 0), V(0, 0, 4), V(0, 0, -4), V(8, 0, 0), V(-8, 0, 0) }

--- Nearest wall face from `origin` with room in front of it to lean: anything
--- standing against the wall there (lockers, a bench, a fountain) rules that
--- direction out, so a leaner never ends up inside the furniture.
local function nearestWall(origin: Vector3): (Vector3?, Vector3?)
	local best, bestDir, bestDist = nil, nil, math.huge
	for _, dir in WALL_DIRS do
		local side = dir:Cross(Vector3.yAxis)
		local pos, dist = nil, math.huge
		local clear = true
		-- the body's centre line first, then both shoulders and the knees
		for i, off in { Vector3.zero, side * 1.1, -side * 1.1, V(0, -2.6, 0) } do
			local p, d, clutter = castToWall(origin + off, dir)
			if not p or (clutter > 0 and clutter > d - LEAN_CLEARANCE) then
				clear = false
				break
			end
			if i == 1 then
				pos, dist = p, d
			end
		end
		if clear and pos and dist < bestDist then
			best, bestDir, bestDist = pos, dir, dist
		end
	end
	return best, bestDir
end

local function spawnLeaning(spot: Part)
	if leanerCount >= MAX_LEANERS or string.find(spot.Name, "Stair") then
		return -- standing on a staircase reads wrong
	end
	local floorY = spot.Position.Y - 0.2
	-- try the marker, then a few spots either side of it
	local wallPos, wallDir
	for _, off in SPOT_OFFSETS do
		wallPos, wallDir = nearestWall(V(spot.Position.X, floorY + WALL_PROBE, spot.Position.Z) + off)
		if wallPos then
			break
		end
	end
	if not (wallPos and wallDir) then
		return -- nothing clear to lean on; leave the spot empty rather than float
	end
	leanerCount += 1

	local face = -wallDir
	local feet = V(wallPos.X, floorY, wallPos.Z) + face * FEET_OUT
	local model, hum = RigFactory.create()
	RigFactory.applyHair(model, math.random(0, 999999))
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	local rootH = hum.HipHeight + (if root then root.Size.Y / 2 else 1)
	-- Pivot about the feet, tip the body back onto the wall, then stand it up.
	model:PivotTo(CFrame.lookAt(feet, feet + face) * CFrame.Angles(LEAN_TILT, 0, 0) * CFrame.new(0, rootH, 0))
	model.Parent = folder
	-- the lean poses' arms were authored over the stock idle's arms
	model:SetAttribute(RigFactory.POSTURE_KEEP_ARMS, true)
	RigFactory.stand(model, hum)

	local which = math.random(#LEAN_POSES)
	pose(model, LEAN_POSES[which])
	if which == 1 then
		task.defer(Seats.givePhone, model)
	end
	RigFactory.enableHeadTracking(model, hum)
	table.insert(spawned, model)
end

--------------------------------------------------------------------------------
-- Sleepers
--------------------------------------------------------------------------------

--- A hacker asleep sitting up on a lounge couch: slumped to one side, head
--- lolled back.
local function spawnCouchSleeper(seat: Part)
	if couchSleeperCount >= MAX_COUCH_SLEEPERS then
		return
	end
	couchSleeperCount += 1

	-- The cushion Seat faces the way the couch faces (its LookVector).
	local face = seat.CFrame.LookVector
	face = V(face.X, 0, face.Z)
	if face.Magnitude < 0.01 then
		face = V(0, 0, 1)
	end
	face = face.Unit

	-- Cushion top sits ~0.85 below where a seated rig's root wants to be.
	local sitPos = seat.Position + V(0, 0.85, 0)
	local model, hum = RigFactory.create()
	RigFactory.applyHair(model, math.random(0, 999999))
	model:PivotTo(CFrame.lookAt(sitPos, sitPos + face))
	-- Anchor BEFORE parenting so the cushion Seat doesn't auto-weld the rig.
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		root.Anchored = true
	end
	model.Parent = folder
	RigFactory.sit(model, hum)

	local lean = if math.random() < 0.5 then 1 else -1
	pose(model, { waist = V(-6, 0, 12 * lean), neck = V(-16, 0, 22 * lean), rS = V(8, 0, 6), lS = V(8, 0, -6) })
	table.insert(spawned, model)
end

--- A hacker crashed out in a sleeping bag on the floor. The bag's quilt hides
--- the lower body, so the rig is laid flat with its face on the pillow.
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

	-- Lay the rig flat along the bag, head toward the pillow end (-Z of the bag).
	local model = RigFactory.create()
	RigFactory.applyHair(model, math.random(0, 999999))
	model:PivotTo(bagCF * CFrame.new(0, 0.75, -1.4) * CFrame.Angles(math.rad(-90), 0, 0))
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		root.Anchored = true
	end
	model.Parent = folder
	-- one arm curled up under the pillow
	pose(model, { neck = V(0, 30, 0), rS = V(150, 0, -10), rE = V(-70, 0, 0) })
	table.insert(spawned, model)
end

--------------------------------------------------------------------------------
-- Lifecycle
--------------------------------------------------------------------------------

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
	maxSeated = math.floor(#seats * DESK_FILL + 0.5)
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

	local sitters, used = Seats.populate(folder, processed)
	for _, m in sitters do
		table.insert(spawned, m)
	end
	disabledSeats = used

	print(
		string.format(
			"[AmbientPopulation] Placed %d at desks + %d in other seats + %d leaning + %d couch-sleepers + %d bag-sleepers",
			seatedCount,
			#sitters,
			leanerCount,
			couchSleeperCount,
			bagSleeperCount
		)
	)
end

local function clearAll()
	for _, m in spawned do
		if m.Parent then
			m:Destroy()
		end
	end
	table.clear(spawned)
	for _, seat in disabledSeats do
		seat.Disabled = false
	end
	table.clear(disabledSeats)
	table.clear(processed)
	seatedCount, leanerCount, couchSleeperCount, bagSleeperCount = 0, 0, 0, 0
	print("[AmbientPopulation] Cleared ambient hackers")
end

-- Populated once the venue exists, cleared for Night 2, and back for the next
-- match (LOBBY or DAY1) if the night emptied the building.
local populated = false
local function ensurePopulated()
	if not populated then
		populated = true
		-- build every outfit once before the crowd is cloned from them
		RigFactory.preloadLooks(20)
		populate()
	end
end

task.delay(2, ensurePopulated)

task.spawn(function()
	local serverComm = ServerStorage:WaitForChild("ServerComm")
	local phaseBus = serverComm:WaitForChild("PhaseChanged") :: BindableEvent
	phaseBus.Event:Connect(function(phase: number)
		if phase == PHASE_NIGHT2 then
			populated = false
			clearAll()
		elseif phase == GameConfig.Phase.LOBBY or phase == GameConfig.Phase.DAY1 then
			ensurePopulated()
		end
	end)
end)
