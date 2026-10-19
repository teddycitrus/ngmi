--!strict
--------------------------------------------------------------------------------
-- Shell.luau
-- The building envelope: floor slabs, suspended ceilings, facades, the front
-- entrance and the roof.
--
-- One slab per level. Its top is that floor; its underside is hidden by the
-- suspended ceiling of the level below, which hangs 1.5 studs lower and is
-- pierced by every wall (walls run on up to the slab), so no two faces ever
-- share a plane.
--------------------------------------------------------------------------------

local Kit = require(script.Parent.Kit)
local Layout = require(script.Parent.Layout)
local Walls = require(script.Parent.Walls)

local V = Vector3.new
local CF = CFrame.new
local M = Enum.Material
local WALL_T = Layout.WALL_T
local FX, FZ = Layout.FX, Layout.FZ

local Shell = {}

local X0, X1 = -(FX + WALL_T), FX + WALL_T
local Z0, Z1 = -(FZ + WALL_T), FZ + WALL_T

export type Hole = Layout.Rect

--- Split the footprint into rectangles that avoid every hole, and call `emit`
--- for each. Cuts into vertical strips at the hole edges; inside a strip the
--- holes that span it partition Z.
local function tile(holes: { Hole }, emit: (number, number, number, number) -> ())
	local xs = { X0, X1 }
	for _, h in holes do
		table.insert(xs, math.clamp(h.xMin, X0, X1))
		table.insert(xs, math.clamp(h.xMax, X0, X1))
	end
	table.sort(xs)
	for i = 1, #xs - 1 do
		local xa, xb = xs[i], xs[i + 1]
		if xb - xa >= 0.05 then
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
				if s[1] - zc >= 0.05 then
					emit(xa, xb, zc, s[1])
				end
				zc = math.max(zc, s[2])
			end
			if Z1 - zc >= 0.05 then
				emit(xa, xb, zc, Z1)
			end
		end
	end
end

--- Floor slab for one level. SurfaceWeathering looks these up by name
--- ("Slab" inside "Slab_<level>").
function Shell.slab(root: Instance, level: number, holes: { Hole }, color: Color3, role: string)
	local topY = Layout.floorY(level)
	local folder = Instance.new("Folder")
	folder.Name = "Slab_" .. level
	folder.Parent = root
	tile(holes, function(xa, xb, za, zb)
		local s = Kit.part(folder, "Slab", V(xb - xa, Layout.SLAB_T, zb - za), V((xa + xb) / 2, topY - Layout.SLAB_T / 2, (za + zb) / 2), color, M.Concrete)
		Kit.surface(s, role)
	end)
end

--- Suspended acoustic ceiling with its T-bar grid, for one level.
function Shell.ceiling(root: Instance, level: number, holes: { Hole })
	local folder = Instance.new("Folder")
	folder.Name = "Ceiling_" .. level
	folder.Parent = root
	local y = Layout.floorY(level) + Layout.CEIL_H
	local tileCol = Color3.fromRGB(226, 226, 220)
	local grid = Color3.fromRGB(200, 200, 196)
	tile(holes, function(xa, xb, za, zb)
		Kit.part(folder, "CeilingTile", V(xb - xa, 0.3, zb - za), V((xa + xb) / 2, y + 0.15, (za + zb) / 2), tileCol, M.Plaster, { collide = false, shadow = false })
	end)

	-- Grid lines every 4 studs, broken around the holes.
	local function inHole(x: number, z: number): boolean
		for _, h in holes do
			if x > h.xMin and x < h.xMax and z > h.zMin and z < h.zMax then
				return true
			end
		end
		return false
	end
	local STEP = 0.5
	local function line(a: Vector3, b: Vector3, along: Vector3)
		-- walk the line in short steps, emitting runs that stay outside holes
		local len = (b - a).Magnitude
		local runStart: number? = nil
		local function close(e: number)
			if runStart and e - runStart > 0.2 then
				local mid = a + along * ((runStart + e) / 2)
				Kit.trim(folder, "TBar", V(0.12, 0.08, e - runStart), CFrame.lookAt(mid, mid + along), grid, M.Metal, { shadow = false })
			end
			runStart = nil
		end
		local d = 0
		while d < len do
			local p = a + along * (d + STEP / 2)
			if inHole(p.X, p.Z) then
				close(d)
			elseif not runStart then
				runStart = d
			end
			d += STEP
		end
		close(len)
	end
	for x = X0 + 4, X1 - 4, 4 do
		line(V(x, y - 0.04, Z0), V(x, y - 0.04, Z1), V(0, 0, 1))
	end
	for z = Z0 + 4, Z1 - 4, 4 do
		-- a hair lower than the Z-running bars, so crossings don't share a face
		line(V(X0, y - 0.05, z), V(X1, y - 0.05, z), V(1, 0, 0))
	end
end

--- A recessed 2x4 troffer. Tagged CEILING_LIGHT for the blackout systems;
--- `lit` = false makes a fixture that glows but throws no light (cheap fill).
function Shell.troffer(
	parent: Instance,
	pos: Vector3,
	alongX: boolean,
	lit: boolean,
	brightness: number?,
	range: number?,
	shadows: boolean?
): Part
	local size = if alongX then V(4.2, 0.12, 2.2) else V(2.2, 0.12, 4.2)
	Kit.trim(parent, "Troffer", size, pos + V(0, 0.02, 0), Color3.fromRGB(236, 236, 232), M.Metal, { shadow = false })
	local lens = Kit.trim(parent, "CeilingLight", if alongX then V(3.8, 0.1, 1.8) else V(1.8, 0.1, 3.8), pos - V(0, 0.065, 0), Color3.fromRGB(255, 250, 238), M.Neon, { shadow = false })
	if lit then
		local l = Kit.light(lens, brightness or 0.55, range or 22)
		l.Shadows = shadows == true
	end
	Kit.tag(lens, Kit.TAGS.CEILING_LIGHT)
	return lens
end

--------------------------------------------------------------------------------
-- Facades
--------------------------------------------------------------------------------
local STONE = Color3.fromRGB(184, 178, 166)
local STONE_DARK = Color3.fromRGB(122, 116, 108)
local PLINTH = Color3.fromRGB(88, 86, 84)
local MULLION = Color3.fromRGB(56, 60, 66)
local GLASS = Color3.fromRGB(150, 176, 196)

local SILL_B, SILL_T = 4.5, 11.5

type Face = { a: Vector3, b: Vector3, out: Vector3, bays: number, doorBay: number? }

--- One storey of one facade: solid base and header, punched windows between
--- piers, exterior fins at every pier, sills, and a stone band at the floor
--- line. `doorBay` swaps that bay's base and glass for a full-height
--- storefront with doors.
local function facade(parent: Instance, f: Face, y: number)
	local flat = f.b - f.a
	local len = flat.Magnitude
	local dir = flat.Unit
	local a = V(f.a.X, y, f.a.Z)
	local h = Layout.INNER_H
	local span = len / f.bays
	local pier = 3.5
	local out = f.out
	local function at(d: number, up: number, off: number): CFrame
		local p = a + dir * d + out * off + V(0, up, 0)
		return CFrame.lookAt(p, p + dir)
	end
	local function wall(d0: number, d1: number, y0: number, y1: number)
		local seg = Walls.piece(parent, a, dir, d0, d1, y + y0, y + y1, WALL_T, STONE, M.Concrete, "Wall")
		if seg then
			Kit.surface(seg, "WALL_CONCRETE_BRICK")
			seg.Color = STONE
		end
	end

	wall(0, len, SILL_T, h + Layout.SLAB_T)
	for i = 1, f.bays do
		local g0, g1 = (i - 1) * span + pier / 2, i * span - pier / 2
		local isDoor = f.doorBay == i
		if not isDoor then
			wall(g0, g1, 0, SILL_B)
		end
		local bottom = if isDoor then 0 else SILL_B
		-- glass, split by a transom and two mullions
		local pane = Walls.piece(parent, a, dir, g0, g1, y + bottom, y + SILL_T, 0.3, GLASS, M.Glass, "Window")
		if pane then
			pane.Transparency = 0.55
			pane.Reflectance = 0.12
		end
		local w = g1 - g0
		if isDoor then
			-- frame the door pair; the doors themselves come from entrance()
			for _, k in { -1, 1 } do
				Kit.trim(parent, "Mullion", V(0.6, SILL_T, 0.4), at((Layout.ENTRY_X - a.X) + k * 4.4, SILL_T / 2, 0), MULLION, M.Metal)
			end
			Kit.trim(parent, "Transom", V(0.66, 0.4, w), at((g0 + g1) / 2, 9.6, 0), MULLION, M.Metal)
		else
			for k = 1, 2 do
				local d = g0 + w * k / 3
				Kit.trim(parent, "Mullion", V(0.6, SILL_T - bottom, 0.3), at(d, (bottom + SILL_T) / 2, 0), MULLION, M.Metal)
			end
			Kit.trim(parent, "Transom", V(0.66, 0.3, w), at((g0 + g1) / 2, SILL_T - 2.4, 0), MULLION, M.Metal)
		end
		if not isDoor then
			Kit.trim(parent, "Sill", V(1.4, 0.35, w + 0.4), at((g0 + g1) / 2, SILL_B - 0.17, WALL_T / 2 + 0.2), STONE_DARK, M.Concrete)
			Kit.trim(parent, "Stool", V(0.8, 0.2, w), at((g0 + g1) / 2, SILL_B + 0.1, -(WALL_T / 2 + 0.3)), Color3.fromRGB(226, 222, 212), M.SmoothPlastic)
		end
	end
	for i = 0, f.bays do
		local d = i * span
		local d0, d1 = math.max(0, d - pier / 2), math.min(len, d + pier / 2)
		wall(d0, d1, 0, SILL_T)
		-- exterior fin, deeper at the corners
		local depth = if i == 0 or i == f.bays then 2.4 else 1.3
		Kit.part(parent, "Fin", V(depth, h + Layout.SLAB_T, d1 - d0 + 0.4), at((d0 + d1) / 2, (h + Layout.SLAB_T) / 2, WALL_T / 2 + depth / 2), STONE_DARK, M.Concrete)
	end
	-- floor-line band; the ground floor gets a dark granite plinth instead
	if y == 0 then
		local runs = { { 0, len } }
		if f.doorBay then
			local g0, g1 = (f.doorBay - 1) * span + pier / 2, f.doorBay * span - pier / 2
			runs = { { 0, g0 }, { g1, len } }
		end
		for _, r in runs do
			Kit.part(parent, "Plinth", V(1.0, 2.6, r[2] - r[1]), at((r[1] + r[2]) / 2, 0.3, WALL_T / 2 + 0.5), PLINTH, M.Granite)
		end
	else
		Kit.trim(parent, "Band", V(0.9, 1.6, len), at(len / 2, -0.4, WALL_T / 2 + 0.45), STONE_DARK, M.Concrete)
	end
end

local function faces(): { Face }
	-- The front door bay: the bay whose centre is nearest the entrance X.
	local southBays = 16
	local span = (X1 - X0) / southBays
	local doorBay = math.floor((Layout.ENTRY_X - X0) / span) + 1
	return {
		{ a = V(X0, 0, Z1), b = V(X1, 0, Z1), out = V(0, 0, 1), bays = 16 },
		{ a = V(X0, 0, Z0), b = V(X1, 0, Z0), out = V(0, 0, -1), bays = southBays, doorBay = doorBay },
		{ a = V(X0, 0, Z0), b = V(X0, 0, Z1), out = V(-1, 0, 0), bays = 10 },
	}
end

--- The entrance storefront: two pairs of locked glass doors, a canopy and the
--- building's name above.
local function entrance(parent: Instance)
	local x = Layout.ENTRY_X
	local z = Z0
	local glassC = Color3.fromRGB(170, 196, 214)
	local frame = Color3.fromRGB(46, 48, 54)
	for _, dx in { -2.1, 2.1 } do
		local cf = CF(x + dx, 4.6, z - 0.3)
		Kit.part(parent, "EntryDoor", V(4, 9.2, 0.2), cf, glassC, M.Glass, { transparency = 0.5, reflectance = 0.12 })
		Kit.trim(parent, "DoorFrame", V(4.2, 0.4, 0.3), cf * CF(0, 4.6, 0), frame, M.Metal)
		Kit.trim(parent, "DoorFrame", V(4.2, 0.6, 0.3), cf * CF(0, -4.4, 0), frame, M.Metal)
		Kit.trim(parent, "PushBar", V(3, 0.2, 0.3), cf * CF(0, -0.9, -0.25), Color3.fromRGB(190, 194, 200), M.Metal)
	end
	Kit.trim(parent, "DoorJamb", V(0.4, 9.6, 0.4), CF(x, 4.8, z - 0.3), frame, M.Metal)
	local chain = Kit.trim(parent, "Chain", V(1.6, 1.4, 0.2), CF(x, 4.1, z - 0.55) * CFrame.Angles(0, 0, math.rad(8)), Color3.fromRGB(120, 116, 110), M.DiamondPlate)
	chain.Name = "Padlock"
	-- canopy on two posts
	local cz = z - 7
	Kit.part(parent, "Canopy", V(22, 0.8, 13), CF(x, 12.6, cz + 0.5), Color3.fromRGB(64, 66, 72), M.Metal)
	Kit.trim(parent, "CanopyFascia", V(22.2, 1.4, 0.4), CF(x, 12.6, cz - 6), Color3.fromRGB(110, 28, 40), M.Metal)
	for _, sx in { -1, 1 } do
		Kit.part(parent, "CanopyPost", V(0.9, 12.2, 0.9), CF(x + sx * 10, 6.1, cz - 5.2), Color3.fromRGB(64, 66, 72), M.Metal)
		local lamp = Kit.trim(parent, "CanopyLight", V(1.2, 0.12, 1.2), CF(x + sx * 5, 12.15, cz), Color3.fromRGB(255, 236, 200), M.Neon)
		Kit.light(lamp, 0.8, 18, Color3.fromRGB(255, 220, 170))
	end
	local fascia = Kit.trim(parent, "EntrySign", V(20, 1.1, 0.1), CF(x, 12.6, cz - 6.25), Color3.fromRGB(110, 28, 40), M.SmoothPlastic)
	Kit.label(fascia, Enum.NormalId.Front, "HALBERD ENGINEERING HALL", Color3.fromRGB(236, 214, 150), nil, Enum.Font.Garamond)
	-- walkway from the plaza
	Kit.part(parent, "Walkway", V(16, 1, 12.4), CF(x, -0.5, -108.7), Color3.fromRGB(150, 146, 140), M.Pavement)
end

--- Big lettering across the auditorium bay, where the opening crane shot
--- looks, plus the university crest.
local function nameplate(parent: Instance)
	local cx = (Layout.AUD.minX + Layout.AUD.maxX) / 2
	local z = Z0 - WALL_T / 2 - 2.8
	local board = Kit.trim(parent, "BuildingName", V(70, 4.5, 0.2), CF(cx, 34, z), Color3.new(), M.SmoothPlastic, { transparency = 1 })
	local label = Kit.label(board, Enum.NormalId.Front, "HALBERD  ENGINEERING  HALL", Color3.fromRGB(232, 222, 196), nil, Enum.Font.Garamond)
	label.TextStrokeTransparency = 0.6
	local crest = Kit.cylZ(parent, "Crest", 0.3, 6, CF(cx, 34, z + 0.2) * CF(-41, 0, 0), Color3.fromRGB(110, 28, 40), M.SmoothPlastic, { collide = false })
	Kit.label(crest, Enum.NormalId.Right, "SV", Color3.fromRGB(212, 175, 60), nil, Enum.Font.Garamond)
end

function Shell.facades(root: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Perimeter"
	folder.Parent = root
	for level = 0, Layout.FLOORS - 1 do
		local y = Layout.floorY(level)
		for _, f in faces() do
			local face = table.clone(f)
			if level ~= 0 then
				face.doorBay = nil
			end
			facade(folder, face, y)
		end
		-- east side backs the stairwell: solid, banded
		local east = Walls.piece(folder, V(X1, y, Z0), V(0, 0, 1), 0, Z1 - Z0, y, y + Layout.INNER_H + Layout.SLAB_T, WALL_T, STONE, M.Concrete, "Wall")
		if east then
			Kit.surface(east, "WALL_CONCRETE_BRICK")
			east.Color = STONE
		end
		Kit.trim(folder, "Band", V(0.9, 1.6, Z1 - Z0), CF(X1 + WALL_T / 2 + 0.45, y - 0.4, 0), STONE_DARK, M.Concrete)
	end
	entrance(folder)
	nameplate(folder)

	-- parapet and coping round the roof
	local roofY = Layout.floorY(Layout.FLOORS)
	for _, r in {
		{ V(0, 0, Z1), V(X1 - X0 + 2, 0, 2) },
		{ V(0, 0, Z0), V(X1 - X0 + 2, 0, 2) },
		{ V(X0, 0, 0), V(2, 0, Z1 - Z0 - 2) },
		{ V(X1, 0, 0), V(2, 0, Z1 - Z0 - 2) },
	} do
		local pos, size = r[1], r[2]
		Kit.part(folder, "Parapet", V(size.X, 3.4, size.Z), V(pos.X, roofY + 1.7, pos.Z), STONE, M.Concrete)
		Kit.trim(folder, "Coping", V(size.X + 0.6, 0.3, size.Z + 0.6), V(pos.X, roofY + 3.55 + (if size.X > size.Z then 0 else 0.02), pos.Z), STONE_DARK, M.Concrete)
	end
	-- rooftop plant
	for _, u in { { -90, 30, 14, 8 }, { 20, -40, 10, 10 }, { 100, 45, 16, 7 } } do
		local p = V(u[1], roofY + u[4] / 2, u[2])
		Kit.part(folder, "RoofUnit", V(u[3], u[4], u[3] * 0.7), p, Color3.fromRGB(150, 154, 158), M.Metal)
		Kit.cylY(folder, "Fan", 0.4, u[3] * 0.4, p + V(0, u[4] / 2 + 0.2, 0), Color3.fromRGB(80, 84, 90), M.Metal, { collide = false })
	end
end

return Shell
