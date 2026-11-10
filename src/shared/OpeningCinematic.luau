--!strict
--------------------------------------------------------------------------------
-- OpeningCinematic.luau
-- The DAY1 opening ceremony, played on each client.
--
--   intro   establishing crane up the front of the building, title card
--   line 1  wide over the audience's heads as the organizer opens her arms
--   line 2  low medium on the organizer pointing out over the room
--   line 3  reverse shot from behind her shoulder, the crowd groaning
--   line 4  tracking along the front row while the mentors and judges wave
--   line 5  she jogs out from behind the lectern miming a sprint, camera
--           tracking alongside
--   line 6  slow orbit around her counting off supplies
--   line 7  crane up and back over the applauding room
--
-- The organizer is the real NPC, posed locally through RigPose (client edits
-- never replicate). The rest of the audience is a client-only crowd of
-- seated actors that exists for this scene alone; the seated named NPCs are
-- hidden locally and played by look-alike actors (Opening/Audience).
--------------------------------------------------------------------------------

local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")
local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = script.Parent
local RigPose = require(Shared.RigPose)
local SpeakerChoreo = require(Shared.SpeakerChoreo)
local Opening = script.Parent:WaitForChild("Opening")
local Audience = require(Opening:WaitForChild("Audience"))
local Overlay = require(Opening:WaitForChild("Overlay"))

local OpeningCinematic = {}

type Extra = Audience.Extra

export type Context = {
	playerGui: PlayerGui,
	disableControls: () -> (),
	enableControls: () -> (),
	resetLens: () -> (),
	getCutsceneBlur: () -> BlurEffect,
	motionBlur: (number, number) -> Tween,
}

local PER_LINE = 3.4 -- per caption when the server sends no durations
local LINE_LEAD = 0.3
local OUTRO = 1.4
local PREP_TIMEOUT = 40 -- last-resort cap on loading and warming the set
local WARM_FRAMES = 4 -- frames each shot is rendered under the cover
local MIN_WARM_PASSES = 2 -- full passes over the shots, even with nothing left to fetch
local GO_TIMEOUT = 50 -- how long to wait for the server's go after reporting ready
local MIN_SETTLE = 1 -- seconds the camera sits on the first frame under the cover
local MAX_START_WAIT = 6 -- never wait longer than this for the server's start time

-- the named NPCs OpeningSequence seats in the front rows, and which of them wave
local SEATED_IDS = { "npc_judge_priya", "npc_sponsor_jordan", "npc_mentor_dev", "npc_volunteer_max", "npc_hacker_alex", "npc_rival_sam", "npc_security_ron" }
local WAVER_IDS = { npc_judge_priya = true, npc_mentor_dev = true }

local SFX_WALLA = "rbxassetid://9114011338" -- theater crowd idle, light coughs
local SFX_APPLAUSE = "rbxassetid://9113138157" -- group clap, small room

local camera = workspace.CurrentCamera
local V = Vector3.new

local function smooth(u: number): number
	u = math.clamp(u, 0, 1)
	return u * u * (3 - 2 * u)
end

local function lerpV(a: Vector3, b: Vector3, u: number): Vector3
	return a:Lerp(b, u)
end

local function getNPC(id: string): Model?
	local folder = workspace:FindFirstChild("NPCs")
	local m = folder and folder:FindFirstChild(id)
	if m and m:IsA("Model") then
		return m
	end
	return nil
end

local function makeSound(id: string, volume: number, looped: boolean): Sound
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume
	s.Looped = looped
	s.Parent = SoundService
	return s
end

--------------------------------------------------------------------------------
-- The scene
--------------------------------------------------------------------------------

function OpeningCinematic.play(data: { [string]: any }, ctx: Context)
	local player = Players.LocalPlayer
	local lines = (data.lines :: { string }?) or { "Welcome to the hackathon." }
	local gestures = (data.gestures :: { string }?) or {}
	local intro = (data.intro :: number?) or 0
	local aud = (data.aud :: { [string]: number }?) or { minX = -152, maxX = 48, minZ = -92, maxZ = -17 }
	local cx = (aud.minX + aud.maxX) / 2
	local speakerPos = (data.speakerPos :: Vector3?) or V(cx - 14, 5, -78.5)
	local speakerMark = (data.speakerMark :: Vector3?) or V(cx - 4, 5, -77)
	local ext = (data.exterior :: { [string]: Vector3 }?) or {}
	local seatNear = data.seatNear :: Vector3?

	ctx.disableControls()

	-- Black cover over everything while the set is built and the renderer
	-- settles, so the seat teleport and crowd spawn are never seen. Lifted
	-- when the timeline starts.
	local cover = Instance.new("ScreenGui")
	cover.Name = "OpeningCover"
	cover.IgnoreGuiInset = true
	cover.ResetOnSpawn = false
	cover.DisplayOrder = 450
	local coverFill = Instance.new("Frame")
	coverFill.BackgroundColor3 = Color3.new(0, 0, 0)
	coverFill.BorderSizePixel = 0
	coverFill.Size = UDim2.fromScale(1, 1)
	coverFill.Parent = cover
	cover.Parent = ctx.playerGui

	local hiddenGuis: { ScreenGui } = {}
	for _, g in ctx.playerGui:GetChildren() do
		if g:IsA("ScreenGui") and g.Enabled and g ~= cover and not g:GetAttribute("CutsceneExempt") then
			g.Enabled = false
			table.insert(hiddenGuis, g)
		end
	end

	-- Park the camera on the opening frame before anything moves, so the
	-- area around it starts loading and lighting now.
	local extFrom = ext.from or V(-70, 4, -228)
	local extTo = ext.to or V(-40, 38, -195)
	local extLook = ext.look or V(-30, 24, -100)
	camera.CameraType = Enum.CameraType.Scriptable
	camera.CFrame = CFrame.lookAt(extFrom, extLook)
	camera.FieldOfView = 50
	local prepStart = os.clock()

	local char = player.Character
	local humanoid = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	-- Seat the player in place on the bench. Never Seat:Sit, whose SeatWeld
	-- drags the whole bench along when we move them out afterwards.
	if hrp and hrp:IsA("BasePart") and seatNear then
		hrp.CFrame = CFrame.lookAt(seatNear, seatNear + V(0, 0, -1))
		task.wait(0.1)
		if humanoid then
			humanoid.Sit = true
			hrp.Anchored = true
		end
	end

	---------------------------------------------------------------- overlay
	local overlay = Overlay.build(ctx.playerGui)
	local gui, topBar, botBar = overlay.gui, overlay.topBar, overlay.botBar
	local caption, title, subtitle = overlay.caption, overlay.title, overlay.subtitle

	local BAR_H = 0.12
	local barIn = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

	---------------------------------------------------------------- cast
	local set = Instance.new("Folder")
	set.Name = "OpeningCrowd"
	set.Parent = workspace

	local avoid: { Vector3 } = {}
	if seatNear then
		table.insert(avoid, seatNear)
	end
	local npcFolder = workspace:FindFirstChild("NPCs")
	if npcFolder then
		for _, m in npcFolder:GetChildren() do
			if m:IsA("Model") then
				table.insert(avoid, m:GetPivot().Position)
			end
		end
	end
	local extras = Audience.buildAudience(set, aud, cx, avoid)
	Audience.castChatters(extras, 6)
	-- the seated named NPCs, swapped for local stand-ins posed with the crowd
	local named, restoreNamed = Audience.standIns(set, SEATED_IDS)
	for _, e in named do
		table.insert(extras, e)
	end

	local organizer = getNPC("npc_organizer_sarah")
	local orgRig = organizer and RigPose.new(organizer)
	local orgHome = organizer and organizer:GetPivot()

	-- Head-tracking IK on the organizer would steer her head at the player
	-- and fight the poses. Hold it off locally for the scene, then restore.
	local ikHeld: { [IKControl]: boolean } = {}
	if organizer then
		for _, d in organizer:GetDescendants() do
			if d:IsA("IKControl") then
				ikHeld[d] = d.Enabled
			end
		end
	end
	local function holdIK()
		for ik in ikHeld do
			ik.Enabled = false
		end
	end

	---------------------------------------------------------------- audio
	local walla = makeSound(SFX_WALLA, 0, true)
	local applause = makeSound(SFX_APPLAUSE, 0, false)
	local function swellApplause(peak: number, holdFor: number)
		applause.TimePosition = 0
		applause.Volume = peak
		applause:Play()
		task.delay(holdFor, function()
			TweenService:Create(applause, TweenInfo.new(1.4), { Volume = 0 }):Play()
		end)
	end

	---------------------------------------------------------------- shots
	local function speakerHead(): Vector3
		local p = if organizer then organizer:GetPivot().Position else speakerPos
		return p + V(0, 1.7, 0)
	end

	-- Each shot: (u in 0..1, seconds into the shot) -> camera CFrame, FOV.
	type Shot = (u: number, s: number) -> (CFrame, number)
	local SHOTS: { Shot } = {
		-- 1: wide over the crowd from the back rows, easing in
		function(u)
			-- kept under the hall's ceiling (16) and its hanging acoustic panels (~14)
			local pos = lerpV(V(cx + 2, 12.8, aud.maxZ - 3), V(cx - 3, 11.6, aud.maxZ - 13), smooth(u))
			return CFrame.lookAt(pos, lerpV(speakerPos + V(4, 0, 0), speakerHead(), u)), 58 - 6 * u
		end,
		-- 2: low medium, front right, slow dolly in
		function(u)
			local h = speakerHead()
			local pos = lerpV(h + V(6.5, -1.6, 9), h + V(5, -1.3, 7.6), smooth(u))
			return CFrame.lookAt(pos, h + V(0, -0.4, 0)), 40 - 4 * u
		end,
		-- 3: reverse, from behind her right shoulder onto the room
		function(u)
			local h = speakerHead()
			local pos = lerpV(h + V(2.6, 1.2, -5.6), h + V(3.4, 1.6, -6.4), smooth(u))
			return CFrame.lookAt(pos, V(cx - 2, 3, aud.minZ + 42)), 55
		end,
		-- 4: tracking along the front row, between the stage and the seats
		function(u)
			local x = cx - 16 + 32 * smooth(u)
			local z = aud.minZ + 22.5
			return CFrame.lookAt(V(x, 3.4, z), V(x + 4, 2.8, z + 6.5)), 50
		end,
		-- 5: side-on, tracking her as she jogs to centre stage
		function(_u)
			local h = speakerHead()
			return CFrame.lookAt(h + V(-9, -0.4, 5), h + V(1.5, -0.6, 0)), 46
		end,
		-- 6: slow orbit around her while she counts off the supplies
		function(u)
			local h = speakerHead()
			local ang = math.rad(-40 + 70 * smooth(u))
			local pos = h + V(math.sin(ang) * 8, 0.3, math.cos(ang) * 8)
			return CFrame.lookAt(pos, h + V(0, -0.5, 0)), 44
		end,
		-- 7: crane up and back over the applauding room
		function(u)
			local e = smooth(u)
			-- tops out below the acoustic panels instead of rising through the ceiling
			local pos = lerpV(V(cx - 34, 6, aud.minZ + 26), V(cx - 24, 12.4, aud.minZ + 54), e)
			return CFrame.lookAt(pos, lerpV(speakerHead(), V(cx - 6, 3, aud.minZ + 26), e)), 58 + 8 * e
		end,
	}

	local function introShot(u: number): (CFrame, number)
		local e = smooth(u)
		return CFrame.lookAt(lerpV(extFrom, extTo, e), extLook), 50 + 10 * e
	end

	camera.CameraType = Enum.CameraType.Scriptable
	local cutIndex = -1
	local function onCut(index: number)
		if index == cutIndex then
			return
		end
		cutIndex = index
		-- a blur snap on the frame of the cut reads as an edit, not a teleport
		local blur = ctx.getCutsceneBlur()
		blur.Size = 12
		ctx.motionBlur(0, 0.25)
	end

	---------------------------------------------------------------- timeline
	local n = #lines
	-- Seconds each caption stays up. The server sends one per line, longer
	-- for the instructions, so players have time to read them.
	local sent = (data.durations :: { number }?) or {}
	local durations: { number } = {}
	local starts: { number } = {}
	local talkLen = 0
	for i = 1, n do
		durations[i] = sent[i] or PER_LINE
		starts[i] = talkLen
		talkLen += durations[i]
	end
	local talkStart = intro + LINE_LEAD
	local total = talkStart + talkLen + OUTRO

	---------------------------------------------------------------- prep
	-- Nothing goes on screen until all of it is in: every mesh, texture and
	-- sound downloaded, and every shot rendered under the cover. The renderer
	-- composites clothing, wraps layered accessories and picks mesh detail
	-- only for what the camera actually sees, so a crowd that was never on
	-- screen pops in on its first shot even with its assets downloaded.
	local preloadDone = false
	task.spawn(function()
		local list: { Instance } = { set, walla, applause }
		if organizer then
			table.insert(list, organizer)
		end
		pcall(function()
			ContentProvider:PreloadAsync(list)
		end)
		preloadDone = true
	end)
	local warmShots: { { CFrame | number } } = {}
	for _, u in { 0, 0.5, 1 } do
		local cf, fov = introShot(u)
		table.insert(warmShots, { cf, fov })
		for _, shot in SHOTS do
			local scf, sfov = shot(u, 0)
			table.insert(warmShots, { scf, sfov })
		end
	end
	local prepBy = os.clock() + PREP_TIMEOUT
	local passes = 0
	repeat
		for _, w in warmShots do
			camera.CFrame = w[1] :: CFrame
			camera.FieldOfView = w[2] :: number
			for _ = 1, WARM_FRAMES do
				RunService.RenderStepped:Wait()
			end
		end
		passes += 1
		local loaded = preloadDone and ContentProvider.RequestQueueSize == 0
	until (loaded and passes >= MIN_WARM_PASSES) or os.clock() > prepBy
	local firstCf, firstFov = introShot(0)
	camera.CFrame = firstCf
	camera.FieldOfView = firstFov

	-- Tell the server this client is ready; it sends one shared start time
	-- once every client is, so nobody's scene starts before its set is in.
	local startAt = data.startAt :: number?
	local goId = data.goId :: string?
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local ready = remotes and remotes:FindFirstChild("OpeningReady")
	if goId and ready and ready:IsA("RemoteEvent") then
		ready:FireServer(goId)
		local goBy = os.clock() + GO_TIMEOUT
		while workspace:GetAttribute("OpeningGoId") ~= goId and os.clock() < goBy do
			task.wait()
		end
		startAt = workspace:GetAttribute("OpeningGoAt") :: number?
	end
	if startAt then
		local untilStart = math.min(startAt - workspace:GetServerTimeNow(), MAX_START_WAIT)
		if untilStart > 0 then
			task.wait(untilStart)
		end
	end
	local settled = os.clock() - prepStart
	if settled < MIN_SETTLE then
		task.wait(MIN_SETTLE - settled)
	end

	-- Live: the loading screen and the cover lift onto the first frame.
	player:SetAttribute("OpeningLive", true)
	TweenService:Create(coverFill, TweenInfo.new(0.7), { BackgroundTransparency = 1 }):Play()
	task.delay(0.8, function()
		cover:Destroy()
	end)
	TweenService:Create(topBar, barIn, { Size = UDim2.new(1, 0, BAR_H, 0) }):Play()
	TweenService:Create(botBar, barIn, { Size = UDim2.new(1, 0, BAR_H, 0) }):Play()

	local t0 = os.clock()
	local walkIndex = table.find(gestures, "sprint")

	local conn = RunService.RenderStepped:Connect(function(dt: number)
		local T = os.clock() - t0
		local frameDt = math.min(dt, 1 / 20)

		-- Which line are we in? 0 = intro, n+1 = outro.
		local line = 0
		local tLine = 0
		if T >= talkStart then
			local rel = T - talkStart
			line = n
			for i = 1, n - 1 do
				if rel < starts[i + 1] then
					line = i
					break
				end
			end
			tLine = rel - starts[line]
		end

		-- camera
		local cf: CFrame, fov: number
		if line == 0 then
			cf, fov = introShot(T / math.max(intro, 0.01))
			if intro <= 0 then
				cf, fov = SHOTS[1](0, 0)
			end
		else
			local shotIndex = ((line - 1) % #SHOTS) + 1
			local shotLen = if line == n then durations[n] + OUTRO else durations[line]
			local u = math.clamp(tLine / shotLen, 0, 1)
			cf, fov = SHOTS[shotIndex](u, tLine)
			onCut(shotIndex)
		end
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = cf
		camera.FieldOfView = fov
		if line == 0 and intro > 0 then
			onCut(0)
		end

		-- organizer
		holdIK()
		if organizer and orgRig and orgHome then
			local gestureName = gestures[math.max(line, 1)]
			local clip = gestureName and SpeakerChoreo.GESTURES[gestureName]
			local body: RigPose.Pose = SpeakerChoreo.REST
			if line > 0 and clip then
				body = RigPose.sample(clip, tLine)
			end
			local talkW = if line > 0 then 1 else 0.4
			local pose = RigPose.add(body, SpeakerChoreo.talk(T, 3.1), talkW)

			-- Line 5: jog out from behind the lectern to centre stage.
			local from = orgHome.Position
			local to = V(speakerMark.X, from.Y, speakerMark.Z)
			local pos = from
			local facing = V(0, 0, 1)
			if walkIndex and line >= walkIndex then
				local w = if line > walkIndex then 1 else smooth((tLine - 0.2) / 1.7)
				pos = from:Lerp(to, w)
				if line == walkIndex and w > 0 and w < 1 then
					local travel = (to - from).Unit
					local turn = smooth(math.clamp((w - 0.55) / 0.45, 0, 1))
					facing = travel:Lerp(V(0, 0, 1), turn)
					pose = RigPose.add(pose, SpeakerChoreo.walk(tLine * 11))
				end
			end
			organizer:PivotTo(CFrame.lookAt(pos, pos + V(facing.X, 0, facing.Z)))
			orgRig:apply(pose, frameDt, 14)
		end

		-- crowd, named NPCs included: skip the ones far off camera to keep the
		-- frame cheap. The mentors and judges wave on line 4. Applause is
		-- eased hard (a soft ease shrank every clap to a third of its swing).
		local waveW = if line == 4 then math.clamp(math.min((tLine - 0.6) / 0.3, (3.2 - tLine) / 0.3), 0, 1) else 0
		local camPos = cf.Position
		for _, e in extras do
			if (e.pos - camPos).Magnitude < 90 then
				local pose, clapW = SpeakerChoreo.crowd(T, e.member, line, tLine)
				if waveW > 0 and e.id and WAVER_IDS[e.id] then
					pose = SpeakerChoreo.wave(pose, T, e.member.seed, waveW)
				end
				-- in full applause the pose is written exactly: any easing
				-- rounds off the moment the palms meet
				if clapW >= 0.98 then
					e.actor.rig:apply(pose)
				else
					e.actor.rig:apply(pose, frameDt, if clapW > 0 then 60 else 10)
				end
			end
		end
	end)

	---------------------------------------------------------------- captions
	task.spawn(function()
		if intro > 0 then
			task.wait(intro * 0.25)
			TweenService:Create(title, TweenInfo.new(0.8), { TextTransparency = 0 }):Play()
			task.wait(0.3)
			TweenService:Create(subtitle, TweenInfo.new(0.8), { TextTransparency = 0.15 }):Play()
			task.wait(math.max(0.2, intro * 0.75 - 1.6))
			TweenService:Create(title, TweenInfo.new(0.5), { TextTransparency = 1 }):Play()
			TweenService:Create(subtitle, TweenInfo.new(0.5), { TextTransparency = 1 }):Play()
		end
	end)
	task.spawn(function()
		task.wait(math.max(0, intro - 0.4))
		walla:Play()
		TweenService:Create(walla, TweenInfo.new(1.2), { Volume = 0.3 }):Play()
		task.wait(talkStart - math.max(0, intro - 0.4))
		TweenService:Create(walla, TweenInfo.new(1.5), { Volume = 0.08 }):Play()
		for i, ln in lines do
			caption.Text = ln
			TweenService:Create(caption, TweenInfo.new(0.3), { TextTransparency = 0 }):Play()
			if i == 1 then
				swellApplause(0.55, 1.6)
			elseif i == n then
				task.delay(1.3, function()
					swellApplause(0.8, 2.4)
					TweenService:Create(walla, TweenInfo.new(0.8), { Volume = 0.35 }):Play()
				end)
			end
			task.wait(durations[i] - 0.35)
			TweenService:Create(caption, TweenInfo.new(0.25), { TextTransparency = 1 }):Play()
			task.wait(0.35)
		end
	end)

	task.wait(total)

	local barOut = TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	TweenService:Create(topBar, barOut, { Size = UDim2.new(1, 0, 0, 0) }):Play()
	TweenService:Create(botBar, barOut, { Size = UDim2.new(1, 0, 0, 0) }):Play()
	TweenService:Create(walla, TweenInfo.new(0.6), { Volume = 0 }):Play()
	task.wait(0.5)

	---------------------------------------------------------------- teardown
	conn:Disconnect()
	gui:Destroy()
	set:Destroy()
	task.delay(2.5, function()
		walla:Destroy()
		applause:Destroy()
	end)
	if orgRig then
		orgRig:reset()
	end
	if organizer and orgHome then
		organizer:PivotTo(orgHome)
	end
	restoreNamed()
	for ik, was in ikHeld do
		if ik.Parent then
			ik.Enabled = was
		end
	end

	-- Up off the bench and out to the hallway on their feet. Sit=false alone
	-- leaves a seated humanoid stuck; Jump pops it up.
	if humanoid then
		humanoid.Sit = false
		humanoid.Jump = true
	end
	if hrp and hrp:IsA("BasePart") then
		hrp.Anchored = false
		local exitTo = data.exitTo :: Vector3?
		if exitTo then
			task.wait(0.1)
			hrp.CFrame = CFrame.new(exitTo)
		end
	end
	camera.CameraType = Enum.CameraType.Custom
	ctx.resetLens()
	if humanoid then
		camera.CameraSubject = humanoid
	end
	-- never re-enable the lobby menu: it's dismissed for the rest of the match
	for _, g in hiddenGuis do
		if g.Parent and g.Name ~= "LobbyGui" then
			g.Enabled = true
		end
	end
	ctx.enableControls()
end

return OpeningCinematic
