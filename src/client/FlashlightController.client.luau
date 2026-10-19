--!strict
--[[
    FlashlightController.client.luau
    Phone flashlight system with battery drain and NGMI EMF interference.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UITheme = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UITheme"))
local Rig = require(script.Parent:WaitForChild("Flashlight"):WaitForChild("Rig"))

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
	-- recharge, the only way to top up is to consume a Battery item.
	drainRate = 100 / 80, -- per second when on → 80s of light on a full charge
	lowBatteryThreshold = 20,
	reactivateThreshold = 10,
	emfInterferenceRange = 25,
	-- How solid the visible shaft is at its source. Subtle on purpose; a dense
	-- cone reads as fog rather than a torch.
	coneTransparency = 0.9,
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
local blinkUntil = 0 -- os.clock() until which a battery blink holds the light dark
local coneBeam: Beam? = nil
local emitterPart: Part? = nil
local updateConnection: RBXScriptConnection? = nil
local mobileButton: TextButton? = nil
local batteryFill: Frame? = nil
local batteryValue: TextLabel? = nil

-- Forward declaration: toggleFlashlight is defined below but referenced by the
-- UI button handlers created above it.
local toggleFlashlight: () -> ()

-- ============================================================
-- FLASHLIGHT RIG (Flashlight/Rig)
-- ============================================================
local function destroyRig()
	Rig.destroy()
	emitterPart, spotlight, coneBeam = nil, nil, nil
end

local function createRig()
	local parts = Rig.create(CONFIG, function()
		return flashlightOn
	end)
	emitterPart, spotlight, coneBeam = parts.emitter, parts.light, parts.cone
end

-- ============================================================
-- MOBILE UI
-- ============================================================
local function setMobileButtonState(state: "off" | "on" | "dead")
	if not mobileButton then
		return
	end
	if state == "on" then
		mobileButton.BackgroundColor3 = UITheme.Color.Text
		mobileButton.BackgroundTransparency = 0.1
		mobileButton.TextColor3 = UITheme.Color.Surface
	else
		mobileButton.BackgroundColor3 = UITheme.Color.Surface
		mobileButton.BackgroundTransparency = UITheme.Alpha.Surface
		mobileButton.TextColor3 = if state == "dead" then UITheme.Color.Danger else UITheme.Color.Text
	end
end

local function createMobileUI()
	if not UserInputService.TouchEnabled or mobileButton then
		return
	end

	local gui = Instance.new("ScreenGui")
	gui.Name = "FlashlightUI"
	gui.DisplayOrder = 20
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.Parent = playerGui

	local btn = Instance.new("TextButton")
	btn.Name = "FlashlightToggle"
	btn.AutoButtonColor = false
	btn.AnchorPoint = Vector2.new(0, 1)
	btn.Size = UDim2.fromOffset(52, 52)
	btn.Position = UDim2.new(0, UITheme.Margin, 1, -(UITheme.Margin + 72))
	btn.BorderSizePixel = 0
	btn.Text = "LIGHT"
	btn.TextSize = 11
	btn.FontFace = UITheme.Font.Bold
	btn.Parent = gui
	UITheme.corner(btn, 26)
	UITheme.outline(btn)
	mobileButton = btn
	setMobileButtonState("off")

	btn.Activated:Connect(function()
		toggleFlashlight()
	end)
end

-- Battery meter for every platform, stacked above StaminaController's energy
-- meter in the bottom-left corner.
local function createBatteryUI()
	local gui = playerGui:FindFirstChild("FlashlightUI") :: ScreenGui?
	if not gui then
		gui = Instance.new("ScreenGui")
	end
	local flashGui = gui :: ScreenGui
	flashGui.Name = "FlashlightUI"
	flashGui.DisplayOrder = 20
	flashGui.ResetOnSpawn = false
	flashGui.IgnoreGuiInset = true
	flashGui.Enabled = true
	flashGui.Parent = playerGui

	if not batteryFill then
		local meter = UITheme.meter(flashGui, "Battery", 180)
		meter.root.Name = "BatteryMeter"
		meter.root.AnchorPoint = Vector2.new(0, 1)
		meter.root.Position = UDim2.new(0, UITheme.Margin, 1, -(UITheme.Margin + 34))
		batteryValue = meter.value
		batteryFill = meter.fill
	end
end

-- ============================================================
-- TOGGLE LOGIC
-- ============================================================
function toggleFlashlight()
	if not isNight2 then
		return
	end

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
			if coneBeam then
				coneBeam.Enabled = true
			end
		end

		-- Update mobile button
		setMobileButtonState("on")
	else
		-- Turn off
		flashlightOn = false
		if spotlight then
			spotlight.Enabled = false
			if coneBeam then
				coneBeam.Enabled = false
			end
		end

		setMobileButtonState("off")
	end

	FlashlightToggle:FireServer(flashlightOn)
end

-- ============================================================
-- UPDATE LOOP
-- ============================================================
local flickerAccum = 0
local wasBlinking = false
local CONE_DEFAULT = Rig.coneRamp(CONFIG.coneTransparency)
local CONE_HIDDEN = NumberSequence.new(1)

local function startUpdateLoop()
	updateConnection = RunService.Heartbeat:Connect(function(dt: number)
		if not isNight2 then
			return
		end

		-- Battery management
		if flashlightOn then
			battery = math.max(0, battery - CONFIG.drainRate * dt)
			if battery <= 0 then
				batteryDead = true
				flashlightOn = false
				if spotlight then
					spotlight.Enabled = false
				end
				if coneBeam then
					coneBeam.Enabled = false
				end
				setMobileButtonState("dead")
			end
		end
		-- No passive recharge: the battery only refills when a Battery item
		-- is consumed (see FlashlightRecharge below).

		-- Update battery UI
		if batteryFill then
			local pct = battery / CONFIG.batteryMax
			batteryFill.Size = UDim2.new(pct, 0, 1, 0)
			local color = if pct > 0.5
				then UITheme.Color.Text
				elseif pct > 0.2 then UITheme.Color.Warn
				else UITheme.Color.Danger
			batteryFill.BackgroundColor3 = color
			if batteryValue then
				batteryValue.Text = string.format("%d%%", math.floor(pct * 100 + 0.5))
				batteryValue.TextColor3 = if pct > 0.5 then UITheme.Color.Dim else color
			end
		end

		-- Flashlight effects
		if flashlightOn and spotlight and spotlight.Parent then
			local pct = battery / CONFIG.batteryMax
			local now = os.clock()

			-- Output sags as the cell drains: full down to 40%, then easing to
			-- 55% at empty, so a dying phone FEELS dimmer before it flickers.
			local baseBrightness = CONFIG.brightness * (if pct > 0.4 then 1 else 0.55 + 0.45 * (pct / 0.4))

			-- Brownout below 35%: a slow Perlin waver, plus random hard blinks
			-- (sometimes a double blink) that get far more frequent once the
			-- battery is under the low threshold.
			if pct < 0.35 then
				local depth = 1 - pct / 0.35
				baseBrightness *= 1 - 0.18 * depth * (0.5 + 0.5 * math.noise(now * 2.5, 7.3))

				local blinksPerSecond = if battery < CONFIG.lowBatteryThreshold then 1.6 else 0.15
				if now >= blinkUntil and math.random() < blinksPerSecond * dt then
					blinkUntil = now + 0.04 + math.random() * 0.1
					if math.random() < 0.35 then
						-- Double blink: back on briefly, then off again.
						local second = blinkUntil + 0.06
						task.delay(second - now, function()
							blinkUntil = math.max(blinkUntil, os.clock() + 0.05 + math.random() * 0.08)
						end)
					end
				end
				if now < blinkUntil then
					baseBrightness *= 0.08
				end
			end
			spotlight.Brightness = baseBrightness

			-- Hide the visible shaft for the length of a blink. Only written on
			-- the edge so it doesn't stomp the EMF stutter's own shaft dimming.
			local blinking = now < blinkUntil
			if coneBeam and blinking ~= wasBlinking then
				coneBeam.Transparency = if blinking then CONE_HIDDEN else CONE_DEFAULT
			end
			wasBlinking = blinking

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
								if dist < nearestDist then
									nearestDist = dist
								end
							end
						end
					end

					if nearestDist < CONFIG.emfInterferenceRange then
						local interference = 1 - (nearestDist / CONFIG.emfInterferenceRange)
						flickerAccum += dt * (1 + interference * 5)
						if flickerAccum > 0.05 then
							flickerAccum = 0
							if math.random() < interference * 0.6 then
								local sickly = Color3.fromRGB(
									255,
									math.floor(245 - interference * 100),
									math.floor(225 - interference * 150)
								)
								spotlight.Brightness = math.random() * baseBrightness * 0.3
								spotlight.Color = sickly
								-- Drag the visible shaft down with the beam so the
								-- cone doesn't stay bright while the light stutters.
								if coneBeam then
									coneBeam.Color = ColorSequence.new(sickly)
									coneBeam.Transparency = NumberSequence.new(0.97)
								end
							else
								spotlight.Brightness = baseBrightness
								spotlight.Color = CONFIG.color
								if coneBeam then
									coneBeam.Color = ColorSequence.new(CONFIG.color)
									coneBeam.Transparency = Rig.coneRamp(CONFIG.coneTransparency)
								end
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
	if gameProcessed then
		return
	end
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
	if not flashlightOn then
		setMobileButtonState("off")
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
		local flashGui = playerGui:FindFirstChild("FlashlightUI")
		if flashGui and flashGui:IsA("ScreenGui") then
			flashGui.Enabled = false
		end
		if updateConnection then
			updateConnection:Disconnect()
			updateConnection = nil
		end
	end
end)

-- The rig follows the camera (not the character), so it survives respawns. Just
-- rebuild it if it somehow went missing, and restore the on-state.
player.CharacterAdded:Connect(function()
	if not isNight2 then
		return
	end
	if not emitterPart or not emitterPart.Parent then
		createRig()
	end
	if flashlightOn then
		if spotlight then
			spotlight.Enabled = true
		end
		if coneBeam then
			coneBeam.Enabled = true
		end
	end
end)

print("[FlashlightController] Initialized - press F to toggle (Night 2 only)")
