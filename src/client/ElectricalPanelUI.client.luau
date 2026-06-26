--!strict
--[[
    ElectricalPanelUI.client.luau
    Wire puzzle mini-game for repairing sabotaged electrical panels during Night 2.

    The player clicks a coloured circle on either side of the panel — a live wire
    then springs from that circle and follows the cursor as a straight line. Clicking
    the matching colour on the OPPOSITE side completes the connection; clicking the
    wrong colour (or the same circle again) cancels it.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local GuiService = game:GetService("GuiService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Gameplay runs in LockFirstPerson (mouse pinned to screen-centre, hidden), which
-- makes the wire puzzle unusable — so free the cursor while the panel is open and
-- restore it on close.
local Shared = ReplicatedStorage:WaitForChild("Shared")
local CursorManager = require(Shared:WaitForChild("CursorManager"))

-- The puzzle ScreenGui uses IgnoreGuiInset = true, so its AbsolutePosition space
-- starts at the true top-left of the screen. UserInputService:GetMouseLocation()
-- is measured from BELOW the topbar, so we add the inset to line the cursor up with
-- the wire endpoints — without this the drag line and the drop hit-test are off by
-- the topbar height and connections silently miss.
local function mouseInGuiSpace(): Vector2
    return UserInputService:GetMouseLocation() + GuiService:GetGuiInset()
end

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PanelRepaired = Remotes:WaitForChild("PanelRepaired") :: RemoteEvent
local OpenPanelPuzzle = Remotes:WaitForChild("OpenPanelPuzzle") :: RemoteEvent
local SabotageEvent = Remotes:WaitForChild("SabotageEvent") :: RemoteEvent
local GameStateChanged = Remotes:WaitForChild("GameStateChanged") :: RemoteEvent

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local isNight2 = false

-- ============================================================
-- WIRE COLORS
-- ============================================================
local WIRE_COLORS = {
    { name = "Red", color = Color3.fromRGB(220, 40, 40) },
    { name = "Blue", color = Color3.fromRGB(40, 100, 220) },
    { name = "Green", color = Color3.fromRGB(40, 200, 80) },
    { name = "Yellow", color = Color3.fromRGB(230, 200, 40) },
}

-- ============================================================
-- STATE
-- ============================================================
type Endpoint = { side: string, index: number, button: TextButton }

local puzzleGui: ScreenGui? = nil
local connectedCount = 0
local currentPanelId: string? = nil
local rightEndpoints: { [number]: TextButton } = {}
local leftEndpoints: { [number]: TextButton } = {}
local connected: { [number]: boolean } = {} -- keyed by colour index
local selected: Endpoint? = nil -- the circle the player clicked first
local dragLine: Frame? = nil -- the live wire following the cursor
local dragConn: RBXScriptConnection? = nil

-- Forward declarations: defined further down but used by handlers above them.
local getNearestNGMIDistance: () -> number
local highlightSelection: () -> ()
local clearSelection: () -> ()
local startDrag: (ep: Endpoint) -> ()
local connectWire: (a: Endpoint, b: Endpoint) -> ()
local onEndpointClicked: (ep: Endpoint) -> ()
local puzzleComplete: () -> ()
local closePuzzle: () -> ()

-- ============================================================
-- LINE DRAWING UTILITY
-- ============================================================
--- Stretch/rotate an existing line frame so it runs from `from` to `to`.
--- Roblox rotates a GuiObject about its CENTRE, so the line is anchored (0.5, 0.5)
--- and positioned at the MIDPOINT of the two ends — then a rotation keeps both
--- endpoints exactly on `from`/`to`. (Anchoring at the left edge instead makes the
--- line swing around that edge as the angle changes, which is what made the drag
--- wire spaz out.)
local function positionLine(line: Frame, from: Vector2, to: Vector2)
    local dx = to.X - from.X
    local dy = to.Y - from.Y
    local length = math.sqrt(dx * dx + dy * dy)
    local angle = math.atan2(dy, dx)
    local thickness = line.Size.Y.Offset
    local midX = (from.X + to.X) / 2
    local midY = (from.Y + to.Y) / 2

    line.Size = UDim2.new(0, length, 0, thickness)
    line.Position = UDim2.new(0, midX, 0, midY)
    line.Rotation = math.deg(angle)
end

local function drawLine(parent: GuiObject, from: Vector2, to: Vector2, color: Color3, thickness: number): Frame
    local line = Instance.new("Frame")
    line.Name = "WireLine"
    line.AnchorPoint = Vector2.new(0.5, 0.5)
    line.Size = UDim2.new(0, 0, 0, thickness)
    line.BackgroundColor3 = color
    line.BorderSizePixel = 0
    line.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, thickness / 2)
    corner.Parent = line

    positionLine(line, from, to)
    return line
end

-- ============================================================
-- GEOMETRY HELPERS
-- ============================================================
local function getWireArea(): Frame?
    if not puzzleGui then return nil end
    local panel = puzzleGui:FindFirstChild("Panel")
    local wireArea = panel and panel:FindFirstChild("WireArea")
    if wireArea and wireArea:IsA("Frame") then
        return wireArea
    end
    return nil
end

--- Centre of an endpoint button, expressed in the WireArea's local pixel space.
local function endpointCenter(button: GuiObject, wireArea: Frame): Vector2
    local p = button.AbsolutePosition + button.AbsoluteSize / 2 - wireArea.AbsolutePosition
    return Vector2.new(p.X, p.Y)
end

-- ============================================================
-- PUZZLE UI
-- ============================================================
local function createPuzzle(panelId: string)
    if puzzleGui then
        closePuzzle() -- tears down the previous panel AND pops its cursor push
    end

    CursorManager.push()
    currentPanelId = panelId
    connectedCount = 0
    rightEndpoints = {}
    leftEndpoints = {}
    connected = {}
    selected = nil
    dragLine = nil
    dragConn = nil

    puzzleGui = Instance.new("ScreenGui")
    puzzleGui.Name = "ElectricalPanel"
    puzzleGui.DisplayOrder = 150
    puzzleGui.IgnoreGuiInset = true
    puzzleGui.Parent = playerGui

    -- Full panel background
    local bg = Instance.new("Frame")
    bg.Name = "Background"
    bg.Size = UDim2.new(1, 0, 1, 0)
    bg.BackgroundColor3 = Color3.fromRGB(10, 10, 15)
    bg.BackgroundTransparency = 0.15
    bg.BorderSizePixel = 0
    bg.Parent = puzzleGui

    -- Panel frame
    local panel = Instance.new("Frame")
    panel.Name = "Panel"
    panel.Size = UDim2.new(0, 500, 0, 400)
    panel.Position = UDim2.new(0.5, -250, 0.5, -200)
    panel.BackgroundColor3 = Color3.fromRGB(50, 55, 60)
    panel.BorderSizePixel = 0
    panel.Parent = puzzleGui

    local panelCorner = Instance.new("UICorner")
    panelCorner.CornerRadius = UDim.new(0, 12)
    panelCorner.Parent = panel

    local panelStroke = Instance.new("UIStroke")
    panelStroke.Color = Color3.fromRGB(100, 100, 110)
    panelStroke.Thickness = 3
    panelStroke.Parent = panel

    -- Title
    local title = Instance.new("TextLabel")
    title.Name = "Title"
    title.Size = UDim2.new(1, 0, 0, 40)
    title.Position = UDim2.new(0, 0, 0, 10)
    title.BackgroundTransparency = 1
    title.Text = "⚡ ELECTRICAL PANEL - RECONNECT WIRES ⚡"
    title.TextSize = 20
    title.Font = Enum.Font.GothamBold
    title.TextColor3 = Color3.fromRGB(255, 200, 50)
    title.Parent = panel

    -- Close button
    local closeBtn = Instance.new("TextButton")
    closeBtn.Name = "CloseBtn"
    closeBtn.Size = UDim2.new(0, 36, 0, 36)
    closeBtn.Position = UDim2.new(1, -44, 0, 8)
    closeBtn.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
    closeBtn.Text = "✕"
    closeBtn.TextSize = 18
    closeBtn.Font = Enum.Font.GothamBold
    closeBtn.TextColor3 = Color3.new(1, 1, 1)
    closeBtn.Parent = panel

    local closeBtnCorner = Instance.new("UICorner")
    closeBtnCorner.CornerRadius = UDim.new(0, 8)
    closeBtnCorner.Parent = closeBtn

    closeBtn.Activated:Connect(function()
        closePuzzle()
    end)

    -- Wire area
    local wireArea = Instance.new("Frame")
    wireArea.Name = "WireArea"
    wireArea.Size = UDim2.new(1, -40, 0, 280)
    wireArea.Position = UDim2.new(0, 20, 0, 60)
    wireArea.BackgroundColor3 = Color3.fromRGB(30, 32, 35)
    wireArea.BorderSizePixel = 0
    wireArea.Parent = panel

    local wireCorner = Instance.new("UICorner")
    wireCorner.CornerRadius = UDim.new(0, 8)
    wireCorner.Parent = wireArea

    -- Clicking empty space in the wire area cancels the wire in progress.
    local cancelCatcher = Instance.new("TextButton")
    cancelCatcher.Name = "CancelCatcher"
    cancelCatcher.Size = UDim2.new(1, 0, 1, 0)
    cancelCatcher.BackgroundTransparency = 1
    cancelCatcher.Text = ""
    cancelCatcher.AutoButtonColor = false
    cancelCatcher.ZIndex = 0 -- behind the endpoints/wires
    cancelCatcher.Parent = wireArea
    cancelCatcher.Activated:Connect(function()
        if selected then
            clearSelection()
        end
    end)

    -- Create shuffled right-side order
    local rightOrder = { 1, 2, 3, 4 }
    for i = #rightOrder, 2, -1 do
        local j = math.random(1, i)
        rightOrder[i], rightOrder[j] = rightOrder[j], rightOrder[i]
    end

    -- Create wire endpoints
    for i = 1, 4 do
        local wireColor = WIRE_COLORS[i]
        local yPos = 20 + (i - 1) * 65

        -- Left endpoint (source)
        local leftPoint = Instance.new("TextButton")
        leftPoint.Name = "Left_" .. i
        leftPoint.Size = UDim2.new(0, 50, 0, 50)
        leftPoint.Position = UDim2.new(0, 15, 0, yPos)
        leftPoint.BackgroundColor3 = wireColor.color
        leftPoint.Text = ""
        leftPoint.ZIndex = 2
        leftPoint.Parent = wireArea

        local leftCorner = Instance.new("UICorner")
        leftCorner.CornerRadius = UDim.new(0.5, 0)
        leftCorner.Parent = leftPoint

        local leftStroke = Instance.new("UIStroke")
        leftStroke.Color = Color3.new(1, 1, 1)
        leftStroke.Thickness = 2
        leftStroke.Transparency = 0.5
        leftStroke.Parent = leftPoint

        -- Label
        local leftLabel = Instance.new("TextLabel")
        leftLabel.Size = UDim2.new(0, 60, 0, 50)
        leftLabel.Position = UDim2.new(0, 70, 0, yPos)
        leftLabel.BackgroundTransparency = 1
        leftLabel.Text = wireColor.name
        leftLabel.TextSize = 16
        leftLabel.Font = Enum.Font.GothamBold
        leftLabel.TextColor3 = wireColor.color
        leftLabel.TextXAlignment = Enum.TextXAlignment.Left
        leftLabel.Parent = wireArea

        leftEndpoints[i] = leftPoint

        -- Click a left circle to start (or finish) a wire of this colour.
        leftPoint.Activated:Connect(function()
            onEndpointClicked({ side = "left", index = i, button = leftPoint })
        end)

        -- Right endpoint (target) - shuffled position
        local rightIndex = rightOrder[i]
        local rightYPos = 20 + (i - 1) * 65

        local rightPoint = Instance.new("TextButton")
        rightPoint.Name = "Right_" .. rightIndex
        rightPoint.Size = UDim2.new(0, 50, 0, 50)
        rightPoint.Position = UDim2.new(1, -65, 0, rightYPos)
        rightPoint.BackgroundColor3 = WIRE_COLORS[rightIndex].color
        rightPoint.Text = ""
        rightPoint.ZIndex = 2
        rightPoint.Parent = wireArea

        local rightCorner = Instance.new("UICorner")
        rightCorner.CornerRadius = UDim.new(0.5, 0)
        rightCorner.Parent = rightPoint

        local rightStroke = Instance.new("UIStroke")
        rightStroke.Color = Color3.new(1, 1, 1)
        rightStroke.Thickness = 2
        rightStroke.Transparency = 0.5
        rightStroke.Parent = rightPoint

        local rightLabel = Instance.new("TextLabel")
        rightLabel.Size = UDim2.new(0, 60, 0, 50)
        rightLabel.Position = UDim2.new(1, -130, 0, rightYPos)
        rightLabel.BackgroundTransparency = 1
        rightLabel.Text = WIRE_COLORS[rightIndex].name
        rightLabel.TextSize = 16
        rightLabel.Font = Enum.Font.GothamBold
        rightLabel.TextColor3 = WIRE_COLORS[rightIndex].color
        rightLabel.TextXAlignment = Enum.TextXAlignment.Right
        rightLabel.Parent = wireArea

        rightEndpoints[rightIndex] = rightPoint

        -- Click a right circle to start (or finish) a wire of this colour.
        rightPoint.Activated:Connect(function()
            onEndpointClicked({ side = "right", index = rightIndex, button = rightPoint })
        end)
    end

    -- Instruction hint
    local hint = Instance.new("TextLabel")
    hint.Name = "Hint"
    hint.Size = UDim2.new(1, 0, 0, 22)
    hint.Position = UDim2.new(0, 0, 1, -58)
    hint.BackgroundTransparency = 1
    hint.Text = "Click a circle, then click the same colour on the other side"
    hint.TextSize = 14
    hint.Font = Enum.Font.Gotham
    hint.TextColor3 = Color3.fromRGB(180, 180, 190)
    hint.Parent = panel

    -- NGMI warning label
    local warningLabel = Instance.new("TextLabel")
    warningLabel.Name = "Warning"
    warningLabel.Size = UDim2.new(1, 0, 0, 30)
    warningLabel.Position = UDim2.new(0, 0, 1, -35)
    warningLabel.BackgroundTransparency = 1
    warningLabel.Text = ""
    warningLabel.TextSize = 16
    warningLabel.Font = Enum.Font.GothamBold
    warningLabel.TextColor3 = Color3.fromRGB(255, 50, 50)
    warningLabel.Parent = panel

    -- NGMI proximity warning loop
    task.spawn(function()
        while puzzleGui and puzzleGui.Parent do
            local dist = getNearestNGMIDistance()
            if dist < 20 and warningLabel.Parent then
                warningLabel.Text = "⚠️ WARNING: HOSTILE DETECTED NEARBY ⚠️"
                warningLabel.TextTransparency = 0
            elseif dist < 35 and warningLabel.Parent then
                warningLabel.Text = "⚠️ Movement detected in hallway..."
                warningLabel.TextTransparency = 0.3
            elseif warningLabel.Parent then
                warningLabel.Text = ""
            end
            task.wait(0.5)
        end
    end)
end

function getNearestNGMIDistance(): number
    local character = player.Character
    if not character then return math.huge end
    local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
    if not rootPart then return math.huge end

    local nearest = math.huge
    for _, ngmi in CollectionService:GetTagged("NGMI") do
        if ngmi:IsA("Model") then
            local ngmiRoot = ngmi:FindFirstChild("HumanoidRootPart") or ngmi.PrimaryPart
            if ngmiRoot and ngmiRoot:IsA("BasePart") then
                local dist = (ngmiRoot.Position - rootPart.Position).Magnitude
                if dist < nearest then nearest = dist end
            end
        end
    end
    return nearest
end

-- ============================================================
-- CONNECTION (click a circle, drag a live wire, click the match)
-- ============================================================

--- Brief red full-panel flash for a wrong match.
local function flashWrong()
    if not puzzleGui then return end
    local panel = puzzleGui:FindFirstChild("Panel") :: Frame?
    if not panel then return end
    local flash = Instance.new("Frame")
    flash.Size = UDim2.new(1, 0, 1, 0)
    flash.BackgroundColor3 = Color3.fromRGB(255, 0, 0)
    flash.BackgroundTransparency = 0.7
    flash.BorderSizePixel = 0
    flash.ZIndex = 10
    flash.Parent = panel
    TweenService:Create(flash, TweenInfo.new(0.3), { BackgroundTransparency = 1 }):Play()
    task.delay(0.3, function()
        if flash.Parent then flash:Destroy() end
    end)
end

--- Show which circle is currently selected (fat white ring on it).
function highlightSelection()
    local function apply(map: { [number]: TextButton }, side: string)
        for idx, btn in map do
            local stroke = btn:FindFirstChildOfClass("UIStroke")
            if stroke then
                local isSel = selected ~= nil and selected.index == idx and selected.side == side
                stroke.Thickness = isSel and 4 or 2
                stroke.Transparency = isSel and 0 or 0.5
            end
        end
    end
    apply(leftEndpoints, "left")
    apply(rightEndpoints, "right")
end

--- Drop any wire in progress (the live line + selection).
function clearSelection()
    selected = nil
    if dragConn then
        dragConn:Disconnect()
        dragConn = nil
    end
    if dragLine then
        dragLine:Destroy()
        dragLine = nil
    end
    highlightSelection()
end

--- Begin a wire at `ep`; the live line then tracks the cursor each frame.
function startDrag(ep: Endpoint)
    local wireArea = getWireArea()
    if not wireArea then return end

    -- Replace any wire already in progress.
    if dragConn then
        dragConn:Disconnect()
        dragConn = nil
    end
    if dragLine then
        dragLine:Destroy()
        dragLine = nil
    end

    selected = ep
    local origin = endpointCenter(ep.button, wireArea)

    local line = drawLine(wireArea, origin, origin, WIRE_COLORS[ep.index].color, 6)
    line.Name = "DragLine"
    line.BackgroundTransparency = 0.15
    line.ZIndex = 1 -- under the circles, over the cancel-catcher
    dragLine = line

    dragConn = RunService.RenderStepped:Connect(function()
        if not dragLine or not selected then return end
        local area = getWireArea()
        if not area then return end
        local from = endpointCenter(ep.button, area)
        local mouse = mouseInGuiSpace() - area.AbsolutePosition
        positionLine(dragLine, from, Vector2.new(mouse.X, mouse.Y))
    end)

    highlightSelection()
end

--- Draw the permanent connection between two endpoints and bookkeep.
function connectWire(a: Endpoint, b: Endpoint)
    local wireArea = getWireArea()
    if not wireArea then return end

    local from = endpointCenter(a.button, wireArea)
    local to = endpointCenter(b.button, wireArea)

    local line = drawLine(wireArea, from, to, WIRE_COLORS[a.index].color, 6)
    line.Name = "Connected_" .. a.index
    line.ZIndex = 1

    -- Spark at the destination circle.
    local sparkFlash = Instance.new("Frame")
    sparkFlash.Size = UDim2.new(0, 30, 0, 30)
    sparkFlash.Position = UDim2.new(0, to.X - 15, 0, to.Y - 15)
    sparkFlash.BackgroundColor3 = Color3.fromRGB(255, 255, 200)
    sparkFlash.BorderSizePixel = 0
    sparkFlash.ZIndex = 3
    sparkFlash.Parent = wireArea
    local sparkCorner = Instance.new("UICorner")
    sparkCorner.CornerRadius = UDim.new(0.5, 0)
    sparkCorner.Parent = sparkFlash
    TweenService:Create(sparkFlash, TweenInfo.new(0.3), {
        Size = UDim2.new(0, 60, 0, 60),
        Position = UDim2.new(0, to.X - 30, 0, to.Y - 30),
        BackgroundTransparency = 1,
    }):Play()
    task.delay(0.3, function()
        if sparkFlash.Parent then sparkFlash:Destroy() end
    end)

    -- Lock both ends so they can't be reused.
    for _, btn in { a.button, b.button } do
        btn.Active = false
        btn.AutoButtonColor = false
        btn.BackgroundTransparency = 0.5
    end
    connected[a.index] = true

    connectedCount += 1
    if connectedCount >= 4 then
        puzzleComplete()
    end
end

--- Routes every endpoint click: start a wire, re-pick, complete, or reject.
function onEndpointClicked(ep: Endpoint)
    if connected[ep.index] then return end -- this colour is already wired up

    -- Nothing in progress → start a new wire here.
    if not selected then
        startDrag(ep)
        return
    end

    -- Clicked the exact circle we started from → cancel.
    if selected.side == ep.side and selected.index == ep.index then
        clearSelection()
        return
    end

    -- Clicked another circle on the SAME side → start over from this one.
    if selected.side == ep.side then
        startDrag(ep)
        return
    end

    -- Opposite side: a match only if the colours line up.
    if ep.index == selected.index then
        local first = selected
        clearSelection()
        connectWire(first, ep)
    else
        flashWrong()
        clearSelection()
    end
end

-- ============================================================
-- PUZZLE COMPLETION
-- ============================================================
function puzzleComplete()
    if not puzzleGui or not currentPanelId then return end

    clearSelection()

    -- Fire server
    PanelRepaired:FireServer(currentPanelId)

    -- Success UI
    local panel = puzzleGui:FindFirstChild("Panel") :: Frame?
    if panel then
        -- Green flash
        local flash = Instance.new("Frame")
        flash.Size = UDim2.new(1, 0, 1, 0)
        flash.BackgroundColor3 = Color3.fromRGB(0, 255, 100)
        flash.BackgroundTransparency = 0.5
        flash.BorderSizePixel = 0
        flash.ZIndex = 10
        flash.Parent = panel

        TweenService:Create(flash, TweenInfo.new(0.8), {
            BackgroundTransparency = 1,
        }):Play()

        -- Success text
        local successLabel = Instance.new("TextLabel")
        successLabel.Size = UDim2.new(1, 0, 0.3, 0)
        successLabel.Position = UDim2.new(0, 0, 0.35, 0)
        successLabel.BackgroundTransparency = 1
        successLabel.Text = "⚡ POWER RESTORED ⚡"
        successLabel.TextSize = 36
        successLabel.Font = Enum.Font.GothamBold
        successLabel.TextColor3 = Color3.fromRGB(100, 255, 150)
        successLabel.TextStrokeTransparency = 0.3
        successLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
        successLabel.ZIndex = 11
        successLabel.Parent = panel
    end

    -- Auto-close after 1.5s
    task.delay(1.5, function()
        closePuzzle()
    end)
end

function closePuzzle()
    local wasOpen = puzzleGui ~= nil

    -- Stop the live wire loop before we tear the GUI down.
    if dragConn then
        dragConn:Disconnect()
        dragConn = nil
    end
    dragLine = nil
    selected = nil

    if puzzleGui then
        puzzleGui:Destroy()
        puzzleGui = nil
    end
    currentPanelId = nil

    if wasOpen then
        CursorManager.pop()
    end
end

-- ============================================================
-- INPUT HANDLING
-- ============================================================
-- ESC to close
UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
    if input.KeyCode == Enum.KeyCode.Escape and puzzleGui then
        closePuzzle()
    end
end)

-- ============================================================
-- EVENT LISTENERS
-- ============================================================
SabotageEvent.OnClientEvent:Connect(function(data: { panelId: string, zone: number })
    -- Panel is now sabotaged — ProximityPrompt on the panel will trigger the puzzle
    -- The InteractionManager handles ProximityPrompt activation
end)

-- The server opens the puzzle for us (after its wall / proximity checks) by firing
-- OpenPanelPuzzle — see InteractionManager.handleElectricalPanel. Driving it from
-- the server keeps the through-wall guard authoritative.
OpenPanelPuzzle.OnClientEvent:Connect(function(data: { panelId: string })
    if isNight2 and data and data.panelId then
        createPuzzle(data.panelId)
    end
end)

GameStateChanged.OnClientEvent:Connect(function(data: { phase: number })
    isNight2 = (data.phase == 3)
    if not isNight2 then
        closePuzzle()
    end
end)

print("[ElectricalPanelUI] Initialized - wire puzzle ready")
