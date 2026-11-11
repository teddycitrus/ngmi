--!strict
--------------------------------------------------------------------------------
-- Boss/Arena.luau
-- The boss restroom as a fighting arena, read from the PoopMonsterSpawn marker
-- that Venue/Rooms/Service drops in front of the middle stall's toilet:
--   * the open floor in front of the stalls (where the monster may walk),
--   * the toilet it lives in and the stall door it bursts through,
--   * which players are inside.
-- The stall door is flung on the first emergence and put back on reset, so a
-- later match on the same server starts with the restroom intact.
--------------------------------------------------------------------------------

local Players = game:GetService("Players")

local Arena = {}
Arena.__index = Arena

export type Arena = typeof(setmetatable(
	{} :: {
		home: Vector3, -- the toilet the monster lives in (floor level)
		floorY: number,
		intoRoom: Vector3, -- unit vector from the stalls toward the door
		center: Vector3, -- middle of the open floor
		minX: number,
		maxX: number,
		minZ: number,
		maxZ: number,
		bounds: { minX: number, maxX: number, minZ: number, maxZ: number }, -- whole room, for "inside"
		door: { part: BasePart, cf: CFrame, collide: boolean }?,
		latch: { part: BasePart, cf: CFrame, collide: boolean }?,
		flung: boolean,
	},
	Arena
))

local BODY_RADIUS = 4.2 -- keeps the body clear of walls, vanity and stall fronts
local STALL_DEPTH = 6.4 -- Service.bath stallD

--- The room's floor rectangle from its FloorFinish part (falls back to a
--- 36 x 28 box around the marker).
local function floorRect(room: Instance, marker: BasePart): (number, number, number, number, number)
	local floor = room:FindFirstChild("FloorFinish")
	if floor and floor:IsA("BasePart") then
		local s, p = floor.Size, floor.Position
		return p.X - s.X / 2, p.X + s.X / 2, p.Z - s.Z / 2, p.Z + s.Z / 2, p.Y + s.Y / 2
	end
	local p = marker.Position
	return p.X - 18, p.X + 18, p.Z - 26, p.Z + 2, p.Y - 1
end

local function nearestNamed(room: Instance, name: string, near: Vector3, within: number): BasePart?
	local best, bestDist = nil, within
	for _, d in room:GetDescendants() do
		if d.Name == name and d:IsA("BasePart") then
			local dist = (d.Position - near).Magnitude
			if dist < bestDist then
				best, bestDist = d, dist
			end
		end
	end
	return best
end

function Arena.new(marker: BasePart): Arena
	local room = marker.Parent or workspace
	local x0, x1, z0, z1, floorY = floorRect(room, marker)
	local roomCenter = Vector3.new((x0 + x1) / 2, floorY, (z0 + z1) / 2)
	local markerFlat = Vector3.new(marker.Position.X, floorY, marker.Position.Z)

	-- Stalls line the back wall along X, so "into the room" is +-Z.
	local intoRoom = if roomCenter.Z < markerFlat.Z then Vector3.new(0, 0, -1) else Vector3.new(0, 0, 1)

	-- The marker sits 3 studs out from the back wall, inside the stall; the
	-- stall fronts are STALL_DEPTH out. Keep the body in front of them.
	local stallFront = markerFlat.Z + intoRoom.Z * (STALL_DEPTH - 3)
	local minZ, maxZ = z0 + BODY_RADIUS, z1 - BODY_RADIUS
	if intoRoom.Z < 0 then
		maxZ = math.min(maxZ, stallFront - BODY_RADIUS)
	else
		minZ = math.max(minZ, stallFront + BODY_RADIUS)
	end
	-- vanity on the west wall, urinals and screens on the east
	local minX, maxX = x0 + BODY_RADIUS + 2.6, x1 - BODY_RADIUS - 3.6

	local toilet = nearestNamed(room, "Bowl", markerFlat, 6)
	local home = if toilet then Vector3.new(toilet.Position.X, floorY, toilet.Position.Z) else markerFlat

	local self = setmetatable({
		home = home,
		floorY = floorY,
		intoRoom = intoRoom,
		center = Vector3.new((minX + maxX) / 2, floorY, (minZ + maxZ) / 2),
		minX = minX,
		maxX = maxX,
		minZ = minZ,
		maxZ = maxZ,
		bounds = { minX = x0, maxX = x1, minZ = z0, maxZ = z1 },
		door = nil,
		latch = nil,
		flung = false,
	}, Arena)

	local door = nearestNamed(room, "StallDoor", markerFlat + intoRoom * 3.4, 4)
	if door then
		self.door = { part = door, cf = door.CFrame, collide = door.CanCollide }
		local latch = nearestNamed(room, "Latch", door.Position, 3)
		if latch then
			self.latch = { part = latch, cf = latch.CFrame, collide = latch.CanCollide }
		end
	end
	return self
end

--- Clamp a floor-level point into the walkable open floor.
function Arena.clamp(self: Arena, p: Vector3): Vector3
	return Vector3.new(math.clamp(p.X, self.minX, self.maxX), self.floorY, math.clamp(p.Z, self.minZ, self.maxZ))
end

--- Where the monster rises: the open floor right in front of its stall.
function Arena.emergePoint(self: Arena): Vector3
	return self:clamp(self.home + self.intoRoom * 12)
end

--- True when a world position is inside the restroom on the boss floor.
function Arena.contains(self: Arena, p: Vector3): boolean
	local b = self.bounds
	return p.X > b.minX and p.X < b.maxX and p.Z > b.minZ and p.Z < b.maxZ and math.abs(p.Y - self.floorY) < 10
end

export type Fighter = { player: Player, root: BasePart, humanoid: Humanoid }

--- Living players standing in the restroom.
function Arena.fighters(self: Arena): { Fighter }
	local list: { Fighter } = {}
	for _, player in Players:GetPlayers() do
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if root and root:IsA("BasePart") and hum and hum.Health > 0 and self:contains(root.Position) then
			table.insert(list, { player = player, root = root, humanoid = hum })
		end
	end
	return list
end

--- Blow the monster's stall door (and its latch) off its hinges.
function Arena.flingDoor(self: Arena)
	local door = self.door
	if self.flung or not door or not door.part.Parent then
		return
	end
	self.flung = true
	local parts = { door }
	if self.latch and self.latch.part.Parent then
		local weld = Instance.new("WeldConstraint")
		weld.Name = "BossFlingWeld"
		weld.Part0 = door.part
		weld.Part1 = self.latch.part
		weld.Parent = door.part
		table.insert(parts, self.latch)
	end
	for _, entry in parts do
		entry.part.CanCollide = true
		entry.part.Anchored = false
	end
	pcall(function()
		door.part:SetNetworkOwner(nil)
	end)
	door.part.AssemblyLinearVelocity = self.intoRoom * 70 + Vector3.new(math.random(-12, 12), 28, 0)
	door.part.AssemblyAngularVelocity = Vector3.new(math.random(-8, 8), math.random(-10, 10), math.random(-8, 8))
	task.delay(5, function()
		if door.part.Parent and not door.part.Anchored then
			door.part.Anchored = true
		end
	end)
end

--- Put the stall door back exactly as the venue built it.
function Arena.restoreDoor(self: Arena)
	if not self.flung then
		return
	end
	self.flung = false
	-- unweld first: setting CFrame on a welded part drags its partner along
	if self.door then
		local weld = self.door.part:FindFirstChild("BossFlingWeld")
		if weld then
			weld:Destroy()
		end
	end
	for _, entry in { self.door, self.latch } do
		if entry and entry.part.Parent then
			entry.part.Anchored = true
			entry.part.AssemblyLinearVelocity = Vector3.zero
			entry.part.AssemblyAngularVelocity = Vector3.zero
			entry.part.CFrame = entry.cf
			entry.part.CanCollide = entry.collide
		end
	end
end

return Arena
