--!strict
--------------------------------------------------------------------------------
-- Kit.luau
-- Part helpers shared by the venue builder and the furniture templates.
--
-- Every static part goes through here so the defaults stay consistent:
-- anchored, smooth surfaces, no Touched events, and no shadows from small
-- trim. A desk's worth of tiny shadow casters is most of what a room costs to
-- render, and none of them throw a shadow anyone would notice.
--------------------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local Kit = {}

Kit.TAGS = GameConfig.TAGS
Kit.COLORS = GameConfig.COLORS

export type At = CFrame | Vector3
export type Opts = {
	collide: boolean?,
	transparency: number?,
	reflectance: number?,
	shadow: boolean?,
}

-- Parts no bigger than this along any axis cast no shadow unless asked to.
local SMALL = 1.5

local function toCF(at: At): CFrame
	if typeof(at) == "Vector3" then
		return CFrame.new(at)
	end
	return at
end
Kit.cf = toCF

local function finish(p: BasePart, at: At, color: Color3, material: Enum.Material?, opts: Opts?, parent: Instance)
	p.CFrame = toCF(at)
	p.Anchored = true
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanTouch = false
	local o = opts or {}
	p.CanCollide = if o.collide ~= nil then o.collide else true
	p.Transparency = o.transparency or 0
	p.Reflectance = o.reflectance or 0
	local s = p.Size
	p.CastShadow = if o.shadow ~= nil then o.shadow else math.max(s.X, s.Y, s.Z) > SMALL
	p.Parent = parent
end

function Kit.part(
	parent: Instance,
	name: string,
	size: Vector3,
	at: At,
	color: Color3,
	material: Enum.Material?,
	opts: Opts?
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	finish(p, at, color, material, opts, parent)
	return p
end

--- Non-colliding trim. Most of the detail in the venue is this.
function Kit.trim(
	parent: Instance,
	name: string,
	size: Vector3,
	at: At,
	color: Color3,
	material: Enum.Material?,
	opts: Opts?
): Part
	local o: Opts = opts or {}
	return Kit.part(parent, name, size, at, color, material, {
		collide = false,
		transparency = o.transparency,
		reflectance = o.reflectance,
		shadow = o.shadow,
	})
end

--- Wedge: the slope runs from the top of the -Z face down to the bottom of
--- the +Z face.
function Kit.wedge(
	parent: Instance,
	name: string,
	size: Vector3,
	at: At,
	color: Color3,
	material: Enum.Material?,
	opts: Opts?
): WedgePart
	local p = Instance.new("WedgePart")
	p.Name = name
	p.Size = size
	finish(p, at, color, material, opts, parent)
	return p
end

--- Cylinder along the part's own X axis (Roblox's convention).
function Kit.cyl(
	parent: Instance,
	name: string,
	length: number,
	diameter: number,
	at: At,
	color: Color3,
	material: Enum.Material?,
	opts: Opts?
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Shape = Enum.PartType.Cylinder
	p.Size = Vector3.new(length, diameter, diameter)
	finish(p, at, color, material, opts, parent)
	return p
end

--- Upright cylinder, standing on its end.
function Kit.cylY(
	parent: Instance,
	name: string,
	height: number,
	diameter: number,
	at: At,
	color: Color3,
	material: Enum.Material?,
	opts: Opts?
): Part
	return Kit.cyl(parent, name, height, diameter, toCF(at) * CFrame.Angles(0, 0, math.pi / 2), color, material, opts)
end

--- Cylinder lying along Z.
function Kit.cylZ(
	parent: Instance,
	name: string,
	length: number,
	diameter: number,
	at: At,
	color: Color3,
	material: Enum.Material?,
	opts: Opts?
): Part
	return Kit.cyl(parent, name, length, diameter, toCF(at) * CFrame.Angles(0, math.pi / 2, 0), color, material, opts)
end

--- Ellipsoid of any proportions. A Ball part is forced round, so this is a
--- block carrying a sphere mesh; its collision box is the block.
function Kit.blob(
	parent: Instance,
	name: string,
	size: Vector3,
	at: At,
	color: Color3,
	material: Enum.Material?,
	opts: Opts?
): Part
	local p = Kit.part(parent, name, size, at, color, material, opts)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = p
	return p
end

--- A real Seat, so a player or NPC can sit on it by stepping onto it.
function Kit.seat(
	parent: Instance,
	name: string,
	size: Vector3,
	at: At,
	color: Color3,
	material: Enum.Material?,
	shape: Enum.PartType?
): Seat
	local s = Instance.new("Seat")
	s.Name = name
	if shape then
		s.Shape = shape
	end
	s.Size = size
	finish(s, at, color, material, nil, parent)
	return s
end

function Kit.light(parent: Instance, brightness: number, range: number, color: Color3?, enabled: boolean?): PointLight
	local l = Instance.new("PointLight")
	l.Brightness = brightness
	l.Range = range
	l.Color = color or Color3.fromRGB(255, 244, 222)
	l.Enabled = if enabled ~= nil then enabled else true
	l.Parent = parent
	return l
end

function Kit.tag(inst: Instance, t: string)
	CollectionService:AddTag(inst, t)
end

--- Apply a GameConfig.SURFACES role (material and reflectance).
function Kit.surface(part: BasePart, roleName: string)
	local role = GameConfig.SURFACES[roleName]
	if not role then
		warn("[Venue] Unknown surface role:", roleName)
		return
	end
	part.Material = role.material
	part.Reflectance = role.reflectance
end

--- Text on one face of a part. `bg` nil leaves the part's own colour showing.
--- `lit` renders at full brightness regardless of scene light (signs, screens).
function Kit.label(
	part: BasePart,
	face: Enum.NormalId,
	text: string,
	fg: Color3,
	bg: Color3?,
	font: Enum.Font?,
	lit: boolean?
): TextLabel
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 24
	if lit then
		gui.LightInfluence = 0
	end
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = if bg then 0 else 1
	label.BackgroundColor3 = bg or Color3.new()
	label.BorderSizePixel = 0
	label.TextColor3 = fg
	label.TextScaled = true
	label.TextWrapped = true
	label.Font = font or Enum.Font.GothamBold
	label.Text = text
	label.Parent = gui
	gui.Parent = part
	return label
end

--- A Model with an invisible "Root" PrimaryPart at the origin, so PivotTo
--- lines the template up by its floor-level origin.
function Kit.model(name: string): Model
	local m = Instance.new("Model")
	m.Name = name
	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(1, 1, 1)
	root.Anchored = true
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.Transparency = 1
	root.Parent = m
	m.PrimaryPart = root
	return m
end

function Kit.pick<T>(t: { T }): T
	return t[math.random(#t)]
end

--------------------------------------------------------------------------------
-- Emissive screens
--------------------------------------------------------------------------------
-- Roblox has no emissive channel, so a screen that reads as ON in a dark room
-- is three things stacked: Neon (ignores scene light), a SurfaceGui with
-- LightInfluence 0 (content at full brightness), and a light so it actually
-- throws a glow onto the desk. Tagged EMISSIVE_SCREEN for the night systems.
--------------------------------------------------------------------------------
export type ScreenOptions = {
	color: Color3?,
	brightness: number?,
	range: number?,
	lineCount: number?,
	-- Draw the code as a few glowing strips instead of a SurfaceGui. Roblox
	-- only renders so many SurfaceGuis at once; past that budget the signs
	-- and posters start to vanish, and there are hundreds of desk monitors.
	strips: boolean?,
}

local function drawCode(surface: SurfaceGui, tint: Color3, lineCount: number)
	local pad = 0.07
	local rowH = (1 - pad * 2) / lineCount
	for i = 1, lineCount do
		local row = Instance.new("Frame")
		row.BorderSizePixel = 0
		row.BackgroundColor3 = if i % 4 == 1 then Color3.fromRGB(255, 220, 140) else tint
		local indent = (i % 3) * 0.06
		-- Ragged right edge so the rows read as code rather than a bar chart.
		row.Size = UDim2.fromScale(0.3 + math.random() * 0.5, rowH * 0.42)
		row.Position = UDim2.fromScale(pad + indent, pad + (i - 1) * rowH)
		row.BackgroundTransparency = 0.2 + math.random() * 0.35
		row.Parent = surface
	end
end

function Kit.screen(
	parent: Instance,
	name: string,
	size: Vector3,
	at: At,
	face: Enum.NormalId,
	options: ScreenOptions?
): Part
	local opts = options or {}
	local tint = opts.color or Kit.COLORS.SCREEN
	local panel = Kit.trim(parent, name, size, at, tint:Lerp(Color3.new(), 0.55), Enum.Material.Neon)
	if opts.strips then
		local cf = toCF(at)
		local out = if face == Enum.NormalId.Back then 1 else -1
		local rows = opts.lineCount or 5
		for i = 1, rows do
			local w = size.X * (0.3 + ((i * 37) % 10) / 20)
			local yOff = size.Y * (0.38 - (i - 1) * 0.76 / math.max(1, rows - 1))
			local xOff = -size.X * 0.42 + w / 2 + (i % 3) * size.X * 0.04
			Kit.trim(
				parent,
				"CodeLine",
				Vector3.new(w, size.Y * 0.06, 0.02),
				cf * CFrame.new(xOff, yOff, out * (size.Z / 2 + 0.01)),
				if i % 4 == 1 then Color3.fromRGB(255, 220, 140) else tint,
				Enum.Material.Neon,
				{ shadow = false }
			)
		end
	else
		local surface = Instance.new("SurfaceGui")
		surface.Name = "ScreenContent"
		surface.Face = face
		surface.LightInfluence = 0
		surface.PixelsPerStud = 40
		surface.Parent = panel
		drawCode(surface, tint, opts.lineCount or 7)
	end
	-- Only screens that ask for a light get one. There are hundreds of desk
	-- monitors, and past a few hundred local lights the renderer starts
	-- dropping the ceiling lights that actually matter.
	if opts.brightness and opts.range then
		local glow = Kit.light(panel, opts.brightness, opts.range, tint)
		glow.Shadows = false
	end
	Kit.tag(panel, Kit.TAGS.EMISSIVE_SCREEN)
	return panel
end

return Kit
