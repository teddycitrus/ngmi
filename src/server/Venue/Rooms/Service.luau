--!strict
--------------------------------------------------------------------------------
-- Service.luau
-- Restrooms and supply closets.
--
-- Contracts kept from the old MapBuilder:
--   * restroom: a plunger ItemSpawn, a HidingSpot in the far stall, and on the
--     boss floor the PoopMonsterSpawn + NGMISpawn_Boss markers;
--   * supply: ItemSpawns resting on the Shelf boards, an ElectricalPanel part
--     (0.6 x 3 x 2.4) proud of the west wall, and a ServerRack model whose
--     "RackBody" carries the disabled Repair prompt and whose "Status" part
--     PowerManager recolours.
--------------------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Venue = script.Parent.Parent
local Kit = require(Venue.Kit)
local Layout = require(Venue.Layout)
local Decor = require(Venue.Decor)
local Walls = require(Venue.Walls)
local ItemConfig = require(ReplicatedStorage.Shared.ItemConfig)

local V = Vector3.new
local CF = CFrame.new
local M = Enum.Material
local TAGS = Kit.TAGS
local COLORS = Kit.COLORS

local Service = {}

type Cell = Layout.Cell
type Ctx = { playerDesks: boolean?, boss: boolean? }

local function farSide(c: Cell): (number, number)
	if c.side == "south" then
		return c.maxZ, -1
	end
	return c.minZ, 1
end

local function marker(parent: Instance, name: string, pos: Vector3, tagName: string): Part
	local m = Kit.part(parent, name, V(1.5, 0.2, 1.5), pos, Color3.new(), nil, { collide = false, transparency = 1 })
	Kit.tag(m, tagName)
	return m
end

local function itemSpawn(itemId: string, pos: Vector3, parent: Instance)
	local m = Kit.part(parent, "ItemSpawn_" .. itemId, V(1, 1, 1), pos, Color3.new(), nil, { collide = false, transparency = 1 })
	m:SetAttribute("ItemId", itemId)
	Kit.tag(m, TAGS.ITEM_SPAWN)
end

-- Tops of the Shelf template's boards, relative to its floor origin.
local SHELF_BOARD_TOP = { 2.2, 5.2, 8.2 }

--- An item resting on a shelf board (shelf rotated by `yaw`).
local function shelfItem(itemId: string, shelf: CFrame, board: number, xOffset: number, parent: Instance)
	local def = ItemConfig.items[itemId]
	local half = if def then def.modelSize.Y / 2 else 0.5
	local p = shelf * CF(xOffset, (SHELF_BOARD_TOP[board] or SHELF_BOARD_TOP[1]) + half, 0)
	itemSpawn(itemId, p.Position, parent)
end

--- Tile skin over the inside face of a restroom wall, up to 7 studs, with
--- gaps for doors. `a`/`b` are wall centre-line endpoints at floor height.
local function tileSkin(parent: Instance, a: Vector3, b: Vector3, inward: Vector3, skip: { { number } })
	local dir = (b - a).Unit
	local len = (b - a).Magnitude
	local origin = a + inward * (Layout.WALL_T / 2 + 0.08)
	local from = 0
	local runs: { { number } } = {}
	for _, s in skip do
		table.insert(runs, { from, s[1] })
		from = s[2]
	end
	table.insert(runs, { from, len })
	for _, r in runs do
		Walls.piece(parent, origin, dir, r[1], r[2], a.Y, a.Y + 7, 0.16, COLORS.TILE_WALL, M.CeramicTiles, "Tile", false)
		Walls.piece(parent, origin + inward * 0.02, dir, r[1], r[2], a.Y + 7, a.Y + 7.25, 0.2, Color3.fromRGB(60, 120, 130), M.CeramicTiles, "TileCap", false)
	end
end

function Service.bath(parent: Instance, c: Cell, level: number, ctx: Ctx)
	local y = Layout.floorY(level)
	local cx, cz = (c.minX + c.maxX) / 2, (c.minZ + c.maxZ) / 2
	local width = c.maxX - c.minX
	local depth = c.maxZ - c.minZ
	local backZ, intoRoom = farSide(c)
	local doorZ = if intoRoom < 0 then c.minZ else c.maxZ

	-- tile skin on all four walls (door wall split round the door)
	local inset = Layout.WALL_T / 2
	local x0, x1 = c.minX + inset, c.maxX - inset
	local z0, z1 = c.minZ + inset, c.maxZ - inset
	tileSkin(parent, V(x0, y, backZ), V(x1, y, backZ), V(0, 0, intoRoom), {})
	tileSkin(parent, V(x0, y, doorZ), V(x1, y, doorZ), V(0, 0, -intoRoom), { { width / 2 - inset - 3.2, width / 2 - inset + 3.2 } })
	tileSkin(parent, V(c.minX, y, z0 + 0.25), V(c.minX, y, z1 - 0.25), V(1, 0, 0), {})
	tileSkin(parent, V(c.maxX, y, z0 + 0.25), V(c.maxX, y, z1 - 0.25), V(-1, 0, 0), {})

	-- stalls along the back wall
	local stallW, stallD = 5, 6.4
	local n = math.clamp(math.floor((width - 10) / stallW), 2, 5)
	local startX = cx - n * stallW / 2
	local face = backZ + intoRoom * (Layout.WALL_T / 2 + 0.24)
	local frontZ = face + intoRoom * stallD
	local lam = Color3.fromRGB(86, 96, 112)
	local steel = Color3.fromRGB(176, 180, 186)
	for i = 0, n do
		local sx = startX + i * stallW
		Kit.part(parent, "StallSide", V(0.15, 5.6, stallD - 0.4), V(sx, y + 3.8, face + intoRoom * (stallD - 0.4) / 2), lam, M.SmoothPlastic)
		Kit.part(parent, "Pilaster", V(0.5, 7.6, 0.2), V(sx, y + 3.8, frontZ), lam, M.SmoothPlastic)
	end
	Kit.trim(parent, "Headrail", V(n * stallW + 0.6, 0.18, 0.24), V(cx, y + 7.7, frontZ), steel, M.Metal)
	for i = 0, n - 1 do
		local mid = startX + (i + 0.5) * stallW
		Decor.place("Toilet", mid, y, face + intoRoom * 1.45, if intoRoom < 0 then 0 else 180, parent)
		-- door hinged on its left pilaster, a few left ajar
		local swing = if i % 3 == 1 then math.rad(-55) * intoRoom else 0
		local hinge = CF(mid - stallW / 2 + 0.3, y, frontZ)
		local cf = hinge * CFrame.Angles(0, swing, 0) * CF((stallW - 0.6) / 2, 3.8, 0)
		Kit.trim(parent, "StallDoor", V(stallW - 0.6, 5.6, 0.12), cf, lam:Lerp(Color3.new(1, 1, 1), 0.08), M.SmoothPlastic)
		Kit.trim(parent, "Latch", V(0.3, 0.2, 0.2), cf * CF((stallW - 0.6) / 2 - 0.3, 0, 0), steel, M.Metal)
		Kit.cylZ(parent, "Paper", 0.5, 0.5, V(mid + stallW / 2 - 0.45, y + 2.6, face + intoRoom * 2.5), Color3.fromRGB(246, 246, 242), M.Fabric, { collide = false })
	end

	-- vanity on the west wall: counter, basins, faucets, mirror, dryer
	local wallFace = c.minX + Layout.WALL_T / 2 + 0.24
	local counterL = math.max(8, depth - 13)
	local vz = cz - intoRoom * 1.5
	Kit.part(parent, "Vanity", V(2.4, 0.3, counterL), V(wallFace + 1.2, y + 2.9, vz), Color3.fromRGB(42, 42, 46), M.Granite)
	Kit.trim(parent, "VanitySkirt", V(0.1, 0.8, counterL - 0.04), V(wallFace + 2.36, y + 2.5, vz), Color3.fromRGB(42, 42, 46), M.Granite)
	local sinks = math.clamp(math.floor(counterL / 4), 2, 5)
	for i = 0, sinks - 1 do
		local sz = vz - counterL / 2 + counterL * (i + 0.5) / sinks
		Kit.blob(parent, "Basin", V(1.5, 0.5, 2.0), V(wallFace + 1.3, y + 2.86, sz), COLORS.TOILET, M.SmoothPlastic, { collide = false })
		Kit.cylY(parent, "Faucet", 0.7, 0.14, V(wallFace + 0.35, y + 3.4, sz), Color3.fromRGB(200, 204, 210), M.Metal, { collide = false })
		Kit.trim(parent, "Spout", V(0.6, 0.1, 0.1), V(wallFace + 0.62, y + 3.72, sz), Color3.fromRGB(200, 204, 210), M.Metal)
		Kit.trim(parent, "Soap", V(0.3, 0.6, 0.3), V(wallFace + 0.2, y + 4.4, sz + 0.9), Color3.fromRGB(230, 232, 236), M.SmoothPlastic)
	end
	Kit.trim(parent, "MirrorFrame", V(0.1, 4.4, counterL + 0.4), V(wallFace + 0.02, y + 6.2, vz), steel, M.Metal)
	Kit.part(parent, "Mirror", V(0.06, 4, counterL), V(wallFace + 0.08, y + 6.2, vz), Color3.fromRGB(200, 214, 226), M.Glass, { reflectance = 0.55, collide = false })
	Decor.onWall(parent, "HandDryer", V(c.minX, y, vz + intoRoom * (counterL / 2 + 2.2)), V(1, 0, 0))
	Decor.onWall(parent, "TrashBin", V(c.minX, y, vz - intoRoom * (counterL / 2 + 2.2)), V(1, 0, 0))

	-- urinals on the east wall with privacy screens between
	for i = 0, 2 do
		local uz = cz - intoRoom * 1.5 - 4.5 + i * 4.5
		Decor.onWall(parent, "Urinal", V(c.maxX, y, uz), V(-1, 0, 0))
		if i < 2 then
			Kit.part(parent, "UrinalScreen", V(2.2, 3.6, 0.15), V(c.maxX - Layout.WALL_T / 2 - 1.4, y + 3.4, uz + 2.25), lam, M.SmoothPlastic)
		end
	end

	-- cold tube light; dies in the blackout with the rest
	local lt = Kit.trim(parent, "BathLight", V(1, 0.2, 6), V(cx, y + Layout.CEIL_H - 0.12, cz), Color3.fromRGB(226, 240, 255), M.Neon)
	Kit.light(lt, 0.65, 20, Color3.fromRGB(220, 235, 255))
	Kit.tag(lt, TAGS.CEILING_LIGHT)

	local farStall = startX + (n - 0.5) * stallW
	local hide = Kit.part(parent, "HideSpot", V(3, 2.5, 3), V(farStall, y + 1.3, face + intoRoom * 2.6), Color3.new(), nil, { collide = false, transparency = 1 })
	Kit.tag(hide, TAGS.HIDING_SPOT)
	-- the only plungers in the building turn up in restrooms
	itemSpawn("plunger", V(startX - 1.2, y + 1.6, face + intoRoom * 3), parent)

	if ctx.boss then
		local p = V(cx, y + 1, face + intoRoom * 3)
		marker(parent, "PoopMonsterSpawn", p, TAGS.POOP_MONSTER_SPAWN)
		marker(parent, "NGMISpawn_Boss", p, TAGS.NGMI_SPAWN)
	end
end

--- Server rack: the shell, rows of servers with blinking LEDs, a status lamp.
local function serverRack(parent: Instance, pos: Vector3)
	local rack = Instance.new("Model")
	rack.Name = "ServerRack"
	local body = Kit.part(rack, "RackBody", V(2.4, 8, 3), pos + V(0, 4, 0), COLORS.SERVER_RACK, M.Metal)
	local face = pos.X + 1.22
	for i = 0, 9 do
		local sy = pos.Y + 1.0 + i * 0.66
		Kit.trim(rack, "Server", V(0.06, 0.5, 2.6), V(face, sy, pos.Z), Color3.fromRGB(28, 30, 34), M.Metal)
		Kit.trim(rack, "Blink", V(0.06, 0.12, 0.12), V(face + 0.03, sy, pos.Z + 1.0 - (i % 3) * 0.2), Color3.fromRGB(70, 90, 110), M.Neon)
	end
	local status = Kit.trim(rack, "Status", V(0.3, 0.6, 0.3), pos + V(1.2, 7.3, 0), Color3.fromRGB(220, 60, 50), M.Neon)
	-- the rack's fault light picks out a blacked-out closet
	Kit.light(status, 0.6, 10, Color3.fromRGB(220, 60, 50))
	Kit.tag(status, TAGS.EMISSIVE_SCREEN)
	Kit.trim(rack, "CableBundle", V(0.8, Layout.CEIL_H - 8, 0.8), pos + V(-0.4, 8 + (Layout.CEIL_H - 8) / 2, 0.6), Color3.fromRGB(30, 60, 140), M.Rubber)
	local p = Instance.new("ProximityPrompt")
	p.ActionText = "Repair Server"
	p.ObjectText = "Server Rack"
	p.HoldDuration = 2
	p.MaxActivationDistance = 8
	p.RequiresLineOfSight = false
	p.Enabled = false -- PowerManager enables it once the floor has power
	p.Parent = body
	rack.PrimaryPart = body
	Kit.tag(rack, TAGS.SERVER_RACK)
	rack.Parent = parent
end

function Service.supply(parent: Instance, c: Cell, level: number, _ctx: Ctx)
	local y = Layout.floorY(level)
	local cx, cz = (c.minX + c.maxX) / 2, (c.minZ + c.maxZ) / 2
	local farZ, inDir = farSide(c)
	local out = V(0, 0, inDir)

	-- two shelving units on the far wall, items resting on their boards
	local shelves: { CFrame } = {}
	for _, dx in { -7, 7 } do
		local pos = V(cx + dx, y, farZ + inDir * (Layout.WALL_T / 2 + 0.15 + 1))
		local cf = CFrame.lookAt(pos, pos + out)
		Decor.onWall(parent, "Shelf", V(cx + dx, y, farZ), out)
		table.insert(shelves, cf)
	end
	local left, right = shelves[1], shelves[2]
	shelfItem("deodorant", left, 1, -3, parent)
	shelfItem("energy_bar", left, 1, 1.5, parent)
	shelfItem("battery", left, 2, -1, parent)
	shelfItem("energy_bar", right, 1, -2, parent)
	shelfItem("deodorant", right, 2, 2, parent)
	shelfItem("battery", right, 2, -2.5, parent)
	if level == 0 then
		shelfItem("deodorant", right, 1, 3, parent)
	end

	-- Electrical panel proud of the west wall (its prompt needs line of sight
	-- from the room), with conduit running up to the ceiling.
	local panelZ = c.minZ + 4
	local panel = Kit.part(parent, "ElectricalPanel", V(0.6, 3, 2.4), V(c.minX + 1.05, y + 3.2, panelZ), Color3.fromRGB(150, 154, 160), M.Metal)
	Kit.tag(panel, TAGS.ELECTRICAL_PANEL)
	Kit.trim(parent, "PanelDoorSeam", V(0.04, 2.6, 0.04), V(c.minX + 1.37, y + 3.2, panelZ), Color3.fromRGB(60, 62, 66), M.Metal)
	local warn = Kit.trim(parent, "PanelWarning", V(0.04, 0.6, 1.2), V(c.minX + 1.39, y + 4.2, panelZ - 0.4), Color3.fromRGB(240, 196, 30), M.SmoothPlastic)
	Kit.label(warn, Enum.NormalId.Right, "DANGER\nHIGH VOLTAGE", Color3.fromRGB(20, 20, 20), nil, Enum.Font.GothamBlack)
	for _, dz in { -0.6, 0, 0.6 } do
		Kit.cylY(parent, "Conduit", Layout.CEIL_H - 4.7, 0.22, V(c.minX + 0.95, y + 4.7 + (Layout.CEIL_H - 4.7) / 2, panelZ + dz), Color3.fromRGB(170, 172, 176), M.Metal, { collide = false })
	end

	serverRack(parent, V(c.minX + Layout.WALL_T / 2 + 1.35, y, cz + 3))

	-- janitorial clutter by the door
	local nearZ = if inDir < 0 then c.minZ else c.maxZ
	Kit.cylY(parent, "MopBucket", 1.4, 1.8, V(c.maxX - 3, y + 0.7, nearZ - inDir * 3.5), Color3.fromRGB(220, 180, 30), M.SmoothPlastic)
	Kit.trim(parent, "MopHandle", V(0.14, 5.5, 0.14), CF(c.maxX - 3.2, y + 3, nearZ - inDir * 3.4) * CFrame.Angles(0, 0, math.rad(-12)), Color3.fromRGB(150, 110, 70), M.Wood)
	for i = 0, 2 do
		Kit.part(parent, "Box", V(2.4, 1.6, 2), V(c.maxX - 3, y + 0.8 + i * 1.6, cz + 4), Color3.fromRGB(176, 140, 96):Lerp(Color3.new(), i * 0.05), M.Cardboard)
	end
	Decor.scatter(parent, c.minX + 6, c.maxX - 6, cz - 5, cz + 5, y + 0.1, math.random(3, 6))
end

return Service
