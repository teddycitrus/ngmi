--!strict
--------------------------------------------------------------------------------
-- NGMIStyles.luau
-- The four ways a hacker turns. Shared.NGMIMutation builds and grows them;
-- each style sets:
--
--   build      the growths, each tagged with the progress (0..1) at which it
--              starts to show, so a style has its own order of change
--   palette    rot colours, accent (veins, bone, fungus, neon), eye colour,
--              skin material and the smoke the cutscene gives off
--   twist      the skeletal deformity (RigPose degrees) the animators layer
--              under every pose, reached at progress `twistFull`
--   tremor     constant shake (degrees, hz); `stutter` scales how often the
--              animator drops frames
--   grow       progress window over which one growth swells in; 0 pops it in
--   turn       the on-screen turn: seconds to go 0 -> 1, eased by `turnEase`
--   night      gameplay NGMIs spawn at `from` and keep changing to `to` over
--              `over` seconds, in `steps` jumps when given
--
--   bloated   the original NGMI: swollen skull, eye cluster, hump, spines
--   splitter  a dry husk split open: head parted down a lit seam, ribs
--             splayed out of the chest, bone blades down the back
--   bloom     a fungal overgrowth: plates fanned round the face, spreading
--             from the head down the body
--   glitch    the code ate them: displaced blocks, neon scan bands, a
--             dissolving arm; changes in hard jumps
--------------------------------------------------------------------------------

local V = Vector3.new
local CF = CFrame.new
local rad = math.rad
local SPHERE = Enum.MeshType.Sphere
local NEON = Enum.Material.Neon

export type Ctx = {
	rng: Random,
	rot: () -> Color3,
	part: (name: string) -> BasePart?,
	graft: (host: BasePart, name: string, size: Vector3, offset: CFrame, color: Color3, stage: number, mesh: Enum.MeshType?, material: Enum.Material?) -> Part,
}

export type Style = {
	key: string,
	rot: { Color3 },
	accent: Color3,
	eye: Color3,
	material: Enum.Material,
	smoke: { Color3 },
	twist: { [string]: Vector3 },
	twistFull: number,
	tremor: { number },
	stutter: number,
	grow: number,
	turn: number,
	turnEase: string,
	night: { from: number, to: number, over: number, steps: number? },
	build: (Ctx) -> (),
}

local Styles = {}

--- Claws off both hands; the swipe attacks read through these.
local function claws(c: Ctx, n: number, lens: { number }, color: Color3, stage: number, mesh: Enum.MeshType?)
	for k, side in { "LeftHand", "RightHand" } do
		local hand = c.part(side)
		if hand then
			local s, len = hand.Size, lens[k]
			for i = 1, n do
				local x = (i - (n + 1) / 2) / math.max(n - 1, 1) * 0.6
				c.graft(hand, "Claw", V(s.X * 0.1, s.Y * 1.2 * len, s.Z * 0.1), CF(x * s.X, -s.Y * 0.8 * len, -s.Z * 0.2) * CFrame.Angles(rad(-18), 0, rad(x * 26.7)), color, stage + (k - 1) * 0.05, mesh)
			end
		end
	end
end

--------------------------------------------------------------------------------
-- Bloated (the original NGMI, unchanged at full progress)
--------------------------------------------------------------------------------
local VEIN = Color3.fromRGB(96, 26, 92)
local RED = Color3.fromRGB(255, 20, 20)

Styles.bloated = {
	key = "bloated",
	rot = { Color3.fromRGB(46, 16, 52), Color3.fromRGB(34, 12, 40), Color3.fromRGB(27, 10, 30), Color3.fromRGB(52, 22, 46), Color3.fromRGB(38, 18, 36) },
	accent = VEIN,
	eye = RED,
	material = Enum.Material.Slate,
	smoke = { Color3.fromRGB(70, 16, 100), Color3.fromRGB(14, 0, 22) },
	twist = {
		waist = V(20, -12, 6),
		neck = V(15, 21, -13),
		rS = V(12, 0, -26),
		lS = V(5, 0, 9),
		rE = V(-48, 0, 0),
		lE = V(-16, 0, 0),
		rH = V(-5, 0, 4),
		lH = V(-11, 0, -6),
		rK = V(13, 0, 0),
		lK = V(27, 0, 0),
	},
	twistFull = 0.5,
	tremor = { 2.5, 4 },
	stutter = 1,
	grow = 0.15,
	turn = 1.1,
	turnEase = "out",
	night = { from = 0.8, to = 1, over = 240 },
	build = function(c: Ctx)
		local rot, rng = c.rot, c.rng
		local head = c.part("Head")
		if head then
			local h = head.Size
			-- Swollen, lopsided skull, plus tumours off the temples.
			c.graft(head, "Cranium", V(h.X * 1.34, h.Y * 1.18, h.Z * 1.28), CF(h.X * 0.07, h.Y * 0.26, h.Z * 0.04), rot(), 0.15, SPHERE)
			c.graft(head, "Tumour", V(h.X * 0.62, h.Y * 0.56, h.Z * 0.6), CF(h.X * 0.5, h.Y * 0.2, -h.Z * 0.08), rot(), 0.4, SPHERE)
			c.graft(head, "Tumour", V(h.X * 0.36, h.Y * 0.34, h.Z * 0.36), CF(-h.X * 0.42, h.Y * 0.46, h.Z * 0.2), rot(), 0.6, SPHERE)
			-- A cluster of eyes, deliberately not in pairs: two where eyes
			-- belong, then three opening where they should not.
			local eyes = {
				{ V(-0.27, 0.16, -0.52), 0.26, 0 },
				{ V(0.29, 0.11, -0.52), 0.24, 0 },
				{ V(0.47, 0.34, -0.34), 0.13, 0.35 },
				{ V(-0.14, 0.42, -0.44), 0.11, 0.5 },
				{ V(0.08, -0.1, -0.55), 0.09, 0.7 },
			}
			for _, e in eyes do
				local v, r = e[1] :: Vector3, e[2] :: number
				c.graft(head, "Eye", V(h.X * r, h.Y * r, h.Z * r), CF(v.X * h.X, v.Y * h.Y, v.Z * h.Z), RED, e[3] :: number, SPHERE, NEON)
			end
			-- Split jaw: a dark cavity where the mouth was, with pale shards.
			c.graft(head, "Maw", V(h.X * 0.66, h.Y * 0.4, h.Z * 0.34), CF(0, -h.Y * 0.3, -h.Z * 0.4) * CFrame.Angles(rad(-10), 0, 0), Color3.fromRGB(10, 3, 9), 0.2, SPHERE)
			for i = -1, 1 do
				c.graft(head, "Shard", V(h.X * 0.08, h.Y * 0.16, h.Z * 0.08), CF(i * h.X * 0.17, -h.Y * 0.28, -h.Z * 0.5), Color3.fromRGB(196, 188, 172), 0.3, SPHERE)
			end
		end

		local torso = c.part("UpperTorso")
		if torso then
			local t = torso.Size
			-- The hunch: a mass riding one shoulder blade.
			c.graft(torso, "Hump", V(t.X * 0.86, t.Y * 0.72, t.Z * 1.15), CF(t.X * 0.16, t.Y * 0.26, t.Z * 0.46), rot(), 0.3, SPHERE)
			c.graft(torso, "Hump", V(t.X * 0.42, t.Y * 0.4, t.Z * 0.7), CF(-t.X * 0.3, t.Y * 0.34, t.Z * 0.42), rot(), 0.55, SPHERE)
			-- A crown of spines off one shoulder, the other swollen out, and
			-- something pushing through the ribs.
			local side = (rng:NextNumber() < 0.5) and 1 or -1
			for i = 0, 2 do
				c.graft(torso, "ShoulderSpine", V(t.X * 0.12, t.Y * (0.5 - i * 0.09), t.Z * 0.12), CF(side * t.X * (0.64 + i * 0.06), t.Y * (0.46 - i * 0.04), t.Z * (0.1 - i * 0.16)) * CFrame.Angles(0, 0, side * rad(28 + i * 16)), VEIN, 0.5 + i * 0.1, SPHERE)
			end
			c.graft(torso, "ShoulderMass", V(t.X * 0.55, t.Y * 0.5, t.Z * 0.85), CF(-side * t.X * 0.52, t.Y * 0.3, 0), rot(), 0.45, SPHERE)
			c.graft(torso, "Ribs", V(t.X * 0.5, t.Y * 0.46, t.Z * 0.8), CF(-side * t.X * 0.22, -t.Y * 0.12, -t.Z * 0.36), rot(), 0.65, SPHERE)
			-- Spines down the back, shrinking as they go.
			for i = 0, 4 do
				local f = i / 4
				local len = 1 - f * 0.55
				c.graft(torso, "Spine", V(t.X * 0.13 * len, t.Y * 0.1 * len, t.Z * 0.95 * len), CF(rng:NextNumber(-0.06, 0.06) * t.X, t.Y * (0.34 - f * 0.62), t.Z * 0.52) * CFrame.Angles(rad(-34 - f * 14), 0, 0), VEIN, 0.55 + f * 0.3, SPHERE)
			end
		end

		-- Limb growths, sized off each limb and placed asymmetrically.
		local limbs = {
			{ "RightUpperArm", 0.9, 1, 0.35 },
			{ "LeftUpperArm", 0.55, -1, 0.6 },
			{ "RightLowerArm", 0.7, 1, 0.45 },
			{ "LeftLowerArm", 0.4, -1, 0.75 },
			{ "RightUpperLeg", 0.6, 1, 0.7 },
			{ "LeftLowerLeg", 0.45, -1, 0.8 },
		}
		for _, spec in limbs do
			local part = c.part(spec[1] :: string)
			if part then
				local sz = part.Size
				local scale, side, stage = spec[2] :: number, spec[3] :: number, spec[4] :: number
				c.graft(part, "Growth", V(sz.X * scale, sz.Y * scale * 0.5, sz.Z * scale), CF(side * sz.X * 0.3, rng:NextNumber(-0.2, 0.2) * sz.Y, sz.Z * 0.25), rot(), stage, SPHERE)
				if scale > 0.6 then
					c.graft(part, "Vein", V(sz.X * 0.22, sz.Y * 0.5, sz.Z * 0.22), CF(side * sz.X * 0.42, -sz.Y * 0.2, -sz.Z * 0.1), VEIN, stage + 0.1, SPHERE)
				end
			end
		end
		-- Hooked claws, the left one longer.
		claws(c, 3, { 1.5, 1.0 }, Color3.fromRGB(92, 78, 70), 0.25, SPHERE)
	end,
}

--------------------------------------------------------------------------------
-- Splitter
--------------------------------------------------------------------------------
local BONE = Color3.fromRGB(206, 198, 176)
local SICK = Color3.fromRGB(226, 232, 60)
local CAVITY = Color3.fromRGB(16, 8, 6)

Styles.splitter = {
	key = "splitter",
	rot = { Color3.fromRGB(86, 82, 74), Color3.fromRGB(74, 70, 64), Color3.fromRGB(98, 92, 80), Color3.fromRGB(66, 64, 60) },
	accent = BONE,
	eye = SICK,
	material = Enum.Material.Concrete,
	smoke = { Color3.fromRGB(120, 116, 70), Color3.fromRGB(24, 22, 14) },
	-- Upright and craned: head thrown back and cocked, arms hanging dead.
	twist = {
		waist = V(-8, 6, 4),
		neck = V(-22, 30, 26),
		rS = V(-10, 0, 10),
		lS = V(-6, 0, -12),
		rE = V(8, 0, 0),
		lE = V(4, 0, 0),
		rH = V(-3, 0, 6),
		lH = V(-3, 0, -6),
		rK = V(4, 0, 0),
		lK = V(10, 0, 0),
	},
	twistFull = 1,
	tremor = { 1.5, 2.5 },
	stutter = 1,
	grow = 0.12,
	turn = 3.6,
	turnEase = "linear",
	night = { from = 0.4, to = 1, over = 480 },
	build = function(c: Ctx)
		local rot = c.rot
		local head = c.part("Head")
		if head then
			local h = head.Size
			-- The seam opens first, then the skull halves push apart round it.
			c.graft(head, "Seam", V(h.X * 0.08, h.Y * 0.86, h.Z * 0.12), CF(0, h.Y * 0.05, -h.Z * 0.5), SICK, 0.05, nil, NEON)
			for _, sx in { -1, 1 } do
				c.graft(head, "SkullHalf", V(h.X * 0.6, h.Y * 1.1, h.Z * 1.08), CF(sx * h.X * 0.34, h.Y * 0.08, 0) * CFrame.Angles(0, 0, sx * rad(-12)), rot(), 0.35, SPHERE)
				c.graft(head, "Mandible", V(h.X * 0.12, h.Y * 0.6, h.Z * 0.12), CF(sx * h.X * 0.3, -h.Y * 0.5, -h.Z * 0.38) * CFrame.Angles(rad(-20), 0, sx * rad(22)), BONE, 0.6, SPHERE)
			end
			-- Eyes open one at a time down the seam.
			for i, y in { 0.3, 0.12, -0.06, -0.24 } do
				local r = 0.15 - i * 0.015
				c.graft(head, "Eye", V(h.X * r, h.Y * r, h.Z * r), CF(0, y * h.Y, -h.Z * 0.56), SICK, 0.2 * i - 0.05, SPHERE, NEON)
			end
		end

		local torso = c.part("UpperTorso")
		if torso then
			local t = torso.Size
			-- Chest cracked open, ribs splaying out of it like fingers.
			c.graft(torso, "Cavity", V(t.X * 0.36, t.Y * 0.62, t.Z * 0.3), CF(0, 0, -t.Z * 0.42), CAVITY, 0.25, SPHERE)
			for _, side in { -1, 1 } do
				for i = 0, 3 do
					c.graft(torso, "Rib", V(t.X * 0.07, t.Y * 0.07, t.Z * (0.95 - i * 0.1)), CF(side * t.X * (0.1 + 0.03 * i), t.Y * (0.26 - 0.16 * i), -t.Z * 0.6) * CFrame.Angles(rad(8 + i * 6), side * rad(38 + 9 * i), 0), BONE, 0.3 + i * 0.1 + (side + 1) * 0.02, SPHERE)
				end
			end
			-- Bone blades down the spine, top first.
			for i = 0, 5 do
				local len = 1 - i * 0.12
				c.graft(torso, "Blade", V(t.X * 0.05, t.Y * 0.42 * len, t.Z * 0.38 * len), CF(0, t.Y * (0.42 - 0.16 * i), t.Z * 0.56) * CFrame.Angles(rad(-24), 0, 0), BONE, 0.45 + i * 0.08, Enum.MeshType.Wedge)
			end
		end

		-- Spurs out of the elbows and knees.
		for i, spec in { { "RightLowerArm", 1, 0.7 }, { "LeftLowerArm", -1, 0.76 }, { "RightLowerLeg", 1, 0.85 }, { "LeftLowerLeg", -1, 0.9 } } do
			local part = c.part(spec[1] :: string)
			if part then
				local s = part.Size
				local leg = i > 2
				c.graft(part, "Spur", V(s.X * 0.2, s.Y * 0.75, s.Z * 0.2), CF(0, s.Y * 0.42, (if leg then -1 else 1) * s.Z * 0.4) * CFrame.Angles(rad(if leg then 42 else -50), 0, (spec[2] :: number) * rad(10)), BONE, spec[3] :: number, SPHERE)
			end
		end
		-- Long, even claws on both hands.
		claws(c, 4, { 1.8, 1.8 }, BONE, 0.55, SPHERE)
	end,
}

--------------------------------------------------------------------------------
-- Bloom
--------------------------------------------------------------------------------
local CREAM = Color3.fromRGB(196, 176, 132)
local GILL = Color3.fromRGB(122, 92, 60)
local AMBER = Color3.fromRGB(255, 128, 28)

Styles.bloom = {
	key = "bloom",
	rot = { Color3.fromRGB(58, 44, 32), Color3.fromRGB(48, 38, 28), Color3.fromRGB(70, 52, 36), Color3.fromRGB(40, 32, 26) },
	accent = CREAM,
	eye = AMBER,
	material = Enum.Material.Slate,
	smoke = { Color3.fromRGB(170, 150, 100), Color3.fromRGB(40, 30, 18) },
	-- Bent hard over, the overgrown head hanging and tipped to one side.
	twist = {
		waist = V(16, 0, -8),
		neck = V(26, -10, 20),
		rS = V(22, 0, -10),
		lS = V(18, 0, 10),
		rE = V(-38, 0, 0),
		lE = V(-32, 0, 0),
		rH = V(-12, 0, 4),
		lH = V(-8, 0, -4),
		rK = V(20, 0, 0),
		lK = V(16, 0, 0),
	},
	twistFull = 0.7,
	tremor = { 3, 6 },
	stutter = 0.8,
	grow = 0.18,
	turn = 2.4,
	turnEase = "smooth",
	night = { from = 0.55, to = 1, over = 300 },
	build = function(c: Ctx)
		local rot, rng = c.rot, c.rng
		local function fungus(): Color3
			return if rng:NextNumber() < 0.6 then CREAM else GILL
		end
		-- Head first, then down the body: the stage follows the height.
		local head = c.part("Head")
		if head then
			local h = head.Size
			c.graft(head, "Eye", V(h.X * 0.12, h.Y * 0.12, h.Z * 0.12), CF(-h.X * 0.2, -h.Y * 0.04, -h.Z * 0.56), AMBER, 0, SPHERE, NEON)
			c.graft(head, "Eye", V(h.X * 0.1, h.Y * 0.1, h.Z * 0.1), CF(h.X * 0.24, -h.Y * 0.02, -h.Z * 0.55), AMBER, 0, SPHERE, NEON)
			c.graft(head, "Maw", V(h.X * 0.5, h.Y * 0.3, h.Z * 0.3), CF(0, -h.Y * 0.32, -h.Z * 0.42), Color3.fromRGB(14, 8, 4), 0.12, SPHERE)
			-- Crust grows over the brow, then petals fan out round the face.
			c.graft(head, "Crust", V(h.X * 1.08, h.Y * 0.52, h.Z * 0.62), CF(0, h.Y * 0.26, -h.Z * 0.24), rot(), 0.22, SPHERE)
			for i = 0, 7 do
				local a = i / 8 * math.pi * 2 + rng:NextNumber(-0.2, 0.2)
				c.graft(head, "Petal", V(h.X * 0.48, h.Y * 0.56, h.Z * 0.1), CF(0, h.Y * 0.12, -h.Z * 0.38) * CFrame.Angles(0, 0, a) * CF(0, h.Y * 0.4, 0) * CFrame.Angles(rad(-28), 0, 0), fungus(), 0.08 + i * 0.035, SPHERE)
			end
			c.graft(head, "Eye", V(h.X * 0.09, h.Y * 0.09, h.Z * 0.09), CF(h.X * 0.04, h.Y * 0.38, -h.Z * 0.5), AMBER, 0.4, SPHERE, NEON)
		end

		local torso = c.part("UpperTorso")
		if torso then
			local t = torso.Size
			for j = 0, 6 do
				local s = rng:NextNumber(0.15, 0.28)
				c.graft(torso, "Knob", V(t.X * s, t.X * s, t.X * s), CF(rng:NextNumber(-0.45, 0.45) * t.X, t.Y * rng:NextNumber(0.32, 0.5), rng:NextNumber(-0.3, 0.4) * t.Z), fungus(), 0.36 + j * 0.03, SPHERE)
			end
			c.graft(torso, "Mat", V(t.X * 0.82, t.Y * 0.72, t.Z * 0.4), CF(0, t.Y * 0.08, t.Z * 0.42), rot(), 0.55, SPHERE)
			local side = (rng:NextNumber() < 0.5) and 1 or -1
			for k = 0, 2 do
				c.graft(torso, "Shelf", V(t.X * (0.55 - k * 0.1), t.Y * 0.08, t.Z * (0.55 - k * 0.1)), CF(side * t.X * 0.5, t.Y * (0.12 - 0.2 * k), t.Z * 0.1) * CFrame.Angles(0, 0, side * rad(-10)), CREAM, 0.58 + k * 0.06, SPHERE)
			end
		end

		for _, spec in { { "RightUpperArm", 0.68 }, { "LeftUpperArm", 0.72 }, { "RightLowerArm", 0.8 }, { "LeftLowerArm", 0.82 }, { "RightUpperLeg", 0.86 }, { "LeftUpperLeg", 0.88 }, { "RightLowerLeg", 0.93 }, { "LeftLowerLeg", 0.95 } } do
			local part = c.part(spec[1] :: string)
			if part then
				local s = part.Size
				for n = 0, 1 do
					local r = rng:NextNumber(0.35, 0.55)
					c.graft(part, "Nodule", V(s.X * r, s.X * r, s.X * r), CF(rng:NextNumber(-0.4, 0.4) * s.X, rng:NextNumber(-0.35, 0.35) * s.Y, rng:NextNumber(-0.3, 0.5) * s.Z), fungus(), (spec[2] :: number) + n * 0.02, SPHERE)
				end
			end
		end
		-- Short, thick claws.
		claws(c, 3, { 0.9, 0.9 }, Color3.fromRGB(70, 54, 40), 0.5, SPHERE)
	end,
}

--------------------------------------------------------------------------------
-- Glitch
--------------------------------------------------------------------------------
local CYAN = Color3.fromRGB(40, 240, 255)
local MAGENTA = Color3.fromRGB(255, 40, 200)

Styles.glitch = {
	key = "glitch",
	rot = { Color3.fromRGB(18, 18, 24), Color3.fromRGB(26, 24, 34), Color3.fromRGB(14, 14, 18), Color3.fromRGB(34, 30, 44) },
	accent = MAGENTA,
	eye = CYAN,
	material = Enum.Material.SmoothPlastic,
	smoke = { Color3.fromRGB(40, 200, 230), Color3.fromRGB(60, 0, 50) },
	-- Wrong in a mechanical way: head turned past where a neck allows, one arm
	-- locked up and out, weight thrown on one leg.
	twist = {
		waist = V(8, -20, 10),
		neck = V(0, 70, -22),
		rS = V(28, 0, 42),
		rE = V(60, 0, 0),
		lS = V(-4, 0, -10),
		lE = V(-60, 0, 0),
		rH = V(0, 0, 4),
		lH = V(-12, 0, -8),
		rK = V(2, 0, 0),
		lK = V(30, 0, 0),
	},
	twistFull = 0.2,
	tremor = { 4, 18 },
	stutter = 2.5,
	grow = 0,
	turn = 0.7,
	turnEase = "linear",
	night = { from = 0.5, to = 1, over = 180, steps = 5 },
	build = function(c: Ctx)
		local rot, rng = c.rot, c.rng
		--- A block somewhere on the surface of `host`, pushed out a little.
		local function chunk(host: BasePart, name: string, sMin: number, sMax: number, stage: number, color: Color3?)
			local s = host.Size
			local k = rng:NextNumber(sMin, sMax)
			local axis = rng:NextInteger(1, 3)
			local sign = if rng:NextNumber() < 0.5 then -1 else 1
			local p = V(rng:NextNumber(-0.4, 0.4), rng:NextNumber(-0.4, 0.4), rng:NextNumber(-0.4, 0.4))
			p = V(if axis == 1 then sign * 0.5 else p.X, if axis == 2 then sign * 0.5 else p.Y, if axis == 3 then sign * 0.5 else p.Z)
			c.graft(host, name, V(s.X * k, s.X * k, s.X * k), CF(p.X * s.X, p.Y * s.Y, p.Z * s.Z), color or rot(), stage, nil, if color then NEON else nil)
		end

		local head = c.part("Head")
		if head then
			local h = head.Size
			c.graft(head, "Eye", V(h.X * 0.32, h.Y * 0.12, h.Z * 0.06), CF(-h.X * 0.2, h.Y * 0.15, -h.Z * 0.53), CYAN, 0, nil, NEON)
			c.graft(head, "Eye", V(h.X * 0.14, h.Y * 0.14, h.Z * 0.06), CF(h.X * 0.25, h.Y * 0.18, -h.Z * 0.53), MAGENTA, 0, nil, NEON)
			-- A second copy of the head, smeared off to one side.
			c.graft(head, "Ghost", V(h.X * 0.95, h.Y * 0.95, h.Z * 0.95), CF(h.X * 0.36, h.Y * 0.12, h.Z * 0.06), rot(), 0.3)
			for i = 0, 3 do
				chunk(head, "Chunk", 0.25, 0.45, 0.1 + i * 0.15)
			end
			c.graft(head, "Eye", V(h.X * 0.08, h.Y * 0.08, h.Z * 0.06), CF(h.X * 0.32, -h.Y * 0.05, -h.Z * 0.55), CYAN, 0.5, nil, NEON)
			c.graft(head, "Eye", V(h.X * 0.1, h.Y * 0.06, h.Z * 0.06), CF(-h.X * 0.36, h.Y * 0.42, -h.Z * 0.42), MAGENTA, 0.75, nil, NEON)
		end

		local torso = c.part("UpperTorso")
		if torso then
			local t = torso.Size
			-- Scan bands wrapping the chest, each slipped sideways.
			for i, y in { 0.3, 0, -0.26 } do
				c.graft(torso, "ScanBand", V(t.X * 1.08, t.Y * 0.045, t.Z * 1.1), CF(rng:NextNumber(-0.12, 0.12) * t.X, y * t.Y, 0), if i % 2 == 1 then CYAN else MAGENTA, 0.2 + (i - 1) * 0.25, nil, NEON)
			end
			for i = 0, 5 do
				chunk(torso, "Fragment", 0.2, 0.36, 0.3 + i * 0.1, if i == 3 then MAGENTA else nil)
			end
			c.graft(torso, "Spike", V(t.X * 0.18, t.Y * 0.7, t.Z * 0.18), CF(-t.X * 0.45, t.Y * 0.62, 0) * CFrame.Angles(0, 0, rad(20)), rot(), 0.55)
		end

		-- The right forearm dissolving into a trail of cubes.
		local arm = c.part("RightLowerArm")
		if arm then
			local s = arm.Size
			for i = 1, 5 do
				local k = 0.5 - i * 0.07
				c.graft(arm, "Shard", V(s.X * k, s.X * k, s.X * k), CF(s.X * (0.45 + i * 0.16), -s.Y * (0.1 + i * 0.12), s.Z * rng:NextNumber(-0.2, 0.3)), if i == 3 then CYAN else rot(), 0.35 + i * 0.09, nil, if i == 3 then NEON else nil)
			end
		end
		local thigh = c.part("LeftUpperLeg")
		if thigh then
			chunk(thigh, "Chunk", 0.4, 0.55, 0.85)
		end
		claws(c, 3, { 1.2, 1.2 }, Color3.fromRGB(60, 60, 72), 0.25)
	end,
}

Styles.ORDER = { "bloated", "splitter", "bloom", "glitch" }

return Styles
