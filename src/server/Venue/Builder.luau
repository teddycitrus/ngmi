--!strict
--------------------------------------------------------------------------------
-- Builder.luau
-- Assembles the whole venue into one "Map" model.
--
-- Structure first, content last: every major step runs in its own pcall, and
-- each room's walls go up before its furniture, so a content error can never
-- leave a floor without walls.
--------------------------------------------------------------------------------

local Kit = require(script.Parent.Kit)
local Layout = require(script.Parent.Layout)
local Walls = require(script.Parent.Walls)
local Shell = require(script.Parent.Shell)
local Decor = require(script.Parent.Decor)
local Halls = require(script.Parent.Halls)
local Stairs = require(script.Parent.Stairs)
local Elevators = require(script.Parent.Elevators)
local Auditorium = require(script.Parent.Auditorium)
local Exterior = require(script.Parent.Exterior)
local Work = require(script.Parent.Rooms.Work)
local Social = require(script.Parent.Rooms.Social)
local Service = require(script.Parent.Rooms.Service)
local QuestChairs = require(script.Parent.QuestChairs)

local V = Vector3.new
local M = Enum.Material
local TAGS = Kit.TAGS

local Builder = {}

type Cell = Layout.Cell
type Ctx = Work.Ctx

local CONTENT: { [string]: (Instance, Cell, number, Ctx) -> () } = {
	lab = Work.lab,
	hackhall = Work.hackhall,
	meeting = Work.meeting,
	lounge = Social.lounge,
	["break"] = Social.breakroom,
	library = Social.library,
	bath = Service.bath,
	supply = Service.supply,
}

local LABEL: { [string]: string } = {
	lab = "LAB",
	hackhall = "HACK HALL",
	meeting = "MEETING",
	lounge = "LOUNGE",
	["break"] = "BREAK ROOM",
	library = "LIBRARY",
	bath = "RESTROOM",
	supply = "SUPPLY",
}

local FINISH: { [string]: { Color3 | Enum.Material } } = {
	lab = { Color3.fromRGB(70, 76, 90), M.Carpet },
	hackhall = { Color3.fromRGB(58, 62, 74), M.Carpet },
	meeting = { Color3.fromRGB(96, 82, 72), M.Carpet },
	lounge = { Color3.fromRGB(150, 112, 76), M.WoodPlanks },
	["break"] = { Color3.fromRGB(186, 184, 176), M.CeramicTiles },
	library = { Color3.fromRGB(104, 50, 52), M.Carpet },
	bath = { Kit.COLORS.TILE_FLOOR, M.CeramicTiles },
	supply = { Color3.fromRGB(128, 128, 124), M.Concrete },
}

local ROOM_KINDS = { "lab", "lounge", "meeting", "break", "lab", "lounge", "meeting", "lab" }

-- One RNG per server boot, so where the special rooms land changes per game.
local LAYOUT_RNG = Random.new()

--- Deal room kinds for one floor. Specials go to random cells; merged halls
--- keep their fixed kind. Level 0 always gets the player-desk lab and the
--- boss restroom; every floor gets three supply rooms and a restroom.
local function floorPlan(level: number, cells: { Cell }): ({ [number]: string }, { [number]: boolean }, { [number]: boolean })
	local plan: { [number]: string } = {}
	local open: { number } = {}
	for _, c in cells do
		if c.kind then
			plan[c.no] = c.kind
		else
			plan[c.no] = ROOM_KINDS[LAYOUT_RNG:NextInteger(1, #ROOM_KINDS)]
			table.insert(open, c.no)
		end
	end
	for i = #open, 2, -1 do
		local j = LAYOUT_RNG:NextInteger(1, i)
		open[i], open[j] = open[j], open[i]
	end
	local nextIdx = 1
	local function deal(kind: string): number?
		local no = open[nextIdx]
		nextIdx += 1
		if no then
			plan[no] = kind
		end
		return no
	end
	local boss, player = {}, {}
	if level == 0 then
		local lab = deal("lab")
		if lab then
			player[lab] = true
		end
		local b = deal("bath")
		if b then
			boss[b] = true
		end
	end
	deal("supply")
	deal("supply")
	deal("supply")
	deal("bath")
	return plan, boss, player
end

--- Walls, floor finish, ceiling lights and door signage for one room.
local function roomShell(folder: Instance, c: Cell, level: number, kind: string)
	local y = Layout.floorY(level)
	local cx, cz = (c.minX + c.maxX) / 2, (c.minZ + c.maxZ) / 2
	local accent = Layout.ACCENT[level + 1]
	local big = kind == "hackhall" or kind == "library"
	local service = kind == "bath" or kind == "supply"

	local sideGaps: { Walls.Gap } = {}
	for _, dx in c.doorXs do
		table.insert(sideGaps, { at = dx - cx, width = if service then 5 else 6, height = 9, kind = if service then "door" else "double" })
	end
	local gaps: Walls.RoomGaps = {}
	gaps[c.side] = sideGaps
	if kind ~= "bath" then
		local east: { Walls.Gap } = { { width = 5, height = 9 } }
		if kind == "lab" or kind == "meeting" then
			table.insert(east, { at = -10, width = 8, height = 9, kind = "window" })
			table.insert(east, { at = 10, width = 8, height = 9, kind = "window" })
		end
		gaps.east = east
		if big then
			gaps.west = { { width = 5, height = 9 } }
		end
	end
	local style: Walls.Style = { color = Layout.WALL[level + 1], accent = if kind == "bath" then nil else accent }
	Walls.room(folder, c.minX, c.maxX, c.minZ, c.maxZ, y, style, gaps)

	local fin = FINISH[kind]
	local floorPart = Kit.part(folder, "FloorFinish", V(c.maxX - c.minX - 1.5, 0.1, c.maxZ - c.minZ - 1.5), V(cx, y + 0.05, cz), fin[1] :: Color3, fin[2] :: Enum.Material)
	floorPart.CastShadow = false

	-- ceiling fixtures: two per room (one carries the light), six in the halls
	local ly = y + Layout.CEIL_H
	if kind ~= "bath" then
		local w = c.maxX - c.minX
		local xs = if big then { -w / 3, 0, w / 3 } else { -w / 4, w / 4 }
		local n = 0
		for _, dx in xs do
			for _, dz in (if big then { -7, 7 } else { 0 }) do
				n += 1
				Shell.troffer(folder, V(cx + dx, ly, cz + dz), false, if big then n % 2 == 1 else n == 1, 0.8, if big then 30 else 34, n == 1)
			end
		end
	end

	-- blade sign over each corridor-side door
	local wallZ = if c.side == "south" then c.minZ else c.maxZ
	local out = V(0, 0, if c.side == "south" then -1 else 1)
	local number = string.format("%d%02d", level + 1, c.no)
	local label = LABEL[kind] or "ROOM"
	for _, dx in c.doorXs do
		Decor.bladeSign(folder, V(dx, y + 11.4, wallZ), out, label .. "  " .. number, accent)
	end
end

local function buildRooms(root: Instance, level: number)
	local folder = Instance.new("Folder")
	folder.Name = "Floor_" .. level
	folder.Parent = root
	local cells = Layout.cells(level)
	local plan, boss, player = floorPlan(level, cells)
	local rooms: { QuestChairs.Room } = {}
	for _, c in cells do
		local kind = plan[c.no] or "lab"
		local roomFolder = Instance.new("Folder")
		roomFolder.Name = string.format("Room_L%d_%d_%s", level, c.no, kind)
		roomFolder.Parent = folder

		local ok, err = pcall(roomShell, roomFolder, c, level, kind)
		if not ok then
			warn(string.format("[Venue] shell failed for %s: %s", roomFolder.Name, tostring(err)))
		end
		local fill = CONTENT[kind]
		if fill then
			local ctx: Ctx = { playerDesks = player[c.no] == true, boss = boss[c.no] == true }
			local ok2, err2 = pcall(fill, roomFolder, c, level, ctx)
			if not ok2 then
				warn(string.format("[Venue] content failed for %s: %s", roomFolder.Name, tostring(err2)))
			end
		end
		table.insert(rooms, { folder = roomFolder, cell = c, kind = kind, playerDesks = player[c.no] == true })
		if c.no % 3 == 0 then
			local cx, cz = (c.minX + c.maxX) / 2, (c.minZ + c.maxZ) / 2
			Halls.marker("NGMISpawn_L" .. level .. "_" .. c.no, V(cx, Layout.floorY(level) + 1, cz), roomFolder, TAGS.NGMI_SPAWN)
		end
	end
	if level == 0 then
		local ok, err = pcall(Auditorium.build, folder)
		if not ok then
			warn("[Venue] auditorium failed: " .. tostring(err))
		end
		local ok2, err2 = pcall(QuestChairs.place, rooms, level)
		if not ok2 then
			warn("[Venue] quest chairs failed: " .. tostring(err2))
		end
	end
end

local function buildSpawns(root: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Spawns"
	folder.Parent = root
	for i = 1, 4 do
		local s = Instance.new("SpawnLocation")
		s.Name = "Spawn_" .. i
		s.Size = V(4.5, 0.2, 4.5)
		-- east of the elevator doors, so nobody spawns in a shaft
		s.Position = V(-140 + (i - 1) * 5, 0.1, 0)
		s.Anchored = true
		s.Neutral = true
		s.Duration = 0
		s.Transparency = 1
		s.CanCollide = false
		s.CanTouch = true
		s.Parent = folder
	end
	-- Named NPC markers (NPCManager matches marker Name to the NPC id), spread
	-- across all three floors so the player has to explore to meet everyone.
	local spots = {
		{ "npc_organizer_sarah", -110, 0 },
		{ "npc_volunteer_max", 40, 0 },
		{ "npc_mentor_dev", -80, 1 },
		{ "npc_hacker_alex", 0, 1 },
		{ "npc_judge_priya", 80, 1 },
		{ "npc_sponsor_jordan", -80, 2 },
		{ "npc_rival_sam", 0, 2 },
		{ "npc_security_ron", 80, 2 },
	}
	for _, spot in spots do
		local lvl = spot[3] :: number
		Halls.marker(spot[1] :: string, V(spot[2] :: number, Layout.floorY(lvl) + 0.5, 0), folder, TAGS.NPC_SPAWN)
	end
end

--- Build the venue and parent it to `parent` (workspace by default).
--- `preview` parents the model up front and yields between steps, so an
--- edit-mode build in Studio doesn't freeze the editor.
function Builder.build(parent: Instance?, preview: boolean?): Model
	local map = Instance.new("Model")
	map.Name = "Map"
	if preview then
		map.Parent = parent or workspace
	end
	local function step(name: string, fn: () -> ())
		local ok, err = pcall(fn)
		if not ok then
			warn(string.format("[Venue] step '%s' failed: %s", name, tostring(err)))
		end
		if preview then
			task.wait()
		end
	end

	local stairHole = { xMin = Layout.SHAFT.xMin, xMax = Layout.FX + Layout.WALL_T, zMin = Layout.SHAFT.zMin, zMax = Layout.SHAFT.zMax }
	local elevHole = { xMin = Layout.ELEV.xMin, xMax = Layout.ELEV.xMax, zMin = Layout.ELEV.zMin, zMax = Layout.ELEV.zMax }
	local a = Layout.AUD
	local audHole = { xMin = a.minX, xMax = a.maxX, zMin = a.minZ, zMax = a.maxZ }

	step("exterior", function()
		Exterior.build(map)
	end)
	step("slabs", function()
		Shell.slab(map, 0, {}, Color3.fromRGB(184, 176, 164), "FLOOR_LINO")
		for level = 1, Layout.FLOORS - 1 do
			Shell.slab(map, level, { stairHole, elevHole }, Color3.fromRGB(176, 172, 164), "FLOOR_WORN")
		end
		Shell.slab(map, Layout.FLOORS, {}, Color3.fromRGB(70, 72, 80), "ROOF_DECK")
	end)
	step("ceilings", function()
		for level = 0, Layout.FLOORS - 1 do
			local holes = { stairHole, elevHole }
			if level == 0 then
				table.insert(holes, audHole)
			end
			Shell.ceiling(map, level, holes)
		end
	end)
	step("facades", function()
		Shell.facades(map)
	end)
	for level = 0, Layout.FLOORS - 1 do
		step("rooms" .. level, function()
			buildRooms(map, level)
		end)
		step("halls" .. level, function()
			Halls.build(map, level)
		end)
	end
	step("stairs", function()
		Stairs.build(map)
	end)
	step("elevators", function()
		Elevators.build(map)
	end)
	step("spawns", function()
		buildSpawns(map)
	end)

	map.Parent = parent or workspace
	return map
end

return Builder
