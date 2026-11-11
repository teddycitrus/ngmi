--!strict
--------------------------------------------------------------------------------
-- NightEncounter.server.luau
-- The last night's first scare, once per player.
--
-- A little after Night 2 begins, the first of the sane NPCs a player sees
-- (one of the staff still cowering somewhere) runs up to them. When it
-- reaches them the client plays a short first-person cutscene
-- (client/NightEncounter): the NPC tells them something is very wrong, a cut
-- shows an NGMI coming round a corner behind them, and mid-way through
-- explaining how to get the power back on the NPC is dragged off. The
-- player turns and runs, and gameplay resumes exactly where the run ends,
-- facing the way they ran.
--
-- If a player has not seen anyone after FALLBACK_AFTER seconds (the staff
-- all hide on the ground floor), the nearest unused NPC is put down the
-- nearest open hall from them and comes running from there.
--
-- Server side: picks the NPC (claimed from NPCManager over the NightNPC
-- bus), drives the run-up, and marks the player untouchable (NightEncounter
-- attribute, honoured by NGMIController) until their client says the scene
-- is over. The client can only end its own scene, once.
--------------------------------------------------------------------------------

local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Layout = require(script.Parent:WaitForChild("Venue"):WaitForChild("Layout"))

local Remote = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("NightEncounter") :: RemoteEvent
local serverComm = ServerStorage:WaitForChild("ServerComm")
local phaseBus = serverComm:WaitForChild("PhaseChanged") :: BindableEvent
local nightNPC = serverComm:WaitForChild("NightNPC", 30) :: BindableFunction

local NIGHT2 = GameConfig.Phase.NIGHT2
local START_DELAY = 20 -- the night transition is still on screen for ~15 s
local FALLBACK_AFTER = 15
local SIGHT_RANGE = 85
local SIGHT_DOT = 0.35
local RUN_SPEED = 22
local MEET_DIST = 5.5
local RUN_TIMEOUT = 14
local SCENE_TIMEOUT = 45
-- Until a player's encounter has played (or this long into the night) no
-- NGMI notices or stalks them (NightGrace attribute, honoured by
-- NGMIController and NGMI/Director), so the scene is never pre-empted by a
-- death at the spawn.
local GRACE_MAX = 90

type Session = { npcId: string, stage: string }

local active = false
local done: { [Player]: boolean } = {}
local sessions: { [Player]: Session } = {}
local used: { [string]: boolean } = {}

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

local function levelOf(y: number): number
	return math.clamp(math.floor((y + 2) / Layout.LEVEL_H), 0, Layout.FLOORS - 1)
end

local function rootOf(model: Instance?): BasePart?
	local r = model and model:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r else nil
end

local function aliveRoot(player: Player): BasePart?
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum and hum.Health > 0 then
		return rootOf(char)
	end
	return nil
end

-- One shared params object: every caller casts right after setting the filter,
-- with no yield in between.
local sharedParams = RaycastParams.new()
sharedParams.FilterType = Enum.RaycastFilterType.Exclude
sharedParams.IgnoreWater = true

local function rayParams(exclude: { Instance }): RaycastParams
	sharedParams.FilterDescendantsInstances = exclude
	return sharedParams
end

local function clearLine(a: Vector3, b: Vector3, exclude: { Instance }): boolean
	return workspace:Raycast(a, b - a, rayParams(exclude)) == nil
end

type Candidate = { id: string, model: Model, name: string }

local function candidates(): { Candidate }
	local ok, list = pcall(function()
		return nightNPC:Invoke("list")
	end)
	local out: { Candidate } = {}
	if ok and typeof(list) == "table" then
		for _, c in list :: { any } do
			if not used[c.id] then
				table.insert(out, c)
			end
		end
	end
	return out
end

--- The first candidate in front of the player with nothing in the way.
local function seenBy(player: Player, list: { Candidate }): Candidate?
	local char = player.Character
	local root = rootOf(char)
	local head = char and char:FindFirstChild("Head")
	if not (root and head and head:IsA("BasePart")) then
		return nil
	end
	local look = root.CFrame.LookVector
	for _, c in list do
		local nr = rootOf(c.model)
		if nr and levelOf(nr.Position.Y) == levelOf(root.Position.Y) then
			local to = nr.Position + Vector3.new(0, 1.5, 0) - head.Position
			if to.Magnitude <= SIGHT_RANGE and to.Unit:Dot(look) > SIGHT_DOT and clearLine(head.Position, head.Position + to, { char :: Model, c.model }) then
				return c
			end
		end
	end
	return nil
end

--- A spot down the most open line from the player, so the NPC can be seen
--- coming. Returns a CFrame facing the player, or nil.
local function runInSpot(root: BasePart): CFrame?
	local origin = root.Position + Vector3.new(0, 1, 0)
	local params = rayParams({ root.Parent :: Instance })
	local best, bestDist = nil, 18
	for i = 0, 15 do
		local a = i / 16 * math.pi * 2
		local dir = Vector3.new(math.cos(a), 0, math.sin(a))
		local hit = workspace:Raycast(origin, dir * 40, params)
		local free = if hit then hit.Distance else 40
		if free > bestDist then
			best, bestDist = dir, free
		end
	end
	if not best then
		return nil
	end
	local pos = origin + best * math.min(bestDist - 3, 32)
	local floor = workspace:Raycast(pos, Vector3.new(0, -8, 0), params)
	if not floor then
		return nil
	end
	local stand = floor.Position + Vector3.new(0, 3, 0)
	return CFrame.lookAt(stand, Vector3.new(root.Position.X, stand.Y, root.Position.Z))
end

--------------------------------------------------------------------------------
-- The run-up
--------------------------------------------------------------------------------

--- Run the NPC to the player. True once they are within MEET_DIST.
local function runUp(npc: Model, player: Player): boolean
	local hum = npc:FindFirstChildOfClass("Humanoid")
	local nr = rootOf(npc)
	if not (hum and nr) then
		return false
	end
	hum.WalkSpeed = RUN_SPEED
	local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true })
	local deadline = os.clock() + RUN_TIMEOUT
	while active and os.clock() < deadline do
		local pr = aliveRoot(player)
		if not (pr and npc.Parent) then
			return false
		end
		local gap = pr.Position - nr.Position
		if gap.Magnitude <= MEET_DIST then
			return true
		end
		if clearLine(nr.Position, pr.Position, { npc, player.Character :: Model }) then
			hum:MoveTo(pr.Position - gap.Unit * (MEET_DIST - 1.5))
			task.wait(0.2)
		else
			local ok = pcall(function()
				path:ComputeAsync(nr.Position, pr.Position)
			end)
			local wps = if ok and path.Status == Enum.PathStatus.Success then path:GetWaypoints() else {}
			local t0 = os.clock()
			for i = 2, math.min(#wps, 6) do
				hum:MoveTo(wps[i].Position)
				while os.clock() - t0 < 1 and (nr.Position - wps[i].Position).Magnitude > 3 do
					task.wait(0.1)
				end
				if os.clock() - t0 >= 1 then
					break
				end
			end
			if #wps == 0 then
				hum:MoveTo(pr.Position)
				task.wait(0.3)
			end
		end
	end
	return false
end

--- NGMIs stay out of the building until everyone's encounter has played
--- (NGMIController waits on the NightReleased workspace attribute), so none
--- is seen or heard before the scene that introduces them.
local function release()
	if active and not workspace:GetAttribute("NightReleased") then
		workspace:SetAttribute("NightReleased", true)
	end
end

local graceOver = false

--- Release once every player has had their scene, or once the grace time
--- has run out and nobody is in the middle of one.
local function checkRelease()
	if graceOver and next(sessions) == nil then
		release()
		return
	end
	for _, player in Players:GetPlayers() do
		if not done[player] then
			return
		end
	end
	release()
end

local function finish(player: Player)
	sessions[player] = nil
	done[player] = true
	task.delay(0.6, function()
		if player.Parent then
			player:SetAttribute("NightEncounter", nil)
			player:SetAttribute("NightGrace", nil)
		end
		checkRelease()
	end)
end

local function encounter(player: Player, c: Candidate, fallback: boolean)
	local npc = nightNPC:Invoke("claim", c.id) :: Model?
	if not npc then
		return
	end
	used[c.id] = true
	local session: Session = { npcId = c.id, stage = "approach" }
	sessions[player] = session

	if fallback then
		local root = aliveRoot(player)
		local spot = root and runInSpot(root)
		if spot then
			npc:PivotTo(spot)
		end
	end

	Remote:FireClient(player, { type = "approach", npc = npc, name = c.name })
	local met = runUp(npc, player)
	local root = aliveRoot(player)
	if not (active and root and npc.Parent) then
		sessions[player] = nil
		return
	end
	if not met then
		-- never got there: set them down just in front, out of the dark
		local p = root.Position + root.CFrame.LookVector * MEET_DIST
		npc:PivotTo(CFrame.lookAt(p, Vector3.new(root.Position.X, p.Y, root.Position.Z)))
	end

	local hum = npc:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.WalkSpeed = 0
		hum:MoveTo((rootOf(npc) :: BasePart).Position)
	end
	player:SetAttribute("NightEncounter", true)
	session.stage = "scene"
	Remote:FireClient(player, { type = "start", npc = npc, name = c.name })

	-- The client clones the NPC as its actor the moment "start" lands; after
	-- that the real one goes (for everyone: it has been taken).
	task.delay(1.5, function()
		pcall(function()
			nightNPC:Invoke("remove", c.id)
		end)
	end)
	-- A client that never reports back still gets its player back.
	task.delay(SCENE_TIMEOUT, function()
		if sessions[player] == session then
			finish(player)
		end
	end)
end

--------------------------------------------------------------------------------
-- Watch loop
--------------------------------------------------------------------------------

local function watch()
	task.wait(START_DELAY)
	local since: { [Player]: number } = {}
	while active do
		for _, player in Players:GetPlayers() do
			if done[player] or sessions[player] or not aliveRoot(player) then
				continue
			end
			since[player] = since[player] or os.clock()
			local list = candidates()
			if #list == 0 then
				done[player] = true -- nobody left to come
				player:SetAttribute("NightGrace", nil)
				checkRelease()
				continue
			end
			local seen = seenBy(player, list)
			if seen then
				task.spawn(encounter, player, seen, false)
			elseif os.clock() - (since[player] :: number) > FALLBACK_AFTER then
				local root = aliveRoot(player) :: BasePart
				table.sort(list, function(a, b)
					local ra, rb = rootOf(a.model), rootOf(b.model)
					local da = if ra then (ra.Position - root.Position).Magnitude else math.huge
					local db = if rb then (rb.Position - root.Position).Magnitude else math.huge
					return da < db
				end)
				task.spawn(encounter, player, list[1], true)
			end
		end
		task.wait(0.25)
	end
end

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------

Remote.OnServerEvent:Connect(function(player: Player, msg: any)
	local session = sessions[player]
	if not (session and session.stage == "scene" and typeof(msg) == "table" and msg.type == "done") then
		return
	end
	-- the client leaves the player where its run ended; nothing to move
	session.stage = "ending"
	finish(player)
end)

phaseBus.Event:Connect(function(phase: number)
	if phase == NIGHT2 and not active then
		active = true
		workspace:SetAttribute("NightReleased", nil)
		graceOver = false
		table.clear(done)
		table.clear(used)
		for _, player in Players:GetPlayers() do
			player:SetAttribute("NightGrace", true)
		end
		task.delay(GRACE_MAX, function()
			graceOver = true
			for _, player in Players:GetPlayers() do
				if not sessions[player] then
					player:SetAttribute("NightGrace", nil)
				end
			end
			checkRelease()
		end)
		task.spawn(watch)
	elseif phase ~= NIGHT2 and active then
		active = false
		workspace:SetAttribute("NightReleased", nil)
		for _, player in Players:GetPlayers() do
			player:SetAttribute("NightEncounter", nil)
			player:SetAttribute("NightGrace", nil)
		end
		table.clear(sessions)
	end
end)

Players.PlayerRemoving:Connect(function(player: Player)
	sessions[player] = nil
	done[player] = nil
end)

print("[NightEncounter] Ready")
