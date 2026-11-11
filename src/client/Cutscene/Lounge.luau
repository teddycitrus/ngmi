--!strict
--------------------------------------------------------------------------------
-- Cutscene/Lounge.luau
-- The off-map set for CutsceneManager's night transition: a venue lounge at
-- 3am. Carpet, panelled walls, a TV and a vending bank on the back wall, a
-- couch corner and beanbags, and laptop tables where the hackers break down.
-- The furniture is cloned from the venue's own templates, which the server
-- publishes to ReplicatedStorage.CutsceneProps (AssetLibrary.publish), so the
-- room matches the game. A doorway in the back wall opens onto a short hall
-- the mutated hackers shamble out into.
--
-- Room: 50 x 40 studs centred on `base`, front (camera side) at +Z, back wall
-- and doorway at -Z, window in the +X wall. The cast's marks are fixed in
-- CutsceneManager; nothing here stands on them or on the exit lanes.
--------------------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local UITheme = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UITheme"))

local Lounge = {}

local V = Vector3.new
local M = Enum.Material

local WALL = Color3.fromRGB(198, 188, 172)
local PANEL = Color3.fromRGB(92, 64, 44)
local CARPET = Color3.fromRGB(78, 74, 80)
local CEIL = Color3.fromRGB(226, 224, 220)
local TUBE_ON = Color3.fromRGB(190, 196, 214)
local TUBE_OFF = Color3.fromRGB(60, 63, 74)

export type Room = {
	backZ: number,
	frontZ: number,
	skyPL: PointLight,
	flicker: RBXScriptConnection,
}

local function newPart(set: Instance, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CastShadow = false
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or M.SmoothPlastic
	p.Parent = set
	return p
end

local props: Instance? = nil
--- Place a venue template so its front looks along `face`. Nil when the
--- server hasn't published it (the room is still usable without).
local function place(set: Instance, name: string, pos: Vector3, face: Vector3): Model?
	props = props or ReplicatedStorage:WaitForChild("CutsceneProps", 5)
	local tmpl = props and props:FindFirstChild(name)
	if not (tmpl and tmpl:IsA("Model")) then
		return nil
	end
	local m = tmpl:Clone()
	m:PivotTo(CFrame.lookAt(pos, pos + face))
	m.Parent = set
	return m
end

--- A wall with a wood wainscot along its lower third and a baseboard.
--- `inward` points into the room.
local function wall(set: Instance, size: Vector3, center: Vector3, inward: Vector3)
	newPart(set, "Wall", size, CFrame.new(center), WALL)
	local along = if math.abs(inward.X) > 0 then V(0, 0, size.Z) else V(size.X, 0, 0)
	local floorY = center.Y - size.Y / 2
	local face = center + inward * (math.min(size.X, size.Z) / 2)
	local function strip(name: string, h: number, y: number, depth: number, color: Color3, mat: Enum.Material)
		local thick = V(math.abs(inward.X), 0, math.abs(inward.Z)) * depth
		newPart(set, name, along + thick + V(0, h, 0), CFrame.new(V(face.X, floorY + y, face.Z) + inward * (depth / 2)), color, mat)
	end
	-- each piece stands proud of the one behind it, so no two faces share a plane
	strip("Wainscot", 3.4, 1.7, 0.12, PANEL, M.Wood)
	strip("ChairRail", 0.25, 3.45, 0.2, PANEL:Lerp(Color3.new(), 0.25), M.Wood)
	strip("Baseboard", 0.5, 0.25, 0.2, Color3.fromRGB(40, 34, 30), M.Wood)
end

function Lounge.build(set: Instance, base: Vector3, floorTop: number): Room
	local cx, cz = base.X, base.Z
	local backZ, frontZ = cz - 20, cz + 20
	local y0 = floorTop
	local wallY = y0 + 6

	newPart(set, "Floor", V(50, 0.4, 40), CFrame.new(cx, y0 - 0.2, cz), CARPET, M.Fabric)
	newPart(set, "Ceiling", V(50, 0.4, 40), CFrame.new(cx, y0 + 12, cz), CEIL)
	wall(set, V(0.6, 12, 40), V(cx - 25, wallY, cz), V(1, 0, 0))
	wall(set, V(0.6, 12, 40), V(cx + 25, wallY, cz), V(-1, 0, 0))
	wall(set, V(50, 12, 0.6), V(cx, wallY, frontZ), V(0, 0, -1))
	-- back wall in two halves around an 8-stud doorway, and the lintel over it
	wall(set, V(21, 12, 0.6), V(cx - 14.5, wallY, backZ), V(0, 0, 1))
	wall(set, V(21, 12, 0.6), V(cx + 14.5, wallY, backZ), V(0, 0, 1))
	newPart(set, "Wall", V(8, 3, 0.6), CFrame.new(cx, y0 + 10.5, backZ), WALL)
	for _, sx in { -1, 1 } do
		newPart(set, "DoorFrame", V(0.4, 9, 0.9), CFrame.new(cx + sx * 4.1, y0 + 4.5, backZ), PANEL, M.Wood)
	end
	newPart(set, "DoorFrame", V(8.6, 0.4, 0.9), CFrame.new(cx, y0 + 9.1, backZ), PANEL, M.Wood)

	-- the lounge rug and the couch corner, front left, clear of the cast
	newPart(set, "Rug", V(16, 0.05, 12), CFrame.new(cx - 15, y0 + 0.03, cz + 10), Color3.fromRGB(116, 62, 70), M.Fabric)
	newPart(set, "RugBorder", V(16.8, 0.04, 12.8), CFrame.new(cx - 15, y0 + 0.02, cz + 10), Color3.fromRGB(196, 170, 120), M.Fabric)
	place(set, "Couch", V(cx - 22.2, y0, cz + 10), V(1, 0, 0))
	place(set, "CoffeeTable", V(cx - 16.5, y0, cz + 10), V(1, 0, 0))
	place(set, "Armchair", V(cx - 11, y0, cz + 14), V(-1, 0, -0.5).Unit)
	place(set, "Armchair", V(cx - 11, y0, cz + 6.5), V(-1, 0, 0.5).Unit)
	place(set, "FloorLamp", V(cx - 23, y0, cz + 17.5), V(0, 0, -1))
	place(set, "PlantTall", V(cx - 23, y0, cz + 3), V(1, 0, 0))

	-- front right: beanbags by the window and another lamp
	place(set, "BeanBag", V(cx + 17, y0, cz + 13), V(-0.4, 0, -1).Unit)
	place(set, "BeanBag", V(cx + 21.5, y0, cz + 15.5), V(-1, 0, -0.6).Unit)
	place(set, "FloorLamp", V(cx + 23, y0, cz + 18.5), V(0, 0, -1))
	place(set, "Plant", V(cx + 22.6, y0, cz - 2), V(-1, 0, 0))

	-- back wall: TV and bookshelf left of the door, notice board and water
	-- cooler beside it, the vending bank and fridge on the right
	local inBack = V(0, 0, 1)
	place(set, "TV", V(cx - 14, y0, backZ + 0.3), inBack)
	place(set, "Bookshelf", V(cx - 22, y0, backZ + 1.3), inBack)
	place(set, "NoticeBoard", V(cx - 7, y0, backZ + 0.3), inBack)
	place(set, "WaterCooler", V(cx + 6.5, y0, backZ + 1.2), inBack)
	place(set, "Vending", V(cx + 12, y0, backZ + 1.9), inBack)
	place(set, "Vending", V(cx + 16.4, y0, backZ + 1.9), inBack)
	place(set, "Fridge", V(cx + 21, y0, backZ + 1.7), inBack)
	place(set, "TrashBin", V(cx + 8.8, y0, backZ + 1.1), inBack)
	place(set, "PlantTall", V(cx - 18, y0, backZ + 1.4), inBack)

	-- the neon sign every venue lounge has, over the vending machines
	local sp = V(cx + 14, y0 + 10.2, backZ + 0.35)
	local sign = newPart(set, "NeonSign", V(8, 1.4, 0.1), CFrame.lookAt(sp, sp + inBack), Color3.new(), M.Neon)
	sign.Transparency = 1
	local sg = Instance.new("SurfaceGui")
	sg.Face = Enum.NormalId.Front
	sg.LightInfluence = 0
	sg.CanvasSize = Vector2.new(400, 70)
	sg.Parent = sign
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.BackgroundTransparency = 1
	lbl.Text = "chill zone"
	lbl.Font = Enum.Font.FredokaOne
	lbl.TextScaled = true
	lbl.TextColor3 = Color3.fromRGB(255, 90, 200)
	lbl.Parent = sg

	-- window in the +X wall, cold night sky behind it. Range 14: a longer
	-- light at the glass becomes a second room light, not a rim on the glass.
	local wz = cz + 6
	newPart(set, "Window", V(0.3, 5, 8), CFrame.new(cx + 24.6, y0 + 6, wz), Color3.fromRGB(28, 33, 48), M.Glass)
	for _, dz in { -4.1, 4.1 } do
		newPart(set, "WindowFrame", V(0.5, 5.4, 0.3), CFrame.new(cx + 24.55, y0 + 6, wz + dz), PANEL, M.Wood)
	end
	for _, dy in { -2.6, 2.6 } do
		newPart(set, "WindowFrame", V(0.6, 0.3, 8.5), CFrame.new(cx + 24.5, y0 + 6 + dy, wz), PANEL, M.Wood)
	end
	local sky = newPart(set, "Sky", V(0.2, 5, 8), CFrame.new(cx + 25.6, y0 + 6, wz), Color3.fromRGB(20, 25, 40), M.Neon)
	sky.Transparency = 1
	local skyPL = Instance.new("PointLight")
	skyPL.Color = Color3.fromRGB(150, 170, 255)
	skyPL.Brightness = 0.6
	skyPL.Range = 14
	skyPL.Parent = sky

	-- Ceiling panels. Two are dead and one flickers: a lounge at 3am is a few
	-- pools of light with dark between them, not an evenly lit room.
	local flickering: { { fix: Part, pl: PointLight } } = {}
	for _, ox in { -14, 0, 14 } do
		for _, oz in { -8, 8 } do
			local dead = (ox == 14 and oz == -8) or (ox == -14 and oz == 8)
			local fix = newPart(set, "CeilLight", V(4, 0.3, 4), CFrame.new(cx + ox, y0 + 11.7, cz + oz), TUBE_ON, M.Neon)
			newPart(set, "CeilTrim", V(4.4, 0.2, 4.4), CFrame.new(cx + ox, y0 + 11.78, cz + oz), Color3.fromRGB(180, 182, 186), M.Metal)
			if dead then
				fix.Color = Color3.fromRGB(38, 40, 48)
				fix.Material = M.SmoothPlastic
			else
				local pl = Instance.new("PointLight")
				pl.Color = Color3.fromRGB(214, 222, 240)
				-- pools on top of the dim ambient, not the room light; at 1.6 a
				-- fixture blew a wall eight studs away out to white
				pl.Brightness = 0.85
				pl.Range = 26
				pl.Parent = fix
				if ox == 0 and oz == -8 then
					table.insert(flickering, { fix = fix, pl = pl })
				end
			end
		end
	end
	local flicker = RunService.Heartbeat:Connect(function()
		local t = os.clock()
		for _, f in flickering do
			local pl = f.pl
			if pl.Enabled then
				local out = math.sin(t * 37) * math.sin(t * 11.3) * math.sin(t * 3.1) < -0.55
				pl.Brightness = if out then 0.06 else 0.85
				f.fix.Color = if out then TUBE_OFF else TUBE_ON
			end
		end
	end)

	-- the hall through the back doorway, for the exit shot
	newPart(set, "HallFloor", V(10, 0.4, 30), CFrame.new(cx, y0 - 0.2, backZ - 15), Color3.fromRGB(120, 124, 130), M.Concrete)
	newPart(set, "HallCeil", V(10, 0.4, 30), CFrame.new(cx, y0 + 9.8, backZ - 15), CEIL)
	newPart(set, "HallWallL", V(0.6, 10, 30), CFrame.new(cx - 5, y0 + 4.8, backZ - 15), WALL)
	newPart(set, "HallWallR", V(0.6, 10, 30), CFrame.new(cx + 5, y0 + 4.8, backZ - 15), WALL)
	for hz = backZ - 4, backZ - 28, -8 do
		local fix = newPart(set, "HallLight", V(2, 0.3, 2), CFrame.new(cx, y0 + 9.4, hz), Color3.fromRGB(255, 245, 225), M.Neon)
		local pl = Instance.new("PointLight")
		pl.Color = Color3.fromRGB(206, 214, 232)
		pl.Brightness = 0.8
		pl.Range = 18
		pl.Parent = fix
	end

	return { backZ = backZ, frontZ = frontZ, skyPL = skyPL, flicker = flicker }
end

--- A laptop table for a seated hacker at `actorPos` (their root), facing +Z:
--- the table top just under their forearms, a lounge chair under them, and a
--- laptop whose screen (`code`, red on black) is the key light on their face.
function Lounge.workTable(set: Instance, actorPos: Vector3, floorTop: number, code: string)
	local topY = actorPos.Y - 0.15
	local tz = actorPos.Z + 1.7
	local wood = Color3.fromRGB(110, 76, 50)
	newPart(set, "TableTop", V(4.4, 0.2, 2.2), CFrame.new(actorPos.X, topY - 0.1, tz), wood, M.Wood)
	local legH = topY - 0.2 - floorTop
	for _, sx in { -1.9, 1.9 } do
		newPart(set, "TableLeg", V(0.2, legH, 1.8), CFrame.new(actorPos.X + sx, floorTop + legH / 2, tz), Color3.fromRGB(34, 35, 40), M.Metal)
	end

	-- a lounge chair: the seat lands under the thighs (about 1.4 off the floor)
	local fabric = ({ Color3.fromRGB(64, 110, 120), Color3.fromRGB(176, 128, 52), Color3.fromRGB(120, 60, 64) })[math.random(3)]
	local seatTop = floorTop + 1.35
	newPart(set, "ChairSeat", V(2.2, 0.35, 2), CFrame.new(actorPos.X, seatTop - 0.175, actorPos.Z - 0.1), fabric, M.Fabric)
	newPart(set, "ChairBack", V(2.2, 2.2, 0.35), CFrame.new(actorPos.X, seatTop + 1.0, actorPos.Z - 1.2) * CFrame.Angles(math.rad(-8), 0, 0), fabric, M.Fabric)
	for _, sx in { -0.95, 0.95 } do
		for _, sz in { -0.95, 0.75 } do
			newPart(set, "ChairLeg", V(0.15, seatTop - 0.35 - floorTop, 0.15), CFrame.new(actorPos.X + sx, (floorTop + seatTop - 0.35) / 2, actorPos.Z + sz), Color3.fromRGB(34, 35, 40), M.Metal)
		end
	end

	-- The laptop's user side is its +Z, so it is turned to face the hacker.
	props = props or ReplicatedStorage:WaitForChild("CutsceneProps", 5)
	local tmpl = props and props:FindFirstChild("Laptop")
	local lap = if tmpl then tmpl:Clone() :: Model else nil
	if lap then
		lap:PivotTo(CFrame.new(actorPos.X, topY + 0.09, tz + 0.1) * CFrame.Angles(0, math.pi, 0))
		lap.Parent = set
		for _, c in lap:GetChildren() do
			if c.Name == "CodeLine" then
				c:Destroy()
			end
		end
		local screen = lap:FindFirstChild("Screen")
		if screen and screen:IsA("BasePart") then
			screen.Color = Color3.fromRGB(16, 12, 16)
			local gui = Instance.new("SurfaceGui")
			gui.Face = Enum.NormalId.Back
			gui.LightInfluence = 0
			gui.CanvasSize = Vector2.new(300, 190)
			gui.Parent = screen
			local text = Instance.new("TextLabel")
			text.Size = UDim2.fromScale(1, 1)
			text.BackgroundColor3 = Color3.fromRGB(10, 6, 9)
			text.FontFace = UITheme.Font.Mono
			text.TextColor3 = Color3.fromRGB(255, 70, 70)
			text.TextXAlignment = Enum.TextXAlignment.Left
			text.TextYAlignment = Enum.TextYAlignment.Top
			text.TextWrapped = true
			text.TextSize = 15
			text.Text = code
			text.Parent = gui
			-- in the dark room the screen is the key light on the hacker's face
			local face = Instance.new("PointLight")
			face.Color = Color3.fromRGB(255, 120, 110)
			face.Brightness = 1
			face.Range = 10
			face.Parent = screen
		end
	end
end

return Lounge
