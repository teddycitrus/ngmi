--!strict
--------------------------------------------------------------------------------
-- Auditorium.luau
-- Ground-floor lecture hall: stage, screen and curtains at the south end,
-- raked bench seating rising to the north doors.
--
-- The opening cinematic is staged here, so the following must not move:
-- the AUD rectangle (OpeningSequence has a copy), the stage (2 high, front
-- edge at minZ + 19), the lectern at (cx - 14, stageZ1 - 3), the clear strip
-- of stage the organizer walks along, and the "BenchSeat" Seats: their size
-- and position are what the crowd placement samples.
--------------------------------------------------------------------------------

local Kit = require(script.Parent.Kit)
local Layout = require(script.Parent.Layout)
local Walls = require(script.Parent.Walls)
local Decor = require(script.Parent.Decor)

local V = Vector3.new
local CF = CFrame.new
local M = Enum.Material
local TAGS = Kit.TAGS
local COLORS = Kit.COLORS

local Auditorium = {}

local TIER = Color3.fromRGB(86, 82, 84)
local FASCIA = Color3.fromRGB(96, 66, 44)
local SEAT = Color3.fromRGB(140, 46, 50)
local CURTAIN = Color3.fromRGB(96, 18, 26)

--- A bench Seat (the crowd samples these) dressed as a row of seat backs.
local function benchRow(parent: Instance, x0: number, x1: number, topY: number, z: number)
	if x1 - x0 < 3 then
		return
	end
	local w = x1 - x0
	local cx = (x0 + x1) / 2
	local bench = Kit.seat(parent, "BenchSeat", V(w, 1.2, 2.4), V(cx, topY + 0.6, z), SEAT, M.Fabric)
	bench.CastShadow = true
	Kit.trim(parent, "BenchFront", V(w, 1.0, 0.1), V(cx, topY + 0.5, z - 1.25), FASCIA, M.Wood)
	Kit.part(parent, "BenchBack", V(w, 0.5, 0.4), V(cx, topY + 1.15, z + 1.4), FASCIA, M.Wood)
	local n = math.floor(w / 3.3)
	for i = 0, n - 1 do
		local sx = x0 + (i + 0.5) * w / n
		Kit.trim(parent, "SeatBack", V(w / n - 0.3, 2.0, 0.35), CF(sx, topY + 2.35, z + 1.45) * CFrame.Angles(math.rad(8), 0, 0), SEAT, M.Fabric)
	end
	Kit.trim(parent, "BackRail", V(w, 0.18, 0.5), V(cx, topY + 3.38, z + 1.6), FASCIA, M.Wood)
end

local function stageDressing(parent: Instance, cx: number, y: number, minX: number, maxX: number, minZ: number, stageZ1: number)
	local stageH = 2
	local w = maxX - minX - 8
	local stage = Kit.part(parent, "Stage", V(w, stageH, stageZ1 - minZ - 1), V(cx, y + stageH / 2, (minZ + 1 + stageZ1) / 2), Color3.fromRGB(70, 48, 32), M.WoodPlanks)
	stage.CastShadow = true
	Kit.trim(parent, "Apron", V(w + 0.2, stageH - 0.2, 0.2), V(cx, y + (stageH - 0.2) / 2, stageZ1 + 0.1), Color3.fromRGB(26, 24, 26), M.SmoothPlastic)
	local edge = Kit.trim(parent, "StageEdge", V(w, 0.08, 0.12), V(cx, y + stageH + 0.04, stageZ1 - 0.08), Color3.fromRGB(255, 200, 120), M.Neon)
	edge.Transparency = 0.3
	-- steps up at both ends
	for _, sx in { -1, 1 } do
		for k = 1, 3 do
			local h = k * stageH / 4
			Kit.part(parent, "StageStep", V(5, h, 1.2), V(cx + sx * (w / 2 - 4), y + h / 2, stageZ1 + 3.7 - k * 1.2), Color3.fromRGB(60, 44, 30), M.WoodPlanks)
		end
	end

	-- projector screen in a black frame
	local screen = Kit.part(parent, "ProjectorScreen", V(46, 14, 0.3), V(cx, y + 9.5, minZ + 0.95), Color3.fromRGB(235, 238, 245), M.SmoothPlastic)
	Kit.label(screen, Enum.NormalId.Back, "VesperHacks 2026\nWelcome, hackers.", Color3.fromRGB(30, 32, 40), Color3.fromRGB(235, 238, 245), Enum.Font.GothamBold)
	Kit.trim(parent, "ScreenFrame", V(47.2, 15.2, 0.2), V(cx, y + 9.5, minZ + 0.82), Color3.fromRGB(16, 16, 18), M.SmoothPlastic)

	-- curtain legs framing the screen and a valance across the top
	for _, sx in { -1, 1 } do
		for k = 0, 3 do
			local x = cx + sx * (25.5 + k * 1.1)
			Kit.trim(parent, "Curtain", V(1.3, Layout.INNER_H - stageH, 0.5), CF(x, y + stageH + (Layout.INNER_H - stageH) / 2, minZ + 2.2 + (k % 2) * 0.3), CURTAIN, M.Fabric)
		end
	end
	Kit.trim(parent, "Valance", V(62, 2.4, 0.6), V(cx, y + Layout.INNER_H - 1.2, minZ + 2.6), CURTAIN, M.Fabric)

	-- lighting truss over the stage front, with cans aimed at the stage
	local trussY = y + Layout.INNER_H - 2
	local trussZ = stageZ1 + 2
	for _, dz in { -0.5, 0.5 } do
		Kit.cyl(parent, "Truss", 60, 0.2, CF(cx, trussY + 0.5, trussZ + dz), Color3.fromRGB(150, 152, 156), M.Metal, { collide = false })
		Kit.cyl(parent, "Truss", 60, 0.2, CF(cx, trussY - 0.5, trussZ + dz), Color3.fromRGB(150, 152, 156), M.Metal, { collide = false })
	end
	for k = -3, 3 do
		local x = cx + k * 8
		local can = Kit.cylY(parent, "StageCan", 1.2, 0.8, CF(x, trussY - 1.3, trussZ) * CFrame.Angles(math.rad(35), 0, 0), Color3.fromRGB(26, 26, 30), M.Metal, { collide = false })
		if k % 2 == 0 then
			local spot = Instance.new("SpotLight")
			spot.Face = Enum.NormalId.Left
			spot.Angle = 50
			spot.Brightness = 1.2
			spot.Range = 26
			spot.Color = Color3.fromRGB(255, 232, 196)
			spot.Parent = can
			Kit.tag(can, TAGS.CEILING_LIGHT)
		end
	end
end

function Auditorium.build(parent: Instance)
	local y = Layout.floorY(0)
	local a = Layout.AUD
	local minX, maxX, minZ, maxZ = a.minX, a.maxX, a.minZ, a.maxZ
	local cx = (minX + maxX) / 2
	local midZ = (minZ + maxZ) / 2
	local stageZ1 = minZ + 19

	Walls.room(parent, minX, maxX, minZ, maxZ, y, { color = Color3.fromRGB(206, 200, 190), accent = Color3.fromRGB(84, 30, 36) }, {
		north = { { width = 16, height = 11, kind = "double" } },
		east = { { width = 8, height = 10, kind = "double" } },
		west = { { width = 8, height = 10, kind = "double" } },
	})
	local carpet = Kit.part(parent, "FloorFinish", V(maxX - minX - 1.5, 0.1, maxZ - minZ - 1.5), V(cx, y + 0.05, midZ), Color3.fromRGB(64, 36, 46), M.Carpet)
	carpet.CastShadow = false

	stageDressing(parent, cx, y, minX, maxX, minZ, stageZ1)
	Decor.place("Lectern", cx - 14, y + 2, stageZ1 - 3, 0, parent)

	-- acoustic panels down both side walls
	for _, side in { { minX, 1 }, { maxX, -1 } } do
		local wx, out = side[1], side[2]
		for k = 0, 6 do
			local z = minZ + 24 + k * 7.5
			if math.abs(z - midZ) > 5 then
				local p = V(wx + out * (Walls.FACE + 0.2), y + 9, z)
				Kit.trim(parent, "AcousticPanel", V(0.4, 7, 5.6), p, if k % 2 == 0 then Color3.fromRGB(60, 56, 62) else Color3.fromRGB(84, 30, 36), M.Fabric)
			end
		end
	end

	Decor.hangingBanner(parent, V(cx - 34, y + Layout.INNER_H - 0.5, minZ + 2), V(0, 0, 1), 11, COLORS.UNI_MAROON, "ST. VESPER", "UNIVERSITY\nEst. 1962")
	Decor.hangingBanner(parent, V(cx + 34, y + Layout.INNER_H - 0.5, minZ + 2), V(0, 0, 1), 11, COLORS.UNI_NAVY, "SCHOOL OF", "COMPUTING\n& ENGINEERING")

	-- raked seating; each tier is solid from the floor up
	local aisleHalf = 5
	local tierStartZ = stageZ1 + 9
	local tiers = 5
	local step = 9
	for t = 0, tiers - 1 do
		local z = tierStartZ + t * step
		local h = t * 1.5
		local stepH = h + 0.8
		Kit.part(parent, "SeatTier", V(maxX - minX - 6, stepH, step), V(cx, y + stepH / 2, z + 0.5), TIER, M.Carpet)
		Kit.trim(parent, "TierNose", V(maxX - minX - 6.1, 0.3, 0.3), V(cx, y + stepH - 0.12, z - 3.95), FASCIA, M.Wood)
		benchRow(parent, minX + 6, cx - aisleHalf, y + h + 0.8, z)
		benchRow(parent, cx + aisleHalf, maxX - 6, y + h + 0.8, z)
		for _, sx in { -1, 1 } do
			local lamp = Kit.trim(parent, "AisleLight", V(0.5, 0.18, 0.12), V(cx + sx * (aisleHalf - 0.6), y + stepH - 0.4, z - 4.08), Color3.fromRGB(255, 210, 140), M.Neon)
			lamp.CastShadow = false
		end
		if t == tiers - 1 then
			local hide = Kit.part(parent, "HideSpot", V(4, 2.5, 3), V(minX + 9, y + h + 2, z), Color3.new(), nil, { collide = false, transparency = 1 })
			Kit.tag(hide, TAGS.HIDING_SPOT)
		end
	end

	-- back row on the flanks, exit stairs down the middle to the north doors
	local topH = (tiers - 1) * 1.5 + 0.8
	local backH = topH + 1.5
	local backZ = tierStartZ + (tiers - 1) * step + step / 2
	local backDepth = (maxZ - 2) - backZ
	local doorHalf = 8
	for _, span in { { minX + 6, cx - doorHalf }, { cx + doorHalf, maxX - 6 } } do
		local x0, x1 = span[1], span[2]
		Kit.part(parent, "SeatTier", V(x1 - x0, backH, backDepth), V((x0 + x1) / 2, y + backH / 2, backZ + backDepth / 2), TIER, M.Carpet)
		benchRow(parent, x0, x1, y + backH, backZ + 1)
	end
	local nSteps = 5
	local sd = math.max(0.6, backDepth / nSteps)
	for i = 0, nSteps - 1 do
		local sh = topH * (nSteps - i) / (nSteps + 1)
		Kit.part(parent, "ExitStair", V(doorHalf * 2, sh, sd + 0.1), V(cx, y + sh / 2, backZ + i * sd + sd / 2), Color3.fromRGB(80, 78, 80), M.Concrete)
		Kit.trim(parent, "StairNose", V(doorHalf * 2 - 0.4, 0.06, 0.2), V(cx, y + sh + 0.03, backZ + i * sd + 0.12), Color3.fromRGB(226, 182, 40), M.SmoothPlastic)
	end

	-- acoustic clouds over the seating, with downlights
	for k = 0, 2 do
		local z = stageZ1 + 12 + k * 15
		for _, sx in { -1, 1 } do
			local p = V(cx + sx * 30, y + Layout.INNER_H - 1.6, z)
			Kit.trim(parent, "AcousticCloud", V(26, 0.5, 9), p, Color3.fromRGB(228, 226, 220), M.Fabric)
			for _, wire in { -1, 1 } do
				Kit.trim(parent, "CloudWire", V(0.05, 1.3, 0.05), p + V(wire * 12, 0.9, 0), Color3.fromRGB(150, 150, 150), M.Metal)
			end
			local lt = Kit.trim(parent, "CeilingLight", V(3, 0.12, 3), p - V(0, 0.3, 0), Color3.fromRGB(255, 250, 238), M.Neon)
			Kit.light(lt, 0.8, 30)
			Kit.tag(lt, TAGS.CEILING_LIGHT)
		end
	end
	-- the projector, hung over the back rows
	local proj = Kit.part(parent, "Projector", V(2.4, 1, 2), V(cx, y + Layout.INNER_H - 2.2, backZ - 4), Color3.fromRGB(226, 226, 222), M.SmoothPlastic, { collide = false })
	Kit.trim(parent, "ProjectorMount", V(0.3, 1.6, 0.3), V(cx, y + Layout.INNER_H - 0.9, backZ - 4), Color3.fromRGB(60, 60, 64), M.Metal)
	Kit.cylZ(parent, "ProjectorLens", 0.3, 0.7, V(cx, y + Layout.INNER_H - 2.2, backZ - 5.1), Color3.fromRGB(20, 20, 24), M.Glass, { collide = false })
	proj.CastShadow = false

	-- signage and gameplay markers
	local sp = V(cx, y + 12.3, maxZ + Walls.FACE + 0.1)
	local sign = Kit.trim(parent, "RoomSign", V(14, 1.6, 0.2), CFrame.lookAt(sp, sp + V(0, 0, 1)), Color3.fromRGB(28, 30, 38), M.SmoothPlastic)
	Kit.label(sign, Enum.NormalId.Front, "AUDITORIUM · LECTURE HALL A", Color3.fromRGB(236, 238, 242), nil, Enum.Font.GothamBold, true)
	for _, d in { { V(minX, y + 11.2, midZ), V(1, 0, 0) }, { V(maxX, y + 11.2, midZ), V(-1, 0, 0) }, { V(cx, y + 12.5, maxZ), V(0, 0, -1) } } do
		Decor.exitSign(parent, d[1], d[2])
	end
	local spawn = Kit.part(parent, "NGMISpawn_Auditorium", V(1.5, 0.2, 1.5), V(cx, y + 1, stageZ1 + 4), Color3.new(), nil, { collide = false, transparency = 1 })
	Kit.tag(spawn, TAGS.NGMI_SPAWN)
	local lean = Kit.part(parent, "LeanSpot_Aud", V(1.5, 0.2, 1.5), V(minX + 1.6, y + 0.2, midZ), Color3.new(), nil, { collide = false, transparency = 1 })
	lean:SetAttribute("Face", V(1, 0, 0))
	Kit.tag(lean, TAGS.LEAN_SPOT)
end

return Auditorium
