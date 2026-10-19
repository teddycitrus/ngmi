--!strict
--------------------------------------------------------------------------------
-- Halls.luau
-- Everything in the circulation space of one floor: hall lighting, the
-- corridor's floor inlays, wall furniture beside each door, sponsor banners,
-- wayfinding, emergency lights, and the gameplay markers that live in halls.
--------------------------------------------------------------------------------

local Kit = require(script.Parent.Kit)
local Layout = require(script.Parent.Layout)
local Shell = require(script.Parent.Shell)
local Decor = require(script.Parent.Decor)

local V = Vector3.new
local M = Enum.Material
local TAGS = Kit.TAGS
local CORR = Layout.CORR_HALF

local Halls = {}

local function marker(name: string, pos: Vector3, parent: Instance, tagName: string?): Part
	local m = Kit.part(parent, name, V(1.5, 0.2, 1.5), pos, Color3.new(), nil, { collide = false, transparency = 1 })
	if tagName then
		Kit.tag(m, tagName)
	end
	return m
end
Halls.marker = marker

local function lights(folder: Instance, level: number)
	local y = Layout.floorY(level) + Layout.CEIL_H
	local n = 0
	-- central corridor: a continuous run, every other fixture lit
	for x = -140, 126, 12 do
		n += 1
		Shell.troffer(folder, V(x, y, 0), true, n % 2 == 0, 0.6, 22, true)
	end
	local xs, zs = Layout.hallLines()
	-- cross halls
	for _, x in xs do
		for _, sign in { -1, 1 } do
			for z = 22, 90, 17 do
				local p = V(x, y, z * sign)
				if not Layout.occupied(level, p.X, p.Z) then
					n += 1
					Shell.troffer(folder, p, false, n % 4 == 0, 0.6, 24)
				end
			end
		end
	end
	-- perimeter ring and the halls between room rows
	for _, z in zs do
		for x = -148, 148, 18 do
			-- skip spots a cross-hall fixture already covers
			local taken = false
			for _, cx in xs do
				if math.abs(cx - x) < 3 and math.abs(z) > 22 and math.abs(z) < 90 then
					taken = true
				end
			end
			if not taken and not Layout.occupied(level, x, z) then
				n += 1
				Shell.troffer(folder, V(x, y, z), true, n % 4 == 0, 0.6, 24)
			end
		end
	end
end

local function corridorFloor(folder: Instance, y: number)
	local x0, x1 = Layout.ELEV.xMax + 1, Layout.SHAFT.xMin - 1
	local len = x1 - x0
	for _, z in { -CORR + 1.4, CORR - 1.4 } do
		Kit.trim(folder, "Inlay", V(len, 0.03, 0.5), V((x0 + x1) / 2, y + 0.015, z), Color3.fromRGB(70, 62, 56), M.Marble, { shadow = false })
	end
	-- a band across the corridor at every cross hall
	local xs = Layout.hallLines()
	for _, x in xs do
		if x > x0 and x < x1 then
			Kit.trim(folder, "Inlay", V(0.5, 0.03, CORR * 2 - 3.3), V(x, y + 0.015, 0), Color3.fromRGB(70, 62, 56), M.Marble, { shadow = false })
		end
	end
end

-- What stands against the corridor wall beside each door, by slot.
local SLOT_A = { "Locker", "NoticeBoard", "WaterFountain", "Bookshelf", "Locker", "TrophyCase", "Bench" }

--- Wall dressing beside each corridor-side door of every room.
local function doorDressing(folder: Instance, level: number)
	local y = Layout.floorY(level)
	local i = 0
	for _, cell in Layout.cells(level) do
		local onCorridor = (cell.side == "south" and cell.minZ < 20) or (cell.side == "north" and cell.maxZ > -20)
		if onCorridor then
			local wallZ = if cell.side == "south" then cell.minZ else cell.maxZ
			local out = V(0, 0, if cell.side == "south" then -1 else 1)
			for _, dx in cell.doorXs do
				i += 1
				local kind = SLOT_A[((i + level * 2) % #SLOT_A) + 1]
				Decor.onWall(folder, kind, V(dx - 12, y, wallZ), out)
				if i % 3 == 0 then
					Decor.onWall(folder, "Clock", V(dx - 12, y, wallZ), out)
				end
				local poster = Decor.POSTERS[((i + level * 3) % #Decor.POSTERS) + 1]
				Decor.poster(folder, V(dx + 12.5, y + 6.4, wallZ), out, poster)
				if i % 2 == 0 then
					Decor.onWall(folder, "FireCabinet", V(dx + 18, y, wallZ), out)
				else
					Decor.onWall(folder, "TrashBin", V(dx + 18, y, wallZ), out)
				end
			end
		end
	end
end

--- Steel corner guards where the cross halls meet the corridor.
local function cornerGuards(folder: Instance, level: number)
	local y = Layout.floorY(level)
	local steel = Color3.fromRGB(176, 180, 186)
	for _, cell in Layout.cells(level) do
		local z = if cell.side == "south" then cell.minZ else cell.maxZ
		if math.abs(z) < 20 then
			local zOut = if cell.side == "south" then -0.85 else 0.85
			for _, x in { cell.minX - 0.85, cell.maxX + 0.85 } do
				Kit.trim(folder, "CornerGuard", V(0.3, 5, 0.3), V(x, y + 2.5, z + zOut), steel, M.Metal)
			end
		end
	end
end

--- Planters where the cross halls meet the windows, benches along the ring.
local function ringDressing(folder: Instance, level: number)
	local y = Layout.floorY(level)
	local xs = Layout.hallLines()
	local inner = Layout.FZ + 0.75 - 0.25
	for k, x in xs do
		if k > 1 and k < #xs then
			for _, sign in { -1, 1 } do
				local entry = level == 0 and sign < 0 and math.abs(x - Layout.ENTRY_X) < 2
				if not entry then
					local c = Decor.place("PlantTall", x, y, sign * (inner - 1.2), 0, folder)
					if c then
						c:PivotTo(c:GetPivot() * CFrame.Angles(0, math.rad(k * 40), 0))
					end
				end
			end
		end
	end
	local cols = Layout.columns()
	local northRows = Layout.bands()[1].rows
	local ringWall = northRows[#northRows][2]
	for k, col in cols do
		if k % 2 == 1 then
			local cx = (col[1] + col[2]) / 2
			for _, sign in { -1, 1 } do
				Decor.onWall(folder, "Bench", V(cx, y, sign * ringWall), V(0, 0, sign))
			end
		end
	end
end

function Halls.build(root: Instance, level: number)
	local folder = Instance.new("Folder")
	folder.Name = "Halls_" .. level
	folder.Parent = root
	local y = Layout.floorY(level)
	local accent = Layout.ACCENT[level + 1]

	lights(folder, level)
	corridorFloor(folder, y)
	doorDressing(folder, level)
	cornerGuards(folder, level)
	ringDressing(folder, level)

	-- pull-up sponsor banners down the corridor, alternating sides
	for i, bx in { -128, -80, -30, 30, 80, 116 } do
		local north = i % 2 == 0
		local bz = if north then CORR - 2.2 else -(CORR - 2.2)
		local sponsor = Decor.SPONSORS[((i - 1 + level) % #Decor.SPONSORS) + 1]
		Decor.bannerStand(folder, V(bx, y, bz), V(0, 0, if north then -1 else 1), sponsor)
	end

	-- wayfinding over the corridor, readable in both directions
	for _, x in { -96, 4, 92 } do
		Decor.hangingSign(folder, V(x, y + Layout.CEIL_H - 1.6, 0), V(1, 0, 0), "<<  ELEVATORS  ·  MAIN EXIT", "STAIR A  ·  LABS  >>", accent)
	end

	-- emergency lights: dark until the blackout, then the only light there is
	for _, ex in { -120, -40, 60 } do
		local em = Kit.trim(folder, "EmergencyLight", V(1.4, 0.5, 0.8), V(ex, y + Layout.CEIL_H - 0.35, 6), Color3.fromRGB(70, 14, 14), M.Neon, { transparency = 0.3 })
		Kit.trim(folder, "EmergencyHousing", V(1.6, 0.25, 1.0), V(ex, y + Layout.CEIL_H - 0.1, 6), Color3.fromRGB(230, 230, 226), M.SmoothPlastic)
		Kit.light(em, 1.5, 16, Kit.COLORS.EMERGENCY, false)
		Kit.tag(em, TAGS.EMERGENCY_LIGHT)
	end

	-- corridor lean spots, back to a wall
	for i, lx in { -110, -50, 40, 100 } do
		local north = i % 2 == 0
		local lz = if north then CORR - 1.2 else -(CORR - 1.2)
		local spot = marker("LeanSpot_Corr_" .. level .. "_" .. i, V(lx, y + 0.2, lz), folder, TAGS.LEAN_SPOT)
		spot:SetAttribute("Face", V(0, 0, if north then -1 else 1))
	end
	marker("NGMISpawn_CorrW_" .. level, V(-100, y + 1, 0), folder, TAGS.NGMI_SPAWN)
	marker("NGMISpawn_CorrE_" .. level, V(80, y + 1, 0), folder, TAGS.NGMI_SPAWN)
end

return Halls
