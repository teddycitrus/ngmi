--!strict
--[[
    HUDController.client.luau
    Master HUD managing all persistent on-screen elements:
    - Clock display, health bar, project meter, phase banner
    - Mobile controls (touch joystick placeholder)
    - Phase-aware visibility management
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local Lighting = game:GetService("Lighting")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local GameStateChanged = Remotes:WaitForChild("GameStateChanged") :: RemoteEvent
local PhaseTimerSync = Remotes:WaitForChild("PhaseTimerSync") :: RemoteEvent
local PlayerDamaged = Remotes:WaitForChild("PlayerDamaged") :: RemoteEvent
local CodingProgress = Remotes:WaitForChild("CodingProgress") :: RemoteEvent

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local isMobile = UserInputService.TouchEnabled

-- ============================================================
-- PHASE NAMES
-- ============================================================
local PHASE_NAMES = {
    [0] = { text = "LOBBY", color = Color3.fromRGB(100, 100, 150) },
    [1] = { text = "DAY 1: FRIDAY NIGHT", color = Color3.fromRGB(100, 200, 255) },
    [2] = { text = "DAY 2: THE GRIND", color = Color3.fromRGB(255, 200, 100) },
    [3] = { text = "NIGHT 2: SURVIVE", color = Color3.fromRGB(255, 50, 50) },
    [4] = { text = "DAY 3: JUDGEMENT DAY", color = Color3.fromRGB(255, 220, 100) },
}

-- ============================================================
-- STATE
-- ============================================================
local currentPhase = 0
local currentHealth = 100
local maxHealth = 100
local projectCompletion = 0

-- ============================================================
-- HUD GUI CREATION
-- ============================================================
local hudGui = Instance.new("ScreenGui")
hudGui.Name = "MainHUD"
hudGui.DisplayOrder = 10
hudGui.ResetOnSpawn = false
hudGui.IgnoreGuiInset = true
hudGui.Parent = playerGui

-- -----------------------------------------------------------
-- CLOCK DISPLAY (top center)
-- -----------------------------------------------------------
local clockFrame = Instance.new("Frame")
clockFrame.Name = "ClockFrame"
clockFrame.Size = UDim2.new(0, 220, 0, 50)
clockFrame.Position = UDim2.new(0.5, -110, 0, 8)
clockFrame.BackgroundColor3 = Color3.fromRGB(15, 18, 25)
clockFrame.BackgroundTransparency = 0.2
clockFrame.BorderSizePixel = 0
clockFrame.Parent = hudGui

local clockCorner = Instance.new("UICorner")
clockCorner.CornerRadius = UDim.new(0, 10)
clockCorner.Parent = clockFrame

local clockStroke = Instance.new("UIStroke")
clockStroke.Color = Color3.fromRGB(50, 55, 70)
clockStroke.Thickness = 1
clockStroke.Parent = clockFrame

-- Day label
local dayLabel = Instance.new("TextLabel")
dayLabel.Name = "DayLabel"
dayLabel.Size = UDim2.new(1, 0, 0, 18)
dayLabel.Position = UDim2.new(0, 0, 0, 4)
dayLabel.BackgroundTransparency = 1
dayLabel.Text = "Day 1"
dayLabel.TextSize = 12
dayLabel.Font = Enum.Font.GothamBold
dayLabel.TextColor3 = Color3.fromRGB(150, 160, 200)
dayLabel.Parent = clockFrame

-- Time label
local timeLabel = Instance.new("TextLabel")
timeLabel.Name = "TimeLabel"
timeLabel.Size = UDim2.new(1, 0, 0, 28)
timeLabel.Position = UDim2.new(0, 0, 0, 20)
timeLabel.BackgroundTransparency = 1
timeLabel.Text = "6:00 PM"
timeLabel.TextSize = 22
timeLabel.Font = Enum.Font.Code
timeLabel.TextColor3 = Color3.new(1, 1, 1)
timeLabel.Parent = clockFrame

-- -----------------------------------------------------------
-- HEALTH: we use Roblox's DEFAULT health bar (bottom of screen) now, plus a
-- screen damage effect (desaturation + blood vignette) built further below.
-- The old custom top-left bar has been removed.
-- -----------------------------------------------------------
StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, true)

-- -----------------------------------------------------------
-- PROJECT METER (below health)
-- -----------------------------------------------------------
local projectFrame = Instance.new("Frame")
projectFrame.Name = "ProjectFrame"
projectFrame.Size = UDim2.new(0, 200, 0, 28)
projectFrame.Position = UDim2.new(0, 16, 0, 16)
projectFrame.BackgroundColor3 = Color3.fromRGB(10, 20, 15)
projectFrame.BackgroundTransparency = 0.2
projectFrame.BorderSizePixel = 0
projectFrame.Visible = false
projectFrame.Parent = hudGui

local projectCorner = Instance.new("UICorner")
projectCorner.CornerRadius = UDim.new(0, 6)
projectCorner.Parent = projectFrame

local projectStroke = Instance.new("UIStroke")
projectStroke.Color = Color3.fromRGB(30, 80, 40)
projectStroke.Thickness = 1
projectStroke.Parent = projectFrame

local projectIcon = Instance.new("TextLabel")
projectIcon.Size = UDim2.new(0, 24, 1, 0)
projectIcon.Position = UDim2.new(0, 4, 0, 0)
projectIcon.BackgroundTransparency = 1
projectIcon.Text = "💻"
projectIcon.TextSize = 16
projectIcon.Parent = projectFrame

local projectBarBG = Instance.new("Frame")
projectBarBG.Size = UDim2.new(1, -60, 0, 14)
projectBarBG.Position = UDim2.new(0, 30, 0.5, -7)
projectBarBG.BackgroundColor3 = Color3.fromRGB(15, 30, 20)
projectBarBG.BorderSizePixel = 0
projectBarBG.Parent = projectFrame

local projectBarBGCorner = Instance.new("UICorner")
projectBarBGCorner.CornerRadius = UDim.new(0, 4)
projectBarBGCorner.Parent = projectBarBG

local projectFill = Instance.new("Frame")
projectFill.Name = "ProjectFill"
projectFill.Size = UDim2.new(0, 0, 1, 0)
projectFill.BackgroundColor3 = Color3.fromRGB(50, 200, 100)
projectFill.BorderSizePixel = 0
projectFill.Parent = projectBarBG

local projectFillCorner = Instance.new("UICorner")
projectFillCorner.CornerRadius = UDim.new(0, 4)
projectFillCorner.Parent = projectFill

local projectFillGradient = Instance.new("UIGradient")
projectFillGradient.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(80, 255, 130)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(30, 150, 70)),
})
projectFillGradient.Parent = projectFill

local pctText = Instance.new("TextLabel")
pctText.Name = "PctText"
pctText.Size = UDim2.new(0, 30, 1, 0)
pctText.Position = UDim2.new(1, -30, 0, 0)
pctText.BackgroundTransparency = 1
pctText.Text = "0%"
pctText.TextSize = 12
pctText.Font = Enum.Font.Code
pctText.TextColor3 = Color3.new(1, 1, 1)
pctText.Parent = projectFrame

-- -----------------------------------------------------------
-- PHASE BANNER (center screen, temporary)
-- -----------------------------------------------------------
local bannerLabel = Instance.new("TextLabel")
bannerLabel.Name = "PhaseBanner"
bannerLabel.Size = UDim2.new(0.6, 0, 0, 60)
bannerLabel.Position = UDim2.new(0.2, 0, 0.35, 0)
bannerLabel.BackgroundTransparency = 1
bannerLabel.Text = ""
bannerLabel.TextSize = 40
bannerLabel.Font = Enum.Font.GothamBold
bannerLabel.TextColor3 = Color3.new(1, 1, 1)
bannerLabel.TextStrokeTransparency = 0.3
bannerLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
bannerLabel.TextTransparency = 1
bannerLabel.Parent = hudGui

-- -----------------------------------------------------------
-- MOBILE CONTROLS HINT
-- -----------------------------------------------------------
if isMobile then
    local mobileHint = Instance.new("TextLabel")
    mobileHint.Size = UDim2.new(0, 200, 0, 30)
    mobileHint.Position = UDim2.new(0.5, -100, 1, -40)
    mobileHint.BackgroundTransparency = 1
    mobileHint.Text = "Use on-screen controls to move"
    mobileHint.TextSize = 12
    mobileHint.Font = Enum.Font.Gotham
    mobileHint.TextColor3 = Color3.fromRGB(150, 150, 150)
    mobileHint.Parent = hudGui
end

-- ============================================================
-- UPDATE FUNCTIONS
-- ============================================================
-- Health is shown by Roblox's default bar; the on-screen damage feedback is
-- handled by the desaturation + blood-vignette system in DAMAGE EFFECTS below.

local function updateProjectMeter()
    local pct = math.clamp(projectCompletion / 100, 0, 1)
    TweenService:Create(projectFill, TweenInfo.new(0.5, Enum.EasingStyle.Quad), {
        Size = UDim2.new(pct, 0, 1, 0),
    }):Play()
    pctText.Text = math.floor(projectCompletion) .. "%"

    if projectCompletion >= 100 then
        projectFill.BackgroundColor3 = Color3.fromRGB(100, 255, 100)
        pctText.TextColor3 = Color3.fromRGB(100, 255, 100)
    end
end

local function showPhaseBanner(phase: number)
    local phaseData = PHASE_NAMES[phase]
    if not phaseData then return end

    bannerLabel.Text = phaseData.text
    bannerLabel.TextColor3 = phaseData.color

    -- Fade in
    TweenService:Create(bannerLabel, TweenInfo.new(0.5), {
        TextTransparency = 0,
    }):Play()

    -- Hold for 3 seconds, then fade out
    task.delay(3, function()
        TweenService:Create(bannerLabel, TweenInfo.new(1), {
            TextTransparency = 1,
        }):Play()
    end)
end

local function updateVisibility(phase: number)
    -- LOBBY (0) and the DAY3 cutscene (4) hide the HUD; the play phases show it.
    local inPlay = (phase == 1 or phase == 2 or phase == 3)
    clockFrame.Visible = inPlay
    projectFrame.Visible = inPlay
    if inPlay then
        projectFrame.Position = UDim2.new(0, 16, 0, 16)
    end
end

-- ============================================================
-- EVENT LISTENERS
-- ============================================================
GameStateChanged.OnClientEvent:Connect(function(data: { phase: number })
    currentPhase = data.phase
    updateVisibility(currentPhase)
    showPhaseBanner(currentPhase)
end)

PhaseTimerSync.OnClientEvent:Connect(function(data: { phase: number, timeRemaining: number, gameClockTime: number })
    -- Update clock display
    local clockTime = data.gameClockTime
    local hours = math.floor(clockTime)
    local minutes = math.floor((clockTime - hours) * 60)

    local ampm = if hours >= 12 then "PM" else "AM"
    local displayHour = hours % 12
    if displayHour == 0 then displayHour = 12 end

    timeLabel.Text = string.format("%d:%02d %s", displayHour, minutes, ampm)

    -- Update day label
    local dayNames = {
        [1] = "Friday",
        [2] = "Saturday",
        [3] = "Saturday Night",
        [4] = "Sunday",
    }
    dayLabel.Text = dayNames[data.phase] or ""

    -- Night mode clock color
    if data.phase == 3 then
        timeLabel.TextColor3 = Color3.fromRGB(255, 100, 100)
        dayLabel.TextColor3 = Color3.fromRGB(255, 80, 80)
        clockStroke.Color = Color3.fromRGB(100, 30, 30)
    else
        timeLabel.TextColor3 = Color3.new(1, 1, 1)
        dayLabel.TextColor3 = Color3.fromRGB(150, 160, 200)
        clockStroke.Color = Color3.fromRGB(50, 55, 70)
    end
end)

PlayerDamaged.OnClientEvent:Connect(function(data: { health: number? , damage: number? })
    if data.health then
        currentHealth = data.health
    elseif data.damage then
        currentHealth = math.max(0, currentHealth - data.damage)
    end

    -- Damage flash
    local flash = Instance.new("Frame")
    flash.Size = UDim2.new(1, 0, 1, 0)
    flash.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
    flash.BackgroundTransparency = 0.7
    flash.BorderSizePixel = 0
    flash.ZIndex = 100
    flash.Parent = hudGui

    TweenService:Create(flash, TweenInfo.new(0.3), {
        BackgroundTransparency = 1,
    }):Play()

    task.delay(0.35, function()
        if flash.Parent then flash:Destroy() end
    end)
end)

CodingProgress.OnClientEvent:Connect(function(data: { completion: number?, blocked: boolean? })
    -- CodingProgress is also used for desk start/stop control signals (which carry
    -- no completion) — ignore those here and only react to real progress updates.
    if type(data) ~= "table" or data.completion == nil then return end
    projectCompletion = data.completion
    updateProjectMeter()
end)

-- ============================================================
-- DAMAGE EFFECTS — desaturation + blood vignette tied to health
-- ============================================================
-- World desaturates / dims as you get hurt.
local damageCC = Instance.new("ColorCorrectionEffect")
damageCC.Name = "DamageColorCorrection"
damageCC.Saturation = 0
damageCC.Brightness = 0
damageCC.Contrast = 0
damageCC.Parent = Lighting

-- Red "blood" stains creeping in from every edge, kept in a CanvasGroup so the
-- whole effect fades in/out as one piece via GroupTransparency.
local overlayGui = Instance.new("ScreenGui")
overlayGui.Name = "DamageOverlay"
overlayGui.IgnoreGuiInset = true
overlayGui.DisplayOrder = 50
overlayGui.ResetOnSpawn = false
overlayGui.Parent = playerGui

-- NOTE: we do NOT use a CanvasGroup here. CanvasGroup.GroupTransparency = 1 did
-- not reliably hide its children, so the blood frames showed even at full health.
-- Instead each edge frame is a direct child whose own BackgroundTransparency we
-- drive to 1 (fully invisible) when unharmed.
local BLOOD = Color3.fromRGB(95, 0, 0)
local bloodFrames: { Frame } = {}
local function bloodEdge(name: string, size: UDim2, pos: UDim2, anchor: Vector2, rotation: number, reversed: boolean)
    local f = Instance.new("Frame")
    f.Name = name
    f.Size = size
    f.Position = pos
    f.AnchorPoint = anchor
    f.BackgroundColor3 = BLOOD
    f.BackgroundTransparency = 1 -- hidden until wounded
    f.BorderSizePixel = 0
    f.Parent = overlayGui
    local g = Instance.new("UIGradient")
    g.Rotation = rotation
    local a, b = 0, 1 -- opaque at the screen edge, clear toward the centre
    if reversed then
        a, b = 1, 0
    end
    g.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, a),
        NumberSequenceKeypoint.new(1, b),
    })
    g.Parent = f
    table.insert(bloodFrames, f)
end
bloodEdge("Top", UDim2.new(1, 0, 0.42, 0), UDim2.new(0, 0, 0, 0), Vector2.new(0, 0), 90, false)
bloodEdge("Bottom", UDim2.new(1, 0, 0.42, 0), UDim2.new(0, 0, 1, 0), Vector2.new(0, 1), 90, true)
bloodEdge("Left", UDim2.new(0.42, 0, 1, 0), UDim2.new(0, 0, 0, 0), Vector2.new(0, 0), 0, false)
bloodEdge("Right", UDim2.new(0.42, 0, 1, 0), UDim2.new(1, 0, 0, 0), Vector2.new(1, 0), 0, true)

local effectIntensity = 0 -- 0 healthy → 1 near death (smoothed)

local function readHealthPct(): number?
    local char = player.Character
    if not char then return nil end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then return nil end
    -- A loading/respawning/dead character momentarily reads Health 0; don't blast
    -- the screen red for that (death is handled by the death screen). Treat it as
    -- "no effect" so the vignette never appears unless you're actually wounded.
    if hum.Health <= 0 then return nil end
    return math.clamp(hum.Health / math.max(1, hum.MaxHealth), 0, 1)
end

RunService.RenderStepped:Connect(function(dt: number)
    local pct = readHealthPct()
    local target = 0
    -- Only during the combat days (Day 2 + Night 2) — Day 1 is the intro, no damage.
    if pct ~= nil and currentPhase >= 2 and currentPhase <= 3 then
        target = 1 - pct
    end
    -- ease toward target both ways, so it thickens as you're hurt and clears as you heal
    effectIntensity += (target - effectIntensity) * math.clamp(dt * 3, 0, 1)
    local i = effectIntensity
    damageCC.Saturation = -0.8 * i
    damageCC.Brightness = -0.04 * i
    damageCC.Contrast = 0.08 * i
    -- Drive each edge frame's own transparency: 1 (invisible) when healthy →
    -- ~0.18 (strong red) near death. Combined with the gradient this fades the
    -- blood from the screen edge toward a clear centre.
    local frameTransparency = 1 - math.clamp(i * 0.82, 0, 0.82)
    for _, f in bloodFrames do
        f.BackgroundTransparency = frameTransparency
    end
end)

-- ============================================================
-- DEATH → GAME OVER + Return to Lobby (mirrors the ending screens)
-- ============================================================
local deathGuiShown = false
local function showDeathScreen()
    if deathGuiShown then return end
    deathGuiShown = true

    -- Free the cursor so the "Return to Lobby" button is clickable — gameplay runs
    -- in LockFirstPerson, which pins the mouse to screen-centre and hides it. Just
    -- switching to Classic isn't enough: the camera is pinned at first-person zoom
    -- (0.5), and at that zoom the mouse re-locks regardless — so widen the zoom to
    -- pull the camera out to third person, which actually frees the cursor.
    player.CameraMode = Enum.CameraMode.Classic
    player.CameraMinZoomDistance = 10
    player.CameraMaxZoomDistance = 16
    UserInputService.MouseBehavior = Enum.MouseBehavior.Default
    UserInputService.MouseIconEnabled = true

    -- Tailor the message to what killed the player (set server-side as a
    -- DeathCause attribute on the hit that downed them).
    local cause = player:GetAttribute("DeathCause")
    local titleText, subText = "YOU DIED", "Your repo dies with you."
    if cause == "poop" then
        titleText = "FLUSHED"
        subText = "The Bathroom Monster dragged you under. You and your commits, straight down the drain."
    elseif cause == "ngmi" then
        titleText = "CAUGHT"
        subText = "An NGMI sank its claws in. Your half-built repo dies with you."
    end

    local gui = Instance.new("ScreenGui")
    gui.Name = "DeathScreen"
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 600
    gui.ResetOnSpawn = false
    gui.Parent = playerGui

    local bg = Instance.new("Frame")
    bg.Size = UDim2.new(1, 0, 1, 0)
    bg.BackgroundColor3 = Color3.fromRGB(8, 0, 0)
    bg.BackgroundTransparency = 1
    bg.BorderSizePixel = 0
    bg.Parent = gui
    TweenService:Create(bg, TweenInfo.new(1.2), { BackgroundTransparency = 0.05 }):Play()

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(0.8, 0, 0.16, 0)
    title.Position = UDim2.new(0.1, 0, 0.28, 0)
    title.BackgroundTransparency = 1
    title.Text = titleText
    title.Font = Enum.Font.Creepster
    title.TextScaled = true
    title.TextColor3 = Color3.fromRGB(205, 20, 20)
    title.TextStrokeTransparency = 0.5
    title.TextStrokeColor3 = Color3.fromRGB(80, 0, 0)
    title.TextTransparency = 1
    title.Parent = bg
    TweenService:Create(title, TweenInfo.new(2), { TextTransparency = 0 }):Play()

    local sub = Instance.new("TextLabel")
    sub.Size = UDim2.new(0.7, 0, 0.06, 0)
    sub.Position = UDim2.new(0.15, 0, 0.49, 0)
    sub.BackgroundTransparency = 1
    sub.Text = subText
    sub.Font = Enum.Font.GothamMedium
    sub.TextScaled = true
    sub.TextColor3 = Color3.fromRGB(200, 200, 200)
    sub.TextTransparency = 1
    sub.Parent = bg
    TweenService:Create(sub, TweenInfo.new(2.5), { TextTransparency = 0.1 }):Play()

    local over = Instance.new("TextLabel")
    over.Size = UDim2.new(0.6, 0, 0.05, 0)
    over.Position = UDim2.new(0.2, 0, 0.6, 0)
    over.BackgroundTransparency = 1
    over.Text = "GAME OVER"
    over.Font = Enum.Font.Code
    over.TextScaled = true
    over.TextColor3 = Color3.fromRGB(140, 140, 140)
    over.Parent = bg

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, 220, 0, 48)
    btn.Position = UDim2.new(0.5, -110, 0.72, 0)
    btn.BackgroundColor3 = Color3.fromRGB(70, 30, 30)
    btn.Text = "Return to Lobby"
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 18
    btn.TextColor3 = Color3.new(1, 1, 1)
    btn.Parent = bg
    local bc = Instance.new("UICorner")
    bc.CornerRadius = UDim.new(0, 8)
    bc.Parent = btn

    btn.Activated:Connect(function()
        GameStateChanged:FireServer({ requestLobby = true })
        gui:Destroy()
        deathGuiShown = false
    end)
end

local function hookCharacterDeath(char: Model)
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then
        hum = char:WaitForChild("Humanoid", 5) :: Humanoid?
    end
    if hum and hum:IsA("Humanoid") then
        hum.Died:Connect(function()
            if currentPhase >= 1 and currentPhase <= 3 then
                showDeathScreen()
            end
        end)
    end
end
if player.Character then
    hookCharacterDeath(player.Character)
end
player.CharacterAdded:Connect(hookCharacterDeath)

-- Returning to the lobby clears any lingering death screen.
GameStateChanged.OnClientEvent:Connect(function(data: { phase: number })
    if data.phase == 0 then
        deathGuiShown = false
        local ds = playerGui:FindFirstChild("DeathScreen")
        if ds then
            ds:Destroy()
        end
    end
end)

print("[HUDController] Initialized - main HUD elements ready")
