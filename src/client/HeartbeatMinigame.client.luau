--!strict
--[[
    HeartbeatMinigame.client.luau
    Rhythm-based hiding mini-game. Player must press in sync with heartbeat
    while hiding from NGMIs. Failure alerts enemies.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UITheme = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UITheme"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local HidingStateChanged = Remotes:WaitForChild("HidingStateChanged") :: RemoteEvent
local GameStateChanged = Remotes:WaitForChild("GameStateChanged") :: RemoteEvent

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ============================================================
-- CONFIGURATION
-- ============================================================
local BPM_RANGES = {
    { distance = 20, bpm = 70 },
    { distance = 15, bpm = 90 },
    { distance = 10, bpm = 110 },
    { distance = 5, bpm = 140 },
    { distance = 0, bpm = 170 },
}

local TIMING_WINDOW = 0.200 -- ±200ms
local MAX_MISSES = 3
local SAFE_DISTANCE = 30 -- NGMI must be > 30 studs to end

-- ============================================================
-- STATE
-- ============================================================
local isNight2 = false
local isHiding = false
local isActive = false
local currentBPM = 70
local missCount = 0
local lastBeatTime = 0
local beatInterval = 60 / 70
local canPress = false
local pressedThisBeat = false

local minigameGui: ScreenGui? = nil
local heartLabel: TextLabel? = nil
local timingRing: Frame? = nil
local missIndicator: TextLabel? = nil
local safeLabel: TextLabel? = nil
local updateConnection: RBXScriptConnection? = nil

-- ============================================================
-- NEAREST NGMI DISTANCE
-- ============================================================
local function getNearestNGMIDistance(): number
    local character = player.Character
    if not character then return math.huge end
    local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
    if not rootPart then return math.huge end

    local playerPos = rootPart.Position
    local nearest = math.huge

    for _, ngmi in CollectionService:GetTagged("NGMI") do
        if ngmi:IsA("Model") then
            local ngmiRoot = ngmi:FindFirstChild("HumanoidRootPart") or ngmi.PrimaryPart
            if ngmiRoot and ngmiRoot:IsA("BasePart") then
                local dist = (ngmiRoot.Position - playerPos).Magnitude
                if dist < nearest then nearest = dist end
            end
        end
    end

    return nearest
end

-- ============================================================
-- BPM CALCULATION
-- ============================================================
local function calculateBPM(distance: number): number
    for i = #BPM_RANGES, 1, -1 do
        if distance <= BPM_RANGES[i].distance then
            if i < #BPM_RANGES then
                -- Interpolate between ranges
                local upper = BPM_RANGES[i]
                local lower = BPM_RANGES[i + 1]
                local t = (distance - upper.distance) / (lower.distance - upper.distance)
                return math.floor(upper.bpm + t * (lower.bpm - upper.bpm))
            end
            return BPM_RANGES[i].bpm
        end
    end
    return BPM_RANGES[1].bpm
end

-- ============================================================
-- UI CREATION
-- ============================================================
local function createMinigameUI()
    if minigameGui then minigameGui:Destroy() end

    minigameGui = Instance.new("ScreenGui")
    minigameGui.Name = "HeartbeatMinigame"
    minigameGui.DisplayOrder = 100
    minigameGui.IgnoreGuiInset = true
    minigameGui.Parent = playerGui

    -- Dark overlay
    local overlay = Instance.new("Frame")
    overlay.Name = "Overlay"
    overlay.Size = UDim2.new(1, 0, 1, 0)
    overlay.BackgroundColor3 = Color3.new(0, 0, 0)
    overlay.BackgroundTransparency = 0.6
    overlay.BorderSizePixel = 0
    overlay.Parent = minigameGui

    -- Center container
    local center = Instance.new("Frame")
    center.Name = "Center"
    center.Size = UDim2.new(0, 200, 0, 200)
    center.Position = UDim2.new(0.5, -100, 0.45, -100)
    center.BackgroundTransparency = 1
    center.Parent = minigameGui

    -- Timing ring (green circle that pulses with the beat)
    timingRing = Instance.new("Frame")
    timingRing.Name = "TimingRing"
    timingRing.Size = UDim2.new(0, 160, 0, 160)
    timingRing.Position = UDim2.new(0.5, -80, 0.5, -80)
    timingRing.BackgroundTransparency = 1
    timingRing.Parent = center

    local ringCorner = Instance.new("UICorner")
    ringCorner.CornerRadius = UDim.new(0.5, 0)
    ringCorner.Parent = timingRing

    local ringStroke = Instance.new("UIStroke")
    ringStroke.Name = "RingStroke"
    ringStroke.Color = Color3.fromRGB(50, 200, 50)
    ringStroke.Thickness = 4
    ringStroke.Transparency = 0.5
    ringStroke.Parent = timingRing

    -- Heart emoji
    heartLabel = Instance.new("TextLabel")
    heartLabel.Name = "Heart"
    heartLabel.Size = UDim2.new(0, 120, 0, 120)
    heartLabel.Position = UDim2.new(0.5, -60, 0.5, -60)
    heartLabel.BackgroundTransparency = 1
    heartLabel.Text = "❤️"
    heartLabel.TextSize = 72
    heartLabel.FontFace = UITheme.Font.Bold
    heartLabel.TextColor3 = Color3.fromRGB(255, 50, 50)
    heartLabel.Parent = center

    -- Instruction text
    local instruction = Instance.new("TextLabel")
    instruction.Name = "Instruction"
    instruction.Size = UDim2.new(0, 300, 0, 30)
    instruction.Position = UDim2.new(0.5, -150, 0.75, 0)
    instruction.BackgroundTransparency = 1
    instruction.Text = "Press SPACE in rhythm with the heartbeat"
    instruction.TextSize = 16
    instruction.FontFace = UITheme.Font.Regular
    instruction.TextColor3 = Color3.fromRGB(200, 200, 200)
    instruction.Parent = minigameGui

    -- Mobile: add large tap target
    if UserInputService.TouchEnabled then
        instruction.Text = "TAP in rhythm with the heartbeat"

        local tapZone = Instance.new("TextButton")
        tapZone.Name = "TapZone"
        tapZone.Size = UDim2.new(1, 0, 0.5, 0)
        tapZone.Position = UDim2.new(0, 0, 0.5, 0)
        tapZone.BackgroundTransparency = 0.95
        tapZone.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
        tapZone.Text = ""
        tapZone.Parent = minigameGui

        tapZone.Activated:Connect(function()
            handlePress()
        end)
    end

    -- Miss indicators
    missIndicator = Instance.new("TextLabel")
    missIndicator.Name = "MissIndicator"
    missIndicator.Size = UDim2.new(0, 200, 0, 30)
    missIndicator.Position = UDim2.new(0.5, -100, 0.35, 0)
    missIndicator.BackgroundTransparency = 1
    missIndicator.Text = ""
    missIndicator.TextSize = 24
    missIndicator.FontFace = UITheme.Font.Bold
    missIndicator.TextColor3 = Color3.fromRGB(255, 200, 50)
    missIndicator.Parent = minigameGui

    -- "Safe..." label (shown when NGMI leaves)
    safeLabel = Instance.new("TextLabel")
    safeLabel.Name = "SafeLabel"
    safeLabel.Size = UDim2.new(0, 300, 0, 60)
    safeLabel.Position = UDim2.new(0.5, -150, 0.2, 0)
    safeLabel.BackgroundTransparency = 1
    safeLabel.Text = ""
    safeLabel.TextSize = 36
    safeLabel.FontFace = UITheme.Font.Bold
    safeLabel.TextColor3 = Color3.fromRGB(100, 255, 100)
    safeLabel.TextTransparency = 1
    safeLabel.Parent = minigameGui
end

-- Forward declarations: these are defined below but referenced by the beat
-- handlers created above them.
local registerMiss: () -> ()
local playerDiscovered: () -> ()

-- ============================================================
-- BEAT PULSE ANIMATION
-- ============================================================
local function pulseBeat()
    if not heartLabel then return end

    -- Scale up heart
    local scaleUp = TweenService:Create(heartLabel, TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        TextSize = 90,
    })
    scaleUp:Play()

    -- Flash timing ring
    if timingRing then
        local stroke = timingRing:FindFirstChild("RingStroke") :: UIStroke?
        if stroke then
            stroke.Transparency = 0
            stroke.Color = Color3.fromRGB(100, 255, 100)
            TweenService:Create(stroke, TweenInfo.new(0.3), {
                Transparency = 0.7,
                Color = Color3.fromRGB(50, 200, 50),
            }):Play()
        end
    end

    -- Scale back down
    task.delay(0.15, function()
        if heartLabel and heartLabel.Parent then
            TweenService:Create(heartLabel, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
                TextSize = 72,
            }):Play()
        end
    end)

    -- Mark beat timing
    lastBeatTime = tick()
    canPress = true
    pressedThisBeat = false

    -- Window closes after TIMING_WINDOW
    task.delay(TIMING_WINDOW * 2, function()
        if not pressedThisBeat and isActive then
            -- Missed this beat
            registerMiss()
        end
        canPress = false
    end)
end

-- ============================================================
-- HIT / MISS LOGIC
-- ============================================================
local function registerHit()
    if not timingRing then return end

    -- Green flash feedback
    local stroke = timingRing:FindFirstChild("RingStroke") :: UIStroke?
    if stroke then
        stroke.Color = Color3.fromRGB(0, 255, 100)
        stroke.Thickness = 6
        TweenService:Create(stroke, TweenInfo.new(0.3), {
            Color = Color3.fromRGB(50, 200, 50),
            Thickness = 4,
        }):Play()
    end
end

function registerMiss()
    missCount += 1

    -- Update miss indicators
    if missIndicator then
        local warnings = string.rep("⚠️ ", missCount)
        missIndicator.Text = warnings
        missIndicator.TextColor3 = Color3.fromRGB(255, math.max(0, 200 - missCount * 80), 50)
    end

    -- Red flash
    if heartLabel then
        heartLabel.TextColor3 = Color3.fromRGB(255, 255, 0)
        TweenService:Create(heartLabel, TweenInfo.new(0.3), {
            TextColor3 = Color3.fromRGB(255, 50, 50),
        }):Play()
    end

    -- Screen red flash
    if minigameGui then
        local flash = Instance.new("Frame")
        flash.Size = UDim2.new(1, 0, 1, 0)
        flash.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
        flash.BackgroundTransparency = 0.7
        flash.BorderSizePixel = 0
        flash.Parent = minigameGui

        TweenService:Create(flash, TweenInfo.new(0.3), {
            BackgroundTransparency = 1,
        }):Play()

        task.delay(0.3, function()
            if flash.Parent then flash:Destroy() end
        end)
    end

    -- Check for discovery
    if missCount >= MAX_MISSES then
        playerDiscovered()
    end
end

function handlePress()
    if not isActive or not canPress or pressedThisBeat then return end
    pressedThisBeat = true

    local timeSinceBeat = math.abs(tick() - lastBeatTime)

    if timeSinceBeat <= TIMING_WINDOW then
        registerHit()
    else
        registerMiss()
    end
end

function playerDiscovered()
    isActive = false

    -- Alert text
    if minigameGui then
        local alertText = Instance.new("TextLabel")
        alertText.Size = UDim2.new(0.6, 0, 0.1, 0)
        alertText.Position = UDim2.new(0.2, 0, 0.15, 0)
        alertText.BackgroundTransparency = 1
        alertText.Text = "⚠️ DISCOVERED! ⚠️"
        alertText.TextSize = 42
        alertText.FontFace = UITheme.Font.Bold
        alertText.TextColor3 = Color3.fromRGB(255, 50, 50)
        alertText.Parent = minigameGui
    end

    -- Tell server player was discovered
    HidingStateChanged:FireServer({ hiding = false, discovered = true })

    -- Close after delay
    task.delay(1.5, function()
        stopMinigame()
    end)
end

-- ============================================================
-- MINIGAME LOOP
-- ============================================================
local function startMinigame()
    if isActive then return end
    isActive = true
    missCount = 0

    createMinigameUI()

    local beatAccum = 0

    updateConnection = RunService.Heartbeat:Connect(function(dt: number)
        if not isActive then return end

        -- Update BPM based on NGMI distance
        local dist = getNearestNGMIDistance()
        currentBPM = calculateBPM(dist)
        beatInterval = 60 / currentBPM

        -- Check if NGMIs left
        if dist > SAFE_DISTANCE then
            -- Safe!
            if safeLabel then
                safeLabel.Text = "Safe..."
                TweenService:Create(safeLabel, TweenInfo.new(0.5), {
                    TextTransparency = 0,
                }):Play()
            end

            task.delay(1.5, function()
                if isActive then
                    HidingStateChanged:FireServer({ hiding = false, discovered = false })
                    stopMinigame()
                end
            end)
            return
        end

        -- Beat timing
        beatAccum += dt
        if beatAccum >= beatInterval then
            beatAccum = 0
            pulseBeat()
        end
    end)
end

function stopMinigame()
    isActive = false
    isHiding = false

    if updateConnection then
        updateConnection:Disconnect()
        updateConnection = nil
    end

    if minigameGui then
        -- Fade out
        for _, child in minigameGui:GetChildren() do
            if child:IsA("Frame") then
                TweenService:Create(child, TweenInfo.new(0.5), {
                    BackgroundTransparency = 1,
                }):Play()
            elseif child:IsA("TextLabel") then
                TweenService:Create(child, TweenInfo.new(0.5), {
                    TextTransparency = 1,
                }):Play()
            end
        end

        task.delay(0.6, function()
            if minigameGui then
                minigameGui:Destroy()
                minigameGui = nil
            end
        end)
    end
end

-- ============================================================
-- INPUT
-- ============================================================
UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
    if gameProcessed then return end
    if input.KeyCode == Enum.KeyCode.Space and isActive then
        handlePress()
    end
end)

-- ============================================================
-- EVENT LISTENERS
-- ============================================================
HidingStateChanged.OnClientEvent:Connect(function(data: { hiding: boolean, ngmiNearby: boolean? })
    if data.hiding and (data.ngmiNearby == nil or data.ngmiNearby) then
        isHiding = true
        local dist = getNearestNGMIDistance()
        if dist <= SAFE_DISTANCE then
            startMinigame()
        end
    elseif not data.hiding then
        stopMinigame()
    end
end)

GameStateChanged.OnClientEvent:Connect(function(data: { phase: number })
    if data.phase ~= 3 then -- Not Night2
        stopMinigame()
        isNight2 = false
    else
        isNight2 = true
    end
end)

print("[HeartbeatMinigame] Initialized - rhythm-based hiding system ready")
