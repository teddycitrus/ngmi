--!strict
--[[
	CinematicCamera.luau
	====================
	Reusable, client-only cutscene rig. Require it from any LocalScript:

		local CinematicCamera = require(ReplicatedStorage.Shared.CinematicCamera)

		local handle = CinematicCamera.play({
			shots = {
				{ cframe = CFrame.lookAt(a, b), duration = 0, fov = 60 }, -- hard cut
				{ cframe = CFrame.lookAt(c, b), duration = 2.5, fov = 45, hold = 0.4 },
				{ cframe = CFrame.lookAt(d, b), duration = 0.35, fov = 30,
				  easing = Enum.EasingStyle.Back, direction = Enum.EasingDirection.Out },
			},
			cues = {
				{ at = 0.2, sound = "rbxassetid://12222030", volume = 0.8 },
				{ at = 2.6, shake = 0.7 },
				{ at = 2.6, aberration = 0.9, duration = 0.5 },
				{ at = 2.7, glitch = 0.4 },
				{ at = 2.7, emit = someParticleEmitter, count = 40 },
				{ at = 3.0, callback = function() print("beat") end },
			},
			letterbox = true,
		})
		handle.Completed:Wait()

	How it moves the camera
	-----------------------
	Each shot interpolates from the previous pose using TweenService:GetValue for
	the easing curve, and the CFrame is written ABSOLUTELY every frame from a
	render-step binding. Nothing is applied relative to the last frame, so other
	systems that multiply onto camera.CFrame (VFXManager's Perlin shake) layer on
	top without ever accumulating drift, even during a static hold.

	CameraController skips its sway / lean whenever the camera is Scriptable, so
	those never fight a cutscene either.

	Screen effects (aberration, FOV punch, jumpscare) live in Cinematic/ScreenFX
	and are re-exported here.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local ScreenFX = require(script.Parent:WaitForChild("Cinematic"):WaitForChild("ScreenFX"))

local CinematicCamera = {}

CinematicCamera.playSound = ScreenFX.playSound
CinematicCamera.aberration = ScreenFX.aberration
CinematicCamera.fovPunch = ScreenFX.fovPunch
CinematicCamera.jumpscare = ScreenFX.jumpscare
local overlayGui = ScreenFX.overlayGui
local vfxBus = ScreenFX.vfxBus
local getControls = ScreenFX.getControls
local localPlayer = ScreenFX.localPlayer

----------------------------------------------------------------------
-- Types
----------------------------------------------------------------------

export type Shot = {
	cframe: CFrame,
	duration: number, -- seconds to travel here from the previous pose; 0 = cut
	fov: number?, -- target FieldOfView, interpolated on the same curve
	hold: number?, -- seconds to sit on this pose before the next shot
	easing: Enum.EasingStyle?,
	direction: Enum.EasingDirection?,
}

export type Cue = {
	at: number, -- seconds from the start of play()
	sound: string?,
	volume: number?,
	pitch: number?,
	shake: number?, -- 0..1 trauma, forwarded to VFXManager
	glitch: number?, -- seconds of colour stutter
	aberration: number?, -- 0..1 strength
	duration: number?, -- for aberration
	flash: Color3?,
	emit: ParticleEmitter?,
	count: number?,
	callback: (() -> ())?,
}

export type PlayOptions = {
	shots: { Shot },
	cues: { Cue }?,
	letterbox: boolean?,
	lockControls: boolean?, -- default true
	restore: boolean?, -- default true: hand the camera back to gameplay
}

export type Handle = {
	Completed: RBXScriptSignal,
	Cancel: (self: Handle) -> (),
	isPlaying: (self: Handle) -> boolean,
}

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------

local RENDER_NAME = "CinematicCameraDrive"
local RENDER_PRIORITY = Enum.RenderPriority.Camera.Value + 1
local LETTERBOX_HEIGHT = 0.11 -- fraction of the screen per bar
local LETTERBOX_TIME = 0.6

----------------------------------------------------------------------
-- Letterbox
----------------------------------------------------------------------

local function setLetterbox(on: boolean)
	local gui = overlayGui("CutsceneLetterbox", 180)
	local top = gui:FindFirstChild("Top") :: Frame?
	local bottom = gui:FindFirstChild("Bottom") :: Frame?
	if not top or not bottom then
		local function bar(name: string, anchorY: number): Frame
			local f = Instance.new("Frame")
			f.Name = name
			f.AnchorPoint = Vector2.new(0, anchorY)
			f.Position = UDim2.fromScale(0, anchorY)
			f.Size = UDim2.fromScale(1, 0)
			f.BackgroundColor3 = Color3.new(0, 0, 0)
			f.BorderSizePixel = 0
			f.Parent = gui
			return f
		end
		top = bar("Top", 0)
		bottom = bar("Bottom", 1)
	end
	local info = TweenInfo.new(LETTERBOX_TIME, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
	local goal = { Size = UDim2.fromScale(1, if on then LETTERBOX_HEIGHT else 0) }
	TweenService:Create(top :: Frame, info, goal):Play()
	TweenService:Create(bottom :: Frame, info, goal):Play()
end

----------------------------------------------------------------------
-- Cue dispatch
----------------------------------------------------------------------

local function fireCue(cue: Cue)
	if cue.sound then
		CinematicCamera.playSound(cue.sound, cue.volume, cue.pitch)
	end
	if cue.shake then
		local bus = vfxBus("VFXShake")
		if bus then
			bus:Fire(cue.shake)
		end
	end
	if cue.glitch then
		local bus = vfxBus("VFXGlitch")
		if bus then
			bus:Fire(cue.glitch)
		end
	end
	if cue.aberration then
		CinematicCamera.aberration(cue.aberration, cue.duration or 0.5)
	end
	if cue.flash then
		local bus = vfxBus("VFXFlash")
		if bus then
			bus:Fire(cue.flash, cue.duration or 0.3)
		end
	end
	if cue.emit and cue.emit.Parent then
		cue.emit:Emit(cue.count or 20)
	end
	if cue.callback then
		task.spawn(cue.callback)
	end
end

----------------------------------------------------------------------
-- Playback
----------------------------------------------------------------------

local activeCancel: (() -> ())? = nil

--- Play a shot list. Only one cinematic runs at a time; starting a new one
--- cancels the previous one cleanly.
function CinematicCamera.play(options: PlayOptions): Handle
	if activeCancel then
		activeCancel()
	end

	local camera = workspace.CurrentCamera
	local shots = options.shots
	local cues = table.clone(options.cues or {})
	table.sort(cues, function(a, b)
		return a.at < b.at
	end)

	local completed = Instance.new("BindableEvent")
	local playing = true

	-- Snapshot so restore puts gameplay back exactly as it was.
	local prevType = camera.CameraType
	local prevFov = camera.FieldOfView

	camera.CameraType = Enum.CameraType.Scriptable
	localPlayer():SetAttribute("CinematicActive", true)

	local controls = if options.lockControls ~= false then getControls() else nil
	if controls then
		controls:Disable()
	end
	if options.letterbox then
		setLetterbox(true)
	end

	-- Build an absolute timeline: each segment knows its start pose and window.
	type Segment = {
		from: CFrame,
		to: CFrame,
		fovFrom: number,
		fovTo: number,
		t0: number,
		t1: number,
		info: TweenInfo,
	}
	local segments: { Segment } = {}
	local clock = 0
	local pose = camera.CFrame
	local fov = camera.FieldOfView
	for _, shot in shots do
		local targetFov = shot.fov or fov
		local info = TweenInfo.new(
			1,
			shot.easing or Enum.EasingStyle.Sine,
			shot.direction or Enum.EasingDirection.InOut
		)
		table.insert(segments, {
			from = if shot.duration <= 0 then shot.cframe else pose,
			to = shot.cframe,
			fovFrom = if shot.duration <= 0 then targetFov else fov,
			fovTo = targetFov,
			t0 = clock,
			t1 = clock + math.max(shot.duration, 0),
			info = info,
		})
		clock += math.max(shot.duration, 0) + (shot.hold or 0)
		pose = shot.cframe
		fov = targetFov
	end
	local totalTime = clock

	local elapsed = 0
	local nextCue = 1

	local function finish(restore: boolean)
		if not playing then
			return
		end
		playing = false
		activeCancel = nil
		RunService:UnbindFromRenderStep(RENDER_NAME)
		if options.letterbox then
			setLetterbox(false)
		end
		if controls then
			controls:Enable()
		end
		localPlayer():SetAttribute("CinematicActive", false)
		if restore then
			camera.FieldOfView = prevFov
			camera.CameraType = if prevType == Enum.CameraType.Scriptable then Enum.CameraType.Custom else prevType
		end
		completed:Fire()
	end

	RunService:BindToRenderStep(RENDER_NAME, RENDER_PRIORITY, function(dt: number)
		elapsed += dt

		while nextCue <= #cues and cues[nextCue].at <= elapsed do
			fireCue(cues[nextCue])
			nextCue += 1
		end

		-- Find the active segment: the last one that has started.
		local seg: Segment? = nil
		for _, s in segments do
			if elapsed >= s.t0 then
				seg = s
			else
				break
			end
		end
		if seg then
			local span = seg.t1 - seg.t0
			local alpha = if span <= 0 then 1 else math.clamp((elapsed - seg.t0) / span, 0, 1)
			local eased = TweenService:GetValue(alpha, seg.info.EasingStyle, seg.info.EasingDirection)
			camera.CFrame = seg.from:Lerp(seg.to, eased)
			camera.FieldOfView = seg.fovFrom + (seg.fovTo - seg.fovFrom) * eased
		end

		if elapsed >= totalTime and nextCue > #cues then
			finish(options.restore ~= false)
		end
	end)

	activeCancel = function()
		finish(true)
	end

	local handle = {
		Completed = completed.Event,
	}
	function handle.Cancel(_self: any)
		finish(true)
	end
	function handle.isPlaying(_self: any): boolean
		return playing
	end
	return (handle :: any) :: Handle
end

--- Cancel whatever cinematic is running, if any.
function CinematicCamera.cancel()
	if activeCancel then
		activeCancel()
	end
end

--- Convenience: build a shot list from parallel keyframe / duration arrays, the
--- shape the legacy CutsceneTrigger remote sends.
function CinematicCamera.fromKeyframes(keyframes: { CFrame }, durations: { number }): { Shot }
	local shots: { Shot } = { { cframe = keyframes[1], duration = 0 } }
	for i = 2, #keyframes do
		table.insert(shots, { cframe = keyframes[i], duration = durations[i - 1] or 1 })
	end
	return shots
end

return CinematicCamera
