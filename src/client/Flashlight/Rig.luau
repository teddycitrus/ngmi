--!strict
--------------------------------------------------------------------------------
-- Flashlight/Rig.luau
-- The camera-tracked flashlight rig for FlashlightController: an invisible
-- emitter part held just in front of the camera, a SpotLight spill plus a
-- narrower hotspot, and a visible light shaft (a camera-facing Beam) that is
-- trimmed every frame so it stops short of whatever it points at.
--
-- A first-person flashlight should light the cone the player is facing,
-- originating from them. The SpotLight casts exactly that cone (no particles),
-- aimed wherever the player looks, pitch included.
--------------------------------------------------------------------------------

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

export type Config = {
	spotAngle: number,
	spotRange: number,
	brightness: number,
	color: Color3,
	coneTransparency: number,
}
export type Parts = { emitter: Part, light: SpotLight, cone: Beam }

local Rig = {}

--- The visible shaft, in studs from the emitter.
---   CONE_START  the shaft does not begin at the lens. The emitter rides one stud
---               in front of the camera, and a FaceCamera beam whose first vertex
---               is that close billboards into a flat translucent slab pasted
---               across a corner of the screen.
---   CONE_MAX    a Beam is a flat quad, and a big one hanging in open air reads as
---               a shape rather than as haze. A short shaft near the player sells a
---               torch; the SpotLight does the far work.
---   CONE_MARGIN how far short of whatever it hits the shaft stops. Without this
---               the quad passes THROUGH the wall and its intersection with the
---               surface draws a hard diagonal edge across the lit pool, which is
---               the artefact that made this look broken in the first place.
local CONE_START = 4
local CONE_MAX = 16
local CONE_MARGIN = 2.5

--- Falloff. A real torch has a tight bright hotspot inside a dimmer spill. The
--- outer SpotLight is the spill; a second, narrower SpotLight on the same
--- emitter is the hotspot. It mirrors the outer light's state every frame, so
--- every existing on / off / flicker branch drives both without knowing.
local HOTSPOT_ANGLE = 18
local HOTSPOT_RANGE_SCALE = 0.85
local HOTSPOT_BRIGHTNESS_RATIO = 0.9

--- Follow delay. The beam's ROTATION trails the camera with exponential
--- smoothing, so a fast flick leaves the light a few frames behind, like a hand
--- catching up with the eyes. Position stays locked to the camera so the light
--- never detaches from the player. A faint Perlin wobble sells a held object.
local FOLLOW_SHARPNESS = 16
local HAND_WOBBLE_DEG = 0.35
local HOLD_OFFSET = CFrame.new(0.4, -0.6, -1)

--- Transparency profile along the shaft. Fades in from nothing at the near end so
--- there is no hard leading edge, and out to nothing at the far end so the widest
--- part of the quad (where its side edges would show) is invisible.
function Rig.coneRamp(peak: number): NumberSequence
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.15, peak),
		NumberSequenceKeypoint.new(0.45, math.min(peak + 0.05, 1)),
		NumberSequenceKeypoint.new(1, 1),
	})
end

local emitterPart: Part? = nil
local spotlight: SpotLight? = nil
local hotspot: SpotLight? = nil
local coneBeam: Beam? = nil
local lagRotation: CFrame? = nil
local renderConn: RBXScriptConnection? = nil

function Rig.destroy()
	if renderConn then
		renderConn:Disconnect()
		renderConn = nil
	end
	if emitterPart then
		emitterPart:Destroy()
		emitterPart = nil
	end
	spotlight = nil
	hotspot = nil
	lagRotation = nil
	coneBeam = nil
end

--- Build the rig. `config` is FlashlightController's CONFIG; `isOn` says
--- whether the light is switched on (the shaft is only traced while it is).
function Rig.create(config: Config, isOn: () -> boolean): Parts
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

	-- A SpotLight casts exactly the cone of illumination we want, origin at the
	-- emitter, fanning out along its front face. No visible particles; it just lights
	-- whatever surfaces fall inside the cone.
	local light = Instance.new("SpotLight")
	light.Name = "PhoneFlashlight"
	light.Angle = config.spotAngle
	light.Range = config.spotRange
	light.Brightness = config.brightness
	light.Color = config.color
	light.Face = Enum.NormalId.Front
	-- Real shadows. The property is `Shadows` on a Light (CastShadow is the
	-- BasePart one). Under Future this is what makes the beam get *occluded* by
	-- desks and doorframes instead of bleeding through them.
	light.Shadows = true
	light.Enabled = false
	light.Parent = e
	spotlight = light

	local hot = Instance.new("SpotLight")
	hot.Name = "PhoneFlashlightHotspot"
	hot.Angle = HOTSPOT_ANGLE
	hot.Range = config.spotRange * HOTSPOT_RANGE_SCALE
	hot.Brightness = config.brightness * HOTSPOT_BRIGHTNESS_RATIO
	hot.Color = config.color
	hot.Face = Enum.NormalId.Front
	hot.Shadows = true
	hot.Enabled = false
	hot.Parent = e
	hotspot = hot

	-- Visible light shaft. Roblox has no true volumetrics, so the shaft is a
	-- camera-facing Beam stretched down the cone: LightInfluence 0 + LightEmission 1
	-- make it self-lit, and the transparency ramp fades it out with distance so it
	-- reads as haze catching the light rather than a solid wedge.
	--
	-- The shaft deliberately does NOT start at the emitter. The emitter rides one
	-- stud in front of the camera, and a FaceCamera beam whose first vertex is that
	-- close billboards into a flat translucent slab pasted across a corner of the
	-- screen (it was offset to the lower right, following the emitter's held-torch
	-- offset). Starting it CONE_START studs out puts the near edge past the point
	-- where it can turn edge-on, and the ramp fades it in from nothing so there is
	-- no hard leading edge either.
	local a0 = Instance.new("Attachment")
	a0.Name = "ConeOrigin"
	a0.Position = Vector3.new(0, 0, -CONE_START)
	a0.Parent = e

	local a1 = Instance.new("Attachment")
	a1.Name = "ConeEnd"
	-- Starts at the cap, not at spotRange: the render loop trims it in from here.
	a1.Position = Vector3.new(0, 0, -CONE_MAX)
	a1.Parent = e

	-- SpotLight.Angle is the FULL cone angle, so the spread at distance d is
	-- 2 * d * tan(angle / 2). Both ends are measured that way so the shaft matches
	-- the cone the SpotLight actually lights.
	local halfAngle = math.rad(config.spotAngle * 0.5)
	local spread = 2 * math.tan(halfAngle)

	local beam = Instance.new("Beam")
	beam.Name = "FlashlightCone"
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Width0 = CONE_START * spread
	beam.Width1 = CONE_MAX * spread
	beam.FaceCamera = true
	beam.LightInfluence = 0
	beam.LightEmission = 1
	beam.Color = ColorSequence.new(config.color)
	beam.Transparency = Rig.coneRamp(config.coneTransparency)
	-- One segment is a single quad, which hinges visibly as you turn. Enough
	-- segments to read as a taper instead.
	beam.Segments = 12
	beam.Enabled = false
	beam.Parent = e
	coneBeam = beam

	local coneParams = RaycastParams.new()
	coneParams.FilterType = Enum.RaycastFilterType.Exclude
	coneParams.IgnoreWater = true

	-- Track the camera every frame so the cone points exactly where the player looks,
	-- nudged forward + down so it reads as a held light originating from the player,
	-- and trim the shaft so it stops short of whatever it is pointed at.
	renderConn = RunService.RenderStepped:Connect(function(dt: number)
		local cam = workspace.CurrentCamera
		if not (emitterPart and cam) then
			return
		end

		-- Lagged aim: rotation chases the camera, position does not lag.
		local target = cam.CFrame * HOLD_OFFSET
		local alpha = 1 - math.exp(-FOLLOW_SHARPNESS * dt)
		local rotation = if lagRotation then lagRotation:Lerp(target.Rotation, alpha) else target.Rotation
		lagRotation = rotation
		local t = os.clock()
		local wobble = CFrame.Angles(
			math.rad(math.noise(t * 0.7, 3.1) * HAND_WOBBLE_DEG),
			math.rad(math.noise(t * 0.6, 8.7) * HAND_WOBBLE_DEG),
			0
		)
		emitterPart.CFrame = CFrame.new(target.Position) * rotation * wobble

		-- Hotspot mirrors the spill light's state (see HOTSPOT_* above).
		if hotspot and spotlight then
			hotspot.Enabled = spotlight.Enabled
			hotspot.Brightness = spotlight.Brightness * HOTSPOT_BRIGHTNESS_RATIO
			hotspot.Color = spotlight.Color
		end

		if not (coneBeam and a1 and isOn()) then
			return
		end

		coneParams.FilterDescendantsInstances = { emitterPart, player.Character }
		local hit = workspace:Raycast(emitterPart.Position, emitterPart.CFrame.LookVector * CONE_MAX, coneParams)
		local reach = if hit then hit.Distance - CONE_MARGIN else CONE_MAX

		if reach <= CONE_START + 1 then
			-- Pressed up against something: there is no room for a shaft, and any
			-- quad here would just be a bright smear on the surface.
			coneBeam.Enabled = false
			return
		end
		coneBeam.Enabled = true
		a1.Position = Vector3.new(0, 0, -reach)
		coneBeam.Width1 = reach * spread
	end)

	return { emitter = e, light = light, cone = beam }
end

return Rig
