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
--   line 6  slow orbit around her counting off supplies, then a cut to one
--           kid in the crowd checking their armpit on "deodorant"
--   line 7  crane up and back over the applauding room
--
-- The organizer and seated mentors are the real NPCs (posed locally through
-- their Motor6Ds; C0 edits never replicate). The rest of the audience is a
-- client-only crowd of seated actors that exists for this scene alone.
--------------------------------------------------------------------------------

local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local Players = game:GetService("Players")

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

local PER_LINE = 3.4
local LINE_LEAD = 0.3
local OUTRO = 1.4

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

	local hiddenGuis: { ScreenGui } = {}
	for _, g in ctx.playerGui:GetChildren() do
		if g:IsA("ScreenGui") and g.Enabled then
			g.Enabled = false
			table.insert(hiddenGuis, g)
		end
	end

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
	TweenService:Create(topBar, barIn, { Size = UDim2.new(1, 0, BAR_H, 0) }):Play()
	TweenService:Create(botBar, barIn, { Size = UDim2.new(1, 0, BAR_H, 0) }):Play()

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
	local sniffer = Audience.castSniffer(extras, cx)

	local organizer = getNPC("npc_organizer_sarah")
	local orgRig = organizer and RigPose.new(organizer)
	local orgHome = organizer and organizer:GetPivot()
	local wavers: { { rig: RigPose.Rig, seed: number } } = {}
	for _, id in { "npc_judge_priya", "npc_mentor_dev" } do
		local m = getNPC(id)
		if m then
			table.insert(wavers, { rig = RigPose.new(m), seed = math.random() * 10 })
		end
	end
	local clappers: { RigPose.Rig } = {}
	for _, id in { "npc_sponsor_jordan", "npc_volunteer_max", "npc_hacker_alex", "npc_rival_sam", "npc_security_ron" } do
		local m = getNPC(id)
		if m then
			table.insert(clappers, RigPose.new(m))
		end
	end

	-- Head-tracking IK on the live NPCs would steer their heads at the player
	-- and fight the poses. Hold it off locally for the scene, then restore.
	local ikHeld: { [IKControl]: boolean } = {}
	for _, model in { organizer :: Model?, getNPC("npc_judge_priya"), getNPC("npc_mentor_dev"), getNPC("npc_sponsor_jordan"), getNPC("npc_volunteer_max"), getNPC("npc_hacker_alex"), getNPC("npc_rival_sam"), getNPC("npc_security_ron") } do
		if model then
			for _, d in model:GetDescendants() do
				if d:IsA("IKControl") then
					ikHeld[d] = d.Enabled
				end
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

	local extFrom = ext.from or V(-70, 4, -228)
	local extTo = ext.to or V(-40, 38, -195)
	local extLook = ext.look or V(-30, 24, -100)

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
		-- 6: orbit around her, then the cut to the sniffer
		function(u)
			if sniffer and u > 0.56 then
				local head = sniffer.actor.head()
				local hp = if head then head.Position else sniffer.pos + V(0, 3, 0)
				local push = smooth((u - 0.56) / 0.44)
				-- off their raised-arm side, so the face turning into the armpit reads
				return CFrame.lookAt(hp + V(-2.8 + 0.5 * push, 0.7, -3.4 + 0.6 * push), hp + V(-0.5, -0.3, 0)), 44
			end
			local h = speakerHead()
			local ang = math.rad(-40 + 62 * smooth(u / 0.56))
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
	local talkStart = intro + LINE_LEAD
	local total = talkStart + n * PER_LINE + OUTRO
	local t0 = os.clock()

	local conn = RunService.RenderStepped:Connect(function(dt: number)
		local T = os.clock() - t0
		local frameDt = math.min(dt, 1 / 20)

		-- Which line are we in? 0 = intro, n+1 = outro.
		local line = 0
		local tLine = 0
		if T >= talkStart then
			line = math.min(n, math.floor((T - talkStart) / PER_LINE) + 1)
			tLine = T - talkStart - (line - 1) * PER_LINE
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
			local shotLen = if line == n then PER_LINE + OUTRO else PER_LINE
			local u = math.clamp(tLine / shotLen, 0, 1)
			cf, fov = SHOTS[shotIndex](u, tLine)
			onCut(shotIndex * 10 + (if shotIndex == 6 and u > 0.56 then 1 else 0))
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
			local walkIndex = table.find(gestures, "sprint")
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

		-- mentors wave on line 4; the rest of the front row claps on line 7
		local waveW = if line == 4 then math.clamp(math.min((tLine - 0.6) / 0.3, (3.2 - tLine) / 0.3), 0, 1) else 0
		for _, w in wavers do
			local clapPose = if line == n and tLine > 1.3 then SpeakerChoreo.wave(T, w.seed, 1) else SpeakerChoreo.wave(T, w.seed, waveW)
			w.rig:apply(clapPose, frameDt, 12)
		end
		for i, rig in clappers do
			local on = line == n and tLine > 1.4
			local c = math.sin(T * 4.4 * math.pi * 2 + i)
			local pose: RigPose.Pose = if on
				then { rS = V(50, 0, -20 + 12 * c), lS = V(50, 0, 20 - 12 * c), rE = V(-70, 0, 0), lE = V(-70, 0, 0) }
				else {}
			rig:apply(pose, frameDt, 12)
		end

		-- crowd: skip the ones far off camera to keep the frame cheap
		local camPos = cf.Position
		for _, e in extras do
			if (e.pos - camPos).Magnitude < 90 then
				e.actor.rig:apply(SpeakerChoreo.crowd(T, e.member, line, tLine), frameDt, 10)
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
			task.wait(PER_LINE - 0.35)
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
	for _, w in wavers do
		w.rig:reset()
	end
	for _, rig in clappers do
		rig:reset()
	end
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
