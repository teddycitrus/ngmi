--!strict
--[[
    VFXManager.client.luau
    Visual effects controller for atmosphere, combat, and transitions.
    Manages: corruption smoke, deodorant spray, screen effects, rain, confetti.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local GameStateChanged = Remotes:WaitForChild("GameStateChanged") :: RemoteEvent
local DeodorantSpray = Remotes:WaitForChild("DeodorantSpray") :: RemoteEvent
local CorruptionStarted = Remotes:WaitForChild("CorruptionStarted") :: RemoteEvent
local EndingTrigger = Remotes:WaitForChild("EndingTrigger") :: RemoteEvent

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = workspace.CurrentCamera

-- ============================================================
-- STATE
-- ============================================================
local currentPhase = 0
local activeEffects: { Instance } = {}
local rainPart: BasePart? = nil
local rainEmitter: ParticleEmitter? = nil

-- ============================================================
-- CLEANUP
-- ============================================================
local function cleanupEffects()
    for _, effect in activeEffects do
        if effect.Parent then effect:Destroy() end
    end
    activeEffects = {}
end

-- ============================================================
-- CORRUPTION SMOKE (Day 2 Halfway Shift)
-- ============================================================
local function addCorruptionSmoke(npc: Model)
    local torso = npc:FindFirstChild("Torso") or npc:FindFirstChild("UpperTorso")
    if not torso or not torso:IsA("BasePart") then return end

    -- Check if already has corruption particles
    if torso:FindFirstChild("CorruptionSmoke") then return end

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

local function applyCorruptionToNPCs()
    for _, npc in CollectionService:GetTagged("NPC") do
        if npc:IsA("Model") then
            addCorruptionSmoke(npc)
        end
    end
end

-- ============================================================
-- DEODORANT SPRAY VFX
-- ============================================================
local function createSprayVFX()
    local character = player.Character
    if not character then return end

    local head = character:FindFirstChild("Head") :: BasePart?
    if not head then return end

    -- Create spray particles at head/hand position
    local sprayPart = Instance.new("Part")
    sprayPart.Name = "SprayVFX"
    sprayPart.Size = Vector3.new(0.5, 0.5, 0.5)
    sprayPart.Transparency = 1
    sprayPart.Anchored = true
    sprayPart.CanCollide = false
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
    sprayPart.CFrame = CFrame.lookAt(
        head.Position + lookDir * 1.5,
        head.Position + lookDir * 10
    )

    -- Brief burst then cleanup
    task.delay(0.4, function()
        emitter.Enabled = false
    end)
    task.delay(1, function()
        sprayPart:Destroy()
    end)
end

-- ============================================================
-- SCREEN EFFECTS MODULE
-- ============================================================
local screenEffectsGui: ScreenGui? = nil
local vignetteFrame: Frame? = nil

local function getScreenGui(): ScreenGui
    if screenEffectsGui and screenEffectsGui.Parent then
        return screenEffectsGui
    end

    screenEffectsGui = Instance.new("ScreenGui")
    screenEffectsGui.Name = "VFXOverlay"
    screenEffectsGui.DisplayOrder = 40
    screenEffectsGui.IgnoreGuiInset = true
    screenEffectsGui.Parent = playerGui

    return screenEffectsGui
end

local function applyGlitch(duration: number)
    local cc = Lighting:FindFirstChild("VFXGlitchCC") :: ColorCorrectionEffect?
    if not cc then
        cc = Instance.new("ColorCorrectionEffect")
        cc.Name = "VFXGlitchCC"
        cc.Parent = Lighting
    end

    -- Rapid color shifts
    task.spawn(function()
        local endTime = tick() + duration
        while tick() < endTime do
            cc.Saturation = -1
            cc.TintColor = Color3.fromRGB(255, math.random(0, 50), math.random(0, 50))
            task.wait(0.05)
            cc.Saturation = 0
            cc.TintColor = Color3.new(1, 1, 1)
            task.wait(0.03)
        end
        cc.Saturation = 0
        cc.TintColor = Color3.new(1, 1, 1)
    end)

    -- Blur flash
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
        if flash.Parent then flash:Destroy() end
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
            staticFrame.BackgroundColor3 = Color3.new(
                math.random() * 0.3,
                math.random() * 0.3,
                math.random() * 0.3
            )
        end
    end)

    task.delay(duration, function()
        if conn then conn:Disconnect() end
        if staticFrame.Parent then staticFrame:Destroy() end
    end)
end

-- ============================================================
-- RAIN EFFECT (Night 2)
-- ============================================================
local function startRain()
    if rainPart then return end

    -- Create invisible Part above the map for rain emission
    rainPart = Instance.new("Part")
    rainPart.Name = "RainEmitter"
    rainPart.Size = Vector3.new(200, 1, 150)
    rainPart.Position = Vector3.new(0, 60, 0) -- Above the building
    rainPart.Transparency = 1
    rainPart.Anchored = true
    rainPart.CanCollide = false
    rainPart.Parent = workspace

    rainEmitter = Instance.new("ParticleEmitter")
    rainEmitter.Color = ColorSequence.new(Color3.fromRGB(180, 200, 255))
    rainEmitter.Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.05),
        NumberSequenceKeypoint.new(1, 0.05),
    })
    rainEmitter.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.3),
        NumberSequenceKeypoint.new(1, 0.8),
    })
    rainEmitter.Lifetime = NumberRange.new(0.5, 1)
    rainEmitter.Rate = 200
    rainEmitter.Speed = NumberRange.new(40, 60)
    rainEmitter.EmissionDirection = Enum.NormalId.Bottom
    rainEmitter.SpreadAngle = Vector2.new(5, 5)
    rainEmitter.Acceleration = Vector3.new(0, -50, 0)
    rainEmitter.Parent = rainPart

    table.insert(activeEffects, rainPart)
end

local function stopRain()
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
local function dissolveNGMIs()
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
                if ngmi.Parent then ngmi:Destroy() end
            end)
        end
    end
end

-- ============================================================
-- CONFETTI (True Ending)
-- ============================================================
local function spawnConfetti()
    -- Create confetti particles from above
    local confettiPart = Instance.new("Part")
    confettiPart.Name = "ConfettiEmitter"
    confettiPart.Size = Vector3.new(40, 1, 40)
    confettiPart.Transparency = 1
    confettiPart.Anchored = true
    confettiPart.CanCollide = false
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

-- ============================================================
-- EVENT LISTENERS
-- ============================================================
GameStateChanged.OnClientEvent:Connect(function(data: { phase: number })
    local prevPhase = currentPhase
    currentPhase = data.phase

    if data.phase == 3 then -- NIGHT2
        startRain()
    elseif prevPhase == 3 then -- Leaving Night2
        stopRain()
    end

    if data.phase ~= prevPhase then
        cleanupEffects()
    end
end)

CorruptionStarted.OnClientEvent:Connect(function()
    applyCorruptionToNPCs()
    -- Atmospheric glitch
    applyGlitch(0.5)
    flashScreen(Color3.fromRGB(80, 0, 120), 0.3)
end)

DeodorantSpray.OnClientEvent:Connect(function(data: { playerId: number? }?)
    createSprayVFX()

    -- Only the player who actually sprayed figures out which NGMI was hit and
    -- reports it to the server (NGMIController damages + repels it). Without this
    -- the spray did nothing — the server never learned what you sprayed.
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
        dissolveNGMIs()
        task.delay(2, function()
            spawnConfetti()
        end)
    end
end)

-- ============================================================
-- PUBLIC API (for other client scripts to call)
-- ============================================================
local VFXManager = {}
VFXManager.applyGlitch = applyGlitch
VFXManager.flashScreen = flashScreen
VFXManager.applyStaticNoise = applyStaticNoise
VFXManager.createSprayVFX = createSprayVFX

print("[VFXManager] Initialized - atmospheric VFX system ready")
