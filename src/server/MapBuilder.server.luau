--!strict
--------------------------------------------------------------------------------
-- MapBuilder.server.luau
-- Procedural 3-floor hackathon venue for "Code Red: The Hackathon Horror".
--
-- Design rules that keep the geometry clean (no overlapping / z-fighting faces):
--   • ONE floor slab per level. Rooms never carry their own floor part, so two
--     floor surfaces can never share a plane. The exterior ground is recessed
--     well below the building so it never coincides with a floor either.
--   • Each level's ceiling IS the slab of the level above — never a second part.
--   • Rooms contribute WALLS only, placed at their own boundaries with gaps /
--     corridors between them, so wall parts never overlap.
--   • Surface decorations (signs, screens) are offset slightly off the wall so
--     their faces are never coplanar with it.
--
-- Layout per floor (top-down, +X = east, +Z = north):
--
--   Z=+53  ┌───────┬───────┬───────┬───────┐
--          │  R1   │  R2   │  R3   │  R4   │   north rooms
--   Z=+9   ├───────┴───────┴───────┴──┬────┤
--          │      central corridor    │stair│  (stairwell at the east end)
--   Z=-9   ├───────┬───────┬───────┬──┴────┤
--          │  R5   │  R6   │  R7   │  R8   │   south rooms
--   Z=-53  └───────┴───────┴───────┴───────┘
--         X=-85                          X=85
--   N-S cross hallways run between the room columns; 3 floors stacked, joined
--   by a switchback stairwell on the east side.
--------------------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting          = game:GetService("Lighting")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)
local AssetLibrary = require(script.Parent.AssetLibrary)

local COLORS = GameConfig.COLORS
local TAGS   = GameConfig.TAGS

local mapModel = Instance.new("Model")
mapModel.Name = "Map"

--------------------------------------------------------------------------------
-- Part helper
--------------------------------------------------------------------------------
type PartProps = {
	name: string?,
	size: Vector3,
	position: Vector3?,
	cframe: CFrame?,
	color: Color3?,
	material: Enum.Material?,
	transparency: number?,
	canCollide: boolean?,
	reflectance: number?,
	shape: Enum.PartType?,
	parent: Instance?,
}

local function makePart(props: PartProps): Part
	local p = Instance.new("Part")
	p.Name = props.name or "Part"
	p.Size = props.size
	if props.cframe then
		p.CFrame = props.cframe
	else
		p.Position = props.position or Vector3.zero
	end
	p.Anchored = true
	p.Color = props.color or Color3.fromRGB(200, 200, 200)
	p.Material = props.material or Enum.Material.SmoothPlastic
	p.Transparency = props.transparency or 0
	p.CanCollide = if props.canCollide ~= nil then props.canCollide else true
	p.Reflectance = props.reflectance or 0
	if props.shape then
		p.Shape = props.shape
	end
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = props.parent or mapModel
	return p
end

local function tag(inst: Instance, t: string)
	CollectionService:AddTag(inst, t)
end

local function addPointLight(parent: Instance, brightness: number, range: number, color: Color3?, enabled: boolean?)
	local l = Instance.new("PointLight")
	l.Brightness = brightness
	l.Range = range
	l.Color = color or Color3.fromRGB(255, 248, 230)
	l.Enabled = if enabled ~= nil then enabled else true
	l.Parent = parent
end

local function addSurfaceText(part: Part, face: Enum.NormalId, text: string, textColor: Color3, bgColor: Color3, font: Enum.Font?)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 20
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = bgColor
	label.TextColor3 = textColor
	label.TextScaled = true
	label.Font = font or Enum.Font.GothamBold
	label.Text = text
	label.TextWrapped = true
	label.Parent = gui
	gui.Parent = part
end

--------------------------------------------------------------------------------
-- Wall decor — posters, bulletin boards, sponsor adverts
--------------------------------------------------------------------------------
-- A poster is a thin panel (the paper) carrying a SurfaceGui with an accent
-- header band + body copy. Panels are offset slightly off their wall so faces
-- are never coplanar (same anti-z-fighting rule as the rest of the venue).

type Poster = { title: string, body: string, accent: Color3, paper: Color3, fg: Color3 }

local PAPER_WHITE = Color3.fromRGB(245, 244, 238)
local PAPER_CORK = Color3.fromRGB(150, 110, 66)
local INK = Color3.fromRGB(35, 35, 42)

local POSTER_POOL: { Poster } = {
	{ title = "CODERED HACKATHON", body = "48 HOURS\n∞ POSSIBILITIES\n1 WINNER", accent = Color3.fromRGB(200, 40, 40), paper = PAPER_WHITE, fg = INK },
	{ title = "STAY HYDRATED", body = "Water > Energy Drinks.\n(We know. We're sorry.)", accent = Color3.fromRGB(40, 130, 210), paper = PAPER_WHITE, fg = INK },
	{ title = "FREE WIFI", body = "SSID: VesperHacks_5G\npass: hunter2", accent = Color3.fromRGB(40, 160, 90), paper = PAPER_WHITE, fg = INK },
	{ title = "DEMO DAY", body = "Sunday · 4 PM\nMain Stage\nWorking demos only!", accent = Color3.fromRGB(150, 60, 200), paper = PAPER_WHITE, fg = INK },
	{ title = "DEADLINE LOOMS", body = "Ship before Night 2.\nThe ones who didn't...\nwe don't talk about.", accent = Color3.fromRGB(40, 40, 48), paper = Color3.fromRGB(220, 210, 200), fg = INK },
	{ title = "IN CASE OF EMERGENCY", body = "Stay calm.\nFind the exits.\nDo NOT look behind you.", accent = Color3.fromRGB(210, 150, 20), paper = PAPER_WHITE, fg = INK },
	{ title = "LOST & FOUND", body = "Missing: 1 mentor,\n3 attendees, and\nall sense of time.", accent = Color3.fromRGB(180, 50, 50), paper = Color3.fromRGB(235, 230, 222), fg = INK },
	{ title = "BULLETIN BOARD", body = "★ Team seeking designer\n★ Charger borrowed (sorry)\n★ Has anyone seen Dev?", accent = Color3.fromRGB(120, 80, 40), paper = PAPER_CORK, fg = Color3.fromRGB(250, 248, 240) },
	-- collegiate flavour — this venue is a university engineering building
	{ title = "ST. VESPER UNIVERSITY", body = "Dept. of Computer Science\nHalberd Engineering Hall", accent = Color3.fromRGB(110, 28, 40), paper = PAPER_WHITE, fg = INK },
	{ title = "ACM STUDENT CHAPTER", body = "Weekly meetups\nThu 6 PM · Room 204\nFree pizza (while it lasts)", accent = Color3.fromRGB(40, 160, 90), paper = PAPER_WHITE, fg = INK },
	{ title = "OFFICE HOURS", body = "Prof. Halberd\nMon / Wed 2–4 PM\nRoom 311 (knock loudly)", accent = Color3.fromRGB(40, 90, 200), paper = PAPER_WHITE, fg = INK },
	{ title = "GO ROBO-LIONS", body = "Engineering vs. Business\nIntramural Finals\nGym · Sat 7 PM", accent = Color3.fromRGB(150, 40, 50), paper = Color3.fromRGB(235, 225, 200), fg = INK },
	{ title = "CAREER FAIR", body = "Main Atrium · Friday\nBring résumés.\nLeave with regrets.", accent = Color3.fromRGB(150, 60, 200), paper = PAPER_WHITE, fg = INK },
}

type Sponsor = { name: string, tagline: string, color: Color3 }

local SPONSOR_POOL: { Sponsor } = {
	{ name = "MEGACORP", tagline = "Enterprise Synergy, at Scale", color = Color3.fromRGB(190, 40, 40) },
	{ name = "NIMBUSCLOUD", tagline = "∞ Free Credits*  (*terms apply)", color = Color3.fromRGB(40, 90, 200) },
	{ name = "BYTEBITES", tagline = "Snacks That Hack Back", color = Color3.fromRGB(40, 160, 80) },
	{ name = "QUANTUMLEAP AI", tagline = "Your Code, But Sentient™", color = Color3.fromRGB(130, 50, 190) },
	{ name = "DEVTOOLS INC", tagline = "We Tool So You Don't Have To", color = Color3.fromRGB(220, 140, 30) },
	{ name = "HYPERSTACK", tagline = "Move Fast · Break Everything", color = Color3.fromRGB(20, 150, 150) },
}

--- Attach a 2-part SurfaceGui (accent header + body copy) to a poster panel.
local function addPosterSurface(part: Part, face: Enum.NormalId, title: string, body: string, accent: Color3, fg: Color3)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 24
	gui.Parent = part

	local header = Instance.new("TextLabel")
	header.Size = UDim2.fromScale(1, 0.3)
	header.BackgroundColor3 = accent
	header.BorderSizePixel = 0
	header.Text = title
	header.TextColor3 = Color3.fromRGB(255, 255, 255)
	header.TextStrokeTransparency = 0.6
	header.Font = Enum.Font.GothamBold
	header.TextScaled = true
	header.Parent = gui

	local bodyLabel = Instance.new("TextLabel")
	bodyLabel.AnchorPoint = Vector2.new(0.5, 0)
	bodyLabel.Position = UDim2.fromScale(0.5, 0.34)
	bodyLabel.Size = UDim2.fromScale(0.92, 0.62)
	bodyLabel.BackgroundTransparency = 1
	bodyLabel.Text = body
	bodyLabel.TextColor3 = fg
	bodyLabel.Font = Enum.Font.GothamMedium
	bodyLabel.TextScaled = true
	bodyLabel.TextWrapped = true
	bodyLabel.Parent = gui
end

--- Place a flat poster on the corridor-facing exterior wall of a room, offset to
--- one side of the (centred) door. `corridorSide` matches the room's door side.
local function placeRoomPoster(parent: Instance, cxr: number, minZ: number, maxZ: number, y: number, corridorSide: string, poster: Poster)
	local pz: number, face: Enum.NormalId
	if corridorSide == "south" then
		pz = minZ - 0.9
		face = Enum.NormalId.Front -- -Z, toward the corridor
	else
		pz = maxZ + 0.9
		face = Enum.NormalId.Back -- +Z, toward the corridor
	end
	local panel = makePart({
		name = "Poster",
		size = Vector3.new(5, 5, 0.2),
		position = Vector3.new(cxr + 8, y + 7, pz),
		color = poster.paper,
		material = Enum.Material.SmoothPlastic,
		canCollide = false,
		parent = parent,
	})
	-- thin frame behind the paper for a mounted look
	makePart({
		name = "PosterFrame",
		size = Vector3.new(5.5, 5.5, 0.1),
		position = Vector3.new(cxr + 8, y + 7, pz + (corridorSide == "south" and 0.08 or -0.08)),
		color = Color3.fromRGB(40, 42, 50),
		material = Enum.Material.SmoothPlastic,
		canCollide = false,
		parent = parent,
	})
	addPosterSurface(panel, face, poster.title, poster.body, poster.accent, poster.fg)
end

--- A free-standing roll-up sponsor banner that sits in the open corridor.
--- `faceFront` true => the advert faces -Z, false => +Z.
local function bannerStand(parent: Instance, x: number, y: number, z: number, faceFront: boolean, sponsor: Sponsor)
	makePart({ name = "BannerBase", size = Vector3.new(5.5, 0.4, 2), position = Vector3.new(x, y + 0.2, z), color = Color3.fromRGB(40, 42, 50), material = Enum.Material.Metal, parent = parent })
	for _, sx in { -1, 1 } do
		makePart({ name = "BannerPost", size = Vector3.new(0.3, 11, 0.3), position = Vector3.new(x + sx * 2.4, y + 5.5, z), color = Color3.fromRGB(60, 62, 70), material = Enum.Material.Metal, parent = parent })
	end
	local panel = makePart({
		name = "Banner",
		size = Vector3.new(5, 10, 0.25),
		position = Vector3.new(x, y + 6, z),
		color = sponsor.color,
		material = Enum.Material.SmoothPlastic,
		canCollide = false,
		parent = parent,
	})
	addPosterSurface(panel, faceFront and Enum.NormalId.Front or Enum.NormalId.Back, sponsor.name, sponsor.tagline, Color3.fromRGB(20, 20, 26), Color3.fromRGB(250, 250, 250))
end

local function marker(name: string, pos: Vector3, parent: Instance, tagName: string?): Part
	local m = makePart({ name = name, size = Vector3.new(1.5, 0.2, 1.5), position = pos, transparency = 1, canCollide = false, parent = parent })
	if tagName then
		tag(m, tagName)
	end
	return m
end

--- A wall lean/sit spot for an ambient hacker. `face` is the unit direction the
--- hacker should look (AWAY from the wall) — AmbientPopulation reads the Face
--- attribute so the rig sits with its back to the wall whichever wall it's on.
local function leanSpot(name: string, pos: Vector3, parent: Instance, face: Vector3): Part
	local m = marker(name, pos, parent, TAGS.LEAN_SPOT)
	m:SetAttribute("Face", face)
	return m
end

local function itemSpawn(itemId: string, pos: Vector3, parent: Instance)
	local m = makePart({ name = "ItemSpawn_" .. itemId, size = Vector3.new(1, 1, 1), position = pos, transparency = 1, canCollide = false, parent = parent })
	m:SetAttribute("ItemId", itemId)
	tag(m, TAGS.ITEM_SPAWN)
end

-- World-Y of the TOP surface of each Shelf board, relative to the shelf's floor
-- origin. The Shelf asset (AssetLibrary.builders.Shelf) has 3 boards centred at
-- local Y 2/5/8, each 0.4 thick → tops at 2.2 / 5.2 / 8.2. Board 1 is the lowest.
local SHELF_BOARD_TOP = { 2.2, 5.2, 8.2 }

--- Spawn an item resting ON a shelf board instead of floating in mid-air.
--- `shelfCenter` is where the Shelf model was pivoted (floor-level centre, which
--- the boards span ±5 in X and ±1 in Z around). `board` is 1-3 (bottom→top) and
--- `xOffset` slides the item along the board. The item's centre is placed at the
--- board top plus half the item's height so it sits flush on the surface.
local function shelfItemSpawn(itemId: string, shelfCenter: Vector3, board: number, xOffset: number, parent: Instance)
	local def = ItemConfig.items[itemId]
	local halfHeight = if def then def.modelSize.Y / 2 else 0.5
	local boardTopY = shelfCenter.Y + (SHELF_BOARD_TOP[board] or SHELF_BOARD_TOP[1])
	itemSpawn(itemId, Vector3.new(shelfCenter.X + xOffset, boardTopY + halfHeight, shelfCenter.Z), parent)
end

--------------------------------------------------------------------------------
-- Layout constants
--------------------------------------------------------------------------------
local WALL_T = 1.5
local LEVEL_H = 18      -- floor-to-floor
local INNER_H = 16      -- floor surface to ceiling (slab bottom)
local SLAB_T = LEVEL_H - INNER_H -- 2
local FLOORS = 3

local FX = 160          -- footprint half-width  (interior X: -160..160)
local FZ = 100          -- footprint half-depth  (interior Z: -100..100)

-- Stairwell shaft (east end, sits inside the central corridor band)
local SHAFT = { xMin = 130, xMax = FX, zMin = -10, zMax = 10 }

-- Elevator bank — a 2-car shaft at the WEST end of the central corridor (against
-- the west perimeter, opening east into the corridor near the entrance lobby).
-- Lives entirely inside the corridor band (z ∈ [-9.5, 9.5]) so it never clashes
-- with the room grid (rooms are at |z| > CORR_HALF).
local ELEV = { xMin = -(FX + WALL_T), xMax = -148, zMin = -9.5, zMax = 9.5 }

-- Ground-floor auditorium / lecture hall — a single large hall that replaces a
-- block of the normal room grid on level 0 (south-west quadrant).
local AUD = { minX = -152, maxX = 48, minZ = -92, maxZ = -17 }

local function floorY(level: number): number
	return level * LEVEL_H
end

--------------------------------------------------------------------------------
-- Wall segment placement (single parts, never coplanar-overlapping)
--------------------------------------------------------------------------------
local function placeSegment(parent: Instance, origin: Vector3, dir: Vector3, startD: number, endD: number, bottom: number, top: number, thickness: number, color: Color3, material: Enum.Material, transparency: number?): Part?
	if endD - startD <= 0.05 then
		return nil
	end
	-- `bottom`/`top` are ABSOLUTE world Y, so the vertical centre is taken from
	-- them directly — we must NOT add origin.Y again (origin.Y is floorY(level),
	-- which is already baked into bottom/top). Adding it double-counted the floor
	-- height and pushed every upper-floor wall a full storey too high, leaving
	-- those floors with no visible walls.
	local mid = (startD + endD) / 2
	local center = Vector3.new(origin.X + dir.X * mid, (bottom + top) / 2, origin.Z + dir.Z * mid)
	return makePart({
		name = "Wall",
		size = Vector3.new(thickness, top - bottom, endD - startD),
		cframe = CFrame.lookAt(center, center + dir),
		color = color,
		material = material,
		transparency = transparency,
		parent = parent,
	})
end

type Door = { width: number, height: number? }

local function solidWall(parent: Instance, a: Vector3, b: Vector3, height: number, color: Color3, material: Enum.Material, door: Door?)
	local delta = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	local length = delta.Magnitude
	local dir = delta.Unit
	local baseY = a.Y
	if door and door.width < length - 2 then
		local h = door.height or 10
		local gs = (length - door.width) / 2
		local ge = gs + door.width
		placeSegment(parent, a, dir, 0, gs, baseY, baseY + height, WALL_T, color, material)
		placeSegment(parent, a, dir, ge, length, baseY, baseY + height, WALL_T, color, material)
		placeSegment(parent, a, dir, gs, ge, baseY + h, baseY + height, WALL_T, color, material)
	else
		placeSegment(parent, a, dir, 0, length, baseY, baseY + height, WALL_T, color, material)
	end
end

local function windowWall(parent: Instance, a: Vector3, b: Vector3, height: number, color: Color3, material: Enum.Material, panes: number)
	local delta = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	local length = delta.Magnitude
	local dir = delta.Unit
	local baseY = a.Y
	-- A solid concrete facade with a punched ribbon of windows. The solid base,
	-- header, mid-transom and thick piers keep it reading as a WALL even on the
	-- upper floors where the glass sits against open sky.
	local sillB, sillT = baseY + 4.5, baseY + 11.5
	local midY = (sillB + sillT) / 2
	placeSegment(parent, a, dir, 0, length, baseY, sillB, WALL_T, color, material)            -- solid base
	placeSegment(parent, a, dir, 0, length, sillT, baseY + height, WALL_T, color, material)   -- solid header
	placeSegment(parent, a, dir, 0, length, midY - 0.4, midY + 0.4, WALL_T, color, material)  -- mid transom
	local pillarW = 3.5
	local span = length / panes
	for i = 0, panes do
		local d = i * span
		placeSegment(parent, a, dir, d - pillarW / 2, d + pillarW / 2, sillB, sillT, WALL_T, color, material) -- piers
	end
	for i = 1, panes do
		local glassStart = (i - 1) * span + pillarW / 2
		local glassEnd = i * span - pillarW / 2
		for _, seg in { { sillB, midY - 0.4 }, { midY + 0.4, sillT } } do
			local pane = placeSegment(parent, a, dir, glassStart, glassEnd, seg[1], seg[2], 0.4, COLORS.GLASS, Enum.Material.Glass, 0.6)
			if pane then
				pane.Name = "Window"
				-- Clearer glass: more transparent + low reflectance so the skyline
				-- outside reads cleanly instead of looking heavily frosted.
				pane.Reflectance = 0.05
			end
		end
	end
end

--- Build the 4 walls of a room (floor/ceiling come from the level slabs).
type RoomDoors = { south: Door?, north: Door?, east: Door?, west: Door? }
local function buildRoomWalls(parent: Instance, minX: number, maxX: number, minZ: number, maxZ: number, level: number, color: Color3, material: Enum.Material, doors: RoomDoors)
	local y = floorY(level)
	local x0, x1 = minX - WALL_T / 2, maxX + WALL_T / 2
	local z0, z1 = minZ + WALL_T / 2, maxZ - WALL_T / 2
	-- south / north span the full width (cover corners)
	solidWall(parent, Vector3.new(x0, y, minZ), Vector3.new(x1, y, minZ), INNER_H, color, material, doors.south)
	solidWall(parent, Vector3.new(x0, y, maxZ), Vector3.new(x1, y, maxZ), INNER_H, color, material, doors.north)
	-- east / west are inset so they don't overlap the corners
	solidWall(parent, Vector3.new(minX, y, z0), Vector3.new(minX, y, z1), INNER_H, color, material, doors.west)
	solidWall(parent, Vector3.new(maxX, y, z0), Vector3.new(maxX, y, z1), INNER_H, color, material, doors.east)
end

--------------------------------------------------------------------------------
-- Floor slabs — one per level, tiled around the stairwell hole on upper levels
--------------------------------------------------------------------------------
type Hole = { xMin: number, xMax: number, zMin: number, zMax: number }

--- Build one level's floor slab, tiled around any number of (non-overlapping)
--- rectangular holes (stairwell, elevator shafts). Cuts the slab into vertical
--- strips at every hole's X edges; within each strip the holes that fully span it
--- partition Z into covered spans, and we emit slab rects for the gaps.
local function buildSlab(level: number, holes: { Hole }, color: Color3)
	local topY = floorY(level)
	local folder = Instance.new("Folder")
	folder.Name = "Slab_" .. level
	folder.Parent = mapModel
	local function slabRect(minX: number, maxX: number, minZ: number, maxZ: number)
		if maxX - minX < 0.05 or maxZ - minZ < 0.05 then
			return
		end
		makePart({
			name = "Slab",
			size = Vector3.new(maxX - minX, SLAB_T, maxZ - minZ),
			position = Vector3.new((minX + maxX) / 2, topY - SLAB_T / 2, (minZ + maxZ) / 2),
			color = color,
			material = Enum.Material.Concrete,
			parent = folder,
		})
	end
	local X0, X1 = -(FX + WALL_T), FX + WALL_T
	local Z0, Z1 = -(FZ + WALL_T), FZ + WALL_T

	local xs = { X0, X1 }
	for _, h in holes do
		table.insert(xs, math.clamp(h.xMin, X0, X1))
		table.insert(xs, math.clamp(h.xMax, X0, X1))
	end
	table.sort(xs)

	for i = 1, #xs - 1 do
		local xa, xb = xs[i], xs[i + 1]
		if xb - xa < 0.05 then
			continue
		end
		local spans: { { number } } = {}
		for _, h in holes do
			if h.xMin <= xa + 0.01 and h.xMax >= xb - 0.01 then
				table.insert(spans, { math.clamp(h.zMin, Z0, Z1), math.clamp(h.zMax, Z0, Z1) })
			end
		end
		table.sort(spans, function(a, b)
			return a[1] < b[1]
		end)
		local zc = Z0
		for _, s in spans do
			if s[1] > zc then
				slabRect(xa, xb, zc, s[1])
			end
			zc = math.max(zc, s[2])
		end
		if zc < Z1 then
			slabRect(xa, xb, zc, Z1)
		end
	end
end

--------------------------------------------------------------------------------
-- Switchback stairs inside the shaft, plus shaft walls + a door to the corridor
--------------------------------------------------------------------------------
local function buildStairwell()
	local folder = Instance.new("Folder")
	folder.Name = "Stairwell"
	folder.Parent = mapModel

	local stepColor = Color3.fromRGB(95, 97, 105)
	local railColor = Color3.fromRGB(58, 60, 68)
	local STEPS = 10
	local HALF_RISE = LEVEL_H / 2 -- each half-flight climbs half a storey
	local FLIGHT_DEPTH = 9
	local FLIGHT_Z = 5 -- the two flights sit either side of the shaft centre

	-- A solid filled flight: each tread is a block that reaches down to the
	-- base, so the staircase reads as one solid mass (no floating step boxes).
	local function flight(yStart: number, xFrom: number, xTo: number, zCenter: number)
		local run = (xTo - xFrom) / STEPS
		local rise = HALF_RISE / STEPS
		for i = 1, STEPS do
			local topY = yStart + i * rise
			local h = topY - (yStart - 1) -- extend just below the start so it's solid
			makePart({
				name = "Step",
				size = Vector3.new(math.abs(run) + 0.2, h, FLIGHT_DEPTH),
				position = Vector3.new(xFrom + run * (i - 0.5), topY - h / 2, zCenter),
				color = stepColor,
				material = Enum.Material.Concrete,
				parent = folder,
			})
		end
	end

	local function landing(y: number, xCenter: number, sizeX: number)
		makePart({
			name = "Landing",
			size = Vector3.new(sizeX, 1, SHAFT.zMax - SHAFT.zMin),
			position = Vector3.new(xCenter, y - 0.5, 0),
			color = stepColor,
			material = Enum.Material.Concrete,
			parent = folder,
		})
	end

	local xW = SHAFT.xMin + 4
	local xE = SHAFT.xMax - 5
	for gap = 0, FLOORS - 2 do
		local baseY = floorY(gap)
		-- up the south side (east-bound), turn on the east landing, up the north
		-- side (west-bound), arrive on a landing flush with the floor slab.
		flight(baseY, xW, xE, -FLIGHT_Z)
		landing(baseY + HALF_RISE, SHAFT.xMax - 5, 10)
		flight(baseY + HALF_RISE, xE, xW, FLIGHT_Z)
		landing(floorY(gap + 1), SHAFT.xMin + 3, 8)
		-- Central spine wall the switchback wraps around. It used to be a short 4-stud
		-- rail floating at mid-height with open air above and below it (the "weird
		-- gaps"). Now it's a full storey-height wall that seals the whole void between
		-- the two flights. It spans only BETWEEN the landings in X (so it never blocks
		-- the U-turn walkway on either landing) and is deep enough in Z to overlap the
		-- inner edge of each flight, leaving no see-through seam.
		local divX0 = (SHAFT.xMin + 3) + 4 -- inner edge of the west landing
		local divX1 = (SHAFT.xMax - 5) - 5 -- inner edge of the east landing
		local divDepth = (FLIGHT_Z * 2 - FLIGHT_DEPTH) + 1.2 -- gap between flights + overlap
		makePart({
			name = "StairDivider",
			size = Vector3.new(divX1 - divX0, LEVEL_H, divDepth),
			position = Vector3.new((divX0 + divX1) / 2, baseY + LEVEL_H / 2, 0),
			color = railColor,
			material = Enum.Material.Metal,
			parent = folder,
		})
	end

	-- Shaft walls on every level (north/south sides + a door on the west into
	-- the corridor). The east side is the building perimeter.
	for level = 0, FLOORS - 1 do
		local y = floorY(level)
		solidWall(folder, Vector3.new(SHAFT.xMin, y, SHAFT.zMin), Vector3.new(FX + WALL_T, y, SHAFT.zMin), INNER_H, COLORS.WALL, Enum.Material.Concrete)
		solidWall(folder, Vector3.new(SHAFT.xMin, y, SHAFT.zMax), Vector3.new(FX + WALL_T, y, SHAFT.zMax), INNER_H, COLORS.WALL, Enum.Material.Concrete)
		solidWall(folder, Vector3.new(SHAFT.xMin, y, SHAFT.zMin), Vector3.new(SHAFT.xMin, y, SHAFT.zMax), INNER_H, COLORS.WALL, Enum.Material.Concrete, { width = 6, height = 10 })
		local shaftMidX = (SHAFT.xMin + SHAFT.xMax) / 2
		-- Ceiling light: mount it flush under a small soffit box at the very top of
		-- the shaft (one storey-height below the roof) so it reads as a fixture
		-- instead of a glowing panel floating in the open stairwell.
		local lightY = floorY(FLOORS - 1) + INNER_H - 0.3
		if level == FLOORS - 1 then
			makePart({ name = "LightSoffit", size = Vector3.new(5, 0.6, 3), position = Vector3.new(shaftMidX, lightY + 0.4, 0), color = COLORS.WALL, material = Enum.Material.Concrete, parent = folder })
			local stairLight = makePart({ name = "StairLight", size = Vector3.new(4, 0.3, 2), position = Vector3.new(shaftMidX, lightY, 0), color = Color3.fromRGB(255, 255, 245), material = Enum.Material.Neon, parent = folder })
			addPointLight(stairLight, 1.4, 40)
			tag(stairLight, TAGS.CEILING_LIGHT)
		end
		-- a rare leaning hacker sitting on the edge of a stair step (not the lower
		-- floors' open air). Only on levels that actually have a flight above them.
		if level < FLOORS - 1 then
			local lrun = (xE - xW) / STEPS
			local lstep = 6
			local lstepTopY = y + lstep * (HALF_RISE / STEPS)
			local lstepX = xW + lrun * (lstep - 0.5)
			-- sit on the step with their back to the shaft's south wall, facing across
			-- the stairwell toward the spine wall.
			leanSpot("LeanSpot_Stair_" .. level, Vector3.new(lstepX, lstepTopY + 0.2, SHAFT.zMin + 2), folder, Vector3.new(0, 0, 1))
		end
		tag(marker("NGMISpawn_Stair_" .. level, Vector3.new(shaftMidX, y + 1, 0), folder), TAGS.NGMI_SPAWN)
	end
end

--------------------------------------------------------------------------------
-- Working elevators — a 2-car bank at the west end of the central corridor.
-- The shaft walls + per-floor doorways + call buttons are built here; the cars
-- are anchored Models tagged ELEVATOR_CAR that ElevatorController moves at run
-- time. Buttons are tagged ELEVATOR_CALL with ElevatorId + TargetY attributes.
--------------------------------------------------------------------------------
local ELEV_CARS = {
	{ id = "ElevA", zMin = ELEV.zMin, zMax = -0.25 },
	{ id = "ElevB", zMin = 0.25, zMax = ELEV.zMax },
}

local function addElevPrompt(part: Part, elevId: string, targetY: number, text: string)
	part:SetAttribute("ElevatorId", elevId)
	part:SetAttribute("TargetY", targetY)
	tag(part, TAGS.ELEVATOR_CALL)
	local pp = Instance.new("ProximityPrompt")
	pp.ActionText = text
	pp.ObjectText = "Elevator"
	pp.HoldDuration = 0
	pp.MaxActivationDistance = 9
	pp.RequiresLineOfSight = false
	pp.Parent = part
end

local function buildCar(parent: Instance, car: { id: string, zMin: number, zMax: number })
	local cz = (car.zMin + car.zMax) / 2
	local cxCar = (ELEV.xMin + ELEV.xMax) / 2
	local halfX = (ELEV.xMax - ELEV.xMin) / 2 - 0.6
	local halfZ = (car.zMax - car.zMin) / 2 - 0.3
	local carH = 11
	local y0 = floorY(0)

	local model = Instance.new("Model")
	model.Name = "ElevatorCar_" .. car.id

	local floorPart = makePart({ name = "CarFloor", size = Vector3.new(halfX * 2, 0.4, halfZ * 2), position = Vector3.new(cxCar, y0 + 0.2, cz), color = Color3.fromRGB(70, 72, 80), material = Enum.Material.DiamondPlate, parent = model })
	makePart({ name = "CarCeiling", size = Vector3.new(halfX * 2, 0.3, halfZ * 2), position = Vector3.new(cxCar, y0 + carH, cz), color = Color3.fromRGB(60, 62, 68), material = Enum.Material.Metal, parent = model })
	makePart({ name = "CarWall", size = Vector3.new(0.3, carH, halfZ * 2), position = Vector3.new(cxCar - halfX, y0 + carH / 2, cz), color = COLORS.METAL_BRUSHED, material = Enum.Material.Metal, parent = model })
	makePart({ name = "CarWall", size = Vector3.new(halfX * 2, carH, 0.3), position = Vector3.new(cxCar, y0 + carH / 2, cz - halfZ), color = COLORS.METAL_BRUSHED, material = Enum.Material.Metal, parent = model })
	makePart({ name = "CarWall", size = Vector3.new(halfX * 2, carH, 0.3), position = Vector3.new(cxCar, y0 + carH / 2, cz + halfZ), color = COLORS.METAL_BRUSHED, material = Enum.Material.Metal, parent = model })
	local lt = makePart({ name = "CarLight", size = Vector3.new(halfX * 1.4, 0.2, 1.4), position = Vector3.new(cxCar, y0 + carH - 0.3, cz), color = Color3.fromRGB(245, 248, 255), material = Enum.Material.Neon, parent = model })
	addPointLight(lt, 1.4, 18)
	tag(lt, TAGS.CEILING_LIGHT) -- killed by the NIGHT2 blackout like every other light

	-- destination buttons on the back wall (one per floor)
	for level = 0, FLOORS - 1 do
		local btn = makePart({ name = "CarButton", size = Vector3.new(0.3, 0.9, 0.9), position = Vector3.new(cxCar - halfX + 0.4, y0 + 4.5, cz - 1.6 + level * 1.6), color = Color3.fromRGB(90, 96, 110), material = Enum.Material.Neon, parent = model })
		addElevPrompt(btn, car.id, floorY(level) + 0.2, "Floor " .. (level + 1))
	end

	model.PrimaryPart = floorPart
	model:SetAttribute("ElevatorId", car.id)
	tag(model, TAGS.ELEVATOR_CAR)
	model.Parent = parent
end

local function buildElevators()
	local folder = Instance.new("Folder")
	folder.Name = "Elevators"
	folder.Parent = mapModel

	for level = 0, FLOORS - 1 do
		local y = floorY(level)
		-- shaft enclosure: north + south sides, a divider between the two cars
		solidWall(folder, Vector3.new(ELEV.xMin, y, ELEV.zMin), Vector3.new(ELEV.xMax, y, ELEV.zMin), INNER_H, COLORS.WALL_TRIM, Enum.Material.Concrete)
		solidWall(folder, Vector3.new(ELEV.xMin, y, ELEV.zMax), Vector3.new(ELEV.xMax, y, ELEV.zMax), INNER_H, COLORS.WALL_TRIM, Enum.Material.Concrete)
		solidWall(folder, Vector3.new(ELEV.xMin, y, 0), Vector3.new(ELEV.xMax, y, 0), INNER_H, COLORS.WALL_TRIM, Enum.Material.Concrete)
		for _, car in ELEV_CARS do
			local cz = (car.zMin + car.zMax) / 2
			-- east face with a doorway opening into the corridor
			solidWall(folder, Vector3.new(ELEV.xMax, y, car.zMin), Vector3.new(ELEV.xMax, y, car.zMax), INNER_H, COLORS.WALL_TRIM, Enum.Material.Concrete, { width = 6, height = 10 })
			-- exterior call button beside the doors
			local btn = makePart({ name = "ElevCall", size = Vector3.new(0.3, 1.2, 0.8), position = Vector3.new(ELEV.xMax + 0.5, y + 4.5, cz + (car.id == "ElevA" and -2.6 or 2.6)), color = Color3.fromRGB(90, 96, 110), material = Enum.Material.Neon, parent = folder })
			addElevPrompt(btn, car.id, y + 0.2, "Call Elevator")
			-- lit floor-number plate over the doors
			local plate = makePart({ name = "ElevPlate", size = Vector3.new(2.4, 1.2, 0.2), position = Vector3.new(ELEV.xMax + 0.2, y + 11, cz), color = Color3.fromRGB(25, 27, 34), material = Enum.Material.SmoothPlastic, parent = folder })
			addSurfaceText(plate, Enum.NormalId.Right, tostring(level + 1), Color3.fromRGB(120, 220, 255), Color3.fromRGB(25, 27, 34))

			-- two sliding shaft doors that fill the 6-wide doorway. ElevatorController
			-- slides them apart while the car is parked at this floor, shut otherwise.
			for _, side in { -1, 1 } do
				local closedZ = cz + side * 1.5
				local openZ = cz + side * 4.4
				local door = makePart({ name = "ElevDoor", size = Vector3.new(0.25, 9.6, 3), position = Vector3.new(ELEV.xMax, y + 4.9, closedZ), color = Color3.fromRGB(190, 205, 220), material = Enum.Material.Glass, transparency = 0.55, reflectance = 0.08, parent = folder })
				door:SetAttribute("ElevatorId", car.id)
				door:SetAttribute("CarY", y + 0.2) -- matches the call-button TargetY for this floor
				door:SetAttribute("ClosedZ", closedZ)
				door:SetAttribute("OpenZ", openZ)
				tag(door, TAGS.ELEVATOR_DOOR)
			end
		end
	end

	for _, car in ELEV_CARS do
		buildCar(folder, car)
	end
end

--------------------------------------------------------------------------------
-- Furniture placement + clutter helpers (shared by every room builder)
--------------------------------------------------------------------------------

--- Clone a furniture template and parent it, rotated yawDeg degrees about Y.
local function place(name: string, x: number, y: number, z: number, yawDeg: number?, parent: Instance): Model?
	local c = AssetLibrary.clone(name, CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yawDeg or 0), 0))
	if c then
		c.Parent = parent
	end
	return c
end

local CAN_COLORS = {
	Color3.fromRGB(200, 40, 40),
	Color3.fromRGB(40, 120, 220),
	Color3.fromRGB(60, 180, 90),
	Color3.fromRGB(240, 180, 40),
	Color3.fromRGB(150, 60, 200),
}
local CHIP_COLORS = {
	Color3.fromRGB(222, 162, 40),
	Color3.fromRGB(210, 60, 50),
	Color3.fromRGB(40, 150, 90),
	Color3.fromRGB(60, 90, 200),
}

local function pick<T>(t: { T }): T
	return t[math.random(#t)]
end

--- Scatter `count` random static props (cans, chip bags, cups, pizza boxes)
--- across a floor region. All are non-colliding so they never trip the player.
local function scatterTrash(parent: Instance, minX: number, maxX: number, minZ: number, maxZ: number, surfaceY: number, count: number)
	for _ = 1, count do
		local px = minX + math.random() * math.max(0.01, maxX - minX)
		local pz = minZ + math.random() * math.max(0.01, maxZ - minZ)
		local rotY = math.random() * math.pi * 2
		local roll = math.random(1, 6)

		if roll == 1 then
			-- upright soda can
			makePart({ name = "SodaCan", size = Vector3.new(1.1, 0.55, 0.55), cframe = CFrame.new(px, surfaceY + 0.55, pz) * CFrame.Angles(0, rotY, math.rad(90)), color = pick(CAN_COLORS), material = Enum.Material.Metal, canCollide = false, shape = Enum.PartType.Cylinder, parent = parent })
		elseif roll == 2 then
			-- toppled / crushed can
			makePart({ name = "SodaCan", size = Vector3.new(1.0, 0.5, 0.5), cframe = CFrame.new(px, surfaceY + 0.25, pz) * CFrame.Angles(0, rotY, 0), color = pick(CAN_COLORS), material = Enum.Material.Metal, canCollide = false, shape = Enum.PartType.Cylinder, parent = parent })
		elseif roll == 3 then
			-- chip bag
			makePart({ name = "ChipBag", size = Vector3.new(1.5, 0.4, 2.1), cframe = CFrame.new(px, surfaceY + 0.2, pz) * CFrame.Angles(0, rotY, 0), color = pick(CHIP_COLORS), material = Enum.Material.SmoothPlastic, canCollide = false, parent = parent })
		elseif roll == 4 then
			-- coffee cup
			makePart({ name = "Cup", size = Vector3.new(1.0, 0.7, 0.7), cframe = CFrame.new(px, surfaceY + 0.5, pz) * CFrame.Angles(0, 0, math.rad(90)), color = Color3.fromRGB(245, 245, 245), material = Enum.Material.SmoothPlastic, canCollide = false, shape = Enum.PartType.Cylinder, parent = parent })
		elseif roll == 5 then
			-- pizza box
			makePart({ name = "PizzaBox", size = Vector3.new(3, 0.4, 3), cframe = CFrame.new(px, surfaceY + 0.2, pz) * CFrame.Angles(0, rotY, 0), color = Color3.fromRGB(208, 178, 138), material = Enum.Material.SmoothPlastic, canCollide = false, parent = parent })
		else
			-- loose papers
			makePart({ name = "Papers", size = Vector3.new(1.8, 0.08, 2.2), cframe = CFrame.new(px, surfaceY + 0.05, pz) * CFrame.Angles(0, rotY, 0), color = Color3.fromRGB(245, 245, 240), material = Enum.Material.SmoothPlastic, canCollide = false, parent = parent })
		end
	end
end

--------------------------------------------------------------------------------
-- Room content builders
--------------------------------------------------------------------------------
local function buildLab(parent: Instance, minX: number, maxX: number, minZ: number, maxZ: number, level: number, makePlayerDesks: boolean)
	local y = floorY(level)
	local cx = (minX + maxX) / 2
	local cz = (minZ + maxZ) / 2
	-- Denser, less-uniform bullpen: a tighter grid of workstations where each row
	-- faces the opposite way and every desk gets a little rotation jitter, plus
	-- cubicle dividers and scattered junk so it reads as a lived-in dev floor.
	local ncols = math.clamp(math.floor((maxX - minX) / 15), 2, 4)
	local nrows = math.clamp(math.floor((maxZ - minZ) / 17), 2, 3)
	local cols = {}
	for i = 1, ncols do
		cols[i] = minX + 9 + (i - 1) * ((maxX - minX - 18) / math.max(1, ncols - 1))
	end
	local rows = {}
	for r = 1, nrows do
		rows[r] = minZ + 9 + (r - 1) * ((maxZ - minZ - 18) / math.max(1, nrows - 1))
	end

	local idx = 0
	local playerDesks = 0
	for ri, rz in ipairs(rows) do
		for _, dx in ipairs(cols) do
			idx += 1
			-- Alternate which way each row faces, with a small random yaw jitter.
			local faceYaw = (ri % 2 == 0) and 180 or 0
			local jitter = math.rad(math.random(-9, 9))
			local station = AssetLibrary.clone("Workstation", CFrame.new(dx, y, rz) * CFrame.Angles(0, math.rad(faceYaw) + jitter, 0))
			if not station then
				continue
			end
			station.Parent = parent
			local desk = station:FindFirstChild("Desk")
			local seat = station:FindFirstChild("Seat")
			local isPlayerDesk = false

			if makePlayerDesks and playerDesks < 4 then
				-- player workstations: tagged for coding, left empty (no typist)
				isPlayerDesk = true
				playerDesks += 1
				if desk then
					tag(desk, TAGS.PLAYER_DESK)
					desk:SetAttribute("DeskId", "desk_" .. playerDesks)
				end
				if seat then
					seat:Destroy()
				end
			elseif (idx + level) % 6 ~= 0 and seat then
				-- most desks get an ambient typist; ~1 in 6 left empty
				tag(seat, TAGS.DESK_SEAT)
				seat:SetAttribute("FaceZ", faceYaw == 0 and -1 or 1) -- faces the monitor
			elseif seat then
				seat:Destroy() -- empty desk
			end

			-- junk on non-player desks
			if not isPlayerDesk and math.random() < 0.75 then
				scatterTrash(parent, dx - 2, dx + 2, rz - 1, rz + 1, y + 3.15, math.random(1, 2))
			end

			-- cubicle divider behind ~40% of desks to break up the open plan.
			-- Placed well back (4.2 studs) so it clears the seated worker instead of
			-- clipping through their chair/body.
			if math.random() < 0.4 then
				local dz = faceYaw == 0 and (rz + 4.2) or (rz - 4.2)
				makePart({ name = "Divider", size = Vector3.new(5.5, 3, 0.3), position = Vector3.new(dx, y + 1.5, dz), color = Color3.fromRGB(120, 126, 142), material = Enum.Material.Fabric, parent = parent })
			end

			if idx % 5 == 0 then
				tag(makePart({ name = "HideSpot", size = Vector3.new(4, 2.5, 2.5), position = Vector3.new(dx, y + 1.3, rz), transparency = 1, canCollide = false, parent = parent }), TAGS.HIDING_SPOT)
			end
		end
	end

	-- edge furniture for density + variety
	place("Whiteboard", minX + 0.8, y, cz, 270, parent)
	place("WaterCooler", maxX - 3, y, minZ + 4, 0, parent)
	place("Plant", maxX - 3, y, maxZ - 3, 0, parent)
	scatterTrash(parent, minX + 7, maxX - 7, minZ + 7, maxZ - 7, y, math.random(6, 10))

	if level == 0 and makePlayerDesks then
		local qc = makePart({ name = "FoldingChair", size = Vector3.new(2, 2.5, 2), position = Vector3.new(cx, y + 1.25, cz), color = Color3.fromRGB(150, 60, 60), material = Enum.Material.Metal, parent = parent })
		tag(qc, TAGS.QUEST_CHAIR)
		qc:SetAttribute("ItemName", "Folding Chair")
	end
end

--- A proper restroom: a row of partitioned stalls (with doors + toilets) along
--- the back wall, urinals down one side, and a sink vanity with a long mirror
--- on the front wall — all on a tiled floor under cool tube lighting.
local function buildBathroom(parent: Instance, minX: number, maxX: number, minZ: number, maxZ: number, level: number, isBossRoom: boolean, corridorSide: string)
	local y = floorY(level)
	local cx = (minX + maxX) / 2
	local cz = (minZ + maxZ) / 2
	local width = maxX - minX
	local depth = maxZ - minZ

	-- The corridor door is on minZ (north-band room → corridorSide "south") or maxZ
	-- (south-band room → "north"). Keep that wall clear: stalls go on the OPPOSITE
	-- Z wall, the sink vanity on the WEST wall and urinals on the EAST wall — so no
	-- fixture ever sits in front of the doorway.
	local doorOnMinZ = (corridorSide == "south")
	local backZ = if doorOnMinZ then maxZ else minZ -- stalls wall (opposite the door)
	local intoRoom = if doorOnMinZ then -1 else 1 -- direction from the back wall into the room

	-- tiled floor + wainscot on the stall (back) wall
	makePart({ name = "BathFloor", size = Vector3.new(width - 1, 0.1, depth - 1), position = Vector3.new(cx, y + 0.06, cz), color = COLORS.TILE_FLOOR, material = Enum.Material.SmoothPlastic, canCollide = false, parent = parent })
	makePart({ name = "Wainscot", size = Vector3.new(width, 4, 0.1), position = Vector3.new(cx, y + 2, backZ - intoRoom * 0.95), color = COLORS.TILE_WALL, material = Enum.Material.SmoothPlastic, canCollide = false, parent = parent })

	-- Toilet stalls along the back wall (opposite the corridor door).
	local stallW = 5
	local nStalls = math.clamp(math.floor((width - 8) / stallW), 2, 5)
	local stallDepth = 6
	local stallZc = backZ + intoRoom * (1 + stallDepth / 2)
	local frontZ = backZ + intoRoom * (1 + stallDepth)
	local toiletZ = backZ + intoRoom * 2.6
	local toiletYaw = if intoRoom == -1 then 0 else 180 -- face into the room
	local startX = cx - (nStalls * stallW) / 2
	for i = 0, nStalls - 1 do
		local sx0 = startX + i * stallW
		makePart({ name = "StallSide", size = Vector3.new(0.2, 6, stallDepth), position = Vector3.new(sx0, y + 3, stallZc), color = COLORS.WALL_TRIM, material = Enum.Material.SmoothPlastic, parent = parent })
		local t = AssetLibrary.clone("Toilet", CFrame.new(sx0 + stallW / 2, y, toiletZ) * CFrame.Angles(0, math.rad(toiletYaw), 0))
		if t then
			t.Parent = parent
		end
		makePart({ name = "StallDoor", size = Vector3.new(stallW - 0.6, 4, 0.15), position = Vector3.new(sx0 + stallW / 2, y + 2.8, frontZ), color = Color3.fromRGB(150, 90, 70), material = Enum.Material.SmoothPlastic, canCollide = false, parent = parent })
	end
	makePart({ name = "StallSide", size = Vector3.new(0.2, 6, stallDepth), position = Vector3.new(startX + nStalls * stallW, y + 3, stallZc), color = COLORS.WALL_TRIM, material = Enum.Material.SmoothPlastic, parent = parent })

	-- Sink vanity + long mirror on the WEST wall (minX), facing +X into the room.
	local counterL = math.max(6, depth - 12)
	makePart({ name = "Vanity", size = Vector3.new(2, 2.6, counterL), position = Vector3.new(minX + 2, y + 1.3, cz), color = Color3.fromRGB(60, 62, 70), material = Enum.Material.SmoothPlastic, parent = parent })
	makePart({ name = "CounterTop", size = Vector3.new(2.4, 0.4, counterL), position = Vector3.new(minX + 2, y + 2.7, cz), color = Color3.fromRGB(40, 42, 48), material = Enum.Material.Slate, parent = parent })
	local nSink = math.clamp(math.floor(counterL / 5), 2, 5)
	for i = 0, nSink - 1 do
		local szk = cz - counterL / 2 + counterL * (i + 0.5) / nSink
		local basin = makePart({ name = "Basin", size = Vector3.new(1.6, 0.5, 2.4), position = Vector3.new(minX + 2, y + 2.78, szk), color = COLORS.TOILET, material = Enum.Material.SmoothPlastic, parent = parent })
		basin.CanCollide = false
		makePart({ name = "Faucet", size = Vector3.new(0.25, 1, 0.25), position = Vector3.new(minX + 2.6, y + 3.4, szk), color = COLORS.METAL_BRUSHED, material = Enum.Material.Metal, canCollide = false, parent = parent })
	end
	makePart({ name = "MirrorFrame", size = Vector3.new(0.12, 4.6, counterL + 0.6), position = Vector3.new(minX + 0.84, y + 6, cz), color = COLORS.METAL_BRUSHED, material = Enum.Material.Metal, canCollide = false, parent = parent })
	makePart({ name = "Mirror", size = Vector3.new(0.1, 4, counterL), position = Vector3.new(minX + 0.9, y + 6, cz), color = Color3.fromRGB(205, 222, 235), material = Enum.Material.Glass, reflectance = 0.55, canCollide = false, parent = parent })

	-- Urinals along the EAST wall (maxX), facing -X into the room.
	local nUr = 3
	for i = 0, nUr - 1 do
		local uz = cz - 4.5 + i * 4.5
		local u = AssetLibrary.clone("Urinal", CFrame.new(maxX - 1.2, y, uz) * CFrame.Angles(0, math.rad(90), 0))
		if u then
			u.Parent = parent
		end
		if i < nUr - 1 then
			makePart({ name = "UrinalDivider", size = Vector3.new(1.6, 3.5, 0.15), position = Vector3.new(maxX - 1.6, y + 3.2, uz + 2.25), color = COLORS.WALL_TRIM, material = Enum.Material.SmoothPlastic, parent = parent })
		end
	end

	-- cool overhead tube lights (tagged so the NIGHT2 blackout kills them too — they
	-- only come back when this floor's power boxes are repaired)
	for _, lz in { cz - depth / 4, cz + depth / 4 } do
		local lt = makePart({ name = "BathLight", size = Vector3.new(1, 0.3, 5), position = Vector3.new(cx, y + INNER_H - 0.3, lz), color = Color3.fromRGB(235, 245, 255), material = Enum.Material.Neon, parent = parent })
		addPointLight(lt, 1.1, 22, Color3.fromRGB(220, 235, 255))
		tag(lt, TAGS.CEILING_LIGHT)
	end

	-- a hiding spot in the far stall (kept for the survival gameplay)
	tag(makePart({ name = "HideSpot", size = Vector3.new(3, 2.5, 3), position = Vector3.new(startX + (nStalls - 0.5) * stallW, y + 1.3, toiletZ), transparency = 1, canCollide = false, parent = parent }), TAGS.HIDING_SPOT)

	-- A plunger leaning in the corner — the Poop Monster's counter-weapon only
	-- ever turns up where you'd actually find a plunger: in a restroom.
	itemSpawn("plunger", Vector3.new(startX - 1.2, y + 1.6, stallZc), parent)

	if isBossRoom then
		tag(marker("PoopMonsterSpawn", Vector3.new(cx, y + 1, backZ + intoRoom * 3), parent), TAGS.POOP_MONSTER_SPAWN)
		tag(marker("NGMISpawn_Boss", Vector3.new(cx, y + 1, backZ + intoRoom * 3), parent), TAGS.NGMI_SPAWN)
	end
end

local function buildSupply(parent: Instance, minX: number, maxX: number, minZ: number, maxZ: number, level: number)
	local y = floorY(level)
	local cx = (minX + maxX) / 2
	local shelfZ = maxZ - 3

	-- Two shelving units lined up against the back wall. The items are then
	-- placed ON these boards (previously the spawns used hard-coded X offsets
	-- from minX that didn't line up with the centred shelf, so every pickup
	-- floated in mid-air beside the rack).
	local leftCenter = Vector3.new(cx - 7, y, shelfZ)
	local rightCenter = Vector3.new(cx + 7, y, shelfZ)
	for _, c in { leftCenter, rightCenter } do
		local shelf = AssetLibrary.clone("Shelf", CFrame.new(c.X, c.Y, c.Z))
		if shelf then
			shelf.Parent = parent
		end
	end

	-- Items resting on the boards (bottom two boards keep them within reach).
	shelfItemSpawn("deodorant", leftCenter, 1, -3, parent)
	shelfItemSpawn("energy_bar", leftCenter, 1, 1.5, parent)
	shelfItemSpawn("battery", leftCenter, 2, -1, parent)
	shelfItemSpawn("energy_bar", rightCenter, 1, -2, parent)
	shelfItemSpawn("deodorant", rightCenter, 2, 2, parent)
	shelfItemSpawn("battery", rightCenter, 2, -2.5, parent)
	if level == 0 then
		shelfItemSpawn("deodorant", rightCenter, 1, 3, parent)
	end

	-- On the WEST wall (always door-free) in a corner, so it isn't mounted in the
	-- east doorway. (Faces +X into the room.) Mounted PROUD of the wall: the wall is
	-- WALL_T (1.5) thick centred on minX, so its inner face is at minX+0.75. We sit
	-- the 0.6-thick panel's back flush there (centre minX+1.05) so its body — and the
	-- ProximityPrompt anchored to it — are in open room space, not buried in the wall.
	-- (Buried, the prompt's RequiresLineOfSight ray hit the wall and it never showed.)
	tag(makePart({ name = "ElectricalPanel", size = Vector3.new(0.6, 3, 2.4), position = Vector3.new(minX + 1.05, y + 3.2, minZ + 4), color = Color3.fromRGB(58, 60, 66), material = Enum.Material.Metal, parent = parent }), TAGS.ELECTRICAL_PANEL)

	-- A repairable server rack against the west wall. On NIGHT2 it sits dead (red
	-- status); once this floor's power is restored, PowerManager enables its
	-- "Repair Server" prompt.
	local rackPos = Vector3.new(minX + 1.4, y, (minZ + maxZ) / 2)
	local rack = Instance.new("Model")
	rack.Name = "ServerRack"
	local body = makePart({ name = "RackBody", size = Vector3.new(2, 8, 2.6), position = rackPos + Vector3.new(0, 4, 0), color = COLORS.SERVER_RACK, material = Enum.Material.Metal, parent = rack })
	makePart({ name = "Status", size = Vector3.new(0.3, 0.7, 0.3), position = rackPos + Vector3.new(1.05, 7, 0), color = Color3.fromRGB(220, 60, 50), material = Enum.Material.Neon, parent = rack })
	for i = 0, 4 do
		makePart({ name = "Blink", size = Vector3.new(0.25, 0.25, 0.12), position = rackPos + Vector3.new(1.05, 2 + i * 1.1, 0.9), color = Color3.fromRGB(70, 90, 110), material = Enum.Material.Neon, parent = rack })
	end
	local sPrompt = Instance.new("ProximityPrompt")
	sPrompt.ActionText = "Repair Server"
	sPrompt.ObjectText = "Server Rack"
	sPrompt.HoldDuration = 2
	sPrompt.MaxActivationDistance = 8
	sPrompt.RequiresLineOfSight = false
	sPrompt.Enabled = false -- PowerManager enables it once the floor has power
	sPrompt.Parent = body
	rack.PrimaryPart = body
	tag(rack, TAGS.SERVER_RACK)
	rack.Parent = parent

	scatterTrash(parent, minX + 6, maxX - 6, minZ + 5, minZ + 12, y, math.random(3, 6))
end

--- Chill-out lounge: a TV wall, a couch cluster around a coffee table, bean
--- bags, plants and a fair bit of junk. "far" wall = the one opposite the door.
local function buildLounge(parent: Instance, minX: number, maxX: number, minZ: number, maxZ: number, level: number)
	local y = floorY(level)
	local cx = (minX + maxX) / 2
	local cz = (minZ + maxZ) / 2
	local north = cz > 0
	local farZ = north and maxZ or minZ
	local inDir = north and -1 or 1 -- direction from the far wall into the room
	local tvYaw = north and 0 or 180 -- TV faces into the room
	local couchYaw = north and 180 or 0 -- main couch faces the TV

	makePart({ name = "Rug", size = Vector3.new(18, 0.1, 14), position = Vector3.new(cx, y + 0.06, cz), color = Color3.fromRGB(110, 60, 70), material = Enum.Material.Fabric, canCollide = false, parent = parent })

	place("TV", cx, y, farZ + inDir * 0.8, tvYaw, parent)
	local mainCouch = place("Couch", cx, y, farZ + inDir * 13, couchYaw, parent)
	place("CoffeeTable", cx, y, farZ + inDir * 8, 0, parent)
	place("Couch", cx - 9, y, cz, 270, parent) -- west couch faces +X (into room)
	place("Couch", cx + 9, y, cz, 90, parent) -- east couch faces -X
	place("BeanBag", cx - 5, y, farZ + inDir * 5, 0, parent)
	place("BeanBag", cx + 5, y, farZ + inDir * 5, 0, parent)
	place("Plant", minX + 4, y, farZ + inDir * 3, 0, parent)
	place("Plant", maxX - 4, y, farZ + inDir * 3, 0, parent)

	scatterTrash(parent, cx - 2.5, cx + 2.5, farZ + inDir * 8 - 1.4, farZ + inDir * 8 + 1.4, y + 1.7, math.random(3, 5))
	scatterTrash(parent, minX + 7, maxX - 7, minZ + 7, maxZ - 7, y, math.random(7, 11))
	-- back to the west wall, facing east into the room
	leanSpot("LeanSpot_Lounge_" .. level, Vector3.new(minX + 1.6, y + 0.2, cz), parent, Vector3.new(1, 0, 0))

	-- a couple of hackers crash out in here: one asleep on the main couch, one in a
	-- sleeping bag on the floor by the wall.
	if mainCouch then
		local cushion = mainCouch:FindFirstChild("CushionR")
		if cushion then
			tag(cushion, TAGS.COUCH_SEAT)
		end
	end
	local sleepMarker = marker("SleepSpot_Lounge_" .. level, Vector3.new(maxX - 5, y + 0.05, maxZ - 6), parent, TAGS.SLEEP_SPOT)
	sleepMarker:SetAttribute("Yaw", 90) -- bag lies along X, tucked beside the wall
end

--- Conference room: a long table ringed with office chairs, a whiteboard, a
--- presentation TV and laptops/cups strewn over the table.
local function buildMeeting(parent: Instance, minX: number, maxX: number, minZ: number, maxZ: number, level: number)
	local y = floorY(level)
	local cx = (minX + maxX) / 2
	local cz = (minZ + maxZ) / 2
	local north = cz > 0
	local farZ = north and maxZ or minZ
	local inDir = north and -1 or 1
	local tvYaw = north and 0 or 180

	local tLen = math.clamp((maxZ - minZ) - 28, 12, 30)
	makePart({ name = "ConfTable", size = Vector3.new(6, 0.4, tLen), position = Vector3.new(cx, y + 3, cz), color = Color3.fromRGB(110, 82, 55), material = Enum.Material.Wood, parent = parent })
	for sx = -1, 1, 2 do
		makePart({ name = "TableLeg", size = Vector3.new(0.5, 3, 0.5), position = Vector3.new(cx + sx * 2.5, y + 1.5, cz - tLen / 2 + 1), color = Color3.fromRGB(70, 70, 75), material = Enum.Material.Metal, parent = parent })
		makePart({ name = "TableLeg", size = Vector3.new(0.5, 3, 0.5), position = Vector3.new(cx + sx * 2.5, y + 1.5, cz + tLen / 2 - 1), color = Color3.fromRGB(70, 70, 75), material = Enum.Material.Metal, parent = parent })
	end

	local nChairs = math.max(2, math.floor(tLen / 5))
	for i = 0, nChairs - 1 do
		local zc = cz - tLen / 2 + 3 + i * (tLen - 6) / math.max(1, nChairs - 1)
		place("OfficeChair", cx - 4.5, y, zc, 270, parent) -- west side faces +X (table)
		place("OfficeChair", cx + 4.5, y, zc, 90, parent) -- east side faces -X (table)
	end

	place("Whiteboard", minX + 0.8, y, cz, 270, parent)
	place("TV", cx, y, farZ + inDir * 0.8, tvYaw, parent)
	place("Plant", maxX - 4, y, farZ + inDir * 3, 0, parent)
	place("Laptop", cx - 1.8, y + 3.3, cz - 3, math.random(0, 359), parent)
	place("Laptop", cx + 1.8, y + 3.3, cz + 3, math.random(0, 359), parent)
	scatterTrash(parent, cx - 2, cx + 2, cz - tLen / 2 + 2, cz + tLen / 2 - 2, y + 3.3, math.random(4, 7))
end

--- Break room: counter with vending machines + water cooler + fridge along the
--- far wall, a couple of bistro tables, and a LOT of snack debris.
local function buildBreakroom(parent: Instance, minX: number, maxX: number, minZ: number, maxZ: number, level: number)
	local y = floorY(level)
	local cx = (minX + maxX) / 2
	local cz = (minZ + maxZ) / 2
	local north = cz > 0
	local farZ = north and maxZ or minZ
	local inDir = north and -1 or 1
	local faceIn = north and 0 or 180

	makePart({ name = "Counter", size = Vector3.new((maxX - minX) - 16, 3, 2.5), position = Vector3.new(cx, y + 1.5, farZ + inDir * 2), color = COLORS.COUNTER, material = Enum.Material.SmoothPlastic, parent = parent })
	place("Vending", minX + 6, y, farZ + inDir * 2, faceIn, parent)
	place("Vending", minX + 11, y, farZ + inDir * 2, faceIn, parent)
	place("WaterCooler", maxX - 7, y, farZ + inDir * 2.5, faceIn, parent)
	makePart({ name = "Fridge", size = Vector3.new(4, 7, 4), position = Vector3.new(maxX - 12, y + 3.5, farZ + inDir * 2.5), color = Color3.fromRGB(220, 225, 230), material = Enum.Material.SmoothPlastic, parent = parent })

	for _, sign in { -1, 1 } do
		local tx = cx + sign * ((maxX - minX) / 5)
		local tz = cz - inDir * 4
		place("BistroTable", tx, y, tz, 0, parent)
		place("OfficeChair", tx, y, tz + 3, 180, parent)
		place("OfficeChair", tx, y, tz - 3, 0, parent)
		scatterTrash(parent, tx - 2, tx + 2, tz - 2, tz + 2, y + 3.15, math.random(2, 4))
	end

	place("Plant", minX + 4, y, cz, 0, parent)
	scatterTrash(parent, minX + 7, maxX - 7, minZ + 7, maxZ - 7, y, math.random(10, 16))
end

--------------------------------------------------------------------------------
-- Ground-floor auditorium / lecture hall
--------------------------------------------------------------------------------

--- A long bench seat (plank + backrest + legs) for the raked seating tiers.
local function benchRow(parent: Instance, x0: number, x1: number, topY: number, z: number)
	if x1 - x0 < 3 then
		return
	end
	local w = x1 - x0
	local cxr = (x0 + x1) / 2
	-- A SOLID stadium bench resting directly on the tier step (no floating gap /
	-- thin floating plank that read as "no seat"), plus a backrest behind it. The
	-- seat is a real Seat so you can sit. Faces -Z (toward the stage).
	local bench = Instance.new("Seat")
	bench.Name = "BenchSeat"
	bench.Size = Vector3.new(w, 1.2, 2.4)
	bench.Position = Vector3.new(cxr, topY + 0.6, z)
	bench.Anchored = true
	bench.Color = Color3.fromRGB(150, 60, 60)
	bench.Material = Enum.Material.Fabric
	bench.TopSurface = Enum.SurfaceType.Smooth
	bench.BottomSurface = Enum.SurfaceType.Smooth
	bench.Parent = parent
	makePart({ name = "BenchBack", size = Vector3.new(w, 2.2, 0.4), position = Vector3.new(cxr, topY + 2.0, z + 1.4), color = Color3.fromRGB(135, 52, 52), material = Enum.Material.Fabric, parent = parent })
end

--- A cloth banner hanging from a ceiling rod; the printed face points +Z (Back).
local function hangingBanner(parent: Instance, x: number, topY: number, z: number, length: number, color: Color3, title: string, body: string)
	makePart({ name = "BannerRod", size = Vector3.new(5.4, 0.3, 0.3), position = Vector3.new(x, topY, z), color = Color3.fromRGB(120, 122, 130), material = Enum.Material.Metal, canCollide = false, parent = parent })
	local cloth = makePart({ name = "Flag", size = Vector3.new(5, length, 0.2), position = Vector3.new(x, topY - length / 2, z), color = color, material = Enum.Material.Fabric, canCollide = false, parent = parent })
	addPosterSurface(cloth, Enum.NormalId.Back, title, body, Color3.fromRGB(20, 20, 26), Color3.fromRGB(245, 245, 245))
end

--- Build the lecture hall: stage + projector screen at the south end, raked
--- bench seating rising toward the north entrance, flanking university banners.
local function buildAuditorium(parent: Instance)
	local y = floorY(0)
	local minX, maxX, minZ, maxZ = AUD.minX, AUD.maxX, AUD.minZ, AUD.maxZ
	local cx = (minX + maxX) / 2

	-- own walls (slab supplies floor + ceiling); doors on the corridor (north),
	-- the east hallway, and the west perimeter hallway.
	buildRoomWalls(parent, minX, maxX, minZ, maxZ, 0, COLORS.WALL, Enum.Material.Concrete, { north = { width = 16, height = 11 }, east = { width = 8, height = 10 }, west = { width = 8, height = 10 } })

	makePart({ name = "AudCarpet", size = Vector3.new(maxX - minX - 2, 0.1, maxZ - minZ - 2), position = Vector3.new(cx, y + 0.06, (minZ + maxZ) / 2), color = Color3.fromRGB(70, 40, 50), material = Enum.Material.Fabric, canCollide = false, parent = parent })

	-- stage at the south end
	local stageH = 2
	local stageZ0, stageZ1 = minZ + 1, minZ + 19
	makePart({ name = "Stage", size = Vector3.new(maxX - minX - 8, stageH, stageZ1 - stageZ0), position = Vector3.new(cx, y + stageH / 2, (stageZ0 + stageZ1) / 2), color = Color3.fromRGB(70, 48, 32), material = Enum.Material.WoodPlanks, parent = parent })

	-- big projector screen on the south wall, facing the seats (+Z = Back)
	local screen = makePart({ name = "ProjectorScreen", size = Vector3.new(46, 14, 0.3), position = Vector3.new(cx, y + 9.5, minZ + 0.9), color = Color3.fromRGB(235, 238, 245), material = Enum.Material.SmoothPlastic, parent = parent })
	addSurfaceText(screen, Enum.NormalId.Back, "VesperHacks 2026\nWelcome, hackers.", Color3.fromRGB(30, 32, 40), Color3.fromRGB(235, 238, 245), Enum.Font.GothamBold)

	-- lectern on stage. The asset's reading slope + mic are on its -Z side, which is
	-- where the speaker stands (just behind it, toward the screen), so yaw 0 turns
	-- the reading side toward the speaker and the blank front panel toward the
	-- audience — i.e. it faces the speaker, not the crowd.
	place("Lectern", cx - 14, y + stageH, stageZ1 - 3, 0, parent)

	-- flanking university banners
	hangingBanner(parent, cx - 26, y + INNER_H - 0.5, minZ + 2, 11, COLORS.UNI_MAROON, "ST. VESPER", "UNIVERSITY\nEst. 1962")
	hangingBanner(parent, cx + 26, y + INNER_H - 0.5, minZ + 2, 11, COLORS.UNI_NAVY, "SCHOOL OF", "COMPUTING\n& ENGINEERING")

	-- raked seating rising toward the north entrance, split by a centre aisle.
	-- Each tier is a SOLID step from the floor up to its tread (no see-through
	-- gaps between platforms), so the seating reads as one continuous rake.
	local aisleHalf = 5
	local tierStartZ = stageZ1 + 9
	local tiers = 5
	local tierStep = 9
	for t = 0, tiers - 1 do
		local z = tierStartZ + t * tierStep
		local h = t * 1.5
		local stepH = h + 0.8
		makePart({ name = "SeatTier", size = Vector3.new(maxX - minX - 6, stepH, tierStep), position = Vector3.new(cx, y + stepH / 2, z + 0.5), color = Color3.fromRGB(90, 92, 100), material = Enum.Material.Concrete, parent = parent })
		benchRow(parent, minX + 6, cx - aisleHalf, y + h + 0.8, z)
		benchRow(parent, cx + aisleHalf, maxX - 6, y + h + 0.8, z)
		if t == tiers - 1 then
			tag(makePart({ name = "HideSpot", size = Vector3.new(4, 2.5, 3), position = Vector3.new(minX + 9, y + h + 2, z), transparency = 1, canCollide = false, parent = parent }), TAGS.HIDING_SPOT)
		end
	end

	-- Back of the hall. The full width USED to be one giant descending staircase;
	-- now only the doorway span gets the exit stairs (down to the north door) and
	-- the flanks become one more, highest row of bench seating.
	local topH = (tiers - 1) * 1.5 + 0.8 -- tread height of the current top tier (6.8)
	local backH = topH + 1.5 -- the extra row sits one tier-step higher
	local backZ = tierStartZ + (tiers - 1) * tierStep + tierStep / 2
	local backDepth = (maxZ - 2) - backZ
	local doorHalf = 8 -- matches the 16-wide north door, centred on cx

	-- highest row of seats on each flank of the doorway
	for _, span in { { minX + 6, cx - doorHalf }, { cx + doorHalf, maxX - 6 } } do
		local x0, x1 = span[1], span[2]
		makePart({ name = "SeatTier", size = Vector3.new(x1 - x0, backH, backDepth), position = Vector3.new((x0 + x1) / 2, y + backH / 2, backZ + backDepth / 2), color = Color3.fromRGB(90, 92, 100), material = Enum.Material.Concrete, parent = parent })
		benchRow(parent, x0, x1, y + backH, backZ + 1)
	end

	-- central exit staircase — only as wide as the doorway — descending from the
	-- top-tier level down to the floor at the north exit.
	local nSteps = 5
	local stepDepth = math.max(0.6, backDepth / nSteps)
	for i = 0, nSteps - 1 do
		local sh = topH * (nSteps - i) / (nSteps + 1)
		local sz = backZ + i * stepDepth
		makePart({ name = "ExitStair", size = Vector3.new(doorHalf * 2, sh, stepDepth + 0.1), position = Vector3.new(cx, y + sh / 2, sz + stepDepth / 2), color = Color3.fromRGB(85, 87, 95), material = Enum.Material.Concrete, parent = parent })
	end

	-- ceiling lights
	for _, lp in { { cx - 30, stageZ1 }, { cx + 30, stageZ1 }, { cx - 30, (minZ + maxZ) / 2 + 12 }, { cx + 30, (minZ + maxZ) / 2 + 12 } } do
		local lt = makePart({ name = "CeilingLight", size = Vector3.new(8, 0.3, 3), position = Vector3.new(lp[1], y + INNER_H - 0.3, lp[2]), color = Color3.fromRGB(255, 255, 245), material = Enum.Material.Neon, parent = parent })
		addPointLight(lt, 1.3, 40)
		tag(lt, TAGS.CEILING_LIGHT)
	end

	-- door sign over the corridor entrance (+Z = Back) and horror markers
	local sign = makePart({ name = "RoomSign", size = Vector3.new(10, 1.4, 0.2), position = Vector3.new(cx, y + 12, maxZ + 0.9), color = Color3.fromRGB(28, 30, 42), material = Enum.Material.SmoothPlastic, parent = parent })
	addSurfaceText(sign, Enum.NormalId.Back, "AUDITORIUM · LECTURE HALL A", Color3.fromRGB(120, 220, 255), Color3.fromRGB(28, 30, 42))
	tag(marker("NGMISpawn_Auditorium", Vector3.new(cx, y + 1, stageZ1 + 4), parent), TAGS.NGMI_SPAWN)
	-- back to the west wall, facing east into the hall
	leanSpot("LeanSpot_Aud", Vector3.new(minX + 1.6, y + 0.2, (minZ + maxZ) / 2), parent, Vector3.new(1, 0, 0))
end

--------------------------------------------------------------------------------
-- One floor: rooms + corridor markers
--------------------------------------------------------------------------------
-- Each floor is a GRID of small rooms separated by hallways, wrapped around a
-- central E-W corridor (Z in [-CORR_HALF, CORR_HALF]) and the east stairwell.
-- Smaller rooms + far more hallways than the old 8-big-room layout.
local CORR_HALF = 9 -- central corridor half-depth
local HALL = 8 -- hallway / gap width between rooms (and the perimeter ring)
local NCOLS = 6 -- rooms across the building (X)
local NROWS = 2 -- room rows per band (Z), per side of the corridor

-- Evenly tile [a0, a1] into `n` room spans with a `gap` hallway between every
-- room AND a gap margin at each end (so rooms never back straight onto the
-- perimeter or each other). Returns a list of { lo, hi }.
local function tileAxis(a0: number, a1: number, n: number, gap: number): { { number } }
	local roomSize = ((a1 - a0) - (n + 1) * gap) / n
	local spans = {}
	for i = 0, n - 1 do
		local lo = a0 + gap + i * (roomSize + gap)
		spans[i + 1] = { lo, lo + roomSize }
	end
	return spans
end

local ROOM_KINDS = { "lab", "lounge", "meeting", "break", "lab", "lounge", "meeting", "lab" }

-- One RNG per server boot, so the room layout (where supplies / the boss restroom
-- / the player-desk lab / etc. land) is shuffled fresh every game instead of being
-- nailed to the same cells on every floor.
local LAYOUT_RNG = Random.new()

-- Build a per-floor plan, scattering the special rooms across RANDOM cells each
-- game. Returns the kind list plus which roomNo is the boss restroom and which is
-- the player-desk lab (level 0 only). Specials are only placed in cells that
-- actually get built (auditorium-footprint cells on level 0 are excluded).
local function makeFloorPlan(level: number, cols: { { number } }, bands: { any }): ({ string }, { [number]: boolean }, { [number]: boolean })
	local valid: { number } = {}
	local count = 0
	for _, band in bands do
		for _, _row in band.rows do
			for _, col in cols do
				count += 1
				local cxr = (col[1] + col[2]) / 2
				-- row center
				local czr = (_row[1] + _row[2]) / 2
				local skip = (level == 0 and cxr >= AUD.minX and cxr <= AUD.maxX and czr >= AUD.minZ and czr <= AUD.maxZ)
				if not skip then
					table.insert(valid, count)
				end
			end
		end
	end

	-- Shuffle the build-able rooms, then deal special kinds off the top.
	for i = #valid, 2, -1 do
		local j = LAYOUT_RNG:NextInteger(1, i)
		valid[i], valid[j] = valid[j], valid[i]
	end

	local plan: { string } = {}
	for i = 1, count do
		plan[i] = ROOM_KINDS[LAYOUT_RNG:NextInteger(1, #ROOM_KINDS)]
	end

	local bossRooms: { [number]: boolean } = {}
	local labRooms: { [number]: boolean } = {}
	local vp = 1
	local function deal(kind: string): number?
		local idx = valid[vp]
		vp += 1
		if idx then
			plan[idx] = kind
		end
		return idx
	end

	if level == 0 then
		local labIdx = deal("lab")
		if labIdx then
			labRooms[labIdx] = true
		end
		local bossIdx = deal("bath")
		if bossIdx then
			bossRooms[bossIdx] = true
		end
	end
	deal("supply")
	deal("supply")
	deal("supply")
	deal("bath")

	return plan, bossRooms, labRooms
end

local function buildFloor(level: number)
	local folder = Instance.new("Folder")
	folder.Name = "Floor_" .. level
	folder.Parent = mapModel

	local y = floorY(level)
	local wallColor = ({ COLORS.WALL, Color3.fromRGB(205, 208, 214), Color3.fromRGB(198, 202, 210) })[level + 1]

	local cols = tileAxis(-FX, FX, NCOLS, HALL)
	local bands = {
		{ rows = tileAxis(CORR_HALF, FZ, NROWS, HALL), corridorSide = "south" }, -- north of the corridor
		{ rows = tileAxis(-FZ, -CORR_HALF, NROWS, HALL), corridorSide = "north" }, -- south of the corridor
	}

	local plan, bossRooms, playerLabRooms = makeFloorPlan(level, cols, bands)
	local roomNo = 0

	for _, band in bands do
		for _, row in band.rows do
			for _, col in cols do
				roomNo += 1
				local minX, maxX = col[1], col[2]
				local minZ, maxZ = row[1], row[2]
				local cxr = (minX + maxX) / 2
				local czr = (minZ + maxZ) / 2
				local kind = plan[roomNo] or "lab"

				-- On the ground floor, cells inside the auditorium footprint are
				-- replaced by the single large lecture hall (built after the loop).
				if level == 0 and cxr >= AUD.minX and cxr <= AUD.maxX and czr >= AUD.minZ and czr <= AUD.maxZ then
					continue
				end

				local roomFolder = Instance.new("Folder")
				roomFolder.Name = string.format("Room_L%d_%d_%s", level, roomNo, kind)
				roomFolder.Parent = folder

				-- Two doors per room (corridor-facing side + east) onto the
				-- surrounding hallway grid, so every room is reachable.
				local doors: RoomDoors = {}
				doors[band.corridorSide] = { width = 6, height = 9 }
				if kind ~= "bath" then
						doors.east = { width = 5, height = 9 }
					end

				-- STRUCTURE FIRST: build walls before any content that could error,
				-- so every room on every floor is guaranteed to be walled.
				buildRoomWalls(roomFolder, minX, maxX, minZ, maxZ, level, wallColor, Enum.Material.Concrete, doors)

				-- nameplate over the corridor-facing door
				local doorZ = band.corridorSide == "south" and minZ or maxZ
				local sign = makePart({
					name = "RoomSign",
					size = Vector3.new(5, 1, 0.2),
					position = Vector3.new(cxr, y + 10, doorZ + (band.corridorSide == "south" and -0.9 or 0.9)),
					color = Color3.fromRGB(28, 30, 42),
					material = Enum.Material.SmoothPlastic,
					parent = roomFolder,
				})
				local labelTxt = (kind == "bath" and "RESTROOM")
					or (kind == "supply" and "SUPPLY")
					or (kind == "lounge" and "LOUNGE")
					or (kind == "meeting" and "MEETING")
					or (kind == "break" and "BREAK ROOM")
					or ("LAB " .. roomNo)
				addSurfaceText(sign, band.corridorSide == "south" and Enum.NormalId.Front or Enum.NormalId.Back, labelTxt, Color3.fromRGB(120, 220, 255), Color3.fromRGB(28, 30, 42))

				-- one ceiling light per (now smaller) room
				local lt = makePart({ name = "CeilingLight", size = Vector3.new(8, 0.3, 2), position = Vector3.new(cxr, y + INNER_H - 0.3, (minZ + maxZ) / 2), color = Color3.fromRGB(255, 255, 245), material = Enum.Material.Neon, parent = roomFolder })
				addPointLight(lt, 1.3, 34)
				tag(lt, TAGS.CEILING_LIGHT)

				-- A poster / bulletin board on the corridor-facing wall beside the
				-- door, so the hallways read as a real, decorated venue.
				local poster = POSTER_POOL[((roomNo + level * 2) % #POSTER_POOL) + 1]
				placeRoomPoster(roomFolder, cxr, minZ, maxZ, y, band.corridorSide, poster)

				-- CONTENT LAST and wrapped: a furniture error can never strip the
				-- room's (already-built) walls or abort the rest of the floor.
				local ok, err = pcall(function()
					if kind == "bath" then
						buildBathroom(roomFolder, minX, maxX, minZ, maxZ, level, bossRooms[roomNo] == true, band.corridorSide)
					elseif kind == "supply" then
						buildSupply(roomFolder, minX, maxX, minZ, maxZ, level)
					elseif kind == "lounge" then
						buildLounge(roomFolder, minX, maxX, minZ, maxZ, level)
					elseif kind == "meeting" then
						buildMeeting(roomFolder, minX, maxX, minZ, maxZ, level)
					elseif kind == "break" then
						buildBreakroom(roomFolder, minX, maxX, minZ, maxZ, level)
					else
						buildLab(roomFolder, minX, maxX, minZ, maxZ, level, playerLabRooms[roomNo] == true)
					end
				end)
				if not ok then
					warn(string.format("[MapBuilder] content failed for %s: %s", roomFolder.Name, tostring(err)))
				end

				if roomNo % 3 == 0 then
					tag(marker("NGMISpawn_L" .. level .. "_" .. roomNo, Vector3.new(cxr, y + 1, (minZ + maxZ) / 2), roomFolder), TAGS.NGMI_SPAWN)
				end
			end
		end
	end

	-- free-standing sponsor banners down the central corridor, alternating sides
	local bannerXs = { -130, -80, -30, 30, 80, 120 }
	for i, bx in bannerXs do
		local northSide = (i % 2 == 0)
		local bz = northSide and (CORR_HALF - 2) or -(CORR_HALF - 2)
		local sponsor = SPONSOR_POOL[((i - 1 + level) % #SPONSOR_POOL) + 1]
		-- a north-side banner faces -Z (toward the corridor centre); south faces +Z
		bannerStand(folder, bx, y, bz, northSide, sponsor)
	end

	-- central corridor lights + emergency lights + lean spots + ngmi spawns
	for cx = -140, 120, 26 do
		local lt = makePart({ name = "CeilingLight", size = Vector3.new(6, 0.3, 2), position = Vector3.new(cx, y + INNER_H - 0.3, 0), color = Color3.fromRGB(255, 255, 245), material = Enum.Material.Neon, parent = folder })
		addPointLight(lt, 1.2, 28)
		tag(lt, TAGS.CEILING_LIGHT)
	end
	for _, ex in { -120, -40, 60 } do
		local em = makePart({ name = "EmergencyLight", size = Vector3.new(1, 0.5, 1), position = Vector3.new(ex, y + INNER_H - 1, 0), color = COLORS.EMERGENCY, material = Enum.Material.Neon, transparency = 0.7, parent = folder })
		addPointLight(em, 1.5, 16, COLORS.EMERGENCY, false)
		tag(em, TAGS.EMERGENCY_LIGHT)
	end
	for i, lx in { -110, -50, 40, 100 } do
		local northSide = (i % 2 == 0)
		local lz = northSide and (CORR_HALF - 1.2) or -(CORR_HALF - 1.2)
		-- back to the corridor wall, facing in toward the centre line
		leanSpot("LeanSpot_Corr_" .. level .. "_" .. i, Vector3.new(lx, y + 0.2, lz), folder, Vector3.new(0, 0, northSide and -1 or 1))
	end
	tag(marker("NGMISpawn_CorrW_" .. level, Vector3.new(-100, y + 1, 0), folder), TAGS.NGMI_SPAWN)
	tag(marker("NGMISpawn_CorrE_" .. level, Vector3.new(80, y + 1, 0), folder), TAGS.NGMI_SPAWN)

	-- Collegiate hallway dressing: lockers, notice boards, fountains, a bookshelf
	-- and a trophy case. These now sit FLUSH against each room's corridor-facing
	-- wall (beside the door, on solid wall — never floating in the open cross-
	-- hallways/doorways where they used to hang in mid-air).
	local decorKinds = { "Locker", "NoticeBoard", "WaterFountain", "Bookshelf", "TrophyCase", "Locker" }
	local decorCxrs = { -130, -78, -26, 26, 78, 130 } -- room-column centres
	for i, cxr in decorCxrs do
		local north = (i % 2 == 0)
		local zc = north and 16 or -16 -- just in front of the corridor wall (z ≈ ±17)
		local yaw = north and 0 or 180 -- back to the wall, facing the corridor
		place(decorKinds[((i - 1 + level) % #decorKinds) + 1], cxr - 11, y, zc, yaw, folder)
	end

	-- The ground floor's south-west block is the auditorium (replaces those cells).
	if level == 0 then
		local ok, err = pcall(buildAuditorium, folder)
		if not ok then
			warn("[MapBuilder] auditorium failed: " .. tostring(err))
		end
	end
end

--------------------------------------------------------------------------------
-- Perimeter walls (with windows) for every level + roof
--------------------------------------------------------------------------------
local function buildPerimeter()
	local folder = Instance.new("Folder")
	folder.Name = "Perimeter"
	folder.Parent = mapModel
	for level = 0, FLOORS - 1 do
		local y = floorY(level)
		local c = Color3.fromRGB(180, 184, 192)
		-- north & south windowed facades
		windowWall(folder, Vector3.new(-FX - WALL_T, y, FZ + WALL_T), Vector3.new(FX + WALL_T, y, FZ + WALL_T), INNER_H, c, Enum.Material.Concrete, 16)
		windowWall(folder, Vector3.new(-FX - WALL_T, y, -FZ - WALL_T), Vector3.new(FX + WALL_T, y, -FZ - WALL_T), INNER_H, c, Enum.Material.Concrete, 16)
		-- west windowed, east solid (shaft side)
		windowWall(folder, Vector3.new(-FX - WALL_T, y, -FZ - WALL_T), Vector3.new(-FX - WALL_T, y, FZ + WALL_T), INNER_H, c, Enum.Material.Concrete, 10)
		solidWall(folder, Vector3.new(FX + WALL_T, y, -FZ - WALL_T), Vector3.new(FX + WALL_T, y, FZ + WALL_T), INNER_H, c, Enum.Material.Concrete)
	end
end

--------------------------------------------------------------------------------
-- Exterior — recessed ground (no coplanar floor), plaza, trees, skyline, sky
--------------------------------------------------------------------------------
local function buildExterior()
	local folder = Instance.new("Folder")
	folder.Name = "Exterior"
	folder.Parent = mapModel

	-- Ground sits 1 stud BELOW the building's ground floor so its top face is
	-- never coplanar with a room floor (this was the source of the flicker).
	makePart({ name = "Ground", size = Vector3.new(2200, 2, 2200), position = Vector3.new(0, -2, 0), color = Color3.fromRGB(95, 130, 70), material = Enum.Material.Grass, parent = folder })
	-- plaza sits clear to the south of the (now larger) footprint, no overlap
	makePart({ name = "Plaza", size = Vector3.new(300, 1, 120), position = Vector3.new(0, -0.5, -175), color = Color3.fromRGB(150, 150, 155), material = Enum.Material.Concrete, parent = folder })

	if not Lighting:FindFirstChildOfClass("Sky") then
		Instance.new("Sky").Parent = Lighting
	end

	local function tree(pos: Vector3, s: number)
		makePart({ name = "Trunk", size = Vector3.new(2 * s, 14 * s, 2 * s), position = pos + Vector3.new(0, 7 * s, 0), color = Color3.fromRGB(90, 60, 35), material = Enum.Material.Wood, parent = folder })
		makePart({ name = "Leaves", size = Vector3.new(16 * s, 16 * s, 16 * s), position = pos + Vector3.new(0, 16 * s, 0), color = Color3.fromRGB(62, 112, 56), material = Enum.Material.Grass, shape = Enum.PartType.Ball, parent = folder })
	end
	local function building(pos: Vector3, size: Vector3, body: Color3, faceDir: number)
		makePart({ name = "Skyline", size = size, position = pos + Vector3.new(0, size.Y / 2, 0), color = body, material = Enum.Material.Concrete, parent = folder })
		local cols = math.floor(size.Z / 8)
		local rows = math.floor(size.Y / 8)
		for r = 1, rows do
			for col = 1, cols do
				local lit = (r + col) % 3 ~= 0
				makePart({ name = "Win", size = Vector3.new(0.4, 4, 4), position = Vector3.new(pos.X + faceDir * (size.X / 2 + 0.2), pos.Y + r * 8 - 2, pos.Z - size.Z / 2 + col * 8 - 4), color = if lit then Color3.fromRGB(255, 240, 180) else Color3.fromRGB(40, 50, 70), material = if lit then Enum.Material.Neon else Enum.Material.Glass, transparency = if lit then 0 else 0.3, parent = folder })
			end
		end
	end

	-- Windows are on the N, S and W facades, so ring the scenery there (the east
	-- side is the solid stairwell wall).
	-- Trees along the south and north lawns
	for i = 0, 9 do
		tree(Vector3.new(-170 + i * 38, -1, -135), 1.0 + (i % 3) * 0.3)
		tree(Vector3.new(-170 + i * 38, -1, 135), 1.0 + ((i + 1) % 3) * 0.3)
	end
	-- Trees along the west lawn
	for i = 0, 6 do
		tree(Vector3.new(-200, -1, -120 + i * 40), 1.1)
	end
	-- Skyline towers around the windowed sides (south, west, north)
	building(Vector3.new(-120, -1, -300), Vector3.new(90, 200, 60), Color3.fromRGB(120, 130, 150), 1)
	building(Vector3.new(60, -1, -320), Vector3.new(70, 150, 70), Color3.fromRGB(100, 110, 130), 1)
	building(Vector3.new(-320, -1, -40), Vector3.new(60, 230, 90), Color3.fromRGB(130, 140, 160), 1)
	building(Vector3.new(-300, -1, 120), Vector3.new(55, 160, 70), Color3.fromRGB(115, 125, 145), 1)
	building(Vector3.new(-100, -1, 300), Vector3.new(80, 180, 60), Color3.fromRGB(110, 120, 140), -1)
	building(Vector3.new(120, -1, 320), Vector3.new(70, 140, 70), Color3.fromRGB(120, 128, 150), -1)
end

--------------------------------------------------------------------------------
-- Player spawns (ground-floor central corridor, west end)
--------------------------------------------------------------------------------
local function buildSpawns()
	local folder = Instance.new("Folder")
	folder.Name = "Spawns"
	folder.Parent = mapModel
	-- entrance lobby sign on the west wall
	for i = 1, 4 do
		local s = Instance.new("SpawnLocation")
		s.Name = "Spawn_" .. i
		s.Size = Vector3.new(4, 1, 4)
		-- shifted east of the elevator doorway (x = -148) so nobody spawns in a shaft
		s.Position = Vector3.new(-140 + (i - 1) * 5, 0.5, 0)
		s.Anchored = true
		s.Neutral = true
		s.Duration = 0
		s.Material = Enum.Material.SmoothPlastic
		s.Color = Color3.fromRGB(60, 120, 200)
		s.Transparency = 0.4
		s.TopSurface = Enum.SurfaceType.Smooth
		s.Parent = folder
	end

	-- Named NPC spawn markers spaced along the open ground-floor corridor so the
	-- talkable NPCs land somewhere reachable (NPCManager matches marker Name to
	-- the NPC id; these replace the old hard-coded spawnPositions).
	-- Spread the named NPCs across all three floors so the player has to explore
	-- (and use the stairs / elevators) to meet everyone, rather than finding the
	-- whole cast bunched together on the ground floor. {id, x, floorLevel}
	local npcSpots = {
		{ "npc_organizer_sarah", -110, 0 },
		{ "npc_volunteer_max", 40, 0 },
		{ "npc_mentor_dev", -80, 1 },
		{ "npc_hacker_alex", 0, 1 },
		{ "npc_judge_priya", 80, 1 },
		{ "npc_sponsor_jordan", -80, 2 },
		{ "npc_rival_sam", 0, 2 },
		{ "npc_security_ron", 80, 2 },
	}
	for _, spot in npcSpots do
		local lvl = spot[3] :: number
		marker(spot[1] :: string, Vector3.new(spot[2] :: number, floorY(lvl) + 0.5, 0), folder, TAGS.NPC_SPAWN)
	end
end

--------------------------------------------------------------------------------
-- BUILD ALL
--------------------------------------------------------------------------------
local function buildAll()
	print("[MapBuilder] Building 3-floor hackathon venue...")
	local t0 = os.clock()

	for _, name in { "Baseplate", "SpawnLocation" } do
		local existing = workspace:FindFirstChild(name)
		if existing then
			existing:Destroy()
		end
	end

	-- HAND-EDIT THE WHOLE VENUE: if you save a finished map model as
	-- assets/Venue.rbxmx (Rojo syncs it to ReplicatedStorage.Assets.Venue), it is
	-- used verbatim and procedural generation is skipped. Workflow: let it
	-- generate once, copy Workspace.Map into Workspace, edit it by hand, then
	-- right-click -> "Save to File" into assets/Venue.rbxmx.
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local prebuilt = assets and assets:FindFirstChild("Venue")
	if prebuilt and prebuilt:IsA("Model") then
		local copy = prebuilt:Clone()
		copy.Name = "Map"
		copy.Parent = workspace
		print(string.format("[MapBuilder] Loaded hand-built Venue in %.2fs", os.clock() - t0))
		return
	end

	-- Every major step is isolated: a failure in one (e.g. a content builder)
	-- can never prevent the structural walls/slabs/stairs of other floors from
	-- being built. This is what guarantees every floor stays fully walled.
	local function step(name: string, fn: () -> ())
		local ok, err = pcall(fn)
		if not ok then
			warn(string.format("[MapBuilder] step '%s' failed: %s", name, tostring(err)))
		end
	end

	step("exterior", buildExterior)
	-- slabs: ground solid; upper floors holed for the stairwell + elevator shaft;
	-- roof solid.
	local stairHole: Hole = { xMin = SHAFT.xMin, xMax = FX + WALL_T, zMin = SHAFT.zMin, zMax = SHAFT.zMax }
	local elevHole: Hole = { xMin = -(FX + WALL_T), xMax = ELEV.xMax, zMin = ELEV.zMin, zMax = ELEV.zMax }
	local slabColors = { COLORS.FLOOR_WOOD, Color3.fromRGB(120, 124, 132), Color3.fromRGB(118, 122, 130), Color3.fromRGB(70, 72, 80) }
	step("slab0", function()
		buildSlab(0, {}, slabColors[1])
	end)
	step("slab1", function()
		buildSlab(1, { stairHole, elevHole }, slabColors[2])
	end)
	step("slab2", function()
		buildSlab(2, { stairHole, elevHole }, slabColors[3])
	end)
	step("roof", function()
		buildSlab(FLOORS, {}, slabColors[4])
	end)
	step("perimeter", buildPerimeter)
	for level = 0, FLOORS - 1 do
		step("floor" .. level, function()
			buildFloor(level)
		end)
	end
	step("stairwell", buildStairwell)
	step("elevators", buildElevators)
	step("spawns", buildSpawns)

	mapModel.Parent = workspace

	local n = 0
	for _, d in mapModel:GetDescendants() do
		if d:IsA("BasePart") then
			n += 1
		end
	end
	print(string.format("[MapBuilder] Venue built in %.2fs — %d parts", os.clock() - t0, n))
	for _, tagName in TAGS do
		local c = #CollectionService:GetTagged(tagName)
		if c > 0 then
			print(string.format("  [Tag] %s: %d", tagName, c))
		end
	end
end

buildAll()
