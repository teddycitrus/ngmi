--!strict
--------------------------------------------------------------------------------
-- Backdrop.luau
-- The live scene behind the lobby menu: a slow rotation of shots of the
-- empty hall at night in a thunderstorm. Outside, the camera stands on the
-- plaza with rain streaking past the lens; inside it drifts through the
-- auditorium, the elevator lobby, the stairwell and the dark corridors while
-- one or two of the lights in frame stutter. Each shot holds 6 to 8 seconds
-- and cuts through black to the next.
--
--   local stop = Backdrop.start(frame)
--
-- `frame` is the full-screen menu background (rain, flash and cut fades are
-- drawn in it). The night look is the LOBBY lighting profile; this module
-- adds what moves. `stop()` puts everything back and hands the camera over.
--
-- While it runs the ambient crowd is parked out of the workspace (the same
-- trick the night transition uses) and player avatars are hidden locally,
-- so the building reads as empty.
--------------------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Lighting = game:GetService("Lighting")
local ProximityPromptService = game:GetService("ProximityPromptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local LightingProfiles = require(Shared:WaitForChild("LightingProfiles"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local Backdrop = {}

-- Same ProSoundEffects layers StormAmbience uses on Night 2.
local RAIN_ID = "rbxassetid://9112853287"
local RUMBLE_ID = "rbxassetid://9120018695"
local CLAP_ID = "rbxassetid://12222030"
local CRACK_ID = "rbxassetid://12222019"

local RENDER_NAME = "LobbyBackdropCamera"
local DROPS = 120
local RAIN_TILT = 9 -- degrees, wind from the right
local CUT_FADE = 0.4
local DRIFT = 0.25 -- share of each shot's from -> to move covered while it holds
local FLICKER_REACH = 70 -- studs from the camera a flickering light may be

type Shot = {
	from: Vector3,
	to: Vector3,
	look0: Vector3,
	look1: Vector3,
	fov: number,
	outside: boolean?,
}

local V = Vector3.new
-- Coordinates follow Venue/Layout: floors every 18 studs, central corridor
-- along Z = 0, elevators at the west end, stair shaft X 130-160, the
-- auditorium in the south-west of the ground floor.
local SHOTS: { Shot } = {
	-- the facade from the plaza
	{ from = V(-52, 6, -200), to = V(-36, 7, -194), look0 = V(30, 25, -101), look1 = V(36, 24, -101), fov = 52, outside = true },
	-- the auditorium from the back rows, down to the stage and screen
	{ from = V(-20, 13, -26), to = V(-34, 12, -30), look0 = V(-52, 6, -86), look1 = V(-56, 6, -86), fov = 58 },
	-- ground floor elevator lobby
	{ from = V(-112, 5.5, 7), to = V(-122, 5.2, 4), look0 = V(-152, 6, -2), look1 = V(-152, 6, 0), fov = 56 },
	-- the main entrance under the plaza lamps
	{ from = V(84, 4.5, -146), to = V(76, 4.8, -142), look0 = V(52, 8, -101), look1 = V(50, 9, -101), fov = 54, outside = true },
	-- up the stairwell from the ground floor landing, along the flight lane
	{ from = V(131.5, 5.2, -6.5), to = V(132.5, 5.8, -6), look0 = V(160, 13, -4.5), look1 = V(160, 14, -4.5), fov = 66 },
	-- first floor corridor, end to end
	{ from = V(116, 23.5, -5), to = V(102, 23.5, -4), look0 = V(-140, 22, 2), look1 = V(-140, 22, 1), fov = 54 },
	-- the hack hall's desks, first floor
	{ from = V(42, 28, 47), to = V(34, 27, 47), look0 = V(-30, 19, 20), look1 = V(-34, 19, 24), fov = 58 },
	-- second floor library
	{ from = V(-10, 44, -20), to = V(-18, 43, -22), look0 = V(-90, 38, -46), look1 = V(-92, 38, -40), fov = 58 },
}

local function loop(id: string, parent: Instance): (Sound, EqualizerSoundEffect)
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Looped = true
	s.Volume = 0
	s.Parent = parent
	local eq = Instance.new("EqualizerSoundEffect")
	eq.Parent = s
	s:Play()
	return s, eq
end

local function oneShot(id: string, volume: number, pitch: number, parent: Instance)
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume
	s.PlaybackSpeed = pitch
	s.Parent = parent
	s:Play()
	s.Ended:Once(function()
		s:Destroy()
	end)
end

local function overlay(parent: Frame, name: string, color: Color3, z: number): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundColor3 = color
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.ZIndex = z
	f.Parent = parent
	return f
end

type Drop = { f: Frame, x: number, y: number, speed: number }

local function buildRain(parent: Frame): (Frame, { Drop })
	local layer = overlay(parent, "Rain", Color3.new(), 1)
	layer.ClipsDescendants = true
	local drops: { Drop } = {}
	for _ = 1, DROPS do
		-- depth 0 is far (short, faint, slow), 1 is right past the lens
		local depth = math.random() ^ 1.6
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Size = UDim2.fromOffset(if depth > 0.8 then 2 else 1, 12 + 46 * depth)
		f.Rotation = RAIN_TILT
		f.BorderSizePixel = 0
		f.BackgroundColor3 = Color3.fromRGB(196, 208, 232)
		f.BackgroundTransparency = 0.88 - 0.4 * depth
		f.ZIndex = 1
		f.Parent = layer
		table.insert(drops, { f = f, x = math.random(), y = math.random(), speed = 0.9 + 1.5 * depth })
	end
	return layer, drops
end

--------------------------------------------------------------------------------
-- Flickering lights
--------------------------------------------------------------------------------

type Flicker = { part: BasePart, light: Light, material: Enum.Material, brightness: number }

--- One or two tagged fixtures in front of the camera, nearest first.
local function pickFlickers(shot: Shot): { Flicker }
	local dir = (shot.look0 - shot.from).Unit
	local found: { { f: Flicker, d: number } } = {}
	for _, p in CollectionService:GetTagged(GameConfig.TAGS.CEILING_LIGHT) do
		if p:IsA("BasePart") and p:IsDescendantOf(workspace) then
			local light = p:FindFirstChildWhichIsA("Light")
			local to = p.Position - shot.from
			local d = to.Magnitude
			if light and light.Enabled and d < FLICKER_REACH and d > 6 and to.Unit:Dot(dir) > 0.75 then
				table.insert(found, { f = { part = p, light = light, material = p.Material, brightness = light.Brightness }, d = d })
			end
		end
	end
	table.sort(found, function(a, b)
		return a.d < b.d
	end)
	local out: { Flicker } = {}
	-- skip the very nearest so the flicker sits in the frame, not over the lens
	for i = 2, math.min(#found, 2 + math.random(0, 1)) do
		table.insert(out, found[i].f)
	end
	if #out == 0 and found[1] then
		table.insert(out, found[1].f)
	end
	return out
end

local function setFixture(f: Flicker, k: number)
	f.light.Brightness = f.brightness * k
	f.part.Material = if k > 0.4 then f.material else Enum.Material.SmoothPlastic
end

--------------------------------------------------------------------------------
-- Run
--------------------------------------------------------------------------------

function Backdrop.start(frame: Frame): () -> ()
	local camera = workspace.CurrentCamera
	local running = true
	local conns: { RBXScriptConnection } = {}
	local profile = LightingProfiles.getProfile("LOBBY")

	-- The character is still standing in the building behind the menu: no
	-- prompts (the elevator call button is right by the spawn) and no
	-- walking about until the menu closes.
	ProximityPromptService.Enabled = false
	local controls: any = nil
	pcall(function()
		local module = require(Players.LocalPlayer:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 3) :: ModuleScript) :: any
		controls = module:GetControls()
		controls:Disable()
	end)

	-- Empty building: park the crowd, hide avatars locally.
	local crowd = workspace:FindFirstChild("AmbientPeople")
	if crowd then
		crowd.Parent = ReplicatedStorage
	end
	local hiddenParts: { [BasePart]: number } = {}
	local function hideAvatars()
		for _, plr in Players:GetPlayers() do
			local char = plr.Character
			if char then
				for _, d in char:GetDescendants() do
					if d:IsA("BasePart") and hiddenParts[d] == nil then
						hiddenParts[d] = d.LocalTransparencyModifier
						d.LocalTransparencyModifier = 1
					end
				end
			end
		end
	end

	-- A storm sky: no stars or moon through the overcast, heavy low cloud.
	local sky = Lighting:FindFirstChildOfClass("Sky")
	local skyStars, skyBodies = 0, true
	if sky then
		skyStars, skyBodies = sky.StarCount, sky.CelestialBodiesShown
		sky.StarCount = 0
		sky.CelestialBodiesShown = false
	end
	local clouds: Clouds? = nil
	if not workspace.Terrain:FindFirstChildOfClass("Clouds") then
		local c = Instance.new("Clouds")
		c.Cover = 0.92
		c.Density = 0.85
		c.Color = Color3.fromRGB(60, 64, 76)
		c.Parent = workspace.Terrain
		clouds = c
	end

	local rainLayer, drops = buildRain(frame)
	local flash = overlay(frame, "Flash", Color3.fromRGB(214, 224, 255), 1)
	local cut = overlay(frame, "Cut", Color3.new(0, 0, 0), 2)
	cut.BackgroundTransparency = 0

	local audio = Instance.new("Folder")
	audio.Name = "LobbyStorm"
	audio.Parent = SoundService
	local rain, rainEq = loop(RAIN_ID, audio)
	local rumble, rumbleEq = loop(RUMBLE_ID, audio)

	-- Shot state
	local shot = SHOTS[1]
	local shotStart = os.clock()
	local shotLength = 7
	local flickers: { Flicker } = {}
	local lastCF = CFrame.lookAt(shot.from, shot.look0)

	local function clearFlickers()
		for _, f in flickers do
			if f.part.Parent then
				setFixture(f, 1)
			end
		end
		table.clear(flickers)
	end

	local function enterShot(s: Shot)
		clearFlickers()
		shot = s
		shotStart = os.clock()
		shotLength = 6 + math.random() * 2
		hideAvatars()
		rainLayer.Visible = s.outside == true
		local info = TweenInfo.new(0.6)
		TweenService:Create(rain, info, { Volume = if s.outside then 0.6 else 0.3 }):Play()
		TweenService:Create(rumble, info, { Volume = if s.outside then 0.32 else 0.22 }):Play()
		local high = if s.outside then 0 else -26
		rainEq.HighGain = high
		rainEq.MidGain = if s.outside then 0 else -8
		rumbleEq.HighGain = high
		if not s.outside then
			flickers = pickFlickers(s)
		end
	end

	camera.CameraType = Enum.CameraType.Scriptable
	RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value + 2, function()
		local u = math.clamp((os.clock() - shotStart) / shotLength, 0, 1)
		-- A slow, barely-there drift: each shot only travels DRIFT of the way
		-- from its start pose toward its end pose, linearly so it never
		-- speeds up mid-shot.
		local e = u * DRIFT
		lastCF = CFrame.lookAt(shot.from:Lerp(shot.to, e), shot.look0:Lerp(shot.look1, e))
		if camera.CameraType ~= Enum.CameraType.Scriptable then
			camera.CameraType = Enum.CameraType.Scriptable
		end
		camera.CFrame = lastCF
		camera.FieldOfView = shot.fov
	end)

	-- Rain past the lens.
	local slope = math.tan(math.rad(RAIN_TILT))
	table.insert(conns, RunService.RenderStepped:Connect(function(dt: number)
		if not rainLayer.Visible then
			return
		end
		local size = frame.AbsoluteSize
		if size.Y <= 0 then
			return
		end
		local aspect = size.Y / size.X
		for _, d in drops do
			d.y += d.speed * dt
			d.x -= d.speed * dt * slope * aspect
			if d.y > 1.08 then
				d.y = -0.08 - math.random() * 0.1
				d.x = math.random() * 1.2
			end
			d.f.Position = UDim2.fromScale(d.x, d.y)
		end
	end))

	-- Failing fixtures: mostly on, with stutters, dropouts and the odd long
	-- dead stretch, each on its own clock.
	table.insert(conns, RunService.Heartbeat:Connect(function()
		local t = os.clock()
		for i, f in flickers do
			local n = math.noise(t * 7, i * 13.7, shotStart)
			local k = 1
			if n > 0.28 then
				k = 0
			elseif n > 0.18 then
				k = if math.random() < 0.5 then 0.15 else 0.9
			end
			setFixture(f, k)
		end
	end))

	-- Shot rotation: shuffled, never the same twice running, opening outside.
	task.spawn(function()
		local order: { number } = {}
		local last = 1
		enterShot(SHOTS[1])
		TweenService:Create(cut, TweenInfo.new(1.2), { BackgroundTransparency = 1 }):Play()
		while running do
			task.wait(shotLength - CUT_FADE)
			if not running then
				break
			end
			TweenService:Create(cut, TweenInfo.new(CUT_FADE), { BackgroundTransparency = 0 }):Play()
			task.wait(CUT_FADE)
			if not running then
				break
			end
			if #order == 0 then
				for i = 1, #SHOTS do
					table.insert(order, i)
				end
				for i = #order, 2, -1 do
					local j = math.random(i)
					order[i], order[j] = order[j], order[i]
				end
				if order[#order] == last then
					order[1], order[#order] = order[#order], order[1]
				end
			end
			last = table.remove(order) :: number
			enterShot(SHOTS[last])
			TweenService:Create(cut, TweenInfo.new(CUT_FADE), { BackgroundTransparency = 1 }):Play()
		end
	end)

	-- Lightning: the world lit up for a beat (much softer from inside, where
	-- it only comes through the windows), a double flicker, then thunder.
	local function setWorldFlash(k: number)
		local outside = shot.outside == true
		local w = if outside then k else k * 0.45
		Lighting.OutdoorAmbient = profile.OutdoorAmbient:Lerp(Color3.fromRGB(190, 200, 235), w)
		Lighting.Brightness = profile.Brightness + 2.4 * w
		Lighting.ExposureCompensation = profile.ExposureCompensation + 0.9 * w
		flash.BackgroundTransparency = if outside then 1 - 0.22 * k else 1
	end

	local function strike()
		local big = math.random() < 0.45
		if big then
			oneShot(CRACK_ID, if shot.outside then 0.5 else 0.25, 0.9 + math.random() * 0.2, audio)
		end
		setWorldFlash(if big then 1 else 0.55)
		task.wait(0.06)
		setWorldFlash(0.1)
		task.wait(0.07 + math.random() * 0.06)
		local peak = if big then 0.85 else 0.4
		setWorldFlash(peak)
		task.wait(0.05)
		local fade = 0.5 + math.random() * 0.3
		local start = os.clock()
		while running and os.clock() - start < fade do
			setWorldFlash(peak * (1 - (os.clock() - start) / fade) ^ 2)
			task.wait()
		end
		if running then
			setWorldFlash(0)
		end
		task.wait(if big then 0.3 + math.random() * 0.5 else 1 + math.random() * 1.2)
		if running then
			local vol = (if big then 0.9 else 0.45) * (if shot.outside then 1 else 0.6)
			oneShot(CLAP_ID, vol, 0.85 + math.random() * 0.25, audio)
		end
	end

	task.spawn(function()
		task.wait(3 + math.random() * 2)
		while running do
			strike()
			task.wait(6 + math.random() * 9)
		end
	end)

	return function()
		if not running then
			return
		end
		running = false
		RunService:UnbindFromRenderStep(RENDER_NAME)
		for _, c in conns do
			c:Disconnect()
		end
		clearFlickers()
		-- Hand the camera back only if nothing else (the opening cutscene)
		-- has taken it since our last frame.
		if camera.CameraType == Enum.CameraType.Scriptable and camera.CFrame.Position:FuzzyEq(lastCF.Position, 0.01) then
			camera.CameraType = Enum.CameraType.Custom
			local char = Players.LocalPlayer.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if hum then
				camera.CameraSubject = hum
			end
		end
		ProximityPromptService.Enabled = true
		if controls then
			controls:Enable()
		end
		if crowd and crowd.Parent == ReplicatedStorage then
			crowd.Parent = workspace
		end
		for p, v in hiddenParts do
			if p.Parent then
				p.LocalTransparencyModifier = v
			end
		end
		if sky then
			sky.StarCount = skyStars
			sky.CelestialBodiesShown = skyBodies
		end
		if clouds then
			clouds:Destroy()
		end
		local out = TweenInfo.new(1.2)
		TweenService:Create(rain, out, { Volume = 0 }):Play()
		TweenService:Create(rumble, out, { Volume = 0 }):Play()
		task.delay(1.3, function()
			audio:Destroy()
		end)
		rainLayer:Destroy()
		flash:Destroy()
		cut:Destroy()
	end
end

return Backdrop
