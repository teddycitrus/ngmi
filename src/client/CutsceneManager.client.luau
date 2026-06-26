--!strict
--[[
    CutsceneManager.client.luau
    Handles all narrative cutscenes:
    - Sleep transition (Day 1 → Day 2)
    - Bad Ending (survived but < 100% completion)
    - True Ending (survived + 100% completion)
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local CutsceneTrigger = Remotes:WaitForChild("CutsceneTrigger") :: RemoteEvent
local EndingTrigger = Remotes:WaitForChild("EndingTrigger") :: RemoteEvent
local GameStateChanged = Remotes:WaitForChild("GameStateChanged") :: RemoteEvent

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = workspace.CurrentCamera

-- ============================================================
-- UTILITIES
-- ============================================================
local function disableControls()
    local success, playerModule = pcall(function()
        return require(player.PlayerScripts:WaitForChild("PlayerModule", 3))
    end)
    if success and playerModule then
        local controls = playerModule:GetControls()
        if controls then controls:Disable() end
    end
end

local function enableControls()
    local success, playerModule = pcall(function()
        return require(player.PlayerScripts:WaitForChild("PlayerModule", 3))
    end)
    if success and playerModule then
        local controls = playerModule:GetControls()
        if controls then controls:Enable() end
    end
end

-- Free the mouse so an ending screen's "Return to Lobby" button is clickable.
-- Gameplay runs in LockFirstPerson, which pins the cursor to screen-centre and
-- hides it; switching CameraMode off Lock stops it being re-centred each frame.
local function unlockCursor()
    player.CameraMode = Enum.CameraMode.Classic
    -- The camera is pinned at first-person zoom (0.5); at that zoom the mouse
    -- re-locks no matter the CameraMode, so widen the zoom to pull it out to third
    -- person where the cursor is genuinely free.
    player.CameraMinZoomDistance = 10
    player.CameraMaxZoomDistance = 16
    UserInputService.MouseBehavior = Enum.MouseBehavior.Default
    UserInputService.MouseIconEnabled = true
end

local function createOverlayGui(name: string): (ScreenGui, Frame)
    local gui = Instance.new("ScreenGui")
    gui.Name = name
    gui.DisplayOrder = 500
    gui.IgnoreGuiInset = true
    gui.Parent = playerGui

    local bg = Instance.new("Frame")
    bg.Name = "Background"
    bg.Size = UDim2.new(1, 0, 1, 0)
    bg.BackgroundColor3 = Color3.new(0, 0, 0)
    bg.BackgroundTransparency = 1 -- Start transparent
    bg.BorderSizePixel = 0
    bg.Parent = gui

    return gui, bg
end

local function fadeIn(bg: Frame, duration: number)
    TweenService:Create(bg, TweenInfo.new(duration, Enum.EasingStyle.Quad), {
        BackgroundTransparency = 0,
    }):Play()
    task.wait(duration)
end

local function fadeOut(bg: Frame, duration: number)
    TweenService:Create(bg, TweenInfo.new(duration, Enum.EasingStyle.Quad), {
        BackgroundTransparency = 1,
    }):Play()
    task.wait(duration)
end

local function showText(parent: Frame, text: string, size: number, color: Color3, yPos: number, duration: number, font: Enum.Font?)
    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(0.8, 0, 0, size + 10)
    label.Position = UDim2.new(0.1, 0, yPos, 0)
    label.BackgroundTransparency = 1
    label.Text = text
    label.TextSize = size
    label.Font = font or Enum.Font.GothamBold
    label.TextColor3 = color
    label.TextTransparency = 1
    label.TextWrapped = true
    label.Parent = parent

    -- Fade in text
    TweenService:Create(label, TweenInfo.new(1, Enum.EasingStyle.Quad), {
        TextTransparency = 0,
    }):Play()

    task.wait(duration)

    -- Fade out text
    TweenService:Create(label, TweenInfo.new(0.8, Enum.EasingStyle.Quad), {
        TextTransparency = 1,
    }):Play()

    task.delay(0.9, function()
        if label.Parent then label:Destroy() end
    end)
end

-- ============================================================
-- SLEEP CUTSCENE (Day 1 → Day 2)
-- The player turns in for the night: a drowsy internal monologue while their
-- walk slows and their vision swims, a fade to black (the server flips to DAY2
-- while it's dark), then they blink awake in the morning and resolve to work.
-- ============================================================
local function playSleepCutscene()
    local char = player.Character
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    local origWalk = 11
    if humanoid and humanoid.WalkSpeed > 0 then origWalk = humanoid.WalkSpeed end
    local Lighting = game:GetService("Lighting")

    local gui = Instance.new("ScreenGui")
    gui.Name = "SleepCutscene"
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 600
    gui.Parent = playerGui

    local bg = Instance.new("Frame")
    bg.BackgroundColor3 = Color3.new(0, 0, 0)
    bg.BackgroundTransparency = 1
    bg.BorderSizePixel = 0
    bg.Size = UDim2.new(1, 0, 1, 0)
    bg.ZIndex = 1
    bg.Parent = gui

    local topBar = Instance.new("Frame")
    topBar.BackgroundColor3 = Color3.new(0, 0, 0)
    topBar.BorderSizePixel = 0
    topBar.Size = UDim2.new(1, 0, 0, 0)
    topBar.ZIndex = 5
    topBar.Parent = gui

    local botBar = Instance.new("Frame")
    botBar.BackgroundColor3 = Color3.new(0, 0, 0)
    botBar.BorderSizePixel = 0
    botBar.AnchorPoint = Vector2.new(0, 1)
    botBar.Position = UDim2.new(0, 0, 1, 0)
    botBar.Size = UDim2.new(1, 0, 0, 0)
    botBar.ZIndex = 5
    botBar.Parent = gui

    local thought = Instance.new("TextLabel")
    thought.AnchorPoint = Vector2.new(0.5, 0.5)
    thought.Size = UDim2.new(0.72, 0, 0, 140)
    thought.Position = UDim2.new(0.5, 0, 0.62, 0)
    thought.BackgroundTransparency = 1
    thought.Font = Enum.Font.Gotham
    thought.TextSize = 26
    thought.TextColor3 = Color3.fromRGB(210, 210, 225)
    thought.TextStrokeTransparency = 0.6
    thought.TextWrapped = true
    thought.TextTransparency = 1
    thought.ZIndex = 10
    thought.Text = ""
    thought.Parent = gui

    local function showThought(text: string, hold: number)
        thought.Text = text
        TweenService:Create(thought, TweenInfo.new(0.6), { TextTransparency = 0 }):Play()
        task.wait(hold)
        TweenService:Create(thought, TweenInfo.new(0.6), { TextTransparency = 1 }):Play()
        task.wait(0.62)
    end

    -- (1) Drowsy — still on their feet. Slow the walk, swim the vision in and out.
    local blur = Instance.new("BlurEffect")
    blur.Name = "SleepBlur"
    blur.Size = 0
    blur.Parent = Lighting
    task.spawn(function()
        if humanoid then
            TweenService:Create(humanoid, TweenInfo.new(4.5, Enum.EasingStyle.Quad), { WalkSpeed = math.max(2, origWalk * 0.3) }):Play()
        end
        TweenService:Create(blur, TweenInfo.new(2.6, Enum.EasingStyle.Quad), { Size = 22 }):Play()
        task.wait(2.8)
        TweenService:Create(blur, TweenInfo.new(2.4, Enum.EasingStyle.Quad), { Size = 0 }):Play()
    end)
    showThought("*yawn*... I'm running on fumes. I can barely keep my eyes open.", 3)
    showThought("I'll call it. If I'm up before everyone tomorrow, I can beat the competition.", 3.2)

    -- (2) They drift off — controls off, fade to black. DAY2 begins while it's dark.
    disableControls()
    TweenService:Create(blur, TweenInfo.new(1.4), { Size = 0 }):Play()
    TweenService:Create(bg, TweenInfo.new(1.5, Enum.EasingStyle.Quad), { BackgroundTransparency = 0 }):Play()
    task.wait(1.6)
    if humanoid then humanoid.WalkSpeed = origWalk end
    task.wait(2.5) -- held asleep (the server flips to DAY2 in here)

    -- (3) Morning. Blink awake.
    local function setLids(closed: number, dur: number)
        local h = 0.5 * closed
        TweenService:Create(topBar, TweenInfo.new(dur, Enum.EasingStyle.Sine), { Size = UDim2.new(1, 0, h, 0) }):Play()
        TweenService:Create(botBar, TweenInfo.new(dur, Enum.EasingStyle.Sine), { Size = UDim2.new(1, 0, h, 0) }):Play()
    end
    setLids(1, 0) -- eyes shut
    TweenService:Create(bg, TweenInfo.new(0.5), { BackgroundTransparency = 1 }):Play() -- clear behind the lids
    task.wait(0.6)
    setLids(0.5, 0.5); task.wait(0.55)   -- crack open
    setLids(0.85, 0.16); task.wait(0.18) -- blink
    setLids(0.35, 0.22); task.wait(0.5)
    setLids(0.8, 0.15); task.wait(0.16)  -- blink
    setLids(0, 0.4); task.wait(0.45)     -- fully open

    showThought("Morning already? Right — no time to waste. Let's get to work.", 2.6)

    -- (4) Resume gameplay (now in DAY2).
    if humanoid then humanoid.WalkSpeed = origWalk end
    if blur.Parent then blur:Destroy() end
    gui:Destroy()
    enableControls()
end

-- ============================================================
-- BAD ENDING
-- ============================================================
local function playBadEnding()
    disableControls()
    unlockCursor()

    camera.CameraType = Enum.CameraType.Scriptable

    local gui, bg = createOverlayGui("BadEnding")

    -- Morning light - briefly show the scene
    task.wait(1)

    -- White flash (sunrise)
    bg.BackgroundColor3 = Color3.fromRGB(255, 240, 200)
    fadeIn(bg, 0.3)
    task.wait(0.5)
    fadeOut(bg, 1)

    -- Wait a moment - the player sees the venue in morning light
    task.wait(2)

    -- Start glitching
    bg.BackgroundColor3 = Color3.new(0, 0, 0)

    -- Glitch flashes
    for i = 1, 8 do
        bg.BackgroundTransparency = 0.3
        bg.BackgroundColor3 = Color3.fromRGB(
            math.random(100, 255),
            math.random(0, 50),
            math.random(100, 255)
        )
        task.wait(0.08)
        bg.BackgroundTransparency = 1
        task.wait(math.random() * 0.3 + 0.1)
    end

    -- Final fade to dark
    bg.BackgroundColor3 = Color3.fromRGB(20, 0, 30)
    fadeIn(bg, 1)

    task.wait(1)

    -- Mutation text sequence — the player lived the weekend but shipped nothing,
    -- so they're turning into one of the very things that hunted them.
    showText(bg, "You made it to Sunday...", 32, Color3.fromRGB(200, 200, 200), 0.3, 3)
    task.wait(1)
    showText(bg, "...but your repo is empty. No demo. No commits.", 26, Color3.fromRGB(255, 100, 100), 0.42, 3)
    task.wait(1.5)

    -- The dreaded message
    local ngmiText = Instance.new("TextLabel")
    ngmiText.Size = UDim2.new(0.8, 0, 0.12, 0)
    ngmiText.Position = UDim2.new(0.1, 0, 0.55, 0)
    ngmiText.BackgroundTransparency = 1
    ngmiText.Text = "You are NGMI now."
    ngmiText.TextSize = 56
    ngmiText.Font = Enum.Font.Creepster
    ngmiText.TextColor3 = Color3.fromRGB(255, 0, 0)
    ngmiText.TextTransparency = 1
    ngmiText.TextStrokeTransparency = 0.5
    ngmiText.TextStrokeColor3 = Color3.fromRGB(100, 0, 0)
    ngmiText.Parent = bg

    TweenService:Create(ngmiText, TweenInfo.new(2, Enum.EasingStyle.Quad), {
        TextTransparency = 0,
    }):Play()

    task.wait(5)

    -- GAME OVER
    local gameOverText = Instance.new("TextLabel")
    gameOverText.Size = UDim2.new(0.6, 0, 0.06, 0)
    gameOverText.Position = UDim2.new(0.2, 0, 0.72, 0)
    gameOverText.BackgroundTransparency = 1
    gameOverText.Text = "GAME OVER"
    gameOverText.TextSize = 24
    gameOverText.Font = Enum.Font.Code
    gameOverText.TextColor3 = Color3.fromRGB(150, 150, 150)
    gameOverText.Parent = bg

    -- Return to lobby button
    local lobbyBtn = Instance.new("TextButton")
    lobbyBtn.Size = UDim2.new(0, 200, 0, 45)
    lobbyBtn.Position = UDim2.new(0.5, -100, 0.82, 0)
    lobbyBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 80)
    lobbyBtn.Text = "Return to Lobby"
    lobbyBtn.TextSize = 18
    lobbyBtn.Font = Enum.Font.GothamBold
    lobbyBtn.TextColor3 = Color3.new(1, 1, 1)
    lobbyBtn.Parent = bg

    local btnCorner = Instance.new("UICorner")
    btnCorner.CornerRadius = UDim.new(0, 8)
    btnCorner.Parent = lobbyBtn

    lobbyBtn.Activated:Connect(function()
        gui:Destroy()
        camera.CameraType = Enum.CameraType.Custom
        local character = player.Character
        if character then
            local humanoid = character:FindFirstChildOfClass("Humanoid")
            if humanoid then
                camera.CameraSubject = humanoid
            end
        end
        enableControls()
        -- Request server to return to lobby
        GameStateChanged:FireServer({ requestLobby = true })
    end)
end

-- ============================================================
-- TRUE ENDING
-- ============================================================
local function playTrueEnding()
    disableControls()
    unlockCursor()

    camera.CameraType = Enum.CameraType.Scriptable

    local gui, bg = createOverlayGui("TrueEnding")

    -- Golden sunrise
    bg.BackgroundColor3 = Color3.fromRGB(255, 220, 150)
    bg.BackgroundTransparency = 0
    task.wait(0.5)
    fadeOut(bg, 3) -- Slow reveal of morning light

    task.wait(2)

    -- Narration overlays
    bg.BackgroundColor3 = Color3.new(0, 0, 0)

    -- "The NGMIs dissolve" text
    local dissolveText = Instance.new("TextLabel")
    dissolveText.Size = UDim2.new(0.8, 0, 0.06, 0)
    dissolveText.Position = UDim2.new(0.1, 0, 0.05, 0)
    dissolveText.BackgroundTransparency = 1
    dissolveText.Text = "The remaining NGMIs dissolve into lines of code..."
    dissolveText.TextSize = 20
    dissolveText.Font = Enum.Font.GothamMedium
    dissolveText.TextColor3 = Color3.fromRGB(100, 255, 150)
    dissolveText.TextTransparency = 0.3
    dissolveText.Parent = gui

    task.wait(4)
    if dissolveText.Parent then
        TweenService:Create(dissolveText, TweenInfo.new(1), { TextTransparency = 1 }):Play()
    end

    task.wait(2)

    -- Fade to celebration
    fadeIn(bg, 1)
    task.wait(1)

    -- Grand prize reveal
    bg.BackgroundColor3 = Color3.fromRGB(10, 10, 20)

    -- Confetti emoji rain effect
    task.spawn(function()
        for _ = 1, 30 do
            local confetti = Instance.new("TextLabel")
            confetti.Size = UDim2.new(0, 30, 0, 30)
            confetti.Position = UDim2.new(math.random() * 0.9 + 0.05, 0, -0.05, 0)
            confetti.BackgroundTransparency = 1
            confetti.Text = ({ "🎉", "🎊", "⭐", "✨", "🏆", "💰" })[math.random(1, 6)]
            confetti.TextSize = 24
            confetti.Rotation = math.random(-30, 30)
            confetti.Parent = bg

            TweenService:Create(confetti, TweenInfo.new(math.random(2, 4), Enum.EasingStyle.Linear), {
                Position = UDim2.new(confetti.Position.X.Scale, 0, 1.1, 0),
                Rotation = confetti.Rotation + math.random(-180, 180),
            }):Play()

            task.delay(5, function()
                if confetti.Parent then confetti:Destroy() end
            end)
            task.wait(0.15)
        end
    end)

    -- Check display
    local checkText = Instance.new("TextLabel")
    checkText.Size = UDim2.new(0.6, 0, 0.15, 0)
    checkText.Position = UDim2.new(0.2, 0, 0.2, 0)
    checkText.BackgroundColor3 = Color3.fromRGB(255, 250, 230)
    checkText.Text = "💰 $10,000 GRAND PRIZE 💰"
    checkText.TextSize = 42
    checkText.Font = Enum.Font.GothamBold
    checkText.TextColor3 = Color3.fromRGB(50, 50, 10)
    checkText.TextTransparency = 1
    checkText.Parent = bg

    local checkCorner = Instance.new("UICorner")
    checkCorner.CornerRadius = UDim.new(0, 12)
    checkCorner.Parent = checkText

    TweenService:Create(checkText, TweenInfo.new(1.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
        TextTransparency = 0,
    }):Play()

    task.wait(3)

    -- Victory message
    showText(bg, "YOU SHIPPED.", 36, Color3.fromRGB(100, 255, 200), 0.45, 3)
    task.wait(0.5)
    showText(bg, "YOU SURVIVED.", 36, Color3.fromRGB(100, 200, 255), 0.53, 3)
    task.wait(0.5)
    showText(bg, "YOU WON.", 42, Color3.fromRGB(255, 255, 100), 0.63, 4)

    task.wait(3)

    -- Credits
    local credits = Instance.new("TextLabel")
    credits.Size = UDim2.new(0.6, 0, 0.3, 0)
    credits.Position = UDim2.new(0.2, 0, 1.1, 0)
    credits.BackgroundTransparency = 1
    credits.Text = table.concat({
        "NOT GONNA MAKE IT",
        "",
        "A game about shipping code under pressure",
        "",
        "Built with Antigravity 2.0",
        "",
        "Thank you for playing!",
        "",
        "Remember: always ship your code.",
        "And maybe shower first.",
    }, "\n")
    credits.TextSize = 18
    credits.Font = Enum.Font.GothamMedium
    credits.TextColor3 = Color3.fromRGB(200, 200, 220)
    credits.Parent = bg

    -- Scroll credits up
    TweenService:Create(credits, TweenInfo.new(10, Enum.EasingStyle.Linear), {
        Position = UDim2.new(0.2, 0, -0.3, 0),
    }):Play()

    task.wait(8)

    -- Return to lobby button
    local lobbyBtn = Instance.new("TextButton")
    lobbyBtn.Size = UDim2.new(0, 220, 0, 50)
    lobbyBtn.Position = UDim2.new(0.5, -110, 0.85, 0)
    lobbyBtn.BackgroundColor3 = Color3.fromRGB(50, 120, 50)
    lobbyBtn.Text = "🏆 Return to Lobby"
    lobbyBtn.TextSize = 20
    lobbyBtn.Font = Enum.Font.GothamBold
    lobbyBtn.TextColor3 = Color3.new(1, 1, 1)
    lobbyBtn.Parent = bg

    local btnCorner = Instance.new("UICorner")
    btnCorner.CornerRadius = UDim.new(0, 10)
    btnCorner.Parent = lobbyBtn

    lobbyBtn.Activated:Connect(function()
        gui:Destroy()
        camera.CameraType = Enum.CameraType.Custom
        local character = player.Character
        if character then
            local humanoid = character:FindFirstChildOfClass("Humanoid")
            if humanoid then
                camera.CameraSubject = humanoid
            end
        end
        enableControls()
        GameStateChanged:FireServer({ requestLobby = true })
    end)
end

-- ============================================================
-- OPENING CUTSCENE (Day 1 start — the organizer's welcome talk)
-- A short (~8s) cinematic: letterbox bars slide in, the camera pushes slowly
-- toward the stage while the organizer's lines play as captions, then the bars
-- "shrink out" and control returns. The player is seated in the auditorium.
-- ============================================================
local function playOpeningCutscene(data: { [string]: any })
    local lines = (data.lines :: { string }?) or { "Welcome to the hackathon." }
    local camStart = (data.camStart :: Vector3?) or Vector3.new(-52, 9, -22)
    local camEnd = (data.camEnd :: Vector3?) or Vector3.new(-46, 6, -42)
    local lookAt = (data.lookAt :: Vector3?) or Vector3.new(-64, 4, -75)
    local seatNear = data.seatNear :: Vector3?

    disableControls()

    -- hide every other on-screen UI for a clean cinematic frame
    local hiddenGuis: { ScreenGui } = {}
    for _, g in playerGui:GetChildren() do
        if g:IsA("ScreenGui") and g.Enabled then
            g.Enabled = false
            table.insert(hiddenGuis, g)
        end
    end

    local char = player.Character
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    local hrp = char and char:FindFirstChild("HumanoidRootPart")

    -- seat the player in the auditorium. We DON'T use the bench's Seat:Sit — that
    -- creates a SeatWeld which drags the whole bench along when the cutscene later
    -- teleports the player out. Just sit them in place on the bench's spot.
    if hrp and hrp:IsA("BasePart") and seatNear then
        hrp.CFrame = CFrame.new(seatNear)
        task.wait(0.1)
        if humanoid then
            humanoid.Sit = true
            hrp.Anchored = true
        end
    end

    -- cinematic camera (slow dolly toward the stage)
    camera.CameraType = Enum.CameraType.Scriptable
    camera.CFrame = CFrame.lookAt(camStart, lookAt)
    TweenService:Create(camera, TweenInfo.new(8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
        CFrame = CFrame.lookAt(camEnd, lookAt),
    }):Play()

    -- letterbox + caption overlay
    local gui = Instance.new("ScreenGui")
    gui.Name = "OpeningCinematic"
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 400
    gui.Parent = playerGui

    local topBar = Instance.new("Frame")
    topBar.BackgroundColor3 = Color3.new(0, 0, 0)
    topBar.BorderSizePixel = 0
    topBar.Position = UDim2.new(0, 0, 0, 0)
    topBar.Size = UDim2.new(1, 0, 0, 0)
    topBar.Parent = gui

    local botBar = Instance.new("Frame")
    botBar.BackgroundColor3 = Color3.new(0, 0, 0)
    botBar.BorderSizePixel = 0
    botBar.AnchorPoint = Vector2.new(0, 1)
    botBar.Position = UDim2.new(0, 0, 1, 0)
    botBar.Size = UDim2.new(1, 0, 0, 0)
    botBar.Parent = gui

    local caption = Instance.new("TextLabel")
    -- Anchored just above the bottom letterbox bar and tall enough to hold a few
    -- wrapped lines, so long sentences show in full instead of being clipped.
    caption.AnchorPoint = Vector2.new(0.5, 1)
    caption.Size = UDim2.new(0.82, 0, 0, 120)
    caption.Position = UDim2.new(0.5, 0, 0.86, 0)
    caption.BackgroundTransparency = 1
    caption.Font = Enum.Font.GothamMedium
    caption.TextSize = 24
    caption.TextColor3 = Color3.fromRGB(245, 245, 245)
    caption.TextStrokeTransparency = 0.5
    caption.TextWrapped = true
    caption.TextYAlignment = Enum.TextYAlignment.Bottom
    caption.TextTransparency = 1
    caption.Text = ""
    caption.Parent = gui

    local BAR_H = 0.12
    -- bars slide IN
    TweenService:Create(topBar, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.new(1, 0, BAR_H, 0) }):Play()
    TweenService:Create(botBar, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.new(1, 0, BAR_H, 0) }):Play()

    -- Each caption is held for a fixed, readable beat (so the speech can be a
    -- proper new-player guide — the more lines it has, the longer it runs).
    local PER_LINE = 3.4
    task.spawn(function()
        task.wait(0.5)
        for _, ln in lines do
            caption.Text = ln
            TweenService:Create(caption, TweenInfo.new(0.3), { TextTransparency = 0 }):Play()
            task.wait(math.max(0.3, PER_LINE - 0.35))
            TweenService:Create(caption, TweenInfo.new(0.25), { TextTransparency = 1 }):Play()
            task.wait(0.05)
        end
    end)

    -- hold the letterbox until every caption has played out
    task.wait(0.5 + #lines * (PER_LINE - 0.3) + 0.6)

    -- bars "shrink out"
    TweenService:Create(topBar, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Size = UDim2.new(1, 0, 0, 0) }):Play()
    TweenService:Create(botBar, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Size = UDim2.new(1, 0, 0, 0) }):Play()
    task.wait(0.5)
    gui:Destroy()

    -- restore gameplay — get the player up off the bench Seat and onto their feet.
    -- (Sit=false alone leaves them welded to the Seat, which would freeze them and
    -- desync their position; Jump pops the SeatWeld, then we step them to the exit.)
    if humanoid then
        humanoid.Sit = false
        humanoid.Jump = true
    end
    if hrp and hrp:IsA("BasePart") then
        hrp.Anchored = false
        local exitTo = data.exitTo :: Vector3?
        if exitTo then
            task.wait(0.1)
            hrp.CFrame = CFrame.new(exitTo)
        end
    end
    camera.CameraType = Enum.CameraType.Custom
    if humanoid then
        camera.CameraSubject = humanoid
    end
    -- bring the hidden UIs back (but never the lobby menu — it's dismissed for the
    -- rest of the match, and re-enabling it would revive its pulsing overlay)
    for _, g in hiddenGuis do
        if g.Parent and g.Name ~= "LobbyGui" then
            g.Enabled = true
        end
    end
    enableControls()
end

-- ============================================================
-- NIGHT TRANSITION CUTSCENE (Day 2 → Night 2)
-- The player dozes off; a montage of real avatar hackers melting down and
-- mutating into NGMIs, a storm kills the power, and the player jolts awake on
-- the floor for the final night. Self-contained & client-local: it clones real
-- venue rigs into an off-map set, poses them via Motor6D, films hard cuts, and
-- tears the set down. The server holds the phase until this plays out.
-- ============================================================
local function playNightTransition()
    disableControls()

    local hiddenGuis: { ScreenGui } = {}
    local hiddenBillboards: { BillboardGui } = {}
    local conns: { RBXScriptConnection } = {}

    local gui = Instance.new("ScreenGui")
    gui.Name = "NightTransition"; gui.IgnoreGuiInset = true; gui.DisplayOrder = 600; gui.Parent = playerGui
    local bg = Instance.new("Frame")
    bg.BackgroundColor3 = Color3.new(0,0,0); bg.BackgroundTransparency = 1; bg.BorderSizePixel = 0
    bg.Size = UDim2.new(1,0,1,0); bg.ZIndex = 1; bg.Parent = gui
    local topBar = Instance.new("Frame")
    topBar.BackgroundColor3 = Color3.new(0,0,0); topBar.BorderSizePixel = 0
    topBar.Position = UDim2.new(0,0,0,0); topBar.Size = UDim2.new(1,0,0,0); topBar.ZIndex = 5; topBar.Parent = gui
    local botBar = Instance.new("Frame")
    botBar.BackgroundColor3 = Color3.new(0,0,0); botBar.BorderSizePixel = 0; botBar.AnchorPoint = Vector2.new(0,1)
    botBar.Position = UDim2.new(0,0,1,0); botBar.Size = UDim2.new(1,0,0,0); botBar.ZIndex = 5; botBar.Parent = gui
    local caption = Instance.new("TextLabel")
    caption.AnchorPoint = Vector2.new(0.5,1); caption.Size = UDim2.new(0.82,0,0,120); caption.Position = UDim2.new(0.5,0,0.88,0)
    caption.BackgroundTransparency = 1; caption.Font = Enum.Font.GothamMedium; caption.TextSize = 24
    caption.TextColor3 = Color3.fromRGB(245,245,245); caption.TextStrokeTransparency = 0.5; caption.TextWrapped = true
    caption.TextYAlignment = Enum.TextYAlignment.Bottom; caption.TextTransparency = 1; caption.ZIndex = 10; caption.Text = ""; caption.Parent = gui
    local thought = Instance.new("TextLabel")
    thought.AnchorPoint = Vector2.new(0.5,0.5); thought.Size = UDim2.new(0.72,0,0,140); thought.Position = UDim2.new(0.5,0,0.5,0)
    thought.BackgroundTransparency = 1; thought.Font = Enum.Font.Gotham; thought.TextSize = 26
    thought.TextColor3 = Color3.fromRGB(205,205,220); thought.TextStrokeTransparency = 0.6; thought.TextWrapped = true
    thought.TextTransparency = 1; thought.ZIndex = 10; thought.Text = ""; thought.Parent = gui
    local flash = Instance.new("Frame")
    flash.BackgroundColor3 = Color3.new(1,1,1); flash.BackgroundTransparency = 1; flash.BorderSizePixel = 0
    flash.Size = UDim2.new(1,0,1,0); flash.ZIndex = 20; flash.Parent = gui

    local watched: { [ScreenGui]: boolean } = {}
    local function keepHidden(g: Instance)
        if not g:IsA("ScreenGui") or g == gui then return end
        local sg = g :: ScreenGui
        if watched[sg] then return end
        watched[sg] = true
        if sg.Enabled then sg.Enabled = false; table.insert(hiddenGuis, sg) end
        table.insert(conns, sg:GetPropertyChangedSignal("Enabled"):Connect(function()
            if sg.Enabled then
                sg.Enabled = false
                if not table.find(hiddenGuis, sg) then table.insert(hiddenGuis, sg) end
            end
        end))
    end
    for _, g in playerGui:GetChildren() do keepHidden(g) end
    table.insert(conns, playerGui.ChildAdded:Connect(function(g) task.defer(keepHidden, g) end))
    table.insert(conns, RunService.RenderStepped:Connect(function()
        for _, sg in hiddenGuis do if sg.Parent and sg.Enabled then sg.Enabled = false end end
    end))
    local ProximityPromptService = game:GetService("ProximityPromptService")
    ProximityPromptService.Enabled = false

    local function showCaption(text: string, hold: number)
        caption.Text = text
        TweenService:Create(caption, TweenInfo.new(0.3), { TextTransparency = 0 }):Play()
        task.wait(hold)
        TweenService:Create(caption, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
        task.wait(0.32)
    end
    local function showThought(text: string, hold: number)
        thought.Text = text
        TweenService:Create(thought, TweenInfo.new(0.6), { TextTransparency = 0 }):Play()
        task.wait(hold)
        TweenService:Create(thought, TweenInfo.new(0.6), { TextTransparency = 1 }):Play()
        task.wait(0.62)
    end
    local function lightningFlash(intensity: number)
        flash.BackgroundTransparency = 1 - intensity
        TweenService:Create(flash, TweenInfo.new(0.35, Enum.EasingStyle.Quad), { BackgroundTransparency = 1 }):Play()
    end

    local BASE = Vector3.new(8000, 400, 8000)
    local DARK = Color3.fromRGB(14, 13, 18)
    local NGMI_BODY = Color3.fromRGB(40, 10, 50)
    local set = Instance.new("Folder"); set.Name = "NightTransitionSet"; set.Parent = workspace

    local function newPart(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): Part
        local p = Instance.new("Part")
        p.Name = name; p.Anchored = true; p.CanCollide = false; p.CastShadow = false
        p.Size = size; p.CFrame = cf; p.Color = color; p.Material = material or Enum.Material.SmoothPlastic; p.Parent = set
        return p
    end

    local cloneSources: { Model } = {}
    local function gatherFrom(folderName: string)
        local f = workspace:FindFirstChild(folderName)
        if not f then return end
        for _, m in f:GetChildren() do
            if m:IsA("Model") and m:FindFirstChildOfClass("Humanoid") and m:FindFirstChild("HumanoidRootPart") and m:FindFirstChild("UpperTorso") then
                table.insert(cloneSources, m)
            end
        end
    end
    gatherFrom("NPCs")
    if #cloneSources == 0 then gatherFrom("AmbientPeople") end

    -- The joint name (e.g. "RightShoulder") may be shared by both a Motor6D AND an
    -- AnimationConstraint on modern rigs, so search for the Motor6D specifically.
    local function motorOf(model: Model, partName: string, motorName: string): Motor6D?
        local part = model:FindFirstChild(partName)
        if not part then return nil end
        for _, c in part:GetChildren() do
            if c:IsA("Motor6D") and c.Name == motorName then return c :: Motor6D end
        end
        return nil
    end
    local JOINTS: { [string]: { string } } = {
        waist = { "UpperTorso", "Waist" }, neck = { "Head", "Neck" },
        rS = { "RightUpperArm", "RightShoulder" }, lS = { "LeftUpperArm", "LeftShoulder" },
        rE = { "RightLowerArm", "RightElbow" }, lE = { "LeftLowerArm", "LeftElbow" },
        rH = { "RightUpperLeg", "RightHip" }, lH = { "LeftUpperLeg", "LeftHip" },
        rK = { "RightLowerLeg", "RightKnee" }, lK = { "LeftLowerLeg", "LeftKnee" },
    }

    local function makeActor(cf: CFrame, role: string): any
        local model: Model
        if #cloneSources > 0 then
            model = cloneSources[math.random(#cloneSources)]:Clone()
        else
            model = Instance.new("Model")
            local r = newPart("HumanoidRootPart", Vector3.new(2,2,1), cf, Color3.fromRGB(60,60,70))
            r.Transparency = 1; r.Parent = model
            newPart("UpperTorso", Vector3.new(2,2,1), cf * CFrame.new(0,0.1,0), Color3.fromRGB(40,90,170)).Parent = model
            newPart("Head", Vector3.new(1.2,1.2,1.2), cf * CFrame.new(0,1.6,0), Color3.fromRGB(224,188,158)).Parent = model
            model.PrimaryPart = r
            Instance.new("Humanoid").Parent = model
        end
        for _, d in model:GetDescendants() do
            if d:IsA("LuaSourceContainer") or d:IsA("ProximityPrompt") or d:IsA("BillboardGui") or d:IsA("Sound") or d:IsA("Shirt") or d:IsA("Pants") or d:IsA("ShirtGraphic") then
                d:Destroy()
            elseif d:IsA("BasePart") then
                d.Anchored = false; d.CanCollide = false; d.CanQuery = false; d.CastShadow = false; d.Massless = true
            end
        end
        local HOODIE = { Color3.fromRGB(40,80,150), Color3.fromRGB(45,120,75), Color3.fromRGB(120,55,140), Color3.fromRGB(165,90,45), Color3.fromRGB(55,105,120), Color3.fromRGB(95,95,110) }
        local SKIN = { Color3.fromRGB(235,200,170), Color3.fromRGB(205,165,125), Color3.fromRGB(160,115,85) }
        local hoodie = HOODIE[math.random(#HOODIE)]
        local skin = SKIN[math.random(#SKIN)]
        local pants = Color3.fromRGB(45,48,58)
        local function paint(names: { string }, col: Color3)
            for _, n in names do local pt = model:FindFirstChild(n); if pt and pt:IsA("BasePart") then pt.Color = col; pt.Material = Enum.Material.SmoothPlastic end end
        end
        paint({ "UpperTorso","LowerTorso","LeftUpperArm","LeftLowerArm","RightUpperArm","RightLowerArm" }, hoodie)
        paint({ "Head","LeftHand","RightHand" }, skin)
        paint({ "LeftUpperLeg","LeftLowerLeg","LeftFoot","RightUpperLeg","RightLowerLeg","RightFoot" }, pants)

        -- CreateHumanoidModelFromDescription rigs carry RigAttachments but no
        -- Motor6Ds; clones never get assembled, so build the R15 joints ourselves.
        if not model:FindFirstChildWhichIsA("Motor6D", true) then
            local JOINT_DEFS = {
                { "Root","HumanoidRootPart","LowerTorso","RootRigAttachment" },
                { "Waist","LowerTorso","UpperTorso","WaistRigAttachment" },
                { "Neck","UpperTorso","Head","NeckRigAttachment" },
                { "RightShoulder","UpperTorso","RightUpperArm","RightShoulderRigAttachment" },
                { "RightElbow","RightUpperArm","RightLowerArm","RightElbowRigAttachment" },
                { "RightWrist","RightLowerArm","RightHand","RightWristRigAttachment" },
                { "LeftShoulder","UpperTorso","LeftUpperArm","LeftShoulderRigAttachment" },
                { "LeftElbow","LeftUpperArm","LeftLowerArm","LeftElbowRigAttachment" },
                { "LeftWrist","LeftLowerArm","LeftHand","LeftWristRigAttachment" },
                { "RightHip","LowerTorso","RightUpperLeg","RightHipRigAttachment" },
                { "RightKnee","RightUpperLeg","RightLowerLeg","RightKneeRigAttachment" },
                { "RightAnkle","RightLowerLeg","RightFoot","RightAnkleRigAttachment" },
                { "LeftHip","LowerTorso","LeftUpperLeg","LeftHipRigAttachment" },
                { "LeftKnee","LeftUpperLeg","LeftLowerLeg","LeftKneeRigAttachment" },
                { "LeftAnkle","LeftLowerLeg","LeftFoot","LeftAnkleRigAttachment" },
            }
            for _, j in JOINT_DEFS do
                local p0 = model:FindFirstChild(j[2]); local p1 = model:FindFirstChild(j[3])
                local a0 = p0 and p0:FindFirstChild(j[4]); local a1 = p1 and p1:FindFirstChild(j[4])
                if p0 and p1 and a0 and a1 then
                    local mt = Instance.new("Motor6D")
                    mt.Name = j[1]; mt.Part0 = p0; mt.Part1 = p1; mt.C0 = a0.CFrame; mt.C1 = a1.CFrame; mt.Parent = p1
                end
            end
        end

        local hum = model:FindFirstChildOfClass("Humanoid")
        if hum then
            hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
            hum.AutoRotate = false
            hum.BreakJointsOnDeath = false
        end
        model.Name = "Actor"
        model:PivotTo(cf)
        local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
        if root then root.Anchored = true end
        model.Parent = set

        local actor: any = {
            model = model, root = root, head = model:FindFirstChild("Head"),
            facing = cf.LookVector, right = cf.RightVector, role = role,
            phase = math.random() * 6.283, J = {}, base = {},
        }
        for key, names in JOINTS do
            local mt = motorOf(model, names[1], names[2])
            if mt then actor.J[key] = mt; actor.base[key] = mt.C0 end
        end
        local function bend(key: string, ang: CFrame)
            local mt = actor.J[key]
            if mt then mt.C0 = actor.base[key] * ang end
        end
        actor.bend = bend
        function actor.setPivot(p: CFrame)
            actor.model:PivotTo(p)
            if root then root.Anchored = true end
            actor.facing = p.LookVector; actor.right = p.RightVector
            actor.head = actor.model:FindFirstChild("Head")
        end

        if role == "slam" or role == "headshake" then
            bend("rH", CFrame.Angles(math.rad(-80),0,0)); bend("lH", CFrame.Angles(math.rad(-80),0,0))
            bend("rK", CFrame.Angles(math.rad(86),0,0)); bend("lK", CFrame.Angles(math.rad(86),0,0))
        end
        if role == "slam" then
            -- hunched at the keyboard, repeatedly slamming both fists on the desk
            bend("waist", CFrame.Angles(math.rad(16),0,0))
            bend("rE", CFrame.Angles(math.rad(-42),0,0)); bend("lE", CFrame.Angles(math.rad(-42),0,0))
            actor.update = function(t)
                local down = math.sin(t*5 + actor.phase) > 0.5
                local s = down and 80 or 32
                bend("rS", CFrame.Angles(math.rad(s),0,math.rad(-6))); bend("lS", CFrame.Angles(math.rad(s),0,math.rad(6)))
                bend("neck", CFrame.Angles(math.rad(down and 30 or 10),0,0))
                bend("waist", CFrame.Angles(math.rad(down and 26 or 14),0,0))
            end
        elseif role == "headshake" then
            -- face buried in hands, shaking their head "no, no, no"
            bend("waist", CFrame.Angles(math.rad(30),0,0))
            bend("rS", CFrame.Angles(math.rad(116),0,math.rad(-14))); bend("lS", CFrame.Angles(math.rad(116),0,math.rad(14)))
            bend("rE", CFrame.Angles(math.rad(-104),0,0)); bend("lE", CFrame.Angles(math.rad(-104),0,0))
            actor.update = function(t)
                local shake = math.sin(t*9 + actor.phase)
                bend("neck", CFrame.Angles(math.rad(22), math.rad(22)*shake, math.rad(7)*shake))
                bend("waist", CFrame.Angles(math.rad(30)+math.rad(3)*math.sin(t*4), math.rad(4)*shake, 0))
            end
        elseif role == "hair" then
            -- both hands clutching and yanking at their hair, head thrashing
            bend("rE", CFrame.Angles(math.rad(-108),0,0)); bend("lE", CFrame.Angles(math.rad(-108),0,0))
            actor.update = function(t)
                local yank = math.sin(t*7 + actor.phase)
                local jit = math.sin(t*23 + actor.phase) * math.rad(6)
                local s = math.rad(112) + math.rad(12)*yank + jit
                bend("rS", CFrame.Angles(s,0,math.rad(-28))); bend("lS", CFrame.Angles(s,0,math.rad(28)))
                bend("neck", CFrame.Angles(math.rad(-4)+math.rad(10)*yank, math.rad(11)*math.sin(t*5), 0))
                bend("waist", CFrame.Angles(math.rad(7)*math.abs(yank),0,0))
            end
        elseif role == "pace" then
            bend("rS", CFrame.Angles(math.rad(150),0,math.rad(-18))); bend("lS", CFrame.Angles(math.rad(150),0,math.rad(18)))
            bend("rE", CFrame.Angles(math.rad(-106),0,0)); bend("lE", CFrame.Angles(math.rad(-106),0,0))
            bend("waist", CFrame.Angles(math.rad(12),0,0))
            actor.update = function(t)
                if actor.a and actor.b then
                    local u = math.sin(t*actor.speed)*0.5+0.5
                    local pos = (actor.a :: Vector3):Lerp(actor.b :: Vector3, u)
                    local dir = (actor.b :: Vector3) - (actor.a :: Vector3)
                    local f = (math.cos(t*actor.speed) >= 0) and dir or -dir
                    f = Vector3.new(f.X,0,f.Z); if f.Magnitude < 0.01 then f = Vector3.new(0,0,1) end
                    local bobY = math.abs(math.sin(t*actor.speed*6))*0.18
                    local p = pos + Vector3.new(0,bobY,0)
                    actor.setPivot(CFrame.lookAt(p, p + f.Unit))
                end
                local sw = math.rad(30)*math.sin(t*(actor.speed or 1)*6 + actor.phase)
                bend("rH", CFrame.Angles(sw,0,0)); bend("lH", CFrame.Angles(-sw,0,0))
                bend("neck", CFrame.Angles(0, math.rad(10)*math.sin(t*3 + actor.phase), 0))
            end
        end
        return actor
    end

    local function ngmify(actor: any)
        for _, d in actor.model:GetDescendants() do
            if d:IsA("BasePart") then d.Color = NGMI_BODY; d.Material = Enum.Material.SmoothPlastic
            elseif d:IsA("Decal") or d:IsA("Texture") or d:IsA("Shirt") or d:IsA("Pants") or d:IsA("ShirtGraphic") then d:Destroy() end
        end
        local head = actor.model:FindFirstChild("Head") :: BasePart?
        if head then
            for _, sx in { -0.3, 0.3 } do
                local eye = Instance.new("Part")
                eye.Name = "Eye"; eye.Shape = Enum.PartType.Ball; eye.Size = Vector3.new(0.26,0.26,0.26)
                eye.Anchored = false; eye.CanCollide = false; eye.CanQuery = false; eye.Massless = true; eye.CastShadow = false
                eye.Color = Color3.fromRGB(255,0,0); eye.Material = Enum.Material.Neon
                eye.CFrame = head.CFrame * CFrame.new(sx, 0.12, -0.62); eye.Parent = actor.model
                local w = Instance.new("WeldConstraint"); w.Part0 = head; w.Part1 = eye; w.Parent = eye
            end
            local glow = Instance.new("PointLight"); glow.Color = Color3.fromRGB(255,0,0); glow.Brightness = 3; glow.Range = 9; glow.Parent = head
        end
        local torso = actor.model:FindFirstChild("UpperTorso") or actor.model:FindFirstChild("Torso")
        if torso and torso:IsA("BasePart") then
            local emit = Instance.new("ParticleEmitter")
            emit.Color = ColorSequence.new(Color3.fromRGB(80,20,120), Color3.fromRGB(20,0,30))
            emit.Size = NumberSequence.new(0.3,1.2); emit.Transparency = NumberSequence.new(0.4,1)
            emit.Lifetime = NumberRange.new(1.2,2.4); emit.Rate = 14; emit.Speed = NumberRange.new(0.5,2)
            emit.SpreadAngle = Vector2.new(180,180); emit.Parent = torso
        end
    end

    local function addDesk(actorPos: Vector3, code: string)
        newPart("Desk", Vector3.new(4.4,0.2,2), CFrame.new(actorPos + Vector3.new(0,-0.7,1.7)), Color3.fromRGB(58,53,62))
        local screenPos = actorPos + Vector3.new(0,0.5,2.5)
        local screen = newPart("Screen", Vector3.new(2.6,1.6,0.1), CFrame.lookAt(screenPos, actorPos + Vector3.new(0,0.4,0)), Color3.fromRGB(16,12,16), Enum.Material.Neon)
        local sg = Instance.new("SurfaceGui"); sg.Face = Enum.NormalId.Front; sg.CanvasSize = Vector2.new(320,200); sg.Parent = screen
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1,0,1,0); lbl.BackgroundColor3 = Color3.fromRGB(10,6,9); lbl.Font = Enum.Font.Code
        lbl.TextColor3 = Color3.fromRGB(255,70,70); lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.TextYAlignment = Enum.TextYAlignment.Top
        lbl.TextWrapped = true; lbl.TextSize = 15; lbl.Text = code; lbl.Parent = sg
        local face = Instance.new("PointLight"); face.Color = Color3.fromRGB(255,120,110); face.Brightness = 0.7; face.Range = 12; face.Parent = screen
    end

    local function headOf(rig: any): BasePart?
        local h = rig.head
        if h and h:IsA("BasePart") then return h end
        h = rig.model and rig.model:FindFirstChild("Head")
        if h and h:IsA("BasePart") then rig.head = h; return h end
        return nil
    end
    local function cutToFace(rig: any, sideways: number, dist: number)
        local head = headOf(rig)
        local headPos = head and head.Position or (rig.model:GetPivot().Position + Vector3.new(0, 2.2, 0))
        local target = headPos - Vector3.new(0,0.5,0)
        local pos = headPos + rig.facing*dist + rig.right*sideways + Vector3.new(0,0.7,0)
        camera.CFrame = CFrame.lookAt(pos, target)
    end
    local function startCamShake(intensity: number): RBXScriptConnection
        local baseCF = camera.CFrame
        return RunService.RenderStepped:Connect(function()
            camera.CFrame = baseCF * CFrame.Angles(math.rad((math.random()-0.5)*intensity), math.rad((math.random()-0.5)*intensity), math.rad((math.random()-0.5)*intensity))
        end)
    end
    local function startSpaz(actor: any, intensity: number): RBXScriptConnection
        actor.update = nil
        return RunService.Heartbeat:Connect(function()
            for key, baseC0 in actor.base do
                local mt = actor.J[key]
                if mt then mt.C0 = baseC0 * CFrame.Angles(math.rad((math.random()-0.5)*intensity), math.rad((math.random()-0.5)*intensity), math.rad((math.random()-0.5)*intensity)) end
            end
        end)
    end

    -- A lab room that matches the venue: light walls, wood floor, warm ceiling
    -- lights, desks + monitors, a window, and a doorway through to a short
    -- hallway the mutated hackers shamble out into.
    local WALL = Color3.fromRGB(216, 216, 222)
    local FLOORC = Color3.fromRGB(139, 90, 43)
    local CEIL = Color3.fromRGB(232, 232, 236)
    local centerX = BASE.X
    local floorTop = BASE.Y + 0.2
    local standY = floorTop + 2.9
    local seatY = floorTop + 2.4
    local backZ = BASE.Z - 20
    local frontZ = BASE.Z + 20
    local wallY = BASE.Y + 6
    newPart("Floor", Vector3.new(50, 0.4, 40), CFrame.new(centerX, floorTop - 0.2, BASE.Z), FLOORC, Enum.Material.WoodPlanks)
    newPart("Ceiling", Vector3.new(50, 0.4, 40), CFrame.new(centerX, BASE.Y + 12, BASE.Z), CEIL)
    newPart("WallL", Vector3.new(0.6, 12, 40), CFrame.new(centerX - 25, wallY, BASE.Z), WALL)
    newPart("WallR", Vector3.new(0.6, 12, 40), CFrame.new(centerX + 25, wallY, BASE.Z), WALL)
    newPart("WallF", Vector3.new(50, 12, 0.6), CFrame.new(centerX, wallY, frontZ), WALL)
    newPart("WallB1", Vector3.new(21, 12, 0.6), CFrame.new(centerX - 14.5, wallY, backZ), WALL)
    newPart("WallB2", Vector3.new(21, 12, 0.6), CFrame.new(centerX + 14.5, wallY, backZ), WALL)
    newPart("WallBTop", Vector3.new(8, 3, 0.6), CFrame.new(centerX, BASE.Y + 10.5, backZ), WALL)
    newPart("Window", Vector3.new(0.3, 5, 8), CFrame.new(centerX + 24.7, BASE.Y + 6, BASE.Z + 6), Color3.fromRGB(28, 33, 48), Enum.Material.Glass)
    local skyLight = newPart("Sky", Vector3.new(0.2, 5, 8), CFrame.new(centerX + 25.6, BASE.Y + 6, BASE.Z + 6), Color3.fromRGB(20, 25, 40), Enum.Material.Neon)
    skyLight.Transparency = 1
    local skyPL = Instance.new("PointLight"); skyPL.Color = Color3.fromRGB(150,170,255); skyPL.Brightness = 0; skyPL.Range = 34; skyPL.Parent = skyLight
    for _, cx in { -14, 0, 14 } do
        for _, cz in { -8, 8 } do
            local fix = newPart("CeilLight", Vector3.new(4, 0.3, 2), CFrame.new(centerX + cx, BASE.Y + 11.6, BASE.Z + cz), Color3.fromRGB(255, 245, 225), Enum.Material.Neon)
            local pl = Instance.new("PointLight"); pl.Color = Color3.fromRGB(255, 240, 215); pl.Brightness = 1.6; pl.Range = 26; pl.Parent = fix
        end
    end

    local cast: { any } = {}
    local function facing(pos: Vector3): CFrame return CFrame.lookAt(pos, pos + Vector3.new(0,0,1)) end
    local slamPos = Vector3.new(centerX - 12, seatY, BASE.Z - 3)
    local slammer = makeActor(facing(slamPos), "slam")
    addDesk(slamPos, "$ make\nundefined reference\nundefined reference\n  187 errors\nbuild FAILED")
    local shakePos = Vector3.new(centerX - 3, seatY, BASE.Z - 4)
    local shaker = makeActor(facing(shakePos), "headshake")
    addDesk(shakePos, "Traceback (most recent call last)\n  File main.py, line 42\nSyntaxError: invalid syntax\nSyntaxError")
    local rager = makeActor(facing(Vector3.new(centerX + 7, standY, BASE.Z - 2)), "hair")
    local pacer = makeActor(facing(Vector3.new(centerX + 15, standY, BASE.Z - 3)), "pace")
    pacer.a = Vector3.new(centerX + 12, standY, BASE.Z - 7); pacer.b = Vector3.new(centerX + 18, standY, BASE.Z + 3); pacer.speed = 0.9
    local victim = makeActor(facing(Vector3.new(centerX, standY, BASE.Z + 5)), "hair")
    table.insert(cast, slammer); table.insert(cast, shaker); table.insert(cast, rager); table.insert(cast, pacer); table.insert(cast, victim)

    local animClock = os.clock()
    table.insert(conns, RunService.Heartbeat:Connect(function()
        local t = os.clock() - animClock
        for _, a in cast do if a.update then pcall(a.update, t) end end
    end))

    -- a short hallway through the back doorway, for the exit shot
    newPart("HallFloor", Vector3.new(10, 0.4, 30), CFrame.new(centerX, floorTop - 0.2, backZ - 15), Color3.fromRGB(120, 124, 130), Enum.Material.Concrete)
    newPart("HallCeil", Vector3.new(10, 0.4, 30), CFrame.new(centerX, BASE.Y + 10, backZ - 15), CEIL)
    newPart("HallWallL", Vector3.new(0.6, 10, 30), CFrame.new(centerX - 5, BASE.Y + 5, backZ - 15), WALL)
    newPart("HallWallR", Vector3.new(0.6, 10, 30), CFrame.new(centerX + 5, BASE.Y + 5, backZ - 15), WALL)
    for hz = backZ - 4, backZ - 28, -8 do
        local fix = newPart("HallLight", Vector3.new(2, 0.3, 2), CFrame.new(centerX, BASE.Y + 9.6, hz), Color3.fromRGB(255, 245, 225), Enum.Material.Neon)
        local pl = Instance.new("PointLight"); pl.Color = Color3.fromRGB(255, 240, 215); pl.Brightness = 1.4; pl.Range = 16; pl.Parent = fix
    end

    -- TIMELINE
    task.wait(0.4)
    showThought("My eyes are burning... I can't even read the screen anymore.", 2.8)
    showThought("I'll just rest them for a few minutes. Just a few...", 2.8)

    TweenService:Create(bg, TweenInfo.new(1.5, Enum.EasingStyle.Quad), { BackgroundTransparency = 0 }):Play()
    task.wait(1.6)
    camera.CameraType = Enum.CameraType.Scriptable
    -- Hold the scriptable camera for the whole cutscene: the camera controller
    -- otherwise reclaims it (back to first-person) the instant NIGHT2 begins, so
    -- the back half ("one by one...") would cut to the player's POV.
    table.insert(conns, RunService.RenderStepped:Connect(function()
        if camera.CameraType ~= Enum.CameraType.Scriptable then
            camera.CameraType = Enum.CameraType.Scriptable
        end
    end))

    for _, d in workspace:GetDescendants() do
        if d:IsA("BillboardGui") and d.Name == "DeskBeaconLabel" and d.Enabled then d.Enabled = false; table.insert(hiddenBillboards, d) end
    end

    local Lighting = game:GetService("Lighting")
    local function setCC(b: number, c: number, s: number, tint: Color3)
        local cc = Lighting:FindFirstChild("GameColorCorrection") or Lighting:FindFirstChildOfClass("ColorCorrectionEffect")
        if cc and cc:IsA("ColorCorrectionEffect") then cc.Brightness = b; cc.Contrast = c; cc.Saturation = s; cc.TintColor = tint end
    end
    local lightOverride = RunService.RenderStepped:Connect(function()
        Lighting.Ambient = Color3.fromRGB(84,82,80); Lighting.OutdoorAmbient = Color3.fromRGB(84,82,80)
        Lighting.Brightness = 1.6; Lighting.ClockTime = 14; Lighting.FogStart = 0; Lighting.FogEnd = 1e6
        setCC(0,0,0,Color3.new(1,1,1))
        local blur = Lighting:FindFirstChild("GameBlur"); if blur and blur:IsA("BlurEffect") then blur.Size = 0 end
        local bloom = Lighting:FindFirstChild("GameBloom") or Lighting:FindFirstChildOfClass("BloomEffect"); if bloom and bloom:IsA("BloomEffect") then bloom.Intensity = 0 end
    end)
    table.insert(conns, lightOverride)

    local BAR_H = 0.12
    TweenService:Create(topBar, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.new(1,0,BAR_H,0) }):Play()
    TweenService:Create(botBar, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.new(1,0,BAR_H,0) }):Play()

    camera.CFrame = CFrame.lookAt(Vector3.new(centerX, standY + 3, BASE.Z + 18), Vector3.new(centerX, standY - 0.5, BASE.Z - 6))
    TweenService:Create(bg, TweenInfo.new(1.2, Enum.EasingStyle.Quad), { BackgroundTransparency = 1 }):Play()
    task.wait(0.4)
    showCaption("As the hours pass, everyone frantically tries to finish their projects.", 3.4)

    cutToFace(slammer, 0.9, 4.0)
    showCaption('"Why won\'t it compile? WHY won\'t it compile?!"', 2.6)
    cutToFace(shaker, -0.9, 3.8)
    showCaption('"Three hundred errors... I can\'t even look anymore."', 2.6)
    cutToFace(rager, 0.6, 4.2)
    showCaption('"There\'s no way. There\'s no way I finish in time!"', 2.6)
    camera.CFrame = CFrame.lookAt(Vector3.new(centerX + 24, standY + 1.5, BASE.Z + 4), Vector3.new(centerX + 14, standY - 0.3, BASE.Z - 3))
    showCaption('"I can\'t do this. I can\'t, I can\'t, I can\'t..."', 2.6)

    -- (5) Close-up of the last hacker breaking — the line, with the screen shaking.
    cutToFace(victim, 0.4, 3.6)
    showCaption('"No. No, no, no, no—"', 1.6)
    local climaxShake = startCamShake(1.7)
    showCaption('"I\'m... I\'m NOT GONNA MAKE IT!!"', 1.8)

    -- (6) They convulse and mutate into an NGMI, right there in the room.
    local spazConn = startSpaz(victim, 26)
    task.wait(1.5)
    spazConn:Disconnect(); climaxShake:Disconnect()
    for key, baseC0 in victim.base do local mt = victim.J[key]; if mt then mt.C0 = baseC0 end end
    ngmify(victim)
    lightningFlash(0.7)

    -- (7) One by one the rest of the room turns; then the NGMIs rise and shamble
    --     out the back doorway into the hallway.
    camera.CFrame = CFrame.lookAt(Vector3.new(centerX, standY + 3, BASE.Z + 18), Vector3.new(centerX, standY - 0.5, BASE.Z - 6))
    showCaption("One by one, they stop being hackers.", 1.0)
    for _, a in { slammer, shaker, rager, pacer } do
        a.update = nil
        ngmify(a)
        task.wait(0.5)
    end
    task.wait(0.5)

    local exits = {}
    local lanes = { 0, -2, 2, -3.4, 3.4 }
    for i, a in { victim, rager, pacer, slammer, shaker } do
        for key, baseC0 in a.base do local mt = a.J[key]; if mt then mt.C0 = baseC0 end end
        local p = a.model:GetPivot().Position
        table.insert(exits, { a = a, start = Vector3.new(p.X, standY, p.Z), lane = lanes[i], delay = (i - 1) * 0.45 })
    end
    local walkStart = os.clock()
    local walkConn = RunService.Heartbeat:Connect(function()
        local now = os.clock() - walkStart
        for _, e in exits do
            local t = now - e.delay
            if t > 0 then
                local a = e.a
                local door = Vector3.new(centerX + e.lane, standY, backZ + 2)
                local hall = Vector3.new(centerX + e.lane, standY, backZ - 24)
                local d1 = door - e.start
                local seg1 = d1.Magnitude
                local dist = t * 4.5
                local pos, dir
                if dist < seg1 then pos = e.start + d1.Unit * dist; dir = d1
                else local d2 = hall - door; pos = door + d2.Unit * math.min(dist - seg1, d2.Magnitude); dir = d2 end
                dir = Vector3.new(dir.X, 0, dir.Z); if dir.Magnitude < 0.01 then dir = Vector3.new(0,0,-1) end
                local bob = math.abs(math.sin((now + a.phase) * 5)) * 0.14
                a.setPivot(CFrame.lookAt(pos + Vector3.new(0, bob, 0), pos + Vector3.new(0, bob, 0) + dir.Unit))
                local sw = math.rad(24) * math.sin(now * 5 + a.phase)
                a.bend("rH", CFrame.Angles(sw,0,0)); a.bend("lH", CFrame.Angles(-sw,0,0))
                a.bend("rS", CFrame.Angles(math.rad(22)+math.rad(6)*math.sin(now*5),0,0)); a.bend("lS", CFrame.Angles(math.rad(22)-math.rad(6)*math.sin(now*5),0,0))
            end
        end
    end)
    table.insert(conns, walkConn)
    task.wait(0.4)
    camera.CFrame = CFrame.lookAt(Vector3.new(centerX, standY + 2.4, BASE.Z + 6), Vector3.new(centerX, standY - 0.2, backZ - 8))
    task.wait(3.6)

    -- (8) Lightning through the window — then the power dies.
    skyPL.Brightness = 9; lightningFlash(1)
    task.wait(0.12); skyPL.Brightness = 0; task.wait(0.18)
    skyPL.Brightness = 11; lightningFlash(1)
    local powerShake = startCamShake(3)
    task.wait(0.16); skyPL.Brightness = 0
    task.wait(0.2)
    bg.BackgroundTransparency = 0
    lightOverride:Disconnect()
    do
        local ok, LightingProfiles = pcall(require, ReplicatedStorage:WaitForChild("Shared"):WaitForChild("LightingProfiles"))
        local p = ok and LightingProfiles and LightingProfiles.getProfile("Night2_Horror")
        if p then
            Lighting.Ambient = p.Ambient; Lighting.OutdoorAmbient = p.OutdoorAmbient; Lighting.Brightness = p.Brightness
            Lighting.ClockTime = p.ClockTime; Lighting.FogColor = p.FogColor; Lighting.FogEnd = p.FogEnd; Lighting.FogStart = p.FogStart
            local cc = p.PostProcessing and p.PostProcessing.ColorCorrection
            if cc then setCC(cc.Brightness, cc.Contrast, cc.Saturation, cc.TintColor) end
            local b = p.PostProcessing and p.PostProcessing.Bloom
            local bloom = Lighting:FindFirstChild("GameBloom") or Lighting:FindFirstChildOfClass("BloomEffect")
            if b and bloom and bloom:IsA("BloomEffect") then bloom.Intensity = b.Intensity; bloom.Size = b.Size; bloom.Threshold = b.Threshold end
        end
    end
    for _, d in set:GetDescendants() do if d:IsA("PointLight") then d.Enabled = false end end
    for _, p in set:GetDescendants() do if p:IsA("BasePart") and p.Material == Enum.Material.Neon then p.Material = Enum.Material.SmoothPlastic end end
    walkConn:Disconnect()
    task.wait(0.4)
    powerShake:Disconnect()
    task.wait(0.9)

    local char = player.Character
    local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
    local humanoid = char and char:FindFirstChildOfClass("Humanoid")
    local basePos = root and root.Position or camera.CFrame.Position
    local fwd = root and root.CFrame.LookVector or camera.CFrame.LookVector
    fwd = Vector3.new(fwd.X, 0, fwd.Z); if fwd.Magnitude < 0.01 then fwd = Vector3.new(0,0,-1) end
    fwd = fwd.Unit
    local floorY = basePos.Y - 2.6
    local lieCF = CFrame.lookAt(Vector3.new(basePos.X, floorY + 0.7, basePos.Z) - fwd*0.4, Vector3.new(basePos.X, floorY + 1.4, basePos.Z) + fwd*2) * CFrame.Angles(0,0,math.rad(20))
    local standEye = Vector3.new(basePos.X, basePos.Y + 1.4, basePos.Z)
    local standCF = CFrame.lookAt(standEye, standEye + fwd)
    camera.CFrame = lieCF

    local function setLids(closed: number, dur: number)
        local h = 0.12 + (0.5 - 0.12) * closed
        TweenService:Create(topBar, TweenInfo.new(dur, Enum.EasingStyle.Sine), { Size = UDim2.new(1,0,h,0) }):Play()
        TweenService:Create(botBar, TweenInfo.new(dur, Enum.EasingStyle.Sine), { Size = UDim2.new(1,0,h,0) }):Play()
    end
    setLids(1, 0)
    bg.BackgroundTransparency = 0
    task.wait(0.6)
    TweenService:Create(bg, TweenInfo.new(0.5), { BackgroundTransparency = 0.25 }):Play()
    setLids(0.55, 0.5)
    task.wait(0.7)
    setLids(0.9, 0.16); task.wait(0.18)
    setLids(0.4, 0.22); task.wait(0.6)
    setLids(0.85, 0.15); task.wait(0.16)
    setLids(0, 0.35); task.wait(0.5)

    showThought("Wha—? The... the power's out.", 2.3)
    showThought("I have to get up. I have to get the power running again.", 2.6)

    TweenService:Create(camera, TweenInfo.new(1.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = standCF }):Play()
    task.wait(1.1)
    showThought("...and finish my project.", 1.8)
    task.wait(0.4)

    TweenService:Create(topBar, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Size = UDim2.new(1,0,0,0) }):Play()
    TweenService:Create(botBar, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Size = UDim2.new(1,0,0,0) }):Play()
    TweenService:Create(bg, TweenInfo.new(1.0, Enum.EasingStyle.Quad), { BackgroundTransparency = 1 }):Play()
    task.wait(1.05)

    for _, c in conns do c:Disconnect() end
    set:Destroy(); gui:Destroy()
    camera.CameraType = Enum.CameraType.Custom
    if humanoid then camera.CameraSubject = humanoid end
    ProximityPromptService.Enabled = true
    for _, g in hiddenGuis do if g.Parent and g.Name ~= "LobbyGui" then g.Enabled = true end end
    for _, b in hiddenBillboards do if b.Parent then b.Enabled = true end end
    enableControls()
end

-- ============================================================
-- EVENT LISTENERS
-- ============================================================
CutsceneTrigger.OnClientEvent:Connect(function(data: { cutscene: string })
    if data.cutscene == "sleep" then
        playSleepCutscene()
    elseif data.cutscene == "opening" then
        playOpeningCutscene(data :: any)
    elseif data.cutscene == "nightTransition" then
        playNightTransition()
    end
end)

EndingTrigger.OnClientEvent:Connect(function(data: { ending: string })
    if data.ending == "bad" then
        playBadEnding()
    elseif data.ending == "true" or data.ending == "good" then
        playTrueEnding()
    end
end)

print("[CutsceneManager] Initialized - sleep, night transition, bad ending, and true ending cutscenes ready")
