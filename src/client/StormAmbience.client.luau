--!strict
--------------------------------------------------------------------------------
-- StormAmbience.client.luau
-- The thunderstorm outside during Night 2. Three looped layers and the odd
-- thunderclap, all mixed from where the camera is:
--
--   rain     heavy rainfall, always there, much louder at the outer walls
--   glass    rain hitting a window, only close to an exterior pane
--   rumble   a distant thunder bed under everything
--   claps    a thunderclap every 15-40 s, loudest at the perimeter
--
-- Deep inside the building the storm is quiet and muffled (an equalizer cuts
-- the highs), and it opens up as the player nears the perimeter ring and the
-- windows. The venue's interior is X +-160, Z +-100 (Venue/Layout); exterior
-- panes are the parts named "Window" on that boundary.
--------------------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")

local PHASE_NIGHT2 = 3
local FX, FZ = 160, 100 -- interior half extents of the venue
local PERIMETER_REACH = 45 -- studs in from the outer wall where the storm starts to swell
local WINDOW_REACH = 20 -- studs from an exterior pane where the glass layer comes in
local FADE = 4 -- seconds to fade the storm in and out with the phase

-- Roblox's licensed ProSoundEffects library and the Roblox thunder clip.
local RAIN_ID = "rbxassetid://9112853287" -- Rain Heavy 1
local GLASS_ID = "rbxassetid://9112857056" -- Rain On Window 2
local RUMBLE_ID = "rbxassetid://9120018695" -- Thunder Distant Rumble 2
local CLAP_ID = "rbxassetid://12222030" -- HalloweenThunder

local group = Instance.new("SoundGroup")
group.Name = "Storm"
group.Volume = 0
group.Parent = SoundService
local eq = Instance.new("EqualizerSoundEffect")
eq.LowGain = 0
eq.Parent = group

local function layer(id: string): Sound
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Looped = true
	s.Volume = 0
	s.SoundGroup = group
	s.Parent = SoundService
	return s
end
local rain = layer(RAIN_ID)
local glass = layer(GLASS_ID)
local rumble = layer(RUMBLE_ID)
local clap = layer(CLAP_ID)
clap.Looped = false

-- Exterior panes bucketed on an XZ grid of WINDOW_REACH cells. A pane closer
-- than WINDOW_REACH is always in the 3x3 cells around the camera, and farther
-- panes contribute nothing, so only those cells need checking.
local CELL_KEY = 4096 -- key collisions only add real panes to the search
local windowCells: { [number]: { Vector3 } } = {}
local function collectWindows()
	table.clear(windowCells)
	local map = workspace:FindFirstChild("Map")
	if not map then
		return
	end
	for _, d in map:GetDescendants() do
		if d:IsA("BasePart") and d.Name == "Window" then
			local p = d.Position
			if math.abs(p.X) > FX - 3 or math.abs(p.Z) > FZ - 3 then
				local key = math.floor(p.X / WINDOW_REACH) * CELL_KEY + math.floor(p.Z / WINDOW_REACH)
				local cell = windowCells[key]
				if not cell then
					cell = {}
					windowCells[key] = cell
				end
				table.insert(cell, p)
			end
		end
	end
end

--- 0 deep inside, 1 at the outer wall (or outside), and 0..1 for the nearest
--- exterior pane.
local function exposure(p: Vector3): (number, number)
	local inset = math.min(FX - math.abs(p.X), FZ - math.abs(p.Z))
	local wall = math.clamp(1 - inset / PERIMETER_REACH, 0, 1)
	local best = math.huge
	local cx, cz = math.floor(p.X / WINDOW_REACH), math.floor(p.Z / WINDOW_REACH)
	for dx = -1, 1 do
		for dz = -1, 1 do
			local cell = windowCells[(cx + dx) * CELL_KEY + (cz + dz)]
			if cell then
				for _, w in cell do
					local d = (w - p).Magnitude
					if d < best then
						best = d
					end
				end
			end
		end
	end
	local pane = math.clamp(1 - best / WINDOW_REACH, 0, 1)
	-- eased, so the swell builds gradually rather than ramping linearly
	return wall * wall * (3 - 2 * wall), pane * pane
end

local active = false
local level = 0 -- the phase fade, 0..1
local wallMix, paneMix = 0, 0
local nextClap = 0

RunService.Heartbeat:Connect(function(dt: number)
	local nextLevel = math.clamp(level + (if active then dt else -dt) / FADE, 0, 1)
	if nextLevel ~= level then
		level = nextLevel
		group.Volume = level
	end
	if level <= 0 then
		if rain.IsPlaying then
			rain:Stop()
			glass:Stop()
			rumble:Stop()
		end
		return
	end
	if not rain.IsPlaying then
		rain:Play()
		glass:Play()
		rumble:Play()
	end

	local camera = workspace.CurrentCamera
	local wall, pane = 0.35, 0 -- a cutscene camera is off the map: hold a middling mix
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		wall, pane = exposure(camera.CFrame.Position)
	end
	local k = 1 - math.exp(-3 * dt)
	wallMix += (wall - wallMix) * k
	paneMix += (pane - paneMix) * k
	local open = math.max(wallMix, paneMix)

	rain.Volume = 0.12 + 0.5 * wallMix + 0.25 * paneMix
	glass.Volume = 0.7 * paneMix
	rumble.Volume = 0.25 + 0.35 * wallMix
	-- inside, walls swallow the highs; at the glass it is the full storm
	eq.HighGain = -28 * (1 - open)
	eq.MidGain = -8 * (1 - open)

	local now = os.clock()
	if active and now >= nextClap then
		nextClap = now + 15 + math.random() * 25
		clap.Volume = (0.35 + 0.65 * open) * (0.7 + math.random() * 0.3)
		clap.PlaybackSpeed = 0.85 + math.random() * 0.25
		clap:Play()
	end
end)

local function onPhase(phase: number)
	local night = phase == PHASE_NIGHT2
	if night and not active then
		collectWindows()
		-- the first clap comes a little after the storm has faded in
		nextClap = os.clock() + 8 + math.random() * 8
	end
	active = night
end

task.spawn(function()
	local phaseValue = ReplicatedStorage:WaitForChild("CurrentPhase", 30)
	if phaseValue and phaseValue:IsA("IntValue") then
		phaseValue.Changed:Connect(onPhase)
		onPhase(phaseValue.Value)
	end
end)
