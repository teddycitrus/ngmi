--!strict
--[[
    NGMIClient.client.luau
    Client-side NGMI enemy visual effects and proximity horror system.
    Handles: proximity screen distortion, NGMI visual FX, death screen, jump scares.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UITheme = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UITheme"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local NGMIStunned = Remotes:WaitForChild("NGMIStunned") :: RemoteEvent
local PlayerDied = Remotes:WaitForChild("PlayerDied") :: RemoteEvent
local PlayerRespawn = Remotes:WaitForChild("PlayerRespawn") :: RemoteEvent
local GameStateChanged = Remotes:WaitForChild("GameStateChanged") :: RemoteEvent

-- Optional: a broken module must never take the proximity horror down with it.
local cinematicOk, cinematicModule = pcall(function()
    return require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CinematicCamera"))
end)
local CinematicCamera = if cinematicOk then cinematicModule else nil

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = workspace.CurrentCamera

-- ============================================================
-- STATE
-- ============================================================
local isNight2 = false
local isDead = false
local nearestNGMIDistance = math.huge
local proximityConnection: RBXScriptConnection? = nil
local jumpScareChance = 0
local lastJumpScareTime = 0

-- ============================================================
-- POST-PROCESSING EFFECTS (reusable)
-- ============================================================
local function getOrCreateEffect(className: string, name: string): Instance
    local existing = Lighting:FindFirstChild(name)
    if existing then return existing end
    local effect = Instance.new(className)
    effect.Name = name
    effect.Parent = Lighting
    return effect
end

-- Vignette overlay (dark edges)
local vignetteGui: ScreenGui? = nil
local vignetteImage: ImageLabel? = nil

local function createVignetteOverlay()
    if vignetteGui then return end

    vignetteGui = Instance.new("ScreenGui")
    vignetteGui.Name = "NGMIVignette"
    vignetteGui.DisplayOrder = 50
    vignetteGui.IgnoreGuiInset = true
    vignetteGui.Parent = playerGui

    vignetteImage = Instance.new("ImageLabel")
    vignetteImage.Name = "Vignette"
    vignetteImage.Size = UDim2.new(1, 0, 1, 0)
    vignetteImage.BackgroundColor3 = Color3.new(0, 0, 0)
    vignetteImage.BackgroundTransparency = 1
    vignetteImage.ImageTransparency = 1
    vignetteImage.Image = "" -- We'll use a gradient frame instead
    vignetteImage.Parent = vignetteGui

    -- Create vignette using gradient frames around edges
    local function createEdge(pos: UDim2, size: UDim2, gradDir: string)
        local edge = Instance.new("Frame")
        edge.Name = "Edge_" .. gradDir
        edge.Position = pos
        edge.Size = size
        edge.BackgroundColor3 = Color3.new(0, 0, 0)
        edge.BackgroundTransparency = 0.3
        edge.BorderSizePixel = 0
        edge.Parent = vignetteImage

        local gradient = Instance.new("UIGradient")
        if gradDir == "left" then
            gradient.Rotation = 0
        elseif gradDir == "right" then
            gradient.Rotation = 180
        elseif gradDir == "top" then
            gradient.Rotation = 90
        elseif gradDir == "bottom" then
            gradient.Rotation = 270
        end
        gradient.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0),
            NumberSequenceKeypoint.new(0.5, 0.8),
            NumberSequenceKeypoint.new(1, 1),
        })
        gradient.Parent = edge
    end

    createEdge(UDim2.new(0, 0, 0, 0), UDim2.new(0.15, 0, 1, 0), "left")
    createEdge(UDim2.new(0.85, 0, 0, 0), UDim2.new(0.15, 0, 1, 0), "right")
    createEdge(UDim2.new(0, 0, 0, 0), UDim2.new(1, 0, 0.1, 0), "top")
    createEdge(UDim2.new(0, 0, 0.9, 0), UDim2.new(1, 0, 0.1, 0), "bottom")
end

local function setVignetteIntensity(intensity: number)
    if not vignetteImage then return end
    for _, child in vignetteImage:GetChildren() do
        if child:IsA("Frame") then
            child.BackgroundTransparency = 1 - (intensity * 0.7)
        end
    end
end

-- ============================================================
-- JUMP SCARE SYSTEM
-- ============================================================
local jumpScareGui: ScreenGui? = nil

-- VFXManager publishes its effect API as BindableEvents parented to its own
-- script (a LocalScript can't be require()d). Resolved lazily and cached so load
-- order between the two scripts doesn't matter, and so a missing VFXManager
-- degrades to "no shake" instead of erroring mid-scare.
local vfxJumpScare: BindableEvent? = nil
local vfxLookedUp = false

local function getVfxJumpScare(): BindableEvent?
    if vfxLookedUp then
        return vfxJumpScare
    end
    vfxLookedUp = true
    local manager = script.Parent and script.Parent:FindFirstChild("VFXManager")
    local bus = manager and manager:FindFirstChild("VFXJumpScare")
    if bus and bus:IsA("BindableEvent") then
        vfxJumpScare = bus
    end
    return vfxJumpScare
end

local function triggerJumpScare()
    if isDead then return end
    if tick() - lastJumpScareTime < 8 then return end -- 8s cooldown
    lastJumpScareTime = tick()

    -- Throw the camera as the face hits. CinematicCamera.jumpscare slams the FOV,
    -- tears the image with chromatic aberration, and fires VFXManager's Perlin
    -- trauma + bloom pulse + static, so the scare is one gesture. Fall back to
    -- the bare VFX bus if the module failed to load.
    if CinematicCamera then
        CinematicCamera.jumpscare(1)
    else
        local bus = getVfxJumpScare()
        if bus then
            bus:Fire(1)
        end
    end

    if jumpScareGui then jumpScareGui:Destroy() end

    jumpScareGui = Instance.new("ScreenGui")
    jumpScareGui.Name = "JumpScare"
    jumpScareGui.DisplayOrder = 200
    jumpScareGui.IgnoreGuiInset = true
    jumpScareGui.Parent = playerGui

    -- Distorted face using text
    local face = Instance.new("TextLabel")
    face.Size = UDim2.new(0.6, 0, 0.6, 0)
    face.Position = UDim2.new(0.2, 0, 0.2, 0)
    face.BackgroundTransparency = 1 -- no ugly box around the eye
    face.TextColor3 = Color3.fromRGB(255, 0, 0)
    face.FontFace = UITheme.Font.Bold
    face.TextSize = 180
    face.Text = "👁️"
    face.TextTransparency = 0
    face.Parent = jumpScareGui

    -- Static overlay
    local static = Instance.new("Frame")
    static.Size = UDim2.new(1, 0, 1, 0)
    static.BackgroundColor3 = Color3.new(1, 1, 1)
    static.BackgroundTransparency = 0.85
    static.Parent = jumpScareGui

    -- Remove after 0.15s
    task.delay(0.15, function()
        if jumpScareGui then
            jumpScareGui:Destroy()
            jumpScareGui = nil
        end
    end)
end

-- ============================================================
-- NGMI VISUAL EFFECTS (on the NGMI models themselves)
-- ============================================================
local function setupNGMIVisuals(ngmi: Model)
    -- Red eye glow - find or create eye parts
    local head = ngmi:FindFirstChild("Head") :: BasePart?
    if not head then return end

    -- Flickering PointLight in eyes
    local eyeLight = Instance.new("PointLight")
    eyeLight.Name = "EyeGlow"
    eyeLight.Color = Color3.fromRGB(255, 0, 0)
    eyeLight.Brightness = 3
    eyeLight.Range = 8
    eyeLight.Parent = head

    -- Corruption particles on torso
    local torso = ngmi:FindFirstChild("Torso") or ngmi:FindFirstChild("UpperTorso")
    if torso and torso:IsA("BasePart") then
        local emitter = Instance.new("ParticleEmitter")
        emitter.Name = "CorruptionTrail"
        emitter.Color = ColorSequence.new({
            ColorSequenceKeypoint.new(0, Color3.fromRGB(80, 20, 120)),
            ColorSequenceKeypoint.new(1, Color3.fromRGB(20, 0, 30)),
        })
        emitter.Size = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.3),
            NumberSequenceKeypoint.new(1, 1.2),
        })
        emitter.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.4),
            NumberSequenceKeypoint.new(0.7, 0.8),
            NumberSequenceKeypoint.new(1, 1),
        })
        emitter.Lifetime = NumberRange.new(1.5, 3)
        emitter.Rate = 12
        emitter.Speed = NumberRange.new(0.5, 2)
        emitter.SpreadAngle = Vector2.new(180, 180)
        emitter.RotSpeed = NumberRange.new(-90, 90)
        emitter.Parent = torso
    end

    -- Flickering eye effect. Body twitching lives in NGMIAnimator, which poses
    -- the Motor6D joints; moving a part's CFrame here would yank the whole
    -- assembly instead.
    task.spawn(function()
        while ngmi.Parent and isNight2 do
            if eyeLight.Parent then
                eyeLight.Brightness = math.random(1, 5)
            end
            task.wait(math.random() * 0.8 + 0.3)
        end
    end)
end

-- Watch for new NGMIs
CollectionService:GetInstanceAddedSignal("NGMI"):Connect(function(instance)
    if instance:IsA("Model") then
        setupNGMIVisuals(instance)
    end
end)

-- Setup existing NGMIs
for _, ngmi in CollectionService:GetTagged("NGMI") do
    if ngmi:IsA("Model") then
        setupNGMIVisuals(ngmi)
    end
end

-- ============================================================
-- PROXIMITY HORROR EFFECTS
-- ============================================================
local colorCorrection: ColorCorrectionEffect? = nil
local blurEffect: BlurEffect? = nil

local function startProximityTracking()
    createVignetteOverlay()

    colorCorrection = getOrCreateEffect("ColorCorrectionEffect", "NGMIProximityCC") :: ColorCorrectionEffect
    blurEffect = getOrCreateEffect("BlurEffect", "NGMIProximityBlur") :: BlurEffect
    blurEffect.Size = 0

    proximityConnection = RunService.Heartbeat:Connect(function()
        if not isNight2 or isDead then return end

        local character = player.Character
        if not character then return end
        local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
        if not rootPart then return end

        local playerPos = rootPart.Position
        nearestNGMIDistance = math.huge

        for _, ngmi in CollectionService:GetTagged("NGMI") do
            if ngmi:IsA("Model") then
                local ngmiRoot = ngmi:FindFirstChild("HumanoidRootPart") or ngmi.PrimaryPart
                if ngmiRoot and ngmiRoot:IsA("BasePart") then
                    local dist = (ngmiRoot.Position - playerPos).Magnitude
                    if dist < nearestNGMIDistance then
                        nearestNGMIDistance = dist
                    end
                end
            end
        end

        -- Apply effects based on distance
        local dist = nearestNGMIDistance

        -- Publish it: HUDController drives its heartbeat vignette off this rather
        -- than running a second CollectionService scan over every NGMI each frame.
        -- Capped rather than math.huge: an infinite attribute value is asking for
        -- trouble at the replication boundary, and "very far" is all readers need.
        player:SetAttribute("NGMIDistance", math.min(dist, 9999))

        if dist < 50 then
            -- Vignette (50-0 studs)
            local vignetteIntensity = math.clamp((50 - dist) / 50, 0, 1)
            setVignetteIntensity(vignetteIntensity)

            -- Color desaturation (30-0 studs)
            if dist < 30 and colorCorrection then
                local desat = math.clamp((30 - dist) / 30, 0, 0.8)
                colorCorrection.Saturation = -desat
                colorCorrection.Contrast = desat * 0.3
            end

            -- Blood-red danger wash that deepens as an NGMI closes in. This is the
            -- ONLY source of red on screen now (Night2's base lighting is neutral),
            -- so the world only turns red when one is near / chasing you.
            if colorCorrection then
                local red = math.clamp((28 - dist) / 28, 0, 1)
                colorCorrection.TintColor = Color3.fromRGB(
                    255,
                    math.floor(255 - red * 130),
                    math.floor(255 - red * 160)
                )
            end

            -- Blur + camera shake (15-0 studs)
            if dist < 15 then
                if blurEffect then
                    local blurIntensity = math.clamp((15 - dist) / 15, 0, 1)
                    blurEffect.Size = blurIntensity * 12
                end

                -- Camera micro-shake
                local shakeIntensity = math.clamp((15 - dist) / 15, 0, 1) * 0.3
                camera.CFrame = camera.CFrame * CFrame.Angles(
                    math.rad(math.random() * shakeIntensity * 2 - shakeIntensity),
                    math.rad(math.random() * shakeIntensity * 2 - shakeIntensity),
                    0
                )
            end

            -- Jump scare risk (8-0 studs, 10% chance per second)
            if dist < 8 then
                jumpScareChance += 0.1 * (1 / 5) -- ~10% per second at 5 checks/sec
                if math.random() < jumpScareChance then
                    triggerJumpScare()
                    jumpScareChance = 0
                end
            else
                jumpScareChance = 0
            end
        else
            -- Reset all effects
            setVignetteIntensity(0)
            if colorCorrection then
                colorCorrection.Saturation = 0
                colorCorrection.Contrast = 0
                colorCorrection.TintColor = Color3.new(1, 1, 1)
            end
            if blurEffect then
                blurEffect.Size = 0
            end
            jumpScareChance = 0
        end
    end)
end

local function stopProximityTracking()
    if proximityConnection then
        proximityConnection:Disconnect()
        proximityConnection = nil
    end

    -- Clean up effects
    setVignetteIntensity(0)
    if colorCorrection then
        colorCorrection.Saturation = 0
        colorCorrection.Contrast = 0
        colorCorrection.TintColor = Color3.new(1, 1, 1)
    end
    if blurEffect then
        blurEffect.Size = 0
    end
    if vignetteGui then
        vignetteGui:Destroy()
        vignetteGui = nil
        vignetteImage = nil
    end
end

-- ============================================================
-- DEATH SCREEN
-- ============================================================
local deathGui: ScreenGui? = nil

local function showDeathScreen()
    isDead = true
    if deathGui then deathGui:Destroy() end

    deathGui = Instance.new("ScreenGui")
    deathGui.Name = "DeathScreen"
    deathGui.DisplayOrder = 300
    deathGui.IgnoreGuiInset = true
    deathGui.Parent = playerGui

    -- Black background
    local bg = Instance.new("Frame")
    bg.Size = UDim2.new(1, 0, 1, 0)
    bg.BackgroundColor3 = Color3.new(0, 0, 0)
    bg.BorderSizePixel = 0
    bg.Parent = deathGui

    -- Error title
    local errorTitle = Instance.new("TextLabel")
    errorTitle.Size = UDim2.new(0.8, 0, 0.08, 0)
    errorTitle.Position = UDim2.new(0.1, 0, 0.25, 0)
    errorTitle.BackgroundTransparency = 1
    errorTitle.FontFace = UITheme.Font.Mono
    errorTitle.TextSize = 36
    errorTitle.TextColor3 = Color3.fromRGB(0, 255, 0)
    errorTitle.Text = "CRITICAL_EXCEPTION: PLAYER_NGMI"
    errorTitle.TextXAlignment = Enum.TextXAlignment.Left
    errorTitle.Parent = bg

    -- Stack trace
    local stackTrace = Instance.new("TextLabel")
    stackTrace.Size = UDim2.new(0.8, 0, 0.2, 0)
    stackTrace.Position = UDim2.new(0.1, 0, 0.35, 0)
    stackTrace.BackgroundTransparency = 1
    stackTrace.FontFace = UITheme.Font.Mono
    stackTrace.TextSize = 20
    stackTrace.TextColor3 = Color3.fromRGB(0, 200, 0)
    stackTrace.TextXAlignment = Enum.TextXAlignment.Left
    stackTrace.TextYAlignment = Enum.TextYAlignment.Top
    stackTrace.Text = table.concat({
        "Stack trace:",
        "  hope.lua:0 - main chunk",
        "  survival.lua:404 - function 'stay_alive'",
        "  hackathon.lua:69 - function 'ship_code'",
        "  life.lua:1 - <error: segmentation fault>",
        "",
        "Process terminated with exit code: NGMI",
    }, "\n")
    stackTrace.Parent = bg

    -- Respawn countdown
    local countdownLabel = Instance.new("TextLabel")
    countdownLabel.Size = UDim2.new(0.8, 0, 0.06, 0)
    countdownLabel.Position = UDim2.new(0.1, 0, 0.6, 0)
    countdownLabel.BackgroundTransparency = 1
    countdownLabel.FontFace = UITheme.Font.Mono
    countdownLabel.TextSize = 24
    countdownLabel.TextColor3 = Color3.fromRGB(255, 50, 50)
    countdownLabel.TextXAlignment = Enum.TextXAlignment.Left
    countdownLabel.Text = "Restarting in 3..."
    countdownLabel.Parent = bg

    -- Countdown animation
    task.spawn(function()
        for i = 3, 1, -1 do
            if countdownLabel.Parent then
                countdownLabel.Text = "Restarting in " .. i .. "..."
            end
            task.wait(1)
        end
        if countdownLabel.Parent then
            countdownLabel.Text = "> Rebooting..."
        end
        task.wait(0.5)
        -- Fade out
        if deathGui then
            local fadeTween = TweenService:Create(bg, TweenInfo.new(1, Enum.EasingStyle.Quad), {
                BackgroundTransparency = 1
            })
            for _, child in bg:GetChildren() do
                if child:IsA("TextLabel") then
                    TweenService:Create(child, TweenInfo.new(1), { TextTransparency = 1 }):Play()
                end
            end
            fadeTween:Play()
            fadeTween.Completed:Wait()
            deathGui:Destroy()
            deathGui = nil
        end
        isDead = false
    end)
end

-- ============================================================
-- NGMI STUN VISUAL EFFECT
-- ============================================================
NGMIStunned.OnClientEvent:Connect(function(ngmiModel: Model)
    if not ngmiModel or not ngmiModel.Parent then return end

    -- Stun particles burst
    local torso = ngmiModel:FindFirstChild("Torso") or ngmiModel:FindFirstChild("UpperTorso")
    if torso and torso:IsA("BasePart") then
        local stunBurst = Instance.new("ParticleEmitter")
        stunBurst.Name = "StunBurst"
        stunBurst.Color = ColorSequence.new(Color3.fromRGB(200, 255, 200))
        stunBurst.Size = NumberSequence.new({
            NumberSequenceKeypoint.new(0, 0.5),
            NumberSequenceKeypoint.new(1, 0),
        })
        stunBurst.Lifetime = NumberRange.new(0.5, 1)
        stunBurst.Rate = 50
        stunBurst.Speed = NumberRange.new(3, 8)
        stunBurst.SpreadAngle = Vector2.new(180, 180)
        stunBurst.Parent = torso

        -- Disable corruption trail temporarily
        local corruptionTrail = torso:FindFirstChild("CorruptionTrail")
        if corruptionTrail and corruptionTrail:IsA("ParticleEmitter") then
            corruptionTrail.Enabled = false
        end

        -- Overhead stun text
        local head = ngmiModel:FindFirstChild("Head") :: BasePart?
        if head then
            local billboard = Instance.new("BillboardGui")
            billboard.Name = "StunText"
            billboard.Size = UDim2.new(6, 0, 2, 0)
            billboard.StudsOffset = Vector3.new(0, 4, 0)
            billboard.Adornee = head
            billboard.Parent = head

            local stunLabel = Instance.new("TextLabel")
            stunLabel.Size = UDim2.new(1, 0, 1, 0)
            stunLabel.BackgroundTransparency = 1
            stunLabel.FontFace = UITheme.Font.Bold
            stunLabel.TextSize = 24
            stunLabel.TextColor3 = Color3.fromRGB(150, 255, 150)
            stunLabel.TextStrokeTransparency = 0.5
            stunLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
            stunLabel.Text = "*cough* Is that... hygiene?!"
            stunLabel.Parent = billboard
        end

        -- Clean up after stun duration
        task.delay(3, function()
            if stunBurst.Parent then stunBurst:Destroy() end
            if corruptionTrail and corruptionTrail.Parent then
                corruptionTrail.Enabled = true
            end
            local stunText = head and head:FindFirstChild("StunText")
            if stunText then stunText:Destroy() end
        end)
    end
end)

-- ============================================================
-- EVENT LISTENERS
-- ============================================================
PlayerDied.OnClientEvent:Connect(function()
    showDeathScreen()
end)

PlayerRespawn.OnClientEvent:Connect(function()
    isDead = false
end)

GameStateChanged.OnClientEvent:Connect(function(data: { phase: number })
    if data.phase == 3 then -- NIGHT2
        isNight2 = true
        startProximityTracking()
    else
        isNight2 = false
        stopProximityTracking()
    end
end)

print("[NGMIClient] Initialized - proximity horror effects ready")
