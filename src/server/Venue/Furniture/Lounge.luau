--!strict
--------------------------------------------------------------------------------
-- Lounge.luau
-- Soft seating, tables, plants and the break-room appliances.
-- Origin at floor level, front facing -Z, centred on the footprint.
--------------------------------------------------------------------------------

local Kit = require(script.Parent.Parent.Kit)

local COLORS = Kit.COLORS
local V = Vector3.new
local CF = CFrame.new
local M = Enum.Material

local DARK = Color3.fromRGB(34, 35, 40)
local CHROME = Color3.fromRGB(190, 194, 200)
local WALNUT = Color3.fromRGB(96, 66, 44)
local LEAF = { Color3.fromRGB(58, 110, 56), Color3.fromRGB(74, 128, 62), Color3.fromRGB(48, 96, 52) }

--------------------------------------------------------------------------------
-- Couch
-- Contract: two Seats, "CushionL" and "CushionR", unrotated (their LookVector
-- is the couch's facing), centred at Y 1.75 and 0.5 thick. AmbientPopulation
-- sits sleepers 0.85 above the cushion centre.
--------------------------------------------------------------------------------
local function couch(): Model
	local m = Kit.model("Couch")
	local body = Color3.fromRGB(66, 76, 100)
	local cushion = Color3.fromRGB(84, 95, 122)
	Kit.part(m, "Base", V(7.9, 0.9, 3.36), CF(0, 0.85, 0), body, M.Fabric)
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			Kit.trim(m, "Foot", V(0.3, 0.42, 0.3), CF(sx * 3.6, 0.21, sz * 1.4), WALNUT, M.Wood)
		end
		Kit.part(m, "Arm", V(0.8, 1.25, 3.4), CF(sx * 3.6, 1.62, 0), body, M.Fabric)
		Kit.cylZ(m, "ArmRoll", 3.4, 0.82, CF(sx * 3.6, 2.24, 0), body, M.Fabric, { collide = false })
	end
	Kit.part(m, "Back", V(6.4, 2.2, 0.7), CF(0, 2.2, 1.31), body, M.Fabric)
	for _, sx in { -1, 1 } do
		Kit.trim(m, "BackCushion", V(3.15, 1.75, 0.6), CF(sx * 1.6, 2.75, 0.82) * CFrame.Angles(math.rad(10), 0, 0), cushion, M.Fabric)
	end
	Kit.seat(m, "CushionL", V(3.4, 0.5, 2.8), CF(-1.8, 1.75, -0.1), cushion, M.Fabric)
	Kit.seat(m, "CushionR", V(3.4, 0.5, 2.8), CF(1.8, 1.75, -0.1), cushion, M.Fabric)
	Kit.blob(m, "Pillow", V(1.3, 1.1, 0.45), CF(-2.75, 2.5, 0.45) * CFrame.Angles(math.rad(15), math.rad(20), math.rad(10)), Color3.fromRGB(204, 150, 60), M.Fabric, { collide = false })
	return m
end

local function armchair(): Model
	local m = Kit.model("Armchair")
	local body = Color3.fromRGB(122, 70, 52)
	Kit.part(m, "Base", V(3.6, 0.9, 3.2), CF(0, 0.85, 0), body, M.Leather)
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			Kit.trim(m, "Foot", V(0.26, 0.42, 0.26), CF(sx * 1.5, 0.21, sz * 1.3), WALNUT, M.Wood)
		end
		Kit.part(m, "Arm", V(0.6, 1.2, 3.16), CF(sx * 1.6, 1.6, 0), body, M.Leather)
		Kit.cylZ(m, "ArmRoll", 3.2, 0.62, CF(sx * 1.6, 2.2, 0), body, M.Leather, { collide = false })
	end
	Kit.part(m, "Back", V(2.6, 2.4, 0.6), CF(0, 2.3, 1.3) * CFrame.Angles(math.rad(8), 0, 0), body, M.Leather)
	Kit.seat(m, "Cushion", V(2.6, 0.5, 2.6), CF(0, 1.55, -0.15), body:Lerp(Color3.new(1, 1, 1), 0.06), M.Leather)
	return m
end

local function coffeeTable(): Model
	local m = Kit.model("CoffeeTable")
	Kit.part(m, "Top", V(5.5, 0.25, 2.8), CF(0, 1.6, 0), WALNUT, M.Wood)
	Kit.trim(m, "Shelf", V(5.0, 0.12, 2.3), CF(0, 0.5, 0), WALNUT:Lerp(Color3.new(), 0.15), M.Wood)
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			Kit.part(m, "Leg", V(0.24, 1.48, 0.24), CF(sx * 2.45, 0.74, sz * 1.15), DARK, M.Metal)
		end
	end
	for i, c in { Color3.fromRGB(200, 60, 50), Color3.fromRGB(230, 226, 214), Color3.fromRGB(40, 90, 160) } do
		Kit.trim(m, "Magazine", V(1.2, 0.06, 1.6), CF(-1.3, 0.59 + i * 0.065, 0) * CFrame.Angles(0, math.rad(i * 11), 0), c, M.SmoothPlastic)
	end
	Kit.blob(m, "Controller", V(0.8, 0.18, 0.5), CF(1.4, 1.81, 0.3) * CFrame.Angles(0, math.rad(25), 0), DARK, M.SmoothPlastic, { collide = false })
	return m
end

--- Round cafe table. Top surface at Y 3.15 (MapBuilder scatters cups there).
local function bistroTable(): Model
	local m = Kit.model("BistroTable")
	Kit.cylY(m, "Top", 0.14, 4.0, CF(0, 3.08, 0), Color3.fromRGB(232, 232, 228), M.Marble)
	Kit.cylY(m, "Edge", 0.16, 4.06, CF(0, 3.06, 0), DARK, M.Metal, { collide = false })
	Kit.cylY(m, "Pole", 2.9, 0.3, CF(0, 1.55, 0), DARK, M.Metal)
	Kit.cylY(m, "Base", 0.14, 2.2, CF(0, 0.07, 0), DARK, M.Metal)
	Kit.blob(m, "BaseDome", V(1.3, 0.4, 1.3), CF(0, 0.16, 0), DARK, M.Metal, { collide = false })
	return m
end

--- Counter-height stool. The visible cushion sits on an invisible square Seat.
local function stool(): Model
	local m = Kit.model("Stool")
	local seat = Kit.seat(m, "Seat", V(1.3, 0.25, 1.3), CF(0, 2.55, 0), Color3.new(), M.SmoothPlastic)
	seat.Transparency = 1
	Kit.cylY(m, "Cushion", 0.3, 1.5, CF(0, 2.55, 0), Color3.fromRGB(150, 44, 44), M.Leather, { collide = false })
	Kit.cylY(m, "Post", 2.3, 0.2, CF(0, 1.25, 0), CHROME, M.Metal, { collide = false })
	Kit.cylY(m, "FootRing", 0.1, 1.2, CF(0, 0.9, 0), CHROME, M.Metal, { collide = false })
	Kit.cylY(m, "Base", 0.1, 1.3, CF(0, 0.05, 0), CHROME, M.Metal, { collide = false })
	return m
end

--- Beanbag: soft lumps over an invisible Seat named "Bag".
local function beanBag(): Model
	local m = Kit.model("BeanBag")
	local c = Color3.fromRGB(204, 120, 44)
	local seat = Kit.seat(m, "Bag", V(3.2, 1.3, 3.2), CF(0, 0.65, 0), c, M.Fabric)
	seat.Transparency = 1
	Kit.blob(m, "Body", V(3.9, 1.9, 3.9), CF(0, 0.95, 0), c, M.Fabric, { collide = false })
	Kit.blob(m, "BackRise", V(3.2, 1.6, 1.5), CF(0, 1.7, 1.05), c, M.Fabric, { collide = false })
	Kit.blob(m, "Dent", V(2.4, 0.6, 2.2), CF(0, 1.72, -0.2), c:Lerp(Color3.new(), 0.18), M.Fabric, { collide = false })
	return m
end

local function pot(m: Model, h: number, d: number)
	local clay = Color3.fromRGB(214, 206, 192)
	Kit.cylY(m, "Pot", h, d, CF(0, h / 2, 0), clay, M.SmoothPlastic)
	Kit.cylY(m, "Rim", 0.22, d + 0.16, CF(0, h - 0.11, 0), clay:Lerp(Color3.new(), 0.08), M.SmoothPlastic, { collide = false })
	Kit.cylY(m, "Soil", 0.06, d - 0.2, CF(0, h - 0.12, 0), Color3.fromRGB(52, 38, 28), M.Ground, { collide = false })
end

--- A leafy shrub of overlapping lobes rather than one ball.
local function plant(): Model
	local m = Kit.model("Plant")
	pot(m, 1.9, 2.0)
	local lobes = { { 0, 3.6, 0, 3.0 }, { 0.7, 3.0, 0.4, 2.3 }, { -0.8, 3.2, -0.3, 2.4 }, { 0.2, 4.6, -0.5, 2.1 }, { -0.4, 2.6, 0.7, 1.9 } }
	for i, l in lobes do
		Kit.blob(m, "Foliage", V(l[4], l[4] * 0.9, l[4]), CF(l[1], l[2], l[3]), LEAF[(i % #LEAF) + 1], M.Grass, { collide = false })
	end
	return m
end

--- Snake plant: tall blades fanning out of a slim pot.
local function plantTall(): Model
	local m = Kit.model("PlantTall")
	pot(m, 2.2, 1.6)
	for i = 0, 5 do
		local yaw = math.rad(i * 60 + (i % 3) * 7)
		local lean = math.rad(6 + (i % 4) * 4)
		local h = 3.2 + (i % 3) * 0.9
		Kit.trim(
			m,
			"Blade",
			V(0.5, h, 0.08),
			CF(0, 2.1, 0) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(lean, 0, 0) * CF(0, h / 2, 0),
			LEAF[(i % #LEAF) + 1],
			M.Grass
		)
	end
	return m
end

--- Snack machine: glass front over lit rows of product, keypad on the right.
local function vending(): Model
	local m = Kit.model("Vending")
	local shell = Color3.fromRGB(170, 40, 42)
	-- A hollow shell, so the product rows behind the glass are visible.
	Kit.part(m, "Back", V(3.98, 8.4, 0.4), CF(0, 4.6, 1.29), shell, M.SmoothPlastic)
	for _, sx in { -1, 1 } do
		Kit.part(m, "Side", V(0.32, 8.44, 3.04), CF(sx * 1.86, 4.6, 0), shell, M.SmoothPlastic)
	end
	Kit.part(m, "Lower", V(4, 1.85, 3), CF(0, 1.33, 0), shell, M.SmoothPlastic)
	Kit.part(m, "Upper", V(4, 0.65, 3), CF(0, 8.48, 0), shell, M.SmoothPlastic)
	Kit.part(m, "KeyColumn", V(0.8, 5.9, 2.8), CF(1.3, 5.2, -0.1), shell:Lerp(Color3.new(), 0.25), M.SmoothPlastic)
	Kit.part(m, "Plinth", V(3.9, 0.4, 2.9), CF(0, 0.2, 0), DARK, M.SmoothPlastic)
	local glow = Kit.trim(m, "Backlight", V(2.6, 5.6, 0.1), CF(-0.4, 5.2, 1.05), Color3.fromRGB(150, 160, 170), M.Neon)
	Kit.light(glow, 0.5, 9, Color3.fromRGB(200, 220, 255)).Shadows = false
	Kit.tag(glow, Kit.TAGS.EMISSIVE_SCREEN)
	local snacks = { Color3.fromRGB(230, 180, 40), Color3.fromRGB(40, 120, 220), Color3.fromRGB(210, 60, 50), Color3.fromRGB(60, 170, 90), Color3.fromRGB(150, 60, 200) }
	for row = 0, 3 do
		local y = 3.0 + row * 1.35
		Kit.trim(m, "Rack", V(2.6, 0.06, 2.2), CF(-0.4, y - 0.05, -0.2), CHROME, M.Metal)
		for col = 0, 3 do
			local c = snacks[((row + col) % #snacks) + 1]
			Kit.trim(m, "Snack", V(0.5, 0.8, 0.5), CF(-1.35 + col * 0.65, y + 0.4, -0.6), c, M.Foil)
		end
	end
	Kit.part(m, "Glass", V(2.6, 5.9, 0.08), CF(-0.4, 5.2, -1.46), COLORS.GLASS, M.Glass, { transparency = 0.55, reflectance = 0.1 })
	local pad = Kit.trim(m, "Keypad", V(0.9, 2.2, 0.06), CF(1.3, 5.6, -1.52), DARK, M.SmoothPlastic)
	Kit.label(pad, Enum.NormalId.Front, "A1 A2 A3\nB1 B2 B3\nC1 C2 C3\n\n$1.75", Color3.fromRGB(120, 230, 160), nil, Enum.Font.Code, true)
	Kit.trim(m, "CoinSlot", V(0.5, 0.7, 0.06), CF(1.3, 3.9, -1.52), CHROME, M.Metal)
	Kit.trim(m, "Flap", V(2.6, 0.9, 0.08), CF(-0.4, 1.5, -1.52), DARK, M.SmoothPlastic)
	local logo = Kit.trim(m, "Logo", V(3.8, 0.9, 0.06), CF(0, 8.3, -1.52), Color3.fromRGB(26, 26, 30), M.SmoothPlastic)
	Kit.label(logo, Enum.NormalId.Front, "BYTEBITES", Color3.fromRGB(255, 220, 90), nil, Enum.Font.GothamBlack, true)
	return m
end

local function waterCooler(): Model
	local m = Kit.model("WaterCooler")
	local white = Color3.fromRGB(232, 236, 240)
	Kit.part(m, "Body", V(1.6, 3.6, 1.6), CF(0, 1.8, 0), white, M.SmoothPlastic)
	Kit.trim(m, "Recess", V(1.2, 1.0, 0.1), CF(0, 2.5, -0.8), Color3.fromRGB(180, 186, 192), M.SmoothPlastic)
	Kit.trim(m, "DripTray", V(1.0, 0.1, 0.5), CF(0, 2.03, -0.87), DARK, M.SmoothPlastic)
	Kit.trim(m, "TapHot", V(0.2, 0.26, 0.24), CF(-0.3, 2.85, -0.88), Color3.fromRGB(200, 40, 40), M.SmoothPlastic)
	Kit.trim(m, "TapCold", V(0.2, 0.26, 0.24), CF(0.3, 2.85, -0.88), Color3.fromRGB(40, 100, 210), M.SmoothPlastic)
	Kit.cylY(m, "Neck", 0.5, 0.6, CF(0, 3.85, 0), white, M.SmoothPlastic, { collide = false })
	Kit.cylY(m, "Jug", 2.0, 1.5, CF(0, 5.0, 0), Color3.fromRGB(150, 205, 235), M.Glass, { collide = false, transparency = 0.35 })
	Kit.cylY(m, "Water", 1.3, 1.36, CF(0, 4.7, 0), Color3.fromRGB(110, 180, 220), M.Glass, { collide = false, transparency = 0.45 })
	Kit.cylY(m, "Cups", 1.2, 0.36, CF(0.98, 2.6, 0), white, M.SmoothPlastic, { collide = false })
	return m
end

local function fridge(): Model
	local m = Kit.model("Fridge")
	local steel = Color3.fromRGB(188, 192, 198)
	Kit.part(m, "Body", V(3.6, 7.2, 2.8), CF(0, 3.6, 0), steel, M.Metal, { reflectance = 0.08 })
	Kit.trim(m, "Seam", V(3.62, 0.06, 0.04), CF(0, 4.9, -1.41), DARK, M.Metal)
	Kit.trim(m, "HandleTop", V(0.14, 1.4, 0.24), CF(1.4, 5.9, -1.5), CHROME, M.Metal)
	Kit.trim(m, "HandleLow", V(0.14, 2.6, 0.24), CF(1.4, 3.3, -1.5), CHROME, M.Metal)
	local note = Kit.trim(m, "Note", V(1.4, 1.0, 0.03), CF(-0.6, 4.2, -1.41) * CFrame.Angles(0, 0, math.rad(-4)), Color3.fromRGB(250, 240, 150), M.SmoothPlastic)
	Kit.label(note, Enum.NormalId.Front, "DO NOT EAT\nMY LUNCH\n- Dev", Color3.fromRGB(40, 40, 60), nil, Enum.Font.PermanentMarker)
	for i, c in { Color3.fromRGB(220, 60, 60), Color3.fromRGB(60, 140, 220), Color3.fromRGB(70, 170, 90) } do
		Kit.trim(m, "Magnet", V(0.3, 0.3, 0.08), CF(-1.2 + i * 0.5, 6.1, -1.42), c, M.SmoothPlastic)
	end
	return m
end

--------------------------------------------------------------------------------
-- SleepingBag
-- Runs along Z: pillow at -Z, feet at +Z. AmbientPopulation lays a sleeper
-- along it; the quilt is tall enough to hide the sleeper's legs.
--------------------------------------------------------------------------------
local function sleepingBag(): Model
	local m = Kit.model("SleepingBag")
	local c = ({ COLORS.SLEEPING_BAG_1, COLORS.SLEEPING_BAG_2, COLORS.SLEEPING_BAG_3 })[math.random(3)]
	Kit.part(m, "Pad", V(3, 0.5, 6.4), CF(0, 0.3, 0.2), c, M.Fabric)
	Kit.cyl(m, "PadEnd", 3, 0.5, CF(0, 0.3, -3.0), c, M.Fabric, { collide = false })
	Kit.blob(m, "Cover", V(3.2, 1.4, 4.9), CF(0, 0.85, 1.15), c:Lerp(Color3.new(), 0.28), M.Fabric, { collide = false })
	Kit.trim(m, "Zip", V(0.06, 0.06, 6), CF(1.48, 0.55, 0.2), Color3.fromRGB(200, 200, 205), M.Metal)
	Kit.blob(m, "Pillow", V(2.4, 0.7, 1.3), CF(0, 0.85, -2.8), Color3.fromRGB(228, 226, 232), M.Fabric, { collide = false })
	return m
end

--- Floor lamp. The bulb is tagged as a ceiling light so it goes dark in the
--- blackout with everything else.
local function floorLamp(): Model
	local m = Kit.model("FloorLamp")
	local brass = Color3.fromRGB(176, 146, 92)
	Kit.cylY(m, "Base", 0.2, 1.4, CF(0, 0.1, 0), DARK, M.Metal)
	Kit.cylY(m, "Pole", 6.2, 0.14, CF(0, 3.2, 0), brass, M.Metal, { collide = false })
	Kit.cylY(m, "Shade", 1.2, 1.7, CF(0, 6.6, 0), Color3.fromRGB(236, 224, 196), M.Fabric, { collide = false, transparency = 0.15 })
	-- glow only: a light per lamp would eat into the renderer's light budget
	local bulb = Kit.blob(m, "Bulb", V(0.5, 0.6, 0.5), CF(0, 6.4, 0), Color3.fromRGB(255, 226, 170), M.Neon, { collide = false })
	Kit.tag(bulb, Kit.TAGS.CEILING_LIGHT)
	return m
end

return {
	builders = {
		Couch = couch,
		Armchair = armchair,
		CoffeeTable = coffeeTable,
		BistroTable = bistroTable,
		Stool = stool,
		BeanBag = beanBag,
		Plant = plant,
		PlantTall = plantTall,
		Vending = vending,
		WaterCooler = waterCooler,
		Fridge = fridge,
		SleepingBag = sleepingBag,
		FloorLamp = floorLamp,
	} :: { [string]: () -> Model },
}
