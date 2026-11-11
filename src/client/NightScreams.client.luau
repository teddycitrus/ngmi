--!strict
--------------------------------------------------------------------------------
-- NightScreams.client.luau
-- Somebody else is not making it either. Through the last night, once the
-- NGMIs are loose (workspace NightReleased), a scream carries from somewhere
-- else in the building now and then: placed in 3D tens of studs away so it
-- comes from a direction, muffled and drowned in reverb so it reads as far
-- off through walls. They come more often as the night goes on.
--------------------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Encounter = require(script.Parent:WaitForChild("Cutscene"):WaitForChild("Encounter"))

local PHASE_NIGHT2 = 3
local FIRST_GAP = 18 -- seconds after release before the first one
local GAP_START, GAP_END = 55, 22 -- seconds between screams, early and late
local RAMP = 600 -- seconds over which the gap shrinks
local FX, FZ = 158, 98 -- keep the source inside the building
local LEVEL_H = 18

local group = Instance.new("SoundGroup")
group.Name = "DistantScreams"
group.Volume = 1
group.Parent = SoundService
local eq = Instance.new("EqualizerSoundEffect")
eq.HighGain = -20
eq.MidGain = -6
eq.LowGain = 0
eq.Priority = 2
eq.Parent = group
local verb = Instance.new("ReverbSoundEffect")
verb.DecayTime = 3.2
verb.Density = 0.9
verb.Diffusion = 1
verb.DryLevel = -8
verb.WetLevel = -2
verb.Priority = 1
verb.Parent = group

local all: { string } = {}
for _, bank in Encounter.SCREAMS do
	for _, id in bank do
		table.insert(all, id)
	end
end

local function scream()
	local camera = workspace.CurrentCamera
	local here = camera.CFrame.Position
	local a = math.random() * math.pi * 2
	local d = 60 + math.random() * 70
	local level = math.clamp(math.floor((here.Y + 2) / LEVEL_H) + math.random(-1, 1), 0, 2)
	local pos = Vector3.new(
		math.clamp(here.X + math.cos(a) * d, -FX, FX),
		level * LEVEL_H + 5,
		math.clamp(here.Z + math.sin(a) * d, -FZ, FZ)
	)
	local att = Instance.new("Attachment")
	att.WorldPosition = pos
	att.Parent = workspace.Terrain
	local s = Instance.new("Sound")
	s.SoundId = all[math.random(#all)]
	s.Volume = 0.5 + math.random() * 0.4
	s.PlaybackSpeed = 0.82 + math.random() * 0.16
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMinDistance = 30
	s.RollOffMaxDistance = 320
	s.SoundGroup = group
	s.Parent = att
	s:Play()
	s.Ended:Once(function()
		att:Destroy()
	end)
	task.delay(12, function()
		if att.Parent then
			att:Destroy()
		end
	end)
end

local running = 0 -- bumped on every phase change, retiring old loops

local function run(token: number)
	while running == token and not workspace:GetAttribute("NightReleased") do
		task.wait(1)
	end
	local start = os.clock()
	task.wait(FIRST_GAP)
	while running == token do
		scream()
		local u = math.clamp((os.clock() - start) / RAMP, 0, 1)
		local gap = GAP_START + (GAP_END - GAP_START) * u
		task.wait(gap * (0.7 + math.random() * 0.6))
	end
end

local function onPhase(phase: number)
	running += 1
	if phase == PHASE_NIGHT2 then
		task.spawn(run, running)
	end
end

task.spawn(function()
	local phaseValue = ReplicatedStorage:WaitForChild("CurrentPhase", 30)
	if phaseValue and phaseValue:IsA("IntValue") then
		phaseValue.Changed:Connect(onPhase)
		onPhase(phaseValue.Value)
	end
end)
