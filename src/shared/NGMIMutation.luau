--!strict
--------------------------------------------------------------------------------
-- NGMIMutation.luau
-- Turns an R15 human rig into an NGMI. Used by the night transition cutscene
-- (client, on its actor clones) and by NGMIController (server, on every
-- gameplay NGMI) so the things that hunt you at night are the same creatures
-- you watched turn.
--
-- An NGMI is not "a hacker painted purple". Recolouring alone leaves the human
-- silhouette standing there in a different shirt, so this deforms the body
-- with growths and a permanent skeletal twist the animators layer under every
-- pose. There are four styles of it (Shared.NGMIStyles), each with its own
-- growths, colours, twist and order of change.
--
-- Mutation has a progress, 0 (just turned: recoloured, nothing grown yet) to 1
-- (fully grown). Every growth carries the progress at which it starts to show,
-- and setProgress swells them in, so the same body can be caught mid-change.
-- The model carries attributes "NGMIStyle" and "MutationProgress"; clones and
-- clients read both back.
--------------------------------------------------------------------------------

local NGMIStyles = require(script.Parent:WaitForChild("NGMIStyles"))

export type Style = NGMIStyles.Style

local NGMIMutation = {}

local DEFAULT = "bloated"
local STYLES = NGMIStyles :: any

NGMIMutation.STYLES = NGMIStyles.ORDER :: { string }
NGMIMutation.EYE_RED = NGMIStyles.bloated.eye
-- The original deformity (the bloated style's twist).
NGMIMutation.TWIST = NGMIStyles.bloated.twist

export type Opts = {
	-- Add the head glow and the breathing particles. The cutscene wants them;
	-- gameplay NGMIs get theirs from NGMIClient, which also flickers them.
	fx: boolean?,
	-- Style key (NGMIStyles.ORDER); random from the seed when omitted.
	style: string?,
	-- Starting progress, default 1 (fully grown).
	progress: number?,
}

--- A style by key, falling back to the original.
function NGMIMutation.style(key: string?): Style
	return (key and STYLES[key]) or STYLES[DEFAULT]
end

--- The style a mutated model was built with.
function NGMIMutation.styleOf(model: Instance): Style
	return NGMIMutation.style(model:GetAttribute("NGMIStyle") :: string?)
end

--- Weld a growth onto a rig part, positioned in that part's local space.
--- A real Weld with an explicit C0, never a WeldConstraint: these rigs are
--- posed through their joints every frame, and a constraint captures
--- whatever pose the parts happened to be in the tick it was created, which
--- leaves the growths hanging off the body a moment later.
local function graft(
	model: Model,
	host: BasePart,
	name: string,
	size: Vector3,
	offset: CFrame,
	color: Color3,
	stage: number,
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
	p:SetAttribute("Stage", math.max(stage, 0))
	-- Always a mesh, so growth scales the mesh and never resizes the part
	-- (a resize re-solves the weld and the assembly every step).
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = meshType or Enum.MeshType.Brick
	mesh.Parent = p
	local w = Instance.new("Weld")
	w.Name = "GrowthWeld"
	w.Part0 = host
	w.Part1 = p
	w.C0 = offset
	w.Parent = p
	p.Parent = model
	return p
end

--- Grow every growth to where `progress` puts it.
function NGMIMutation.setProgress(model: Model, progress: number)
	local p = math.clamp(progress, 0, 1)
	model:SetAttribute("MutationProgress", p)
	local grow = NGMIMutation.styleOf(model).grow
	for _, d in model:GetChildren() do
		local stage = d:GetAttribute("Stage")
		-- most children are not growths: look for a mesh only on the ones that are
		if typeof(stage) == "number" and d:IsA("BasePart") then
			local mesh = d:FindFirstChildOfClass("SpecialMesh")
			if mesh then
				local u = if grow > 0 then math.clamp((p - stage) / grow, 0, 1) else (if p >= stage then 1 else 0)
				if u <= 0 then
					d.Transparency = 1
				else
					d.Transparency = 0
					-- eased swell from a bud to full size
					local k = 0.15 + 0.85 * (1 - (1 - u) ^ 2)
					if math.abs(mesh.Scale.X - k) > 0.005 then
						mesh.Scale = Vector3.one * k
					end
				end
			end
		end
	end
end

--- The twist a model should hold right now: its style's deformity, weighted
--- by how far the mutation has come.
function NGMIMutation.twistOf(model: Instance): { [string]: Vector3 }
	local style = NGMIMutation.styleOf(model)
	local p = (model:GetAttribute("MutationProgress") :: number?) or 1
	local w = math.clamp(p / style.twistFull, 0, 1)
	if w >= 1 then
		return style.twist
	end
	local out = {}
	for k, v in style.twist do
		out[k] = v * w
	end
	return out
end

--- Progress `t` seconds into an on-screen turn.
function NGMIMutation.turnProgress(style: Style, t: number): number
	local u = math.clamp(t / style.turn, 0, 1)
	if style.turnEase == "out" then
		return 1 - (1 - u) ^ 3
	elseif style.turnEase == "smooth" then
		return u * u * (3 - 2 * u)
	end
	return u
end

--- Progress of a gameplay NGMI `age` seconds after it spawned.
function NGMIMutation.nightProgress(style: Style, age: number): number
	local n = style.night
	local u = math.clamp(age / n.over, 0, 1)
	if n.steps then
		u = math.floor(u * n.steps) / n.steps
	end
	return n.from + (n.to - n.from) * u
end

--- `seed` only picks the style when opts.style is not given. The style itself
--- is always built from the same seed, so every NGMI of a style is identical.
function NGMIMutation.apply(model: Model, seed: number, opts: Opts?)
	local key = opts and opts.style
	if not (key and STYLES[key]) then
		key = NGMIStyles.ORDER[Random.new(seed):NextInteger(1, #NGMIStyles.ORDER)]
	end
	local style = NGMIMutation.style(key)
	local rng = Random.new(table.find(NGMIStyles.ORDER, style.key) or 1)
	model:SetAttribute("NGMIStyle", style.key)
	local function rot(): Color3
		return style.rot[rng:NextInteger(1, #style.rot)]
	end

	-- Nothing of the avatar survives: hair, hats, glasses, layered clothing,
	-- clothes, faces and body textures all go before the rot goes on.
	for _, d in model:GetDescendants() do
		if
			d:IsA("Accessory")
			or d:IsA("BodyColors")
			or d:IsA("Decal")
			or d:IsA("Texture")
			or d:IsA("Shirt")
			or d:IsA("Pants")
			or d:IsA("ShirtGraphic")
			or d:IsA("SurfaceAppearance")
		then
			d:Destroy()
		end
	end
	-- Mottled rot rather than one flat colour, so the body reads as diseased
	-- tissue instead of a repaint.
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" then
			d.Color = rot()
			d.Material = style.material
			if d:IsA("MeshPart") then
				d.TextureID = ""
			end
		end
	end

	style.build({
		rng = rng,
		rot = rot,
		part = function(name: string): BasePart?
			local p = model:FindFirstChild(name)
			if not p and name == "UpperTorso" then
				p = model:FindFirstChild("Torso")
			end
			return if p and p:IsA("BasePart") then p else nil
		end,
		graft = function(host, name, size, offset, color, stage, mesh, material)
			return graft(model, host, name, size, offset, color, stage, mesh, material)
		end,
	})

	if opts and opts.fx then
		local head = model:FindFirstChild("Head")
		if head and head:IsA("BasePart") then
			-- Reaches far enough to light its OWN body: in a blacked-out room
			-- the growths were invisible otherwise.
			local glow = Instance.new("PointLight")
			glow.Color = style.eye
			glow.Brightness = 1.6
			glow.Range = 9
			glow.Parent = head
		end
		local torso = model:FindFirstChild("UpperTorso") or model:FindFirstChild("Torso")
		if torso and torso:IsA("BasePart") then
			local emit = Instance.new("ParticleEmitter")
			emit.Color = ColorSequence.new(style.smoke[1], style.smoke[2])
			emit.Size = NumberSequence.new(0.4, 1.6)
			emit.Transparency = NumberSequence.new(0.55, 1)
			emit.Lifetime = NumberRange.new(1.6, 3)
			emit.Rate = 9
			emit.Speed = NumberRange.new(0.2, 1.1)
			emit.SpreadAngle = Vector2.new(180, 180)
			emit.Parent = torso
		end
	end

	NGMIMutation.setProgress(model, if opts and opts.progress then opts.progress else 1)
end

return NGMIMutation
