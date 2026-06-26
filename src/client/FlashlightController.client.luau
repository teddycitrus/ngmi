--!strict
--[[
    FlashlightController.client.luau
    Phone flashlight system with battery drain and NGMI EMF interference.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local FlashlightToggle = Remotes:WaitForChild("FlashlightToggle") :: RemoteEvent
local FlashlightRecharge = Remotes:WaitForChild("FlashlightRecharge") :: RemoteEvent
local GameStateChanged = Remotes:WaitForChild("GameStateChanged") :: RemoteEvent

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

-- ============================================================
-- CONFIGURATION
-- ============================================================
local CONFIG = {
    spotAngle = 45,
    spotRange = 42,
    brightness = 2,
    color = Color3.fromRGB(255, 245, 225),
    batteryMax = 100,
    -- A full charge lasts 80 seconds (100 / 1.25). There is NO passive
    -- recharge — the only way to top up is to consume a Battery item.
    drainRate = 100 / 80, -- per second when on → 80s of light on a full charge
    lowBatteryThreshold = 20,
    reactivateThreshold = 10,
    emfInterferenceRange = 20,
    toggleKey = Enum.KeyCode.F,
}

-- ============================================================
-- STATE
-- ============================================================
local isNight2 = false
local flashlightOn = false
local battery = CONFIG.batteryMax
local batteryDead = false
local spotlight: SpotLight? = nil
local emitterPart: Part? = nil
local renderConn: RBXScriptConnection? = nil
local updateConnection: RBXScriptConnection? = nil
local mobileButton: TextButton? = nil
local batteryBar: Frame? = nil
local batteryFill: Frame? = nil

-- Forward declaration: toggleFlashlight is defined below but referenced by the
-- UI button handlers created above it.
local toggleFlashlight: () -> ()

-- ============================================================
-- FLASHLIGHT RIG (camera-tracked SpotLight)
-- ============================================================
-- A first-person flashlight should light the cone the player is facing, originating
-- from them. We track a tiny invisible part to the camera each frame and hang a
-- SpotLight off it — the SpotLight casts exactly that cone of illumination (no
-- particles), aimed wherever the player looks (pitch included).
local function destroyRig()
    if renderConn then
        renderConn:Disconnect()
        renderConn = nil
    end
    if emitterPart then
        emitterPart:Destroy()
        emitterPart = nil
    end
    spotlight = nil
end

local function createRig()
    destroyRig()

    local e = Instance.new("Part")
    e.Name = "FlashlightEmitter"
    e.Size = Vector3.new(0.2, 0.2, 0.2)
    e.Transparency = 1
    e.Anchored = true
    e.CanCollide = false
    e.CanQuery = false -- never block raycasts (wall checks, NGMI vision, etc.)
    e.CanTouch = false
    e.CastShadow = false
    e.Parent = workspace
    emitterPart = e

    -- A SpotLight casts exactly the cone of illumination we want — origin at the
    -- emitter, fanning out along its front face. No visible particles; it just lights
    -- whatever surfaces fall inside the cone.
    local light = Instance.new("SpotLight")
    light.Name = "PhoneFlashlight"
    light.Angle = CONFIG.spotAngle
    light.Range = CONFIG.spotRange
    light.Brightness = CONFIG.brightness
    light.Color = CONFIG.color
    light.Face = Enum.NormalId.Front
    light.Enabled = false
    light.Parent = e
    spotlight = light

    -- Track the camera every frame so the cone points exactly where the player looks,
    -- nudged forward + down so it reads as a held light originating from the player.
    renderConn = RunService.RenderStepped:Connect(function()
        local cam = workspace.CurrentCamera
        if emitterPart and cam then
            emitterPart.CFrame = cam.CFrame * CFrame.new(0.4, -0.6, -1)
        end
    end)
end

-- ============================================================
-- MOBILE UI
-- ============================================================
local function createMobileUI()
    if not UserInputService.TouchEnabled then return end

    local gui = Instance.new("ScreenGui")
    gui.Name = "FlashlightUI"
    gui.DisplayOrder = 20
    gui.ResetOnSpawn = false
    gui.Parent = playerGui

    -- Toggle button
    mobileButton = Instance.new("TextButton")
    mobileButton.Name = "FlashlightToggle"
    mobileButton.Size = UDim2.new(0, 56, 0, 56)
    mobileButton.Position = UDim2.new(0, 16, 1, -180)
    mobileButton.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
    mobileButton.Text = "🔦"
    mobileButton.TextSize = 28
    mobileButton.Font = Enum.Font.GothamBold
    mobileButton.TextColor3 = Color3.new(1, 1, 1)
    mobileButton.Parent = gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 12)
    corner.Parent = mobileButton

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(80, 80, 100)
    stroke.Thickness = 2
    stroke.Parent = mobileButton

    -- Battery indicator bar under button
    batteryBar = Instance.new("Frame")
    batteryBar.Name = "BatteryBar"
    batteryBar.Size = UDim2.new(0, 56, 0, 6)
    batteryBar.Position = UDim2.new(0, 16, 1, -120)
    batteryBar.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
    batteryBar.BorderSizePixel = 0
    batteryBar.Parent = gui

    local barCorner = Instance.new("UICorner")
    barCorner.CornerRadius = UDim.new(0, 3)
    barCorner.Parent = batteryBar

    batteryFill = Instance.new("Frame")
    batteryFill.Name = "Fill"
    batteryFill.Size = UDim2.new(1, 0, 1, 0)
    batteryFill.BackgroundColor3 = Color3.fromRGB(100, 255, 100)
    batteryFill.BorderSizePixel = 0
    batteryFill.Parent = batteryBar

    local fillCorner = Instance.new("UICorner")
    fillCorner.CornerRadius = UDim.new(0, 3)
    fillCorner.Parent = batteryFill

    mobileButton.Activated:Connect(function()
        toggleFlashlight()
    end)
end

-- Also create battery bar for PC
local function createBatteryUI()
    local gui = playerGui:FindFirstChild("FlashlightUI")
    if not gui then
        gui = Instance.new("ScreenGui")
        gui.Name = "FlashlightUI"
        gui.DisplayOrder = 20
        gui.ResetOnSpawn = false
        gui.Parent = playerGui
    end

    if not batteryBar then
        batteryBar = Instance.new("Frame")
        batteryBar.Name = "BatteryBar"
        batteryBar.Size = UDim2.new(0, 120, 0, 8)
        -- Sit ABOVE the energy bar (bottom-left, ~60px tall) so they don't overlap
        batteryBar.Position = UDim2.new(0, 16, 1, -78)
        batteryBar.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
        batteryBar.BorderSizePixel = 0
        batteryBar.Parent = gui

        local barCorner = Instance.new("UICorner")
        barCorner.CornerRadius = UDim.new(0, 4)
        barCorner.Parent = batteryBar

        batteryFill = Instance.new("Frame")
        batteryFill.Name = "Fill"
        batteryFill.Size = UDim2.new(1, 0, 1, 0)
        batteryFill.BackgroundColor3 = Color3.fromRGB(100, 255, 100)
        batteryFill.BorderSizePixel = 0
        batteryFill.Parent = batteryBar

        local fillCorner = Instance.new("UICorner")
        fillCorner.CornerRadius = UDim.new(0, 4)
        fillCorner.Parent = batteryFill

        -- Label
        local label = Instance.new("TextLabel")
        label.Name = "Label"
        label.Size = UDim2.new(0, 120, 0, 16)
        label.Position = UDim2.new(0, 16, 1, -96)
        label.BackgroundTransparency = 1
        label.Font = Enum.Font.Code
        label.TextSize = 12
        label.TextColor3 = Color3.fromRGB(200, 200, 200)
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Text = "🔦 BATTERY"
        label.Parent = gui
    end
end

-- ============================================================
-- TOGGLE LOGIC
-- ============================================================
function toggleFlashlight()
    if not isNight2 then return end

    if not flashlightOn then
        -- Turn on
        if batteryDead and battery < CONFIG.reactivateThreshold then
            return -- Must recharge first
        end
        batteryDead = false
        flashlightOn = true

        if not emitterPart or not emitterPart.Parent then
            createRig()
        end
        if spotlight then
            spotlight.Enabled = true
        end

        -- Update mobile button
        if mobileButton then
            mobileButton.BackgroundColor3 = Color3.fromRGB(255, 220, 100)
            mobileButton.TextColor3 = Color3.fromRGB(30, 30, 30)
        end
    else
        -- Turn off
        flashlightOn = false
        if spotlight then
            spotlight.Enabled = false
        end

        if mobileButton then
            mobileButton.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
            mobileButton.TextColor3 = Color3.new(1, 1, 1)
        end
    end

    FlashlightToggle:FireServer(flashlightOn)
end

-- ============================================================
-- UPDATE LOOP
-- ============================================================
local flickerAccum = 0

local function startUpdateLoop()
    updateConnection = RunService.Heartbeat:Connect(function(dt: number)
        if not isNight2 then return end

        -- Battery management
        if flashlightOn then
            battery = math.max(0, battery - CONFIG.drainRate * dt)
            if battery <= 0 then
                batteryDead = true
                flashlightOn = false
                if spotlight then spotlight.Enabled = false end
                if mobileButton then
                    mobileButton.BackgroundColor3 = Color3.fromRGB(60, 20, 20)
                end
            end
        end
        -- No passive recharge: the battery only refills when a Battery item
        -- is consumed (see FlashlightRecharge below).

        -- Update battery UI
        if batteryFill then
            local pct = battery / CONFIG.batteryMax
            batteryFill.Size = UDim2.new(pct, 0, 1, 0)
            if pct > 0.5 then
                batteryFill.BackgroundColor3 = Color3.fromRGB(100, 255, 100)
            elseif pct > 0.2 then
                batteryFill.BackgroundColor3 = Color3.fromRGB(255, 200, 50)
            else
                batteryFill.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
            end
        end

        -- Flashlight effects
        if flashlightOn and spotlight and spotlight.Parent then
            local baseBrightness = CONFIG.brightness

            -- Low battery flicker
            if battery < CONFIG.lowBatteryThreshold then
                flickerAccum += dt
                if flickerAccum > 0.1 then
                    flickerAccum = 0
                    if math.random() < 0.3 then
                        spotlight.Brightness = math.random() * baseBrightness * 0.5
                    else
                        spotlight.Brightness = baseBrightness
                    end
                end
            end

            -- NGMI EMF interference
            local character = player.Character
            if character then
                local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
                if rootPart then
                    local nearestDist = math.huge
                    for _, ngmi in CollectionService:GetTagged("NGMI") do
                        if ngmi:IsA("Model") then
                            local ngmiRoot = ngmi:FindFirstChild("HumanoidRootPart") or ngmi.PrimaryPart
                            if ngmiRoot and ngmiRoot:IsA("BasePart") then
                                local dist = (ngmiRoot.Position - rootPart.Position).Magnitude
                                if dist < nearestDist then nearestDist = dist end
                            end
                        end
                    end

                    if nearestDist < CONFIG.emfInterferenceRange then
                        local interference = 1 - (nearestDist / CONFIG.emfInterferenceRange)
                        flickerAccum += dt * (1 + interference * 5)
                        if flickerAccum > 0.05 then
                            flickerAccum = 0
                            if math.random() < interference * 0.6 then
                                spotlight.Brightness = math.random() * baseBrightness * 0.3
                                spotlight.Color = Color3.fromRGB(
                                    255,
                                    math.floor(245 - interference * 100),
                                    math.floor(225 - interference * 150)
                                )
                            else
                                spotlight.Brightness = baseBrightness
                                spotlight.Color = CONFIG.color
                            end
                        end
                    else
                        if battery >= CONFIG.lowBatteryThreshold then
                            spotlight.Brightness = baseBrightness
                            spotlight.Color = CONFIG.color
                        end
                    end
                end
            end
        end
    end)
end

-- ============================================================
-- INPUT
-- ============================================================
UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
    if gameProcessed then return end
    if input.KeyCode == CONFIG.toggleKey then
        toggleFlashlight()
    end
end)

-- ============================================================
-- BATTERY RECHARGE (consuming a Battery item)
-- ============================================================
FlashlightRecharge.OnClientEvent:Connect(function()
    battery = CONFIG.batteryMax
    batteryDead = false
    -- Pop the spotlight back to full brightness if it's currently on.
    if flashlightOn and spotlight then
        spotlight.Brightness = CONFIG.brightness
        spotlight.Color = CONFIG.color
    end
    if mobileButton and not flashlightOn then
        mobileButton.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
    end
end)

-- ============================================================
-- PHASE LISTENER
-- ============================================================
GameStateChanged.OnClientEvent:Connect(function(data: { phase: number })
    if data.phase == 3 then -- NIGHT2
        isNight2 = true
        battery = CONFIG.batteryMax
        batteryDead = false
        createRig()
        createMobileUI()
        createBatteryUI()
        startUpdateLoop()
    else
        isNight2 = false
        flashlightOn = false
        destroyRig()
        if updateConnection then
            updateConnection:Disconnect()
            updateConnection = nil
        end
    end
end)

-- The rig follows the camera (not the character), so it survives respawns. Just
-- rebuild it if it somehow went missing, and restore the on-state.
player.CharacterAdded:Connect(function()
    if not isNight2 then return end
    if not emitterPart or not emitterPart.Parent then
        createRig()
    end
    if flashlightOn then
        if spotlight then spotlight.Enabled = true end
    end
end)

print("[FlashlightController] Initialized - press F to toggle (Night 2 only)")
