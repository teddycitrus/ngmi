--!strict
--------------------------------------------------------------------------------
-- SurfaceWeathering.server.luau
-- Ages the venue once MapBuilder (or the hand-built Venue) has produced
-- workspace.Map. Purely cosmetic; no uploaded textures required.
--
--   • Grime: every plaster / concrete / brick part gets a small random darken
--     and a faint warm or sickly shift, so long walls stop reading as one flat
--     colour. Built-in 2022 materials already carry normal + roughness maps;
--     this breaks up the albedo they sit on.
--   • Puddles: low, slightly transparent, smooth patches on the floor slabs.
--     Under Future with EnvironmentSpecularScale up they pick up crisp
--     specular highlights from ceiling lights and the flashlight: that is
--     what reads as "wet" in Roblox.
--   • Blood (NIGHT2 only): clustered pools with a drag trail, and splatter on
--     nearby walls. Cleared when DAY3 dawns.
--
-- Placement raycasts straight down from well above the slab and only accepts
-- a point if the slab itself is the first thing hit, so nothing spawns under
-- desks or inside walls. All parts are CanQuery = false and live in
-- workspace.Weathering.
--------------------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")

--------------------------------------------------------------------------------
-- Tunables
--------------------------------------------------------------------------------

local GRIME_MATERIALS: { [Enum.Material]: boolean } = {
	[Enum.Material.Plaster] = true,
	[Enum.Material.Concrete] = true,
	[Enum.Material.Brick] = true,
}
local GRIME_DARKEN_MAX = 0.12

local PUDDLES_PER_SLAB_AREA = 1 / 900 -- one per ~30x30 studs of slab
local PUDDLE_MAX_PER_SLAB = 6
local PUDDLE_COLOR = Color3.fromRGB(26, 28, 32)

local BLOOD_POOLS = 14
local BLOOD_COLOR = Color3.fromRGB(62, 3, 7)
local BLOOD_WALL_SEARCH = 7 -- studs from a pool to look for a wall to splatter

local CLEARANCE = 8 -- studs of empty air required above a floor decal

local PHASE_NIGHT2 = 3
local PHASE_DAY3 = 4

--------------------------------------------------------------------------------
-- Setup
--------------------------------------------------------------------------------

local map = workspace:WaitForChild("Map", 120)
if not map then
	warn("[SurfaceWeathering] workspace.Map never appeared; skipping")
	return
end

local folder = Instance.new("Folder")
folder.Name = "Weathering"
folder.Parent = workspace

local bloodFolder: Folder? = nil
local rng = Random.new()

local castParams = RaycastParams.new()
castParams.FilterType = Enum.RaycastFilterType.Exclude
castParams.FilterDescendantsInstances = { folder }
castParams.IgnoreWater = true

local function decalPart(name: string, size: Vector3, cf: CFrame, color: Color3, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

--- Flat disc lying on a floor: a Cylinder's axis is X, so roll it onto its side.
local function floorDisc(name: string, pos: Vector3, diameter: number, color: Color3, parent: Instance): Part
	local cf = CFrame.new(pos) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), math.rad(90))
	local p = decalPart(name, Vector3.new(0.02, diameter, diameter), cf, color, parent)
	p.Shape = Enum.PartType.Cylinder
	return p
end

--- Random point on top of `slab` with nothing but air above it, or nil.
local function sampleFloor(slab: BasePart): Vector3?
	local half = slab.Size / 2
	local topY = slab.Position.Y + half.Y
	for _ = 1, 6 do
		local x = slab.Position.X + rng:NextNumber(-half.X + 2, half.X - 2)
		local z = slab.Position.Z + rng:NextNumber(-half.Z + 2, half.Z - 2)
		local hit = workspace:Raycast(Vector3.new(x, topY + CLEARANCE, z), Vector3.new(0, -CLEARANCE - 1, 0), castParams)
		-- Rooms lay a thin carpet / tile finish over the slab; that counts too.
		if hit and (hit.Instance == slab or hit.Instance.Name == "FloorFinish") then
			return Vector3.new(x, hit.Position.Y, z)
		end
	end
	return nil
end

-- Slabs are found during the grime pass (one walk over the map serves both)
-- and the venue never changes them, so the list is built once.
local slabsByLevel: { [number]: { BasePart } } = {}
local topSlabLevel = -1
local walkableSlabs: { BasePart }? = nil

local function noteSlab(d: BasePart)
	if d.Parent then
		local level = tonumber(string.match(d.Parent.Name, "^Slab_(%d+)$"))
		if level then
			slabsByLevel[level] = slabsByLevel[level] or {}
			table.insert(slabsByLevel[level], d)
			topSlabLevel = math.max(topSlabLevel, level)
		end
	end
end

--- Walkable floor slabs. MapBuilder files them under Slab_<level>; the highest
--- level is the roof deck, whose top nobody walks on, so it is left out.
local function floorSlabs(): { BasePart }
	if walkableSlabs then
		return walkableSlabs
	end
	local slabs: { BasePart } = {}
	for level, list in slabsByLevel do
		if level ~= topSlabLevel or topSlabLevel == 0 then
			table.move(list, 1, #list, #slabs + 1, slabs)
		end
	end
	walkableSlabs = slabs
	return slabs
end

--------------------------------------------------------------------------------
-- Grime
--------------------------------------------------------------------------------

local function applyGrime()
	local count = 0
	for _, d in map:GetDescendants() do
		if not d:IsA("BasePart") then
			continue
		end
		if d.Name == "Slab" then
			noteSlab(d)
		elseif GRIME_MATERIALS[d.Material] then
			local darken = rng:NextNumber(0, GRIME_DARKEN_MAX)
			local shift = if rng:NextNumber() < 0.5
				then Color3.fromRGB(60, 50, 30) -- nicotine warm
				else Color3.fromRGB(40, 52, 40) -- damp green
			local c = d.Color:Lerp(Color3.new(0, 0, 0), darken):Lerp(shift, rng:NextNumber(0, 0.05))
			d.Color = c
			count += 1
		end
	end
	return count
end

--------------------------------------------------------------------------------
-- Puddles
--------------------------------------------------------------------------------

local function placePuddles(): number
	local placed = 0
	for _, slab in floorSlabs() do
		local area = slab.Size.X * slab.Size.Z
		local n = math.min(PUDDLE_MAX_PER_SLAB, math.floor(area * PUDDLES_PER_SLAB_AREA))
		for _ = 1, n do
			local pos = sampleFloor(slab)
			if pos then
				-- Two or three overlapping discs make an organic blob.
				local base = rng:NextNumber(2.5, 5.5)
				for i = 1, rng:NextInteger(2, 3) do
					local off = if i == 1 then Vector3.zero else Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1)) * base * 0.45
					local disc = floorDisc("Puddle", pos + off + Vector3.new(0, 0.012 + i * 0.001, 0), base * rng:NextNumber(0.55, 1), PUDDLE_COLOR, folder)
					disc.Transparency = 0.35
					disc.Reflectance = 0.12
				end
				placed += 1
			end
		end
	end
	return placed
end

--------------------------------------------------------------------------------
-- Blood (NIGHT2)
--------------------------------------------------------------------------------

local function wallSplatter(origin: Vector3, parent: Instance)
	local dir = Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1))
	if dir.Magnitude < 0.1 then
		return
	end
	local start = origin + Vector3.new(0, rng:NextNumber(2, 4.5), 0)
	local hit = workspace:Raycast(start, dir.Unit * BLOOD_WALL_SEARCH, castParams)
	if not hit or math.abs(hit.Normal.Y) > 0.2 then
		return
	end
	for _ = 1, rng:NextInteger(3, 7) do
		local jitter = Vector3.new(0, rng:NextNumber(-1, 1), 0) + hit.Normal:Cross(Vector3.yAxis) * rng:NextNumber(-1.2, 1.2)
		local pos = hit.Position + hit.Normal * 0.012 + jitter
		local d = rng:NextNumber(0.2, 1.1)
		local p = decalPart("BloodSplatter", Vector3.new(0.02, d, d), CFrame.fromMatrix(pos, hit.Normal, Vector3.yAxis), BLOOD_COLOR, parent)
		p.Shape = Enum.PartType.Cylinder
		p.Reflectance = 0.05
	end
	-- One long run dripping down from the splatter.
	local runLen = rng:NextNumber(0.8, 2.4)
	local runPos = hit.Position + hit.Normal * 0.014 - Vector3.new(0, runLen / 2, 0)
	decalPart("BloodRun", Vector3.new(0.12, runLen, 0.02), CFrame.lookAt(runPos, runPos + hit.Normal), BLOOD_COLOR, parent)
end

local function spawnBlood()
	if bloodFolder then
		return
	end
	local f = Instance.new("Folder")
	f.Name = "Blood"
	f.Parent = folder
	bloodFolder = f

	local slabs = floorSlabs()
	if #slabs == 0 then
		return
	end
	for _ = 1, BLOOD_POOLS do
		local pos = sampleFloor(slabs[rng:NextInteger(1, #slabs)])
		if pos then
			local size = rng:NextNumber(1.2, 3.2)
			for i = 1, rng:NextInteger(3, 5) do
				local off = if i == 1 then Vector3.zero else Vector3.new(rng:NextNumber(-1, 1), 0, rng:NextNumber(-1, 1)) * size * 0.6
				local disc = floorDisc("BloodPool", pos + off + Vector3.new(0, 0.016 + i * 0.001, 0), size * rng:NextNumber(0.35, 1), BLOOD_COLOR, f)
				disc.Reflectance = 0.06
			end
			-- Drag trail: something was pulled away from here.
			if rng:NextNumber() < 0.6 then
				local len = rng:NextNumber(4, 10)
				local yaw = rng:NextNumber(0, math.pi * 2)
				local dir = Vector3.new(math.cos(yaw), 0, math.sin(yaw))
				local mid = pos + dir * (len / 2) + Vector3.new(0, 0.014, 0)
				local trail = decalPart("BloodTrail", Vector3.new(size * 0.35, 0.02, len), CFrame.lookAt(mid, mid + dir), BLOOD_COLOR, f)
				trail.Transparency = 0.25
			end
			wallSplatter(pos, f)
		end
	end
end

local function clearBlood()
	if bloodFolder then
		bloodFolder:Destroy()
		bloodFolder = nil
	end
end

--------------------------------------------------------------------------------
-- Run
--------------------------------------------------------------------------------

-- Let MapBuilder finish parenting furniture before sampling the floors.
task.wait(2)

local grimed = applyGrime()
local puddles = placePuddles()
print(string.format("[SurfaceWeathering] Grime on %d parts, %d puddles", grimed, puddles))

task.spawn(function()
	local phaseValue = ReplicatedStorage:WaitForChild("CurrentPhase", 60)
	if not (phaseValue and phaseValue:IsA("IntValue")) then
		return
	end
	local function onPhase(phase: number)
		if phase == PHASE_NIGHT2 then
			spawnBlood()
		elseif phase == PHASE_DAY3 or phase == 0 then
			clearBlood()
		end
	end
	phaseValue.Changed:Connect(onPhase)
	onPhase(phaseValue.Value)
end)
