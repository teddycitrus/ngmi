--!strict
--------------------------------------------------------------------------------
-- Layout.luau
-- Every dimension of the venue in one place, plus the room grid.
--
-- Top-down, +X east, +Z north. Three storeys of the same plan:
--
--   Z=+100 ┌──────────────── perimeter ring hall ────────────────┐
--          │ [R][R] [R][R] [R][R] ...  6 columns x 2 rows         │
--   Z=+9   ├─elev─┬────────── central corridor ──────────┬─stair─┤
--   Z=-9   │ [R][R] [R][R] [R][R] ...                     │       │
--   Z=-100 └──────────────── perimeter ring hall ─── front door ──┘
--
-- 8-stud cross halls run between the room columns. Level 0 swaps the
-- south-west block for the auditorium; a few cells merge into big halls.
--
-- Other scripts hard-code some of these (OpeningSequence's AUD, the NPC spawn
-- coordinates along Z=0), so the outer footprint, the corridor and the
-- auditorium must not move.
--------------------------------------------------------------------------------

local Layout = {}

Layout.WALL_T = 1.5
Layout.LEVEL_H = 18 -- floor to floor
Layout.INNER_H = 16 -- floor to slab underside
Layout.SLAB_T = 2
Layout.CEIL_H = 14.5 -- underside of the suspended ceiling
Layout.FLOORS = 3

Layout.FX = 160 -- interior half-width
Layout.FZ = 100 -- interior half-depth

Layout.CORR_HALF = 9
Layout.HALL = 8
Layout.NCOLS = 6
Layout.NROWS = 2

export type Rect = { xMin: number, xMax: number, zMin: number, zMax: number }

Layout.SHAFT = { xMin = 130, xMax = 160, zMin = -10, zMax = 10 } :: Rect
Layout.ELEV = { xMin = -161.5, xMax = -148, zMin = -9.5, zMax = 9.5 } :: Rect
-- Ground-floor lecture hall. OpeningSequence has its own copy of this.
Layout.AUD = { minX = -152, maxX = 48, minZ = -92, maxZ = -17 }
-- Main entrance: glass doors in the south facade at the foot of the cross
-- hall that runs between the auditorium and the next room column.
Layout.ENTRY_X = 52

-- Per-floor accent for the wainscot, stair stripe and signage, so a player
-- can tell which floor they are on at a glance.
Layout.ACCENT = {
	Color3.fromRGB(62, 128, 134),
	Color3.fromRGB(150, 70, 74),
	Color3.fromRGB(76, 96, 156),
}
Layout.WALL = {
	Color3.fromRGB(228, 224, 214),
	Color3.fromRGB(222, 221, 214),
	Color3.fromRGB(220, 222, 224),
}

function Layout.floorY(level: number): number
	return level * Layout.LEVEL_H
end

--- Tile [a0, a1] into `n` spans with a `gap` hall between each and at both
--- ends. Returns { {lo, hi} }.
function Layout.tileAxis(a0: number, a1: number, n: number, gap: number): { { number } }
	local size = ((a1 - a0) - (n + 1) * gap) / n
	local spans = {}
	for i = 0, n - 1 do
		local lo = a0 + gap + i * (size + gap)
		spans[i + 1] = { lo, lo + size }
	end
	return spans
end

function Layout.columns(): { { number } }
	return Layout.tileAxis(-Layout.FX, Layout.FX, Layout.NCOLS, Layout.HALL)
end

type Band = { rows: { { number } }, side: string }

function Layout.bands(): { Band }
	return {
		{ rows = Layout.tileAxis(Layout.CORR_HALF, Layout.FZ, Layout.NROWS, Layout.HALL), side = "south" },
		{ rows = Layout.tileAxis(-Layout.FZ, -Layout.CORR_HALF, Layout.NROWS, Layout.HALL), side = "north" },
	}
end

function Layout.inAud(x: number, z: number): boolean
	local a = Layout.AUD
	return x >= a.minX and x <= a.maxX and z >= a.minZ and z <= a.maxZ
end

-- Cells that merge into one big room. Band 1 is north of the corridor, band 2
-- south; row 1 of band 1 and row 2 of band 2 are the rows on the corridor.
type Merge = { level: number, band: number, row: number, from: number, to: number, kind: string }
local MERGES: { Merge } = {
	{ level = 1, band = 1, row = 1, from = 3, to = 4, kind = "hackhall" },
	{ level = 2, band = 2, row = 2, from = 2, to = 3, kind = "library" },
}

export type Cell = {
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
	side: string, -- which side the central corridor is on: "south" or "north"
	no: number,
	kind: string?, -- fixed kind for merged halls; nil = dealt by the floor plan
	doorXs: { number }, -- world X of each corridor-side door
}

local function mergeAt(level: number, band: number, row: number): Merge?
	for _, m in MERGES do
		if m.level == level and m.band == band and m.row == row then
			return m
		end
	end
	return nil
end

local cellCache: { [number]: { Cell } } = {}

--- The rooms on one floor, in a stable order. Cached; treat as read-only.
function Layout.cells(level: number): { Cell }
	if cellCache[level] then
		return cellCache[level]
	end
	local cols = Layout.columns()
	local out: { Cell } = {}
	local n = 0
	for bi, band in Layout.bands() do
		for ri, row in band.rows do
			local merge = mergeAt(level, bi, ri)
			local ci = 1
			while ci <= #cols do
				local col = cols[ci]
				local cx, cz = (col[1] + col[2]) / 2, (row[1] + row[2]) / 2
				if merge and ci == merge.from then
					n += 1
					local doors = {}
					for k = merge.from, merge.to do
						table.insert(doors, (cols[k][1] + cols[k][2]) / 2)
					end
					table.insert(out, {
						minX = col[1],
						maxX = cols[merge.to][2],
						minZ = row[1],
						maxZ = row[2],
						side = band.side,
						no = n,
						kind = merge.kind,
						doorXs = doors,
					})
					ci = merge.to + 1
				else
					if not (level == 0 and Layout.inAud(cx, cz)) then
						n += 1
						table.insert(out, {
							minX = col[1],
							maxX = col[2],
							minZ = row[1],
							maxZ = row[2],
							side = band.side,
							no = n,
							kind = nil,
							doorXs = { cx },
						})
					end
					ci += 1
				end
			end
		end
	end
	cellCache[level] = out
	return out
end

--- Is (x, z) inside a room, the auditorium or a shaft on this level? Used to
--- keep hall fixtures out of the rooms.
function Layout.occupied(level: number, x: number, z: number): boolean
	if level == 0 and Layout.inAud(x, z) then
		return true
	end
	for _, c in Layout.cells(level) do
		if x > c.minX - 1 and x < c.maxX + 1 and z > c.minZ - 1 and z < c.maxZ + 1 then
			return true
		end
	end
	local s, e = Layout.SHAFT, Layout.ELEV
	if x > s.xMin - 1 and z > s.zMin - 1 and z < s.zMax + 1 then
		return true
	end
	if x < e.xMax + 1 and z > e.zMin - 1 and z < e.zMax + 1 then
		return true
	end
	return false
end

--- Centre lines of the halls: X of each cross hall, Z of each E-W hall
--- (perimeter ring and the gaps between room rows), excluding the corridor.
function Layout.hallLines(): ({ number }, { number })
	local xs, zs = {}, {}
	local cols = Layout.columns()
	table.insert(xs, (-Layout.FX + cols[1][1]) / 2)
	for i = 1, #cols - 1 do
		table.insert(xs, (cols[i][2] + cols[i + 1][1]) / 2)
	end
	table.insert(xs, (cols[#cols][2] + Layout.FX) / 2)
	for _, band in Layout.bands() do
		local rows = band.rows
		for i = 1, #rows - 1 do
			table.insert(zs, (rows[i][2] + rows[i + 1][1]) / 2)
		end
	end
	local northRows = Layout.bands()[1].rows
	local ring = (Layout.FZ + northRows[#northRows][2]) / 2
	table.insert(zs, ring)
	table.insert(zs, -ring)
	return xs, zs
end

return Layout
