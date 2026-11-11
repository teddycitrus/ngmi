--!strict
--------------------------------------------------------------------------------
-- Flashlight/Rig.luau
-- The Night 2 light rig for FlashlightController, centred on the camera:
--
--   Glow   always on in the blackout. A short, dim point light, so with no
--          flashlight the player still sees a few studs around them (the
--          floor at their feet, the wall they are touching) and nothing past.
--   Light  the phone flashlight. A point light radiating from the camera with
--          a much longer reach, so switching it on pushes the visible area
--          out in every direction. Losing it is a setback, not a death.
--
-- Both sit on one invisible emitter that rides just in front of the camera,
-- clamped by a ray so it never ends up on the far side of a wall the player
-- is pressed against. While the light sits inside the player's head, the
-- character would shadow it, so the local character casts no shadows while
-- the rig exists (a local change; other players are unaffected).
--------------------------------------------------------------------------------

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

export type Config = {
	range: number, -- the core light; its fringe tiers reach FRINGE[#FRINGE].scale times further
	brightness: number,
	color: Color3,
}
export type Parts = { emitter: Part, light: PointLight }

local Rig = {}

-- The bare-eyes glow. Tuned in Play against the Night 2 grade, which crushes
-- anything dim (at brightness 0.9 nothing showed at all).
local GLOW_RANGE = 5
local GLOW_BRIGHTNESS = 2.2
local GLOW_COLOR = Color3.fromRGB(176, 186, 214)

-- A single PointLight dies at its Range in a visible ring. Each light gets a
-- stack of dimmer, wider copies on the same emitter, each tier reaching
-- further at a fraction of the brightness, so the edge tails off over many
-- studs (a rough inverse-square falloff) instead of stopping. One wider twin
-- still left a second, softer ring; three tiers blend it out. The copies
-- mirror their light every frame (on, colour, and brightness scaled by their
-- ratio), so the controller's battery sag and flicker drive them all.
local FRINGE = {
	{ scale = 1.4, ratio = 0.4 },
	{ scale = 1.85, ratio = 0.18 },
	{ scale = 2.3, ratio = 0.07 },
}

--- Copies of `light` for every fringe tier, parented next to it.
local function fringeTiers(light: PointLight): { PointLight }
	local out = {}
	for i, tier in FRINGE do
		local f = light:Clone()
		f.Name = light.Name .. "Fringe" .. i
		f.Range = math.min(light.Range * tier.scale, 60)
		f.Brightness = light.Brightness * tier.ratio
		f.Parent = light.Parent
		table.insert(out, f)
	end
	return out
end

local HOLD_OFFSET = Vector3.new(0, -0.1, -0.6)
local WALL_CLEARANCE = 0.25 -- studs kept between the emitter and a surface

local emitterPart: Part? = nil
local renderConn: RBXScriptConnection? = nil
local shadowed: { [BasePart]: boolean } = {}
local shadowChar: Model? = nil

local function restoreShadows()
	for part, was in shadowed do
		if part.Parent then
			part.CastShadow = was
		end
	end
	table.clear(shadowed)
	shadowChar = nil
end

local function hideCharacterShadows(char: Model?)
	if char == shadowChar then
		return
	end
	restoreShadows()
	shadowChar = char
	if not char then
		return
	end
	for _, d in char:GetDescendants() do
		if d:IsA("BasePart") then
			shadowed[d] = d.CastShadow
			d.CastShadow = false
		end
	end
end

function Rig.destroy()
	if renderConn then
		renderConn:Disconnect()
		renderConn = nil
	end
	if emitterPart then
		emitterPart:Destroy()
		emitterPart = nil
	end
	restoreShadows()
end

--- Build the rig. `config` is FlashlightController's CONFIG; the flashlight
--- starts switched off, the glow starts on.
function Rig.create(config: Config): Parts
	Rig.destroy()

	local e = Instance.new("Part")
	e.Name = "FlashlightEmitter"
	e.Size = Vector3.new(0.2, 0.2, 0.2)
	e.Transparency = 1
	e.Anchored = true
	e.CanCollide = false
	e.CanQuery = false -- never block raycasts (wall checks, NGMI vision, etc.)
	e.CanTouch = false
	e.CastShadow = false
	e.Parent = workspace
	emitterPart = e

	local glow = Instance.new("PointLight")
	glow.Name = "Glow"
	glow.Range = GLOW_RANGE
	glow.Brightness = GLOW_BRIGHTNESS
	glow.Color = GLOW_COLOR
	-- No shadows: the reach is too short to leak anywhere the player can see.
	glow.Shadows = false
	glow.Parent = e
	fringeTiers(glow)

	local light = Instance.new("PointLight")
	light.Name = "PhoneFlashlight"
	light.Range = config.range
	light.Brightness = config.brightness
	light.Color = config.color
	-- Shadows keep it from lighting the next room through the wall.
	light.Shadows = true
	light.Enabled = false
	light.Parent = e
	local fringes = fringeTiers(light)

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true

	-- What the fringes and the ray filter were last set from; nothing else
	-- writes them, so an unchanged source means nothing to write.
	local mirroredEnabled: boolean? = nil
	local mirroredBrightness: number? = nil
	local mirroredColor: Color3? = nil
	local filterChar: Model | false | nil = false

	renderConn = RunService.RenderStepped:Connect(function()
		local cam = workspace.CurrentCamera
		if not (emitterPart and cam) then
			return
		end
		-- A cutscene owns a Scriptable camera; lights riding it would light the
		-- cutscene set, so the rig is pulled out until gameplay has the camera.
		emitterPart.Parent = if cam.CameraType == Enum.CameraType.Scriptable then nil else workspace
		local character = player.Character
		hideCharacterShadows(character)
		local enabled, brightness, color = light.Enabled, light.Brightness, light.Color
		if enabled ~= mirroredEnabled or brightness ~= mirroredBrightness or color ~= mirroredColor then
			mirroredEnabled, mirroredBrightness, mirroredColor = enabled, brightness, color
			for i, f in fringes do
				f.Enabled = enabled
				f.Brightness = brightness * FRINGE[i].ratio
				f.Color = color
			end
		end

		local camCF = cam.CFrame
		local eye = camCF.Position
		local reach = camCF:VectorToWorldSpace(HOLD_OFFSET)
		if character ~= filterChar then
			filterChar = character
			params.FilterDescendantsInstances = { emitterPart, character }
		end
		local block = workspace:Raycast(eye, reach, params)
		local dist = if block then math.max(0, block.Distance - WALL_CLEARANCE) else reach.Magnitude
		emitterPart.CFrame = CFrame.new(eye + reach.Unit * dist)
	end)

	return { emitter = e, light = light }
end

return Rig
