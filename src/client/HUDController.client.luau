--!strict
--[[
    HUDController.client.luau
    Master HUD managing all persistent on-screen elements:
    - Clock display, project meter, phase banner, first-person reticle
    - Mobile controls (touch joystick placeholder)
    - Phase-aware visibility management
    Screen feedback layers live in HUD/ScreenFX, the game-over screen in
    HUD/DeathScreen.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CursorManager = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CursorManager"))
local UITheme = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UITheme"))
local StarterGui = game:GetService("StarterGui")
local HUD = script.Parent:WaitForChild("HUD")
local ScreenFX = require(HUD:WaitForChild("ScreenFX"))
local DeathScreen = require(HUD:WaitForChild("DeathScreen"))

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
    [0] = { text = "LOBBY", color = UITheme.Color.Text },
    [1] = { text = "DAY 1  FRIDAY NIGHT", color = UITheme.Color.Text },
    [2] = { text = "DAY 2  THE GRIND", color = UITheme.Color.Text },
    [3] = { text = "NIGHT 2  SURVIVE", color = UITheme.Color.Danger },
    [4] = { text = "DAY 3  JUDGEMENT DAY", color = UITheme.Color.Text },
}

-- ============================================================
-- STATE
-- ============================================================
local currentPhase = 0
local currentHealth = 100
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
-- CLOCK (top center): day caption over the time, no backing panel.
-- -----------------------------------------------------------
local clockFrame = Instance.new("Frame")
clockFrame.Name = "ClockFrame"
clockFrame.AnchorPoint = Vector2.new(0.5, 0)
clockFrame.Size = UDim2.fromOffset(200, 44)
clockFrame.Position = UDim2.new(0.5, 0, 0, UITheme.Margin - 6)
clockFrame.BackgroundTransparency = 1
clockFrame.Parent = hudGui

local dayLabel = UITheme.label(clockFrame, {
    text = "",
    size = 11,
    font = UITheme.Font.Bold,
    color = UITheme.Color.Dim,
    alignX = Enum.TextXAlignment.Center,
})
dayLabel.Name = "DayLabel"
dayLabel.Size = UDim2.new(1, 0, 0, 14)

local timeLabel = UITheme.label(clockFrame, {
    text = "6:00 PM",
    size = 22,
    font = UITheme.Font.Mono,
    alignX = Enum.TextXAlignment.Center,
})
timeLabel.Name = "TimeLabel"
timeLabel.Size = UDim2.new(1, 0, 0, 26)
timeLabel.Position = UDim2.fromOffset(0, 16)

-- -----------------------------------------------------------
-- HEALTH: we use Roblox's DEFAULT health bar (bottom of screen) now, plus a
-- screen damage effect (desaturation + blood vignette) built further below.
-- The old custom top-left bar has been removed.
-- -----------------------------------------------------------
StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, true)

-- -----------------------------------------------------------
-- PROJECT METER (top left)
-- -----------------------------------------------------------
local projectMeter = UITheme.meter(hudGui, "Project", 180)
local projectFrame = projectMeter.root
projectFrame.Position = UDim2.fromOffset(UITheme.Margin, UITheme.Margin)
projectFrame.Visible = false
local projectFill = projectMeter.fill
projectFill.Size = UDim2.fromScale(0, 1)
local pctText = projectMeter.value
pctText.Text = "0%"

-- -----------------------------------------------------------
-- PHASE BANNER (center screen, temporary)
-- -----------------------------------------------------------
local bannerLabel = UITheme.label(hudGui, {
    size = 30,
    font = UITheme.Font.Bold,
    transparency = 1,
    alignX = Enum.TextXAlignment.Center,
})
bannerLabel.Name = "PhaseBanner"
bannerLabel.Size = UDim2.new(0.6, 0, 0, 40)
bannerLabel.Position = UDim2.new(0.2, 0, 0.36, 0)
local bannerShadow = bannerLabel:FindFirstChildOfClass("UIStroke") :: UIStroke

-- Hairline under the banner text that draws outward as the banner appears.
local bannerRule = Instance.new("Frame")
bannerRule.Name = "PhaseBannerRule"
bannerRule.AnchorPoint = Vector2.new(0.5, 0)
bannerRule.Position = UDim2.new(0.5, 0, 0.36, 46)
bannerRule.Size = UDim2.fromOffset(0, 1)
bannerRule.BackgroundColor3 = UITheme.Color.Text
bannerRule.BackgroundTransparency = 0.5
bannerRule.BorderSizePixel = 0
bannerRule.Parent = hudGui

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
    mobileHint.FontFace = UITheme.Font.Regular
    mobileHint.TextColor3 = UITheme.Color.Faint
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
        projectFill.BackgroundColor3 = UITheme.Color.Good
        pctText.TextColor3 = UITheme.Color.Good
    end
end

local function showPhaseBanner(phase: number)
    local phaseData = PHASE_NAMES[phase]
    if not phaseData then
        return
    end

    bannerLabel.Text = phaseData.text
    bannerLabel.TextColor3 = phaseData.color
    bannerRule.BackgroundColor3 = phaseData.color
    bannerRule.Size = UDim2.fromOffset(0, 1)
    bannerRule.BackgroundTransparency = 0.5

    -- Fade in while the rule draws outward from the centre.
    local fadeIn = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
    TweenService:Create(bannerLabel, fadeIn, { TextTransparency = 0 }):Play()
    TweenService:Create(bannerShadow, fadeIn, { Transparency = UITheme.Alpha.Shadow }):Play()
    TweenService:Create(bannerRule, TweenInfo.new(0.9, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
        Size = UDim2.fromOffset(220, 1),
    }):Play()

    -- Hold for 3 seconds, then fade out
    task.delay(3, function()
        local fadeOut = TweenInfo.new(1)
        TweenService:Create(bannerLabel, fadeOut, { TextTransparency = 1 }):Play()
        TweenService:Create(bannerShadow, fadeOut, { Transparency = 1 }):Play()
        TweenService:Create(bannerRule, fadeOut, { BackgroundTransparency = 1 }):Play()
    end)
end

local function updateVisibility(phase: number)
    -- LOBBY (0) and the DAY3 cutscene (4) hide the HUD; the play phases show it.
    local inPlay = (phase == 1 or phase == 2 or phase == 3)
    clockFrame.Visible = inPlay
    projectFrame.Visible = inPlay
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
    if displayHour == 0 then
        displayHour = 12
    end

    timeLabel.Text = string.format("%d:%02d %s", displayHour, minutes, ampm)

    -- Update day label
    local dayNames = {
        [1] = "FRIDAY",
        [2] = "SATURDAY",
        [3] = "SATURDAY NIGHT",
        [4] = "SUNDAY",
    }
    dayLabel.Text = dayNames[data.phase] or ""

    -- Night mode clock color
    if data.phase == 3 then
        timeLabel.TextColor3 = UITheme.Color.Danger
        dayLabel.TextColor3 = UITheme.Color.Danger
    else
        timeLabel.TextColor3 = UITheme.Color.Text
        dayLabel.TextColor3 = UITheme.Color.Dim
    end
end)

-- Senders disagree on the payload (HANDOFF G9): a table from GameStateManager
-- and QuestManager, bare numbers from NGMIController. The flash needs neither.
PlayerDamaged.OnClientEvent:Connect(function(data: any)
    if typeof(data) == "table" then
        if data.health then
            currentHealth = data.health
        elseif data.damage then
            currentHealth = math.max(0, currentHealth - data.damage)
        end
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
        if flash.Parent then
            flash:Destroy()
        end
    end)
end)

CodingProgress.OnClientEvent:Connect(function(data: { completion: number?, blocked: boolean? })
    -- CodingProgress is also used for desk start/stop control signals (which carry
    -- no completion) — ignore those here and only react to real progress updates.
    if type(data) ~= "table" or data.completion == nil then
        return
    end
    projectCompletion = data.completion
    updateProjectMeter()
end)

-- ============================================================
-- SCREEN FEEDBACK AND DEATH SCREEN
-- ============================================================
ScreenFX.start(function()
    return currentPhase
end)

local function hookCharacterDeath(char: Model)
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then
        hum = char:WaitForChild("Humanoid", 5) :: Humanoid?
    end
    if hum and hum:IsA("Humanoid") then
        hum.Died:Connect(function()
            if currentPhase >= 1 and currentPhase <= 3 then
                DeathScreen.show()
            end
        end)
    end
end
if player.Character then
    hookCharacterDeath(player.Character)
end
-- A new character means the player respawned and is back in play, so the death
-- screen (and the free cursor it holds) has to go.
player.CharacterAdded:Connect(function(char: Model)
    DeathScreen.close()
    hookCharacterDeath(char)
end)
-- Any phase change makes a death screen stale, the lobby included.
GameStateChanged.OnClientEvent:Connect(DeathScreen.close)

-- ============================================================
-- FIRST-PERSON RETICLE
-- ============================================================
-- Gameplay runs in LockFirstPerson, where Roblox keeps drawing the desktop mouse
-- arrow pinned to the middle of the screen: it reads as something clickable, and
-- it is a poor thing to aim a flashlight with. Hide it and draw a small white
-- dot in its place. The moment any GUI scene frees the cursor the real pointer
-- comes straight back, so CursorManager stays the single owner of cursor state
-- and this only ever fills in the gap it leaves.
local reticle = Instance.new("Frame")
reticle.Name = "Reticle"
reticle.AnchorPoint = Vector2.new(0.5, 0.5)
reticle.Position = UDim2.fromScale(0.5, 0.5)
reticle.Size = UDim2.fromOffset(4, 4)
reticle.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
reticle.BorderSizePixel = 0
reticle.ZIndex = 50
reticle.Visible = false
reticle.Parent = hudGui

local reticleCorner = Instance.new("UICorner")
reticleCorner.CornerRadius = UDim.new(1, 0)
reticleCorner.Parent = reticle

-- A soft dark ring so the dot survives a white wall or a ceiling light behind it.
local reticleRing = Instance.new("UIStroke")
reticleRing.Color = Color3.fromRGB(0, 0, 0)
reticleRing.Thickness = 1
reticleRing.Transparency = 0.45
reticleRing.Parent = reticle

if not isMobile then
    local reticleShown = false
    RunService.RenderStepped:Connect(function()
        -- MouseBehavior is the authoritative signal: first person pins the mouse
        -- to centre with LockCenter, which is exactly when the arrow is useless.
        -- CameraMode is checked too so the dot is up on the frame the phase
        -- switches to gameplay, before the camera module has re-pinned the mouse.
        local locked = not CursorManager.isOpen()
            and (
                player.CameraMode == Enum.CameraMode.LockFirstPerson
                or UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
            )
        if locked == reticleShown then
            return
        end
        reticleShown = locked
        reticle.Visible = locked
        UserInputService.MouseIconEnabled = not locked
    end)
end

print("[HUDController] Initialized - main HUD elements ready")
