--!strict
--------------------------------------------------------------------------------
-- Stairs.luau
-- Switchback stairwell at the east end of the corridor.
--
-- The walking geometry (solid treads, landings, the spine wall) is unchanged
-- from the original build because pathfinding and the ambient sitters depend
-- on it: 15 steps per half-flight (0.6 rise, 1.4 run), flights along X at
-- Z = +-5, a turn landing at the east end and a floor landing at the west.
-- Everything else here is dressing.
--------------------------------------------------------------------------------

local Kit = require(script.Parent.Kit)
local Layout = require(script.Parent.Layout)
local Walls = require(script.Parent.Walls)
local Decor = require(script.Parent.Decor)

local V = Vector3.new
local CF = CFrame.new
local M = Enum.Material
local SHAFT = Layout.SHAFT
local WALL_T = Layout.WALL_T
local TAGS = Kit.TAGS

local Stairs = {}

local STEPS = 15
local HALF_RISE = Layout.LEVEL_H / 2
local DEPTH = 9 -- flight width (along Z)
local FLIGHT_Z = 5
local DIV_DEPTH = (FLIGHT_Z * 2 - DEPTH) + 1.2
local FLOOR_LANDING = 6 -- depth of the landing at each floor, from the shaft's west wall
local TURN_LANDING = 6 -- depth of the half-way turn landing, from the east wall
local RAIL_H = 3

local CONCRETE = Color3.fromRGB(116, 116, 112)
local BLOCK = Color3.fromRGB(206, 204, 196)
local NOSE = Color3.fromRGB(42, 42, 46)
local SAFETY = Color3.fromRGB(226, 182, 40)
local RAIL = Color3.fromRGB(52, 60, 72)

--- A round handrail on wall brackets, from `a` to `b`, standing off the wall
--- face along `out`.
local function handrail(parent: Instance, a: Vector3, b: Vector3, out: Vector3)
	local mid = (a + b) / 2
	local len = (b - a).Magnitude
	Kit.cyl(parent, "Handrail", len, 0.24, CFrame.lookAt(mid, b) * CFrame.Angles(0, math.pi / 2, 0), RAIL, M.Metal, { collide = false })
	local n = math.max(2, math.floor(len / 4))
	for i = 0, n do
		local p = a:Lerp(b, i / n)
		Kit.trim(parent, "RailBracket", V(0.1, 0.5, 0.1), CF(p - out * 0.2 - V(0, 0.25, 0)), RAIL, M.Metal)
		Kit.trim(parent, "RailBracket", V(0.08, 0.08, 0.4), CFrame.lookAt(p - out * 0.2 - V(0, 0.5, 0), p - out * 0.6 - V(0, 0.5, 0)), RAIL, M.Metal)
	end
end

--- Solid filled flight with nosings, plus a sloped skirt and handrail on the
--- shaft-wall side and the spine side.
local function flight(parent: Instance, yStart: number, xFrom: number, xTo: number, zc: number)
	local run = (xTo - xFrom) / STEPS
	local rise = HALF_RISE / STEPS
	local dir = if run >= 0 then 1 else -1
	for i = 1, STEPS do
		local topY = yStart + i * rise
		local h = topY - (yStart - 1)
		local tread = Kit.part(parent, "Step", V(math.abs(run), h, DEPTH), V(xFrom + run * (i - 0.5), topY - h / 2, zc), CONCRETE, M.Concrete)
		Kit.surface(tread, "STAIR_CONCRETE")
		local noseX = xFrom + run * (i - 1) + dir * 0.2
		Kit.trim(parent, "StepNose", V(0.42, 0.06, DEPTH - 0.6), V(noseX, topY + 0.03, zc), NOSE, M.Rubber)
		Kit.trim(parent, "StepEdge", V(0.12, 0.07, DEPTH - 0.7), V(noseX - dir * 0.14, topY + 0.035, zc), SAFETY, M.SmoothPlastic)
	end
	local outward = if zc >= 0 then 1 else -1
	local wallFace = SHAFT.zMax * outward - outward * (WALL_T / 2)
	local spineFace = outward * (DIV_DEPTH / 2)
	local y0, y1 = yStart, yStart + HALF_RISE
	for _, face in { { wallFace, -outward }, { spineFace, outward } } do
		local fz, into = face[1], face[2]
		-- sloped skirt board following the pitch, just above the nosings
		local a = V(xFrom, y0 + 0.5, fz + into * 0.05)
		local b = V(xTo, y1 + 0.5, fz + into * 0.05)
		Kit.trim(parent, "Skirt", V(0.1, 0.9, (b - a).Magnitude), CFrame.lookAt((a + b) / 2, b), NOSE, M.SmoothPlastic)
		handrail(
			parent,
			V(xFrom, y0 + RAIL_H, fz + into * 0.6),
			V(xTo, y1 + RAIL_H, fz + into * 0.6),
			V(0, 0, into)
		)
	end
end

local function landing(parent: Instance, y: number, x0: number, x1: number, noseX: number?, noseDir: number?)
	local pad = Kit.part(parent, "Landing", V(x1 - x0, 1.03, SHAFT.zMax - SHAFT.zMin), V((x0 + x1) / 2, y - 0.525, 0), CONCRETE, M.Concrete)
	Kit.surface(pad, "STAIR_CONCRETE")
	if noseX and noseDir then
		Kit.trim(parent, "LandingEdge", V(0.12, 0.07, SHAFT.zMax - SHAFT.zMin - 1), V(noseX + noseDir * 0.1, y + 0.035, 0), SAFETY, M.SmoothPlastic)
	end
end

--- Caged wall bulkhead light. Tagged so it dies in the blackout.
local function bulkhead(parent: Instance, x: number, y: number, wallZ: number, inward: number)
	local face = wallZ + inward * (WALL_T / 2)
	Kit.trim(parent, "BulkheadBase", V(2.0, 1.3, 0.3), V(x, y, face + inward * 0.15), Color3.fromRGB(60, 62, 66), M.Metal)
	local lens = Kit.trim(parent, "StairLight", V(1.6, 0.9, 0.3), V(x, y, face + inward * 0.42), Color3.fromRGB(255, 246, 220), M.Neon)
	for k = -1, 1 do
		Kit.trim(parent, "Cage", V(0.06, 1.1, 0.06), V(x + k * 0.55, y, face + inward * 0.62), Color3.fromRGB(40, 40, 44), M.Metal)
	end
	Kit.trim(parent, "Cage", V(1.8, 0.06, 0.06), V(x, y, face + inward * 0.66), Color3.fromRGB(40, 40, 44), M.Metal)
	Kit.light(lens, 0.7, 22)
	Kit.tag(lens, TAGS.CEILING_LIGHT)
end

--- A painted floor number on the shaft wall, the way real stairwells do it.
local function floorNumber(parent: Instance, level: number, y: number)
	local face = SHAFT.zMax - WALL_T / 2 - 0.02
	local board = Kit.trim(parent, "FloorNumber", V(2.6, 3.4, 0.04), V(SHAFT.xMin + 2.1, y + 8.2, face), Color3.new(), M.SmoothPlastic, { transparency = 1 })
	Kit.label(board, Enum.NormalId.Front, tostring(level + 1), Layout.ACCENT[level + 1], nil, Enum.Font.GothamBlack)
	local sub = Kit.trim(parent, "FloorLabel", V(2.6, 0.6, 0.04), V(SHAFT.xMin + 2.1, y + 6.1, face), Color3.new(), M.SmoothPlastic, { transparency = 1 })
	Kit.label(sub, Enum.NormalId.Front, "FLOOR " .. (level + 1), Color3.fromRGB(40, 40, 44), nil, Enum.Font.GothamBold)
end

function Stairs.build(root: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Stairwell"
	folder.Parent = root

	-- Each flight runs exactly from one landing's edge to the next. They used
	-- to run 4-5 studs into the landing slabs, so the last step met the landing
	-- edge ~1.8 studs below its top: an unclimbable top stair.
	local xW = SHAFT.xMin + FLOOR_LANDING
	local xE = SHAFT.xMax - TURN_LANDING
	for gap = 0, Layout.FLOORS - 2 do
		local baseY = Layout.floorY(gap)
		flight(folder, baseY, xW, xE, -FLIGHT_Z)
		landing(folder, baseY + HALF_RISE, xE, SHAFT.xMax, xE, 1)
		flight(folder, baseY + HALF_RISE, xE, xW, FLIGHT_Z)
		landing(folder, Layout.floorY(gap + 1), SHAFT.xMin, xW, xW, -1)
		-- spine wall the switchback wraps around, sealed full height
		local divX0, divX1 = xW, xE
		local spine = Kit.part(folder, "StairDivider", V(divX1 - divX0, Layout.LEVEL_H, DIV_DEPTH), V((divX0 + divX1) / 2, baseY + Layout.LEVEL_H / 2, 0), BLOCK, M.Brick)
		spine.Name = "StairDivider"
		Kit.trim(folder, "Stripe", V(divX1 - divX0 + 0.1, 1.0, DIV_DEPTH + 0.1), V((divX0 + divX1) / 2, baseY + HALF_RISE + 4.2, 0), Layout.ACCENT[gap + 2], M.SmoothPlastic)
		local turnY = baseY + HALF_RISE + 6.5
		bulkhead(folder, SHAFT.xMax - 3, turnY, SHAFT.zMin, 1)
		bulkhead(folder, SHAFT.xMax - 3, turnY, SHAFT.zMax, -1)
	end

	local block: Walls.Style = { color = BLOCK, material = M.Brick, trim = false }
	for level = 0, Layout.FLOORS - 1 do
		local y = Layout.floorY(level)
		local h = Layout.INNER_H + Layout.SLAB_T - 0.02
		Walls.run(folder, V(SHAFT.xMin, y, SHAFT.zMin), V(Layout.FX + WALL_T, y, SHAFT.zMin), h, block)
		Walls.run(folder, V(SHAFT.xMin, y, SHAFT.zMax), V(Layout.FX + WALL_T, y, SHAFT.zMax), h, block)
		-- corridor wall with a fire door; leaf folds into the stairwell
		Walls.run(
			folder,
			V(SHAFT.xMin, y, SHAFT.zMin + WALL_T / 2),
			V(SHAFT.xMin, y, SHAFT.zMax - WALL_T / 2),
			h,
			{ color = Layout.WALL[level + 1], accent = Layout.ACCENT[level + 1] },
			{ { width = 6, height = 10, kind = "fire" } },
			V(1, 0, 0),
			0.18
		)
		-- accent stripe round the inside of the shaft at this storey
		for _, side in { -1, 1 } do
			local z = side * (SHAFT.zMax - WALL_T / 2 - 0.02)
			Kit.trim(folder, "Stripe", V(SHAFT.xMax - SHAFT.xMin, 1.0, 0.06), V((SHAFT.xMin + SHAFT.xMax) / 2 + 0.75, y + 4.2, z), Layout.ACCENT[level + 1], M.SmoothPlastic)
		end
		floorNumber(folder, level, y)
		Decor.exitSign(folder, V(SHAFT.xMin, y + 11.4, 0), V(-1, 0, 0))
		Decor.plaque(folder, V(SHAFT.xMin, y + 5.4, -4.4), V(-1, 0, 0), "STAIR A", "Floors 1-3", Layout.ACCENT[level + 1])
		bulkhead(folder, SHAFT.xMin + 3.5, y + 7, SHAFT.zMin, 1)

		if level == Layout.FLOORS - 1 then
			local top = y + Layout.INNER_H
			Kit.part(folder, "LightSoffit", V(5, 0.6, 3), V((SHAFT.xMin + SHAFT.xMax) / 2, top - 0.3, 0), BLOCK, M.Concrete)
			local lt = Kit.trim(folder, "StairLight", V(4, 0.2, 2), V((SHAFT.xMin + SHAFT.xMax) / 2, top - 0.7, 0), Color3.fromRGB(255, 255, 245), M.Neon)
			Kit.light(lt, 0.85, 34)
			Kit.tag(lt, TAGS.CEILING_LIGHT)
		end
		if level < Layout.FLOORS - 1 then
			-- a hacker sitting on a step, back to the south wall
			local lrun = (xE - xW) / STEPS
			local lstep = math.floor(STEPS * 0.4)
			local lean = Kit.part(folder, "LeanSpot_Stair_" .. level, V(1.5, 0.2, 1.5), V(xW + lrun * (lstep - 0.5), y + lstep * (HALF_RISE / STEPS) + 0.2, SHAFT.zMin + 2), Color3.new(), nil, { collide = false, transparency = 1 })
			lean:SetAttribute("Face", V(0, 0, 1))
			Kit.tag(lean, TAGS.LEAN_SPOT)
		end
		local spawn = Kit.part(folder, "NGMISpawn_Stair_" .. level, V(1.5, 0.2, 1.5), V((SHAFT.xMin + SHAFT.xMax) / 2, y + 1, 0), Color3.new(), nil, { collide = false, transparency = 1 })
		Kit.tag(spawn, TAGS.NGMI_SPAWN)
	end

	-- under the first flight: the janitor's corner
	local y = Layout.floorY(0)
	Kit.cylY(folder, "MopBucket", 1.4, 1.8, V(SHAFT.xMax - 6, y + 0.7, 7.5), Color3.fromRGB(220, 180, 30), M.SmoothPlastic, { collide = false })
	Kit.trim(folder, "MopHandle", V(0.14, 5.5, 0.14), CF(SHAFT.xMax - 6.2, y + 3, 7.6) * CFrame.Angles(0, 0, math.rad(-14)), Color3.fromRGB(150, 110, 70), M.Wood)
	local sign = Kit.trim(folder, "WetFloor", V(1.6, 2.6, 0.08), CF(SHAFT.xMax - 9, y + 1.25, 7) * CFrame.Angles(math.rad(-10), math.rad(-30), 0), SAFETY, M.SmoothPlastic)
	Kit.label(sign, Enum.NormalId.Front, "CAUTION\nWET\nFLOOR", Color3.fromRGB(30, 30, 30), nil, Enum.Font.GothamBlack)
end

return Stairs
