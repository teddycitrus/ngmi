--!strict
--------------------------------------------------------------------------------
-- NGMIMutation.luau
-- Turns an R15 human rig into an NGMI. Used by the night transition cutscene
-- (client, on its actor clones) and by NGMIController (server, on every
-- gameplay NGMI) so the things that hunt you at night are the same creatures
-- you watched turn.
--
-- An NGMI is not "a hacker painted purple". Recolouring alone leaves the human
-- silhouette standing there in a different shirt, so this deforms the body:
-- asymmetric growths off the back and limbs, a swollen lopsided cranium, a
-- cluster of extra eyes, a split jaw, and (via TWIST) a permanent skeletal
-- twist the animators layer under every pose.
--------------------------------------------------------------------------------

local NGMIMutation = {}

local ROT = {
	Color3.fromRGB(46, 16, 52),
	Color3.fromRGB(34, 12, 40),
	Color3.fromRGB(27, 10, 30),
	Color3.fromRGB(52, 22, 46),
	Color3.fromRGB(38, 18, 36),
}
local VEIN = Color3.fromRGB(96, 26, 92)
NGMIMutation.EYE_RED = Color3.fromRGB(255, 20, 20)

-- The deformity, in RigPose degrees. Animators fold it into the base pose so
-- every gait and attack layers over the twist instead of wiping it.
NGMIMutation.TWIST = {
	waist = Vector3.new(20, -12, 6),
	neck = Vector3.new(15, 21, -13),
	rS = Vector3.new(12, 0, -26),
	lS = Vector3.new(5, 0, 9),
	rE = Vector3.new(-48, 0, 0),
	lE = Vector3.new(-16, 0, 0),
	rH = Vector3.new(-5, 0, 4),
	lH = Vector3.new(-11, 0, -6),
	rK = Vector3.new(13, 0, 0),
	lK = Vector3.new(27, 0, 0),
}

export type Opts = {
	-- Add the head glow and the breathing particles. The cutscene wants them;
	-- gameplay NGMIs get theirs from NGMIClient, which also flickers them.
	fx: boolean?,
}

--- Weld a growth onto a rig part, positioned in that part's local space.
--- A real Weld with an explicit C0, never a WeldConstraint: these rigs are
--- posed through their Motor6Ds every frame, and a constraint captures
--- whatever pose the parts happened to be in the tick it was created, which
--- leaves the growths hanging off the body a moment later.
local function graft(
	model: Model,
	host: BasePart,
	name: string,
	size: Vector3,
	offset: CFrame,
	color: Color3,
	meshType: Enum.MeshType?,
	material: Enum.Material?
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material or Enum.Material.Slate
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.CastShadow = false
	p.CFrame = host.CFrame * offset
	if meshType then
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = meshType
		mesh.Parent = p
	end
	local w = Instance.new("Weld")
	w.Name = "GrowthWeld"
	w.Part0 = host
	w.Part1 = p
	w.C0 = offset
	w.Parent = p
	p.Parent = model
	return p
end

function NGMIMutation.apply(model: Model, seed: number, opts: Opts?)
	local rng = Random.new(seed)
	local function rot(): Color3
		return ROT[rng:NextInteger(1, #ROT)]
	end

	-- Mottled rot rather than one flat colour, so the body reads as diseased
	-- tissue instead of a repaint. Slate over SmoothPlastic for the same reason.
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			if d.Name ~= "HumanoidRootPart" then
				d.Color = rot()
				d.Material = Enum.Material.Slate
			end
		elseif
			d:IsA("Decal")
			or d:IsA("Texture")
			or d:IsA("Shirt")
			or d:IsA("Pants")
			or d:IsA("ShirtGraphic")
			or d:IsA("SurfaceAppearance")
		then
			d:Destroy()
		end
	end

	local head = model:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		local h = head.Size
		-- Swollen, lopsided skull, plus tumours off the temples.
		graft(model, head, "Cranium", Vector3.new(h.X * 1.34, h.Y * 1.18, h.Z * 1.28), CFrame.new(h.X * 0.07, h.Y * 0.26, h.Z * 0.04), rot(), Enum.MeshType.Sphere)
		graft(model, head, "Tumour", Vector3.new(h.X * 0.62, h.Y * 0.56, h.Z * 0.6), CFrame.new(h.X * 0.5, h.Y * 0.2, -h.Z * 0.08), rot(), Enum.MeshType.Sphere)
		graft(model, head, "Tumour", Vector3.new(h.X * 0.36, h.Y * 0.34, h.Z * 0.36), CFrame.new(-h.X * 0.42, h.Y * 0.46, h.Z * 0.2), rot(), Enum.MeshType.Sphere)

		-- A cluster of eyes, deliberately not in pairs. Two where eyes belong
		-- and three that have opened somewhere they should not have.
		local eyes = {
			{ Vector3.new(-0.27, 0.16, -0.52), 0.26 },
			{ Vector3.new(0.29, 0.11, -0.52), 0.24 },
			{ Vector3.new(0.47, 0.34, -0.34), 0.13 },
			{ Vector3.new(-0.14, 0.42, -0.44), 0.11 },
			{ Vector3.new(0.08, -0.1, -0.55), 0.09 },
		}
		for _, e in eyes do
			local v, r = e[1] :: Vector3, e[2] :: number
			graft(model, head, "Eye", Vector3.new(h.X * r, h.Y * r, h.Z * r), CFrame.new(v.X * h.X, v.Y * h.Y, v.Z * h.Z), NGMIMutation.EYE_RED, Enum.MeshType.Sphere, Enum.Material.Neon)
		end

		-- Split jaw: a dark cavity where the mouth was, with a few pale shards.
		graft(model, head, "Maw", Vector3.new(h.X * 0.66, h.Y * 0.4, h.Z * 0.34), CFrame.new(0, -h.Y * 0.3, -h.Z * 0.4) * CFrame.Angles(math.rad(-10), 0, 0), Color3.fromRGB(10, 3, 9), Enum.MeshType.Sphere)
		for i = -1, 1 do
			graft(model, head, "Shard", Vector3.new(h.X * 0.08, h.Y * 0.16, h.Z * 0.08), CFrame.new(i * h.X * 0.17, -h.Y * 0.28, -h.Z * 0.5), Color3.fromRGB(196, 188, 172), Enum.MeshType.Sphere)
		end

		if opts and opts.fx then
			-- Reaches far enough to light its OWN body: in a blacked-out room
			-- the growths were invisible otherwise.
			local glow = Instance.new("PointLight")
			glow.Color = NGMIMutation.EYE_RED
			glow.Brightness = 1.6
			glow.Range = 9
			glow.Parent = head
		end
	end

	local torso = model:FindFirstChild("UpperTorso") or model:FindFirstChild("Torso")
	if torso and torso:IsA("BasePart") then
		local t = torso.Size
		-- The hunch: a mass riding one shoulder blade, which is what breaks the
		-- human silhouette from behind and at distance.
		graft(model, torso, "Hump", Vector3.new(t.X * 0.86, t.Y * 0.72, t.Z * 1.15), CFrame.new(t.X * 0.16, t.Y * 0.26, t.Z * 0.46), rot(), Enum.MeshType.Sphere)
		graft(model, torso, "Hump", Vector3.new(t.X * 0.42, t.Y * 0.4, t.Z * 0.7), CFrame.new(-t.X * 0.3, t.Y * 0.34, t.Z * 0.42), rot(), Enum.MeshType.Sphere)

		-- Front-readable mass: a crown of spines off one shoulder, the other
		-- shoulder swollen out, and something pushing through the ribs.
		local side = (rng:NextNumber() < 0.5) and 1 or -1
		for i = 0, 2 do
			graft(
				model,
				torso,
				"ShoulderSpine",
				Vector3.new(t.X * 0.12, t.Y * (0.5 - i * 0.09), t.Z * 0.12),
				CFrame.new(side * t.X * (0.64 + i * 0.06), t.Y * (0.46 - i * 0.04), t.Z * (0.1 - i * 0.16))
					* CFrame.Angles(0, 0, side * math.rad(28 + i * 16)),
				VEIN,
				Enum.MeshType.Sphere
			)
		end
		graft(model, torso, "ShoulderMass", Vector3.new(t.X * 0.55, t.Y * 0.5, t.Z * 0.85), CFrame.new(-side * t.X * 0.52, t.Y * 0.3, 0), rot(), Enum.MeshType.Sphere)
		graft(model, torso, "Ribs", Vector3.new(t.X * 0.5, t.Y * 0.46, t.Z * 0.8), CFrame.new(-side * t.X * 0.22, -t.Y * 0.12, -t.Z * 0.36), rot(), Enum.MeshType.Sphere)

		-- Spines down the back, shrinking as they go.
		for i = 0, 4 do
			local f = i / 4
			local len = 1 - f * 0.55
			graft(
				model,
				torso,
				"Spine",
				Vector3.new(t.X * 0.13 * len, t.Y * 0.1 * len, t.Z * 0.95 * len),
				CFrame.new(rng:NextNumber(-0.06, 0.06) * t.X, t.Y * (0.34 - f * 0.62), t.Z * 0.52) * CFrame.Angles(math.rad(-34 - f * 14), 0, 0),
				VEIN,
				Enum.MeshType.Sphere
			)
		end

		if opts and opts.fx then
			local emit = Instance.new("ParticleEmitter")
			emit.Color = ColorSequence.new(Color3.fromRGB(70, 16, 100), Color3.fromRGB(14, 0, 22))
			emit.Size = NumberSequence.new(0.4, 1.6)
			emit.Transparency = NumberSequence.new(0.55, 1)
			emit.Lifetime = NumberRange.new(1.6, 3)
			emit.Rate = 9
			emit.Speed = NumberRange.new(0.2, 1.1)
			emit.SpreadAngle = Vector2.new(180, 180)
			emit.Parent = torso
		end
	end

	-- Limb growths, sized off each limb and placed asymmetrically.
	local limbs = {
		{ "RightUpperArm", 0.9, 1 },
		{ "LeftUpperArm", 0.55, -1 },
		{ "RightLowerArm", 0.7, 1 },
		{ "LeftLowerArm", 0.4, -1 },
		{ "RightUpperLeg", 0.6, 1 },
		{ "LeftLowerLeg", 0.45, -1 },
	}
	for _, spec in limbs do
		local part = model:FindFirstChild(spec[1] :: string)
		if part and part:IsA("BasePart") then
			local sz = part.Size
			local scale = spec[2] :: number
			local side = spec[3] :: number
			graft(model, part, "Growth", Vector3.new(sz.X * scale, sz.Y * scale * 0.5, sz.Z * scale), CFrame.new(side * sz.X * 0.3, rng:NextNumber(-0.2, 0.2) * sz.Y, sz.Z * 0.25), rot(), Enum.MeshType.Sphere)
			if scale > 0.6 then
				graft(model, part, "Vein", Vector3.new(sz.X * 0.22, sz.Y * 0.5, sz.Z * 0.22), CFrame.new(side * sz.X * 0.42, -sz.Y * 0.2, -sz.Z * 0.1), VEIN, Enum.MeshType.Sphere)
			end
		end
	end

	-- Hooked claws off both hands, the left one longer. These are what the
	-- swipe attacks read through, so they point down the forearm.
	for _, spec in { { "LeftHand", 1.5 }, { "RightHand", 1.0 } } do
		local hand = model:FindFirstChild(spec[1] :: string)
		if hand and hand:IsA("BasePart") then
			local c = hand.Size
			local len = spec[2] :: number
			for i = -1, 1 do
				graft(
					model,
					hand,
					"Claw",
					Vector3.new(c.X * 0.1, c.Y * 1.2 * len, c.Z * 0.1),
					CFrame.new(i * c.X * 0.3, -c.Y * 0.8 * len, -c.Z * 0.2) * CFrame.Angles(math.rad(-18), 0, math.rad(i * 8)),
					Color3.fromRGB(92, 78, 70),
					Enum.MeshType.Sphere
				)
			end
		end
	end
end

return NGMIMutation
