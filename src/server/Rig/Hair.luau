--!strict
--------------------------------------------------------------------------------
-- Rig/Hair.luau
-- Hair and headwear for RigFactory rigs (re-exported as RigFactory.attachToHead
-- and RigFactory.applyHair).
--------------------------------------------------------------------------------

local Hair = {}

-- Beanie colours fall back to the hoodie palette; RigFactory fills this in.
Hair.knitColors = {} :: { Color3 }

--------------------------------------------------------------------------------
-- Head pieces (hair and headwear)
--------------------------------------------------------------------------------
-- Rigs come out of the avatar API bald, and the hair NPCManager used to weld on
-- was a single flat slab parked on the skull: from any angle that is not
-- straight-on it read as a cardboard box. Every piece here is a mesh sized to
-- its own part instead. A sphere for anything that should curve over the head,
-- a cylinder for bands and ear cups (a CylinderMesh runs along the part's Y, so
-- rotate the offset to lay one on its side).
--
-- TWO THINGS THIS FILE LEARNED THE HARD WAY, both of which put hair inside the
-- skull instead of on it:
--
--  1. Sizes and offsets are multiples of the HEAD'S OWN SIZE, never studs. An
--     R15 head from CreateHumanoidModelFromDescription measures about
--     1.07 x 1.13 x 1.07, not the 1.2 cube a classic rig has, so stud offsets
--     copied from a blocky rig sit wrong on every avatar. In these units the
--     crown is y = +0.5, the face is z = -0.5, and the EYES sit at y = +0.23
--     (measured off the rendered face, not guessed). A cap centred below about
--     y = 0.3 hangs over the brow and reads as a helmet.
--  2. Pieces are held by a real Weld with an explicit C0, never a WeldConstraint.
--     A WeldConstraint captures whatever relative pose the two parts happen to be
--     in when it is created, and these heads are ANIMATED: the sit animation and
--     the head-tracking IK move the head every frame, so the captured pose is a
--     tick stale and the hair ends up inside the skull (measured drift ran from
--     0.07 up to 0.29 studs, a quarter of a head, depending on animation phase).
--     A Weld's C0 states the offset analytically, so it is right on every frame
--     no matter what the head is doing.
--
-- Pieces are welded, massless, non-collidable and shadowless, so a crowd of
-- eighty of them costs nothing in physics or rendering.
--------------------------------------------------------------------------------

export type HeadPieceOpts = {
	mesh: Enum.MeshType?,
	material: Enum.Material?,
}

--- How long after a rig is built its body scale has finished settling. The weld
--- holds the piece in the right PLACE from the start; this is only about picking
--- up the final head size for the piece's own dimensions.
local HEAD_PIECE_SETTLE = 0.2

local HAIRS = {
	Color3.fromRGB(28, 20, 16),
	Color3.fromRGB(82, 54, 32),
	Color3.fromRGB(120, 86, 50),
	Color3.fromRGB(38, 38, 44),
	Color3.fromRGB(178, 142, 90),
	Color3.fromRGB(150, 45, 45),
	Color3.fromRGB(70, 70, 78),
	Color3.fromRGB(210, 200, 180),
}

local function shade(c: Color3, f: number): Color3
	return Color3.new(c.R * f, c.G * f, c.B * f)
end

--- Head-relative factors resolved against the head's actual size: `sizeF` is a
--- multiple of the head's size on each axis, and `offsetF`'s position is a
--- multiple of the head's size (its rotation is used as-is). Head-relative means
--- one set of numbers fits the R15 avatar head and the blocky fallback rig alike.
local function pieceSize(head: BasePart, sizeF: Vector3): Vector3
	local s = head.Size
	return Vector3.new(sizeF.X * s.X, sizeF.Y * s.Y, sizeF.Z * s.Z)
end

local function pieceOffset(head: BasePart, offsetF: CFrame): CFrame
	local s = head.Size
	local o = offsetF.Position
	return CFrame.new(o.X * s.X, o.Y * s.Y, o.Z * s.Z) * offsetF.Rotation
end

--- Weld a decorative part to a head. `size` and `offset` are head-relative (see
--- seatPiece); `offset` y = 0.5 is the crown, z = -0.5 is the face.
function Hair.attachToHead(
	head: BasePart,
	name: string,
	size: Vector3,
	offset: CFrame,
	color: Color3,
	opts: HeadPieceOpts?
): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Color = color
	p.Material = (opts and opts.material) or Enum.Material.SmoothPlastic
	p.CanCollide = false
	p.CanQuery = false
	p.Massless = true
	p.CastShadow = false
	p.Size = pieceSize(head, size)
	p.CFrame = head.CFrame * pieceOffset(head, offset) -- avoids a one-frame flash at the origin

	if opts and opts.mesh then
		-- SpecialMesh has no Cylinder that respects part size the way the
		-- dedicated class does, so bands and cups get a real CylinderMesh.
		local mesh: DataModelMesh
		if opts.mesh == Enum.MeshType.Cylinder then
			mesh = Instance.new("CylinderMesh")
		else
			local special = Instance.new("SpecialMesh")
			special.MeshType = opts.mesh
			mesh = special
		end
		mesh.Parent = p
	end

	p.Parent = head.Parent

	-- Weld, not WeldConstraint: C0 states the offset outright, so an animated
	-- head can never leave the piece behind (see the note at the top).
	local headWeld = Instance.new("Weld")
	headWeld.Name = "HeadPieceWeld"
	headWeld.Part0 = head
	headWeld.Part1 = p
	headWeld.C0 = pieceOffset(head, offset)
	headWeld.Parent = p -- parented to the piece so destroying it takes the weld

	-- The weld already has the piece in the right place; this only picks up the
	-- head's final size if the rig was still scaling when it was built.
	task.delay(HEAD_PIECE_SETTLE, function()
		if not (p.Parent and head.Parent) then
			return
		end
		p.Size = pieceSize(head, size)
		headWeld.C0 = pieceOffset(head, offset)
	end)

	return p
end

--- Give a rig hair or headwear picked from `seed`, so the same NPC id always
--- gets the same head. `accent` (the character's hoodie colour, say) is used for
--- knitted and canvas headwear so it belongs to the outfit; without one, a
--- colour is picked from the same palette the rigs are dressed from.
--- Returns the style that was rolled, so a caller adding its own headwear can
--- see what is already up there ("beanie" and a ball cap do not co-exist).
function Hair.applyHair(model: Model, seed: number, accent: Color3?): string
	local head = model:FindFirstChild("Head")
	if not (head and head:IsA("BasePart")) then
		return "none"
	end

	local attach = Hair.attachToHead
	local sphere: HeadPieceOpts = { mesh = Enum.MeshType.Sphere }
	local cylinder: HeadPieceOpts = { mesh = Enum.MeshType.Cylinder }

	local hair = HAIRS[(seed // 3) % #HAIRS + 1]
	local dark = shade(hair, 0.78)
	local palette = Hair.knitColors
	local knit = accent or palette[(seed // 5) % #palette + 1]
	local style = seed % 6

	if style == 0 then
		-- Short crop, cropped close at the nape.
		attach(head, "Hair", Vector3.new(1.1, 0.7, 1.12), CFrame.new(0, 0.32, 0.02), hair, sphere)
		attach(head, "HairNape", Vector3.new(0.9, 0.44, 0.44), CFrame.new(0, 0.06, 0.44), dark, sphere)
		return "crop"
	elseif style == 1 then
		-- Big round curls: one mass plus a little volume over each ear.
		attach(head, "Hair", Vector3.new(1.34, 1.05, 1.36), CFrame.new(0, 0.46, 0.02), hair, sphere)
		for _, sx in { -1, 1 } do
			attach(head, "HairVolume", Vector3.new(0.66, 0.66, 0.7), CFrame.new(sx * 0.5, 0.3, 0.05), hair, sphere)
		end
		return "curls"
	elseif style == 2 then
		-- Mid-length, falling past the ears, with a fringe tipped over the brow.
		attach(head, "Hair", Vector3.new(1.14, 0.75, 1.18), CFrame.new(0, 0.32, 0.03), hair, sphere)
		attach(
			head,
			"HairFringe",
			Vector3.new(1.06, 0.3, 0.28),
			CFrame.new(0, 0.3, -0.44) * CFrame.Angles(math.rad(-14), 0, 0),
			hair,
			sphere
		)
		for _, sx in { -1, 1 } do
			attach(head, "HairSide", Vector3.new(0.24, 0.8, 0.86), CFrame.new(sx * 0.5, 0.02, 0.06), dark, sphere)
		end
		return "mid"
	elseif style == 3 then
		-- Knitted beanie with a rolled brim and a bobble.
		attach(head, "Hair", Vector3.new(1.08, 0.5, 1.1), CFrame.new(0, 0.26, 0.03), hair, sphere)
		attach(head, "Beanie", Vector3.new(1.2, 0.8, 1.24), CFrame.new(0, 0.4, 0), knit, sphere)
		attach(head, "BeanieBrim", Vector3.new(1.28, 0.24, 1.28), CFrame.new(0, 0.26, 0), shade(knit, 0.82), cylinder)
		attach(head, "BeanieBobble", Vector3.new(0.32, 0.32, 0.32), CFrame.new(0, 0.9, 0), shade(knit, 0.82), sphere)
		return "beanie"
	elseif style == 4 then
		-- Tied back into a bun.
		attach(head, "Hair", Vector3.new(1.12, 0.7, 1.16), CFrame.new(0, 0.3, 0.03), hair, sphere)
		attach(head, "HairBun", Vector3.new(0.62, 0.62, 0.62), CFrame.new(0, 0.36, 0.54), hair, sphere)
		attach(
			head,
			"HairTie",
			Vector3.new(0.36, 0.13, 0.36),
			CFrame.new(0, 0.25, 0.45) * CFrame.Angles(math.rad(90), 0, 0),
			Color3.fromRGB(30, 30, 36),
			cylinder
		)
		return "bun"
	end

	-- Buzz cut: a thin shadow of hair that still catches a highlight.
	attach(head, "Hair", Vector3.new(1.06, 0.52, 1.1), CFrame.new(0, 0.36, 0.02), dark, sphere)
	return "buzz"
end

return Hair
