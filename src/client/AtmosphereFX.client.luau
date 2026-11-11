--!strict
--------------------------------------------------------------------------------
-- AtmosphereFX.client.luau
-- Local, per-player ambient particles and practical-light misbehaviour.
--
--   • Dust motes: a world-space particle volume that follows the camera. The
--     motes use LightInfluence 1 and no emission, so they are invisible in the
--     dark and only appear where a light (or the flashlight cone) passes
--     through them. That is what sells a flashlight beam as cutting through air.
--   • Ground fog: during CORRUPTION and NIGHT2 a thin layer of large, very
--     transparent smoke particles hugs the floor under the player.
--   • Flicker + sparks: from DAY2 on, a nearby CeilingLight fixture now and
--     then stutters. Sometimes it spits a shower of sparks with a buzz and a
--     brief orange flash.
--
-- Flicker only ever touches a light's Brightness and its fixture's Color,
-- restoring both after. LightingController owns Enabled and Material, so the
-- two never fight even if a phase change lands mid-flicker.
--
-- Every part created here is CanQuery = false so it never blocks gameplay
-- raycasts or the depth-of-field focus probe.
--------------------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local CorruptionStarted = Remotes:WaitForChild("CorruptionStarted") :: RemoteEvent

local camera = workspace.CurrentCamera

--------------------------------------------------------------------------------
-- Tunables
--------------------------------------------------------------------------------

local SMOKE_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local BUZZ_SOUND = "rbxassetid://12222019" -- same crackle AudioManager uses

local PHASE_LOBBY = 0
local PHASE_DAY1 = 1
local PHASE_DAY2 = 2
local PHASE_NIGHT2 = 3

-- Dust motes per phase (particles / second inside the camera volume)
local DUST_RATE: { [number]: number } = {
	[PHASE_LOBBY] = 0,
	[PHASE_DAY1] = 25,
	[PHASE_DAY2] = 40,
	[PHASE_NIGHT2] = 70,
	[4] = 30, -- DAY3: dawn light through dust
}
local DUST_RATE_CORRUPTION = 60
local DUST_VOLUME = Vector3.new(36, 14, 36)

local FOG_RATE = 7
local FOG_VOLUME = Vector3.new(56, 0.6, 56)
local FOG_FLOOR_PROBE = 0.3 -- seconds between floor raycasts

-- Flicker scheduling per phase: { min gap, max gap } in seconds
local FLICKER_GAP: { [number]: { number } } = {
	[PHASE_DAY2] = { 7, 16 },
	[PHASE_NIGHT2] = { 3, 8 },
}
local FLICKER_GAP_CORRUPTION = { 2, 6 }
local FLICKER_RANGE = 55
local SPARK_CHANCE = 0.35

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local currentPhase = PHASE_LOBBY
local corruption = false
local flickering: { [Instance]: boolean } = {}
local rng = Random.new()

--------------------------------------------------------------------------------
-- Rig helpers
--------------------------------------------------------------------------------

local function carrierPart(name: string, size: Vector3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Transparency = 1
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = workspace
	return p
end

--------------------------------------------------------------------------------
-- Dust motes
--------------------------------------------------------------------------------

local dustPart = carrierPart("AtmosphereDust", DUST_VOLUME)
local dust = Instance.new("ParticleEmitter")
dust.Name = "DustMotes"
dust.Texture = SMOKE_TEXTURE
dust.Shape = Enum.ParticleEmitterShape.Box
dust.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
dust.Rate = 0
dust.Lifetime = NumberRange.new(8, 14)
dust.Speed = NumberRange.new(0.05, 0.25)
dust.SpreadAngle = Vector2.new(180, 180)
dust.Acceleration = Vector3.new(0, -0.015, 0)
dust.Drag = 0.6
dust.RotSpeed = NumberRange.new(-20, 20)
dust.Size = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 0.05),
	NumberSequenceKeypoint.new(1, 0.08),
})
dust.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.2, 0.25),
	NumberSequenceKeypoint.new(0.8, 0.35),
	NumberSequenceKeypoint.new(1, 1),
})
dust.Color = ColorSequence.new(Color3.fromRGB(235, 228, 215))
-- Lit only by real lights: invisible in the dark, glittering in a beam.
dust.LightInfluence = 1
dust.LightEmission = 0
dust.Parent = dustPart

--------------------------------------------------------------------------------
-- Ground fog
--------------------------------------------------------------------------------

local fogPart = carrierPart("AtmosphereGroundFog", FOG_VOLUME)
local fog = Instance.new("ParticleEmitter")
fog.Name = "GroundFog"
fog.Texture = SMOKE_TEXTURE
fog.Shape = Enum.ParticleEmitterShape.Box
fog.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
fog.Rate = 0
fog.Lifetime = NumberRange.new(10, 16)
fog.Speed = NumberRange.new(0.15, 0.5)
fog.SpreadAngle = Vector2.new(180, 8)
fog.EmissionDirection = Enum.NormalId.Top
fog.Acceleration = Vector3.new(0, -0.02, 0)
fog.RotSpeed = NumberRange.new(-6, 6)
fog.Rotation = NumberRange.new(0, 360)
fog.Size = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 5),
	NumberSequenceKeypoint.new(1, 9),
})
fog.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.3, 0.88),
	NumberSequenceKeypoint.new(0.7, 0.9),
	NumberSequenceKeypoint.new(1, 1),
})
fog.LightInfluence = 0.85
fog.Parent = fogPart

local fogParams = RaycastParams.new()
fogParams.FilterType = Enum.RaycastFilterType.Exclude
fogParams.IgnoreWater = true

local floorY = 0
local lastProbe = 0
local fogOn = false
local lastCamPos: Vector3? = nil
-- false until the filter is first built; then the character it was built for
local filterChar: Model | false | nil = false

--------------------------------------------------------------------------------
-- Phase application
--------------------------------------------------------------------------------

local function applyPhase()
	dust.Rate = if corruption then DUST_RATE_CORRUPTION else (DUST_RATE[currentPhase] or 0)

	fogOn = corruption or currentPhase == PHASE_NIGHT2
	fog.Rate = if fogOn then FOG_RATE else 0
	fog.Color = ColorSequence.new(if corruption then Color3.fromRGB(70, 86, 78) else Color3.fromRGB(42, 48, 62))
end

--------------------------------------------------------------------------------
-- Follow the camera
--------------------------------------------------------------------------------

RunService.Heartbeat:Connect(function()
	local camPos = camera.CFrame.Position
	if camPos ~= lastCamPos then
		lastCamPos = camPos
		dustPart.CFrame = CFrame.new(camPos)
	end

	if fogOn then
		local now = os.clock()
		if now - lastProbe > FOG_FLOOR_PROBE then
			lastProbe = now
			local character = Players.LocalPlayer.Character
			if character ~= filterChar then
				filterChar = character
				fogParams.FilterDescendantsInstances = if character then { character, dustPart, fogPart } else { dustPart, fogPart }
			end
			local hit = workspace:Raycast(camPos, Vector3.new(0, -20, 0), fogParams)
			if hit then
				floorY = hit.Position.Y
			end
		end
		fogPart.CFrame = CFrame.new(camPos.X, floorY + FOG_VOLUME.Y / 2 + 0.2, camPos.Z)
	end
end)

--------------------------------------------------------------------------------
-- Flicker + sparks
--------------------------------------------------------------------------------

local function lightsIn(fixture: Instance): { Light }
	local lights: { Light } = {}
	for _, d in fixture:GetDescendants() do
		if d:IsA("Light") then
			table.insert(lights, d)
		end
	end
	return lights
end

local function sparkBurst(fixture: BasePart)
	local attach = Instance.new("Attachment")
	attach.Position = Vector3.new(0, -fixture.Size.Y / 2, 0)
	attach.Parent = fixture

	local sparks = Instance.new("ParticleEmitter")
	sparks.Rate = 0
	sparks.Lifetime = NumberRange.new(0.35, 0.9)
	sparks.Speed = NumberRange.new(6, 13)
	sparks.SpreadAngle = Vector2.new(65, 65)
	sparks.EmissionDirection = Enum.NormalId.Bottom
	sparks.Acceleration = Vector3.new(0, -45, 0)
	sparks.Drag = 1.5
	sparks.LightEmission = 1
	sparks.LightInfluence = 0
	sparks.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.09),
		NumberSequenceKeypoint.new(1, 0.01),
	})
	sparks.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 245, 210)),
		ColorSequenceKeypoint.new(0.4, Color3.fromRGB(255, 170, 60)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 60, 10)),
	})
	sparks.Parent = attach
	sparks:Emit(rng:NextInteger(14, 30))

	local flash = Instance.new("PointLight")
	flash.Color = Color3.fromRGB(255, 170, 80)
	flash.Brightness = 4
	flash.Range = 14
	flash.Parent = attach
	task.delay(0.08, function()
		flash.Enabled = false
	end)

	local buzz = Instance.new("Sound")
	buzz.SoundId = BUZZ_SOUND
	buzz.Volume = 0.45
	buzz.PlaybackSpeed = rng:NextNumber(0.9, 1.2)
	buzz.RollOffMaxDistance = 45
	buzz.Parent = attach
	buzz:Play()

	task.delay(2.5, function()
		attach:Destroy()
	end)
end

local function flicker(fixture: BasePart)
	if flickering[fixture] then
		return
	end
	local lights = lightsIn(fixture)
	local anyOn = false
	for _, l in lights do
		if l.Enabled then
			anyOn = true
		end
	end
	if not anyOn then
		return -- dark fixtures (NIGHT2 blackout) have nothing to flicker
	end
	flickering[fixture] = true

	local baseBrightness: { [Light]: number } = {}
	for _, l in lights do
		baseBrightness[l] = l.Brightness
	end
	local baseColor = fixture.Color
	local dimColor = baseColor:Lerp(Color3.new(0.1, 0.1, 0.1), 0.85)

	-- PowerManager / SurvivalManager change these same properties on the
	-- server. If a replicated change lands mid-flicker, the value we find no
	-- longer matches what we wrote: that light is dropped from the flicker and
	-- never "restored" to a stale base.
	local written: { [Light]: number } = {}
	local colorWritten: Color3? = nil

	local function setLevel(level: number)
		for _, l in lights do
			local base = baseBrightness[l]
			local mine = written[l]
			if base and (mine == nil or math.abs(l.Brightness - mine) < 1e-4) then
				l.Brightness = base * level
				written[l] = l.Brightness
			else
				baseBrightness[l] = nil
			end
		end
	end

	local function setColor(color: Color3)
		if colorWritten == nil or fixture.Color == colorWritten then
			fixture.Color = color
			colorWritten = color
		end
	end

	task.spawn(function()
		local sparkAt = if rng:NextNumber() < SPARK_CHANCE then rng:NextInteger(1, 3) else -1
		for i = 1, rng:NextInteger(3, 9) do
			setLevel(rng:NextNumber(0.02, 0.35))
			setColor(dimColor)
			if i == sparkAt then
				sparkBurst(fixture)
			end
			task.wait(rng:NextNumber(0.03, 0.14))

			setLevel(1)
			setColor(baseColor)
			task.wait(rng:NextNumber(0.02, 0.25))
		end
		flickering[fixture] = nil
	end)
end

--- Prefer a fixture the player can actually see, within range.
local function pickFixture(): BasePart?
	local camCF = camera.CFrame
	local candidates: { BasePart } = {}
	for _, inst in CollectionService:GetTagged("CeilingLight") do
		if inst:IsA("BasePart") then
			local offset = inst.Position - camCF.Position
			local dist = offset.Magnitude
			if dist < FLICKER_RANGE and dist > 4 and camCF.LookVector:Dot(offset.Unit) > 0.2 then
				table.insert(candidates, inst)
			end
		end
	end
	if #candidates == 0 then
		return nil
	end
	return candidates[rng:NextInteger(1, #candidates)]
end

task.spawn(function()
	while true do
		local gap = if corruption then FLICKER_GAP_CORRUPTION else FLICKER_GAP[currentPhase]
		if gap then
			task.wait(rng:NextNumber(gap[1], gap[2]))
			-- Re-check: the phase may have moved on while waiting.
			if corruption or FLICKER_GAP[currentPhase] then
				local fixture = pickFixture()
				if fixture then
					flicker(fixture)
				end
			end
		else
			task.wait(2)
		end
	end
end)

--------------------------------------------------------------------------------
-- Phase wiring
--------------------------------------------------------------------------------

local function onPhase(phase: number)
	if phase ~= currentPhase then
		corruption = false -- corruption only lives inside DAY2
	end
	currentPhase = phase
	applyPhase()
end

task.spawn(function()
	local phaseValue = ReplicatedStorage:WaitForChild("CurrentPhase", 30)
	if phaseValue and phaseValue:IsA("IntValue") then
		phaseValue.Changed:Connect(onPhase)
		onPhase(phaseValue.Value)
	end
end)

CorruptionStarted.OnClientEvent:Connect(function()
	if currentPhase == PHASE_DAY2 then
		corruption = true
		applyPhase()
	end
end)

applyPhase()
print("[AtmosphereFX] Initialised - dust motes, ground fog and fixture flicker ready")
