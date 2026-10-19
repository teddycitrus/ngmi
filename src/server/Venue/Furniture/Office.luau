--!strict
--------------------------------------------------------------------------------
-- Office.luau
-- Workstations, laptops, chairs, boards and screens.
--
-- Conventions for every template: origin at floor level, front facing -Z.
-- Wall-hung pieces (Whiteboard, TV) have their back face on the origin plane;
-- floor-standing pieces are centred on their footprint.
--
-- Contracts other scripts rely on are noted where they apply.
--------------------------------------------------------------------------------

local Kit = require(script.Parent.Parent.Kit)

local COLORS = Kit.COLORS
local V = Vector3.new
local CF = CFrame.new
local M = Enum.Material

local LAMINATE = Color3.fromRGB(198, 174, 138)
local FRAME = Color3.fromRGB(54, 56, 62)
local CHROME = Color3.fromRGB(190, 194, 200)
local PLASTIC_DARK = Color3.fromRGB(34, 35, 40)
local ALU = Color3.fromRGB(176, 180, 186)

local Office = {}

--- A five-star task chair, facing -Z within `at`. With `asSeat` the cushion
--- is a real Seat named "Seat".
function Office.chair(m: Model, at: CFrame, fabric: Color3, asSeat: boolean)
	for i = 0, 4 do
		local spoke = at * CFrame.Angles(0, math.rad(i * 72 + 36), 0)
		Kit.trim(m, "ChairLeg", V(0.2, 0.22, 1.1), spoke * CF(0, 0.3, -0.5) * CFrame.Angles(math.rad(-8), 0, 0), PLASTIC_DARK, M.SmoothPlastic)
	end
	Kit.cylY(m, "GasLift", 1.1, 0.2, at * CF(0, 1.05, 0), CHROME, M.Metal, { collide = false })
	Kit.trim(m, "SeatPan", V(1.8, 0.16, 1.75), at * CF(0, 1.68, 0), PLASTIC_DARK, M.SmoothPlastic)
	if asSeat then
		Kit.seat(m, "Seat", V(1.9, 0.3, 1.85), at * CF(0, 1.9, -0.02), fabric, M.Fabric)
	else
		Kit.part(m, "ChairSeat", V(1.9, 0.3, 1.85), at * CF(0, 1.9, -0.02), fabric, M.Fabric)
	end
	Kit.trim(m, "BackPost", V(0.3, 1.3, 0.14), at * CF(0, 2.35, 0.98) * CFrame.Angles(math.rad(8), 0, 0), PLASTIC_DARK, M.SmoothPlastic)
	Kit.part(m, "ChairBack", V(1.75, 1.9, 0.26), at * CF(0, 3.3, 1.08) * CFrame.Angles(math.rad(9), 0, 0), fabric, M.Fabric)
	for _, sx in { -1, 1 } do
		Kit.trim(m, "ArmPost", V(0.14, 0.62, 0.14), at * CF(sx * 0.98, 2.3, 0.25), PLASTIC_DARK, M.SmoothPlastic)
		Kit.trim(m, "ArmPad", V(0.24, 0.1, 0.95), at * CF(sx * 0.98, 2.65, 0.12), PLASTIC_DARK, M.Rubber)
	end
end

--------------------------------------------------------------------------------
-- Workstation
-- Contract: "Desk" (top, PlayerDesk tag), "Seat" (invisible typist marker at
-- local (0, 0, 1.8)), and a "Monitor" model ambient laptop users delete. The
-- desk top surface is at Y 3.26, where AmbientPopulation sets its laptops.
--------------------------------------------------------------------------------
local function workstation(): Model
	local m = Kit.model("Workstation")
	local top = 3.26
	Kit.part(m, "Desk", V(6, 0.14, 3), CF(0, top - 0.07, 0), LAMINATE, M.Wood)
	for _, sx in { -1, 1 } do
		Kit.part(m, "Leg", V(0.22, top - 0.32, 0.22), CF(sx * 2.7, (top - 0.18) / 2 + 0.02, -0.2), FRAME, M.Metal)
		Kit.trim(m, "Foot", V(0.3, 0.12, 2.7), CF(sx * 2.7, 0.06, 0), FRAME, M.Metal)
	end
	Kit.trim(m, "Modesty", V(5.2, 1.3, 0.06), CF(0, top - 1.0, -1.32), Color3.fromRGB(96, 98, 104), M.DiamondPlate)

	-- three-drawer pedestal on the right
	Kit.part(m, "Pedestal", V(1.3, 2.5, 2.24), CF(2.0, 1.31, -0.17), Color3.fromRGB(214, 212, 206), M.SmoothPlastic)
	for i = 0, 2 do
		local y = 0.55 + i * 0.8
		Kit.trim(m, "Drawer", V(1.22, 0.72, 0.05), CF(2.0, y, 0.97), Color3.fromRGB(226, 224, 218), M.SmoothPlastic)
	end

	-- fabric privacy screen along the back edge
	Kit.trim(m, "PrivacyScreen", V(6, 1.6, 0.12), CF(0, top + 0.8, -1.56), Color3.fromRGB(92, 102, 118), M.Fabric)

	-- Monitor, keyboard and mouse live together so a laptop user can delete
	-- the lot in one go.
	local mon = Instance.new("Model")
	mon.Name = "Monitor"
	Kit.trim(mon, "StandBase", V(1.0, 0.06, 0.75), CF(0, top + 0.03, -0.95), PLASTIC_DARK, M.SmoothPlastic)
	Kit.trim(mon, "StandNeck", V(0.2, 1.05, 0.12), CF(0, top + 0.55, -1.12), PLASTIC_DARK, M.SmoothPlastic)
	Kit.trim(mon, "Bezel", V(3.2, 1.95, 0.12), CF(0, top + 1.3, -1.02), Color3.fromRGB(22, 22, 26), M.SmoothPlastic)
	-- The seat is at +Z, so the image goes on the panel's +Z (Back) face.
	Kit.screen(mon, "Screen", V(3.0, 1.75, 0.04), CF(0, top + 1.32, -0.95), Enum.NormalId.Back, { lineCount = 4, strips = true })
	Kit.trim(mon, "Keyboard", V(2.2, 0.08, 0.72), CF(0, top + 0.04, 0.45), Color3.fromRGB(58, 60, 68), M.SmoothPlastic)
	Kit.blob(mon, "Mouse", V(0.3, 0.14, 0.46), CF(1.55, top + 0.08, 0.45), PLASTIC_DARK, M.SmoothPlastic, { collide = false })
	mon.Parent = m

	Kit.cylY(m, "Mug", 0.4, 0.36, CF(-2.25, top + 0.2, -0.35), Color3.fromRGB(150, 40, 44), M.SmoothPlastic, { collide = false })

	Office.chair(m, CF(0, 0, 1.95), COLORS.CHAIR, false)

	-- where an ambient typist sits (invisible; delete to leave the desk empty)
	local seat = Kit.part(m, "Seat", V(1.5, 0.2, 1.5), CF(0, 0, 1.8), Color3.new(1, 1, 1), nil, { collide = false })
	seat.Transparency = 1
	return m
end

--------------------------------------------------------------------------------
-- Laptop
-- Contract: PrimaryPart "Base" (0.18 thick, centred on the origin), user on
-- +Z, lid hinged off the -Z edge. AmbientPopulation's lap and desk offsets
-- are measured against exactly this.
--------------------------------------------------------------------------------
local function laptop(): Model
	local m = Instance.new("Model")
	m.Name = "Laptop"
	local D = 1.3
	local LID_H = 1.25
	local base = Kit.part(m, "Base", V(2, 0.18, D), CF(), ALU, M.Metal, { collide = false })
	m.PrimaryPart = base
	Kit.trim(m, "KeyDeck", V(1.8, 0.02, 0.62), CF(0, 0.095, -0.2), Color3.fromRGB(30, 31, 36), M.SmoothPlastic)
	Kit.trim(m, "Trackpad", V(0.72, 0.02, 0.4), CF(0, 0.095, 0.38), Color3.fromRGB(150, 154, 160), M.SmoothPlastic)

	-- The lid pivots about the hinge line (top of the base, back edge). -15
	-- degrees opens it to about 105 from the base, leaning away from the user.
	local hinge = CF(0, 0.09, -D / 2)
	local lidCF = hinge * CFrame.Angles(math.rad(-15), 0, 0) * CF(0, LID_H / 2, 0)
	Kit.screen(m, "Screen", V(1.86, LID_H - 0.14, 0.04), lidCF * CF(0, 0.02, 0.04), Enum.NormalId.Back, {
		color = Color3.fromRGB(120, 200, 255),
		lineCount = 4,
		strips = true,
	})
	Kit.trim(m, "Bezel", V(2, LID_H, 0.06), lidCF * CF(0, 0, 0.0), Color3.fromRGB(26, 27, 32), M.SmoothPlastic)
	Kit.trim(m, "Lid", V(2.02, LID_H + 0.02, 0.06), lidCF * CF(0, 0, -0.06), ALU, M.Metal)
	Kit.cylZ(m, "Logo", 0.02, 0.26, lidCF * CF(0, 0.1, -0.095), Color3.fromRGB(235, 236, 240), M.Neon, { collide = false })
	return m
end

local function officeChair(): Model
	local m = Kit.model("OfficeChair")
	Office.chair(m, CF(), COLORS.CHAIR, true)
	return m
end

--- Wall-hung whiteboard with a sprint plan scrawled on it.
local function whiteboard(): Model
	local m = Kit.model("Whiteboard")
	local board = Kit.part(m, "Board", V(10, 4.6, 0.1), CF(0, 6, -0.12), COLORS.WHITEBOARD, M.SmoothPlastic, { reflectance = 0.04 })
	for _, sy in { -1, 1 } do
		Kit.trim(m, "Frame", V(10.3, 0.2, 0.24), CF(0, 6 + sy * 2.4, -0.12), ALU, M.Metal)
	end
	for _, sx in { -1, 1 } do
		Kit.trim(m, "Frame", V(0.2, 4.6, 0.24), CF(sx * 5.05, 6, -0.12), ALU, M.Metal)
	end
	Kit.trim(m, "Tray", V(8, 0.1, 0.5), CF(0, 3.57, -0.4), ALU, M.Metal)
	Kit.trim(m, "TrayLip", V(8.04, 0.18, 0.06), CF(0, 3.62, -0.64), ALU, M.Metal)
	local inks = { Color3.fromRGB(30, 60, 160), Color3.fromRGB(180, 30, 30), Color3.fromRGB(20, 120, 50), Color3.fromRGB(20, 20, 24) }
	for i, c in inks do
		Kit.cyl(m, "Marker", 0.62, 0.13, CF(-3 + i * 0.5, 3.68, -0.42), c, M.SmoothPlastic, { collide = false })
	end
	Kit.trim(m, "Eraser", V(0.7, 0.22, 0.32), CF(2.6, 3.72, -0.42), Color3.fromRGB(40, 40, 44), M.Fabric)
	local ink = Kit.label(
		board,
		Enum.NormalId.Front,
		"SPRINT PLAN\n1. auth  [done]\n2. database ???\n3. ship it\n\nSLEEP IS A BUG",
		Color3.fromRGB(30, 50, 140),
		nil,
		Enum.Font.PermanentMarker
	)
	ink.TextXAlignment = Enum.TextXAlignment.Left
	ink.Size = UDim2.fromScale(0.7, 0.9)
	ink.Position = UDim2.fromScale(0.05, 0.05)
	return m
end

--- Wall-mounted TV on a bracket, with a soundbar under it.
local function tv(): Model
	local m = Kit.model("TV")
	Kit.trim(m, "Bracket", V(2.4, 2.4, 0.3), CF(0, 8, -0.15), PLASTIC_DARK, M.Metal)
	Kit.part(m, "Frame", V(9.2, 5.2, 0.3), CF(0, 8, -0.45), Color3.fromRGB(16, 16, 20), M.SmoothPlastic)
	Kit.screen(m, "Screen", V(8.9, 4.9, 0.04), CF(0, 8, -0.61), Enum.NormalId.Front, {
		color = Color3.fromRGB(90, 140, 210),
		brightness = 0.5,
		range = 12,
		lineCount = 6,
	})
	Kit.trim(m, "Soundbar", V(5, 0.36, 0.4), CF(0, 5.05, -0.35), PLASTIC_DARK, M.Fabric)
	Kit.trim(m, "Cable", V(0.08, 4.6, 0.08), CF(-0.6, 2.6, -0.06), PLASTIC_DARK, M.Rubber)
	return m
end

--- Speaker's podium. Contract: about 3 tall so it doesn't hide the speaker;
--- the reading slope and mic are on the -Z side, where the speaker stands.
local function lectern(): Model
	local m = Kit.model("Lectern")
	local wood = COLORS.PODIUM
	Kit.part(m, "Plinth", V(3.1, 0.2, 2.1), CF(0, 0.1, 0), Color3.fromRGB(40, 28, 18), M.Wood)
	Kit.part(m, "Body", V(2.8, 2.7, 1.8), CF(0, 1.55, 0), wood, M.Wood)
	for _, sx in { -1, 1 } do
		Kit.trim(m, "Pilaster", V(0.3, 2.66, 1.9), CF(sx * 1.32, 1.53, 0), wood:Lerp(Color3.new(), 0.2), M.Wood)
	end
	local crest = Kit.trim(m, "Crest", V(2.0, 1.6, 0.06), CF(0, 1.75, 0.93), COLORS.UNI_MAROON, M.Fabric)
	Kit.label(crest, Enum.NormalId.Back, "ST. VESPER\nUNIVERSITY", COLORS.UNI_GOLD, nil, Enum.Font.Garamond)
	local topCF = CF(0, 3.05, -0.15) * CFrame.Angles(math.rad(-12), 0, 0)
	Kit.part(m, "Top", V(3.2, 0.18, 2.2), topCF, Color3.fromRGB(60, 40, 24), M.Wood)
	Kit.trim(m, "Notes", V(1.2, 0.03, 1.5), topCF * CF(-0.4, 0.1, 0), Color3.fromRGB(245, 244, 236), M.SmoothPlastic)
	Kit.cylY(m, "MicStem", 1.1, 0.08, CF(0.85, 3.65, -0.5) * CFrame.Angles(math.rad(-20), 0, 0), PLASTIC_DARK, M.Metal, { collide = false })
	Kit.blob(m, "Mic", V(0.22, 0.34, 0.22), CF(0.85, 4.2, -0.72), Color3.fromRGB(30, 30, 34), M.Metal, { collide = false })
	return m
end

--------------------------------------------------------------------------------
-- Shelf
-- Contract: three boards spanning X +-5, Z +-1, tops at Y 2.2 / 5.2 / 8.2
-- (MapBuilder rests item spawns on the bottom two).
--------------------------------------------------------------------------------
local function shelf(): Model
	local m = Kit.model("Shelf")
	local steel = Color3.fromRGB(64, 70, 80)
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			Kit.part(m, "Upright", V(0.22, 8.8, 0.22), CF(sx * 4.95, 4.4, sz * 0.92), steel, M.Metal)
		end
	end
	for i = 0, 2 do
		local y = 2 + i * 3
		Kit.part(m, "Shelf", V(10, 0.4, 2), CF(0, y, 0), Color3.fromRGB(176, 148, 108), M.Wood)
		for _, sz in { -1, 1 } do
			Kit.trim(m, "Beam", V(9.7, 0.3, 0.12), CF(0, y - 0.32, sz * 0.95), Color3.fromRGB(220, 120, 40), M.Metal)
		end
	end
	Kit.part(m, "KickShelf", V(9.7, 0.2, 1.9), CF(0, 0.3, 0), Color3.fromRGB(176, 148, 108), M.Wood)
	local card = Color3.fromRGB(176, 140, 96)
	for i, b in { { -3.2, 1.6, 1.4 }, { -1.2, 1.2, 1.1 }, { 1.4, 1.8, 1.5 }, { 3.6, 1.1, 1.2 } } do
		local w, h = b[2], b[3]
		Kit.trim(m, "Box", V(w, h, 1.6), CF(b[1], 8.2 + h / 2, 0) * CFrame.Angles(0, math.rad(i * 3 - 6), 0), card, M.Cardboard)
	end
	Kit.trim(m, "Box", V(2, 1.4, 1.6), CF(-2.5, 1.1, 0), card, M.Cardboard)
	Kit.trim(m, "Box", V(1.6, 1.1, 1.5), CF(2.8, 0.95, 0.05), card:Lerp(Color3.new(), 0.1), M.Cardboard)
	return m
end

--- Office laser printer on its cabinet.
local function printer(): Model
	local m = Kit.model("Printer")
	local grey = Color3.fromRGB(206, 206, 202)
	Kit.part(m, "Cabinet", V(2.6, 2.2, 2.2), CF(0, 1.1, 0), Color3.fromRGB(70, 72, 78), M.SmoothPlastic)
	Kit.part(m, "Body", V(2.5, 1.4, 2.2), CF(0, 2.9, 0), grey, M.SmoothPlastic)
	Kit.trim(m, "Scanner", V(2.4, 0.22, 2.1), CF(0, 3.71, 0.02), grey:Lerp(Color3.new(), 0.25), M.SmoothPlastic)
	Kit.trim(m, "PaperTray", V(2.2, 0.2, 0.06), CF(0, 2.45, -1.11), grey:Lerp(Color3.new(), 0.1), M.SmoothPlastic)
	Kit.trim(m, "OutTray", V(1.7, 0.06, 1.0), CF(0, 3.22, -0.95) * CFrame.Angles(math.rad(-8), 0, 0), PLASTIC_DARK, M.SmoothPlastic)
	Kit.trim(m, "Pages", V(1.4, 0.08, 0.9), CF(0, 3.28, -0.95) * CFrame.Angles(math.rad(-8), 0, 0), Color3.fromRGB(246, 246, 242), M.SmoothPlastic)
	Kit.trim(m, "Panel", V(0.9, 0.06, 0.5), CF(0.75, 3.62, -0.9) * CFrame.Angles(math.rad(25), 0, 0), PLASTIC_DARK, M.SmoothPlastic)
	Kit.trim(m, "PanelDisplay", V(0.5, 0.02, 0.25), CF(0.75, 3.66, -0.92) * CFrame.Angles(math.rad(25), 0, 0), Color3.fromRGB(255, 150, 40), M.Neon)
	Kit.trim(m, "Status", V(0.12, 0.12, 0.06), CF(-0.95, 3.4, -1.12), Color3.fromRGB(255, 150, 40), M.Neon)
	return m
end

--- Low storage cabinet for the meeting room.
local function credenza(): Model
	local m = Kit.model("Credenza")
	local wood = Color3.fromRGB(118, 84, 56)
	Kit.part(m, "Body", V(7, 2.6, 1.8), CF(0, 1.5, 0), wood, M.Wood)
	Kit.part(m, "Top", V(7.2, 0.14, 1.9), CF(0, 2.87, 0), wood:Lerp(Color3.new(), 0.15), M.Wood)
	Kit.trim(m, "Kick", V(6.8, 0.2, 1.6), CF(0, 0.1, 0.05), PLASTIC_DARK, M.SmoothPlastic)
	for i = -1, 1 do
		Kit.trim(m, "Door", V(2.22, 2.3, 0.06), CF(i * 2.3, 1.5, -0.91), wood:Lerp(Color3.new(1, 1, 1), 0.06), M.Wood)
		Kit.trim(m, "Pull", V(0.08, 0.8, 0.08), CF(i * 2.3 + 0.9, 1.7, -0.97), CHROME, M.Metal)
	end
	Kit.cylY(m, "Carafe", 0.9, 0.5, CF(-2.4, 3.39, 0), Color3.fromRGB(40, 40, 44), M.Metal, { collide = false })
	for i = 0, 2 do
		Kit.cylY(m, "Cup", 0.36, 0.3, CF(-1.6 + i * 0.4, 3.12, -0.3), Color3.fromRGB(245, 245, 240), M.SmoothPlastic, { collide = false })
	end
	return m
end

Office.builders = {
	Workstation = workstation,
	Laptop = laptop,
	OfficeChair = officeChair,
	Whiteboard = whiteboard,
	TV = tv,
	Lectern = lectern,
	Shelf = shelf,
	Printer = printer,
	Credenza = credenza,
} :: { [string]: () -> Model }

return Office
