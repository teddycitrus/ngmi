--!strict
--------------------------------------------------------------------------------
-- VFX/Particles.luau
-- Particle and world effects for VFXManager: corruption smoke on NPCs, the
-- deodorant spray burst, Night 2 rain, and the true-ending code dissolution and
-- confetti. Every emitter part is CanQuery = false so it never blocks a
-- raycast (depth-of-field focus, spray targeting).
--------------------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local Particles = {}

local activeEffects: { Instance } = {}
local rainPart: BasePart? = nil
local rainEmitter: ParticleEmitter? = nil

-- ============================================================
-- CLEANUP
-- ============================================================
function Particles.cleanupEffects()
	for _, effect in activeEffects do
		if effect.Parent then
			effect:Destroy()
		end
	end
	activeEffects = {}
end

-- ============================================================
-- CORRUPTION SMOKE (Day 2 Halfway Shift)
-- ============================================================
local function addCorruptionSmoke(npc: Model)
	local torso = npc:FindFirstChild("Torso") or npc:FindFirstChild("UpperTorso")
	if not torso or not torso:IsA("BasePart") then
		return
	end

	-- Check if already has corruption particles
	if torso:FindFirstChild("CorruptionSmoke") then
		return
	end

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "CorruptionSmoke"
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(80, 20, 100)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(40, 10, 60)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(10, 0, 15)),
	})
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(0.5, 0.8),
		NumberSequenceKeypoint.new(1, 1.5),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(0.6, 0.7),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(2, 4)
	emitter.Rate = 8
	emitter.Speed = NumberRange.new(0.3, 1.5)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.RotSpeed = NumberRange.new(-60, 60)
	emitter.Acceleration = Vector3.new(0, 1, 0) -- Float upward
	emitter.Parent = torso

	table.insert(activeEffects, emitter)
end

function Particles.applyCorruptionToNPCs()
	for _, npc in CollectionService:GetTagged("NPC") do
		if npc:IsA("Model") then
			addCorruptionSmoke(npc)
		end
	end
end

-- ============================================================
-- DEODORANT SPRAY VFX
-- ============================================================
function Particles.createSprayVFX()
	local character = player.Character
	if not character then
		return
	end

	local head = character:FindFirstChild("Head") :: BasePart?
	if not head then
		return
	end

	-- Create spray particles at head/hand position
	local sprayPart = Instance.new("Part")
	sprayPart.Name = "SprayVFX"
	sprayPart.Size = Vector3.new(0.5, 0.5, 0.5)
	sprayPart.Transparency = 1
	sprayPart.Anchored = true
	sprayPart.CanCollide = false
	-- Decorative only: keep it out of every raycast, including the spray's own
	-- target trace (VFXManager) and the depth-of-field focus probe.
	sprayPart.CanQuery = false
	sprayPart.CanTouch = false
	sprayPart.CFrame = head.CFrame * CFrame.new(0, 0, -2)
	sprayPart.Parent = workspace

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(200, 240, 255)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(255, 255, 255)),
	})
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(0.3, 1.5),
		NumberSequenceKeypoint.new(1, 3),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(0.5, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(0.3, 0.6)
	emitter.Rate = 100
	emitter.Speed = NumberRange.new(15, 25)
	emitter.SpreadAngle = Vector2.new(18, 18)
	emitter.RotSpeed = NumberRange.new(-180, 180)
	-- Emit out the part's Front (-Z) face. The part is oriented (below) so -Z
	-- points where the player is aiming, so the spray shoots that way instead of
	-- straight up (the default Top emission direction).
	emitter.EmissionDirection = Enum.NormalId.Front
	emitter.Parent = sprayPart

	-- Orient spray in camera direction (its -Z / Front faces the aim point)
	local lookDir = camera.CFrame.LookVector
	sprayPart.CFrame = CFrame.lookAt(head.Position + lookDir * 1.5, head.Position + lookDir * 10)

	-- Brief burst then cleanup
	task.delay(0.4, function()
		emitter.Enabled = false
	end)
	task.delay(1, function()
		sprayPart:Destroy()
	end)
end

-- ============================================================
-- RAIN EFFECT (Night 2)
-- ============================================================
function Particles.startRain()
	if rainPart then
		return
	end

	-- Create invisible Part above the map for rain emission
	local part = Instance.new("Part")
	part.Name = "RainEmitter"
	part.Size = Vector3.new(200, 1, 150)
	part.Position = Vector3.new(0, 60, 0) -- Above the building
	part.Transparency = 1
	part.Anchored = true
	part.CanCollide = false
	-- Sits directly above the venue; without this it swallows every upward ray,
	-- including the depth-of-field probe and the deodorant target trace.
	part.CanQuery = false
	part.CanTouch = false
	part.Parent = workspace
	rainPart = part

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(Color3.fromRGB(180, 200, 255))
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.05),
		NumberSequenceKeypoint.new(1, 0.05),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(1, 0.8),
	})
	emitter.Lifetime = NumberRange.new(0.5, 1)
	emitter.Rate = 200
	emitter.Speed = NumberRange.new(40, 60)
	emitter.EmissionDirection = Enum.NormalId.Bottom
	emitter.SpreadAngle = Vector2.new(5, 5)
	emitter.Acceleration = Vector3.new(0, -50, 0)
	emitter.Parent = part
	rainEmitter = emitter

	table.insert(activeEffects, part)
end

function Particles.stopRain()
	if rainEmitter then
		rainEmitter.Enabled = false
	end
	task.delay(2, function()
		if rainPart then
			rainPart:Destroy()
			rainPart = nil
			rainEmitter = nil
		end
	end)
end

-- ============================================================
-- CODE DISSOLUTION (True Ending)
-- ============================================================
function Particles.dissolveNGMIs()
	for _, ngmi in CollectionService:GetTagged("NGMI") do
		if ngmi:IsA("Model") then
			-- Add code-like dissolution particles
			local torso = ngmi:FindFirstChild("Torso") or ngmi:FindFirstChild("UpperTorso")
			if torso and torso:IsA("BasePart") then
				local dissolveEmitter = Instance.new("ParticleEmitter")
				dissolveEmitter.Color = ColorSequence.new({
					ColorSequenceKeypoint.new(0, Color3.fromRGB(0, 255, 100)),
					ColorSequenceKeypoint.new(0.5, Color3.fromRGB(100, 255, 200)),
					ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 255, 220)),
				})
				dissolveEmitter.Size = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0.3),
					NumberSequenceKeypoint.new(1, 0.1),
				})
				dissolveEmitter.Transparency = NumberSequence.new({
					NumberSequenceKeypoint.new(0, 0),
					NumberSequenceKeypoint.new(0.8, 0.5),
					NumberSequenceKeypoint.new(1, 1),
				})
				dissolveEmitter.Lifetime = NumberRange.new(2, 4)
				dissolveEmitter.Rate = 50
				dissolveEmitter.Speed = NumberRange.new(2, 5)
				dissolveEmitter.Acceleration = Vector3.new(0, 3, 0) -- Float up
				dissolveEmitter.SpreadAngle = Vector2.new(180, 180)
				dissolveEmitter.Parent = torso
			end

			-- Fade out the NGMI model
			task.spawn(function()
				for _, part in ngmi:GetDescendants() do
					if part:IsA("BasePart") then
						TweenService:Create(part, TweenInfo.new(3), {
							Transparency = 1,
						}):Play()
					end
				end
				task.wait(4)
				if ngmi.Parent then
					ngmi:Destroy()
				end
			end)
		end
	end
end

-- ============================================================
-- CONFETTI (True Ending)
-- ============================================================
function Particles.spawnConfetti()
	-- Create confetti particles from above
	local confettiPart = Instance.new("Part")
	confettiPart.Name = "ConfettiEmitter"
	confettiPart.Size = Vector3.new(40, 1, 40)
	confettiPart.Transparency = 1
	confettiPart.Anchored = true
	confettiPart.CanCollide = false
	confettiPart.CanQuery = false
	confettiPart.CanTouch = false
	confettiPart.Parent = workspace

	local character = player.Character
	if character and character.PrimaryPart then
		confettiPart.Position = character.PrimaryPart.Position + Vector3.new(0, 20, 0)
	else
		confettiPart.Position = Vector3.new(0, 30, 0)
	end

	local colors = {
		Color3.fromRGB(255, 50, 50),
		Color3.fromRGB(50, 200, 255),
		Color3.fromRGB(255, 220, 50),
		Color3.fromRGB(100, 255, 100),
		Color3.fromRGB(255, 100, 255),
	}

	for _, color in colors do
		local emitter = Instance.new("ParticleEmitter")
		emitter.Color = ColorSequence.new(color)
		emitter.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.3),
			NumberSequenceKeypoint.new(1, 0.3),
		})
		emitter.Transparency = NumberSequence.new(0)
		emitter.Lifetime = NumberRange.new(3, 5)
		emitter.Rate = 20
		emitter.Speed = NumberRange.new(1, 5)
		emitter.EmissionDirection = Enum.NormalId.Bottom
		emitter.SpreadAngle = Vector2.new(60, 60)
		emitter.RotSpeed = NumberRange.new(-360, 360)
		emitter.Acceleration = Vector3.new(0, -10, 0)
		emitter.Parent = confettiPart
	end

	table.insert(activeEffects, confettiPart)

	-- Stop after 10 seconds
	task.delay(10, function()
		for _, child in confettiPart:GetChildren() do
			if child:IsA("ParticleEmitter") then
				child.Enabled = false
			end
		end
		task.delay(5, function()
			confettiPart:Destroy()
		end)
	end)
end

return Particles
