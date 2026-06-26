--!strict
--------------------------------------------------------------------------------
-- AssetLibrary.luau  (ModuleScript)
-- Single source of truth for every static model that gets placed many times
-- (workstations, laptops, toilets, shelves...). MapBuilder & AmbientPopulation
-- CLONE these templates instead of building parts inline, so re-modelling one
-- template restyles every instance in the venue.
--
-- HOW TO REMODEL A TEMPLATE BY HAND (and keep your changes):
--   1. Press Play once. Each template appears under ServerStorage.AssetTemplates.
--   2. Stop. Copy the template you want (e.g. "Workstation") into Workspace and
--      edit it however you like in Studio.
--   3. Right-click it -> "Save to File..." and save it into this repo's
--      `assets/` folder as e.g. `assets/Workstation.rbxmx`.
--   4. Rojo syncs `assets/` into ReplicatedStorage.Assets. From then on the
--      AssetLibrary uses YOUR model (it prefers ReplicatedStorage.Assets.<name>
--      over the built-in fallback). Your hand edits now live in version control
--      and load every time.
--
-- Keep a part named "Root" as the model's PrimaryPart at the model's floor-level
-- origin so it lines up when placed. (Or just set the model's Pivot to the floor
-- centre in Studio.)
--------------------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local COLORS = GameConfig.COLORS

local AssetLibrary = {}

local cacheFolder = Instance.new("Folder")
cacheFolder.Name = "AssetTemplates"
cacheFolder.Parent = ServerStorage

local templates: { [string]: Instance } = {}

--------------------------------------------------------------------------------
-- Small part helper for the built-in fallbacks
--------------------------------------------------------------------------------
local function part(parent: Instance, name: string, size: Vector3, pos: Vector3, color: Color3, material: Enum.Material?, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Position = pos
	p.Anchored = true
	p.CanCollide = true
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	if shape then
		p.Shape = shape
	end
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

--- Like `part`, but creates a real Roblox Seat so a player (or NPC) can sit on it
--- just by stepping onto it. Used for the actually-sittable furniture surfaces.
local function seatPart(parent: Instance, name: string, size: Vector3, pos: Vector3, color: Color3, material: Enum.Material?, shape: Enum.PartType?): Seat
	local s = Instance.new("Seat")
	s.Name = name
	s.Size = size
	s.Position = pos
	s.Anchored = true
	s.CanCollide = true
	s.Color = color
	s.Material = material or Enum.Material.SmoothPlastic
	if shape then
		s.Shape = shape
	end
	s.TopSurface = Enum.SurfaceType.Smooth
	s.BottomSurface = Enum.SurfaceType.Smooth
	s.Parent = parent
	return s
end

--- Invisible origin part so Model:PivotTo lines the model up at floor level.
local function withRoot(model: Model): Model
	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(1, 1, 1)
	root.CFrame = CFrame.new(0, 0, 0)
	root.Anchored = true
	root.CanCollide = false
	root.Transparency = 1
	root.Parent = model
	model.PrimaryPart = root
	return model
end

--------------------------------------------------------------------------------
-- Built-in fallback builders (used until you drop a model into assets/)
-- All built around origin (0,0,0) = floor centre, facing -Z.
--------------------------------------------------------------------------------
local builders: { [string]: () -> Model } = {}

builders.Workstation = function(): Model
	local m = Instance.new("Model")
	m.Name = "Workstation"
	withRoot(m)
	part(m, "Desk", Vector3.new(6, 0.3, 3), Vector3.new(0, 3, 0), COLORS.DESK, Enum.Material.Wood)
	for sx = -1, 1, 2 do
		for sz = -1, 1, 2 do
			part(m, "Leg", Vector3.new(0.3, 3, 0.3), Vector3.new(sx * 2.6, 1.5, sz * 1.2), COLORS.CHAIR, Enum.Material.Metal)
		end
	end
	part(m, "Monitor", Vector3.new(3, 2, 0.25), Vector3.new(0, 4.4, -1.2), COLORS.MONITOR)
	-- The seat is at +Z, so the glowing screen must sit on the monitor's +Z
	-- (seat-facing) side, otherwise the person stares at the monitor's back.
	local screen = part(m, "Screen", Vector3.new(2.7, 1.7, 0.06), Vector3.new(0, 4.4, -1.05), COLORS.SCREEN, Enum.Material.Neon)
	local light = Instance.new("PointLight")
	light.Brightness = 0.35
	light.Range = 6
	light.Color = COLORS.SCREEN
	light.Parent = screen
	part(m, "Chair", Vector3.new(2, 0.3, 2), Vector3.new(0, 2, 1.8), COLORS.CHAIR, Enum.Material.Fabric)
	part(m, "ChairBack", Vector3.new(2, 2, 0.3), Vector3.new(0, 3, 2.7), COLORS.CHAIR, Enum.Material.Fabric)
	-- four legs under the seat so the chair isn't floating
	for sx = -1, 1, 2 do
		for sz = -1, 1, 2 do
			part(m, "ChairLeg", Vector3.new(0.25, 1.9, 0.25), Vector3.new(sx * 0.8, 0.95, 1.8 + sz * 0.8), Color3.fromRGB(60, 60, 65), Enum.Material.Metal)
		end
	end
	-- where an ambient typist sits (invisible marker; delete to force an empty desk)
	local seat = part(m, "Seat", Vector3.new(1.5, 0.2, 1.5), Vector3.new(0, 0, 1.8), Color3.new(1, 1, 1))
	seat.Transparency = 1
	seat.CanCollide = false
	return m
end

builders.Laptop = function(): Model
	local m = Instance.new("Model")
	m.Name = "Laptop"
	local base = part(m, "Base", Vector3.new(2, 0.18, 1.5), Vector3.new(0, 0, 0), Color3.fromRGB(60, 62, 70), Enum.Material.Metal)
	base.CanCollide = false
	m.PrimaryPart = base
	local screen = part(m, "Screen", Vector3.new(2, 1.3, 0.12), Vector3.new(0, 0.7, -0.75), Color3.fromRGB(120, 200, 255), Enum.Material.Neon)
	screen.CanCollide = false
	screen.CFrame = CFrame.new(0, 0.7, -0.75) * CFrame.Angles(math.rad(20), 0, 0)
	-- solid back lid behind the screen so it's not just a floating glowing pane
	local lid = part(m, "Lid", Vector3.new(2.12, 1.42, 0.1), Vector3.new(0, 0.7, -0.75), Color3.fromRGB(45, 47, 55), Enum.Material.Metal)
	lid.CanCollide = false
	lid.CFrame = screen.CFrame * CFrame.new(0, 0, 0.06)
	return m
end

builders.Toilet = function(): Model
	local m = Instance.new("Model")
	m.Name = "Toilet"
	withRoot(m)
	-- floor-mounted toilet; tank against the +Z wall, bowl/seat toward -Z (the user)
	part(m, "Pedestal", Vector3.new(1.4, 1.1, 1.2), Vector3.new(0, 0.55, 0.2), COLORS.TOILET)
	part(m, "Bowl", Vector3.new(1.8, 0.7, 1.9), Vector3.new(0, 1.1, -0.1), COLORS.TOILET)
	part(m, "Seat", Vector3.new(1.8, 0.2, 1.9), Vector3.new(0, 1.5, -0.1), Color3.fromRGB(225, 225, 230))
	part(m, "Tank", Vector3.new(1.8, 1.7, 0.6), Vector3.new(0, 1.7, 0.95), COLORS.TOILET)
	return m
end

builders.Urinal = function(): Model
	local m = Instance.new("Model")
	m.Name = "Urinal"
	withRoot(m)
	-- wall-mounted, faces -Z toward the user
	part(m, "Body", Vector3.new(1.8, 3, 1), Vector3.new(0, 3.2, 0.35), COLORS.TOILET)
	part(m, "Bowl", Vector3.new(1.5, 1.6, 0.9), Vector3.new(0, 2.4, -0.2), COLORS.TOILET)
	part(m, "Lip", Vector3.new(1.6, 0.3, 0.5), Vector3.new(0, 1.95, -0.5), COLORS.TOILET)
	local flush = part(m, "Flush", Vector3.new(0.5, 0.5, 0.4), Vector3.new(0, 4.7, 0.4), COLORS.METAL_BRUSHED, Enum.Material.Metal)
	flush.CanCollide = false
	return m
end

builders.Locker = function(): Model
	-- bank of 4 school lockers, faces -Z
	local m = Instance.new("Model")
	m.Name = "Locker"
	withRoot(m)
	part(m, "Body", Vector3.new(8, 7, 2), Vector3.new(0, 3.7, 0), COLORS.LOCKER, Enum.Material.Metal)
	part(m, "Base", Vector3.new(8, 0.4, 2), Vector3.new(0, 0.2, 0), Color3.fromRGB(70, 78, 88), Enum.Material.Metal)
	local doorColors = { Color3.fromRGB(96, 108, 120), Color3.fromRGB(108, 118, 128), Color3.fromRGB(88, 100, 112), Color3.fromRGB(100, 110, 122) }
	for i = 0, 3 do
		local dx = -3 + i * 2
		part(m, "Door", Vector3.new(1.8, 6.4, 0.15), Vector3.new(dx, 3.8, -1.02), doorColors[i + 1], Enum.Material.Metal)
		part(m, "Vent", Vector3.new(1.2, 0.5, 0.05), Vector3.new(dx, 6.3, -1.1), Color3.fromRGB(60, 66, 74), Enum.Material.Metal)
		local h = part(m, "Handle", Vector3.new(0.2, 0.6, 0.12), Vector3.new(dx + 0.6, 3.6, -1.12), Color3.fromRGB(40, 44, 50), Enum.Material.Metal)
		h.CanCollide = false
	end
	return m
end

builders.Bookshelf = function(): Model
	-- tall bookshelf packed with books, faces -Z
	local m = Instance.new("Model")
	m.Name = "Bookshelf"
	withRoot(m)
	part(m, "Back", Vector3.new(6, 9, 0.4), Vector3.new(0, 4.5, 0.8), Color3.fromRGB(96, 68, 44), Enum.Material.Wood)
	for sx = -1, 1, 2 do
		part(m, "Side", Vector3.new(0.4, 9, 2), Vector3.new(sx * 3, 4.5, 0), Color3.fromRGB(110, 78, 50), Enum.Material.Wood)
	end
	local bookCols = { Color3.fromRGB(170, 60, 55), Color3.fromRGB(60, 90, 160), Color3.fromRGB(70, 140, 80), Color3.fromRGB(200, 160, 60), Color3.fromRGB(140, 80, 160), Color3.fromRGB(90, 90, 100) }
	for s = 0, 3 do
		local sy = 1.6 + s * 2.2
		part(m, "Shelf", Vector3.new(5.6, 0.3, 1.8), Vector3.new(0, sy, 0), Color3.fromRGB(110, 78, 50), Enum.Material.Wood)
		local bx = -2.5
		while bx < 2.3 do
			local bw = 0.25 + math.random() * 0.22
			local bh = 1.1 + math.random() * 0.5
			local bk = part(m, "Book", Vector3.new(bw, bh, 1.4), Vector3.new(bx + bw / 2, sy + 0.15 + bh / 2, 0), bookCols[math.random(#bookCols)], Enum.Material.SmoothPlastic)
			bk.CanCollide = false
			bx = bx + bw + 0.04
		end
	end
	return m
end

builders.WaterFountain = function(): Model
	-- wall drinking fountain, faces -Z
	local m = Instance.new("Model")
	m.Name = "WaterFountain"
	withRoot(m)
	part(m, "Back", Vector3.new(2.4, 2.2, 0.4), Vector3.new(0, 4, 0.7), COLORS.METAL_BRUSHED, Enum.Material.Metal)
	part(m, "Basin", Vector3.new(2.6, 0.9, 1.6), Vector3.new(0, 3, -0.2), Color3.fromRGB(190, 195, 200), Enum.Material.Metal)
	local w = part(m, "Water", Vector3.new(2, 0.1, 1.1), Vector3.new(0, 3.35, -0.2), Color3.fromRGB(120, 190, 225), Enum.Material.Glass)
	w.CanCollide = false
	return m
end

builders.Lectern = function(): Model
	-- speaker's podium, faces -Z
	local m = Instance.new("Model")
	m.Name = "Lectern"
	withRoot(m)
	-- Kept short (3 high, not 4) so it sits at the speaker's chest and doesn't hide
	-- their shoulders/face when they present from just behind it.
	part(m, "Body", Vector3.new(3, 3, 2), Vector3.new(0, 1.5, 0), COLORS.PODIUM, Enum.Material.Wood)
	local top = part(m, "Top", Vector3.new(3.2, 0.3, 2.2), Vector3.new(0, 3.1, -0.2), Color3.fromRGB(60, 40, 24), Enum.Material.Wood)
	top.CFrame = top.CFrame * CFrame.Angles(math.rad(-12), 0, 0)
	local mic = part(m, "Mic", Vector3.new(0.15, 1.6, 0.15), Vector3.new(0.8, 3.6, -0.5), Color3.fromRGB(30, 30, 34), Enum.Material.Metal)
	mic.CanCollide = false
	return m
end

builders.NoticeBoard = function(): Model
	-- cork notice board with pinned flyers, wall-mounted, faces -Z
	local m = Instance.new("Model")
	m.Name = "NoticeBoard"
	withRoot(m)
	part(m, "Frame", Vector3.new(7, 5, 0.4), Vector3.new(0, 6, 0.1), COLORS.WOOD_TRIM, Enum.Material.Wood)
	part(m, "Cork", Vector3.new(6.3, 4.3, 0.1), Vector3.new(0, 6, -0.16), COLORS.CORK, Enum.Material.Wood)
	local noteCols = { Color3.fromRGB(245, 240, 210), Color3.fromRGB(220, 235, 245), Color3.fromRGB(245, 220, 225), Color3.fromRGB(225, 245, 220) }
	for _ = 1, 7 do
		local nx = -2.6 + math.random() * 5.2
		local ny = 4.2 + math.random() * 3.4
		local n = part(m, "Note", Vector3.new(0.8 + math.random() * 0.5, 0.8 + math.random() * 0.5, 0.06), Vector3.new(nx, ny, -0.24), noteCols[math.random(#noteCols)], Enum.Material.SmoothPlastic)
		n.CanCollide = false
		n.CFrame = n.CFrame * CFrame.Angles(0, 0, math.rad(math.random(-8, 8)))
	end
	return m
end

builders.TrophyCase = function(): Model
	-- glass display case with trophies, faces -Z
	local m = Instance.new("Model")
	m.Name = "TrophyCase"
	withRoot(m)
	part(m, "Cabinet", Vector3.new(6, 8, 2), Vector3.new(0, 4, 0.4), Color3.fromRGB(70, 50, 34), Enum.Material.Wood)
	for s = 0, 2 do
		part(m, "Shelf", Vector3.new(5.4, 0.2, 1.6), Vector3.new(0, 2.2 + s * 2.2, -0.2), Color3.fromRGB(90, 66, 44), Enum.Material.Wood)
	end
	local glass = part(m, "Glass", Vector3.new(5.6, 7, 0.1), Vector3.new(0, 4.2, -0.9), COLORS.GLASS, Enum.Material.Glass)
	glass.Transparency = 0.5
	glass.Reflectance = 0.1
	glass.CanCollide = false
	for s = 0, 2 do
		local sy = 2.4 + s * 2.2
		for t = -1, 1 do
			local cup = part(m, "Trophy", Vector3.new(0.7, 1.2, 0.7), Vector3.new(t * 1.6, sy + 0.6, -0.2), COLORS.UNI_GOLD, Enum.Material.Metal)
			cup.CanCollide = false
			local base = part(m, "TrophyBase", Vector3.new(0.5, 0.3, 0.5), Vector3.new(t * 1.6, sy + 0.15, -0.2), Color3.fromRGB(80, 55, 30), Enum.Material.Wood)
			base.CanCollide = false
		end
	end
	return m
end

builders.Shelf = function(): Model
	local m = Instance.new("Model")
	m.Name = "Shelf"
	withRoot(m)
	for i = 0, 2 do
		part(m, "Shelf", Vector3.new(10, 0.4, 2), Vector3.new(0, 2 + i * 3, 0), Color3.fromRGB(120, 90, 60), Enum.Material.Wood)
	end
	for sx = -1, 1, 2 do
		part(m, "Upright", Vector3.new(0.4, 8, 2), Vector3.new(sx * 5, 4, 0), Color3.fromRGB(90, 70, 45), Enum.Material.Wood)
	end
	return m
end

--------------------------------------------------------------------------------
-- Furniture / décor templates (all face -Z, origin at floor centre)
--------------------------------------------------------------------------------

builders.Couch = function(): Model
	local m = Instance.new("Model")
	m.Name = "Couch"
	withRoot(m)
	local body = Color3.fromRGB(72, 84, 112)
	local cushion = Color3.fromRGB(92, 104, 134)
	part(m, "Base", Vector3.new(8, 1.2, 3.4), Vector3.new(0, 1, 0), body, Enum.Material.Fabric)
	part(m, "Back", Vector3.new(8, 2.4, 0.8), Vector3.new(0, 2.2, 1.3), body, Enum.Material.Fabric)
	part(m, "ArmL", Vector3.new(0.8, 1.9, 3.4), Vector3.new(-3.6, 1.55, 0), body, Enum.Material.Fabric)
	part(m, "ArmR", Vector3.new(0.8, 1.9, 3.4), Vector3.new(3.6, 1.55, 0), body, Enum.Material.Fabric)
	-- the two cushions are sittable Seats (two spots per couch)
	seatPart(m, "CushionL", Vector3.new(3.4, 0.5, 2.8), Vector3.new(-1.8, 1.75, -0.1), cushion, Enum.Material.Fabric)
	seatPart(m, "CushionR", Vector3.new(3.4, 0.5, 2.8), Vector3.new(1.8, 1.75, -0.1), cushion, Enum.Material.Fabric)
	return m
end

builders.CoffeeTable = function(): Model
	local m = Instance.new("Model")
	m.Name = "CoffeeTable"
	withRoot(m)
	part(m, "Top", Vector3.new(5.5, 0.3, 2.8), Vector3.new(0, 1.6, 0), Color3.fromRGB(120, 90, 60), Enum.Material.Wood)
	for sx = -1, 1, 2 do
		for sz = -1, 1, 2 do
			part(m, "Leg", Vector3.new(0.3, 1.6, 0.3), Vector3.new(sx * 2.3, 0.8, sz * 1.0), Color3.fromRGB(90, 70, 45), Enum.Material.Wood)
		end
	end
	return m
end

builders.BistroTable = function(): Model
	local m = Instance.new("Model")
	m.Name = "BistroTable"
	withRoot(m)
	part(m, "Top", Vector3.new(4, 0.3, 4), Vector3.new(0, 3, 0), Color3.fromRGB(228, 228, 232), Enum.Material.SmoothPlastic)
	part(m, "Pole", Vector3.new(0.5, 3, 0.5), Vector3.new(0, 1.5, 0), Color3.fromRGB(120, 120, 125), Enum.Material.Metal)
	part(m, "Base", Vector3.new(2.2, 0.3, 2.2), Vector3.new(0, 0.15, 0), Color3.fromRGB(120, 120, 125), Enum.Material.Metal)
	return m
end

builders.OfficeChair = function(): Model
	local m = Instance.new("Model")
	m.Name = "OfficeChair"
	withRoot(m)
	seatPart(m, "Seat", Vector3.new(2, 0.3, 2), Vector3.new(0, 2, 0), COLORS.CHAIR, Enum.Material.Fabric)
	part(m, "Back", Vector3.new(2, 2.2, 0.3), Vector3.new(0, 3, 1), COLORS.CHAIR, Enum.Material.Fabric)
	part(m, "Post", Vector3.new(0.4, 2, 0.4), Vector3.new(0, 1, 0), Color3.fromRGB(60, 60, 65), Enum.Material.Metal)
	part(m, "Base", Vector3.new(2, 0.3, 2), Vector3.new(0, 0.15, 0), Color3.fromRGB(60, 60, 65), Enum.Material.Metal)
	return m
end

builders.TV = function(): Model
	local m = Instance.new("Model")
	m.Name = "TV"
	withRoot(m)
	-- wall-mounted screen at ~8 studs; faces -Z
	part(m, "Frame", Vector3.new(9, 5, 0.4), Vector3.new(0, 8, 0.2), Color3.fromRGB(20, 20, 24), Enum.Material.SmoothPlastic)
	local screen = part(m, "Screen", Vector3.new(8.2, 4.3, 0.12), Vector3.new(0, 8, 0), Color3.fromRGB(46, 64, 92), Enum.Material.Neon)
	local glow = Instance.new("PointLight")
	glow.Brightness = 0.5
	glow.Range = 12
	glow.Color = Color3.fromRGB(90, 140, 210)
	glow.Parent = screen
	return m
end

builders.Whiteboard = function(): Model
	local m = Instance.new("Model")
	m.Name = "Whiteboard"
	withRoot(m)
	part(m, "Board", Vector3.new(10, 5, 0.3), Vector3.new(0, 6, 0), COLORS.WHITEBOARD, Enum.Material.SmoothPlastic)
	part(m, "FrameTop", Vector3.new(10.4, 0.4, 0.45), Vector3.new(0, 8.5, 0), Color3.fromRGB(150, 150, 155), Enum.Material.Metal)
	part(m, "FrameBot", Vector3.new(10.4, 0.4, 0.45), Vector3.new(0, 3.5, 0), Color3.fromRGB(150, 150, 155), Enum.Material.Metal)
	part(m, "Tray", Vector3.new(8, 0.3, 0.8), Vector3.new(0, 3.5, -0.5), Color3.fromRGB(150, 150, 155), Enum.Material.Metal)
	return m
end

builders.Plant = function(): Model
	local m = Instance.new("Model")
	m.Name = "Plant"
	withRoot(m)
	part(m, "Pot", Vector3.new(2, 2, 2), Vector3.new(0, 1, 0), Color3.fromRGB(92, 72, 56), Enum.Material.Slate)
	part(m, "Foliage", Vector3.new(4.5, 5.5, 4.5), Vector3.new(0, 4.6, 0), Color3.fromRGB(58, 116, 58), Enum.Material.Grass, Enum.PartType.Ball)
	return m
end

builders.Vending = function(): Model
	local m = Instance.new("Model")
	m.Name = "Vending"
	withRoot(m)
	part(m, "Body", Vector3.new(4, 9, 3), Vector3.new(0, 4.5, 0), Color3.fromRGB(176, 44, 44), Enum.Material.SmoothPlastic)
	local front = part(m, "Front", Vector3.new(3, 6, 0.2), Vector3.new(0, 5.2, -1.5), Color3.fromRGB(40, 52, 64), Enum.Material.Neon)
	local glow = Instance.new("PointLight")
	glow.Brightness = 0.5
	glow.Range = 9
	glow.Color = Color3.fromRGB(120, 180, 255)
	glow.Parent = front
	return m
end

builders.WaterCooler = function(): Model
	local m = Instance.new("Model")
	m.Name = "WaterCooler"
	withRoot(m)
	part(m, "Base", Vector3.new(2, 4, 2), Vector3.new(0, 2, 0), Color3.fromRGB(232, 236, 240), Enum.Material.SmoothPlastic)
	part(m, "Jug", Vector3.new(1.7, 2, 1.7), Vector3.new(0, 5, 0), Color3.fromRGB(140, 200, 235), Enum.Material.Glass)
	return m
end

builders.BeanBag = function(): Model
	local m = Instance.new("Model")
	m.Name = "BeanBag"
	withRoot(m)
	seatPart(m, "Bag", Vector3.new(3.6, 2.2, 3.6), Vector3.new(0, 1.1, 0), Color3.fromRGB(204, 120, 44), Enum.Material.Fabric, Enum.PartType.Ball)
	return m
end

builders.SleepingBag = function(): Model
	-- A rolled-out sleeping bag on the floor. Runs along Z: head/pillow at -Z, foot
	-- at +Z. The covering quilt over the lower body hides a sleeper's legs, so a
	-- lying rig reads as "asleep in a bag" without needing a perfect lying pose.
	local m = Instance.new("Model")
	m.Name = "SleepingBag"
	withRoot(m)
	local bagCol = ({ COLORS.SLEEPING_BAG_1, COLORS.SLEEPING_BAG_2, COLORS.SLEEPING_BAG_3 })[math.random(3)]
	-- flat padded base
	part(m, "Pad", Vector3.new(3, 0.5, 7), Vector3.new(0, 0.3, 0), bagCol, Enum.Material.Fabric)
	-- quilt/cover bunched over the lower half (+Z), a touch darker
	part(m, "Cover", Vector3.new(3.1, 0.9, 4.6), Vector3.new(0, 0.85, 1.1), bagCol:Lerp(Color3.new(0, 0, 0), 0.28), Enum.Material.Fabric)
	-- pillow at the head end (-Z)
	part(m, "Pillow", Vector3.new(2.4, 0.7, 1.3), Vector3.new(0, 0.85, -2.8), Color3.fromRGB(228, 226, 232), Enum.Material.Fabric)
	return m
end

--------------------------------------------------------------------------------
-- Template resolution: prefer a user model in ReplicatedStorage.Assets, else
-- build the fallback. The resolved template is parked in
-- ServerStorage.AssetTemplates so you can grab and remodel it.
--------------------------------------------------------------------------------
local function getTemplate(name: string): Instance?
	if templates[name] then
		return templates[name]
	end

	local tmpl: Instance? = nil
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local override = assets and assets:FindFirstChild(name)
	if override and (override:IsA("Model") or override:IsA("BasePart")) then
		tmpl = override:Clone()
	elseif builders[name] then
		tmpl = builders[name]()
	end

	if tmpl then
		tmpl.Parent = cacheFolder
		templates[name] = tmpl
	end
	return tmpl
end

--- Clone an asset and (optionally) place it. Returns the clone, or nil if the
--- name is unknown and has no user override.
function AssetLibrary.clone(name: string, pivot: CFrame?): Model?
	local tmpl = getTemplate(name)
	if not tmpl then
		return nil
	end
	local c = tmpl:Clone()
	if pivot then
		if c:IsA("Model") then
			c:PivotTo(pivot)
		elseif c:IsA("BasePart") then
			c.CFrame = pivot
		end
	end
	return c :: Model
end

return AssetLibrary
