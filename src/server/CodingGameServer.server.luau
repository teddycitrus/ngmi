--!strict
--[[
	CodingGameServer.server.luau
	============================
	Server-side coding progress tracker for "Not Gonna Make It".

	Responsibilities:
	  • Tracks per-player project completion (0-100%)
	  • Validates CodingTaskComplete claims from clients (anti-cheat)
	  • Applies score-based progress for three mini-game types
	  • Blocks progress when power is sabotaged
	  • Stores final completion % at phase transitions for ending evaluation

	Progress per task type:
	  Typing Challenge  →  +5-15% based on accuracy
	  Bug Fix Puzzle    → +10-20% based on speed (time remaining)
	  Dependency Puzzle →  +8-12% based on matches + speed
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)

----------------------------------------------------------------------
-- Remotes
----------------------------------------------------------------------
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local CodingTaskCompleteRemote = Remotes:WaitForChild("CodingTaskComplete") :: RemoteEvent
local CodingProgressRemote = Remotes:WaitForChild("CodingProgress") :: RemoteEvent
local PanelRepairedRemote = Remotes:WaitForChild("PanelRepaired") :: RemoteEvent
local SabotageEventRemote = Remotes:WaitForChild("SabotageEvent") :: RemoteEvent
local GameStateChangedRemote = Remotes:WaitForChild("GameStateChanged") :: RemoteEvent
local QuestUpdateRemote = Remotes:WaitForChild("QuestUpdate") :: RemoteEvent

----------------------------------------------------------------------
-- Types
----------------------------------------------------------------------
export type PlayerCodingState = {
	completion: number,       -- 0-100 float
	lastTaskTick: number,     -- os.clock() of last accepted task (cooldown)
	taskCount: number,        -- total tasks completed (for mini-game rotation)
	blocked: boolean,         -- true when power is sabotaged in player's zone
	finalCompletion: number?, -- locked at phase transition for ending eval
}

export type TaskPayload = {
	taskType: string,  -- "typing" | "bugfix" | "dependency"
	score: number,     -- 0.0 - 1.0 normalized quality score
}

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------
local TASK_COOLDOWN: number = 3.0          -- seconds between accepted tasks (anti-cheat)
local DESK_PROXIMITY: number = 20          -- studs — max distance from desk to submit
local DESK_TAG: string = GameConfig.TAGS.PLAYER_DESK

-- Day 2 builds the project: each completed task is a flat chunk, so exactly two
-- tasks take you from 0 → 100%.
local DAY2_TASK_GAIN: number = 50

-- Night 2 is a "recompile" scramble: finish this many tasks, each at a random
-- highlighted terminal that moves after every one.
local NIGHT_TERMINAL_MIN: number = 3
local NIGHT_TERMINAL_MAX: number = 4

-- Valid task types for validation
local VALID_TASK_TYPES: { [string]: boolean } = {
	typing     = true,
	bugfix     = true,
	dependency = true,
}

----------------------------------------------------------------------
-- State
----------------------------------------------------------------------
local playerStates: { [number]: PlayerCodingState } = {}  -- keyed by UserId
local currentPhase: number = GameConfig.Phase.LOBBY

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

--[[
	Initializes or resets coding state for a player.
]]
local function initPlayerState(player: Player): ()
	playerStates[player.UserId] = {
		completion = 0,
		lastTaskTick = 0,
		taskCount = 0,
		blocked = false,
		finalCompletion = nil,
	}
end

--[[
	Cleans up coding state when a player leaves.
]]
local function cleanupPlayerState(player: Player): ()
	playerStates[player.UserId] = nil
end

--[[
	Checks whether the player's character is within proximity of any
	desk tagged with PLAYER_DESK. Returns true if close enough to code.
]]
local function isPlayerAtDesk(player: Player): boolean
	local character = player.Character
	if not character then
		return false
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not rootPart then
		return false
	end

	local playerPos = rootPart.Position
	local desks = CollectionService:GetTagged(DESK_TAG)

	for _, desk in desks do
		if desk:IsA("BasePart") then
			local dist = (desk.Position - playerPos).Magnitude
			if dist <= DESK_PROXIMITY then
				return true
			end
		elseif desk:IsA("Model") then
			local primary = desk.PrimaryPart
			if primary then
				local dist = (primary.Position - playerPos).Magnitude
				if dist <= DESK_PROXIMITY then
					return true
				end
			end
		end
	end

	return false
end

----------------------------------------------------------------------
-- Night 2 — rotating "active terminal"
-- A sequence of recompile tasks: one player desk is highlighted at a time, only
-- it counts, and finishing one lights up a different random desk.
----------------------------------------------------------------------
local nightActive = false
local nightTarget = 0
local nightDone = 0
local nightActiveDesk: BasePart? = nil
local nightHighlight: Highlight? = nil
local nightPowerConn: RBXScriptConnection? = nil

--- All player-desk BaseParts currently in the world.
local function deskParts(): { BasePart }
	local out: { BasePart } = {}
	for _, d in CollectionService:GetTagged(DESK_TAG) do
		if d:IsA("BasePart") then
			table.insert(out, d)
		elseif d:IsA("Model") and d.PrimaryPart then
			table.insert(out, d.PrimaryPart)
		end
	end
	return out
end

--- Is the player standing at this specific desk?
local function isPlayerAtPart(player: Player, part: BasePart?): boolean
	if not part then
		return false
	end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return false
	end
	return (root.Position - part.Position).Magnitude <= DESK_PROXIMITY
end

local function nightObjText(): string
	return string.format("Recompile the build: %d/%d terminals", math.min(nightDone, nightTarget), nightTarget)
end

local function broadcastNightObjective(completed: boolean)
	for _, plr in Players:GetPlayers() do
		QuestUpdateRemote:FireClient(plr, {
			id = "night_recompile", name = "night_recompile", description = "",
			progress = completed and 1 or 0, target = 1, completed = completed,
			active = true, text = nightObjText(),
		})
	end
end

local function clearTerminalHighlight()
	if nightHighlight then
		nightHighlight:Destroy()
		nightHighlight = nil
	end
	nightActiveDesk = nil
	workspace:SetAttribute("NightTerminalDeskId", nil)
end

--- Highlight one desk as the active terminal (distinct green, see-through-walls)
--- and publish its id so InteractionManager only opens the coding UI there.
local function highlightTerminal(part: BasePart)
	if nightHighlight then
		nightHighlight:Destroy()
		nightHighlight = nil
	end
	local hl = Instance.new("Highlight")
	hl.Name = "ActiveTerminalHighlight"
	hl.FillColor = Color3.fromRGB(90, 255, 140)
	hl.OutlineColor = Color3.fromRGB(200, 255, 220)
	hl.FillTransparency = 0.5
	hl.OutlineTransparency = 0
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Adornee = part
	hl.Parent = part
	nightHighlight = hl
	nightActiveDesk = part
	workspace:SetAttribute("NightTerminalDeskId", (part:GetAttribute("DeskId") :: string?) or part.Name)
end

--- Move the active terminal to a random desk (different from the current one).
local function advanceTerminal()
	local desks = deskParts()
	if #desks == 0 then
		return
	end
	local pick = desks[math.random(#desks)]
	local guard = 0
	while #desks > 1 and pick == nightActiveDesk and guard < 12 do
		pick = desks[math.random(#desks)]
		guard += 1
	end
	highlightTerminal(pick)
	broadcastNightObjective(false)
end

local function startNightTerminals()
	if nightActive or #deskParts() == 0 then
		return
	end
	nightActive = true
	nightDone = 0
	nightTarget = math.random(NIGHT_TERMINAL_MIN, NIGHT_TERMINAL_MAX)
	nightActiveDesk = nil
	advanceTerminal()
	print("[CodingGameServer] NIGHT2 recompile started —", nightTarget, "terminals.")
end

local function stopNightTerminals()
	nightActive = false
	clearTerminalHighlight()
end

--[[
	Sends current coding progress to a specific client.
	Includes blocked state so the UI can show sabotage effects.
]]
local function sendProgressUpdate(player: Player, state: PlayerCodingState): ()
	CodingProgressRemote:FireClient(player, {
		completion = state.completion,
		blocked = state.blocked,
		taskCount = state.taskCount,
	})
end

----------------------------------------------------------------------
-- Task Completion Handler
----------------------------------------------------------------------

--[[
	Validates and processes a CodingTaskComplete claim from a client.

	Anti-cheat checks:
	  1. Player must be in a coding-allowed phase (DAY2 or NIGHT2)
	  2. Player must be near a tagged desk
	  3. Cooldown must have elapsed since last task
	  4. Task type must be valid
	  5. Score must be in valid range
	  6. Power must not be sabotaged (blocked)
]]
local function onCodingTaskComplete(player: Player, payload: any): ()
	-- Phase gate: only accept during DAY2 or NIGHT2
	if currentPhase ~= GameConfig.Phase.DAY2 and currentPhase ~= GameConfig.Phase.NIGHT2 then
		warn("[CodingGameServer] Task rejected: wrong phase for", player.Name)
		return
	end

	-- Validate payload structure
	if typeof(payload) ~= "table" then
		warn("[CodingGameServer] Invalid payload from", player.Name)
		return
	end

	local taskType = payload.taskType
	local score = payload.score

	if typeof(taskType) ~= "string" or not VALID_TASK_TYPES[taskType] then
		warn("[CodingGameServer] Invalid taskType from", player.Name, ":", tostring(taskType))
		return
	end

	if typeof(score) ~= "number" or score < 0 or score > 1 then
		warn("[CodingGameServer] Invalid score from", player.Name, ":", tostring(score))
		return
	end

	-- Get or initialize player state
	local state = playerStates[player.UserId]
	if not state then
		initPlayerState(player)
		state = playerStates[player.UserId]
	end

	-- Anti-cheat: cooldown check
	local now = os.clock()
	if (now - state.lastTaskTick) < TASK_COOLDOWN then
		warn("[CodingGameServer] Task rejected: cooldown for", player.Name)
		return
	end

	-- Anti-cheat: proximity check
	if not isPlayerAtDesk(player) then
		warn("[CodingGameServer] Task rejected: not at desk for", player.Name)
		return
	end

	-- NIGHT2 gate: the "finish your project" recompile only unlocks once ALL the
	-- power AND all the servers are back online (PowerManager publishes this).
	if currentPhase == GameConfig.Phase.NIGHT2 and workspace:GetAttribute("NightSystemsRestored") ~= true then
		CodingProgressRemote:FireClient(player, {
			completion = state.completion,
			blocked = true,
			taskCount = state.taskCount,
		})
		return
	end

	-- Sabotage check: power is out → block progress
	if state.blocked then
		-- Notify client that coding is blocked
		CodingProgressRemote:FireClient(player, {
			completion = state.completion,
			blocked = true,
			taskCount = state.taskCount,
		})
		return
	end

	if currentPhase == GameConfig.Phase.DAY2 then
		-- Day 2: building the project — two flat tasks take you to 100%.
		state.completion = math.min(100, state.completion + DAY2_TASK_GAIN)
		state.lastTaskTick = now
		state.taskCount += 1
		print(string.format("[CodingGameServer] %s built the project → %.0f%%", player.Name, state.completion))
		sendProgressUpdate(player, state)

	elseif currentPhase == GameConfig.Phase.NIGHT2 then
		-- Night 2: the recompile scramble. Only the currently HIGHLIGHTED terminal
		-- counts; completing it lights up the next random one.
		if not nightActive then
			CodingProgressRemote:FireClient(player, { completion = state.completion, blocked = true, taskCount = state.taskCount })
			return
		end
		if not isPlayerAtPart(player, nightActiveDesk) then
			-- right idea, wrong machine — point them at the highlighted terminal
			CodingProgressRemote:FireClient(player, { completion = state.completion, wrongTerminal = true, taskCount = state.taskCount })
			return
		end
		state.lastTaskTick = now
		state.taskCount += 1
		nightDone += 1
		if nightDone >= nightTarget then
			broadcastNightObjective(true)
			stopNightTerminals()
			print("[CodingGameServer] NIGHT2 recompile complete.")
		else
			advanceTerminal()
			print(string.format("[CodingGameServer] %s recompiled (%d/%d).", player.Name, nightDone, nightTarget))
		end
		sendProgressUpdate(player, state)
	end
end

----------------------------------------------------------------------
-- Sabotage / Power System
----------------------------------------------------------------------

--[[
	When a sabotage event fires (PowerOutage), block all players' coding
	in the affected zone. In this simplified version, all players are
	blocked since we have a single venue.
]]
local function onSabotageEvent(_player: Player?, sabotageData: any): ()
	if typeof(sabotageData) ~= "table" then
		return
	end

	local sabotageType = sabotageData.sabotageType
	if sabotageType ~= "PowerOutage" and sabotageType ~= "ServerCrash" then
		return -- only power-related sabotages block coding
	end

	print("[CodingGameServer] Power sabotage! Blocking all coding progress.")

	for userId, state in playerStates do
		state.blocked = true

		-- Notify each affected player
		local player = Players:GetPlayerByUserId(userId)
		if player then
			CodingProgressRemote:FireClient(player, {
				completion = state.completion,
				blocked = true,
				taskCount = state.taskCount,
			})
		end
	end
end

--[[
	When a panel is repaired, unblock coding for all players.
	A more advanced version could track zones, but for the hackathon
	venue a single zone is sufficient.
]]
local function onPanelRepaired(_player: Player?): ()
	print("[CodingGameServer] Panel repaired. Unblocking coding progress.")

	for userId, state in playerStates do
		state.blocked = false

		local player = Players:GetPlayerByUserId(userId)
		if player then
			sendProgressUpdate(player, state)
		end
	end
end

----------------------------------------------------------------------
-- Phase Transition Handling
----------------------------------------------------------------------

--[[
	On phase change, lock in final completion percentages for ending
	evaluation. Reset blocked state for new phases.
]]
local function onGameStateChanged(_player: Player?, phaseData: any): ()
	if typeof(phaseData) ~= "table" then
		return
	end

	local newPhase = phaseData.phase
	if typeof(newPhase) ~= "number" then
		return
	end

	local oldPhase = currentPhase
	currentPhase = newPhase

	-- Night 2: the "finish your project" recompile only becomes available once ALL
	-- power and servers are restored (PowerManager sets NightSystemsRestored). Start
	-- it then; tear it down when the night ends.
	if newPhase == GameConfig.Phase.NIGHT2 then
		if workspace:GetAttribute("NightSystemsRestored") == true then
			startNightTerminals()
		else
			if nightPowerConn then
				nightPowerConn:Disconnect()
			end
			nightPowerConn = workspace:GetAttributeChangedSignal("NightSystemsRestored"):Connect(function()
				if currentPhase == GameConfig.Phase.NIGHT2 and workspace:GetAttribute("NightSystemsRestored") == true then
					startNightTerminals()
				end
			end)
		end
	elseif oldPhase == GameConfig.Phase.NIGHT2 then
		if nightPowerConn then
			nightPowerConn:Disconnect()
			nightPowerConn = nil
		end
		stopNightTerminals()
	end

	-- Transitioning OUT of DAY2 or NIGHT2 → store final completion
	if (oldPhase == GameConfig.Phase.DAY2 or oldPhase == GameConfig.Phase.NIGHT2)
		and newPhase ~= GameConfig.Phase.DAY2
		and newPhase ~= GameConfig.Phase.NIGHT2
	then
		print("[CodingGameServer] Phase ended — locking final completion percentages.")
		for userId, state in playerStates do
			state.finalCompletion = state.completion
			print(
				string.format(
					"  Player %d → %.1f%%",
					userId,
					state.completion
				)
			)
		end
	end

	-- Reset blocked state on any phase change
	for _, state in playerStates do
		state.blocked = false
	end
end

----------------------------------------------------------------------
-- Public Getter (for other server scripts)
----------------------------------------------------------------------

--[[
	Returns the completion percentage for a given player.
	Other server scripts (e.g., EndingEvaluator) can require this module
	via its parent (ServerScriptService.Server.CodingGameServer) — but
	since this is a Script not a ModuleScript, we expose via an attribute
	on the player instead.
]]
local function setPlayerCompletionAttribute(player: Player): ()
	local state = playerStates[player.UserId]
	if state then
		player:SetAttribute("ProjectCompletion", state.completion)
		if state.finalCompletion then
			player:SetAttribute("FinalProjectCompletion", state.finalCompletion)
		end
	end
end

-- Update attributes periodically so other systems can read them
task.spawn(function()
	while true do
		for _, player in Players:GetPlayers() do
			setPlayerCompletionAttribute(player)
		end
		task.wait(1)
	end
end)

----------------------------------------------------------------------
-- Connections
----------------------------------------------------------------------

-- Listen for task completions from clients
CodingTaskCompleteRemote.OnServerEvent:Connect(onCodingTaskComplete)

-- Listen for sabotage events (server-side, fired by SabotageManager)
SabotageEventRemote.OnServerEvent:Connect(onSabotageEvent)

-- Listen for panel repairs
PanelRepairedRemote.OnServerEvent:Connect(onPanelRepaired)

-- Listen for phase changes via the server phase bus (not a client remote).
do
	local ServerStorage = game:GetService("ServerStorage")
	local serverComm = ServerStorage:WaitForChild("ServerComm")
	local phaseBus = serverComm:WaitForChild("PhaseChanged") :: BindableEvent
	phaseBus.Event:Connect(function(phase: number)
		onGameStateChanged(nil, { phase = phase })
	end)
end

-- Player lifecycle
Players.PlayerAdded:Connect(function(player: Player)
	initPlayerState(player)
	print("[CodingGameServer] Initialized coding state for", player.Name)
end)

Players.PlayerRemoving:Connect(function(player: Player)
	-- Store final completion before cleanup
	setPlayerCompletionAttribute(player)
	cleanupPlayerState(player)
	print("[CodingGameServer] Cleaned up coding state for", player.Name)
end)

-- Initialize any players already in the game (studio hot-reload)
for _, player in Players:GetPlayers() do
	if not playerStates[player.UserId] then
		initPlayerState(player)
	end
end

print("[CodingGameServer] ✅ Coding progress system initialized")
