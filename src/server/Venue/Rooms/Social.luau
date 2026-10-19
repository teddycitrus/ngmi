--!strict
--------------------------------------------------------------------------------
-- Social.luau
-- Lounges, break rooms and the library.
--
-- Contracts kept from the old MapBuilder: the lounge's main couch CushionR is
-- tagged CouchSeat, and each lounge has a SleepSpot marker (Yaw attribute)
-- and a LeanSpot on its west wall.
--------------------------------------------------------------------------------

local Venue = script.Parent.Parent
local Kit = require(Venue.Kit)
local Layout = require(Venue.Layout)
local Decor = require(Venue.Decor)
local AssetLibrary = require(Venue.Parent.AssetLibrary)

local V = Vector3.new
local CF = CFrame.new
local M = Enum.Material
local TAGS = Kit.TAGS

local Social = {}

type Cell = Layout.Cell
type Ctx = { playerDesks: boolean?, boss: boolean? }

local function farSide(c: Cell): (number, number)
	if c.side == "south" then
		return c.maxZ, -1
	end
	return c.minZ, 1
end

--- Place a template so its front looks along `face`.
local function facing(name: string, pos: Vector3, face: Vector3, parent: Instance): Model?
	local m = AssetLibrary.clone(name, CFrame.lookAt(pos, pos + face))
	if m then
		m.Parent = parent
	end
	return m
end

local function marker(parent: Instance, name: string, pos: Vector3, tagName: string): Part
	local m = Kit.part(parent, name, V(1.5, 0.2, 1.5), pos, Color3.new(), nil, { collide = false, transparency = 1 })
	Kit.tag(m, tagName)
	return m
end

function Social.lounge(parent: Instance, c: Cell, level: number, _ctx: Ctx)
	local y = Layout.floorY(level)
	local cx, cz = (c.minX + c.maxX) / 2, (c.minZ + c.maxZ) / 2
	local farZ, inDir = farSide(c)
	local nearZ = if inDir < 0 then c.minZ else c.maxZ
	local toTV = V(0, 0, -inDir)
	local mid = farZ + inDir * 9

	Kit.trim(parent, "Rug", V(20, 0.05, 15), V(cx, y + 0.13, mid), Color3.fromRGB(116, 62, 70), M.Fabric, { shadow = false })
	Kit.trim(parent, "RugBorder", V(21, 0.04, 16), V(cx, y + 0.12, mid), Color3.fromRGB(196, 170, 120), M.Fabric, { shadow = false })
	Decor.onWall(parent, "TV", V(cx, y, farZ), V(0, 0, inDir))
	Decor.onWall(parent, "Credenza", V(cx, y, farZ), V(0, 0, inDir))
	local main = facing("Couch", V(cx, y, farZ + inDir * 15), toTV, parent)
	facing("Couch", V(cx - 9.5, y, mid), V(1, 0, 0), parent)
	facing("Couch", V(cx + 9.5, y, mid), V(-1, 0, 0), parent)
	Decor.place("CoffeeTable", cx, y, mid, 0, parent)
	Decor.place("BeanBag", cx - 5, y, farZ + inDir * 4.6, 20, parent)
	Decor.place("BeanBag", cx + 5, y, farZ + inDir * 4.6, -15, parent)
	facing("Armchair", V(c.minX + 4, y, nearZ - inDir * 5), V(1, 0, -inDir * 0.6).Unit, parent)
	Decor.place("FloorLamp", c.minX + 2.5, y, nearZ - inDir * 9, 0, parent)
	Decor.place("FloorLamp", cx + 12.5, y, farZ + inDir * 15, 0, parent)
	Decor.place("PlantTall", c.minX + 2.6, y, farZ + inDir * 2.6, 0, parent)
	Decor.place("Plant", c.maxX - 2.8, y, farZ + inDir * 2.8, 0, parent)
	Decor.onWall(parent, "Bookshelf", V(c.minX, y, mid), V(1, 0, 0))

	-- neon sign on the far wall above the TV
	local sp = V(cx, y + 12.4, farZ + inDir * 0.95)
	local neon = Kit.trim(parent, "NeonSign", V(7, 1.2, 0.1), CFrame.lookAt(sp, sp + V(0, 0, inDir)), Color3.new(), M.Neon, { transparency = 1 })
	Kit.label(neon, Enum.NormalId.Front, "chill zone", Color3.fromRGB(255, 90, 200), nil, Enum.Font.FredokaOne, true)

	Decor.scatter(parent, cx - 2.5, cx + 2.5, mid - 1.2, mid + 1.2, y + 1.73, math.random(3, 5))
	Decor.scatter(parent, c.minX + 4, c.maxX - 4, c.minZ + 4, c.maxZ - 4, y + 0.1, math.random(6, 10))

	if main then
		local cushion = main:FindFirstChild("CushionR")
		if cushion then
			Kit.tag(cushion, TAGS.COUCH_SEAT)
		end
	end
	local sleep = marker(parent, "SleepSpot_Lounge_" .. level, V(c.maxX - 6, y + 0.15, nearZ - inDir * 6), TAGS.SLEEP_SPOT)
	sleep:SetAttribute("Yaw", 90)
	local lean = marker(parent, "LeanSpot_Lounge_" .. level, V(c.minX + 1.6, y + 0.2, cz), TAGS.LEAN_SPOT)
	lean:SetAttribute("Face", V(1, 0, 0))
end

--- Kitchen run along the far wall: base cabinets, sink, uppers, appliances.
local function kitchen(parent: Instance, x0: number, x1: number, y: number, farZ: number, inDir: number)
	local face = farZ + inDir * (Layout.WALL_T / 2 + 0.15)
	local len = x1 - x0
	local cx = (x0 + x1) / 2
	local cab = Color3.fromRGB(62, 92, 100)
	local function z(off: number): number
		return face + inDir * off
	end
	Kit.part(parent, "Cabinets", V(len, 2.8, 2.3), V(cx, y + 1.5, z(1.15)), cab, M.SmoothPlastic)
	Kit.trim(parent, "Kick", V(len - 0.2, 0.3, 2.1), V(cx, y + 0.15, z(1.0)), Color3.fromRGB(30, 30, 34), M.SmoothPlastic)
	Kit.part(parent, "Counter", V(len + 0.2, 0.2, 2.6), V(cx, y + 3.0, z(1.3)), Color3.fromRGB(46, 46, 50), M.Granite)
	Kit.trim(parent, "Backsplash", V(len, 2.4, 0.08), V(cx, y + 4.3, z(0.06)), Color3.fromRGB(226, 228, 224), M.CeramicTiles)
	local n = math.floor(len / 2.4)
	for i = 0, n - 1 do
		local x = x0 + (i + 0.5) * len / n
		Kit.trim(parent, "CabDoor", V(len / n - 0.15, 2.2, 0.05), V(x, y + 1.65, z(2.32)), cab:Lerp(Color3.new(1, 1, 1), 0.08), M.SmoothPlastic)
		Kit.trim(parent, "Pull", V(0.08, 0.6, 0.08), V(x + 0.6, y + 2.3, z(2.38)), Color3.fromRGB(190, 194, 200), M.Metal)
		Kit.part(parent, "UpperCab", V(len / n - 0.1, 2.8, 1.4), V(x, y + 7.2, z(0.7)), cab, M.SmoothPlastic)
		Kit.trim(parent, "UpperDoor", V(len / n - 0.25, 2.6, 0.05), V(x, y + 7.2, z(1.42)), cab:Lerp(Color3.new(1, 1, 1), 0.08), M.SmoothPlastic)
	end
	-- sink, microwave, coffee machine
	local sx = x0 + len * 0.3
	Kit.trim(parent, "Sink", V(2.4, 0.08, 1.6), V(sx, y + 3.11, z(1.3)), Color3.fromRGB(150, 154, 160), M.Metal)
	Kit.cylY(parent, "Faucet", 1.0, 0.16, V(sx, y + 3.6, z(0.35)), Color3.fromRGB(196, 200, 206), M.Metal, { collide = false })
	Kit.trim(parent, "Spout", V(0.12, 0.12, 0.8), V(sx, y + 4.05, z(0.7)), Color3.fromRGB(196, 200, 206), M.Metal)
	local mx = x0 + len * 0.62
	Kit.part(parent, "Microwave", V(2.0, 1.1, 1.4), V(mx, y + 3.65, z(0.9)), Color3.fromRGB(30, 30, 34), M.SmoothPlastic)
	Kit.trim(parent, "MicrowaveGlass", V(1.2, 0.8, 0.04), V(mx - 0.3, y + 3.65, z(1.62)), Color3.fromRGB(16, 18, 22), M.Glass)
	local cfx = x0 + len * 0.82
	Kit.part(parent, "CoffeeMachine", V(1.1, 1.6, 1.2), V(cfx, y + 3.9, z(0.8)), Color3.fromRGB(150, 30, 30), M.SmoothPlastic)
	Kit.cylY(parent, "CoffeePot", 0.6, 0.6, V(cfx, y + 3.4, z(1.5)), Color3.fromRGB(40, 30, 24), M.Glass, { collide = false, transparency = 0.2 })
end

function Social.breakroom(parent: Instance, c: Cell, level: number, _ctx: Ctx)
	local y = Layout.floorY(level)
	local cx = (c.minX + c.maxX) / 2
	local farZ, inDir = farSide(c)
	local out = V(0, 0, inDir)

	Decor.onWall(parent, "Vending", V(c.minX + 3.2, y, farZ), out)
	Decor.onWall(parent, "Vending", V(c.minX + 7.6, y, farZ), out)
	kitchen(parent, c.minX + 10.4, c.maxX - 11, y, farZ, inDir)
	Decor.onWall(parent, "Fridge", V(c.maxX - 8.6, y, farZ), out)
	Decor.onWall(parent, "WaterCooler", V(c.maxX - 4, y, farZ), out)

	local tz = farZ + inDir * 13
	for _, sign in { -1, 1 } do
		local tx = cx + sign * 9
		Decor.place("BistroTable", tx, y, tz, 0, parent)
		for k = 0, 2 do
			local a = math.rad(k * 120 + 30)
			Decor.place("Stool", tx + math.cos(a) * 2.9, y, tz + math.sin(a) * 2.9, 0, parent)
		end
		Decor.scatter(parent, tx - 1.4, tx + 1.4, tz - 1.4, tz + 1.4, y + 3.15, math.random(2, 4))
	end
	-- west wall: the east wall has a door whose leaf folds back along it
	Decor.onWall(parent, "TrashBin", V(c.minX, y, tz - inDir * 6), V(1, 0, 0))
	Decor.onWall(parent, "NoticeBoard", V(c.minX, y, tz), V(1, 0, 0))
	Decor.place("Plant", c.minX + 2.8, y, tz + inDir * 7, 0, parent)
	Decor.scatter(parent, c.minX + 4, c.maxX - 4, c.minZ + 4, c.maxZ - 4, y + 0.1, math.random(10, 15))
end

local function bankerLamp(parent: Instance, pos: Vector3, lit: boolean)
	local brass = Color3.fromRGB(176, 146, 92)
	Kit.trim(parent, "LampBase", V(0.7, 0.12, 0.5), pos + V(0, 0.06, 0), brass, M.Metal)
	Kit.trim(parent, "LampStem", V(0.08, 1.1, 0.08), pos + V(0, 0.6, 0.1), brass, M.Metal)
	local shade = Kit.cyl(parent, "LampShade", 1.2, 0.5, CF(pos + V(0, 1.15, -0.05)), Color3.fromRGB(30, 110, 60), M.Glass, { collide = false, transparency = 0.1 })
	if lit then
		Kit.light(shade, 0.5, 9, Color3.fromRGB(255, 220, 160))
		Kit.tag(shade, TAGS.CEILING_LIGHT)
	end
end

--- Book stacks on the west half, reading tables and armchairs on the east.
function Social.library(parent: Instance, c: Cell, level: number, _ctx: Ctx)
	local y = Layout.floorY(level)
	local cx, cz = (c.minX + c.maxX) / 2, (c.minZ + c.maxZ) / 2
	local farZ, inDir = farSide(c)
	local stackX = c.minX + 22
	for _, dz in { -8, 0, 8 } do
		for k = -1, 1 do
			local x = stackX + k * 6.45
			-- back to back: the -Z one faces -Z, the +Z one faces +Z
			Decor.place("Bookshelf", x, y, cz + dz - 1.16, 0, parent)
			Decor.place("Bookshelf", x, y, cz + dz + 1.16, 180, parent)
		end
		local endCap = Kit.trim(parent, "StackLabel", V(0.1, 0.9, 3.6), V(stackX + 9.75, y + 8.3, cz + dz), Layout.ACCENT[level + 1], M.SmoothPlastic)
		Kit.label(endCap, Enum.NormalId.Right, ({ "000-299", "300-599", "600-999" })[(dz / 8) + 2], Color3.new(1, 1, 1), nil, Enum.Font.GothamBold)
	end

	local wood = Color3.fromRGB(110, 76, 50)
	for _, tx in { cx + 4, cx + 26 } do
		for _, tz in { cz - 6.5, cz + 6.5 } do
			Kit.part(parent, "ReadingTable", V(10, 0.25, 4), V(tx, y + 3.12, tz), wood, M.Wood)
			for _, sx in { -1, 1 } do
				Kit.part(parent, "TableLeg", V(0.4, 3, 3.4), V(tx + sx * 4.4, y + 1.5, tz), wood:Lerp(Color3.new(), 0.2), M.Wood)
				Decor.place("OfficeChair", tx + sx * 2.5, y, tz + 3.4, 0, parent)
				Decor.place("OfficeChair", tx + sx * 2.5, y, tz - 3.4, 180, parent)
			end
			bankerLamp(parent, V(tx - 2.5, y + 3.25, tz), true)
			bankerLamp(parent, V(tx + 2.5, y + 3.25, tz), false)
			Decor.scatter(parent, tx - 4, tx + 4, tz - 1.4, tz + 1.4, y + 3.25, math.random(1, 3))
		end
	end
	for k = 0, 2 do
		facing("Armchair", V(c.maxX - 5 - k * 6, y, farZ + inDir * 4), V(0, 0, inDir), parent)
	end
	Decor.place("FloorLamp", c.maxX - 2.4, y, farZ + inDir * 2.4, 0, parent)
	local sp = V(cx + 15, y + 10.5, farZ + inDir * 0.95)
	local sign = Kit.trim(parent, "QuietSign", V(8, 1.4, 0.1), CFrame.lookAt(sp, sp + V(0, 0, inDir)), Color3.fromRGB(30, 32, 38), M.SmoothPlastic)
	Kit.label(sign, Enum.NormalId.Front, "QUIET PLEASE", Color3.fromRGB(236, 230, 210), nil, Enum.Font.Garamond)
	Decor.place("PlantTall", c.minX + 2.5, y, farZ + inDir * 2.5, 0, parent)
	Decor.scatter(parent, c.minX + 4, c.maxX - 4, c.minZ + 4, c.maxZ - 4, y + 0.1, math.random(4, 7))
end

return Social
