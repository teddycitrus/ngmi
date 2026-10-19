--!strict
--[[
	VFXManager.client.luau
	Visual effects controller for atmosphere, combat, and transitions.

	Owns:
	  * Event post-processing (ColorCorrection, Bloom) and screen overlays
	    (glitch, flash, static)
	  * The NGMI proximity poll and the deodorant/melee hit report
	  * Wiring for VFX/Focus (depth of field), VFX/Shake (camera shake) and
	    VFX/Particles (corruption smoke, spray, rain, ending effects)

	Effect layering
	---------------
	LightingController owns the PHASE look through GameColorCorrection / GameBloom
	/ GameBlur. This script's stack layers on top of that, so its ColorCorrection
	and Bloom sit at IDENTITY (zero contribution) at rest and only deviate while an
	event is playing. Two blooms both running hot would double-expose the whole
	frame. Every instance here is resolved by its own unique name for the same
	reason, never by class, or two systems end up fighting over one effect.
]]

local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local VFX = script.Parent:WaitForChild("VFX")
local Focus = require(VFX:WaitForChild("Focus"))
local Shake = require(VFX:WaitForChild("Shake"))
local Particles = require(VFX:WaitForChild("Particles"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local GameStateChanged = Remotes:WaitForChild("GameStateChanged") :: RemoteEvent
local DeodorantSpray = Remotes:WaitForChild("DeodorantSpray") :: RemoteEvent
local CorruptionStarted = Remotes:WaitForChild("CorruptionStarted") :: RemoteEvent
local EndingTrigger = Remotes:WaitForChild("EndingTrigger") :: RemoteEvent
local SabotageEvent = Remotes:WaitForChild("SabotageEvent") :: RemoteEvent

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = workspace.CurrentCamera

-- ============================================================
-- CONSTANTS
-- ============================================================

local PHASE_LOBBY = 0
local PHASE_NIGHT2 = 3

-- Post-processing instance names (unique to this script)
local NAME_COLOR_CORRECTION = "VFXColorCorrection"
local NAME_BLOOM = "VFXBloom"

-- NGMI proximity shake (NIGHT2)
local PROXIMITY_RANGE = 30 -- studs; inside this an NGMI rattles the camera
local PROXIMITY_MAX_TRAUMA = 0.22 -- ceiling for the continuous tremor
local PROXIMITY_POLL_INTERVAL = 0.2

-- ============================================================
-- STATE
-- ============================================================
local currentPhase = 0

-- Post-processing stack
local colorCorrection: ColorCorrectionEffect
local bloomEffect: BloomEffect

-- ============================================================
-- POST-PROCESSING STACK
-- ============================================================

--- Resolve a uniquely-named child of Lighting, creating it if absent.
--- Name-based on purpose: LightingController, HUDController and NGMIClient all
--- park their own effects here, and a class lookup would adopt the wrong one.
local function ensureEffect<T>(className: string, name: string): T
	local existing = Lighting:FindFirstChild(name)
	if existing and existing:IsA(className) then
		return existing :: any
	end
	local created = Instance.new(className)
	created.Name = name
	created.Parent = Lighting
	return created :: any
end

local function buildPostProcessingStack()
	colorCorrection = ensureEffect("ColorCorrectionEffect", NAME_COLOR_CORRECTION)
	-- Identity at rest: events drive it, the phase look belongs to LightingController.
	colorCorrection.Brightness = 0
	colorCorrection.Contrast = 0
	colorCorrection.Saturation = 0
	colorCorrection.TintColor = Color3.new(1, 1, 1)
	colorCorrection.Enabled = true

	bloomEffect = ensureEffect("BloomEffect", NAME_BLOOM)
	-- Intensity 0 contributes nothing on top of GameBloom until an event fires.
	bloomEffect.Intensity = 0
	bloomEffect.Size = 28
	bloomEffect.Threshold = 0.9
	bloomEffect.Enabled = true
end

-- ============================================================
-- SCREEN EFFECTS MODULE
-- ============================================================
local screenEffectsGui: ScreenGui? = nil

local function getScreenGui(): ScreenGui
	if screenEffectsGui and screenEffectsGui.Parent then
		return screenEffectsGui
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "VFXOverlay"
	gui.DisplayOrder = 40
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.Parent = playerGui
	screenEffectsGui = gui

	return gui
end

--- Rapid desaturate / tint stutter. Drives the shared VFX ColorCorrection and
--- restores it to identity when finished, so it never leaves a residual tint on
--- top of the phase look.
local function applyGlitch(duration: number)
	task.spawn(function()
		local endTime = os.clock() + duration
		while os.clock() < endTime do
			colorCorrection.Saturation = -1
			colorCorrection.TintColor = Color3.fromRGB(255, math.random(0, 50), math.random(0, 50))
			task.wait(0.05)
			colorCorrection.Saturation = 0
			colorCorrection.TintColor = Color3.new(1, 1, 1)
			task.wait(0.03)
		end
		colorCorrection.Saturation = 0
		colorCorrection.TintColor = Color3.new(1, 1, 1)
	end)

	-- Blur flash on a throwaway instance so it can't clobber GameBlur.
	local blur = Instance.new("BlurEffect")
	blur.Name = "VFXGlitchBlur"
	blur.Size = 10
	blur.Parent = Lighting

	task.delay(duration, function()
		blur:Destroy()
	end)
end

local function flashScreen(color: Color3, duration: number)
	local gui = getScreenGui()

	local flash = Instance.new("Frame")
	flash.Size = UDim2.new(1, 0, 1, 0)
	flash.BackgroundColor3 = color
	flash.BackgroundTransparency = 0.5
	flash.BorderSizePixel = 0
	flash.ZIndex = 50
	flash.Parent = gui

	TweenService:Create(flash, TweenInfo.new(duration), {
		BackgroundTransparency = 1,
	}):Play()

	task.delay(duration + 0.1, function()
		if flash.Parent then
			flash:Destroy()
		end
	end)
end

local function applyStaticNoise(intensity: number, duration: number)
	local gui = getScreenGui()

	-- Create static noise effect with rapid random frames
	local staticFrame = Instance.new("Frame")
	staticFrame.Name = "StaticNoise"
	staticFrame.Size = UDim2.new(1, 0, 1, 0)
	staticFrame.BackgroundColor3 = Color3.new(1, 1, 1)
	staticFrame.BackgroundTransparency = 1 - (intensity * 0.15)
	staticFrame.BorderSizePixel = 0
	staticFrame.ZIndex = 45
	staticFrame.Parent = gui

	-- Rapid flicker
	local conn: RBXScriptConnection? = nil
	conn = RunService.RenderStepped:Connect(function()
		if staticFrame.Parent then
			staticFrame.BackgroundTransparency = 1 - (math.random() * intensity * 0.2)
			staticFrame.BackgroundColor3 = Color3.new(math.random() * 0.3, math.random() * 0.3, math.random() * 0.3)
		end
	end)

	task.delay(duration, function()
		if conn then
			conn:Disconnect()
		end
		if staticFrame.Parent then
			staticFrame:Destroy()
		end
	end)
end

--- Short bloom bump. Used to sell a jumpscare without touching the phase bloom.
local function pulseBloom(intensity: number, duration: number)
	bloomEffect.Intensity = intensity
	TweenService:Create(bloomEffect, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Intensity = 0,
	}):Play()
end

-- ============================================================
-- NGMI PROXIMITY TREMOR (Night 2)
-- ============================================================
-- A low continuous rattle that grows as the nearest NGMI closes in. Polled
-- rather than per-frame: the tag lookup is the expensive part and 5 Hz is
-- plenty for something that feeds a smoothed trauma value.
-- ============================================================
local function nearestNGMIDistance(): number
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return math.huge
	end

	local best = math.huge
	for _, ngmi in CollectionService:GetTagged("NGMI") do
		if ngmi:IsA("Model") then
			local ngmiRoot = (ngmi:FindFirstChild("HumanoidRootPart") or ngmi.PrimaryPart) :: BasePart?
			if ngmiRoot then
				local dist = (ngmiRoot.Position - root.Position).Magnitude
				if dist < best then
					best = dist
				end
			end
		end
	end
	return best
end

task.spawn(function()
	while true do
		task.wait(PROXIMITY_POLL_INTERVAL)

		if currentPhase ~= PHASE_NIGHT2 then
			Focus.setCloseness(0)
		else
			local dist = nearestNGMIDistance()
			local closeness = if dist < PROXIMITY_RANGE then 1 - (dist / PROXIMITY_RANGE) else 0
			Focus.setCloseness(closeness)
			-- Top up toward the proximity ceiling without stacking past it, so a
			-- nearby NGMI hums rather than escalating to a full quake.
			local target = closeness * PROXIMITY_MAX_TRAUMA
			if target > 0 and Shake.get() < target then
				Shake.add(target - Shake.get())
			end
		end
	end
end)

-- ============================================================
-- EVENT LISTENERS
-- ============================================================
GameStateChanged.OnClientEvent:Connect(function(data: { phase: number })
	local prevPhase = currentPhase
	currentPhase = data.phase

	if data.phase == PHASE_NIGHT2 then
		Particles.startRain()
	elseif prevPhase == PHASE_NIGHT2 then
		Particles.stopRain()
	end
	Focus.setPhase(data.phase, data.phase == PHASE_LOBBY)

	if data.phase ~= prevPhase then
		Particles.cleanupEffects()
	end
end)

CorruptionStarted.OnClientEvent:Connect(function()
	Focus.setCorruption()
	Particles.applyCorruptionToNPCs()
	-- Atmospheric glitch
	applyGlitch(0.5)
	flashScreen(Color3.fromRGB(80, 0, 120), 0.3)
	Shake.add(0.45)
end)

-- Power sabotage: the lights die and the building lurches. Payload shape varies
-- by sender (GameStateManager sends { sabotageType }, SurvivalManager sends
-- { panelId, zone }), so this deliberately ignores the contents.
SabotageEvent.OnClientEvent:Connect(function()
	Shake.add(0.5)
	applyStaticNoise(0.6, 0.5)
end)

DeodorantSpray.OnClientEvent:Connect(function(data: { playerId: number? }?)
	Particles.createSprayVFX()

	-- Only the player who actually sprayed figures out which NGMI was hit and
	-- reports it to the server (NGMIController damages + repels it). Without this
	-- the spray did nothing, the server never learned what you sprayed.
	if typeof(data) ~= "table" or data.playerId ~= player.UserId then
		return
	end
	local char = player.Character
	local origin = char and char:FindFirstChild("Head") :: BasePart?
	if not origin then
		return
	end
	local SPRAY_RANGE = 22
	local dir = camera.CFrame.LookVector

	-- 1) Direct hit: spray what you're aiming at.
	local target: Model? = nil
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { char }
	local hit = workspace:Raycast(origin.Position, dir * SPRAY_RANGE, params)
	if hit then
		local cur: Instance? = hit.Instance
		while cur and cur ~= workspace do
			if cur:IsA("Model") and CollectionService:HasTag(cur, "NGMI") then
				target = cur
				break
			end
			cur = cur.Parent
		end
	end

	-- 2) Forgiving fallback: nearest NGMI roughly in front of you, in range.
	if not target then
		local bestDist = math.huge
		for _, ngmi in CollectionService:GetTagged("NGMI") do
			if ngmi:IsA("Model") then
				local root = (ngmi:FindFirstChild("HumanoidRootPart") or ngmi.PrimaryPart) :: BasePart?
				if root then
					local to = root.Position - origin.Position
					local dist = to.Magnitude
					if dist <= SPRAY_RANGE and dist > 0.1 and dir:Dot(to.Unit) > 0.25 and dist < bestDist then
						bestDist = dist
						target = ngmi
					end
				end
			end
		end
	end

	if target then
		DeodorantSpray:FireServer(target)
	end
end)

EndingTrigger.OnClientEvent:Connect(function(data: { ending: string })
	if data.ending == "true" or data.ending == "good" then
		Particles.dissolveNGMIs()
		task.delay(2, Particles.spawnConfetti)
	end
end)

-- Keep the depth-of-field ray from colliding with a freshly spawned character.
player.CharacterAdded:Connect(Focus.refreshFilter)

-- ============================================================
-- PUBLIC API
-- ============================================================
-- A LocalScript cannot be require()d, so the API is published as BindableEvents
-- parented to this script, the same pattern CameraController uses for its
-- CameraShake bus. Callers do:
--   local vfx = script.Parent:WaitForChild("VFXManager")
--   vfx:WaitForChild("VFXShake"):Fire(0.8)
-- ============================================================
local function publishEvent(name: string, handler: (...any) -> ()): ()
	local bindable = Instance.new("BindableEvent")
	bindable.Name = name
	bindable.Parent = script
	bindable.Event:Connect(handler)
end

publishEvent("VFXShake", function(intensity: number)
	Shake.add(intensity)
end)

publishEvent("VFXJumpScare", function(intensity: number?)
	local amount = intensity or 1
	Shake.add(amount)
	pulseBloom(1.2 * amount, 0.6)
	applyStaticNoise(0.8 * amount, 0.35)
end)

publishEvent("VFXGlitch", function(duration: number)
	applyGlitch(duration)
end)

publishEvent("VFXFlash", function(color: Color3, duration: number)
	flashScreen(color, duration)
end)

publishEvent("VFXStatic", function(intensity: number, duration: number)
	applyStaticNoise(intensity, duration)
end)

-- ============================================================
-- INITIALISATION
-- ============================================================
buildPostProcessingStack()
Focus.init()
-- Start in whatever phase is already live (a respawn or late load), not
-- blindly: in the lobby the focus raycast stays off until a phase change.
do
	local phaseValue = ReplicatedStorage:FindFirstChild("CurrentPhase")
	currentPhase = if phaseValue and phaseValue:IsA("IntValue") then phaseValue.Value else PHASE_LOBBY
	Focus.setPhase(currentPhase, currentPhase == PHASE_LOBBY)
end

print("[VFXManager] Initialised - post-processing stack, raycast DOF and Perlin camera shake ready")
