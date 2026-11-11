--!strict
--------------------------------------------------------------------------------
-- NightEncounter.client.luau
-- The first-person cutscene for the Night 2 encounter
-- (server/NightEncounter decides who, when and where).
--
--   approach  a staff member is running up to you: "Hey! Over here!"
--   start     they have reached you. Your character freezes and faces them
--             and they tell you what is happening. Cut to a shot of an NGMI
--             coming round a corner behind them. Back to your eyes: they are
--             halfway through telling you how to get the power back on when
--             it takes them from behind and drags them off, screaming at you
--             to save yourself. You turn and run down the most open line,
--             the screen goes black, the server moves you to a hall
--             elsewhere on the floor, and play resumes there.
--
-- Everything in the scene is local: the staff member and the NGMI are actor
-- clones (Shared.CutsceneActors), the real NPC is removed by the server.
--------------------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CutsceneActors = require(Shared:WaitForChild("CutsceneActors"))
local CutsceneFolder = script.Parent:WaitForChild("Cutscene")
local Encounter = require(CutsceneFolder:WaitForChild("Encounter"))
local SceneHold = require(CutsceneFolder:WaitForChild("SceneHold"))
local NGMIVoice = require(script.Parent:WaitForChild("NGMIVoice"))

local Remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("NightEncounter") :: RemoteEvent

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local camera = workspace.CurrentCamera

local V = Vector3.new
local RENDER_NAME = "NightEncounterCamera"
local HEARTBEAT_ID = "rbxassetid://9125402735"
local STING_ID = "rbxassetid://12222019"
local GRAB_GAP = 3.2 -- studs between the NGMI's root and the NPC's while it holds him (his hair reaches back)
local LAMP_OFFSET = CFrame.new(0.5, -0.4, -0.5) -- the lens lamp, just below and in front of the camera

local playing = false
local abortScene: (() -> ())? = nil

local function sound(id: string, volume: number, pitch: number?): Sound
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume
	s.PlaybackSpeed = pitch or 1
	s.Parent = SoundService
	s:Play()
	return s
end

--------------------------------------------------------------------------------
-- The scene
--------------------------------------------------------------------------------

local function play(npcSource: Model, name: string)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local head = char and char:FindFirstChild("Head") :: BasePart?
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not (char and root and head and hum and npcSource:FindFirstChild("HumanoidRootPart")) then
		Remote:FireServer({ type = "done" })
		return
	end
	playing = true
	local conns: { RBXScriptConnection } = {}
	local overlay = Encounter.overlay(playerGui)
	local set = Instance.new("Folder")
	set.Name = "EncounterSet"
	set.Parent = workspace

	-- Freeze the player, clear the screen.
	local releaseHold = SceneHold.hold(char, overlay.gui)
	local prevFov = camera.FieldOfView
	local voice: NGMIVoice.Voice? = nil

	-- Everything the scene changes, put back. Also run if the scene errors.
	local function cleanup()
		abortScene = nil
		RunService:UnbindFromRenderStep(RENDER_NAME)
		for _, c in conns do
			c:Disconnect()
		end
		table.clear(conns)
		if voice then
			voice:destroy()
			voice = nil
		end
		set:Destroy()
		camera.FieldOfView = prevFov
		camera.CameraType = Enum.CameraType.Custom
		camera.CameraSubject = hum
		releaseHold()
	end
	abortScene = cleanup

	-- Stage it: the staff member a few steps in front, the player turned to
	-- face them.
	local exclude: { Instance } = { char, set, npcSource }
	for _, m in CollectionService:GetTagged("NGMI") do
		table.insert(exclude, m)
	end
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = exclude
	local eyeLift = head.Position.Y - root.Position.Y + 0.15
	local toNpc = (npcSource:GetPivot().Position - root.Position) * V(1, 0, 1)
	local dir = if toNpc.Magnitude > 0.5 then toNpc.Unit else (root.CFrame.LookVector * V(1, 0, 1)).Unit
	root.CFrame = CFrame.lookAt(root.Position, root.Position + dir)
	local eye = root.Position + V(0, eyeLift, 0)
	local floorHit = workspace:Raycast(root.Position, V(0, -10, 0), rp)
	local floorY = if floorHit then floorHit.Position.Y else root.Position.Y - 3
	local npcPos = V(eye.X, floorY + Encounter.standLift(npcSource), eye.Z) + dir * 5.6
	local npcHome = CFrame.lookAt(npcPos, V(eye.X, npcPos.Y, eye.Z))

	local npc = CutsceneActors.spawn({ source = npcSource, parent = set, cframe = npcHome, shadows = true }) :: any
	for _, d in npcSource:GetDescendants() do
		if d:IsA("BasePart") or d:IsA("Decal") then
			d.LocalTransparencyModifier = 1
		end
	end

	-- The NGMI, waiting round the corner.
	local route = Encounter.findCorner(eye, npcPos, floorY, exclude)
	local ngmi, lift = Encounter.makeNgmi(npcSource, set, route)
	-- arm's length on these two bodies, so only the hands touch them
	local grabGap = if ngmi and npc then Encounter.grabGap(ngmi, npc.model, GRAB_GAP) else GRAB_GAP
	voice = if ngmi then NGMIVoice.attach(ngmi.model) else nil

	-- A practical riding the lens so faces read in the blackout (the
	-- flashlight rig steps out while a cutscene holds the camera).
	local lamp = Instance.new("Part")
	lamp.Anchored, lamp.CanCollide, lamp.CanQuery, lamp.Transparency = true, false, false, 1
	lamp.Size = V(0.2, 0.2, 0.2)
	lamp.Parent = set
	local lampLight = Instance.new("PointLight")
	lampLight.Color = Color3.fromRGB(236, 210, 166)
	lampLight.Brightness = 1.1
	lampLight.Range = 16
	lampLight.Parent = lamp

	-- Performance state, read by one Heartbeat loop.
	local t0 = os.clock()
	local npcMode, glance = "talk", 0
	local ngmiMode, gait = "stalk", 0
	table.insert(conns, RunService.Heartbeat:Connect(function(dt: number)
		local t = os.clock() - t0
		if npc then
			local pose = if npcMode == "grabbed" then Encounter.grabbed(t) elseif npcMode == "dragged" then Encounter.dragged(t) else Encounter.talk(t, glance)
			npc.rig:apply(pose, dt, if npcMode == "talk" then 14 else 9)
		end
		if ngmi then
			-- softer blend into the grab so the arms close round them instead
			-- of snapping shut
			local pose = if ngmiMode == "grab" then Encounter.grab(t, ngmi.twist) elseif ngmiMode == "drag" then Encounter.drag(gait, t, ngmi.twist) else Encounter.stalk(gait, t, ngmi.twist)
			ngmi.rig:apply(pose, dt, if ngmiMode == "stalk" then 16 else 8)
		end
	end))

	--- Walk the NGMI along `points` at `speed` studs/s, facing where it goes.
	--- A new walk replaces the one in progress.
	local walkConn: RBXScriptConnection? = nil
	local function stopWalk()
		if walkConn then
			walkConn:Disconnect()
			walkConn = nil
		end
	end
	local function walk(points: { Vector3 }, speed: number)
		stopWalk()
		local i, finished = 1, false
		local c = RunService.Heartbeat:Connect(function(dt: number)
			if finished or not ngmi then
				return
			end
			local pos = ngmi.model:GetPivot().Position
			local target = points[i] + V(0, lift, 0)
			local to = target - pos
			local step = speed * dt
			if to.Magnitude <= step then
				pos = target
				i += 1
				finished = i > #points
			else
				pos += to.Unit * step
			end
			gait += step / 4.2 * math.pi * 2
			local face = (target - pos) * V(1, 0, 1)
			ngmi.setPivot(if face.Magnitude > 0.05 then CFrame.lookAt(pos, pos + face) else CFrame.new(pos) * ngmi.model:GetPivot().Rotation)
		end)
		walkConn = c
		table.insert(conns, c)
	end

	-- Camera: written every frame from `shot`, with a shake on top.
	local shot = camera.CFrame
	local shake = 0
	camera.CameraType = Enum.CameraType.Scriptable
	RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Camera.Value + 5, function(dt: number)
		if camera.CameraType ~= Enum.CameraType.Scriptable then
			camera.CameraType = Enum.CameraType.Scriptable
		end
		shake = math.max(0, shake - dt * 1.6)
		local s = shake * shake
		local jitter = CFrame.Angles(math.rad((math.random() - 0.5) * 3 * s), math.rad((math.random() - 0.5) * 3 * s), math.rad((math.random() - 0.5) * 2 * s))
		camera.CFrame = shot * jitter
		lamp.CFrame = shot * LAMP_OFFSET
	end)
	local function npcFace(): Vector3
		local h = npc and npc.head()
		return if h then h.Position - V(0, 0.1, 0) else npcPos + V(0, 1.5, 0)
	end
	local function ease(from: CFrame, to: () -> CFrame, dur: number)
		local s0 = os.clock()
		while os.clock() - s0 < dur do
			local u = math.clamp((os.clock() - s0) / dur, 0, 1)
			shot = from:Lerp(to(), u * u * (3 - 2 * u))
			task.wait()
		end
		shot = to()
	end
	local function track(dur: number)
		local s0 = os.clock()
		while os.clock() - s0 < dur do
			shot = shot:Lerp(CFrame.lookAt(eye, npcFace()), 0.12)
			task.wait()
		end
	end

	-- (1) They catch their breath and start talking.
	overlay.bars(true)
	ease(camera.CFrame, function()
		return CFrame.lookAt(eye, npcFace())
	end, 0.6)
	overlay.say(name, "Oh thank god, you're okay. Something's wrong. Something's really, really wrong.")
	track(3.1)
	overlay.say(name, "Everyone's changing. Dev's eyes went red and he just... looked at me. Like he didn't know me.")
	local g0 = os.clock()
	while os.clock() - g0 < 3.3 do
		local u = os.clock() - g0
		glance = math.clamp((u - 1.0) / 0.4, 0, 1) * (1 - math.clamp((u - 2.3) / 0.4, 0, 1))
		shot = shot:Lerp(CFrame.lookAt(eye, npcFace()), 0.12)
		task.wait()
	end
	glance = 0

	-- (2a) Cut: over its shoulder as it comes round the corner of the side
	-- hall, the staff member's back to it at the end of the line.
	overlay.say(nil, nil)
	local back = (npcPos - eye) * V(1, 0, 1)
	back = back.Unit
	local right = back:Cross(V(0, 1, 0)).Unit
	-- the NGMI stays a silhouette; the light is on him, so his back reads
	lampLight.Brightness, lampLight.Range, lampLight.Color = 0.25, 10, Color3.fromRGB(150, 164, 200)
	local npcLight = Encounter.keyLight(npc and npc.model:FindFirstChild("UpperTorso") or set)
	walk({ route.mouth, route.mouth - back * 2.5 }, 4.5)
	if voice then
		voice:play("click")
	end
	local function overShoulder(): CFrame
		local piv = if ngmi then ngmi.model:GetPivot() else CFrame.lookAt(route.corner + V(0, lift, 0), route.mouth + V(0, lift, 0))
		return Encounter.overShoulder(piv, npcFace(), rp)
	end
	shot = overShoulder()
	camera.FieldOfView = 42
	local cutStart = os.clock()
	local growled = false
	while os.clock() - cutStart < 3.4 do
		shot = shot:Lerp(overShoulder(), 0.15)
		if os.clock() - cutStart > 2.4 and voice and not growled then
			growled = true
			voice:play("growl")
			shake = 0.25
		end
		task.wait()
	end
	npcLight:Destroy()

	-- (3) Back to your eyes. They are getting to the important part when it
	-- reaches them.
	camera.FieldOfView = prevFov
	lampLight.Brightness, lampLight.Range, lampLight.Color = 1.1, 16, Color3.fromRGB(236, 210, 166)
	shot = CFrame.lookAt(eye, npcFace())
	-- It stops a couple of steps behind them, over their shoulder, and waits
	-- there while they keep talking; then it closes the gap all at once.
	-- grabGap: root to root at arm's length, so only the hands touch him
	local behind = V(npcPos.X, floorY, npcPos.Z) + back * grabGap + right * route.side * 0.3
	local lurk = behind + back * 2.2 + right * route.side * 0.4
	if ngmi then
		local p = ngmi.model:GetPivot().Position
		local distLeft = ((p - V(0, lift, 0)) - lurk).Magnitude
		walk({ lurk }, math.clamp(distLeft / 2.6, 2.5, 12))
	end
	overlay.say(name, "Listen to me. The power's out on every floor. There are breaker panels on each one, you have to fix every panel and the lights come back on and the--")
	track(4.2)

	-- (4) It takes them: two quick steps in, arms closing round them, and
	-- they are jerked off their feet backwards.
	stopWalk()
	local screams = Encounter.screamsFor(name)
	local function scream(volume: number)
		local h = npc and npc.head()
		local s = Instance.new("Sound")
		s.SoundId = screams[math.random(#screams)]
		s.Volume = volume
		s.PlaybackSpeed = 0.95 + math.random() * 0.1
		s.RollOffMinDistance = 6
		s.RollOffMaxDistance = 90
		s.Parent = h or SoundService
		s:Play()
	end
	local face = (V(npcPos.X, 0, npcPos.Z) - V(lurk.X, 0, lurk.Z)).Unit
	local from = lurk
	if ngmi then
		from = ngmi.model:GetPivot().Position - V(0, lift, 0)
	end
	ngmiMode = "grab"
	if voice then
		voice:play("screech")
	end
	local grab0 = os.clock()
	local jolted = false
	while os.clock() - grab0 < 0.42 do
		local u = math.clamp((os.clock() - grab0) / 0.36, 0, 1)
		local e = 1 - (1 - u) ^ 3
		local p = from:Lerp(behind, e)
		gait += 0.35
		if ngmi then
			ngmi.setPivot(CFrame.lookAt(p + V(0, lift, 0), p + V(0, lift, 0) + face))
		end
		if u > 0.7 and not jolted then
			-- contact: the hit shoves them toward the player a half step
			jolted = true
			npcMode = "grabbed"
			shake = 0.55
			sound(STING_ID, 0.45, 0.75)
			scream(1.1)
			if npc then
				npc.setPivot(npcHome + (-back * 0.45))
			end
		end
		shot = shot:Lerp(CFrame.lookAt(eye, npcFace()), 0.2)
		task.wait()
	end
	overlay.say(name, "NO! No, no, no, get off me!")
	-- held a beat, thrashing, pulled back against it
	local h0 = os.clock()
	while os.clock() - h0 < 0.9 do
		local u = math.clamp((os.clock() - h0) / 0.5, 0, 1)
		if npc then
			npc.setPivot((npcHome + (-back * 0.45)):Lerp(npcHome * CFrame.new(0, -0.1, 0.1) * CFrame.Angles(math.rad(6), 0, 0), u))
		end
		shot = shot:Lerp(CFrame.lookAt(eye, npcFace()), 0.12)
		task.wait()
	end

	-- (5) Hauled away backwards, back the way it came, speeding up as it
	-- gets them moving; their heels drag and they keep screaming.
	npcMode, ngmiMode = "dragged", "drag"
	overlay.say(name, "Go! RUN! Save yourself!")
	local npcLift = Encounter.standLift(npcSource)
	local path = { behind, route.mouth, route.corner }
	local leg, along, speed = 1, 0, 0
	local drag = RunService.Heartbeat:Connect(function(dt: number)
		if leg >= #path or not (ngmi and npc) then
			return
		end
		speed = math.min(6, speed + dt * 7)
		along += dt * speed
		gait += dt * speed / 3.2 * math.pi * 2
		local a, b = path[leg], path[leg + 1]
		local len = (b - a).Magnitude
		if along >= len then
			along -= len
			leg += 1
			return
		end
		local p = a:Lerp(b, along / len)
		local towardPlayer = (eye - p) * V(1, 0, 1)
		local facing = if towardPlayer.Magnitude > 0.1 then towardPlayer.Unit else -back
		ngmi.setPivot(CFrame.lookAt(p + V(0, lift, 0), p + V(0, lift, 0) + facing))
		-- held out at arm's length by the shoulders, knees gone, leaning back
		local sway = math.sin(os.clock() * 9) * 0.06
		local np = p + facing * grabGap + V(0, npcLift - 0.5, 0)
		npc.setPivot(CFrame.lookAt(np, np + facing) * CFrame.Angles(math.rad(5), 0, sway))
	end)
	table.insert(conns, drag)
	task.delay(0.7, scream, 1)
	task.delay(1.9, scream, 0.85)
	if voice then
		task.delay(0.9, function()
			voice:play("snarl")
		end)
	end
	shake = 0.35
	track(2.8)
	overlay.say(nil, nil)

	-- (6) Turn and run.
	local runDir, free = Encounter.runDirection(eye, npcPos, exclude)
	ease(shot, function()
		return CFrame.lookAt(eye, eye + runDir)
	end, 0.35)
	local beat = sound(HEARTBEAT_ID, 0.9, 1.25)
	local runFor = math.clamp((free - 3) / 16, 0.6, 1.9)
	local r0 = os.clock()
	while os.clock() - r0 < runFor do
		local u = os.clock() - r0
		local p = eye + runDir * (16 * u) + V(0, math.sin(u * 15) * 0.2, 0)
		shot = CFrame.lookAt(p, p + runDir) * CFrame.Angles(0, 0, math.rad(math.sin(u * 7.5) * 2))
		task.wait()
	end

	-- (7) Hand back right where the run left off: the character is put at the
	-- spot the camera reached, facing the way it was running, and play
	-- carries on from there with no cut.
	local endEye = eye + runDir * (16 * runFor)
	local standAt = endEye - V(0, eyeLift, 0)
	root.CFrame = CFrame.lookAt(standAt, standAt + runDir)
	cleanup()
	camera.CFrame = CFrame.lookAt(endEye, endEye + runDir)
	Remote:FireServer({ type = "done" })
	overlay.bars(false)
	TweenService:Create(beat, TweenInfo.new(3), { Volume = 0 }):Play()
	task.wait(0.6)
	overlay.think("The breaker panels. Every floor. I have to get the power back on.")
	task.wait(3.2)
	overlay.think(nil)
	task.wait(0.4)
	beat:Destroy()
	overlay.gui:Destroy()
	playing = false
end

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

local approachGui: Encounter.Overlay? = nil

Remote.OnClientEvent:Connect(function(msg: any)
	if typeof(msg) ~= "table" then
		return
	end
	if msg.type == "approach" and not playing then
		local o = approachGui or Encounter.overlay(playerGui)
		approachGui = o
		o.say(msg.name, "Hey! HEY! Over here!")
		task.delay(2.4, function()
			if approachGui == o then
				o.gui:Destroy()
				approachGui = nil
			end
		end)
	elseif msg.type == "start" and not playing and typeof(msg.npc) == "Instance" and msg.npc:IsA("Model") then
		if approachGui then
			approachGui.gui:Destroy()
			approachGui = nil
		end
		local npc = msg.npc :: Model
		task.spawn(function()
			local ok, err = pcall(play, npc, tostring(msg.name or ""))
			if not ok then
				-- never strand the player in a broken scene
				warn("[NightEncounter] scene failed: " .. tostring(err))
				if abortScene then
					pcall(abortScene)
				end
				local gui = playerGui:FindFirstChild("NightEncounter")
				if gui then
					gui:Destroy()
				end
				Remote:FireServer({ type = "done" })
				playing = false
			end
		end)
	end
end)
