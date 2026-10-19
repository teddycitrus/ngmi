--!strict
--------------------------------------------------------------------------------
-- Exterior.luau
-- Campus grounds: lawn, the front plaza and walkway, trees, hedges, lamps, a
-- monument sign, a flagpole, the road, and the city skyline beyond.
--
-- The lawn sits 1 stud below the ground floor so its top never shares a
-- plane with a floor slab. The opening crane shot starts on the plaza south
-- of the building and rises toward the auditorium bay.
--------------------------------------------------------------------------------

local Lighting = game:GetService("Lighting")

local Kit = require(script.Parent.Kit)
local Layout = require(script.Parent.Layout)

local V = Vector3.new
local CF = CFrame.new
local M = Enum.Material

local Exterior = {}

local LEAVES = { Color3.fromRGB(58, 102, 52), Color3.fromRGB(70, 116, 58), Color3.fromRGB(50, 90, 50), Color3.fromRGB(84, 120, 60) }
local BARK = Color3.fromRGB(78, 58, 40)

local function tree(parent: Instance, pos: Vector3, s: number, seed: number)
	local rng = Random.new(seed)
	local h = 10 * s
	Kit.cylY(parent, "Trunk", h, 1.6 * s, pos + V(0, h / 2, 0), BARK, M.Wood)
	Kit.cylY(parent, "TrunkFlare", 1.2 * s, 2.4 * s, pos + V(0, 0.6 * s, 0), BARK, M.Wood, { collide = false })
	for b = 0, 2 do
		local yaw = rng:NextNumber(0, math.pi * 2)
		local branchCF = CF(pos + V(0, h * (0.6 + b * 0.12), 0)) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(0, 0, math.rad(50)) * CF(0, 2.2 * s, 0)
		Kit.cylY(parent, "Branch", 4.4 * s, 0.6 * s, branchCF, BARK, M.Wood, { collide = false })
	end
	local crown = pos + V(0, h + 3 * s, 0)
	for k = 1, 7 do
		local off = if k == 1 then Vector3.zero else V(rng:NextNumber(-1, 1), rng:NextNumber(-0.5, 0.8), rng:NextNumber(-1, 1)) * 5 * s
		local d = (if k == 1 then 11 else rng:NextNumber(6, 9)) * s
		Kit.blob(parent, "Leaves", V(d, d * 0.8, d), crown + off, LEAVES[rng:NextInteger(1, #LEAVES)], M.Grass, { collide = false })
	end
end

local function lamp(parent: Instance, pos: Vector3, facing: number)
	local dark = Color3.fromRGB(34, 36, 40)
	Kit.cylY(parent, "LampBase", 1.2, 1.2, pos + V(0, 0.6, 0), dark, M.Metal)
	Kit.cylY(parent, "LampPost", 13, 0.5, pos + V(0, 7.2, 0), dark, M.Metal)
	local arm = CF(pos + V(0, 13.4, 0)) * CFrame.Angles(0, facing, 0)
	Kit.trim(parent, "LampArm", V(0.3, 0.3, 3), arm * CF(0, 0, -1.4), dark, M.Metal)
	Kit.part(parent, "LampHead", V(1.6, 0.6, 2.2), arm * CF(0, -0.2, -2.8), dark, M.Metal)
	local lens = Kit.trim(parent, "LampLens", V(1.3, 0.1, 1.9), arm * CF(0, -0.52, -2.8), Color3.fromRGB(255, 226, 170), M.Neon)
	Kit.light(lens, 1, 28, Color3.fromRGB(255, 214, 160))
end

local function bench(parent: Instance, pos: Vector3, yaw: number)
	local cf = CF(pos) * CFrame.Angles(0, yaw, 0)
	local wood = Color3.fromRGB(130, 92, 58)
	for i = -1, 1 do
		Kit.part(parent, "BenchSlat", V(6, 0.2, 0.5), cf * CF(0, 1.7, i * 0.55), wood, M.Wood)
	end
	for _, y in { 2.5, 3.1 } do
		Kit.trim(parent, "BenchBack", V(6, 0.4, 0.15), cf * CF(0, y, 0.9) * CFrame.Angles(math.rad(12), 0, 0), wood, M.Wood)
	end
	for _, sx in { -1, 1 } do
		Kit.part(parent, "BenchLeg", V(0.3, 1.6, 1.7), cf * CF(sx * 2.6, 0.8, 0), Color3.fromRGB(34, 36, 40), M.Metal)
	end
end

local function skyline(parent: Instance, pos: Vector3, size: Vector3, body: Color3, faceDir: number)
	Kit.part(parent, "Skyline", size, pos + V(0, size.Y / 2, 0), body, M.Concrete)
	Kit.part(parent, "SkylineCrown", V(size.X - 6, 6, size.Z - 6), pos + V(0, size.Y + 3, 0), body:Lerp(Color3.new(), 0.2), M.Concrete)
	local cols = math.floor(size.Z / 8)
	local rows = math.floor(size.Y / 8)
	-- one strip of glass per floor, with the lit offices laid over it in runs
	local x = pos.X + faceDir * (size.X / 2 + 0.2)
	for r = 1, rows do
		local y = pos.Y + r * 8 - 2
		Kit.part(parent, "Win", V(0.4, 4, size.Z - 4), V(x, y, pos.Z), Color3.fromRGB(36, 44, 62), M.Glass, { collide = false, shadow = false })
		local c = 1
		while c <= cols do
			if (r * 7 + c * 3) % 5 < 2 then
				local c1 = c
				while c1 + 1 <= cols and (r * 7 + (c1 + 1) * 3) % 5 < 2 do
					c1 += 1
				end
				local z0 = pos.Z - size.Z / 2 + c * 8 - 5.95
				local z1 = pos.Z - size.Z / 2 + c1 * 8 - 2.05
				Kit.part(parent, "WinLit", V(0.5, 3.9, z1 - z0), V(x + faceDir * 0.05, y, (z0 + z1) / 2), Color3.fromRGB(255, 232, 170), M.Neon, { collide = false, shadow = false })
				c = c1 + 1
			else
				c += 1
			end
		end
	end
end

function Exterior.build(root: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Exterior"
	folder.Parent = root

	Kit.part(folder, "Ground", V(2200, 2, 2200), V(0, -2, 0), Color3.fromRGB(86, 116, 64), M.Grass)
	-- plaza with expansion joints and a granite border
	local pz = -175
	Kit.part(folder, "Plaza", V(300, 1, 120), V(0, -0.5, pz), Color3.fromRGB(166, 162, 154), M.Pavement)
	for x = -144, 144, 12 do
		Kit.trim(folder, "Joint", V(0.2, 0.04, 120), V(x, 0.02, pz), Color3.fromRGB(120, 118, 112), M.Concrete, { shadow = false })
	end
	for z = pz - 54, pz + 54, 12 do
		Kit.trim(folder, "Joint", V(300, 0.05, 0.2), V(0, 0.025, z), Color3.fromRGB(120, 118, 112), M.Concrete, { shadow = false })
	end
	for _, z in { pz - 60.5 } do
		Kit.part(folder, "Kerb", V(302, 1.2, 1), V(0, -0.4, z), Color3.fromRGB(96, 94, 92), M.Granite)
	end
	-- road along the far side of the plaza
	Kit.part(folder, "Road", V(900, 1, 34), V(0, -1.4, pz - 79), Color3.fromRGB(46, 46, 50), M.Asphalt)
	for x = -440, 440, 16 do
		Kit.trim(folder, "LaneMark", V(8, 0.05, 0.5), V(x, -0.88, pz - 79), Color3.fromRGB(230, 214, 120), M.SmoothPlastic, { shadow = false })
	end

	-- monument sign at the head of the walkway
	local mx, mz = Layout.ENTRY_X + 30, -122
	Kit.part(folder, "MonumentBase", V(16, 1.5, 4), V(mx, 0.75, mz), Color3.fromRGB(96, 94, 92), M.Granite)
	local face = Kit.part(folder, "Monument", V(14, 4.5, 2.4), V(mx, 3.75, mz), Color3.fromRGB(176, 170, 160), M.Limestone)
	Kit.label(face, Enum.NormalId.Front, "ST. VESPER UNIVERSITY\nHalberd Engineering Hall", Color3.fromRGB(110, 28, 40), nil, Enum.Font.Garamond)
	local lit = Kit.trim(folder, "MonumentLight", V(12, 0.2, 0.6), V(mx, 0.9, mz - 2.3), Color3.fromRGB(255, 226, 180), M.Neon)
	Kit.light(lit, 0.6, 10, Color3.fromRGB(255, 220, 170))

	-- flagpole
	local fx, fz = Layout.ENTRY_X - 30, -124
	Kit.cylY(folder, "FlagPole", 40, 0.6, V(fx, 20, fz), Color3.fromRGB(196, 198, 202), M.Metal)
	Kit.blob(folder, "Finial", V(1, 1, 1), V(fx, 40.4, fz), Kit.COLORS.UNI_GOLD, M.Metal, { collide = false })
	local flag = Kit.trim(folder, "Flag", V(9, 5.5, 0.1), V(fx + 4.8, 36.6, fz), Kit.COLORS.UNI_MAROON, M.Fabric)
	Kit.label(flag, Enum.NormalId.Front, "SV", Kit.COLORS.UNI_GOLD, nil, Enum.Font.Garamond)

	-- lamps and benches along the plaza edge, kept clear of the doors
	for _, dx in { -75, -45, -15, 15, 45, 75 } do
		lamp(folder, V(Layout.ENTRY_X + dx, 0, -118), math.pi)
	end
	for _, dx in { -90, -60, 60, 90 } do
		bench(folder, V(Layout.ENTRY_X + dx, 0, -119), math.pi)
	end
	-- hedges along the facade, broken at the entrance
	local hedgeZ = -(Layout.FZ + Layout.WALL_T) - 4.2
	local spans = { { -(Layout.FX + 6), Layout.ENTRY_X - 12 }, { Layout.ENTRY_X + 12, Layout.FX + 6 } }
	for _, s in spans do
		local len = s[2] - s[1]
		Kit.part(folder, "Hedge", V(len, 3, 3.2), V((s[1] + s[2]) / 2, 0.5, hedgeZ), LEAVES[3], M.LeafyGrass)
		Kit.part(folder, "HedgeBed", V(len + 1, 0.6, 4.2), V((s[1] + s[2]) / 2, -0.9, hedgeZ), Color3.fromRGB(60, 44, 32), M.Ground)
	end

	if not Lighting:FindFirstChildOfClass("Sky") then
		Instance.new("Sky").Parent = Lighting
	end

	-- trees on the lawns that the windows look out on (south, north, west)
	for i = 0, 9 do
		tree(folder, V(-170 + i * 38, -1, -137), 1.0 + (i % 3) * 0.25, i)
		tree(folder, V(-170 + i * 38 + 12, -1, 136), 1.0 + ((i + 1) % 3) * 0.25, 100 + i)
	end
	for i = 0, 6 do
		tree(folder, V(-202, -1, -120 + i * 40), 1.1, 200 + i)
	end

	skyline(folder, V(-120, -1, -320), V(90, 200, 60), Color3.fromRGB(120, 130, 150), 1)
	skyline(folder, V(60, -1, -340), V(70, 150, 70), Color3.fromRGB(100, 110, 130), 1)
	skyline(folder, V(-320, -1, -40), V(60, 230, 90), Color3.fromRGB(130, 140, 160), 1)
	skyline(folder, V(-300, -1, 120), V(55, 160, 70), Color3.fromRGB(115, 125, 145), 1)
	skyline(folder, V(-100, -1, 300), V(80, 180, 60), Color3.fromRGB(110, 120, 140), -1)
	skyline(folder, V(120, -1, 320), V(70, 140, 70), Color3.fromRGB(120, 128, 150), -1)
end

return Exterior
