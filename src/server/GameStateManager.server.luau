--!strict
--------------------------------------------------------------------------------
-- GameStateManager.server.luau
-- Central server-side game controller for "Not Gonna Make It"
--
-- Implements the core state machine: LOBBY → DAY1 → DAY2 → NIGHT2 → DAY3
-- Manages per-match state, per-player data, phase transitions, timers,
-- in-game clock computation, NGMI spawning, sabotage events, and ending
-- evaluation.
--------------------------------------------------------------------------------

local Players         = game:GetService("Players")
local RunService      = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local ServerStorage   = game:GetService("ServerStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local DebugConfig = require(ReplicatedStorage.Shared.DebugConfig)
local ServerRole = require(script.Parent:WaitForChild("ServerRole"))
local BadgeManager = require(script.Parent:WaitForChild("BadgeManager"))

--------------------------------------------------------------------------------
-- Remote references (created by Rojo from default.project.json)
--------------------------------------------------------------------------------
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local GameStateChanged   = Remotes:WaitForChild("GameStateChanged")   :: RemoteEvent
local PhaseTimerSync     = Remotes:WaitForChild("PhaseTimerSync")     :: RemoteEvent
local CorruptionStarted  = Remotes:WaitForChild("CorruptionStarted")  :: RemoteEvent
local PlayerDamaged      = Remotes:WaitForChild("PlayerDamaged")      :: RemoteEvent
local PlayerDied         = Remotes:WaitForChild("PlayerDied")         :: RemoteEvent
local PlayerRespawn      = Remotes:WaitForChild("PlayerRespawn")      :: RemoteEvent
local CutsceneTrigger    = Remotes:WaitForChild("CutsceneTrigger")    :: RemoteEvent
local EndingTrigger      = Remotes:WaitForChild("EndingTrigger")      :: RemoteEvent
local SabotageEvent      = Remotes:WaitForChild("SabotageEvent")      :: RemoteEvent
local AdminCommand       = Remotes:WaitForChild("AdminCommand")       :: RemoteEvent

--------------------------------------------------------------------------------
-- Server-internal phase bus
--------------------------------------------------------------------------------
-- The other server subsystems (NPCs, NGMIs, Quests, Survival, Coding,
-- Interactions) were each written to learn the current phase a different way.
-- This authority publishes through ALL of them so every subsystem stays in
-- sync without needing to require this Script (which isn't possible):
--   • ServerStorage.ServerComm.PhaseChanged  (BindableEvent, number)
--   • ServerStorage.ServerComm.CorruptionTriggered (BindableEvent)
--   • ReplicatedStorage.CurrentPhase (IntValue)
--   • GameStateChanged:FireClient (RemoteEvent → clients)
--------------------------------------------------------------------------------

local function ensureFolder(parent: Instance, name: string): Folder
	local found = parent:FindFirstChild(name)
	if found and found:IsA("Folder") then
		return found
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local serverComm = ensureFolder(ServerStorage, "ServerComm")

local function ensureBindable(name: string): BindableEvent
	local found = serverComm:FindFirstChild(name)
	if found and found:IsA("BindableEvent") then
		return found
	end
	local bindable = Instance.new("BindableEvent")
	bindable.Name = name
	bindable.Parent = serverComm
	return bindable
end

local PhaseChangedBus = ensureBindable("PhaseChanged")
local CorruptionBus   = ensureBindable("CorruptionTriggered")
local StartMatchBus   = ensureBindable("StartMatch")

-- Replicated mirror of the phase so QuestManager (and any client) can read it.
local CurrentPhaseValue: IntValue
do
	local existing = ReplicatedStorage:FindFirstChild("CurrentPhase")
	if existing and existing:IsA("IntValue") then
		CurrentPhaseValue = existing
	else
		local iv = Instance.new("IntValue")
		iv.Name = "CurrentPhase"
		iv.Value = GameConfig.Phase.LOBBY
		iv.Parent = ReplicatedStorage
		CurrentPhaseValue = iv
	end
end

--- Publish a phase change to every server subsystem.
local function publishPhase(phase: number)
	CurrentPhaseValue.Value = phase
	PhaseChangedBus:Fire(phase)
end

--------------------------------------------------------------------------------
-- Type definitions
--------------------------------------------------------------------------------
export type PlayerData = {
	health: number,
	maxHealth: number,
	projectCompletion: number,  -- 0‑100 %
	inventory: { string },
	isAlive: boolean,
	isHiding: boolean,
	currentQuests: { string },
}

export type MatchState = {
	matchId: string,
	players: { Player },
	currentPhase: number,
	phaseStartTime: number,   -- os.clock() when phase began
	phaseTimer: number,        -- seconds remaining in phase
	gameTime: number,          -- in‑game clock hour (0‑24)
	corruptionTriggered: boolean,
	ngmiSpawnTimer: number,
	sabotageTimer: number,
	ngmiCount: number,
	ended: boolean,
}

--------------------------------------------------------------------------------
-- Module‑level state
--------------------------------------------------------------------------------
local activeMatch: MatchState? = nil
local playerDataMap: { [Player]: PlayerData } = {}

-- Unique match IDs
local matchCounter = 0

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

--- Generate a simple unique match ID
local function generateMatchId(): string
	matchCounter += 1
	return "match_" .. tostring(matchCounter) .. "_" .. tostring(math.floor(os.clock()))
end

--- Create default player data for a new player
local function createPlayerData(): PlayerData
	return {
		health = GameConfig.Player.maxHealth,
		maxHealth = GameConfig.Player.maxHealth,
		projectCompletion = 0,
		inventory = {},
		isAlive = true,
		isHiding = false,
		currentQuests = {},
	}
end

--- Compute the in‑game clock hour for the current phase & elapsed time.
--- Uses the linear mapping defined in GameConfig.PhaseTimeRanges.
--- For NIGHT2 the clock wraps past midnight (0→8).
local function computeGameClock(phase: number, elapsed: number): number
	local clockInfo = GameConfig.PhaseTimeRanges[phase]
	if not clockInfo then
		return 12 -- safe fallback: noon
	end

	local duration = GameConfig.PhaseDuration[phase]
	if not duration or duration <= 0 then
		return clockInfo.Start
	end

	local t = math.clamp(elapsed / duration, 0, 1) -- normalised progress

	local startH = clockInfo.Start
	local endH   = clockInfo.End

	-- Handle wrap‑around for night (e.g. 20→6 means 20→30 in linear space)
	if endH < startH then
		endH += 24
	end

	local hour = startH + (endH - startH) * t
	-- Wrap back into [0, 24) range
	if hour >= 24 then
		hour -= 24
	end

	return hour
end

--- Format an hour float into "HH:MM" (24‑h) — useful for debug logging
local function formatClock(hour: number): string
	local h = math.floor(hour) % 24
	local m = math.floor((hour % 1) * 60)
	return string.format("%02d:%02d", h, m)
end

--------------------------------------------------------------------------------
-- Broadcasting
--------------------------------------------------------------------------------

--- Send the phase timer sync packet to every player in the match.
--- Fired once per second from the Heartbeat loop.
local function broadcastTimerSync(match: MatchState)
	local data = {
		currentPhase   = match.currentPhase,
		timeRemaining  = math.max(0, math.floor(match.phaseTimer)),
		gameClockTime  = match.gameTime,
	}
	for _, player in match.players do
		PhaseTimerSync:FireClient(player, data)
	end
end

--- Notify all match players of a phase change
local function broadcastPhaseChange(match: MatchState, newPhase: number)
	for _, player in match.players do
		GameStateChanged:FireClient(player, {
			phase = newPhase,
			matchId = match.matchId,
		})
	end
end

--- Fire a remote to all match players
local function fireToAll(remote: RemoteEvent, match: MatchState, ...: any)
	for _, player in match.players do
		remote:FireClient(player, ...)
	end
end

--------------------------------------------------------------------------------
-- Player data accessors (used by other server scripts via require)
--------------------------------------------------------------------------------

local GameStateManager = {}

function GameStateManager.getPlayerData(player: Player): PlayerData?
	return playerDataMap[player]
end

function GameStateManager.getActiveMatch(): MatchState?
	return activeMatch
end

function GameStateManager.getCurrentPhase(): number
	if activeMatch then
		return activeMatch.currentPhase
	end
	return GameConfig.Phase.LOBBY
end

--------------------------------------------------------------------------------
-- Player damage / death / respawn
--------------------------------------------------------------------------------

--- Apply damage to a player. If health reaches 0, trigger death sequence.
function GameStateManager.damagePlayer(player: Player, amount: number)
	local data = playerDataMap[player]
	if not data or not data.isAlive then return end

	data.health = math.max(0, data.health - amount)
	PlayerDamaged:FireClient(player, { health = data.health, maxHealth = data.maxHealth })

	if data.health <= 0 then
		GameStateManager.killPlayer(player)
	end
end

--- Kill a player — fire PlayerDied, then schedule respawn after delay.
function GameStateManager.killPlayer(player: Player)
	local data = playerDataMap[player]
	if not data then return end

	data.isAlive = false
	data.health = 0
	PlayerDied:FireClient(player)

	-- Respawn after a short delay
	task.delay(GameConfig.RESPAWN_DELAY, function()
		-- Ensure player is still in the game
		if not player.Parent then return end
		local d = playerDataMap[player]
		if not d then return end

		d.isAlive = true
		d.health = GameConfig.Player.maxHealth
		PlayerRespawn:FireClient(player)

		-- Move character to a NIGHT2 spawn point if available
		local character = player.Character
		if character then
			local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root then
				-- Pick a random NGMI spawn for players during Night2 — keeps them
				-- inside the map rather than the lobby.
				local spawns = CollectionService:GetTagged(GameConfig.TAGS.PLAYER_DESK)
				if #spawns > 0 then
					local target = spawns[math.random(#spawns)]
					root.CFrame = (target :: BasePart).CFrame + Vector3.new(0, 5, 0)
				end
			end
		end
	end)
end

--- Heal a player by a given amount
function GameStateManager.healPlayer(player: Player, amount: number)
	local data = playerDataMap[player]
	if not data or not data.isAlive then return end
	data.health = math.min(data.maxHealth, data.health + amount)
	PlayerDamaged:FireClient(player, { health = data.health, maxHealth = data.maxHealth })
end

--- Add project completion progress
function GameStateManager.addProjectProgress(player: Player, amount: number)
	local data = playerDataMap[player]
	if not data then return end
	data.projectCompletion = math.clamp(data.projectCompletion + amount, 0, 100)
end

--------------------------------------------------------------------------------
-- Phase transition logic
--------------------------------------------------------------------------------

--- Transition to a new phase. Handles cleanup of the old phase and setup of
--- the new one.
local function transitionTo(match: MatchState, newPhase: number)
	print("[GameState] Transitioning from", match.currentPhase, "→", newPhase)

	match.currentPhase = newPhase
	match.phaseStartTime = os.clock()
	match.phaseTimer = GameConfig.PhaseDuration[newPhase] or 0

	-- Reset phase‑specific flags
	if newPhase == GameConfig.Phase.DAY2 then
		match.corruptionTriggered = false
	elseif newPhase == GameConfig.Phase.NIGHT2 then
		match.ngmiSpawnTimer = GameConfig.NGMISpawn.spawnInterval
		match.sabotageTimer = GameConfig.Sabotage.intervalMin
		match.ngmiCount = 0
	end

	-- Broadcast the change to clients…
	broadcastPhaseChange(match, newPhase)
	-- …and to every server-side subsystem listening on the phase bus.
	publishPhase(newPhase)

	-- Phase‑specific entry actions
	if newPhase == GameConfig.Phase.DAY1 then
		print("[GameState] DAY1 started — exploration phase (" .. (GameConfig.PhaseDuration[newPhase] or 0) .. "s)")

	elseif newPhase == GameConfig.Phase.DAY2 then
		print("[GameState] DAY2 started — coding phase (" .. (GameConfig.PhaseDuration[newPhase] or 0) .. "s)")

	elseif newPhase == GameConfig.Phase.NIGHT2 then
		print("[GameState] NIGHT2 started — survival horror (" .. (GameConfig.PhaseDuration[newPhase] or 0) .. "s)")

	elseif newPhase == GameConfig.Phase.DAY3 then
		print("[GameState] DAY3 started — evaluating endings")
		evaluateEndings(match) -- forward‑declared; defined below
	end
end

--------------------------------------------------------------------------------
-- NIGHT2 sub‑systems: NGMI spawning & sabotage
--------------------------------------------------------------------------------

--- Attempt to spawn an NGMI enemy at a random NGMISpawn tag.
local function trySpawnNGMI(match: MatchState)
	if match.ngmiCount >= GameConfig.NGMISpawn.maxCount then
		return
	end

	local spawns = CollectionService:GetTagged(GameConfig.TAGS.NGMI_SPAWN)
	if #spawns == 0 then
		warn("[GameState] No NGMISpawn tags found — cannot spawn NGMI")
		return
	end

	local spawnPart = spawns[math.random(#spawns)] :: BasePart
	match.ngmiCount += 1

	-- Actual NGMI creation is handled by a dedicated NGMIManager module.
	-- Here we fire a server‑side signal that the NGMI system listens to.
	-- For now, we log and can be extended later.
	print("[GameState] Spawning NGMI #" .. match.ngmiCount .. " at", spawnPart.Position)

	-- TODO: require(ServerScriptService.Server.NGMIManager).spawnAt(spawnPart.CFrame)
end

--- Fire a random sabotage event to all players
local function triggerSabotage(match: MatchState)
	local sabotageType = GameConfig.SABOTAGE_TYPES[math.random(#GameConfig.SABOTAGE_TYPES)]
	print("[GameState] Sabotage event:", sabotageType)
	fireToAll(SabotageEvent, match, { sabotageType = sabotageType })
end

--------------------------------------------------------------------------------
-- Ending evaluation
--------------------------------------------------------------------------------

--- Evaluate each player's outcome and fire the EndingTrigger remote.
--- Called upon entering DAY3.
function evaluateEndings(match: MatchState)
	match.ended = true

	for _, player in match.players do
		if not player.Parent then continue end -- player left

		local data = playerDataMap[player]
		if not data then continue end

		local endingType: string

		-- A player who died during the night already saw their death screen (and
		-- got the matching death badge) — don't replay an ending cutscene on top.
		-- Of the survivors: shipping 100% is the true ending; anyone who lived but
		-- shipped nothing has "become an NGMI" (the bad ending).
		if not data.isAlive then
			continue
		elseif data.projectCompletion >= GameConfig.COMPLETION_THRESHOLD then
			endingType = "true"
			BadgeManager.award(player, GameConfig.BADGES.trueEnding)
		else
			endingType = "bad"
			BadgeManager.award(player, GameConfig.BADGES.becameNGMI)
		end

		print("[GameState] Player", player.Name, "→", endingType,
			"(completion:", data.projectCompletion, "%, alive:", data.isAlive, ")")

		EndingTrigger:FireClient(player, {
			ending = endingType,
			projectCompletion = data.projectCompletion,
		})
	end
end

--------------------------------------------------------------------------------
-- Day1 → Day2 sleep transition helper
-- Fires a cutscene trigger so the client can fade‑to‑black / "sleeping…"
--------------------------------------------------------------------------------
local function triggerSleepCutscene(match: MatchState)
	fireToAll(CutsceneTrigger, match, { cutscene = "sleep" })
	-- Hold DAY1 until the client cinematic has the player asleep (screen black),
	-- then DAY2 begins so they wake straight into the morning. (Matches the
	-- timing of CutsceneManager.playSleepCutscene.)
	task.wait(9)
end

--------------------------------------------------------------------------------
-- Day2 → Night2 transition cutscene.
-- The client plays a long cinematic (CutsceneManager "nightTransition"): the
-- player dozes off, a montage shows the other hackers mutating into NGMIs, a
-- storm kills the power, and the player wakes into the dark. We hold the phase
-- for NIGHT_TRANSITION_HOLD so the flip to NIGHT2 lands mid-montage, while the
-- camera is on the off-map cutscene set and the real venue is hidden — the
-- venue is already dark (Night2_Horror lighting) by the time the eyes open.
--------------------------------------------------------------------------------
local NIGHT_TRANSITION_HOLD = 28 -- seconds; lands while the venue is still hidden

local function triggerNightTransitionCutscene(match: MatchState)
	fireToAll(CutsceneTrigger, match, { cutscene = "nightTransition" })
end

--- Open the final night with its transition cutscene: roll the cinematic on
--- every client, hold the current phase while it plays, then begin NIGHT2.
--- Shared by the objective-driven DAY2 completion and the admin "skip to
--- Night 2" command, so a skipped run starts exactly like a played one.
local function beginNight2WithCutscene(match: MatchState)
	task.spawn(function()
		triggerNightTransitionCutscene(match)
		task.wait(NIGHT_TRANSITION_HOLD)
		if not match.ended then
			transitionTo(match, GameConfig.Phase.NIGHT2)
		end
	end)
end

--- Open DAY2 with its Day1→Day2 sleep cutscene: roll it on every client, hold
--- DAY1 while it plays, then begin DAY2. Shared by the objective-driven DAY1
--- completion and the admin "skip to Day 2" command, so a skipped run starts
--- exactly like a played one.
local function beginDay2WithCutscene(match: MatchState)
	task.spawn(function()
		triggerSleepCutscene(match) -- fires "sleep" + holds ~9s (player asleep)
		if not match.ended then
			transitionTo(match, GameConfig.Phase.DAY2)
		end
	end)
end

--------------------------------------------------------------------------------
-- Main game loop — runs inside a Heartbeat connection
--------------------------------------------------------------------------------
local lastSyncTime = 0
local SYNC_INTERVAL = 1 -- broadcast timer sync every 1 second

local function onHeartbeat(dt: number)
	local match = activeMatch
	if not match or match.ended then return end

	local phase = match.currentPhase
	if phase == GameConfig.Phase.LOBBY then return end -- lobby doesn't tick

	local elapsed = os.clock() - match.phaseStartTime
	local duration = GameConfig.PhaseDuration[phase] or 0

	-- Update remaining timer
	match.phaseTimer = math.max(0, duration - elapsed)

	-- Compute in‑game clock
	match.gameTime = computeGameClock(phase, elapsed)

	--------------------------------------------------------------------
	-- Phase‑specific per‑frame logic
	--------------------------------------------------------------------

	if phase == GameConfig.Phase.DAY2 then
		-- Corruption trigger at the halfway point
		if not match.corruptionTriggered and elapsed >= GameConfig.DAY2_CORRUPTION_START then
			match.corruptionTriggered = true
			print("[GameState] CORRUPTION triggered at", formatClock(match.gameTime))
			fireToAll(CorruptionStarted, match)
			CorruptionBus:Fire()
		end

	elseif phase == GameConfig.Phase.NIGHT2 then
		-- NGMI spawning
		match.ngmiSpawnTimer -= dt
		if match.ngmiSpawnTimer <= 0 then
			match.ngmiSpawnTimer = GameConfig.NGMISpawn.spawnInterval
			trySpawnNGMI(match)
		end

		-- Sabotage events
		match.sabotageTimer -= dt
		if match.sabotageTimer <= 0 then
			match.sabotageTimer = math.random(GameConfig.Sabotage.intervalMin, GameConfig.Sabotage.intervalMax)
			triggerSabotage(match)
		end
	end

	--------------------------------------------------------------------
	-- Broadcast timer sync every SYNC_INTERVAL seconds
	--------------------------------------------------------------------
	lastSyncTime += dt
	if lastSyncTime >= SYNC_INTERVAL then
		lastSyncTime -= SYNC_INTERVAL
		broadcastTimerSync(match)
	end

	--------------------------------------------------------------------
	-- Phase expiry → next phase
	--------------------------------------------------------------------
	if duration > 0 and match.phaseTimer <= 0 then
		-- Only the final night is time-gated. DAY1 and DAY2 advance when their
		-- objectives are completed (ProgressionManager → RequestAdvance bus below),
		-- not on a timer.
		if phase == GameConfig.Phase.NIGHT2 then
			transitionTo(match, GameConfig.Phase.DAY3)
		end
	end
end

RunService.Heartbeat:Connect(onHeartbeat)

--------------------------------------------------------------------------------
-- Match lifecycle
--------------------------------------------------------------------------------

--- Assign each player their own PlayerDesk and publish it so the client can
--- draw a personal "your desk" beacon. Desks are tagged by MapBuilder (which
--- runs asynchronously), so we poll briefly until they exist. Each player gets
--- the desk at their roster index; the assignment is mirrored onto both the
--- player (AssignedDeskId attribute → replicates to that client) and the desk
--- (OwnerUserId attribute).
local function assignDesks(players: { Player })
	local desks: { Instance } = {}
	for _ = 1, 50 do
		desks = CollectionService:GetTagged(GameConfig.TAGS.PLAYER_DESK)
		if #desks > 0 then
			break
		end
		task.wait(0.2)
	end
	if #desks == 0 then
		warn("[GameState] No PlayerDesks found — cannot assign desks")
		return
	end

	-- Stable order by DeskId so assignment is deterministic
	table.sort(desks, function(a, b)
		local ida = (a:GetAttribute("DeskId") :: string?) or a.Name
		local idb = (b:GetAttribute("DeskId") :: string?) or b.Name
		return ida < idb
	end)

	for i, player in players do
		local desk = desks[((i - 1) % #desks) + 1]
		local deskId = (desk:GetAttribute("DeskId") :: string?) or desk.Name
		player:SetAttribute("AssignedDeskId", deskId)
		desk:SetAttribute("OwnerUserId", player.UserId)
	end
end

--- Start a new match with the given players.
--- This is called by the MatchmakingManager once a lobby fills up.
function GameStateManager.startMatch(players: { Player })
	-- Idempotent: never run two matches at once on a single server.
	if activeMatch then
		return
	end
	if #players == 0 then
		return
	end

	-- Create per‑player data
	for _, player in players do
		playerDataMap[player] = createPlayerData()
	end

	local match: MatchState = {
		matchId = generateMatchId(),
		players = players,
		currentPhase = GameConfig.Phase.LOBBY,
		phaseStartTime = os.clock(),
		phaseTimer = 0,
		gameTime = 18, -- 6 PM lobby
		corruptionTriggered = false,
		ngmiSpawnTimer = GameConfig.NGMISpawn.spawnInterval,
		sabotageTimer = GameConfig.Sabotage.intervalMin,
		ngmiCount = 0,
		ended = false,
	}

	activeMatch = match
	print("[GameState] Match", match.matchId, "created with", #players, "player(s)")

	-- Give every player their own desk + beacon (async; desks build on a delay)
	task.spawn(assignDesks, players)

	-- Immediately transition to DAY1
	transitionTo(match, GameConfig.Phase.DAY1)
end

--- Clean up after a match ends or a player leaves
function GameStateManager.endMatch()
	if activeMatch then
		print("[GameState] Match", activeMatch.matchId, "ended")
		activeMatch.ended = true
		activeMatch = nil
	end
end

--------------------------------------------------------------------------------
-- Player connection handling
--------------------------------------------------------------------------------

Players.PlayerRemoving:Connect(function(player)
	-- Clean up player data
	playerDataMap[player] = nil

	-- Remove from active match roster
	if activeMatch then
		local idx = table.find(activeMatch.players, player)
		if idx then
			table.remove(activeMatch.players, idx)
		end
		-- If no players left, end the match
		if #activeMatch.players == 0 then
			GameStateManager.endMatch()
		end
	end
end)

--------------------------------------------------------------------------------
-- Reserved match-server bootstrap
-- On a reserved server the matched party is teleported in to play immediately.
-- Wait a short grace period for everyone to arrive, then start the match once.
-- (On a lobby server / in Studio this stays dormant — matches there are kicked
-- off by LobbyManager through the StartMatch bus below.)
--------------------------------------------------------------------------------
if ServerRole.isMatchServer then
	local MATCH_START_GRACE = 3 -- seconds to let the whole party teleport in

	local function tryStartReservedMatch()
		if activeMatch then return end
		local present = Players:GetPlayers()
		if #present == 0 then return end
		GameStateManager.startMatch(present)
	end

	Players.PlayerAdded:Connect(function()
		task.delay(MATCH_START_GRACE, tryStartReservedMatch)
	end)
	for _, _existing in Players:GetPlayers() do
		task.delay(MATCH_START_GRACE, tryStartReservedMatch)
	end
end

--------------------------------------------------------------------------------
-- Match start requests from LobbyManager (via the StartMatch bus).
-- Payload is the array of players that filled the queue.
--------------------------------------------------------------------------------
StartMatchBus.Event:Connect(function(players: { Player })
	if typeof(players) ~= "table" then return end
	GameStateManager.startMatch(players)
end)

--------------------------------------------------------------------------------
-- Objective-driven advancement (ProgressionManager fires this when the current
-- phase's quests are all complete). DAY1 → sleep cutscene → DAY2 → NIGHT2.
--------------------------------------------------------------------------------
local AdvanceBus = ensureBindable("RequestAdvance")
AdvanceBus.Event:Connect(function()
	local match = activeMatch
	if not match or match.ended then
		return
	end
	local phase = match.currentPhase
	if phase == GameConfig.Phase.DAY1 then
		beginDay2WithCutscene(match)
	elseif phase == GameConfig.Phase.DAY2 then
		beginNight2WithCutscene(match)
	end
end)

--------------------------------------------------------------------------------
-- Admin / testing commands (gated by DebugConfig.isAdmin)
-- The client AdminPanel fires AdminCommand with { cmd = "...", ... }. Phase
-- transitions are server-authoritative, so jumping to a phase has to go through
-- here rather than the client poking the clock directly.
--------------------------------------------------------------------------------

--- True if `phase` is a real phase in the state machine.
local function isValidPhase(phase: any): boolean
	if type(phase) ~= "number" then return false end
	for _, p in GameConfig.PHASE_ORDER do
		if p == phase then return true end
	end
	return false
end

--- Force the match to a specific phase. Spins up a match with everyone present
--- if none is running yet (common when testing solo in Studio), and clears the
--- `ended` flag so you can keep skipping even after DAY3 evaluated an ending.
local function adminSetPhase(targetPhase: number)
	-- Cold-starting a match runs through DAY1, which fires the DAY1 opening
	-- ceremony. When the admin jumps straight to DAY2 or the final night, suppress
	-- that opening so it can't collide with the transition cutscene.
	local coldStart = not activeMatch
	if coldStart and (targetPhase == GameConfig.Phase.DAY2 or targetPhase == GameConfig.Phase.NIGHT2) then
		serverComm:SetAttribute("SkipOpening", true)
	end
	if coldStart then
		GameStateManager.startMatch(Players:GetPlayers()) -- lands on DAY1
	end
	local match = activeMatch
	if not match then return end

	match.ended = false

	-- A cold start already lands on DAY1, so "skip to Day 1" is a no-op here;
	-- re-transitioning would re-spawn the whole NPC cast (two of each).
	if match.currentPhase == targetPhase then
		return
	end

	-- Skipping to DAY2 / the final night opens with their transition cutscenes,
	-- exactly like reaching them through normal play.
	if targetPhase == GameConfig.Phase.NIGHT2 then
		beginNight2WithCutscene(match)
	elseif targetPhase == GameConfig.Phase.DAY2 then
		beginDay2WithCutscene(match)
	else
		transitionTo(match, targetPhase)
	end
end

AdminCommand.OnServerEvent:Connect(function(player: Player, payload: any)
	if not DebugConfig.isAdmin(player) then
		warn("[GameState] Rejected admin command from non-admin", player.Name)
		return
	end
	if typeof(payload) ~= "table" then return end

	if payload.cmd == "setPhase" and isValidPhase(payload.phase) then
		print("[GameState] Admin", player.Name, "→ setPhase", payload.phase)
		adminSetPhase(payload.phase)
	end
end)

return GameStateManager
