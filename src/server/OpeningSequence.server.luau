--!strict
--------------------------------------------------------------------------------
-- OpeningSequence.server.luau
-- DAY1 opening ceremony. When the match starts, the named NPCs (and the player)
-- are gathered in the ground-floor auditorium: the organizer gives a short
-- welcome talk at the lectern while everyone else is seated facing the stage.
-- A ~8s cinematic plays on each client (CutsceneManager "opening"). Afterwards
-- the NPCs get up and disperse to their own floors so the hackathon can begin.
--
-- This script only repositions the NPC models that NPCManager spawns; it never
-- owns their lifecycle, so the two scripts don't fight.
--------------------------------------------------------------------------------

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")
local CollectionService = game:GetService("CollectionService")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local RigFactory = require(script.Parent.RigFactory)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local CutsceneTrigger = Remotes:WaitForChild("CutsceneTrigger") :: RemoteEvent

--------------------------------------------------------------------------------
-- Auditorium geometry — mirrors MapBuilder's AUD block on the ground floor.
--------------------------------------------------------------------------------
local AUD = { minX = -152, maxX = 48, minZ = -92, maxZ = -17 }
local FLOOR_Y = 0
local CX = (AUD.minX + AUD.maxX) / 2 -- -52
local STAGE_Z1 = AUD.minZ + 19 -- -73  (front edge of the stage)
-- The organizer stands ON the stage, just BEHIND the lectern (which is placed at
-- x=CX-14 by MapBuilder) so the podium reads as in front of her, not covering her.
-- y≈5 puts an R15 rig's feet on the 2-high stage.
local SPEAKER_POS = Vector3.new(CX - 14, FLOOR_Y + 5, STAGE_Z1 - 5.5)

-- The organizer's welcome lines (shown as captions during the cinematic).
-- The opening is a new-player guide: schedule, your desk, mentors, sprinting,
-- and the supplies + how they help. (Deliberately says nothing about the NGMIs.)
local ORG_LINES = {
	"Welcome to VesperHacks! Forty-eight hours, one demo, no sleep.",
	"Build your project at your assigned desk. Follow the glowing marker to find it.",
	"Code there to make progress, and ship it before the second night is over.",
	"Stuck? Mentors and judges are on every floor. Go talk to them.",
	"To move fast, hold Shift to sprint, just keep an eye on your energy bar.",
	"Raid the supply closets too. Energy bars refill your sprint, and grab the deodorant and a flashlight battery while you are at it.",
	"That is everything. Demos are Sunday. Now go build something. Good luck, hackers!",
}

-- Cinematic camera framing — sits in the open floor between the stage and the
-- front pew and looks back at the speaker at the lectern, so the seating never
-- blocks the shot. Slow push-in toward them.
local CAM_LOOK = Vector3.new(CX - 14, 5.5, STAGE_Z1 - 5) -- the organizer's chest/head
local CAM_START = Vector3.new(CX - 8, 7, STAGE_Z1 + 6)
local CAM_END = Vector3.new(CX - 11, 6, STAGE_Z1 + 1.5)
local PLAYER_SEAT_NEAR = Vector3.new(CX + 8, 9, -30)

-- the seven NPCs that take a seat (the organizer presents instead)
local SEATED_IDS = {
	"npc_judge_priya",
	"npc_sponsor_jordan",
	"npc_mentor_dev",
	"npc_volunteer_max",
	"npc_hacker_alex",
	"npc_rival_sam",
	"npc_security_ron",
}
local ALL_IDS = {
	"npc_organizer_sarah",
	"npc_judge_priya",
	"npc_sponsor_jordan",
	"npc_mentor_dev",
	"npc_volunteer_max",
	"npc_hacker_alex",
	"npc_rival_sam",
	"npc_security_ron",
}

local playedOpening = false

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local function getNPC(id: string): Model?
	local folder = workspace:FindFirstChild("NPCs")
	if not folder then
		return nil
	end
	local m = folder:FindFirstChild(id)
	if m and m:IsA("Model") then
		return m
	end
	return nil
end

local function setPromptEnabled(model: Model, enabled: boolean)
	local root = model:FindFirstChild("HumanoidRootPart")
	local prompt = root and root:FindFirstChild("DialoguePrompt")
	if prompt and prompt:IsA("ProximityPrompt") then
		prompt.Enabled = enabled
	end
end

local function stopAnimTracks(humanoid: Humanoid)
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if animator then
		for _, t in animator:GetPlayingAnimationTracks() do
			t:Stop()
		end
	end
end

--- Walk a humanoid toward a point, giving up after `timeout` seconds so a stuck
--- NPC never stalls the whole dispersal.
local function walkTo(humanoid: Humanoid, pos: Vector3, timeout: number)
	humanoid:MoveTo(pos)
	local reached = false
	local conn = humanoid.MoveToFinished:Connect(function()
		reached = true
	end)
	local t0 = os.clock()
	while not reached and os.clock() - t0 < timeout do
		task.wait(0.15)
	end
	conn:Disconnect()
end

--- Collect the auditorium bench Seats, sorted front (near the stage) → back.
local function collectBenches(): { Seat }
	local benches: { Seat } = {}
	local map = workspace:FindFirstChild("Map")
	if not map then
		return benches
	end
	for _, d in map:GetDescendants() do
		if d:IsA("Seat") and d.Name == "BenchSeat" then
			local p = d.Position
			if p.X >= AUD.minX and p.X <= AUD.maxX and p.Z >= AUD.minZ and p.Z <= AUD.maxZ and p.Y < 16 then
				table.insert(benches, d)
			end
		end
	end
	table.sort(benches, function(a, b)
		return a.Position.Z < b.Position.Z
	end)
	return benches
end

local function homeMarkerFor(id: string): BasePart?
	for _, m in CollectionService:GetTagged(GameConfig.TAGS.NPC_SPAWN) do
		if m:IsA("BasePart") and m.Name == id then
			return m
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- The sequence
--------------------------------------------------------------------------------
local function runOpening()
	-- If the admin jumped straight to a later phase (e.g. skipping to Night 2),
	-- the DAY1 opening would collide with that jump's own cutscene — stand down.
	local sc = ServerStorage:FindFirstChild("ServerComm")
	if sc and sc:GetAttribute("SkipOpening") then
		sc:SetAttribute("SkipOpening", nil)
		print("[OpeningSequence] SkipOpening set — standing down (admin phase skip).")
		return
	end

	-- Wait for NPCManager to have spawned the cast.
	local deadline = os.clock() + 6
	while os.clock() < deadline and not getNPC("npc_organizer_sarah") do
		task.wait(0.2)
	end

	-- Mark the whole cast as cutscene-controlled so NPCManager's idle-wander leaves
	-- them alone while we pose, seat and disperse them. Cleared per-NPC once each is
	-- relocated to its home floor at the end of the sequence.
	for _, id in ALL_IDS do
		local m = getNPC(id)
		if m then
			m:SetAttribute("CutsceneControlled", true)
		end
	end

	-- Organizer presents from the lectern, facing the audience (+Z).
	local org = getNPC("npc_organizer_sarah")
	if org then
		local r = org:FindFirstChild("HumanoidRootPart")
		local h = org:FindFirstChildOfClass("Humanoid")
		org:PivotTo(CFrame.lookAt(SPEAKER_POS, SPEAKER_POS + Vector3.new(0, 0, 1)))
		if r and r:IsA("BasePart") then
			r.Anchored = true
		end
		if h then
			stopAnimTracks(h)
		end
		setPromptEnabled(org, false)
	end

	-- Everyone else takes a front-row bench, seated facing the stage (-Z).
	-- We POSE them seated (anchor + sit animation) rather than using the bench's
	-- real Seat:Sit — a SeatWeld would otherwise stay attached and drag the whole
	-- 89-stud bench along when we later relocate each NPC to their home floor,
	-- leaving giant red benches stuck under every special NPC.
	local benches = collectBenches()
	-- A real Seat auto-grabs (welds) any Humanoid that overlaps it — so posing an
	-- NPC on the pew silently created a SeatWeld that dragged the whole bench off
	-- on dispersal. Disable the pews' auto-sit while the ceremony runs; they're
	-- re-enabled afterward so players can still sit on them.
	for _, b in benches do
		b.Disabled = true
	end
	for i, id in SEATED_IDS do
		local m = getNPC(id)
		local bench = benches[i]
		if m and bench then
			local h = m:FindFirstChildOfClass("Humanoid")
			-- Seat them at the AISLE end of their bench (not mid-pew), so when the
			-- ceremony ends they step straight into the centre aisle rather than
			-- shuffling along the length of a pew to reach it.
			local aisleX = (bench.Position.X < CX) and (CX - 8) or (CX + 8)
			local seatTop = Vector3.new(aisleX, bench.Position.Y + bench.Size.Y / 2 + 1.6, bench.Position.Z)
			m:PivotTo(CFrame.lookAt(seatTop, seatTop + Vector3.new(0, 0, -1)))
			if h then
				stopAnimTracks(h)
				RigFactory.sit(m, h) -- anchors + plays the seated pose (no weld)
			end
			setPromptEnabled(m, false)
		end
	end

	-- Roll the cinematic on every client.
	for _, plr in Players:GetPlayers() do
		CutsceneTrigger:FireClient(plr, {
			cutscene = "opening",
			lines = ORG_LINES,
			camStart = CAM_START,
			camEnd = CAM_END,
			lookAt = CAM_LOOK,
			seatNear = PLAYER_SEAT_NEAR,
			-- where to drop the player when the cutscene ends: the hallway just
			-- outside the auditorium's north door, on their feet and free to move.
			exitTo = Vector3.new(CX, FLOOR_Y + 4, AUD.maxZ + 4),
		})
	end

	-- Let the talk play out (scales with the number of guide lines, ~3.4s each, to
	-- match the client cinematic), then everyone disperses.
	task.wait(#ORG_LINES * 3.4 + 1.5)

	-- Each NPC stands, walks up the centre aisle to the north doorway, steps into
	-- the corridor and rounds the corner — then (now out of sight) is relocated to
	-- their home floor. Paths are hardcoded to the auditorium's north exit.
	for i, id in ALL_IDS do
		local m = getNPC(id)
		if not m then
			continue
		end
		local h = m:FindFirstChildOfClass("Humanoid")
		local r = m:FindFirstChild("HumanoidRootPart")
		if r and r:IsA("BasePart") then
			r.Anchored = false
		end
		setPromptEnabled(m, true)
		if h and r and r:IsA("BasePart") then
			h.Sit = false
			h.Jump = true -- pops them up out of the bench Seat weld
			local side = (i % 2 == 0) and 1 or -1 -- alternate which way they round the corner
			task.spawn(function()
				-- into the centre aisle at their current row…
				walkTo(h, Vector3.new(CX, FLOOR_Y, math.min(r.Position.Z, AUD.maxZ - 8)), 3)
				-- …up to the north doorway…
				walkTo(h, Vector3.new(CX, FLOOR_Y, AUD.maxZ - 3), 4)
				-- …step through into the corridor…
				walkTo(h, Vector3.new(CX, FLOOR_Y, AUD.maxZ + 4), 3)
				-- …and turn the corner.
				walkTo(h, Vector3.new(CX + side * 16, FLOOR_Y, AUD.maxZ + 8), 3)
				-- gone from view — send them home to their own floor.
				local marker = homeMarkerFor(id)
				if marker and m.Parent then
					m:PivotTo(marker.CFrame + Vector3.new(0, 3, 0))
					local hh = m:FindFirstChildOfClass("Humanoid")
					if hh then
						hh.Sit = false
					end
				end
				-- Hand them back to NPCManager: idle-wander can take over now.
				if m.Parent then
					m:SetAttribute("CutsceneControlled", false)
				end
			end)
		end
	end

	-- Once everyone has cleared out, re-enable the pews so players can sit on them.
	-- (The anti-drift watchdog below still snaps any stray bench home as a backup.)
	task.delay(13, function()
		local map = workspace:FindFirstChild("Map")
		if not map then
			return
		end
		for _, d in map:GetDescendants() do
			if d:IsA("Seat") and d.Name == "BenchSeat" then
				d.Disabled = false
			end
		end
	end)

	print("[OpeningSequence] Opening ceremony complete — NPCs dispersing.")
end

--------------------------------------------------------------------------------
-- Trigger on DAY1 (once per match), listening on the shared phase bus.
--------------------------------------------------------------------------------
task.spawn(function()
	local serverComm = ServerStorage:WaitForChild("ServerComm")
	local phaseBus = serverComm:WaitForChild("PhaseChanged") :: BindableEvent
	phaseBus.Event:Connect(function(phase: number)
		if phase == GameConfig.Phase.DAY1 and not playedOpening then
			playedOpening = true
			task.spawn(runOpening)
		end
	end)
	print("[OpeningSequence] Ready — waiting for DAY1.")
end)

--------------------------------------------------------------------------------
-- Bench anti-drift watchdog.
-- A SeatWeld can drag an 89-stud auditorium bench across the map when whoever's
-- sitting on it gets teleported. We record each bench's build-time home and snap
-- any drifted bench straight back (clearing the weld/occupant first), so a stray
-- red bench can never end up stuck to an NPC or the player.
--------------------------------------------------------------------------------
task.spawn(function()
	local homes: { [Seat]: CFrame } = {}
	while true do
		local map = workspace:FindFirstChild("Map")
		if map then
			for _, d in map:GetDescendants() do
				if d:IsA("Seat") and d.Name == "BenchSeat" then
					local bench = d :: Seat
					if not homes[bench] then
						homes[bench] = bench.CFrame -- first sighting = home (auditorium)
					elseif (bench.Position - homes[bench].Position).Magnitude > 2 then
						local occ = bench.Occupant
						if occ then
							occ.Sit = false
						end
						local weld = bench:FindFirstChild("SeatWeld")
						if weld then
							weld:Destroy()
						end
						bench.Anchored = true
						bench.CFrame = homes[bench]
					end
				end
			end
		end
		task.wait(2)
	end
end)
