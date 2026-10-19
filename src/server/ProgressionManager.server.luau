--!strict
--------------------------------------------------------------------------------
-- ProgressionManager.server.luau
-- Quest/objective-gated progression. DAY1 and DAY2 advance ONLY when their
-- objectives are complete (the final night, NIGHT2, stays time-based and is owned
-- by GameStateManager). When a phase's *required* objectives are all done, we fire
-- the RequestAdvance bus that GameStateManager listens on.
--
-- This is deliberately self-contained: it derives completion from things it can
-- observe directly (player positions, the ProjectCompletion attribute that
-- CodingGameServer publishes, the ItemPickedUp / NPCTalked server buses, and the
-- BathroomMonster tag) so it needs almost no hooks in other systems. Objective
-- check-offs are pushed to the client objectives panel via the QuestUpdate remote.
--
-- Objectives
--   DAY1 (required): find your desk · meet 2 staff
--   DAY2 (required): coding sprint I (50%) · sprint II (100%) · scavenge 3 supplies
--                    · explore all 3 floors
--   DAY2 (bonus):    defeat the Bathroom Monster · fix a frozen PC
--------------------------------------------------------------------------------

local Players           = game:GetService("Players")
local RunService        = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")
local CollectionService = game:GetService("CollectionService")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local QuestUpdate        = Remotes:WaitForChild("QuestUpdate") :: RemoteEvent

local DAY1 = GameConfig.Phase.DAY1
local DAY2 = GameConfig.Phase.DAY2

-- targets
local TALK_TARGET = 2
local ITEM_TARGET = 3
local FLOOR_TARGET = 3
local DESK_RADIUS = 18

local REQUIRED: { [number]: { string } } = {
	[DAY1] = { "find_desk", "talk_npcs" },
	[DAY2] = { "code_wave1", "code_wave2", "collect_items", "explore_rooms" },
}
local ALL_OBJ: { [number]: { string } } = {
	[DAY1] = { "find_desk", "talk_npcs" },
	[DAY2] = { "code_wave1", "code_wave2", "collect_items", "explore_rooms", "poop_monster", "fix_computer" },
}

--------------------------------------------------------------------------------
-- Shared buses
--------------------------------------------------------------------------------
local serverComm = ServerStorage:WaitForChild("ServerComm")
local phaseBus = serverComm:WaitForChild("PhaseChanged") :: BindableEvent
local function ensureBindable(name: string): BindableEvent
	local found = serverComm:FindFirstChild(name)
	if found and found:IsA("BindableEvent") then
		return found
	end
	local b = Instance.new("BindableEvent")
	b.Name = name
	b.Parent = serverComm
	return b
end
local advanceBus = ensureBindable("RequestAdvance")

--------------------------------------------------------------------------------
-- State (match-global)
--------------------------------------------------------------------------------
local phase = 0
local active = false
local done: { [string]: boolean } = {}
local talkedNpcs: { [string]: boolean } = {}
local talkedCount = 0
local itemsCollected = 0
local floorsVisited: { [number]: boolean } = {}
local floorsCount = 0
local sawMonster = false
local frozenPC: Model? = nil
local lastFired: { [string]: string } = {}

-- Activity tracking so we don't advance the day mid-conversation / mid-task.
-- Any of these "pokes" the timer; the advance waits for a lull, then a beat.
local lastActivity = 0
local advanceScheduled = false
local lastSeenCodePct = 0
local IDLE_GRACE = 3.0 -- seconds of no activity required before advancing
local function pokeActivity()
	lastActivity = os.clock()
end

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------
local function bestCodePct(): number
	local best = 0
	for _, plr in Players:GetPlayers() do
		local c = plr:GetAttribute("ProjectCompletion")
		if typeof(c) == "number" and c > best then
			best = c
		end
	end
	return math.floor(best)
end

--- The live label for an objective (with its current progress baked in).
local function objText(id: string): string
	if id == "find_desk" then
		return "Find your desk"
	elseif id == "talk_npcs" then
		return string.format("Meet the staff (%d/%d)", math.min(talkedCount, TALK_TARGET), TALK_TARGET)
	elseif id == "code_wave1" then
		return string.format("Coding sprint I: reach 50%% (%d%%)", bestCodePct())
	elseif id == "code_wave2" then
		return string.format("Coding sprint II: reach 100%% (%d%%)", bestCodePct())
	elseif id == "collect_items" then
		return string.format("Scavenge supplies (%d/%d)", math.min(itemsCollected, ITEM_TARGET), ITEM_TARGET)
	elseif id == "explore_rooms" then
		return string.format("Explore all 3 floors (%d/%d)", math.min(floorsCount, FLOOR_TARGET), FLOOR_TARGET)
	elseif id == "poop_monster" then
		return "Bonus: defeat the Bathroom Monster"
	elseif id == "fix_computer" then
		return "Bonus: fix a frozen PC"
	end
	return id
end

--- Push an objective's state to every client's objectives panel (deduped).
local function fireObjective(id: string, completed: boolean, force: boolean?)
	local text = objText(id)
	local key = text .. (completed and "|1" or "|0")
	if not force and lastFired[id] == key then
		return
	end
	lastFired[id] = key
	for _, plr in Players:GetPlayers() do
		QuestUpdate:FireClient(plr, {
			id = id,
			name = id,
			description = "",
			progress = completed and 1 or 0,
			target = 1,
			completed = completed,
			active = true,
			text = text,
		})
	end
end

--- Once a phase's objectives are met we DON'T cut to the next day instantly —
--- that yanked players out of conversations and activities. Instead we wait for
--- a lull (no dialogue / pickups / coding for IDLE_GRACE seconds), hold a beat of
--- 3-5s, re-confirm the player is still idle, and only then advance.
local function scheduleAdvance()
	if advanceScheduled then
		return
	end
	advanceScheduled = true
	local advancingPhase = phase
	task.spawn(function()
		-- 1) Wait for the player to stop doing things.
		while os.clock() - lastActivity < IDLE_GRACE do
			task.wait(0.4)
			if phase ~= advancingPhase then
				advanceScheduled = false
				return
			end
		end
		-- 2) Hold a cinematic beat (3-5s).
		task.wait(3 + math.random() * 2)
		-- 3) If they wandered back into an activity, wait it out again.
		while os.clock() - lastActivity < IDLE_GRACE do
			task.wait(0.4)
			if phase ~= advancingPhase then
				advanceScheduled = false
				return
			end
		end
		if phase ~= advancingPhase or not active then
			advanceScheduled = false
			return
		end
		active = false
		print(string.format("[ProgressionManager] Phase %d objectives complete — advancing.", advancingPhase))
		advanceBus:Fire()
	end)
end

local function checkAdvance()
	if not active then
		return
	end
	local req = REQUIRED[phase]
	if not req then
		return
	end
	for _, id in req do
		if not done[id] then
			return
		end
	end
	scheduleAdvance()
end

local function markDone(id: string)
	if done[id] then
		return
	end
	done[id] = true
	fireObjective(id, true, true)
	checkAdvance()
end

--- Re-broadcast the whole current objective set (keeps late joiners / missed
--- events in sync).
local function refresh()
	local ids = ALL_OBJ[phase]
	if not ids then
		return
	end
	lastFired = {}
	for _, id in ids do
		fireObjective(id, done[id] == true, true)
	end
end

--------------------------------------------------------------------------------
-- Detectors
--------------------------------------------------------------------------------
local function anyPlayerNearDesk(): boolean
	local desks = CollectionService:GetTagged(GameConfig.TAGS.PLAYER_DESK)
	for _, plr in Players:GetPlayers() do
		local char = plr.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp and hrp:IsA("BasePart") then
			for _, d in desks do
				local pos: Vector3? = nil
				if d:IsA("BasePart") then
					pos = d.Position
				elseif d:IsA("Model") and d.PrimaryPart then
					pos = d.PrimaryPart.Position
				end
				if pos and (pos - hrp.Position).Magnitude <= DESK_RADIUS then
					return true
				end
			end
		end
	end
	return false
end

--- Floor index (0,1,2) from a world Y (floors are 18 studs apart).
local function floorOf(y: number): number
	return math.clamp(math.floor((y + 6) / 18), 0, 2)
end

local accum = 0
RunService.Heartbeat:Connect(function(dt: number)
	accum += dt
	if accum < 0.5 then
		return
	end
	accum = 0
	if not active then
		return
	end

	if phase == DAY1 then
		if not done.find_desk and anyPlayerNearDesk() then
			markDone("find_desk")
		end
	elseif phase == DAY2 then
		-- coding sprints (read the attribute CodingGameServer publishes)
		if not done.code_wave1 or not done.code_wave2 then
			local pct = bestCodePct()
			if pct > lastSeenCodePct then
				lastSeenCodePct = pct
				pokeActivity() -- actively coding → don't advance yet
			end
			fireObjective("code_wave1", done.code_wave1 == true)
			fireObjective("code_wave2", done.code_wave2 == true)
			if not done.code_wave1 and pct >= 50 then
				markDone("code_wave1")
			end
			if not done.code_wave2 and pct >= 100 then
				markDone("code_wave2")
			end
		end
		-- explore all floors
		if not done.explore_rooms then
			for _, plr in Players:GetPlayers() do
				local char = plr.Character
				local hrp = char and char:FindFirstChild("HumanoidRootPart")
				if hrp and hrp:IsA("BasePart") then
					local f = floorOf(hrp.Position.Y)
					if not floorsVisited[f] then
						floorsVisited[f] = true
						floorsCount += 1
						fireObjective("explore_rooms", false)
					end
				end
			end
			if floorsCount >= FLOOR_TARGET then
				markDone("explore_rooms")
			end
		end
	end
end)

-- talk to staff (any dialogue response counts the NPC once). NPCManager fires
-- NPCTalked only after checking the player really is talking to that NPC, so
-- made-up npcIds from a client can't tick the objective.
ensureBindable("NPCTalked").Event:Connect(function(_player: Player, npcId: string)
	if not active or phase ~= DAY1 or done.talk_npcs then
		return
	end
	if typeof(npcId) ~= "string" then
		return
	end
	pokeActivity() -- mid-conversation → hold off on advancing
	if not talkedNpcs[npcId] then
		talkedNpcs[npcId] = true
		talkedCount += 1
		fireObjective("talk_npcs", false)
		if talkedCount >= TALK_TARGET then
			markDone("talk_npcs")
		end
	end
end)

-- scavenge supplies. Pickups happen via the item prompt's server-side Triggered
-- handler (not the PickupItem remote), so we count off InventoryManager's
-- ItemPickedUp bus, which fires on every successful grab.
local itemPickedUpBus = ensureBindable("ItemPickedUp")
itemPickedUpBus.Event:Connect(function(_player: Player, _itemId: string?)
	if not active or phase ~= DAY2 or done.collect_items then
		return
	end
	pokeActivity()
	itemsCollected += 1
	fireObjective("collect_items", false)
	if itemsCollected >= ITEM_TARGET then
		markDone("collect_items")
	end
end)

-- bonus: bathroom monster defeated (its model is destroyed once killed)
CollectionService:GetInstanceAddedSignal("BathroomMonster"):Connect(function()
	sawMonster = true
end)
CollectionService:GetInstanceRemovedSignal("BathroomMonster"):Connect(function()
	if phase == DAY2 and sawMonster then
		markDone("poop_monster")
	end
end)

--------------------------------------------------------------------------------
-- Bonus side quest: a "frozen PC" the player can fix
--------------------------------------------------------------------------------
local function part(parent: Instance, name: string, size: Vector3, pos: Vector3, color: Color3, mat: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Position = pos
	p.Anchored = true
	p.Color = color
	p.Material = mat or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

--- Pick a random work room (lab/lounge/meeting/break) on a random floor for the
--- "frozen PC" side quest, so it isn't bolted to the same spot every game.
local function randomRoomBase(): Vector3
	local fallback = Vector3.new(-130, 0, 30)
	local map = workspace:FindFirstChild("Map")
	if not map then
		return fallback
	end
	local candidates = {}
	for _, f in map:GetDescendants() do
		if f:IsA("Folder") and (f.Name:match("_lab$") or f.Name:match("_lounge$") or f.Name:match("_meeting$") or f.Name:match("_break$")) then
			table.insert(candidates, f)
		end
	end
	if #candidates == 0 then
		return fallback
	end
	local room = candidates[math.random(#candidates)]
	-- bounding-box centre from the room's parts, snapped to its floor slab
	local minv, maxv = Vector3.new(1e9, 1e9, 1e9), Vector3.new(-1e9, -1e9, -1e9)
	local floorY = 0
	for _, p in room:GetDescendants() do
		if p:IsA("BasePart") then
			minv = Vector3.new(math.min(minv.X, p.Position.X), math.min(minv.Y, p.Position.Y), math.min(minv.Z, p.Position.Z))
			maxv = Vector3.new(math.max(maxv.X, p.Position.X), math.max(maxv.Y, p.Position.Y), math.max(maxv.Z, p.Position.Z))
			floorY = math.clamp(math.floor((p.Position.Y + 6) / 18), 0, 2) * 18
		end
	end
	local c = (minv + maxv) / 2
	return Vector3.new(c.X, floorY, c.Z + 3)
end

local function spawnFrozenPC()
	if frozenPC then
		return
	end
	local base = randomRoomBase()
	local model = Instance.new("Model")
	model.Name = "FrozenPC"
	part(model, "Table", Vector3.new(5, 0.3, 2.5), base + Vector3.new(0, 3, 0), Color3.fromRGB(120, 90, 60), Enum.Material.Wood)
	for _, sx in { -2, 2 } do
		part(model, "Leg", Vector3.new(0.3, 3, 0.3), base + Vector3.new(sx, 1.5, 0), Color3.fromRGB(70, 70, 75), Enum.Material.Metal)
	end
	part(model, "Tower", Vector3.new(1, 2, 1.6), base + Vector3.new(1.6, 4.2, 0), Color3.fromRGB(40, 42, 50), Enum.Material.Metal)
	local screen = part(model, "Screen", Vector3.new(3, 2, 0.2), base + Vector3.new(-0.6, 4.6, 0), Color3.fromRGB(40, 90, 220), Enum.Material.Neon)
	-- "frozen" blue-screen distress
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.CanvasSize = Vector2.new(200, 140)
	gui.Parent = screen
	local txt = Instance.new("TextLabel")
	txt.Size = UDim2.fromScale(1, 1)
	txt.BackgroundTransparency = 1
	txt.Font = Enum.Font.Code
	txt.TextScaled = true
	txt.TextColor3 = Color3.fromRGB(235, 240, 255)
	txt.Text = ":(\nFROZEN"
	txt.Parent = gui

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Fix PC"
	prompt.ObjectText = "Frozen Workstation"
	prompt.HoldDuration = 1.5
	prompt.MaxActivationDistance = 9
	prompt.RequiresLineOfSight = false
	prompt.Parent = screen
	prompt.Triggered:Connect(function()
		if not active or phase ~= DAY2 or done.fix_computer then
			return
		end
		screen.Color = Color3.fromRGB(60, 200, 90)
		txt.Text = ":)\nFIXED"
		prompt:Destroy()
		markDone("fix_computer")
	end)

	model.Parent = workspace
	frozenPC = model
end

--------------------------------------------------------------------------------
-- Phase lifecycle
--------------------------------------------------------------------------------
local function resetState()
	done = {}
	talkedNpcs = {}
	talkedCount = 0
	itemsCollected = 0
	floorsVisited = {}
	floorsCount = 0
	lastFired = {}
	advanceScheduled = false
	lastActivity = os.clock()
	lastSeenCodePct = 0
	if frozenPC then
		frozenPC:Destroy()
		frozenPC = nil
	end
end

phaseBus.Event:Connect(function(p: number)
	phase = p
	resetState()
	if p == DAY1 then
		active = true
		task.delay(1.5, refresh) -- give the objectives panel a moment to load the new phase
	elseif p == DAY2 then
		active = true
		sawMonster = false
		for _, _m in CollectionService:GetTagged("BathroomMonster") do
			sawMonster = true
		end
		spawnFrozenPC()
		task.delay(1.5, refresh)
	else
		active = false
	end
end)

-- periodic resync so the panel always reflects authoritative state
task.spawn(function()
	while true do
		task.wait(3)
		if active then
			refresh()
		end
	end
end)

print("[ProgressionManager] Ready — DAY1/DAY2 are quest-gated.")
