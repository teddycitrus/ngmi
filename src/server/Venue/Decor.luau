--!strict
--------------------------------------------------------------------------------
-- Decor.luau
-- Placement helpers and the small set dressing every builder shares: furniture
-- placement, trash scatter, framed posters, sponsor banners and signage.
--------------------------------------------------------------------------------

local Kit = require(script.Parent.Kit)
local Walls = require(script.Parent.Walls)
local AssetLibrary = require(script.Parent.Parent.AssetLibrary)

local Decor = {}

local INK = Color3.fromRGB(35, 35, 42)
local PAPER = Color3.fromRGB(245, 244, 238)
local FRAME = Color3.fromRGB(38, 40, 46)

--------------------------------------------------------------------------------
-- Placement
--------------------------------------------------------------------------------

--- Clone a template at (x, y, z) turned yawDeg about Y.
function Decor.place(name: string, x: number, y: number, z: number, yawDeg: number?, parent: Instance): Model?
	local c = AssetLibrary.clone(name, CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yawDeg or 0), 0))
	if c then
		c.Parent = parent
	end
	return c
end

-- Depth of the floor-standing templates that back onto a wall. Anything not
-- listed is wall-hung: its origin is already on its back face.
local DEPTH: { [string]: number } = {
	Locker = 2,
	Bookshelf = 2,
	TrophyCase = 2.2,
	Vending = 3.2,
	Fridge = 2.8,
	WaterCooler = 1.8,
	Printer = 2.4,
	Shelf = 2,
	Bench = 1.8,
	TrashBin = 1.5,
	Plant = 2.4,
	PlantTall = 2.2,
	Couch = 3.4,
	Credenza = 1.8,
	HandDryer = 0,
	Lectern = 2,
}

--- Back a template onto a wall. `wallPos` is any point on the wall's centre
--- line at floor height; `out` is the unit normal pointing into the space.
function Decor.onWall(parent: Instance, name: string, wallPos: Vector3, out: Vector3): Model?
	local depth = DEPTH[name] or 0
	local p = wallPos + out * (Walls.FACE + depth / 2)
	local c = AssetLibrary.clone(name, CFrame.lookAt(p, p + out))
	if c then
		c.Parent = parent
	end
	return c
end

--------------------------------------------------------------------------------
-- Trash
--------------------------------------------------------------------------------
local CANS = {
	Color3.fromRGB(200, 40, 40),
	Color3.fromRGB(40, 120, 220),
	Color3.fromRGB(60, 180, 90),
	Color3.fromRGB(240, 180, 40),
	Color3.fromRGB(150, 60, 200),
	Color3.fromRGB(30, 30, 34),
}
local BAGS = {
	Color3.fromRGB(222, 162, 40),
	Color3.fromRGB(210, 60, 50),
	Color3.fromRGB(40, 150, 90),
	Color3.fromRGB(60, 90, 200),
}
local SILVER = Color3.fromRGB(196, 198, 204)

--- Scatter `count` non-colliding bits of junk over a rectangle at surfaceY.
function Decor.scatter(
	parent: Instance,
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
	surfaceY: number,
	count: number
)
	for _ = 1, count do
		local x = minX + math.random() * math.max(0.01, maxX - minX)
		local z = minZ + math.random() * math.max(0.01, maxZ - minZ)
		local base = CFrame.new(x, surfaceY, z) * CFrame.Angles(0, math.random() * math.pi * 2, 0)
		local roll = math.random(1, 8)
		if roll == 6 and (maxX - minX < 4 or maxZ - minZ < 4) then
			roll = 5 -- a pizza box doesn't fit on a desk; leave a cup instead
		end
		if roll <= 2 then
			-- standing can, tall energy drink or squat soda
			local tall = roll == 1
			local h = if tall then 0.85 else 0.6
			local d = if tall then 0.36 else 0.42
			Kit.cylY(parent, "Can", h, d, base * CFrame.new(0, h / 2, 0), Kit.pick(CANS), Enum.Material.Metal, { collide = false })
			Kit.cylY(parent, "CanTop", 0.04, d * 0.9, base * CFrame.new(0, h + 0.02, 0), SILVER, Enum.Material.Metal, { collide = false })
		elseif roll == 3 then
			-- crushed can on its side
			Kit.cyl(parent, "Can", 0.5, 0.42, base * CFrame.new(0, 0.2, 0) * CFrame.Angles(0, 0, math.rad(8)), Kit.pick(CANS), Enum.Material.Metal, { collide = false })
		elseif roll == 4 then
			-- chip bag, puffed
			Kit.blob(parent, "ChipBag", Vector3.new(1.3, 0.35, 1.8), base * CFrame.new(0, 0.16, 0), Kit.pick(BAGS), Enum.Material.Foil, { collide = false })
		elseif roll == 5 then
			-- coffee cup with lid and sleeve
			Kit.cylY(parent, "Cup", 0.75, 0.48, base * CFrame.new(0, 0.38, 0), PAPER, Enum.Material.SmoothPlastic, { collide = false })
			Kit.cylY(parent, "Sleeve", 0.3, 0.52, base * CFrame.new(0, 0.38, 0), Color3.fromRGB(150, 110, 70), Enum.Material.Cardboard, { collide = false })
			Kit.cylY(parent, "Lid", 0.08, 0.54, base * CFrame.new(0, 0.79, 0), Color3.fromRGB(40, 40, 44), Enum.Material.SmoothPlastic, { collide = false })
		elseif roll == 6 then
			-- pizza box, lid propped open on a few
			local box = Color3.fromRGB(206, 176, 136)
			Kit.part(parent, "PizzaBox", Vector3.new(3, 0.3, 3), base * CFrame.new(0, 0.15, 0), box, Enum.Material.Cardboard, { collide = false })
			if math.random() < 0.4 then
				Kit.part(
					parent,
					"PizzaLid",
					Vector3.new(3, 0.06, 3),
					base * CFrame.new(0, 0.3, 1.5) * CFrame.Angles(math.rad(70), 0, 0) * CFrame.new(0, 0, -1.5),
					box,
					Enum.Material.Cardboard,
					{ collide = false }
				)
			end
		elseif roll == 7 then
			-- crumpled paper
			Kit.blob(parent, "Paper", Vector3.new(0.5, 0.42, 0.48), base * CFrame.new(0, 0.2, 0), PAPER, Enum.Material.SmoothPlastic, { collide = false })
		else
			-- loose printouts
			Kit.part(parent, "Papers", Vector3.new(1.7, 0.04, 2.2), base * CFrame.new(0, 0.03, 0), PAPER, Enum.Material.SmoothPlastic, { collide = false })
		end
	end
end

--------------------------------------------------------------------------------
-- Posters and sponsors
--------------------------------------------------------------------------------
export type Poster = { title: string, body: string, accent: Color3, paper: Color3, fg: Color3 }

local CORK = Color3.fromRGB(150, 110, 66)

Decor.POSTERS = {
	{ title = "NGMI HACKATHON", body = "48 HOURS\n∞ POSSIBILITIES\n1 WINNER", accent = Color3.fromRGB(200, 40, 40), paper = PAPER, fg = INK },
	{ title = "STAY HYDRATED", body = "Water > Energy Drinks.\n(We know. We're sorry.)", accent = Color3.fromRGB(40, 130, 210), paper = PAPER, fg = INK },
	{ title = "FREE WIFI", body = "SSID: VesperHacks_5G\npass: hunter2", accent = Color3.fromRGB(40, 160, 90), paper = PAPER, fg = INK },
	{ title = "DEMO DAY", body = "Sunday · 4 PM\nMain Stage\nWorking demos only!", accent = Color3.fromRGB(150, 60, 200), paper = PAPER, fg = INK },
	{ title = "DEADLINE LOOMS", body = "Ship before Night 2.\nThe ones who didn't...\nwe don't talk about.", accent = Color3.fromRGB(40, 40, 48), paper = Color3.fromRGB(220, 210, 200), fg = INK },
	{ title = "IN CASE OF EMERGENCY", body = "Stay calm.\nFind the exits.\nDo NOT look behind you.", accent = Color3.fromRGB(210, 150, 20), paper = PAPER, fg = INK },
	{ title = "LOST & FOUND", body = "Missing: 1 mentor,\n3 attendees, and\nall sense of time.", accent = Color3.fromRGB(180, 50, 50), paper = Color3.fromRGB(235, 230, 222), fg = INK },
	{ title = "BULLETIN BOARD", body = "★ Team seeking designer\n★ Charger borrowed (sorry)\n★ Has anyone seen Dev?", accent = Color3.fromRGB(120, 80, 40), paper = CORK, fg = Color3.fromRGB(250, 248, 240) },
	{ title = "ST. VESPER UNIVERSITY", body = "Dept. of Computer Science\nHalberd Engineering Hall", accent = Color3.fromRGB(110, 28, 40), paper = PAPER, fg = INK },
	{ title = "ACM STUDENT CHAPTER", body = "Weekly meetups\nThu 6 PM · Room 204\nFree pizza (while it lasts)", accent = Color3.fromRGB(40, 160, 90), paper = PAPER, fg = INK },
	{ title = "OFFICE HOURS", body = "Prof. Halberd\nMon / Wed 2-4 PM\nRoom 311 (knock loudly)", accent = Color3.fromRGB(40, 90, 200), paper = PAPER, fg = INK },
	{ title = "GO ROBO-LIONS", body = "Engineering vs. Business\nIntramural Finals\nGym · Sat 7 PM", accent = Color3.fromRGB(150, 40, 50), paper = Color3.fromRGB(235, 225, 200), fg = INK },
	{ title = "CAREER FAIR", body = "Main Atrium · Friday\nBring résumés.\nLeave with regrets.", accent = Color3.fromRGB(150, 60, 200), paper = PAPER, fg = INK },
} :: { Poster }

export type Sponsor = { name: string, tagline: string, color: Color3 }

Decor.SPONSORS = {
	{ name = "MEGACORP", tagline = "Enterprise Synergy, at Scale", color = Color3.fromRGB(190, 40, 40) },
	{ name = "NIMBUSCLOUD", tagline = "∞ Free Credits*  (*terms apply)", color = Color3.fromRGB(40, 90, 200) },
	{ name = "BYTEBITES", tagline = "Snacks That Hack Back", color = Color3.fromRGB(40, 160, 80) },
	{ name = "QUANTUMLEAP AI", tagline = "Your Code, But Sentient™", color = Color3.fromRGB(130, 50, 190) },
	{ name = "DEVTOOLS INC", tagline = "We Tool So You Don't Have To", color = Color3.fromRGB(220, 140, 30) },
	{ name = "HYPERSTACK", tagline = "Move Fast · Break Everything", color = Color3.fromRGB(20, 150, 150) },
} :: { Sponsor }

--- Header band plus body copy on one face of a panel.
function Decor.printed(part: BasePart, face: Enum.NormalId, title: string, body: string, accent: Color3, fg: Color3)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 24
	gui.Parent = part

	local header = Instance.new("TextLabel")
	header.Size = UDim2.fromScale(1, 0.28)
	header.BackgroundColor3 = accent
	header.BorderSizePixel = 0
	header.Text = title
	header.TextColor3 = Color3.new(1, 1, 1)
	header.Font = Enum.Font.GothamBlack
	header.TextScaled = true
	header.Parent = gui
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0.06, 0)
	pad.PaddingRight = UDim.new(0.06, 0)
	pad.PaddingTop = UDim.new(0.08, 0)
	pad.PaddingBottom = UDim.new(0.08, 0)
	pad.Parent = header

	local copy = Instance.new("TextLabel")
	copy.AnchorPoint = Vector2.new(0.5, 0)
	copy.Position = UDim2.fromScale(0.5, 0.34)
	copy.Size = UDim2.fromScale(0.88, 0.6)
	copy.BackgroundTransparency = 1
	copy.Text = body
	copy.TextColor3 = fg
	copy.Font = Enum.Font.GothamMedium
	copy.TextScaled = true
	copy.TextWrapped = true
	copy.Parent = gui
end

--- A framed poster on a wall. `wallPos` is on the wall centre line at the
--- poster's centre height; `out` points into the space it faces.
function Decor.poster(parent: Instance, wallPos: Vector3, out: Vector3, poster: Poster, w: number?, h: number?)
	local pw, ph = w or 4.2, h or 5.4
	local p = wallPos + out * (Walls.FACE + 0.06)
	local cf = CFrame.lookAt(p, p + out)
	Kit.trim(parent, "PosterFrame", Vector3.new(pw + 0.3, ph + 0.3, 0.1), cf, FRAME, Enum.Material.Metal)
	local paper = Kit.trim(parent, "Poster", Vector3.new(pw, ph, 0.06), cf * CFrame.new(0, 0, -0.05), poster.paper, Enum.Material.SmoothPlastic)
	Decor.printed(paper, Enum.NormalId.Front, poster.title, poster.body, poster.accent, poster.fg)
end

--- A pull-up sponsor banner standing in a hall, printed face looking along `out`.
function Decor.bannerStand(parent: Instance, pos: Vector3, out: Vector3, sponsor: Sponsor)
	local cf = CFrame.lookAt(pos, pos + out)
	local dark = Color3.fromRGB(36, 38, 44)
	local alu = Color3.fromRGB(176, 180, 186)
	-- cassette base with a rounded front, two splayed feet
	Kit.part(parent, "BannerBase", Vector3.new(5.4, 0.5, 0.9), cf * CFrame.new(0, 0.3, 0), alu, Enum.Material.Metal)
	Kit.cyl(parent, "BannerRoll", 5.4, 0.5, cf * CFrame.new(0, 0.55, -0.2), alu, Enum.Material.Metal, { collide = false })
	for _, sx in { -1, 1 } do
		Kit.trim(parent, "BannerFoot", Vector3.new(0.3, 0.12, 2.4), cf * CFrame.new(sx * 2.4, 0.06, 0), dark, Enum.Material.Metal)
	end
	Kit.trim(parent, "BannerPole", Vector3.new(0.14, 10.4, 0.14), cf * CFrame.new(0, 5.6, 0.12), alu, Enum.Material.Metal)
	Kit.trim(parent, "BannerBar", Vector3.new(5.2, 0.18, 0.18), cf * CFrame.new(0, 10.8, 0), alu, Enum.Material.Metal)
	local banner = Kit.part(parent, "Banner", Vector3.new(5, 10.1, 0.06), cf * CFrame.new(0, 5.75, 0), sponsor.color, Enum.Material.Fabric, { collide = false })
	Decor.printed(banner, Enum.NormalId.Front, sponsor.name, sponsor.tagline, Color3.fromRGB(20, 20, 26), Color3.fromRGB(250, 250, 250))
end

--- A cloth banner hanging from a ceiling rod, printed face looking along `out`.
function Decor.hangingBanner(parent: Instance, top: Vector3, out: Vector3, length: number, color: Color3, title: string, body: string)
	local cf = CFrame.lookAt(top, top + out)
	local rod = Color3.fromRGB(130, 132, 140)
	Kit.cyl(parent, "BannerRod", 5.6, 0.25, cf, rod, Enum.Material.Metal, { collide = false })
	for _, sx in { -1, 1 } do
		Kit.trim(parent, "BannerWire", Vector3.new(0.05, 1.4, 0.05), cf * CFrame.new(sx * 2.3, 0.7, 0), rod, Enum.Material.Metal)
	end
	local cloth = Kit.part(parent, "Flag", Vector3.new(5, length, 0.16), cf * CFrame.new(0, -length / 2, 0), color, Enum.Material.Fabric, { collide = false })
	Decor.printed(cloth, Enum.NormalId.Front, title, body, Color3.fromRGB(20, 20, 26), Color3.fromRGB(245, 245, 245))
	Kit.trim(parent, "FlagHem", Vector3.new(5.1, 0.3, 0.2), cf * CFrame.new(0, -length + 0.14, 0), Color3.fromRGB(212, 175, 60), Enum.Material.Fabric)
end

--------------------------------------------------------------------------------
-- Signage
--------------------------------------------------------------------------------

--- A double-sided sign projecting from a wall above a door, readable from
--- down the hall. `wallPos` is on the wall centre line at the sign's height.
function Decor.bladeSign(parent: Instance, wallPos: Vector3, out: Vector3, text: string, accent: Color3)
	local len = 3.6
	local p = wallPos + out * (Walls.FACE + len / 2 + 0.15)
	local cf = CFrame.lookAt(p, p + out)
	Kit.trim(parent, "SignBracket", Vector3.new(0.2, 0.2, len + 0.3), cf * CFrame.new(0, 0.75, 0), FRAME, Enum.Material.Metal)
	local blade = Kit.trim(parent, "RoomSign", Vector3.new(0.18, 1.2, len), cf, Color3.fromRGB(28, 30, 38), Enum.Material.SmoothPlastic)
	Kit.trim(parent, "SignStripe", Vector3.new(0.2, 0.18, len + 0.04), cf * CFrame.new(0, -0.6, 0), accent, Enum.Material.SmoothPlastic)
	for _, face in { Enum.NormalId.Left, Enum.NormalId.Right } do
		Kit.label(blade, face, text, Color3.fromRGB(236, 238, 242), nil, Enum.Font.GothamBold, true)
	end
end

--- Room number plaque beside a door.
function Decor.plaque(parent: Instance, wallPos: Vector3, out: Vector3, number: string, name: string, accent: Color3)
	local p = wallPos + out * (Walls.FACE + 0.05)
	local cf = CFrame.lookAt(p, p + out)
	local plate = Kit.trim(parent, "Plaque", Vector3.new(1.5, 1.1, 0.08), cf, Color3.fromRGB(30, 32, 38), Enum.Material.SmoothPlastic)
	Kit.trim(parent, "PlaqueBar", Vector3.new(1.54, 0.16, 0.1), cf * CFrame.new(0, 0.48, 0), accent, Enum.Material.SmoothPlastic)
	Kit.label(plate, Enum.NormalId.Front, number .. "\n" .. name, Color3.fromRGB(230, 232, 236), nil, Enum.Font.GothamMedium)
end

--- Lit EXIT sign, wall-mounted above a door.
function Decor.exitSign(parent: Instance, wallPos: Vector3, out: Vector3)
	local p = wallPos + out * (Walls.FACE + 0.25)
	local cf = CFrame.lookAt(p, p + out)
	Kit.trim(parent, "ExitBox", Vector3.new(2.4, 1, 0.45), cf, Color3.fromRGB(236, 236, 230), Enum.Material.SmoothPlastic)
	local face = Kit.trim(parent, "ExitFace", Vector3.new(2.1, 0.75, 0.06), cf * CFrame.new(0, 0, -0.24), Color3.fromRGB(70, 12, 12), Enum.Material.Neon)
	Kit.label(face, Enum.NormalId.Front, "EXIT", Color3.fromRGB(255, 70, 60), Color3.fromRGB(40, 6, 6), Enum.Font.GothamBlack, true)
end

--- Two-line wayfinding sign hanging from the ceiling across a hall.
function Decor.hangingSign(parent: Instance, pos: Vector3, out: Vector3, front: string, back: string, accent: Color3)
	local cf = CFrame.lookAt(pos, pos + out)
	local w = 8
	for _, sx in { -1, 1 } do
		Kit.trim(parent, "SignRod", Vector3.new(0.08, 1.4, 0.08), cf * CFrame.new(sx * (w / 2 - 0.5), 1.35, 0), FRAME, Enum.Material.Metal)
	end
	local board = Kit.trim(parent, "WayfindingSign", Vector3.new(w, 1.3, 0.16), cf, Color3.fromRGB(28, 30, 38), Enum.Material.SmoothPlastic)
	Kit.trim(parent, "SignStripe", Vector3.new(w + 0.04, 0.16, 0.18), cf * CFrame.new(0, -0.65, 0), accent, Enum.Material.SmoothPlastic)
	Kit.label(board, Enum.NormalId.Front, front, Color3.fromRGB(236, 238, 242), nil, Enum.Font.GothamBold, true)
	Kit.label(board, Enum.NormalId.Back, back, Color3.fromRGB(236, 238, 242), nil, Enum.Font.GothamBold, true)
end

return Decor
