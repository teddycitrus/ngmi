--!strict
--------------------------------------------------------------------------------
-- Cinematic/ScreenFX.luau
-- Screen effects and client helpers for CinematicCamera, re-exported there as
-- CinematicCamera.playSound / aberration / fovPunch / jumpscare.
--
-- Roblox has no chromatic-aberration post effect. `aberration` fakes one with
-- red / cyan edge fringes that jitter in opposite directions, plus horizontal
-- tear bars and a brief split tint on a private ColorCorrectionEffect.
-- Effect instances use the "Cutscene" name prefix so LightingController's
-- foreign-effect sweep leaves them alone.
--------------------------------------------------------------------------------

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local ScreenFX = {}

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

function ScreenFX.localPlayer(): Player
	return Players.LocalPlayer
end

function ScreenFX.playerGui(): PlayerGui
	return ScreenFX.localPlayer():WaitForChild("PlayerGui") :: PlayerGui
end

--- PlayerModule controls, or nil if the default scripts were replaced.
function ScreenFX.getControls(): any
	local scripts = ScreenFX.localPlayer():FindFirstChild("PlayerScripts")
	local module = scripts and scripts:FindFirstChild("PlayerModule")
	if not module then
		return nil
	end
	local ok, mod = pcall(require, module :: ModuleScript)
	if ok and mod then
		return (mod :: any):GetControls()
	end
	return nil
end

--- VFXManager publishes BindableEvents on its own script. Resolved lazily so
--- load order does not matter and a missing manager simply means no effect.
function ScreenFX.vfxBus(name: string): BindableEvent?
	local scripts = ScreenFX.localPlayer():FindFirstChild("PlayerScripts")
	local client = scripts and scripts:FindFirstChild("Client")
	local manager = client and client:FindFirstChild("VFXManager")
	local bus = manager and manager:FindFirstChild(name)
	if bus and bus:IsA("BindableEvent") then
		return bus
	end
	return nil
end

function ScreenFX.overlayGui(name: string, order: number): ScreenGui
	local existing = ScreenFX.playerGui():FindFirstChild(name)
	if existing and existing:IsA("ScreenGui") then
		return existing
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = order
	gui.Parent = ScreenFX.playerGui()
	return gui
end

----------------------------------------------------------------------
-- Screen effects (usable on their own, outside play())
----------------------------------------------------------------------

--- Play a one-shot 2D sound. Parented to SoundService so it is never spatial.
function ScreenFX.playSound(id: string, volume: number?, pitch: number?)
	local sound = Instance.new("Sound")
	sound.SoundId = id
	sound.Volume = volume or 1
	sound.PlaybackSpeed = pitch or 1
	sound.Parent = SoundService
	sound:Play()
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	task.delay(15, function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
end

--- Fake chromatic aberration: opposing red / cyan fringes that jitter apart,
--- horizontal tear bars, and a split tint. `strength` 0..1.
function ScreenFX.aberration(strength: number, duration: number)
	local s = math.clamp(strength, 0, 1)
	-- Each call gets its own container so overlapping calls clean up
	-- independently instead of wiping each other's frames.
	local gui = Instance.new("Frame")
	gui.Name = "Aberration"
	gui.Size = UDim2.fromScale(1, 1)
	gui.BackgroundTransparency = 1
	gui.Parent = ScreenFX.overlayGui("CutsceneAberration", 190)

	local function fringe(color: Color3, flip: boolean): Frame
		local f = Instance.new("Frame")
		f.Size = UDim2.fromScale(1, 1)
		f.BackgroundColor3 = color
		f.BackgroundTransparency = 0
		f.BorderSizePixel = 0
		f.Parent = gui
		-- Transparent in the middle, tinted at one edge: a lens fringe, not a wash.
		local g = Instance.new("UIGradient")
		g.Rotation = if flip then 180 else 0
		g.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1 - 0.55 * s),
			NumberSequenceKeypoint.new(0.18, 1),
			NumberSequenceKeypoint.new(1, 1),
		})
		g.Parent = f
		return f
	end

	local red = fringe(Color3.fromRGB(255, 20, 40), false)
	local cyan = fringe(Color3.fromRGB(20, 230, 255), true)

	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "CutsceneAberrationCC"
	cc.Parent = Lighting

	local bars: { Frame } = {}
	for _ = 1, 3 do
		local bar = Instance.new("Frame")
		bar.BorderSizePixel = 0
		bar.BackgroundColor3 = Color3.new(1, 1, 1)
		bar.Parent = gui
		table.insert(bars, bar)
	end

	local rng = Random.new()
	local start = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local t = (os.clock() - start) / duration
		if t >= 1 then
			conn:Disconnect()
			gui:Destroy()
			cc:Destroy()
			return
		end
		local fade = (1 - t) * s
		local jitter = rng:NextNumber(0.004, 0.018) * fade
		red.Position = UDim2.fromScale(-jitter, rng:NextNumber(-0.004, 0.004) * fade)
		cyan.Position = UDim2.fromScale(jitter, rng:NextNumber(-0.004, 0.004) * fade)
		red.BackgroundTransparency = 1 - fade
		cyan.BackgroundTransparency = 1 - fade

		cc.TintColor = Color3.new(1, 1 - 0.25 * fade * rng:NextNumber(), 1 - 0.1 * fade)
		cc.Contrast = 0.3 * fade
		cc.Saturation = -0.4 * fade

		for _, bar in bars do
			local visible = rng:NextNumber() < 0.5 * fade
			bar.Visible = visible
			if visible then
				bar.Size = UDim2.new(1, 0, rng:NextNumber(0.004, 0.03), 0)
				bar.Position = UDim2.new(rng:NextNumber(-0.05, 0.05), 0, rng:NextNumber(), 0)
				bar.BackgroundTransparency = rng:NextNumber(0.6, 0.9)
			end
		end
	end)
end

--- Dramatic FOV punch: snap in toward `fov`, then ease back to where it was.
function ScreenFX.fovPunch(fov: number, inTime: number, outTime: number)
	local camera = workspace.CurrentCamera
	local original = camera.FieldOfView
	local punchIn = TweenService:Create(
		camera,
		TweenInfo.new(inTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ FieldOfView = fov }
	)
	punchIn:Play()
	punchIn.Completed:Once(function()
		TweenService:Create(
			camera,
			TweenInfo.new(outTime, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut),
			{ FieldOfView = original }
		):Play()
	end)
end

--- One call for a jumpscare beat: FOV slam, aberration, heavy shake, bloom
--- pulse and static (the last three via VFXManager), optional sting sound.
function ScreenFX.jumpscare(intensity: number?, soundId: string?)
	local k = math.clamp(intensity or 1, 0, 1)
	ScreenFX.fovPunch(workspace.CurrentCamera.FieldOfView - 22 * k, 0.07, 0.9)
	ScreenFX.aberration(k, 0.65)
	local bus = ScreenFX.vfxBus("VFXJumpScare")
	if bus then
		bus:Fire(k)
	end
	if soundId then
		ScreenFX.playSound(soundId, 1.2 * k, 0.95)
	end
end

return ScreenFX
