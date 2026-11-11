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
local NGMIFit = require(Shared:WaitForChild("NGMIFit"))
local OpeningCinematic = require(Shared:WaitForChild("OpeningCinematic"))
local Lounge = require(script.Parent:WaitForChild("Cutscene"):WaitForChild("Lounge"))
local WorldIndex = require(script.Parent:WaitForChild("Cutscene"):WaitForChild("WorldIndex"))

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
    -- the player muttering to themselves: small, low on the screen
    thought.AnchorPoint = Vector2.new(0.5, 1)
    thought.Size = UDim2.new(0.6, 0, 0, 48)
    thought.Position = UDim2.new(0.5, 0, 0.92, 0)
    thought.TextYAlignment = Enum.TextYAlignment.Bottom
    thought.BackgroundTransparency = 1
    thought.FontFace = UITheme.Font.Regular
    thought.TextSize = 18
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

    showThought("Morning already? Right, no time to waste. Let's get to work.", 2.6)

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
    for _ = 1, 8 do
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
-- The player dozes off. In a lounge, three hackers: one breaks and turns
-- NGMI, goes for the one at the next table, and the third jumps up to watch
-- and turns too. A storm kills the power, and the player jolts awake on the
-- floor for the final night. Self-contained & client-local: it clones real
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
    -- the player muttering to themselves: small, low on the screen
    thought.AnchorPoint = Vector2.new(0.5,1); thought.Size = UDim2.new(0.6,0,0,48); thought.Position = UDim2.new(0.5,0,0.92,0)
    thought.TextYAlignment = Enum.TextYAlignment.Bottom
    thought.BackgroundTransparency = 1; thought.FontFace = UITheme.Font.Regular; thought.TextSize = 18
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
    local set = Instance.new("Folder"); set.Name = "NightTransitionSet"; set.Parent = workspace

    -- The strike that kills the power: a crack on the flash and a thunderclap
    -- over the shake and the cut to black. Made now so they have loaded by then.
    local function stormSound(id: string, volume: number): Sound
        local s = Instance.new("Sound")
        s.SoundId = id
        s.Volume = volume
        s.Parent = game:GetService("SoundService")
        return s
    end
    local strikeCrack = stormSound("rbxassetid://12222019", 1) -- Roblox HalloweenLightning
    local thunderclap = stormSound("rbxassetid://12222030", 1) -- Roblox HalloweenThunder

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
    -- Cast from the server's pool of crowd hackers (ReplicatedStorage.CutsceneCast),
    -- falling back to the venue's people if it hasn't arrived.
    local sources: { Model } = {}
    local pool = ReplicatedStorage:FindFirstChild("CutsceneCast")
    if pool then
        for _, m in pool:GetChildren() do
            if m:IsA("Model") and m:FindFirstChild("UpperTorso") then table.insert(sources, m) end
        end
    end
    if #sources == 0 then
        sources = CutsceneActors.gatherSources({ "AmbientPeople", "NPCs" })
    end
    -- three different people, not the same body twice
    for i = #sources, 2, -1 do
        local j = math.random(i)
        sources[i], sources[j] = sources[j], sources[i]
    end
    -- Each actor turns a different way (Shared.NGMIStyles), dealt in a shuffled order.
    local castStyles = table.clone(NGMIMutation.STYLES)
    for i = #castStyles, 2, -1 do
        local j = math.random(i)
        castStyles[i], castStyles[j] = castStyles[j], castStyles[i]
    end
    local styleCount = 0
    local function makeActor(cf: CFrame, role: string, seated: boolean): any
        local actor: any = CutsceneActors.spawn({
            source = if #sources > 0 then sources[styleCount % #sources + 1] else nil,
            parent = set,
            cframe = cf,
            repaint = true,
            stripClothes = true,
        })
        if not actor then return nil end
        -- arms in, and the contacts (hands to the mouth, face in the hands)
        -- solved on this body
        actor.fit = NGMIFit.prepare(actor.rig)
        actor.role = role
        actor.seated = seated
        actor.mode = "breakdown"
        actor.modeStart = 0
        styleCount += 1
        actor.style = NGMIMutation.style(castStyles[(styleCount - 1) % #castStyles + 1])
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

    -- A venue lounge at 3am (Cutscene/Lounge): carpet, panelled walls, the
    -- couch corner, vending machines and laptop tables, from the venue's own
    -- furniture templates. Ceiling panels at half strength, one flickering.
    local centerX = BASE.X
    local floorTop = BASE.Y + 0.2
    local standY = floorTop + standLift
    -- Thighs land ~1.4 studs off the floor, on the lounge chairs.
    local seatY = floorTop + 2.85
    local room = Lounge.build(set, BASE, floorTop)
    local skyPL = room.skyPL
    table.insert(conns, room.flicker)


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
    local keyOffset = CFrame.new(1.2, 1, 1)
    table.insert(conns, RunService.RenderStepped:Connect(function()
        keyPart.CFrame = camera.CFrame * keyOffset
    end))

    -- Three hackers. The first, standing with his arms wrapped round himself,
    -- breaks and turns, then goes for the one slamming her desk at the next
    -- table. The third jumps out of his chair to watch, and turns himself.
    local cast: { any } = {}
    local function facing(pos: Vector3): CFrame return CFrame.lookAt(pos, pos + Vector3.new(0,0,1)) end
    local function cue(a: any) if a then table.insert(cast, a) end return a end
    local victimPos = Vector3.new(centerX - 6, seatY, BASE.Z)
    local victim = cue(makeActor(facing(victimPos), "slam", true))
    Lounge.workTable(set, victimPos, floorTop, "$ make\nundefined reference\nundefined reference\n  187 errors\nbuild FAILED")
    local first = cue(makeActor(facing(Vector3.new(centerX + 2, standY, BASE.Z + 2)), "unravel", false))
    local witnessPos = Vector3.new(centerX + 12, seatY, BASE.Z)
    local witness = cue(makeActor(facing(witnessPos), "headshake", true))
    Lounge.workTable(set, witnessPos, floorTop, "npm ERR! code ELIFECYCLE\nnpm ERR! errno 1\n\n> build failed\n> 04:11:58")

    -- One loop poses the whole cast. Each actor is in its breakdown loop, a
    -- clip from NGMIChoreo.CLIP (mutating at the clip's mutateAt), or the
    -- turned idle once a clip runs out.
    local animClock = os.clock()
    local onMutate: (any) -> () = function(_a: any) end
    local function poseActor(a: any, t: number, dt: number)
        local pose: RigPose.Pose
        if a.mode == "breakdown" then
            pose = NGMIChoreo.BREAKDOWN[a.role](t, a)
        elseif a.mode == "clip" then
            local clip = a.clip
            local lt = t - a.modeStart
            if clip.mutateAt and not a.mutated and lt >= clip.mutateAt then
                a.mutated = true
                a.mutatedAt = t
                NGMIMutation.apply(a.model, math.floor(a.phase * 100000) + 7, { fx = true, style = a.style.key, progress = 0 })
                onMutate(a)
            end
            pose = clip.fn(math.min(lt, clip.length), a)
            if lt >= clip.length then a.mode = "idle" end
        else
            pose = NGMIChoreo.idle(t, a)
        end
        -- the growths spread in at the style's own pace, the twist with them
        if a.mutated then
            if not a.grown then
                local p = NGMIMutation.turnProgress(a.style, t - a.mutatedAt)
                NGMIMutation.setProgress(a.model, p)
                a.grown = p >= 1
            end
            pose = RigPose.add(pose, NGMIMutation.twistOf(a.model))
        end
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
    local function play(a: any, clip: string)
        if a then
            a.mode = "clip"
            a.clip = NGMIChoreo.CLIP[clip]
            a.modeStart = os.clock() - animClock
        end
    end
    --- Move an actor's pivot to `goal` over `dur` seconds, eased.
    local function glide(a: any, goal: CFrame, dur: number)
        local from = a.model:GetPivot()
        local t0 = os.clock()
        local c: RBXScriptConnection
        c = RunService.Heartbeat:Connect(function()
            local u = math.clamp((os.clock() - t0) / dur, 0, 1)
            a.setPivot(from:Lerp(goal, u * u * (3 - 2 * u)))
            if u >= 1 then c:Disconnect() end
        end)
        table.insert(conns, c)
    end

    -- TIMELINE
    task.wait(0.4)
    showThought("My eyes are burning... I'll just rest them for a minute.", 2.6)

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

    for _, d in WorldIndex.hideTargets() do
        if d:IsA("BillboardGui") and d.Name == "DeskBeaconLabel" and d.Enabled then d.Enabled = false; table.insert(hiddenBillboards, d) end
    end
    -- With the venue's ~480 ambient rigs in the workspace the set's lights
    -- never reached it (every shot before NIGHT2 cleared the crowd rendered
    -- black, measured); out of the workspace, the room lights at once. The
    -- screen is black, so nobody sees the venue empty. Server removals still
    -- replicate into the folder while it is parked.
    local ambientPeople = workspace:FindFirstChild("AmbientPeople")
    if ambientPeople then
        ambientPeople.Parent = ReplicatedStorage
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
    local setAmbient, setOutdoor, setFog = Color3.fromRGB(44, 48, 70), Color3.fromRGB(26, 30, 44), Color3.fromRGB(9, 10, 17)
    local setAtmosColor, setAtmosDecay, setTint = Color3.fromRGB(10, 12, 18), Color3.fromRGB(3, 4, 7), Color3.fromRGB(198, 206, 235)
    local lightOverride = RunService.RenderStepped:Connect(function()
        -- Ambient is the lever here, not the fixtures. Roblox adds Ambient flatly
        -- everywhere regardless of occlusion, and this set is a sealed box, so the
        -- practicals only ever add pools on top of it. What made the original read
        -- as midday was not that Ambient was high, it was that it was high AND
        -- neutral grey; the same magnitude shifted hard to blue reads as night.
        Lighting.Ambient = setAmbient
        Lighting.OutdoorAmbient = setOutdoor
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
        Lighting.FogColor = setFog
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
            atmos.Color = setAtmosColor; atmos.Decay = setAtmosDecay
            atmos.Glare = 0; atmos.Haze = 0.6
        end
        -- Cold, slightly crushed, a little desaturated: 3am on a bad monitor.
        setCC(-0.02, 0.14, -0.12, setTint)
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
    -- Hold on black while the renderer lights the set around the camera's new
    -- position; faded straight in, the first shot opened on a dark room.
    task.wait(1.5)
    TweenService:Create(bg, TweenInfo.new(1.2, Enum.EasingStyle.Quad), { BackgroundTransparency = 1 }):Play()
    task.wait(0.4)
    showCaption("3 a.m. Nobody in here is going to make the deadline.", 2.6)

    -- (2) The first one breaks: the line, with the screen shaking.
    cutToFace(first, 0.4, 3.6)
    showCaption('"No. No, no, no, no..."', 1.4)
    local climaxShake = startCamShake(1.7)
    showCaption('"I\'m... I\'m NOT GONNA MAKE IT!!"', 1.6)
    climaxShake:Disconnect()

    -- (3) He turns, framed wide enough to see the whole body go. Every
    -- mutation lands under a flash and a blur snap.
    onMutate = function(_a: any)
        lightningFlash(0.5)
        getCutsceneBlur().Size = 10
        motionBlur(0, 0.35)
    end
    cutToLocal(first, Vector3.new(1.2, 0.6, -7.5), Vector3.new(0, -0.2, 0), 52)
    local turnShake = startCamShake(0.8)
    play(first, "unravel")
    task.wait(NGMIChoreo.CLIP.unravel.length - 0.2)
    turnShake:Disconnect()

    -- (4) He whips round and lunges at the hacker at the next table, coming
    -- in on her left. Two-shot from her other front corner, so he charges in
    -- from the right of frame instead of starting in front of the lens.
    local vp = victim.model:GetPivot().Position
    local strike = Vector3.new(vp.X + 3.4, standY, vp.Z - 0.6)
    local twoShot = CFrame.lookAt(Vector3.new(vp.X - 4.5, standY + 1.1, vp.Z + 7), Vector3.new(vp.X + 1.6, seatY + 0.4, vp.Z - 0.3))
    camera.CFrame = twoShot
    snapCut(50)
    local fromPos = first.model:GetPivot().Position
    first.setPivot(CFrame.lookAt(fromPos, Vector3.new(vp.X, standY, vp.Z)))
    task.wait(0.2)
    glide(first, CFrame.lookAt(strike, Vector3.new(vp.X, standY, vp.Z)), 0.35)
    play(first, "attack")
    task.wait(0.3)
    play(victim, "struck")
    getCutsceneBlur().Size = 12
    motionBlur(0, 0.3)
    local hitShake = startCamShake(1.4)
    task.wait(0.5)
    hitShake:Disconnect()
    task.wait(0.5)

    -- (5) The third jumps up out of his chair, turning to the attack, and
    -- freezes with his hands to his mouth. Close on his face.
    local wp = witness.model:GetPivot().Position
    local standAt = Vector3.new(wp.X + 1.6, standY, wp.Z - 0.8)
    local watchCF = CFrame.lookAt(standAt, Vector3.new(strike.X, standY, strike.Z))
    witness.seated = false
    play(witness, "horror")
    glide(witness, watchCF, 0.3)
    task.wait(0.05)
    camera.CFrame = CFrame.lookAt(watchCF:PointToWorldSpace(Vector3.new(0.9, 1.5, -5.5)), watchCF:PointToWorldSpace(Vector3.new(0, 1.2, 0)))
    snapCut(46)
    task.wait(1.45)
    -- what he is watching: she has stopped fighting
    camera.CFrame = twoShot
    snapCut(50)
    task.wait(0.9)
    -- (6) Back on him as the twitching takes over and he turns, the head
    -- snapping up into the lens.
    camera.CFrame = CFrame.lookAt(watchCF:PointToWorldSpace(Vector3.new(0.5, 1.8, -4.6)), watchCF:PointToWorldSpace(Vector3.new(0, 1.5, 0)))
    snapCut(44)
    local seizeShake: RBXScriptConnection? = nil
    task.delay(0.55, function()
        seizeShake = startCamShake(1.1)
    end)
    task.wait(NGMIChoreo.CLIP.horror.length - 2.4 + 0.4)
    if seizeShake then seizeShake:Disconnect() end

    -- (8) Lightning through the window — then the power dies.
    skyPL.Brightness = 9; lightningFlash(1)
    strikeCrack:Play()
    task.wait(0.12); skyPL.Brightness = 0.6; task.wait(0.18)
    skyPL.Brightness = 11; lightningFlash(1)
    thunderclap:Play()
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
            -- the set held the haze at its own values; the night has thicker
            local atmos = Lighting:FindFirstChildOfClass("Atmosphere")
            local a = p.Atmosphere
            if atmos and a then
                atmos.Density = a.Density
                atmos.Offset = a.Offset
                atmos.Color = a.Color
                atmos.Decay = a.Decay
                atmos.Glare = a.Glare
                atmos.Haze = a.Haze
            end
            local b = p.PostProcessing and p.PostProcessing.Bloom
            local bloom = Lighting:FindFirstChild("GameBloom") or Lighting:FindFirstChildOfClass("BloomEffect")
            if b and bloom and bloom:IsA("BloomEffect") then bloom.Intensity = b.Intensity; bloom.Size = b.Size; bloom.Threshold = b.Threshold end
        end
    end
    for _, d in set:GetDescendants() do
        if d:IsA("PointLight") then
            d.Enabled = false
        elseif d:IsA("BasePart") and d.Material == Enum.Material.Neon then
            d.Material = Enum.Material.SmoothPlastic
        end
    end
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
    task.wait(0.4)
    TweenService:Create(bg, TweenInfo.new(0.5), { BackgroundTransparency = 0.25 }):Play()
    setLids(0.55, 0.4)
    task.wait(0.5)
    setLids(0.9, 0.16); task.wait(0.18)
    setLids(0, 0.35); task.wait(0.4)

    showThought("The power's out...", 1.6)
    TweenService:Create(camera, TweenInfo.new(1.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = standCF }):Play()
    showThought("I have to get it running again. And finish my project.", 2.4)

    TweenService:Create(topBar, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Size = UDim2.new(1,0,0,0) }):Play()
    TweenService:Create(botBar, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Size = UDim2.new(1,0,0,0) }):Play()
    TweenService:Create(bg, TweenInfo.new(1.0, Enum.EasingStyle.Quad), { BackgroundTransparency = 1 }):Play()
    task.wait(1.05)

    for _, c in conns do c:Disconnect() end
    set:Destroy(); gui:Destroy()
    strikeCrack:Destroy()
    thunderclap:Destroy()
    if ambientPeople and ambientPeople.Parent == ReplicatedStorage then
        ambientPeople.Parent = workspace
    end
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
