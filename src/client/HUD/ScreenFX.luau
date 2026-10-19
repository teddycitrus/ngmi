--!strict
--------------------------------------------------------------------------------
-- HUD/ScreenFX.luau
-- Full-screen feedback layers for HUDController:
--   * damage: world desaturation plus a blood vignette that tracks health
--     (Day 2 and Night 2 only)
--   * atmosphere: a dark vignette and CRT scanlines, always on
--   * heartbeat: a red pulse on Night 2 when exhausted or an NGMI is close
-- All layers are non-interactive, so none can eat a click or affect cursor
-- state. ScreenFX.start(getPhase) drives the animated ones from one
-- RenderStepped connection.
--------------------------------------------------------------------------------

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local ScreenFX = {}

-- ============================================================
-- DAMAGE EFFECTS: desaturation + blood vignette tied to health
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
    if not char then
        return nil
    end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum then
        return nil
    end
    -- A loading/respawning/dead character momentarily reads Health 0; don't blast
    -- the screen red for that (death is handled by the death screen). Treat it as
    -- "no effect" so the vignette never appears unless you're actually wounded.
    if hum.Health <= 0 then
        return nil
    end
    return math.clamp(hum.Health / math.max(1, hum.MaxHealth), 0, 1)
end

local function stepDamage(dt: number, currentPhase: number)
    local pct = readHealthPct()
    local target = 0
    -- Only during the combat days (Day 2 + Night 2); Day 1 is the intro, no damage.
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
end

-- ============================================================
-- SCREEN ATMOSPHERE: CRT scanlines, vignette, heartbeat pulse
-- ============================================================
-- Three stacked passive layers on their own ScreenGui, all non-interactive
-- (Active = false, no GuiButtons) so none of them can eat a click or affect
-- cursor state. They sit below the death screen (DisplayOrder 600) and above the
-- main HUD (10).
--
-- The heartbeat is the only animated one, and it only runs during NIGHT2: it
-- reads the Energy attribute StaminaController publishes and the NGMIDistance
-- attribute NGMIClient publishes, so it costs one attribute read per frame
-- rather than a second scan over every NGMI in the venue.
-- ============================================================

local atmosGui = Instance.new("ScreenGui")
atmosGui.Name = "ScreenAtmosphere"
atmosGui.DisplayOrder = 55
atmosGui.IgnoreGuiInset = true
atmosGui.ResetOnSpawn = false
atmosGui.Parent = playerGui

--- Low-opacity dark vignette. Four edge gradients rather than one image, so it
--- needs no uploaded asset and stays crisp at any aspect ratio.
local function buildVignette(parent: Instance, thickness: number, alpha: number): Frame
    local holder = Instance.new("Frame")
    holder.Name = "Vignette"
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Active = false
    holder.ZIndex = 1
    holder.Parent = parent

    local edges = {
        { UDim2.new(1, 0, thickness, 0), UDim2.fromScale(0, 0), Enum.StartCorner.TopLeft, 90 },
        { UDim2.new(1, 0, thickness, 0), UDim2.new(0, 0, 1 - thickness, 0), Enum.StartCorner.TopLeft, 270 },
        { UDim2.new(thickness, 0, 1, 0), UDim2.fromScale(0, 0), Enum.StartCorner.TopLeft, 0 },
        { UDim2.new(thickness, 0, 1, 0), UDim2.new(1 - thickness, 0, 0, 0), Enum.StartCorner.TopLeft, 180 },
    }

    for _, e in edges do
        local band = Instance.new("Frame")
        band.Size = e[1]
        band.Position = e[2]
        band.BackgroundColor3 = Color3.new(0, 0, 0)
        band.BorderSizePixel = 0
        band.Active = false
        band.ZIndex = 1
        band.Parent = holder

        local grad = Instance.new("UIGradient")
        grad.Rotation = e[4]
        grad.Transparency = NumberSequence.new({
            NumberSequenceKeypoint.new(0, alpha),
            NumberSequenceKeypoint.new(1, 1),
        })
        grad.Parent = band
    end

    return holder
end

buildVignette(atmosGui, 0.22, 0.72)

--- CRT scanlines: evenly spaced dark rows at very low opacity. Spaced in offset
--- pixels so the line pitch stays constant instead of stretching with the window.
local function buildScanlines(parent: Instance, pitch: number, alpha: number)
    local holder = Instance.new("Frame")
    holder.Name = "Scanlines"
    holder.Size = UDim2.fromScale(1, 1)
    holder.BackgroundTransparency = 1
    holder.Active = false
    holder.ClipsDescendants = true
    holder.ZIndex = 2
    holder.Parent = parent

    -- Redrawn on resize so the rows always cover the viewport exactly.
    local function redraw()
        holder:ClearAllChildren()
        local height = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize.Y or 1080
        for y = 0, math.ceil(height), pitch do
            local line = Instance.new("Frame")
            line.Size = UDim2.new(1, 0, 0, 1)
            line.Position = UDim2.new(0, 0, 0, y)
            line.BackgroundColor3 = Color3.new(0, 0, 0)
            line.BackgroundTransparency = alpha
            line.BorderSizePixel = 0
            line.Active = false
            line.ZIndex = 2
            line.Parent = holder
        end
    end

    redraw()
    local cam = workspace.CurrentCamera
    if cam then
        cam:GetPropertyChangedSignal("ViewportSize"):Connect(redraw)
    end
end

buildScanlines(atmosGui, 3, 0.93)

--- Heartbeat vignette: a red pulse that rides on top of the static vignette when
--- the player is exhausted or something is closing in.
local heartFrame = buildVignette(atmosGui, 0.34, 1)
heartFrame.Name = "Heartbeat"
heartFrame.ZIndex = 3
for _, band in heartFrame:GetChildren() do
    if band:IsA("Frame") then
        band.BackgroundColor3 = Color3.fromRGB(90, 0, 0)
    end
end

local HEART_NGMI_RANGE = 28 -- studs; inside this the heartbeat starts
local HEART_LOW_ENERGY = 0.3 -- fraction of the energy bar that counts as exhausted
local HEART_MIN_BPM = 65
local HEART_MAX_BPM = 150

local heartPhase = 0

-- The gradients are rebuilt only when the pulse alpha actually moves, not
-- every frame: a NumberSequence per band per frame is pure garbage.
local heartGradients: { UIGradient } = {}
for _, band in heartFrame:GetChildren() do
    local grad = band:FindFirstChildOfClass("UIGradient")
    if grad then
        table.insert(heartGradients, grad)
    end
end
local heartAlpha = 1

local function stepHeartbeat(dt: number, currentPhase: number)
    -- NIGHT2 only; the daytime phases have no business with a horror pulse.
    if currentPhase ~= 3 then
        if heartFrame.Visible then
            heartFrame.Visible = false
        end
        return
    end

    local energy = (player:GetAttribute("Energy") :: number?) or 1
    local ngmiDist = (player:GetAttribute("NGMIDistance") :: number?) or 9999

    -- Two independent drivers, whichever is more urgent wins.
    local exhaustion = math.clamp((HEART_LOW_ENERGY - energy) / HEART_LOW_ENERGY, 0, 1)
    local dread = math.clamp((HEART_NGMI_RANGE - ngmiDist) / HEART_NGMI_RANGE, 0, 1)
    local intensity = math.max(exhaustion, dread)

    if intensity <= 0.01 then
        heartFrame.Visible = false
        heartPhase = 0
        return
    end
    heartFrame.Visible = true

    -- Rate scales with intensity, so a close chase on an empty bar races.
    local bpm = HEART_MIN_BPM + (HEART_MAX_BPM - HEART_MIN_BPM) * intensity
    heartPhase += dt * (bpm / 60)

    -- Double-thump: a strong systolic beat with a weaker one just behind it.
    local beat = heartPhase % 1
    local pulse = math.max(
        math.exp(-((beat - 0.0) ^ 2) / 0.004),
        math.exp(-((beat - 0.22) ^ 2) / 0.006) * 0.55
    )

    local alpha = 1 - (pulse * intensity * 0.55)
    if math.abs(alpha - heartAlpha) < 0.01 then
        return
    end
    heartAlpha = alpha
    local sequence = NumberSequence.new({
        NumberSequenceKeypoint.new(0, alpha),
        NumberSequenceKeypoint.new(1, 1),
    })
    for _, grad in heartGradients do
        grad.Transparency = sequence
    end
end

--- Start the animated layers. `getPhase` returns HUDController's current phase.
function ScreenFX.start(getPhase: () -> number)
    RunService.RenderStepped:Connect(function(dt: number)
        local phase = getPhase()
        stepDamage(dt, phase)
        stepHeartbeat(dt, phase)
    end)
end

return ScreenFX
