--!strict
--------------------------------------------------------------------------------
-- HUD/DeathScreen.luau
-- The GAME OVER screen HUDController shows when the player dies in play, with
-- a "Return to Lobby" button (mirrors the ending screens).
--
-- show() takes a CursorManager.push(); CursorManager is reference-counted and
-- its per-frame guard pins the camera to third person with a free cursor for
-- as long as the count is above zero. So close() is the single teardown, it is
-- idempotent, and HUDController calls it on every way off the screen: the
-- button, a respawn, and any phase change.
--------------------------------------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CursorManager = require(Shared:WaitForChild("CursorManager"))
local UITheme = require(Shared:WaitForChild("UITheme"))

local GameStateChanged = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("GameStateChanged") :: RemoteEvent

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local DeathScreen = {}

local shownGui: ScreenGui? = nil

function DeathScreen.close()
    local gui = shownGui
    if not gui then
        return
    end
    shownGui = nil
    gui:Destroy()
    CursorManager.pop()
end

local function textLabel(parent: Instance, text: string, size: UDim2, pos: UDim2, font: Font, color: Color3): TextLabel
    local label = Instance.new("TextLabel")
    label.Size = size
    label.Position = pos
    label.BackgroundTransparency = 1
    label.Text = text
    label.FontFace = font
    label.TextScaled = true
    label.TextColor3 = color
    label.Parent = parent
    return label
end

function DeathScreen.show()
    if shownGui then
        return
    end

    -- Free the cursor so the "Return to Lobby" button is clickable. Gameplay runs
    -- in LockFirstPerson, which pins the mouse to screen-centre and hides it, and
    -- at first-person zoom the mouse re-locks regardless of CameraMode, so
    -- CursorManager also widens the zoom.
    CursorManager.push()

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
    shownGui = gui

    local bg = Instance.new("Frame")
    bg.Size = UDim2.new(1, 0, 1, 0)
    bg.BackgroundColor3 = Color3.fromRGB(8, 0, 0)
    bg.BackgroundTransparency = 1
    bg.BorderSizePixel = 0
    bg.Parent = gui
    TweenService:Create(bg, TweenInfo.new(1.2), { BackgroundTransparency = 0.05 }):Play()

    local title = textLabel(bg, titleText, UDim2.new(0.8, 0, 0.09, 0), UDim2.new(0.1, 0, 0.34, 0), UITheme.Font.Bold, UITheme.Color.Danger)
    title.TextTransparency = 1
    TweenService:Create(title, TweenInfo.new(2), { TextTransparency = 0 }):Play()

    local sub = textLabel(bg, subText, UDim2.new(0.6, 0, 0.032, 0), UDim2.new(0.2, 0, 0.46, 0), UITheme.Font.Regular, UITheme.Color.Dim)
    sub.TextTransparency = 1
    TweenService:Create(sub, TweenInfo.new(2.5), { TextTransparency = 0.1 }):Play()

    textLabel(bg, "GAME OVER", UDim2.new(0.6, 0, 0.022, 0), UDim2.new(0.2, 0, 0.56, 0), UITheme.Font.Mono, UITheme.Color.Faint)

    local btn = UITheme.button(bg, "Return to Lobby", 44)
    btn.Size = UDim2.fromOffset(220, 44)
    btn.Position = UDim2.new(0.5, -110, 0.66, 0)
    btn.TextSize = 15

    btn.Activated:Connect(function()
        GameStateChanged:FireServer({ requestLobby = true })
        DeathScreen.close()
    end)
end

return DeathScreen
