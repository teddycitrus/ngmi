--!strict
--------------------------------------------------------------------------------
-- QuestChairs.luau
-- The four folding chairs for the Chair Hoarder quest. One always goes in the
-- player-desk lab; the rest go to other random level-0 rooms (never a
-- restroom, which may hold the boss). Each chair lands on a free patch of
-- floor found by testing its footprint against every part already in the
-- room, so it works for any room kind without per-room tables.
--
-- Contract: each chair is one BasePart tagged QuestChair with ItemName and
-- QuestId; its legs and back are children of it, so InteractionManager can
-- hide the whole chair by walking the seat's descendants.
--------------------------------------------------------------------------------

local Kit = require(script.Parent.Kit)
local Layout = require(script.Parent.Layout)

local V = Vector3.new
local CF = CFrame.new
local M = Enum.Material

local QuestChairs = {}

QuestChairs.COUNT = 4
QuestChairs.QUEST_ID = "chair_hoarder"

export type Room = { folder: Instance, cell: Layout.Cell, kind: string, playerDesks: boolean }

local RNG = Random.new()
local HALF = V(1.3, 0, 1.3) -- footprint half size, with a little clearance
local HEIGHT = 4.6
local WALL_MARGIN = 3
local DOOR_CLEAR = 6

-- Folding chair facing -Z: a tilted frame runs from the front feet up to the
-- backrest, short rear legs angle back from under the seat. Pieces that meet
-- overlap slightly instead of sharing faces (z-fight rule).
local FRAME_TILT = math.atan(1.25 / 3.3) -- front foot (z -0.55) to frame top (y 3.3, z 0.7)
local REAR_TILT = -math.atan(0.85 / 1.5) -- under the seat (z -0.1) to rear foot (z 0.75)

local function build(parent: Instance, pos: Vector3, yaw: number): BasePart
	local base = CF(pos) * CFrame.Angles(0, yaw, 0)
	local red = Color3.fromRGB(150, 50, 50)
	local steel = Color3.fromRGB(70, 72, 78)
	local frame = function(y: number): number -- frame z at height y
		return -0.55 + 1.25 * y / 3.3
	end
	local seat = Kit.part(parent, "FoldingChair", V(1.5, 0.12, 1.35), base * CF(0, 1.55, -0.05), red, M.Metal)
	Kit.tag(seat, Kit.TAGS.QUEST_CHAIR)
	seat:SetAttribute("ItemName", "Folding Chair")
	seat:SetAttribute("QuestId", QuestChairs.QUEST_ID)
	for _, sx in { -1, 1 } do
		Kit.trim(seat, "ChairFrame", V(0.1, 3.53, 0.1), base * CF(sx * 0.78, 1.65, frame(1.65)) * CFrame.Angles(FRAME_TILT, 0, 0), steel, M.Metal)
		Kit.trim(seat, "ChairLeg", V(0.09, 1.72, 0.09), base * CF(sx * 0.68, 0.75, 0.325) * CFrame.Angles(REAR_TILT, 0, 0), steel, M.Metal)
	end
	Kit.trim(seat, "ChairBack", V(1.5, 0.8, 0.08), base * CF(0, 2.85, frame(2.85)) * CFrame.Angles(FRAME_TILT, 0, 0), red, M.Metal)
	Kit.trim(seat, "ChairBar", V(1.6, 0.07, 0.07), base * CF(0, 0.35, frame(0.35)), steel, M.Metal)
	return seat
end

--- World-space bounding boxes of everything standing in the room.
local function obstacles(folder: Instance): { { Vector3 } }
	local out = {}
	for _, d in folder:GetDescendants() do
		if d:IsA("BasePart") and d.Name ~= "FloorFinish" then
			local cf, h = d.CFrame, d.Size / 2
			local x, y, z = cf.XVector, cf.YVector, cf.ZVector
			local ext = V(
				math.abs(x.X) * h.X + math.abs(y.X) * h.Y + math.abs(z.X) * h.Z,
				math.abs(x.Y) * h.X + math.abs(y.Y) * h.Y + math.abs(z.Y) * h.Z,
				math.abs(x.Z) * h.X + math.abs(y.Z) * h.Y + math.abs(z.Z) * h.Z
			)
			table.insert(out, { cf.Position - ext, cf.Position + ext })
		end
	end
	return out
end

local function nearDoor(c: Layout.Cell, x: number, z: number): boolean
	local cz = (c.minZ + c.maxZ) / 2
	local wallZ = if c.side == "south" then c.minZ else c.maxZ
	for _, dx in c.doorXs do
		if math.abs(x - dx) < DOOR_CLEAR and math.abs(z - wallZ) < DOOR_CLEAR then
			return true
		end
	end
	-- side doors on the east wall (and the west wall of the big halls)
	return math.abs(z - cz) < DOOR_CLEAR and (x > c.maxX - DOOR_CLEAR or x < c.minX + DOOR_CLEAR)
end

--- A random free floor spot in the room, or nil if it is packed.
local function freeSpot(room: Room, y: number): Vector3?
	local c = room.cell
	local boxes = obstacles(room.folder)
	local candidates = {}
	for x = c.minX + WALL_MARGIN, c.maxX - WALL_MARGIN, 2 do
		for z = c.minZ + WALL_MARGIN, c.maxZ - WALL_MARGIN, 2 do
			if not nearDoor(c, x, z) then
				table.insert(candidates, V(x, y, z))
			end
		end
	end
	for i = #candidates, 2, -1 do
		local j = RNG:NextInteger(1, i)
		candidates[i], candidates[j] = candidates[j], candidates[i]
	end
	for _, p in candidates do
		local lo, hi = p - HALF + V(0, 0.15, 0), p + HALF + V(0, HEIGHT, 0)
		local clear = true
		for _, b in boxes do
			local bLo, bHi = b[1], b[2]
			if bLo.X < hi.X and bHi.X > lo.X and bLo.Y < hi.Y and bHi.Y > lo.Y and bLo.Z < hi.Z and bHi.Z > lo.Z then
				clear = false
				break
			end
		end
		if clear then
			return p
		end
	end
	return nil
end

--- Place the chairs among this floor's rooms. Call after room content is in.
function QuestChairs.place(rooms: { Room }, level: number)
	local y = Layout.floorY(level)
	local order: { Room } = {}
	local others: { Room } = {}
	for _, r in rooms do
		if r.playerDesks then
			table.insert(order, r)
		elseif r.kind ~= "bath" then
			table.insert(others, r)
		end
	end
	for i = #others, 2, -1 do
		local j = RNG:NextInteger(1, i)
		others[i], others[j] = others[j], others[i]
	end
	for _, r in others do
		table.insert(order, r)
	end

	local placed = 0
	for _, r in order do
		if placed >= QuestChairs.COUNT then
			break
		end
		local p = freeSpot(r, y)
		if p then
			build(r.folder, p, math.rad(RNG:NextInteger(0, 359)))
			placed += 1
		end
	end
	if placed < QuestChairs.COUNT then
		warn(string.format("[Venue] only placed %d of %d quest chairs", placed, QuestChairs.COUNT))
	end
end

return QuestChairs
