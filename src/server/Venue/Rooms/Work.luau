--!strict
--------------------------------------------------------------------------------
-- Work.luau
-- Labs, the Hack Hall and meeting rooms. Builders get the room's cell and
-- fill it; walls, floor finish, lights and signage come from Builder.
--
-- Contracts kept from the old MapBuilder:
--   * the player-desk lab tags exactly 4 desks PlayerDesk with DeskId
--     desk_1..desk_4 and removes their typist markers;
--   * every other typist marker ("Seat") is tagged DeskSeat with FaceZ = the
--     world Z direction the typist faces;
--   * the player-desk lab gets one of the QuestChairs (placed by Builder via
--     QuestChairs after content, so it can find free floor).
--------------------------------------------------------------------------------

local Venue = script.Parent.Parent
local Kit = require(Venue.Kit)
local Layout = require(Venue.Layout)
local Decor = require(Venue.Decor)
local Closet = require(Venue.Closet)
local AssetLibrary = require(Venue.Parent.AssetLibrary)

local V = Vector3.new
local CF = CFrame.new
local M = Enum.Material
local TAGS = Kit.TAGS

local Work = {}

type Cell = Layout.Cell
export type Ctx = { playerDesks: boolean?, boss: boolean? }

local function farSide(c: Cell): (number, number)
	-- the wall opposite the door, and the direction from it into the room
	if c.side == "south" then
		return c.maxZ, -1
	end
	return c.minZ, 1
end

--- A hiding closet standing against the far wall at world X `x`, door
--- facing into the room.
local function closet(parent: Instance, c: Cell, level: number, x: number)
	local farZ, inDir = farSide(c)
	local z = farZ + inDir * (Layout.WALL_T / 2 + Closet.D / 2 + 0.05)
	local base = V(x, Layout.floorY(level), z)
	Closet.build(parent, CFrame.lookAt(base, base + V(0, 0, inDir)))
end

-- Counts across the whole player-desk lab so exactly four desks get tagged.
type DeskState = { idx: number, player: number, makePlayer: boolean, level: number }

--- One desk of a pod. yaw 0 puts the chair on +Z.
local function desk(parent: Instance, x: number, y: number, z: number, yaw: number, st: DeskState)
	local station = AssetLibrary.clone("Workstation", CF(x, y, z) * CFrame.Angles(0, math.rad(yaw), 0))
	if not station then
		return
	end
	station.Parent = parent
	st.idx += 1
	local top = station:FindFirstChild("Desk")
	local seat = station:FindFirstChild("Seat")
	if st.makePlayer and st.player < 4 then
		st.player += 1
		if top then
			Kit.tag(top, TAGS.PLAYER_DESK)
			top:SetAttribute("DeskId", "desk_" .. st.player)
		end
		if seat then
			seat:Destroy()
		end
		return
	end
	if seat and (st.idx + st.level) % 6 ~= 0 then
		Kit.tag(seat, TAGS.DESK_SEAT)
		seat:SetAttribute("FaceZ", if yaw == 0 then -1 else 1)
	elseif seat then
		seat:Destroy()
	end
	if math.random() < 0.7 then
		Decor.scatter(parent, x - 2.6, x - 1.2, z - 0.6, z + 0.6, y + 2.75, math.random(1, 2)) -- on the desk top (Office.DESK_TOP)
	end
end

--- A pod: two rows of `n` desks back to back, monitors meeting in the middle.
local function pod(parent: Instance, cx: number, y: number, pz: number, n: number, st: DeskState)
	for k = 1, n do
		local x = cx + (k - (n + 1) / 2) * 6.05
		desk(parent, x, y, pz + 1.65, 0, st)
		desk(parent, x, y, pz - 1.65, 180, st)
	end
	-- power pole feeding the pod from the ceiling
	local px = cx + (n / 2) * 6.05 + 0.5
	Kit.part(parent, "PowerPole", V(0.6, Layout.CEIL_H, 0.6), V(px, y + Layout.CEIL_H / 2, pz), Color3.fromRGB(196, 198, 202), M.Metal)
end

function Work.lab(parent: Instance, c: Cell, level: number, ctx: Ctx)
	local y = Layout.floorY(level)
	local cx, cz = (c.minX + c.maxX) / 2, (c.minZ + c.maxZ) / 2
	local farZ, inDir = farSide(c)
	local st: DeskState = { idx = 0, player = 0, makePlayer = ctx.playerDesks == true, level = level }
	pod(parent, cx, y, c.minZ + 9.8, 3, st)
	pod(parent, cx, y, c.maxZ - 9.8, 3, st)

	Decor.onWall(parent, "Whiteboard", V(c.minX, y, cz), V(1, 0, 0))
	Decor.onWall(parent, "TV", V(cx, y, farZ), V(0, 0, inDir))
	Decor.onWall(parent, "Printer", V(c.maxX - 5, y, farZ), V(0, 0, inDir))
	Decor.onWall(parent, "WaterCooler", V(c.minX + 4, y, farZ), V(0, 0, inDir))
	closet(parent, c, level, c.minX + 11)
	Decor.place("PlantTall", c.maxX - 2.5, y, farZ + inDir * 6, 0, parent)
	Decor.onWall(parent, "TrashBin", V(c.minX, y, cz + 9), V(1, 0, 0))
	Decor.scatter(parent, c.minX + 3, c.maxX - 3, c.minZ + 3, c.maxZ - 3, y + 0.1, math.random(5, 9))
end

--- Two big pods of twelve, a countdown on the wall and a hanging banner.
function Work.hackhall(parent: Instance, c: Cell, level: number, _ctx: Ctx)
	local y = Layout.floorY(level)
	local cx, cz = (c.minX + c.maxX) / 2, (c.minZ + c.maxZ) / 2
	local farZ, inDir = farSide(c)
	local st: DeskState = { idx = 0, player = 0, makePlayer = false, level = level }
	pod(parent, cx, y, c.minZ + 9.8, 10, st)
	pod(parent, cx, y, c.maxZ - 9.8, 10, st)

	-- countdown on the west wall
	local p = V(c.minX + Layout.WALL_T / 2 + 0.3, y + 8.5, cz)
	Kit.part(parent, "CountdownFrame", V(0.4, 4.4, 12.4), p, Color3.fromRGB(18, 18, 22), M.SmoothPlastic)
	local board = Kit.trim(parent, "Countdown", V(0.1, 4, 12), p + V(0.25, 0, 0), Color3.fromRGB(10, 10, 14), M.Neon)
	Kit.label(board, Enum.NormalId.Right, "T-MINUS 31:14:07", Color3.fromRGB(255, 70, 60), Color3.fromRGB(10, 10, 14), Enum.Font.Code, true)
	Kit.light(board, 0.6, 16, Color3.fromRGB(255, 70, 60)).Shadows = false
	Kit.tag(board, TAGS.EMISSIVE_SCREEN)

	Decor.hangingBanner(parent, V(cx, y + Layout.CEIL_H - 0.4, cz), V(0, 0, -inDir), 7, Layout.ACCENT[level + 1], "HACK HALL", "VesperHacks 2026\nShip it or else")
	Decor.onWall(parent, "Whiteboard", V(c.maxX, y, cz), V(-1, 0, 0))
	Decor.onWall(parent, "Vending", V(cx - 10, y, farZ), V(0, 0, inDir))
	Decor.onWall(parent, "WaterCooler", V(cx - 5, y, farZ), V(0, 0, inDir))
	Decor.onWall(parent, "TrashBin", V(cx + 6, y, farZ), V(0, 0, inDir))
	closet(parent, c, level, cx + 16)
	closet(parent, c, level, cx - 22)
	for _, dx in { -40, 40 } do
		Decor.place("BeanBag", cx + dx, y, farZ + inDir * 4, math.random(0, 359), parent)
	end
	Decor.scatter(parent, c.minX + 3, c.maxX - 3, c.minZ + 3, c.maxZ - 3, y + 0.1, math.random(16, 24))
end

--- Racetrack conference table ringed with chairs, TV at the head.
function Work.meeting(parent: Instance, c: Cell, level: number, _ctx: Ctx)
	local y = Layout.floorY(level)
	local cx, cz = (c.minX + c.maxX) / 2, (c.minZ + c.maxZ) / 2
	local farZ, inDir = farSide(c)
	local wood = Color3.fromRGB(112, 78, 52)
	local L, W = 20, 6
	local top = y + 2.75 -- Office.DESK_TOP, for the 1.72 chairs
	Kit.part(parent, "ConfTable", V(L - W, 0.3, W), V(cx, top - 0.15, cz), wood, M.Wood)
	for _, sx in { -1, 1 } do
		Kit.cylY(parent, "ConfTableEnd", 0.3, W, V(cx + sx * (L - W) / 2, top - 0.15, cz), wood, M.Wood)
		Kit.part(parent, "Pedestal", V(1.4, 2.4, 2.6), V(cx + sx * 5, y + 1.25, cz), Color3.fromRGB(40, 42, 48), M.Metal)
	end
	local hub = Kit.trim(parent, "CableHub", V(1.8, 0.06, 0.8), V(cx, top + 0.03, cz), Color3.fromRGB(40, 42, 48), M.Metal)
	hub.CastShadow = false
	for k = -2, 2 do
		local x = cx + k * 3.6
		Decor.place("OfficeChair", x, y, cz + 4.6, 0, parent)
		Decor.place("OfficeChair", x, y, cz - 4.6, 180, parent)
	end
	Decor.place("OfficeChair", cx + L / 2 + 2, y, cz, 90, parent)
	for k, dx in { -6, 3.5 } do
		Decor.place("Laptop", cx + dx, top + 0.09, cz + (if k == 1 then 1.6 else -1.6), if k == 1 then 0 else 180, parent)
	end
	Decor.scatter(parent, cx - 7, cx + 7, cz - 1.8, cz + 1.8, top, math.random(4, 7))

	Decor.onWall(parent, "TV", V(c.minX, y, cz), V(1, 0, 0))
	Decor.onWall(parent, "Whiteboard", V(cx, y, farZ), V(0, 0, inDir))
	Decor.onWall(parent, "Credenza", V(c.minX, y, cz + 9), V(1, 0, 0))
	Decor.place("PlantTall", c.maxX - 2.5, y, farZ + inDir * 2.5, 0, parent)
	Decor.place("Plant", c.minX + 2.6, y, farZ + inDir * 2.6, 0, parent)
	closet(parent, c, level, c.minX + 9)
end

return Work
