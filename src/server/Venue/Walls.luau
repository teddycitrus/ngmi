--!strict
--------------------------------------------------------------------------------
-- Walls.luau
-- Interior partitions. A wall run is the structural wall plus its trim
-- (rubber baseboard, two-tone wainscot, wood chair rail), openings with metal
-- casings, and door leaves standing open flat against the wall.
--
-- Geometry rules (same as the rest of the venue): trim is always a little
-- thicker than the wall it dresses, so no two faces share a plane, and each
-- trim band covers a different height range, so their end faces never overlap.
-- Structural pieces are named "Wall": InteractionManager treats those as
-- line-of-sight blockers.
--------------------------------------------------------------------------------

local Kit = require(script.Parent.Kit)
local Layout = require(script.Parent.Layout)

local WALL_T = Layout.WALL_T

local Walls = {}

-- How far each trim band stands proud of the wall face.
local BASE_OUT, WAIN_OUT, RAIL_OUT, CASE_OUT = 0.1, 0.06, 0.13, 0.2
local BASE_H = 0.5
local WAIN_TOP = 3.6
local RAIL_H = 0.25
local CASE_W = 0.45
local OVERLAP = 0.05 -- how far a covering piece reaches past the edge it covers

local BASEBOARD = Color3.fromRGB(46, 47, 52)
local RAIL = Color3.fromRGB(122, 90, 62)
local CASING = Color3.fromRGB(70, 72, 78)
local LEAF = Color3.fromRGB(150, 108, 70)
local FIRE_LEAF = Color3.fromRGB(140, 42, 38)
local STEEL = Color3.fromRGB(168, 172, 178)
local GLASS = Color3.fromRGB(190, 210, 225)

Walls.SILL = WAIN_TOP + RAIL_H -- default window sill sits on the chair rail
Walls.FACE = WALL_T / 2 + RAIL_OUT + 0.02 -- clear of every trim band

export type Gap = {
	at: number?, -- gap centre, measured from the middle of the run
	width: number,
	height: number?,
	kind: string?, -- "door" (default), "double", "fire", "open", "window"
	sill: number?, -- windows only
}

export type Style = {
	color: Color3,
	accent: Color3?, -- wainscot colour; nil skips wainscot and chair rail
	material: Enum.Material?,
	trim: boolean?, -- false = bare wall
}

--- One rectangular piece lying in the wall plane, from distance d0 to d1 along
--- `dir` and y0 to y1 in height.
local function piece(
	parent: Instance,
	origin: Vector3,
	dir: Vector3,
	d0: number,
	d1: number,
	y0: number,
	y1: number,
	thick: number,
	color: Color3,
	material: Enum.Material,
	name: string,
	collide: boolean?
): Part?
	if d1 - d0 <= 0.05 or y1 - y0 <= 0.05 then
		return nil
	end
	local mid = (d0 + d1) / 2
	local c = Vector3.new(origin.X + dir.X * mid, (y0 + y1) / 2, origin.Z + dir.Z * mid)
	return Kit.part(
		parent,
		name,
		Vector3.new(thick, y1 - y0, d1 - d0),
		CFrame.lookAt(c, c + dir),
		color,
		material,
		{ collide = if collide ~= nil then collide else true }
	)
end
Walls.piece = piece

type Span = { s: number, e: number, g: Gap }

--- An open door leaf resting flat against the wall beside its opening.
local function leaf(
	parent: Instance,
	origin: Vector3,
	dir: Vector3,
	inward: Vector3,
	d0: number,
	d1: number,
	y: number,
	h: number,
	fire: boolean
)
	local w = d1 - d0
	local mid = (d0 + d1) / 2
	local base = Vector3.new(origin.X + dir.X * mid, y, origin.Z + dir.Z * mid)
	local off = WALL_T / 2 + RAIL_OUT + 0.14
	local function at(along: number, up: number, out: number): CFrame
		local p = base + dir * along + inward * (off + out) + Vector3.new(0, up, 0)
		return CFrame.lookAt(p, p + dir)
	end
	local col = if fire then FIRE_LEAF else LEAF
	local mat = if fire then Enum.Material.Metal else Enum.Material.Wood
	Kit.trim(parent, "DoorLeaf", Vector3.new(0.16, h, w), at(0, h / 2, 0), col, mat)
	Kit.trim(parent, "KickPlate", Vector3.new(0.2, 0.8, w - 0.3), at(0, 0.5, 0), STEEL, Enum.Material.Metal)
	Kit.trim(
		parent,
		"VisionPanel",
		Vector3.new(0.2, 2.6, 0.55),
		at(-w * 0.18, h * 0.66, 0),
		GLASS,
		Enum.Material.Glass,
		{ transparency = 0.45 }
	)
	if fire then
		Kit.trim(parent, "PushBar", Vector3.new(0.22, 0.22, w * 0.72), at(0, 3.4, 0.2), STEEL, Enum.Material.Metal)
	else
		Kit.trim(parent, "Lever", Vector3.new(0.4, 0.14, 0.62), at(-w / 2 + 0.55, 3.4, 0.18), STEEL, Enum.Material.Metal)
	end
end

--- A straight wall from a to b (a.Y is the floor), `height` tall, with
--- openings. `inward` is the side door leaves fold toward. `inset` pulls the
--- trim back from both ends so it clears the trim of a perpendicular wall; a
--- negative inset runs it past the ends to wrap an outside corner.
function Walls.run(
	parent: Instance,
	a: Vector3,
	b: Vector3,
	height: number,
	style: Style,
	gaps: { Gap }?,
	inward: Vector3?,
	inset: number?
)
	local flat = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	local len = flat.Magnitude
	if len < 0.1 then
		return
	end
	local dir = flat.Unit
	local y = a.Y
	local mat = style.material or Enum.Material.Plaster

	local spans: { Span } = {}
	for _, g in gaps or {} do
		local mid = len / 2 + (g.at or 0)
		local s, e = mid - g.width / 2, mid + g.width / 2
		if s > CASE_W + 0.2 and e < len - CASE_W - 0.2 then
			table.insert(spans, { s = s, e = e, g = g })
		end
	end
	table.sort(spans, function(p, q)
		return p.s < q.s
	end)

	-- Structure, with headers and window panes.
	local cursor = 0
	for _, sp in spans do
		local g = sp.g
		local top = y + (g.height or 9)
		piece(parent, a, dir, cursor, sp.s, y, y + height, WALL_T, style.color, mat, "Wall")
		piece(parent, a, dir, sp.s, sp.e, top, y + height, WALL_T, style.color, mat, "Wall")
		if g.kind == "window" then
			local sill = y + (g.sill or Walls.SILL)
			piece(parent, a, dir, sp.s, sp.e, y, sill, WALL_T, style.color, mat, "Wall")
			local pane = piece(parent, a, dir, sp.s, sp.e, sill, top, 0.2, GLASS, Enum.Material.Glass, "Window")
			if pane then
				pane.Transparency = 0.62
				pane.Reflectance = 0.06
			end
			local n = math.max(1, math.floor((sp.e - sp.s) / 4.5))
			for i = 1, n - 1 do
				local d = sp.s + i * (sp.e - sp.s) / n
				piece(parent, a, dir, d - 0.12, d + 0.12, sill, top, 0.5, CASING, Enum.Material.Metal, "Mullion", false)
			end
		end
		cursor = sp.e
	end
	piece(parent, a, dir, cursor, len, y, y + height, WALL_T, style.color, mat, "Wall")

	if style.trim == false then
		return
	end

	-- Trim bands, broken only at doorways (they run on under windows).
	local i0 = inset or 0
	local ranges: { { number } } = {}
	local from = i0
	for _, sp in spans do
		if sp.g.kind ~= "window" then
			table.insert(ranges, { from, sp.s })
			from = sp.e
		end
	end
	table.insert(ranges, { from, len - i0 })
	for _, r in ranges do
		piece(parent, a, dir, r[1], r[2], y, y + BASE_H, WALL_T + BASE_OUT * 2, BASEBOARD, Enum.Material.Rubber, "Trim", false)
		if style.accent then
			piece(parent, a, dir, r[1], r[2], y + BASE_H, y + WAIN_TOP, WALL_T + WAIN_OUT * 2, style.accent, Enum.Material.Plaster, "Trim", false)
			piece(
				parent,
				a,
				dir,
				r[1],
				r[2],
				y + WAIN_TOP,
				y + WAIN_TOP + RAIL_H,
				WALL_T + RAIL_OUT * 2,
				RAIL,
				Enum.Material.Wood,
				"Trim",
				false
			)
		end
	end

	-- Casings and leaves.
	local ct = WALL_T + CASE_OUT * 2
	for _, sp in spans do
		local g = sp.g
		local top = y + (g.height or 9)
		local bottom = y
		if g.kind == "window" then
			local sill = y + (g.sill or Walls.SILL)
			bottom = sill + 0.05
			piece(parent, a, dir, sp.s - CASE_W, sp.e + CASE_W, sill - 0.3, bottom, ct, CASING, Enum.Material.Metal, "Casing", false)
		end
		-- Every casing face sits a hair off the wall faces it covers. Ending a
		-- jamb exactly where the wall ends, or running the head's underside flush
		-- with the lintel, puts two faces in one plane and they z-fight.
		piece(parent, a, dir, sp.s - CASE_W, sp.s + OVERLAP, bottom, top, ct, CASING, Enum.Material.Metal, "Casing", false)
		piece(parent, a, dir, sp.e - OVERLAP, sp.e + CASE_W, bottom, top, ct, CASING, Enum.Material.Metal, "Casing", false)
		piece(
			parent,
			a,
			dir,
			sp.s - CASE_W - OVERLAP,
			sp.e + CASE_W + OVERLAP,
			top - OVERLAP,
			top + CASE_W,
			ct + OVERLAP,
			CASING,
			Enum.Material.Metal,
			"Casing",
			false
		)

		local kind = g.kind or "door"
		if inward and (kind == "door" or kind == "double" or kind == "fire") then
			local h = (g.height or 9) - 0.15
			local w = sp.e - sp.s
			local gapClear = CASE_W + 0.15
			local lim = math.max(i0, 0)
			if kind == "double" then
				local lw = w / 2
				if sp.s - gapClear - lw > lim + 0.2 and sp.e + gapClear + lw < len - lim - 0.2 then
					leaf(parent, a, dir, inward, sp.s - gapClear - lw, sp.s - gapClear, y, h, false)
					leaf(parent, a, dir, inward, sp.e + gapClear, sp.e + gapClear + lw, y, h, false)
				end
			elseif sp.s - gapClear - w > lim + 0.2 then
				leaf(parent, a, dir, inward, sp.s - gapClear - w, sp.s - gapClear, y, h, kind == "fire")
			elseif sp.e + gapClear + w < len - lim - 0.2 then
				leaf(parent, a, dir, inward, sp.e + gapClear, sp.e + gapClear + w, y, h, kind == "fire")
			end
		end
	end
end

export type RoomGaps = { south: { Gap }?, north: { Gap }?, east: { Gap }?, west: { Gap }? }

--- The four walls of a rectangular room. South and north span the full width
--- to cover the corners; east and west sit between them.
function Walls.room(
	parent: Instance,
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
	y: number,
	style: Style,
	gaps: RoomGaps,
	height: number?
)
	local h = height or Layout.INNER_H
	local x0, x1 = minX - WALL_T / 2, maxX + WALL_T / 2
	local z0, z1 = minZ + WALL_T / 2, maxZ - WALL_T / 2
	-- South/north trim wraps a little past the outside corners. Ending it flush
	-- with the side walls' outer faces put its end faces in the same plane as
	-- those walls, and the corner flickered. East/west trim starts clear of
	-- the south/north trim's thickness, so no two trim faces meet in a plane.
	local wrap = -(RAIL_OUT + 0.01)
	local inset = RAIL_OUT + 0.05
	Walls.run(parent, Vector3.new(x0, y, minZ), Vector3.new(x1, y, minZ), h, style, gaps.south, Vector3.zAxis, wrap)
	Walls.run(parent, Vector3.new(x0, y, maxZ), Vector3.new(x1, y, maxZ), h, style, gaps.north, -Vector3.zAxis, wrap)
	Walls.run(parent, Vector3.new(minX, y, z0), Vector3.new(minX, y, z1), h, style, gaps.west, Vector3.xAxis, inset)
	Walls.run(parent, Vector3.new(maxX, y, z0), Vector3.new(maxX, y, z1), h, style, gaps.east, -Vector3.xAxis, inset)
end

return Walls
