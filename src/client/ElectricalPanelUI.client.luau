--!strict
--[[
    ElectricalPanelUI.client.luau
    Wire puzzle mini-game for repairing sabotaged electrical panels during Night 2.

    The player presses a coloured circle on either side of the panel and a live
    wire follows the pointer. Either drag it onto the matching colour on the
    OPPOSITE side and let go, or click the circle and then click the match.
    The wrong colour cancels it, as does letting go of a drag on empty space.
    While the panel is open the character can't move and prompts are off, so a
    stray key can't walk you out of reach or reopen (and reset) the puzzle.
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
local UITheme = require(Shared:WaitForChild("UITheme"))

-- Pointer positions, in the space the buttons are hit-tested and laid out in.
-- Measured in Play with this IgnoreGuiInset ScreenGui and a 58 px inset: a
-- release over a circle reported InputObject.Position at the circle's centre
-- (AbsolutePosition + half its size), while GetMouseLocation() read 58 px
-- lower. So input positions are used as they are, and GetMouseLocation() has
-- the inset taken OFF. The old code added it on instead, leaving the live wire
-- two topbar heights below the cursor.
local lastTouch: Vector2? = nil
local function mouseInGuiSpace(): Vector2
    return lastTouch or (UserInputService:GetMouseLocation() - GuiService:GetGuiInset())
end
local function inputInGuiSpace(input: InputObject): Vector2
    return Vector2.new(input.Position.X, input.Position.Y)
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
    { name = "Red", color = Color3.fromRGB(204, 70, 62) },
    { name = "Blue", color = Color3.fromRGB(74, 124, 204) },
    { name = "Green", color = Color3.fromRGB(84, 174, 108) },
    { name = "Yellow", color = Color3.fromRGB(218, 182, 72) },
}

-- ============================================================
-- STATE
-- ============================================================
type Endpoint = { side: string, index: number, button: TextButton }

local puzzleGui: ScreenGui? = nil
local connectedCount = 0
local currentPanelId: string? = nil
local currentPanel: Instance? = nil -- the panel part, to confirm the server took the repair
local submittedGui: ScreenGui? = nil -- the puzzle this client finished itself
local rightEndpoints: { [number]: TextButton } = {}
local leftEndpoints: { [number]: TextButton } = {}
local connected: { [number]: boolean } = {} -- keyed by colour index
local selected: Endpoint? = nil -- the circle the player clicked first
local dragLine: Frame? = nil -- the live wire following the cursor
local dragConn: RBXScriptConnection? = nil
local pressedFrom: Endpoint? = nil -- the circle a press (possible drag) began on
local pressedAt = Vector2.zero
local controlsHeld = false
local promptsWereEnabled = true

-- Forward declarations: defined further down but used by handlers above them.
local getNearestNGMIDistance: () -> number
local highlightSelection: () -> ()
local clearSelection: () -> ()
local startDrag: (ep: Endpoint) -> ()
local connectWire: (a: Endpoint, b: Endpoint) -> ()
local onEndpointClicked: (ep: Endpoint) -> ()
local puzzleComplete: () -> ()
local closePuzzle: () -> ()

local onPress: (ep: Endpoint, input: InputObject) -> ()
local allEndpoints: { [GuiObject]: Endpoint } = {}

local function isPointerInput(input: InputObject): boolean
    return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

--- Freeze the character and switch off proximity prompts while the panel is
--- open (and give both back on close).
local function holdPlayer(hold: boolean)
    if hold == controlsHeld then
        return
    end
    controlsHeld = hold
    local playerScripts = player:FindFirstChild("PlayerScripts")
    local module = playerScripts and playerScripts:FindFirstChild("PlayerModule")
    if module and module:IsA("ModuleScript") then
        local ok, pm = pcall(require, module)
        local controls = ok and pm and (pm :: any):GetControls()
        if controls then
            if hold then
                controls:Disable()
            else
                controls:Enable()
            end
        end
    end
    local pps = game:GetService("ProximityPromptService")
    if hold then
        promptsWereEnabled = pps.Enabled
        pps.Enabled = false
    else
        pps.Enabled = promptsWereEnabled
    end
end

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
    allEndpoints = {}
    selected = nil
    pressedFrom = nil
    dragLine = nil
    dragConn = nil

    puzzleGui = Instance.new("ScreenGui")
    puzzleGui.Name = "ElectricalPanel"
    puzzleGui.DisplayOrder = 150
    puzzleGui.IgnoreGuiInset = true
    -- Closed explicitly on death (CharacterRemoving below). Letting a respawn
    -- wipe it skipped closePuzzle, so the cursor push leaked and the camera
    -- stayed pulled out in third person.
    puzzleGui.ResetOnSpawn = false
    puzzleGui.Parent = playerGui
    holdPlayer(true)

    -- Dim the world behind; the panel itself is a flat dark plate with a
    -- hairline edge, in the HUD's type (UITheme).
    local bg = Instance.new("Frame")
    bg.Name = "Background"
    bg.Size = UDim2.new(1, 0, 1, 0)
    bg.BackgroundColor3 = Color3.fromRGB(6, 6, 8)
    bg.BackgroundTransparency = 0.35
    bg.BorderSizePixel = 0
    bg.Parent = puzzleGui

    local panel = Instance.new("Frame")
    panel.Name = "Panel"
    panel.AnchorPoint = Vector2.new(0.5, 0.5)
    panel.Size = UDim2.new(0, 460, 0, 392)
    panel.Position = UDim2.fromScale(0.5, 0.5)
    panel.BackgroundColor3 = Color3.fromRGB(14, 15, 18)
    panel.BorderSizePixel = 0
    panel.Parent = puzzleGui
    UITheme.corner(panel, 6)
    UITheme.outline(panel, 0.86)

    local caption = UITheme.label(panel, { text = "ELECTRICAL PANEL", size = 11, font = UITheme.Font.Bold, color = UITheme.Color.Faint, shadow = false })
    caption.Position = UDim2.fromOffset(24, 20)
    caption.Size = UDim2.new(1, -120, 0, 14)

    local title = UITheme.label(panel, { text = "Reconnect the circuits", size = 20, font = UITheme.Font.Bold, shadow = false })
    title.Name = "Title"
    title.Position = UDim2.fromOffset(24, 36)
    title.Size = UDim2.new(1, -120, 0, 24)

    local closeBtn = Instance.new("TextButton")
    closeBtn.Name = "CloseBtn"
    closeBtn.AnchorPoint = Vector2.new(1, 0)
    closeBtn.Size = UDim2.new(0, 64, 0, 28)
    closeBtn.Position = UDim2.new(1, -18, 0, 20)
    closeBtn.BackgroundColor3 = UITheme.Color.Line
    closeBtn.BackgroundTransparency = 0.96
    closeBtn.AutoButtonColor = false
    closeBtn.Text = "Close"
    closeBtn.TextSize = 13
    closeBtn.FontFace = UITheme.Font.Medium
    closeBtn.TextColor3 = UITheme.Color.Dim
    closeBtn.Parent = panel
    UITheme.corner(closeBtn, 4)
    UITheme.outline(closeBtn)
    closeBtn.MouseEnter:Connect(function()
        closeBtn.TextColor3 = UITheme.Color.Text
        closeBtn.BackgroundTransparency = 0.9
    end)
    closeBtn.MouseLeave:Connect(function()
        closeBtn.TextColor3 = UITheme.Color.Dim
        closeBtn.BackgroundTransparency = 0.96
    end)
    closeBtn.Activated:Connect(function()
        closePuzzle()
    end)

    local wireArea = Instance.new("Frame")
    wireArea.Name = "WireArea"
    wireArea.Size = UDim2.new(1, -48, 0, 256)
    wireArea.Position = UDim2.new(0, 24, 0, 76)
    wireArea.BackgroundColor3 = Color3.fromRGB(9, 10, 12)
    wireArea.BorderSizePixel = 0
    wireArea.Parent = panel
    UITheme.corner(wireArea, 4)
    UITheme.outline(wireArea, 0.92)

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

    --- A terminal: a coloured stud in a dark ring, its colour named beside it.
    local function terminal(name: string, index: number, xScale: number, xOffset: number, y: number, labelRight: boolean): TextButton
        local wire = WIRE_COLORS[index]
        local stud = Instance.new("TextButton")
        stud.Name = name
        stud.AnchorPoint = Vector2.new(0.5, 0.5)
        stud.Size = UDim2.new(0, 26, 0, 26)
        stud.Position = UDim2.new(xScale, xOffset, 0, y)
        stud.BackgroundColor3 = wire.color
        stud.AutoButtonColor = false
        stud.Text = ""
        stud.ZIndex = 2
        stud.Parent = wireArea
        UITheme.corner(stud, 13)
        local ring = Instance.new("UIStroke")
        ring.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        ring.Color = Color3.new(1, 1, 1)
        ring.Thickness = 2
        ring.Transparency = 0.8
        ring.Parent = stud
        local label = UITheme.label(wireArea, {
            text = string.upper(wire.name),
            size = 11,
            font = UITheme.Font.Bold,
            color = UITheme.Color.Dim,
            alignX = if labelRight then Enum.TextXAlignment.Right else Enum.TextXAlignment.Left,
            shadow = false,
        })
        label.AnchorPoint = Vector2.new(if labelRight then 1 else 0, 0.5)
        label.Size = UDim2.new(0, 70, 0, 14)
        label.Position = UDim2.new(xScale, xOffset + (if labelRight then -22 else 22), 0, y)
        return stud
    end

    for i = 1, 4 do
        local y = 36 + (i - 1) * 61

        local leftPoint = terminal("Left_" .. i, i, 0, 30, y, false)
        leftEndpoints[i] = leftPoint
        local leftEp: Endpoint = { side = "left", index = i, button = leftPoint }
        allEndpoints[leftPoint] = leftEp
        leftPoint.InputBegan:Connect(function(input: InputObject)
            onPress(leftEp, input)
        end)

        -- Right endpoint (target) - shuffled position
        local rightIndex = rightOrder[i]
        local rightPoint = terminal("Right_" .. rightIndex, rightIndex, 1, -30, y, true)
        rightEndpoints[rightIndex] = rightPoint
        local rightEp: Endpoint = { side = "right", index = rightIndex, button = rightPoint }
        allEndpoints[rightPoint] = rightEp
        rightPoint.InputBegan:Connect(function(input: InputObject)
            onPress(rightEp, input)
        end)
    end

    local hint = UITheme.label(panel, {
        text = "Drag each wire to the terminal of the same colour.",
        size = 13,
        font = UITheme.Font.Regular,
        color = UITheme.Color.Faint,
        shadow = false,
    })
    hint.Name = "Hint"
    hint.Position = UDim2.new(0, 24, 1, -46)
    hint.Size = UDim2.new(1, -48, 0, 16)

    -- NGMI proximity warning, quiet until it matters
    local warningLabel = UITheme.label(panel, { size = 13, font = UITheme.Font.Medium, color = UITheme.Color.Danger, shadow = false })
    warningLabel.Name = "Warning"
    warningLabel.Position = UDim2.new(0, 24, 1, -28)
    warningLabel.Size = UDim2.new(1, -48, 0, 16)

    -- Bound to this panel's own gui, so a quick close and reopen can't leave
    -- the old loop running alongside the new one.
    local thisGui = puzzleGui
    task.spawn(function()
        while thisGui and thisGui.Parent do
            local dist = getNearestNGMIDistance()
            if dist < 20 and warningLabel.Parent then
                warningLabel.Text = "Something is right outside."
                warningLabel.TextTransparency = 0
            elseif dist < 35 and warningLabel.Parent then
                warningLabel.Text = "You hear movement in the hall."
                warningLabel.TextTransparency = 0.35
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
    flash.BackgroundColor3 = Color3.fromRGB(226, 72, 72)
    flash.BackgroundTransparency = 0.85
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
                stroke.Thickness = isSel and 3 or 2
                stroke.Transparency = isSel and 0.1 or 0.8
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

    local line = drawLine(wireArea, origin, origin, WIRE_COLORS[ep.index].color, 4)
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

    local line = drawLine(wireArea, from, to, WIRE_COLORS[a.index].color, 4)
    line.Name = "Connected_" .. a.index
    line.ZIndex = 1

    -- Spark at the destination circle.
    local sparkFlash = Instance.new("Frame")
    sparkFlash.Size = UDim2.new(0, 30, 0, 30)
    sparkFlash.Position = UDim2.new(0, to.X - 15, 0, to.Y - 15)
    sparkFlash.BackgroundColor3 = Color3.fromRGB(255, 246, 220)
    sparkFlash.BackgroundTransparency = 0.4
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

--- The circle under a GUI-space point, if any.
local function endpointAt(pos: Vector2): Endpoint?
    for button, ep in allEndpoints do
        local a, size = button.AbsolutePosition, button.AbsoluteSize
        local c = a + size / 2
        -- circles: within the radius, plus a little slack for a fast release
        if (pos - c).Magnitude <= size.X / 2 + 8 then
            return ep
        end
    end
    return nil
end

--- A press on a circle. With a wire already live from the other side it
--- completes (click, then click); otherwise a wire starts here and either
--- follows a drag or waits for the second click.
function onPress(ep: Endpoint, input: InputObject)
    if not isPointerInput(input) or connected[ep.index] then return end
    if input.UserInputType == Enum.UserInputType.Touch then
        lastTouch = inputInGuiSpace(input)
    end
    if selected and selected.side ~= ep.side then
        pressedFrom = nil
        onEndpointClicked(ep)
        return
    end
    pressedFrom = ep
    pressedAt = inputInGuiSpace(input)
    if not (selected and selected.index == ep.index and selected.side == ep.side) then
        startDrag(ep)
    end
end

-- Releases happen wherever the pointer is, so they are caught globally. A
-- Button's Activated only fires when press and release land on the SAME
-- button, which is why dragging a wire onto its match used to do nothing.
UserInputService.InputEnded:Connect(function(input: InputObject)
    if not (puzzleGui and pressedFrom and isPointerInput(input)) then return end
    local from = pressedFrom
    pressedFrom = nil
    local at = inputInGuiSpace(input)
    local target = endpointAt(at)
    if target and target.side ~= from.side then
        onEndpointClicked(target)
    elseif not target and (at - pressedAt).Magnitude > 12 then
        clearSelection() -- dragged and let go on nothing
    end
    -- released on the circle it started from: a click, the wire stays live
end)

UserInputService.InputChanged:Connect(function(input: InputObject)
    if input.UserInputType == Enum.UserInputType.Touch and puzzleGui then
        lastTouch = inputInGuiSpace(input)
    elseif input.UserInputType == Enum.UserInputType.MouseMovement then
        lastTouch = nil
    end
end)

player.CharacterRemoving:Connect(function()
    closePuzzle()
end)

-- ============================================================
-- PUZZLE COMPLETION
-- ============================================================
function puzzleComplete()
    if not puzzleGui or not currentPanelId then return end

    clearSelection()

    PanelRepaired:FireServer(currentPanelId)
    local panelPart = currentPanel
    local thisGui = puzzleGui
    submittedGui = thisGui

    -- Success UI
    local panel = puzzleGui:FindFirstChild("Panel") :: Frame?
    if panel then
        -- Green flash
        local flash = Instance.new("Frame")
        flash.Size = UDim2.new(1, 0, 1, 0)
        flash.BackgroundColor3 = UITheme.Color.Good
        flash.BackgroundTransparency = 0.82
        flash.BorderSizePixel = 0
        flash.ZIndex = 10
        flash.Parent = panel

        TweenService:Create(flash, TweenInfo.new(0.8), {
            BackgroundTransparency = 1,
        }):Play()

        -- Success text
        local successLabel = UITheme.label(panel, {
            text = "Restoring power",
            size = 22,
            font = UITheme.Font.Bold,
            color = UITheme.Color.Text,
            alignX = Enum.TextXAlignment.Center,
        })
        successLabel.AnchorPoint = Vector2.new(0.5, 0.5)
        successLabel.Position = UDim2.fromScale(0.5, 0.5)
        successLabel.Size = UDim2.new(1, -48, 0, 30)
        successLabel.ZIndex = 11

        -- Only claim success once the server has actually repaired the panel
        -- (it refuses a report from too far away, or after the puzzle was
        -- reopened). It used to say POWER RESTORED regardless.
        task.spawn(function()
            local t0 = os.clock()
            while panelPart and not panelPart:GetAttribute("IsRepaired") and os.clock() - t0 < 3 do
                task.wait(0.1)
            end
            if not successLabel.Parent then return end
            if not panelPart or panelPart:GetAttribute("IsRepaired") then
                successLabel.Text = "Power restored"
                successLabel.TextColor3 = UITheme.Color.Good
            else
                successLabel.Text = "The panel didn't take it. Try again."
                successLabel.TextSize = 18
                successLabel.TextColor3 = UITheme.Color.Warn
            end
            task.wait(1.5)
            if puzzleGui == thisGui then
                closePuzzle()
            end
        end)
    else
        task.delay(1.5, closePuzzle)
    end
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
    pressedFrom = nil
    lastTouch = nil

    if puzzleGui then
        puzzleGui:Destroy()
        puzzleGui = nil
    end
    currentPanelId = nil
    currentPanel = nil

    if wasOpen then
        CursorManager.pop()
        holdPlayer(false)
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
OpenPanelPuzzle.OnClientEvent:Connect(function(data: { panelId: string, panel: Instance? })
    if isNight2 and data and data.panelId then
        createPuzzle(data.panelId)
        currentPanel = data.panel
        local panelPart = data.panel
        local gui = puzzleGui
        if not (panelPart and gui) then
            return
        end
        -- Panels are shared: if a teammate fixes this one while we're still
        -- wiring it, say so and close instead of leaving a dead puzzle open.
        local conn: RBXScriptConnection
        conn = panelPart:GetAttributeChangedSignal("IsRepaired"):Connect(function()
            if not panelPart:GetAttribute("IsRepaired") then
                return
            end
            conn:Disconnect()
            if puzzleGui ~= gui or submittedGui == gui then
                return
            end
            local frame = gui:FindFirstChild("Panel")
            if frame then
                local note = UITheme.label(frame, {
                    text = "A teammate fixed this panel",
                    size = 22,
                    font = UITheme.Font.Bold,
                    color = UITheme.Color.Good,
                    alignX = Enum.TextXAlignment.Center,
                })
                note.AnchorPoint = Vector2.new(0.5, 0.5)
                note.Position = UDim2.fromScale(0.5, 0.5)
                note.Size = UDim2.new(1, -48, 0, 30)
                note.ZIndex = 11
            end
            task.delay(1.2, function()
                if puzzleGui == gui then
                    closePuzzle()
                end
            end)
        end)
        gui.Destroying:Connect(function()
            conn:Disconnect()
        end)
    end
end)

GameStateChanged.OnClientEvent:Connect(function(data: { phase: number })
    isNight2 = (data.phase == 3)
    if not isNight2 then
        closePuzzle()
    end
end)

print("[ElectricalPanelUI] Initialized - wire puzzle ready")
