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
local ReplicatedStorage = game:GetService("ReplicatedStorage")
-- Lighting was previously fetched ad hoc inside individual scene functions; the
-- shared cinematic helpers below need it at module scope.
local Lighting = game:GetService("Lighting")

local CursorManager = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CursorManager"))
local UITheme = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UITheme"))
local Shared = ReplicatedStorage:WaitForChild("Shared")
local RigPose = require(Shared:WaitForChild("RigPose"))
local CutsceneActors = require(Shared:WaitForChild("CutsceneActors"))
local NGMIMutation = require(Shared:WaitForChild("NGMIMutation"))
local NGMIChoreo = require(Shared:WaitForChild("NGMIChoreo"))
local OpeningCinematic = require(Shared:WaitForChild("OpeningCinematic"))

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
    -- Route through the shared CursorManager: its per-frame guard holds the cursor
    -- free for as long as the scene is open, so a first-person re-lock can't trap it.
    CursorManager.push()
end

--- Partner to unlockCursor. MUST be called once for every unlockCursor, at the
--- point the scene actually closes.
---
--- CursorManager is reference-counted and its per-frame guard keeps the cursor
--- free for as long as openCount > 0. An unbalanced push therefore doesn't just
--- leak a counter: it pins the camera in third person at zoom 10-16 and leaves
--- the mouse free for the REST OF THE SESSION, so gameplay never returns to
--- LockFirstPerson.
local function relockCursor()
    CursorManager.pop()
end

-- ============================================================
-- CINEMATIC CAMERA
-- ============================================================
-- Shared rig for every cutscene beat: Cubic camera paths, lens FOV pulls, and a
-- motion blur that is driven from the SAME tween clock as the move, so the blur
-- ramps with the camera instead of drifting out of sync with it.
--
-- The blur instance is private to this module (CutsceneBlur). LightingController
-- owns GameBlur for the phase look and NGMIClient owns NGMIProximityBlur, so
-- reusing either here would fight those systems mid-scene.
local DEFAULT_FOV = 70

local cutsceneBlur: BlurEffect? = nil

local function getCutsceneBlur(): BlurEffect
    local existing = Lighting:FindFirstChild("CutsceneBlur")
    if existing and existing:IsA("BlurEffect") then
        return existing
    end
    local b = Instance.new("BlurEffect")
    b.Name = "CutsceneBlur"
    b.Size = 0
    b.Parent = Lighting
    cutsceneBlur = b
    return b
end

--- Ease the camera along a path to `goal` over `duration`.
--- Cubic InOut is the house easing for cutscene moves: it leaves and arrives
--- almost stationary, which reads as a camera operator rather than a lerp.
local function cameraMove(goal: CFrame, duration: number, direction: Enum.EasingDirection?): Tween
    camera.CameraType = Enum.CameraType.Scriptable
    local info = TweenInfo.new(
        duration,
        Enum.EasingStyle.Cubic,
        direction or Enum.EasingDirection.InOut
    )
    local tween = TweenService:Create(camera, info, { CFrame = goal })
    tween:Play()
    return tween
end

--- Lens pull. A slow push-in tightens the frame; a fast one snaps focus onto a
--- reveal. Runs on the same Cubic curve as the camera move so a simultaneous
--- move + pull feel like one gesture.
local function fovPull(targetFov: number, duration: number, direction: Enum.EasingDirection?): Tween
    local info = TweenInfo.new(
        duration,
        Enum.EasingStyle.Cubic,
        direction or Enum.EasingDirection.InOut
    )
    local tween = TweenService:Create(camera, info, { FieldOfView = targetFov })
    tween:Play()
    return tween
end

--- Motion blur ramp, matched to a move's duration so the two stay locked.
local function motionBlur(size: number, duration: number): Tween
    local blur = getCutsceneBlur()
    local info = TweenInfo.new(duration, Enum.EasingStyle.Cubic, Enum.EasingDirection.InOut)
    local tween = TweenService:Create(blur, info, { Size = size })
    tween:Play()
    return tween
end

--- Put the lens back where gameplay expects it. Called at every scene teardown
--- alongside restoring CameraType, so a cutscene can never strand the player on
--- a 40-degree FOV or a blurred frame.
local function resetLens()
    TweenService:Create(camera, TweenInfo.new(0.4, Enum.EasingStyle.Cubic), { FieldOfView = DEFAULT_FOV }):Play()
    local blur = cutsceneBlur or Lighting:FindFirstChild("CutsceneBlur")
    if blur and blur:IsA("BlurEffect") then
        TweenService:Create(blur, TweenInfo.new(0.4), { Size = 0 }):Play()
    end
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
    label.FontFace = if font then Font.fromEnum(font) else UITheme.Font.Bold
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
    thought.FontFace = UITheme.Font.Regular
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
    -- The lens creeps in as consciousness narrows; resetLens on waking puts it back.
    fovPull(54, 6)
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
    resetLens()
    enableControls()
end

-- ============================================================
-- ENDING SCREEN TEARDOWN
-- ============================================================
-- Both endings free the cursor for their "Return to Lobby" button, so every way
-- off the screen has to release it, not just that button: the button's
-- requestLobby (server/LobbyReturn) and any phase change (a new match, the
-- lobby, an admin skip) are the exits. A leaked push pins the camera in third person
-- for the rest of the session.
local closeEnding: (() -> ())? = nil

--- Take the cursor for an ending screen and return its one-shot close.
local function openEndingScreen(gui: ScreenGui): () -> ()
    if closeEnding then
        closeEnding() -- a second ending replaces the first
    end
    unlockCursor()
    local closed = false
    local function close()
        if closed then
            return
        end
        closed = true
        if closeEnding == close then
            closeEnding = nil
        end
        gui:Destroy()
        relockCursor()
        resetLens()
        camera.CameraType = Enum.CameraType.Custom
        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        if humanoid then
            camera.CameraSubject = humanoid
        end
        enableControls()
    end
    closeEnding = close
    return close
end

GameStateChanged.OnClientEvent:Connect(function(data: { phase: number })
    if typeof(data) == "table" and data.phase ~= 4 and closeEnding then
        closeEnding()
    end
end)

-- ============================================================
-- BAD ENDING
-- ============================================================
local function playBadEnding()
    disableControls()

    camera.CameraType = Enum.CameraType.Scriptable
    -- Long, slow constriction across the whole ending: the frame closes in on a
    -- player who didn't make it.
    camera.FieldOfView = DEFAULT_FOV
    fovPull(52, 12)

    local gui, bg = createOverlayGui("BadEnding")
    local closeScreen = openEndingScreen(gui)

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
    ngmiText.FontFace = UITheme.Font.Bold
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
    gameOverText.FontFace = UITheme.Font.Mono
    gameOverText.TextColor3 = Color3.fromRGB(150, 150, 150)
    gameOverText.Parent = bg

    -- Return to lobby button
    local lobbyBtn = Instance.new("TextButton")
    lobbyBtn.Size = UDim2.new(0, 200, 0, 45)
    lobbyBtn.Position = UDim2.new(0.5, -100, 0.82, 0)
    lobbyBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 80)
    lobbyBtn.Text = "Return to Lobby"
    lobbyBtn.TextSize = 18
    lobbyBtn.FontFace = UITheme.Font.Bold
    lobbyBtn.TextColor3 = Color3.new(1, 1, 1)
    lobbyBtn.Parent = bg

    local btnCorner = Instance.new("UICorner")
    btnCorner.CornerRadius = UDim.new(0, 8)
    btnCorner.Parent = lobbyBtn

    lobbyBtn.Activated:Connect(function()
        closeScreen()
        -- Request server to return to lobby
        GameStateChanged:FireServer({ requestLobby = true })
    end)
end

-- ============================================================
-- TRUE ENDING
-- ============================================================
local function playTrueEnding()
    disableControls()

    camera.CameraType = Enum.CameraType.Scriptable
    -- The opposite gesture to the bad ending: the lens opens out into the morning.
    camera.FieldOfView = 58
    fovPull(78, 12)

    local gui, bg = createOverlayGui("TrueEnding")
    local closeScreen = openEndingScreen(gui)

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
    dissolveText.FontFace = UITheme.Font.Medium
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
    checkText.FontFace = UITheme.Font.Bold
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
    credits.FontFace = UITheme.Font.Medium
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
    lobbyBtn.FontFace = UITheme.Font.Bold
    lobbyBtn.TextColor3 = Color3.new(1, 1, 1)
    lobbyBtn.Parent = bg

    local btnCorner = Instance.new("UICorner")
    btnCorner.CornerRadius = UDim.new(0, 10)
    btnCorner.Parent = lobbyBtn

    lobbyBtn.Activated:Connect(function()
        closeScreen()
        GameStateChanged:FireServer({ requestLobby = true })
    end)
end

-- ============================================================
-- OPENING CUTSCENE (Day 1 start, the organizer's welcome talk)
-- Shot list and staging live in Shared.OpeningCinematic.
-- ============================================================
local function playOpeningCutscene(data: { [string]: any })
    OpeningCinematic.play(data, {
        playerGui = playerGui :: PlayerGui,
        disableControls = disableControls,
        enableControls = enableControls,
        resetLens = resetLens,
        getCutsceneBlur = getCutsceneBlur,
        motionBlur = motionBlur,
    })
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
    caption.BackgroundTransparency = 1; caption.FontFace = UITheme.Font.Medium; caption.TextSize = 24
    caption.TextColor3 = Color3.fromRGB(245,245,245); caption.TextStrokeTransparency = 0.5; caption.TextWrapped = true
    caption.TextYAlignment = Enum.TextYAlignment.Bottom; caption.TextTransparency = 1; caption.ZIndex = 10; caption.Text = ""; caption.Parent = gui
    local thought = Instance.new("TextLabel")
    thought.AnchorPoint = Vector2.new(0.5,0.5); thought.Size = UDim2.new(0.72,0,0,140); thought.Position = UDim2.new(0.5,0,0.5,0)
    thought.BackgroundTransparency = 1; thought.FontFace = UITheme.Font.Regular; thought.TextSize = 26
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
    local set = Instance.new("Folder"); set.Name = "NightTransitionSet"; set.Parent = workspace

    local function newPart(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?): Part
        local p = Instance.new("Part")
        p.Name = name; p.Anchored = true; p.CanCollide = false; p.CastShadow = false
        p.Size = size; p.CFrame = cf; p.Color = color; p.Material = material or Enum.Material.SmoothPlastic; p.Parent = set
        return p
    end

    -- Performers are clones of real venue rigs (Shared.CutsceneActors); the
    -- breakdowns, the turns and the exit shamble are in Shared.NGMIChoreo, and
    -- the mutation itself is Shared.NGMIMutation, the same one the gameplay
    -- NGMIs are built with.
    local sources = CutsceneActors.gatherSources({ "NPCs", "AmbientPeople" })
    local function makeActor(cf: CFrame, role: string, seated: boolean): any
        local actor: any = CutsceneActors.spawn({
            source = if #sources > 0 then sources[math.random(#sources)] else nil,
            parent = set,
            cframe = cf,
            repaint = true,
            stripClothes = true,
        })
        if not actor then return nil end
        actor.role = role
        actor.seated = seated
        actor.mode = "breakdown"
        actor.modeStart = 0
        actor.twist = 0
        return actor
    end

    -- Root height for a standing rig: hips sit HipHeight above the floor and
    -- the root's centre half its height above that.
    local standLift = 3.6
    do
        local src = sources[1]
        local hum = src and src:FindFirstChildOfClass("Humanoid")
        local root = src and src:FindFirstChild("HumanoidRootPart")
        if hum and root and root:IsA("BasePart") and hum.HipHeight > 0 then
            standLift = hum.HipHeight + root.Size.Y * 0.5
        end
    end

    local function addDesk(actorPos: Vector3, code: string)
        newPart("Desk", Vector3.new(4.4,0.2,2), CFrame.new(actorPos + Vector3.new(0,-0.25,1.7)), Color3.fromRGB(58,53,62))
        local screenPos = actorPos + Vector3.new(0,0.5,2.5)
        local screen = newPart("Screen", Vector3.new(2.6,1.6,0.1), CFrame.lookAt(screenPos, actorPos + Vector3.new(0,0.4,0)), Color3.fromRGB(16,12,16), Enum.Material.Neon)
        local sg = Instance.new("SurfaceGui"); sg.Face = Enum.NormalId.Front; sg.CanvasSize = Vector2.new(320,200); sg.Parent = screen
        local lbl = Instance.new("TextLabel")
        lbl.Size = UDim2.new(1,0,1,0); lbl.BackgroundColor3 = Color3.fromRGB(10,6,9); lbl.FontFace = UITheme.Font.Mono
        lbl.TextColor3 = Color3.fromRGB(255,70,70); lbl.TextXAlignment = Enum.TextXAlignment.Left; lbl.TextYAlignment = Enum.TextYAlignment.Top
        lbl.TextWrapped = true; lbl.TextSize = 15; lbl.Text = code; lbl.Parent = sg
        -- In a dark room the monitor is the key light on the actor's face, so it
        -- carries more than it did when the room was flat-lit.
        local face = Instance.new("PointLight"); face.Color = Color3.fromRGB(255,120,110); face.Brightness = 1; face.Range = 10; face.Parent = screen
    end

    local function headOf(rig: any): BasePart?
        if not rig then return nil end
        return rig.head()
    end
    -- A hard cut with a blur snap over it. Punching the blur up on the frame of
    -- the cut and decaying it away is what makes an instant CFrame change read as
    -- an edit rather than a teleport, and it tightens the lens for the close-up so
    -- the face is shot long instead of wide.
    local function snapCut(fov: number)
        local snap = getCutsceneBlur()
        snap.Size = 14
        motionBlur(0, 0.28)
        fovPull(fov, 0.35, Enum.EasingDirection.Out)
    end
    local function cutToFace(rig: any, sideways: number, dist: number)
        if not rig then return end
        local head = headOf(rig)
        local headPos = head and head.Position or (rig.model:GetPivot().Position + Vector3.new(0, 2.2, 0))
        local target = headPos - Vector3.new(0,0.5,0)
        local pos = headPos + rig.facing*dist + rig.right*sideways + Vector3.new(0,0.7,0)
        camera.CFrame = CFrame.lookAt(pos, target)
        snapCut(48)
    end
    --- Cut to a camera placed in the actor's own space (-Z is in front of
    --- them), aimed at a point also given in their space.
    local function cutToLocal(rig: any, camLocal: Vector3, lookLocal: Vector3, fov: number)
        if not rig then return end
        local pivot = rig.model:GetPivot()
        camera.CFrame = CFrame.lookAt(pivot:PointToWorldSpace(camLocal), pivot:PointToWorldSpace(lookLocal))
        snapCut(fov)
    end
    local function startCamShake(intensity: number): RBXScriptConnection
        local baseCF = camera.CFrame
        return RunService.RenderStepped:Connect(function()
            camera.CFrame = baseCF * CFrame.Angles(math.rad((math.random()-0.5)*intensity), math.rad((math.random()-0.5)*intensity), math.rad((math.random()-0.5)*intensity))
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
    local standY = floorTop + standLift
    -- Thighs land ~1.4 studs off the floor, just under the desk tops.
    local seatY = floorTop + 2.85
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
    -- Cold night sky through the window. It used to sit at zero until the
    -- lightning hit, so the window was a black rectangle; a low steady value
    -- gives the room a cold edge to sit against the tubes.
    --
    -- Range 14, NOT the 34 it had: the room is only 50 x 40, so a 34-stud light
    -- at the window is not a rim on the glass, it is a second room light washing
    -- everything. That single number was why every close-up rendered as a white
    -- wall while the wides still looked like a blackout.
    local skyPL = Instance.new("PointLight"); skyPL.Color = Color3.fromRGB(150,170,255); skyPL.Brightness = 0.6; skyPL.Range = 14; skyPL.Parent = skyLight
    -- Overhead tubes. Half of them are dead and the rest are tired: a venue at
    -- 3am is not evenly lit, it is a few pools of light with dark between them.
    -- One fixture flickers, which is the cheapest "this place is wrong" signal
    -- there is and it gives the room some motion before anything happens.
    local flickerFixtures: { Part } = {}
    for _, cx in { -14, 0, 14 } do
        for _, cz in { -8, 8 } do
            local dead = (cx == 14 and cz == -8) or (cx == -14 and cz == 8)
            local fix = newPart("CeilLight", Vector3.new(4, 0.3, 2), CFrame.new(centerX + cx, BASE.Y + 11.6, BASE.Z + cz), Color3.fromRGB(190, 196, 214), Enum.Material.Neon)
            if dead then
                fix.Color = Color3.fromRGB(38, 40, 48)
                fix.Material = Enum.Material.SmoothPlastic
            else
                local pl = Instance.new("PointLight")
                pl.Color = Color3.fromRGB(214, 222, 240) -- fluorescent, not warm lamplight
                -- Modest on purpose. Ambient already puts the room at a dim night
                -- level; these are pools on top of it, not the room light. At 1.6
                -- a single fixture lit a wall eight studs away to near-white, and
                -- every close-up shot near a desk blew out.
                pl.Brightness = 1.1
                pl.Range = 28
                pl.Parent = fix
                if cx == 0 and cz == -8 then
                    table.insert(flickerFixtures, fix)
                end
            end
        end
    end
    table.insert(conns, RunService.Heartbeat:Connect(function()
        local t = os.clock()
        for _, fix in flickerFixtures do
            local pl = fix:FindFirstChildOfClass("PointLight")
            if pl then
                -- mostly on, with irregular dropouts
                local n = math.sin(t * 37) * math.sin(t * 11.3) * math.sin(t * 3.1)
                local out = n < -0.55
                pl.Brightness = out and 0.08 or 1.1
                fix.Color = out and Color3.fromRGB(60, 63, 74) or Color3.fromRGB(190, 196, 214)
            end
        end
    end))

    -- A key light riding the lens. The two desk actors are lit by their monitors,
    -- but the standing ones (the rager, and the victim who carries the climax)
    -- have nothing in front of them, so every close-up of them was a black
    -- silhouette once the room went dark. Short range on purpose: it reaches a
    -- face at close-up distance and dies well before it can lift the wides.
    local keyPart = newPart("KeyLight", Vector3.new(0.2, 0.2, 0.2), CFrame.new(BASE), Color3.new(0,0,0))
    keyPart.Transparency = 1
    local keyLight = Instance.new("PointLight")
    keyLight.Color = Color3.fromRGB(198, 208, 235)
    -- Calibrated against a stand-in head at the close-up distance the shots use
    -- (3.2 studs): 1.5/15 blew the room out to daylight, 0.35/9 left the face a
    -- silhouette. This reads the face and dies before it reaches the walls.
    keyLight.Brightness = 0.12
    keyLight.Range = 6
    keyLight.Parent = keyPart
    table.insert(conns, RunService.RenderStepped:Connect(function()
        keyPart.CFrame = camera.CFrame * CFrame.new(1.2, 1, 1)
    end))

    -- One role per actor, never reused, and each role has its own turn in
    -- NGMIChoreo.TURN. If you add an actor, give it its own role and turn.
    local cast: { any } = {}
    local function facing(pos: Vector3): CFrame return CFrame.lookAt(pos, pos + Vector3.new(0,0,1)) end
    local function cue(a: any) if a then table.insert(cast, a) end return a end
    local slamPos = Vector3.new(centerX - 12, seatY, BASE.Z - 3)
    local slammer = cue(makeActor(facing(slamPos), "slam", true))
    addDesk(slamPos, "$ make\nundefined reference\nundefined reference\n  187 errors\nbuild FAILED")
    local shakePos = Vector3.new(centerX - 3, seatY, BASE.Z - 4)
    local shaker = cue(makeActor(facing(shakePos), "headshake", true))
    addDesk(shakePos, "Traceback (most recent call last)\n  File main.py, line 42\nSyntaxError: invalid syntax\nSyntaxError")
    local rager = cue(makeActor(facing(Vector3.new(centerX + 7, standY, BASE.Z - 2)), "hair", false))
    local pacer = cue(makeActor(facing(Vector3.new(centerX + 15, standY, BASE.Z - 3)), "pace", false))
    if pacer then
        pacer.a = Vector3.new(centerX + 12, standY, BASE.Z - 7); pacer.b = Vector3.new(centerX + 18, standY, BASE.Z + 3); pacer.speed = 0.9
    end
    local deskPos = Vector3.new(centerX - 20, seatY, BASE.Z - 2)
    local facedesker = cue(makeActor(facing(deskPos), "facedesk", true))
    addDesk(deskPos, "git push --force\n! [rejected] main -> main\nmerge conflict in 14 files\nmerge conflict in 14 files")
    local starePos = Vector3.new(centerX + 20, seatY, BASE.Z + 3)
    local starer = cue(makeActor(facing(starePos), "stare", true))
    addDesk(starePos, "npm ERR! code ELIFECYCLE\nnpm ERR! errno 1\n\n> build failed\n> 04:11:58")
    local victim = cue(makeActor(facing(Vector3.new(centerX, standY, BASE.Z + 5)), "unravel", false))

    -- One loop poses the whole cast. Each actor is in a mode: its breakdown
    -- loop, its one-shot turn (mutating partway through), the turned idle, or
    -- the exit walk (posed by the walk loop below).
    local animClock = os.clock()
    local onMutate: (any) -> () = function(_a: any) end
    local function poseActor(a: any, t: number, dt: number)
        local pose: RigPose.Pose
        if a.mode == "breakdown" then
            local stride: number? = nil
            if a.role == "pace" and a.a and a.b then
                local u = math.sin(t*a.speed)*0.5+0.5
                local pos = (a.a :: Vector3):Lerp(a.b :: Vector3, u)
                local dir = (a.b :: Vector3) - (a.a :: Vector3)
                local f = if math.cos(t*a.speed) >= 0 then dir else -dir
                f = Vector3.new(f.X,0,f.Z); if f.Magnitude < 0.01 then f = Vector3.new(0,0,1) end
                a.setPivot(CFrame.lookAt(pos, pos + f.Unit))
                stride = t*a.speed*6
            end
            pose = NGMIChoreo.BREAKDOWN[a.role](t, a, stride)
        elseif a.mode == "turn" then
            local turn = NGMIChoreo.TURN[a.role]
            local lt = t - a.modeStart
            if not a.mutated and lt >= turn.mutateAt then
                a.mutated = true
                NGMIMutation.apply(a.model, math.floor(a.phase * 100000) + 7, { fx = true })
                onMutate(a)
            end
            pose = turn.fn(math.min(lt, turn.length), a)
            if lt >= turn.length then a.mode = "idle" end
        elseif a.mode == "idle" then
            pose = NGMIChoreo.idle(t, a)
        else
            pose = a.walkPose or {}
        end
        if a.mutated then a.twist = math.min(1, a.twist + dt / 0.6) end
        if a.twist > 0 then pose = RigPose.add(pose, NGMIMutation.TWIST, a.twist) end
        a.rig:apply(pose, dt, 20)
    end
    table.insert(conns, RunService.Heartbeat:Connect(function(dt: number)
        local t = os.clock() - animClock
        for _, a in cast do
            if a.mode ~= "frozen" then
                local ok, err = pcall(poseActor, a, t, dt)
                if not ok then
                    warn("[CutsceneManager] actor pose failed: " .. tostring(err))
                    a.mode = "frozen"
                end
            end
        end
    end))
    local function startTurn(a: any)
        if a and a.mode ~= "turn" then
            a.mode = "turn"
            a.modeStart = os.clock() - animClock
        end
    end

    -- a short hallway through the back doorway, for the exit shot
    newPart("HallFloor", Vector3.new(10, 0.4, 30), CFrame.new(centerX, floorTop - 0.2, backZ - 15), Color3.fromRGB(120, 124, 130), Enum.Material.Concrete)
    newPart("HallCeil", Vector3.new(10, 0.4, 30), CFrame.new(centerX, BASE.Y + 10, backZ - 15), CEIL)
    newPart("HallWallL", Vector3.new(0.6, 10, 30), CFrame.new(centerX - 5, BASE.Y + 5, backZ - 15), WALL)
    newPart("HallWallR", Vector3.new(0.6, 10, 30), CFrame.new(centerX + 5, BASE.Y + 5, backZ - 15), WALL)
    for hz = backZ - 4, backZ - 28, -8 do
        local fix = newPart("HallLight", Vector3.new(2, 0.3, 2), CFrame.new(centerX, BASE.Y + 9.6, hz), Color3.fromRGB(255, 245, 225), Enum.Material.Neon)
        local pl = Instance.new("PointLight"); pl.Color = Color3.fromRGB(206, 214, 232); pl.Brightness = 0.8; pl.Range = 18; pl.Parent = fix
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

    local function setCC(b: number, c: number, s: number, tint: Color3)
        local cc = Lighting:FindFirstChild("GameColorCorrection") or Lighting:FindFirstChildOfClass("ColorCorrectionEffect")
        if cc and cc:IsA("ColorCorrectionEffect") then cc.Brightness = b; cc.Contrast = c; cc.Saturation = s; cc.TintColor = tint end
    end
    -- Late night, not midday. This used to force ClockTime 14 with a flat grey
    -- 84/84/84 ambient, which lit the set like an office at lunchtime and made
    -- the whole sequence read as a white room. The room is now dark, cold and
    -- blue, and the only real light is what the practicals throw: overhead
    -- fluorescents at half strength, and monitors on faces.
    local lightOverride = RunService.RenderStepped:Connect(function()
        -- Ambient is the lever here, not the fixtures. Roblox adds Ambient flatly
        -- everywhere regardless of occlusion, and this set is a sealed box, so the
        -- practicals only ever add pools on top of it. What made the original read
        -- as midday was not that Ambient was high, it was that it was high AND
        -- neutral grey; the same magnitude shifted hard to blue reads as night.
        Lighting.Ambient = Color3.fromRGB(44, 48, 70)
        Lighting.OutdoorAmbient = Color3.fromRGB(26, 30, 44)
        -- Brightness 0, i.e. no sun and no moon. Every part in this set is built
        -- with CastShadow = false, so the ceiling does not block skylight: any
        -- Brightness at all pours straight through it and lights the interior as
        -- if the room had no roof. That is what the original ClockTime 14 was
        -- really doing, and it is why close-ups kept blowing out to white while
        -- the wides looked fine. With it at zero the room is lit by exactly two
        -- things, Ambient and the practicals, which is the whole point.
        Lighting.Brightness = 0
        Lighting.ClockTime = 0.8
        -- Future feeds sky light into the scene through EnvironmentDiffuseScale,
        -- separately from Brightness, and this shell casts no shadows to stop it.
        Lighting.EnvironmentDiffuseScale = 0
        Lighting.EnvironmentSpecularScale = 0
        Lighting.FogColor = Color3.fromRGB(9, 10, 17)
        -- Fog starts well back on purpose. At FogStart 14 the wide shots were dark
        -- only because the fog was crushing them, while every close-up sat INSIDE
        -- the fog and rendered at the true ambient, which is why faces blew out
        -- white in the same scene that looked like a blackout from across the room.
        -- Pulled back, the room's darkness comes from ambient and the practicals,
        -- and it reads the same at both ends of the lens.
        Lighting.FogStart = 40
        Lighting.FogEnd = 200
        -- With an Atmosphere present the Fog settings above are ignored, and
        -- whatever phase we came from (a light grey day haze) washed every wide
        -- shot of this set out to white. Hold it at the night's values.
        local atmos = Lighting:FindFirstChildOfClass("Atmosphere")
        if atmos then
            atmos.Density = 0.3; atmos.Offset = 0.05
            atmos.Color = Color3.fromRGB(10, 12, 18); atmos.Decay = Color3.fromRGB(3, 4, 7)
            atmos.Glare = 0; atmos.Haze = 0.6
        end
        -- Cold, slightly crushed, a little desaturated: 3am on a bad monitor.
        setCC(-0.02, 0.14, -0.12, Color3.fromRGB(198, 206, 235))
        local blur = Lighting:FindFirstChild("GameBlur"); if blur and blur:IsA("BlurEffect") then blur.Size = 0 end
        local bloom = Lighting:FindFirstChild("GameBloom") or Lighting:FindFirstChildOfClass("BloomEffect")
        -- Bloom stays ON here, unlike before: it is what makes the monitors and
        -- the tube fixtures read as the only light sources in a dark room.
        if bloom and bloom:IsA("BloomEffect") then bloom.Intensity = 0.35; bloom.Size = 26; bloom.Threshold = 1 end
    end)
    table.insert(conns, lightOverride)

    local BAR_H = 0.12
    TweenService:Create(topBar, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.new(1,0,BAR_H,0) }):Play()
    TweenService:Create(botBar, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = UDim2.new(1,0,BAR_H,0) }):Play()

    camera.CFrame = CFrame.lookAt(Vector3.new(centerX, standY + 3, BASE.Z + 18), Vector3.new(centerX, standY - 0.5, BASE.Z - 6))
    TweenService:Create(bg, TweenInfo.new(1.2, Enum.EasingStyle.Quad), { BackgroundTransparency = 1 }):Play()
    task.wait(0.4)
    showCaption("As the hours pass, everyone frantically tries to finish their projects.", 3.4)

    -- Wide sideways offsets on the two desk actors on purpose: the monitor sits
    -- 2.5 studs in front of them, so a straight-on close-up is framed THROUGH the
    -- back of the screen. Coming in off the shoulder clears it and puts the
    -- monitor glow across the face instead of behind it.
    cutToFace(slammer, 2.4, 3.2)
    showCaption('"Why won\'t it compile? WHY won\'t it compile?!"', 2.6)
    cutToFace(shaker, -2.4, 3.2)
    showCaption('"Three hundred errors... I can\'t even look anymore."', 2.6)
    cutToFace(rager, 0.6, 4.2)
    showCaption('"There\'s no way. There\'s no way I finish in time!"', 2.6)
    camera.CFrame = CFrame.lookAt(Vector3.new(centerX + 24, standY + 1.5, BASE.Z + 4), Vector3.new(centerX + 14, standY - 0.3, BASE.Z - 3))
    showCaption('"I can\'t do this. I can\'t, I can\'t, I can\'t..."', 2.6)

    -- (5) Close-up of the last hacker breaking, the line, with the screen shaking.
    cutToFace(victim, 0.4, 3.6)
    showCaption('"No. No, no, no, no—"', 1.6)
    local climaxShake = startCamShake(1.7)
    showCaption('"I\'m... I\'m NOT GONNA MAKE IT!!"', 1.8)
    climaxShake:Disconnect()

    -- (6) The victim turns, framed wide enough to see the whole body go.
    -- Every mutation from here on lands under a flash and a blur snap.
    onMutate = function(_a: any)
        lightningFlash(0.5)
        getCutsceneBlur().Size = 10
        motionBlur(0, 0.35)
    end
    cutToLocal(victim, Vector3.new(1.2, 0.6, -7.5), Vector3.new(0, -0.2, 0), 52)
    local turnShake = startCamShake(0.8)
    startTurn(victim)
    task.wait(NGMIChoreo.TURN.unravel.length - 0.3)
    turnShake:Disconnect()

    -- (7) One by one the room turns. A montage, each turn shot for what is
    --     wrong with it: the slammer from the side for the neck, the face on
    --     the desk from low for the twisted lift, the rager wide for the fold,
    --     and the starer dead on so its head snaps round into the lens.
    camera.CFrame = CFrame.lookAt(Vector3.new(centerX, standY + 3, BASE.Z + 18), Vector3.new(centerX, standY - 0.5, BASE.Z - 6))
    snapCut(74)
    showCaption("One by one, they stop being hackers.", 1.0)
    local montage = {
        { a = slammer, cam = Vector3.new(3.4, 1.8, -2.4), look = Vector3.new(0, 1.4, 0), fov = 50, hold = 2.5 },
        { a = facedesker, cam = Vector3.new(-1.9, 0.5, -2.1), look = Vector3.new(0, 1.0, -0.4), fov = 46, hold = 2.6 },
        { a = rager, cam = Vector3.new(2.2, 0.6, -8.5), look = Vector3.new(0, -0.4, 0), fov = 50, hold = 2.7 },
        { a = starer, cam = Vector3.new(0.15, 1.9, -2.3), look = Vector3.new(0, 1.5, 0), fov = 42, hold = 2.3 },
    }
    for _, shot in montage do
        if shot.a then
            startTurn(shot.a)
            -- cut a beat into the move so the edit lands on motion
            task.wait(0.12)
            cutToLocal(shot.a, shot.cam, shot.look, shot.fov)
            task.wait(shot.hold)
        end
    end
    -- the last two go together, in the wide
    camera.CFrame = CFrame.lookAt(Vector3.new(centerX + 6, standY + 2.2, BASE.Z + 15), Vector3.new(centerX + 4, standY - 0.6, BASE.Z - 4))
    snapCut(66)
    startTurn(shaker)
    task.wait(0.35)
    startTurn(pacer)
    task.wait(2.6)

    -- (8a) They rise and shamble out the back doorway into the hallway.
    local exits = {}
    local lanes = { 0, -2, 2, -3.4, 3.4 }
    local slot = 0
    for _, a in { victim, rager, pacer, slammer, shaker, facedesker, starer } do
        if a then
            slot += 1
            a.mode = "walk"
            a.seated = false
            local p = a.model:GetPivot().Position
            table.insert(exits, { a = a, start = Vector3.new(p.X, standY, p.Z), lane = lanes[((slot - 1) % #lanes) + 1], delay = (slot - 1) * 0.4 })
        end
    end
    local walkStart = os.clock()
    local walkConn = RunService.Heartbeat:Connect(function()
        local now = os.clock() - walkStart
        for _, e in exits do
            local t = math.max(0, now - e.delay)
            local a = e.a
            local door = Vector3.new(centerX + e.lane, standY, backZ + 2)
            local hall = Vector3.new(centerX + e.lane, standY, backZ - 24)
            local d1 = door - e.start
            local seg1 = d1.Magnitude
            -- uneven pace: every lurch stalls them for a beat
            local dist = math.max(0, t * 4.2 - math.max(0, math.sin(t * 1.6 + a.phase)) * 0.6)
            local pos, dir
            if dist < seg1 then pos = e.start + d1.Unit * dist; dir = d1
            else local d2 = hall - door; pos = door + d2.Unit * math.min(dist - seg1, d2.Magnitude); dir = d2 end
            dir = Vector3.new(dir.X, 0, dir.Z); if dir.Magnitude < 0.01 then dir = Vector3.new(0,0,-1) end
            a.setPivot(CFrame.lookAt(pos, pos + dir.Unit))
            if now > e.delay then
                a.walkPose = NGMIChoreo.shamble(now, dist * 1.7 + a.phase, a)
            else
                -- up out of the chair, waiting its turn to move
                a.walkPose = NGMIChoreo.idle(now, a)
            end
        end
    end)
    table.insert(conns, walkConn)
    task.wait(0.4)
    camera.CFrame = CFrame.lookAt(Vector3.new(centerX, standY + 2.4, BASE.Z + 6), Vector3.new(centerX, standY - 0.2, backZ - 8))
    snapCut(70)
    task.wait(3.6)

    -- (8) Lightning through the window — then the power dies.
    skyPL.Brightness = 9; lightningFlash(1)
    task.wait(0.12); skyPL.Brightness = 0.6; task.wait(0.18)
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
            -- The set above zeroed the environment scales; hand them back so wet
            -- floors keep their specular response for the night.
            Lighting.ShadowSoftness = p.ShadowSoftness
            Lighting.EnvironmentDiffuseScale = p.EnvironmentDiffuseScale
            Lighting.EnvironmentSpecularScale = p.EnvironmentSpecularScale
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
    -- The close-ups left the lens long and the blur hot; hand both back to
    -- gameplay or NIGHT2 opens on a 48-degree blurred frame.
    resetLens()
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
