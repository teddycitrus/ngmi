--!strict
--------------------------------------------------------------------------------
-- Elevators.luau
-- Two-car bank at the west end of the corridor.
--
-- Contract with ElevatorController (do not change without it):
--   * each car is a Model tagged ELEVATOR_CAR with an ElevatorId attribute
--     and PrimaryPart "CarFloor" (axis-aligned; the controller PivotTo's it);
--   * every button is a part tagged ELEVATOR_CALL with a ProximityPrompt and
--     ElevatorId / TargetY (the CarFloor Y at that floor = floorY + 0.2);
--   * every landing door panel is tagged ELEVATOR_DOOR with ElevatorId, CarY,
--     ClosedZ and OpenZ; the controller slides it along Z between the two.
--------------------------------------------------------------------------------

local Kit = require(script.Parent.Kit)
local Layout = require(script.Parent.Layout)
local Walls = require(script.Parent.Walls)

local V = Vector3.new
local CF = CFrame.new
local M = Enum.Material
local ELEV = Layout.ELEV
local WALL_T = Layout.WALL_T
local TAGS = Kit.TAGS

local Elevators = {}

local STEEL = Color3.fromRGB(172, 176, 182)
local STEEL_DARK = Color3.fromRGB(92, 96, 102)
local CLAD = Color3.fromRGB(70, 66, 62)
local WOOD = Color3.fromRGB(128, 92, 62)
local LIT = Color3.fromRGB(120, 220, 255)

local CARS = {
	{ id = "ElevA", zMin = ELEV.zMin, zMax = -0.25 },
	{ id = "ElevB", zMin = 0.25, zMax = ELEV.zMax },
}

local function prompt(part: BasePart, elevId: string, targetY: number, text: string)
	part:SetAttribute("ElevatorId", elevId)
	part:SetAttribute("TargetY", targetY)
	Kit.tag(part, TAGS.ELEVATOR_CALL)
	local pp = Instance.new("ProximityPrompt")
	pp.ActionText = text
	pp.ObjectText = "Elevator"
	pp.HoldDuration = 0
	pp.MaxActivationDistance = 9
	pp.RequiresLineOfSight = false
	pp.Parent = part
end

local function buildCar(parent: Instance, car: { id: string, zMin: number, zMax: number })
	local cz = (car.zMin + car.zMax) / 2
	local cx = (ELEV.xMin + ELEV.xMax) / 2
	local hx = (ELEV.xMax - ELEV.xMin) / 2 - 0.65
	local hz = (car.zMax - car.zMin) / 2 - 0.3
	local H = 11
	local y0 = Layout.floorY(0)
	local back = cx - hx
	local front = cx + hx

	local model = Instance.new("Model")
	model.Name = "ElevatorCar_" .. car.id

	local floorPart = Kit.part(model, "CarFloor", V(hx * 2, 0.4, hz * 2), V(cx, y0 + 0.2, cz), Color3.fromRGB(60, 62, 68), M.Granite)
	Kit.trim(model, "Threshold", V(0.5, 0.06, hz * 2 - 0.4), V(front - 0.3, y0 + 0.43, cz), STEEL, M.Metal)
	Kit.part(model, "CarCeiling", V(hx * 2, 0.3, hz * 2), V(cx, y0 + H, cz), STEEL_DARK, M.Metal)
	-- back wall and side walls: steel lower, wood upper, steel kick
	Kit.part(model, "CarWall", V(0.3, H, hz * 2), V(back, y0 + H / 2, cz), STEEL, M.Metal)
	for _, sz in { -1, 1 } do
		Kit.part(model, "CarWall", V(hx * 2, H, 0.3), V(cx, y0 + H / 2, cz + sz * hz), STEEL, M.Metal)
		Kit.trim(model, "Panel", V(hx * 2 - 1.2, 6, 0.06), V(cx - 0.3, y0 + 6, cz + sz * (hz - 0.18)), WOOD, M.Wood)
		Kit.cyl(model, "Handrail", hx * 2 - 1.6, 0.2, CF(cx - 0.3, y0 + 3.3, cz + sz * (hz - 0.5)), STEEL, M.Metal, { collide = false })
	end
	Kit.part(model, "Mirror", V(0.06, 5.5, hz * 2 - 1.2), V(back + 0.18, y0 + 6.2, cz), Color3.fromRGB(200, 212, 222), M.Glass, { reflectance = 0.5, collide = false })
	Kit.cylZ(model, "Handrail", hz * 2 - 1.4, 0.2, CF(back + 0.5, y0 + 3.3, cz), STEEL, M.Metal, { collide = false })
	-- lit ceiling panel; dies in the blackout like every other light
	local lt = Kit.trim(model, "CarLight", V(hx * 1.3, 0.12, hz * 1.4), V(cx, y0 + H - 0.2, cz), Color3.fromRGB(245, 248, 255), M.Neon)
	Kit.light(lt, 0.85, 15)
	Kit.tag(lt, TAGS.CEILING_LIGHT)
	-- front fascia above the door opening
	Kit.trim(model, "Fascia", V(0.3, 1.6, hz * 2), V(front - 0.1, y0 + H - 0.8, cz), STEEL_DARK, M.Metal)

	-- operating panel on the back wall: one button per floor
	local plate = Kit.trim(model, "OperatingPanel", V(0.1, 3.4, 1.4), V(back + 0.2, y0 + 4.8, cz + hz - 1.2), STEEL_DARK, M.Metal)
	local display = Kit.trim(model, "CarDisplay", V(0.06, 0.6, 1.0), V(back + 0.27, y0 + 6.1, cz + hz - 1.2), Color3.fromRGB(12, 14, 18), M.SmoothPlastic)
	Kit.label(display, Enum.NormalId.Right, "VESPER LIFT", LIT, nil, Enum.Font.Code, true)
	plate.CastShadow = false
	for level = 0, Layout.FLOORS - 1 do
		local by = y0 + 3.6 + level * 0.8
		local btn = Kit.cyl(model, "CarButton", 0.2, 0.55, CF(back + 0.3, by, cz + hz - 1.2), Color3.fromRGB(90, 96, 110), M.Neon)
		prompt(btn, car.id, Layout.floorY(level) + 0.2, "Floor " .. (level + 1))
		local lab = Kit.trim(model, "ButtonLabel", V(0.04, 0.4, 0.4), V(back + 0.27, by, cz + hz - 0.65), Color3.new(), M.SmoothPlastic, { transparency = 1 })
		Kit.label(lab, Enum.NormalId.Right, tostring(level + 1), Color3.fromRGB(230, 232, 236), nil, Enum.Font.GothamBold)
	end

	model.PrimaryPart = floorPart
	model:SetAttribute("ElevatorId", car.id)
	Kit.tag(model, TAGS.ELEVATOR_CAR)
	model.Parent = parent
end

--- Up/down hall lantern over a landing door.
local function lantern(parent: Instance, x: number, y: number, z: number)
	Kit.trim(parent, "Lantern", V(0.2, 0.7, 1.6), V(x, y, z), STEEL_DARK, M.Metal)
	for _, k in { -1, 1 } do
		local arrow = Kit.wedge(parent, "LanternArrow", V(0.06, 0.4, 0.5), CF(x + 0.12, y, z + k * 0.4) * CFrame.Angles(if k > 0 then 0 else math.pi, 0, 0) * CFrame.Angles(0, math.pi / 2, 0), Color3.fromRGB(80, 200, 120), M.Neon, { collide = false })
		arrow.Transparency = 0.2
	end
end

function Elevators.build(root: Instance)
	local folder = Instance.new("Folder")
	folder.Name = "Elevators"
	folder.Parent = root
	local shaftStyle: Walls.Style = { color = Color3.fromRGB(150, 150, 146), material = M.Brick, trim = false }

	for level = 0, Layout.FLOORS - 1 do
		local y = Layout.floorY(level)
		-- stop just inside the slab above, so the wall top never shares its face
		local h = Layout.INNER_H + Layout.SLAB_T - 0.02
		Walls.run(folder, V(ELEV.xMin, y, ELEV.zMin), V(ELEV.xMax, y, ELEV.zMin), h, shaftStyle)
		Walls.run(folder, V(ELEV.xMin, y, ELEV.zMax), V(ELEV.xMax, y, ELEV.zMax), h, shaftStyle)
		Walls.run(folder, V(ELEV.xMin, y, 0), V(ELEV.xMax, y, 0), h, shaftStyle)
		local face = ELEV.xMax + WALL_T / 2

		for _, car in CARS do
			local cz = (car.zMin + car.zMax) / 2
			-- landing wall with a 6-wide opening, clad on the lobby side
			Walls.run(folder, V(ELEV.xMax, y, car.zMin), V(ELEV.xMax, y, car.zMax), h, shaftStyle, { { width = 6, height = 10, kind = "open" } })
			for _, span in { { car.zMin + 0.2, cz - 3.6 }, { cz + 3.6, car.zMax - 0.2 } } do
				local a, b = span[1], span[2]
				if b - a > 0.1 then
					Kit.trim(folder, "Cladding", V(0.2, 10.6, b - a), V(face + 0.1, y + 5.3, (a + b) / 2), CLAD, M.Slate)
				end
			end
			Kit.trim(folder, "Cladding", V(0.2, Layout.CEIL_H - 10.6, car.zMax - car.zMin - 0.4), V(face + 0.1, y + 10.6 + (Layout.CEIL_H - 10.6) / 2, cz), CLAD, M.Slate)
			-- stainless portal round the opening
			for _, k in { -1, 1 } do
				Kit.trim(folder, "Portal", V(0.5, 10.1, 0.6), V(face + 0.15, y + 5.05, cz + k * 3.32), STEEL, M.Metal, { reflectance = 0.08 })
			end
			Kit.trim(folder, "Portal", V(0.54, 0.5, 7.3), V(face + 0.15, y + 10.3, cz), STEEL, M.Metal, { reflectance = 0.08 })
			Kit.trim(folder, "Sill", V(1.2, 0.06, 6), V(ELEV.xMax + 0.2, y + 0.03, cz), STEEL_DARK, M.Metal)
			lantern(folder, face + 0.3, y + 11.4, cz)

			-- lit floor indicator above the portal
			local plate = Kit.trim(folder, "ElevPlate", V(0.2, 0.9, 2.2), V(face + 0.3, y + 12.6, cz), Color3.fromRGB(16, 18, 22), M.SmoothPlastic)
			Kit.label(plate, Enum.NormalId.Right, tostring(level + 1), LIT, nil, Enum.Font.Code, true)

			-- call stations share the strip of wall between the two cars
			local side = if car.id == "ElevA" then -1 else 1
			local sz = cz - side * 4.125
			Kit.trim(folder, "CallPlate", V(0.12, 1.8, 0.8), V(face + 0.26, y + 4.5, sz), STEEL, M.Metal)
			local btn = Kit.cyl(folder, "ElevCall", 0.24, 0.5, CF(face + 0.36, y + 4.5, sz), Color3.fromRGB(90, 96, 110), M.Neon)
			prompt(btn, car.id, y + 0.2, "Call Elevator")

			-- sliding landing doors (brushed steel panels)
			for _, k in { -1, 1 } do
				local closedZ = cz + k * 1.5
				local openZ = cz + k * 4.4
				local door = Kit.part(folder, "ElevDoor", V(0.25, 9.6, 3), V(ELEV.xMax, y + 4.9, closedZ), STEEL, M.Metal, { reflectance = 0.1 })
				door:SetAttribute("ElevatorId", car.id)
				door:SetAttribute("CarY", y + 0.2)
				door:SetAttribute("ClosedZ", closedZ)
				door:SetAttribute("OpenZ", openZ)
				Kit.tag(door, TAGS.ELEVATOR_DOOR)
			end
		end

		-- freestanding floor directory in the lobby, facing down the corridor
		local tx, tz = ELEV.xMax + 4.5, 6.6
		Kit.part(folder, "DirectoryBase", V(1.2, 0.4, 3.4), V(tx, y + 0.2, tz), CLAD, M.Slate)
		Kit.part(folder, "DirectoryPylon", V(0.8, 7, 3), V(tx, y + 3.9, tz), CLAD, M.Slate)
		local dir = Kit.trim(folder, "Directory", V(0.06, 4.6, 2.6), V(tx + 0.43, y + 4.6, tz), Color3.fromRGB(24, 26, 32), M.SmoothPlastic)
		Kit.label(
			dir,
			Enum.NormalId.Right,
			"FLOOR " .. (level + 1) .. "\n\n" .. ({
				"Auditorium\nLabs\nRestrooms",
				"Hack Hall\nLabs\nLounges",
				"Library\nLabs\nMeeting",
			})[level + 1],
			Color3.fromRGB(236, 238, 242),
			nil,
			Enum.Font.GothamMedium,
			true
		)
		Kit.trim(folder, "DirectoryBar", V(0.86, 0.3, 3.04), V(tx, y + 7.27, tz), Layout.ACCENT[level + 1], M.SmoothPlastic)
	end

	for _, car in CARS do
		buildCar(folder, car)
	end
end

return Elevators
