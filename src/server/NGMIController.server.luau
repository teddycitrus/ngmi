--!strict
--[[
	NGMIController.server.luau
	==========================
	Server-side AI for NGMI entities — mutated hackathon attendees that hunt
	players during the NIGHT2 phase. Each NGMI runs an independent state
	machine: PATROL → ALERT → CHASE → ATTACK, with STUNNED / RETREAT /
	LOST interrupts triggered by deodorant spray or lost line of sight.

	Spawning uses a wave system that escalates over the 15-minute night,
	and difficulty (speed, detection, attack cooldown) ramps every 5 min.
]]

--------------------------------------------------------------------------------
-- Services
--------------------------------------------------------------------------------
local CollectionService    = game:GetService("CollectionService")
local PathfindingService   = game:GetService("PathfindingService")
local Players              = game:GetService("Players")
local ReplicatedStorage    = game:GetService("ReplicatedStorage")
local RunService           = game:GetService("RunService")
local ServerStorage        = game:GetService("ServerStorage")

--------------------------------------------------------------------------------
-- Shared Config
--------------------------------------------------------------------------------
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local NGMIMutation = require(ReplicatedStorage.Shared.NGMIMutation)
local BadgeManager = require(script.Parent:WaitForChild("BadgeManager"))
local RigFactory = require(script.Parent:WaitForChild("RigFactory"))

--------------------------------------------------------------------------------
-- Remotes
--------------------------------------------------------------------------------
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PlayerDamaged     = Remotes:WaitForChild("PlayerDamaged")     :: RemoteEvent
local DeodorantSpray    = Remotes:WaitForChild("DeodorantSpray")    :: RemoteEvent
local NGMIStunned       = Remotes:WaitForChild("NGMIStunned")       :: RemoteEvent

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------
local PHASE_NIGHT2: number = GameConfig.Phase.NIGHT2

-- Wave definitions: { timeOffsetSeconds, count }
local WAVE_SCHEDULE: { { time: number, count: number } } = {
	{ time = 0,   count = 2 },  -- Wave 1: immediate
	{ time = 180, count = 3 },  -- Wave 2: 3:00
	{ time = 360, count = 4 },  -- Wave 3: 6:00
	{ time = 600, count = 5 },  -- Wave 4: 10:00
}

-- AI Tuning (base values — scaled by difficulty over time)
local BASE_SPEED: number            = GameConfig.NGMI.baseSpeed        -- 20
local DETECTION_RANGE: number       = GameConfig.NGMI.detectionRange   -- 40
local ATTACK_RANGE: number          = GameConfig.NGMI.attackRange      -- 5
local BASE_DAMAGE: number           = GameConfig.NGMI.baseDamage       -- 25
local STUN_DURATION: number         = GameConfig.NGMI.stunDuration     -- 3
local ATTACK_COOLDOWN_BASE: number  = 1  -- seconds between melee hits
local CHASE_SPEED_MULT: number      = 1.5
local RETREAT_SPEED_MULT: number    = 1.5
local RETREAT_DURATION: number      = 5   -- seconds fleeing after stun ends
local SPRAY_HITS_TO_DEFEAT: number  = 8   -- deodorant sprays to drive an NGMI off (1/8 each)
local LOST_TIMEOUT: number          = 8   -- seconds with no sight before giving up
local CHASE_MAX_DURATION: number    = 14  -- chase "for a bit" — then break off even if still in sight
local VISION_CONE_DOT: number       = math.cos(math.rad(30))  -- half-angle = 30° → 60° cone
local SOUND_DETECT_RANGE: number    = 25  -- sprint noise detection radius
local PROXIMITY_DETECT_RANGE: number = 12 -- notices you regardless of facing within this
local HIDING_DETECT_RANGE: number   = 5   -- can detect hidden players within this
local PATROL_PAUSE_MIN: number      = 2
local PATROL_PAUSE_MAX: number      = 4
local PATH_RECALC_INTERVAL: number  = 1   -- re-path every N seconds while chasing
local ALERT_PAUSE: number           = 0.5 -- seconds of freeze on first detection

-- Melee. Every attack is telegraphed: the NGMI winds up (clients animate it
-- from the AttackKind / AttackSeq attributes), strikes, and only lands the hit
-- if the target is still in reach a beat after the strike, so stepping back
-- out of a swing or sidestepping a lunge actually works.
local WINDUP: { [string]: number } = GameConfig.NGMI.attackWindup
local STRIKE_DRIVE: { [string]: number } = GameConfig.NGMI.attackStrike
local STRIKE_SPEED: { [string]: number } = { swipe_l = 16, swipe_r = 16, lunge = 44 }
local HIT_REACH: number             = 1.25 -- x ATTACK_RANGE, measured after the strike
local RECOVER_TIME: number          = 0.45
local LUNGE_RANGE: number           = 10   -- may leap in from this far while chasing
local LUNGE_CHANCE: number          = 1.1  -- per second, when in lunge range

-- Difficulty scaling every 5 minutes of Night 2
local DIFFICULTY_INTERVAL: number   = 300  -- 5 minutes
local SPEED_INCREASE: number        = 2
local RANGE_INCREASE: number        = 5
local COOLDOWN_DECREASE: number     = 0.2

-- NGMI appearance
local BODY_COLOR    = Color3.fromRGB(40, 10, 50)    -- dark purple-black
local EYE_COLOR     = Color3.fromRGB(255, 0, 0)     -- glowing red
local EYE_RADIUS    = 0.35                            -- studs

-- Mumble lines shown briefly over NGMI heads while patrolling
local PATROL_MUMBLES: { string } = {
	"SyntaxError: unexpected token...",
	"why won't it compile...",
	"undefined... undefined...",
	"Cannot read property 'soul'...",
	"NaN... NaN... NaN...",
	"fatal: not a git repository...",
	"Segmentation fault (core dumped)...",
	"TypeError: 'NoneType' is not iterable...",
	"error[E0382]: borrow of moved value...",
}

-- Chase voice lines screamed at players
local CHASE_LINES: { string } = {
	"Uncaught ReferenceError!",
	"SEGMENTATION FAULT!",
	"You're not making it out!",
	"Your code will never compile!",
	"NULL POINTER EXCEPTION!",
	"404: HOPE NOT FOUND!",
}

local STUN_TEXT: string = "*cough* *cough* Is that... hygiene?!"

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------
export type AIState = "PATROL" | "ALERT" | "CHASE" | "ATTACK" | "STUNNED" | "RETREAT" | "LOST"

type NGMIData = {
	model: Model,
	humanoid: Humanoid,
	rootPart: BasePart,
	headPart: BasePart,
	state: AIState,
	-- Deodorant combat: each spray deals 1/8 of max health, so 8 sprays drive
	-- one off for good. `health` counts down in whole spray-hits.
	health: number,
	maxHealth: number,
	targetPlayer: Player?,
	-- Timers
	stateTimer: number,     -- accumulator for time-in-state
	attackCooldown: number,  -- time until next attack is allowed
	pathTimer: number,       -- time since last pathfind recalculation
	patrolPauseRemaining: number,
	-- Patrol
	patrolWaypoints: { Vector3 },
	currentWaypointIndex: number,
	-- BillboardGui for overhead text
	billboardGui: BillboardGui,
	mumbleTimer: number,
	-- Path
	currentPath: Path?,
	pathWaypointIndex: number,
	-- Attack sequencing: nil when idle, else "windup" / "strike" / "recover"
	attackPhase: string?,
	attackKind: string,
	attackTimer: number,
	attackSeq: number,
	forceLunge: boolean,
}

--------------------------------------------------------------------------------
-- Module State
--------------------------------------------------------------------------------
local isNight2Active: boolean = false
local nightStartTime: number = 0     -- tick() when NIGHT2 began
local heartbeatConn: RBXScriptConnection? = nil

-- All live NGMI entities, keyed by model for fast lookup
local ngmiEntities: { [Model]: NGMIData } = {}

-- Track which waves have already spawned
local wavesSpawned: { [number]: boolean } = {}

-- Difficulty scaling applied on top of base values
local difficultySpeed: number = 0
local difficultyRange: number = 0
local difficultyCooldownReduction: number = 0
local lastDifficultyTier: number = 0

-- Weapon uses InventoryManager has confirmed (item, ammo and its use cooldown
-- checked), waiting for the user's client to report what it hit. Each
-- confirmed use allows exactly one DeodorantSpray hit, inside
-- SPRAY_CLAIM_WINDOW seconds and within that weapon's reach.
type ConfirmedUse = { at: number, reach: number }
local confirmedSprays: { [Player]: ConfirmedUse } = {}
local SPRAY_CLAIM_WINDOW = 2
-- Reach from the user's root to the NGMI's root. Client targeting looks 22
-- studs out (VFXManager); the slack covers the NGMI moving during the round
-- trip. Melee (chair leg, plunger) has a stun radius of about 6 studs, so it
-- only connects up close.
local WEAPON_REACH: { [string]: number } = { spray = 30, melee = 12 }

-- Track sprinting players for sound detection (set by external systems;
-- here we infer from Humanoid.WalkSpeed > base walk speed)
-- We check live each frame, so no cache is needed.

--------------------------------------------------------------------------------
-- Raycast Params (exclude NGMI models and non-collidable parts)
--------------------------------------------------------------------------------
local raycastParams = RaycastParams.new()
raycastParams.FilterType = Enum.RaycastFilterType.Exclude
raycastParams.IgnoreWater = true

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

--[[ Return all 'NGMISpawn' tagged parts in the workspace. ]]
local function getSpawnPoints(): { BasePart }
	local spawns: { BasePart } = {}
	for _, inst in CollectionService:GetTagged(GameConfig.TAGS.NGMI_SPAWN) do
		if inst:IsA("BasePart") then
			table.insert(spawns, inst)
		end
	end
	return spawns
end

--[[ Pick a random element from a list. ]]
local function randomPick<T>(list: { T }): T
	return list[math.random(1, #list)]
end

--[[ Get effective speed for an NGMI, factoring difficulty scaling. ]]
local function getEffectiveSpeed(): number
	return BASE_SPEED + difficultySpeed
end

--[[ Get effective detection range. ]]
local function getEffectiveDetectionRange(): number
	return DETECTION_RANGE + difficultyRange
end

--[[ Get effective attack cooldown. ]]
local function getEffectiveAttackCooldown(): number
	return math.max(0.3, ATTACK_COOLDOWN_BASE - difficultyCooldownReduction)
end

--[[ Build a list of patrol waypoints from all NGMI spawn points. ]]
local function buildPatrolWaypoints(): { Vector3 }
	local wps: { Vector3 } = {}
	for _, sp in getSpawnPoints() do
		table.insert(wps, sp.Position)
	end
	-- Fallback: if no spawn points exist, use origin area
	if #wps == 0 then
		table.insert(wps, Vector3.new(0, 5, 0))
		table.insert(wps, Vector3.new(30, 5, 30))
		table.insert(wps, Vector3.new(-30, 5, -30))
	end
	return wps
end

--------------------------------------------------------------------------------
-- NGMI Model Builder
--------------------------------------------------------------------------------
--[[
	Creates an NPC humanoid model with the NGMI aesthetic:
	- Dark purple-black body
	- Two small red neon spheres welded to the head (glowing eyes)
	- BillboardGui for overhead mumble/chase text
	- Tagged with CollectionService 'NGMI'
]]
--[[
	Join two parts with a Motor6D whose pivot sits `pivot` (in part1 space) away
	from part1's centre, so a limb swings from the shoulder / hip / neck instead
	of its middle. Motors rather than WeldConstraints so NGMIAnimator (client)
	can pose the body. C0 edits made on a client never replicate, so each client
	animates its own copy for free.
]]
local function motorJoint(name: string, part0: BasePart, part1: BasePart, pivot: Vector3): Motor6D
	local pivotCF = part1.CFrame * CFrame.new(pivot)
	local motor = Instance.new("Motor6D")
	motor.Name = name
	motor.Part0 = part0
	motor.Part1 = part1
	motor.C0 = part0.CFrame:ToObjectSpace(pivotCF)
	motor.C1 = CFrame.new(pivot)
	motor.Parent = part1
	return motor
end

--[[
	Legacy block NGMI, only used if the avatar API can't produce an R15 rig.
	Joint names match R15 so NGMIAnimator still poses what it has.
]]
local function createBlockNGMIModel(spawnCFrame: CFrame): Model
	-- Build a rig from scratch (R15-style simplified)
	local model = Instance.new("Model")
	model.Name = "NGMI"

	-- Torso (PrimaryPart)
	local torso = Instance.new("Part")
	torso.Name = "HumanoidRootPart"
	torso.Size = Vector3.new(2, 2, 1)
	torso.CFrame = spawnCFrame
	torso.Anchored = false
	torso.CanCollide = true
	torso.Color = BODY_COLOR
	torso.Material = Enum.Material.SmoothPlastic
	torso.Parent = model

	local upperTorso = Instance.new("Part")
	upperTorso.Name = "UpperTorso"
	upperTorso.Size = Vector3.new(2, 1.6, 1)
	upperTorso.CFrame = spawnCFrame * CFrame.new(0, 1.8, 0)
	upperTorso.Anchored = false
	upperTorso.CanCollide = false
	upperTorso.Color = BODY_COLOR
	upperTorso.Material = Enum.Material.SmoothPlastic
	upperTorso.Parent = model

	motorJoint("Waist", torso, upperTorso, Vector3.new(0, -0.8, 0))

	-- Head
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Shape = Enum.PartType.Ball
	head.Size = Vector3.new(1.6, 1.6, 1.6)
	head.CFrame = spawnCFrame * CFrame.new(0, 3.2, 0)
	head.Anchored = false
	head.CanCollide = false
	head.Color = BODY_COLOR
	head.Material = Enum.Material.SmoothPlastic
	head.Parent = model

	motorJoint("Neck", upperTorso, head, Vector3.new(0, -0.8, 0))

	-- Face (required for Humanoid to work properly)
	local face = Instance.new("Decal")
	face.Name = "face"
	face.Parent = head

	-- Left Eye (red neon sphere)
	local leftEye = Instance.new("Part")
	leftEye.Name = "LeftEye"
	leftEye.Shape = Enum.PartType.Ball
	leftEye.Size = Vector3.new(EYE_RADIUS * 2, EYE_RADIUS * 2, EYE_RADIUS * 2)
	leftEye.CFrame = head.CFrame * CFrame.new(-0.35, 0.15, -0.7)
	leftEye.Anchored = false
	leftEye.CanCollide = false
	leftEye.Color = EYE_COLOR
	leftEye.Material = Enum.Material.Neon
	leftEye.Parent = model

	local leftEyeWeld = Instance.new("WeldConstraint")
	leftEyeWeld.Part0 = head
	leftEyeWeld.Part1 = leftEye
	leftEyeWeld.Parent = leftEye

	-- Right Eye (red neon sphere)
	local rightEye = Instance.new("Part")
	rightEye.Name = "RightEye"
	rightEye.Shape = Enum.PartType.Ball
	rightEye.Size = Vector3.new(EYE_RADIUS * 2, EYE_RADIUS * 2, EYE_RADIUS * 2)
	rightEye.CFrame = head.CFrame * CFrame.new(0.35, 0.15, -0.7)
	rightEye.Anchored = false
	rightEye.CanCollide = false
	rightEye.Color = EYE_COLOR
	rightEye.Material = Enum.Material.Neon
	rightEye.Parent = model

	local rightEyeWeld = Instance.new("WeldConstraint")
	rightEyeWeld.Part0 = head
	rightEyeWeld.Part1 = rightEye
	rightEyeWeld.Parent = rightEye

	-- Arms (tattered look via rougher material)
	local leftArm = Instance.new("Part")
	leftArm.Name = "LeftUpperArm"
	leftArm.Size = Vector3.new(0.8, 2, 0.8)
	leftArm.CFrame = spawnCFrame * CFrame.new(-1.4, 1.8, 0)
	leftArm.Anchored = false
	leftArm.CanCollide = false
	leftArm.Color = BODY_COLOR
	leftArm.Material = Enum.Material.Slate -- tattered appearance
	leftArm.Parent = model

	motorJoint("LeftShoulder", upperTorso, leftArm, Vector3.new(0, 0.9, 0))

	local rightArm = Instance.new("Part")
	rightArm.Name = "RightUpperArm"
	rightArm.Size = Vector3.new(0.8, 2, 0.8)
	rightArm.CFrame = spawnCFrame * CFrame.new(1.4, 1.8, 0)
	rightArm.Anchored = false
	rightArm.CanCollide = false
	rightArm.Color = BODY_COLOR
	rightArm.Material = Enum.Material.Slate
	rightArm.Parent = model

	motorJoint("RightShoulder", upperTorso, rightArm, Vector3.new(0, 0.9, 0))

	-- Legs
	local leftLeg = Instance.new("Part")
	leftLeg.Name = "LeftUpperLeg"
	leftLeg.Size = Vector3.new(0.8, 2, 0.8)
	leftLeg.CFrame = spawnCFrame * CFrame.new(-0.5, -1, 0)
	leftLeg.Anchored = false
	leftLeg.CanCollide = false
	leftLeg.Color = BODY_COLOR
	leftLeg.Material = Enum.Material.Slate
	leftLeg.Parent = model

	motorJoint("LeftHip", torso, leftLeg, Vector3.new(0, 0.9, 0))

	local rightLeg = Instance.new("Part")
	rightLeg.Name = "RightUpperLeg"
	rightLeg.Size = Vector3.new(0.8, 2, 0.8)
	rightLeg.CFrame = spawnCFrame * CFrame.new(0.5, -1, 0)
	rightLeg.Anchored = false
	rightLeg.CanCollide = false
	rightLeg.Color = BODY_COLOR
	rightLeg.Material = Enum.Material.Slate
	rightLeg.Parent = model

	motorJoint("RightHip", torso, rightLeg, Vector3.new(0, 0.9, 0))

	-- Humanoid
	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = math.huge  -- NGMIs cannot be killed
	humanoid.Health = math.huge
	humanoid.WalkSpeed = getEffectiveSpeed()
	-- Hide the default overhead name/health "NGMI" tag floating above enemies
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.Parent = model

	model.PrimaryPart = torso

	-- BillboardGui for overhead text (mumbles, chase screams, stun text)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "OverheadGui"
	billboard.Size = UDim2.new(8, 0, 2, 0)
	billboard.StudsOffset = Vector3.new(0, 4, 0)
	billboard.Adornee = head
	billboard.AlwaysOnTop = false
	billboard.MaxDistance = 60
	billboard.Parent = model

	local textLabel = Instance.new("TextLabel")
	textLabel.Name = "MumbleText"
	textLabel.Size = UDim2.new(1, 0, 1, 0)
	textLabel.BackgroundTransparency = 1
	textLabel.TextColor3 = Color3.fromRGB(200, 50, 50)
	textLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	textLabel.TextStrokeTransparency = 0.3
	textLabel.Font = Enum.Font.Code
	textLabel.TextScaled = true
	textLabel.Text = ""
	textLabel.TextTransparency = 1  -- hidden by default
	textLabel.Parent = billboard

	-- Tag for CollectionService so client can find them
	CollectionService:AddTag(model, "NGMI")

	-- Parent to workspace
	model.Parent = workspace

	return model
end

--[[
	The real NGMI: a venue avatar rig run through the same mutation the night
	transition cutscene uses, so the things hunting you are the hackers you
	watched turn. Full R15 limbs (elbows, knees, hands) give NGMIAnimator
	something to stagger, lunge and swipe with.
]]
local function createNGMIModel(spawnCFrame: CFrame): Model
	local model, humanoid = RigFactory.create()
	if not model:FindFirstChild("UpperTorso") then
		model:Destroy()
		return createBlockNGMIModel(spawnCFrame)
	end
	model.Name = "NGMI"
	NGMIMutation.apply(model, math.random(1, 1000000))

	humanoid.MaxHealth = math.huge -- NGMIs cannot be killed
	humanoid.Health = math.huge
	humanoid.WalkSpeed = getEffectiveSpeed()
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.BreakJointsOnDeath = false

	local head = model:FindFirstChild("Head") :: BasePart
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "OverheadGui"
	billboard.Size = UDim2.new(8, 0, 2, 0)
	billboard.StudsOffset = Vector3.new(0, 3.5, 0)
	billboard.Adornee = head
	billboard.AlwaysOnTop = false
	billboard.MaxDistance = 60
	billboard.Parent = model

	local textLabel = Instance.new("TextLabel")
	textLabel.Name = "MumbleText"
	textLabel.Size = UDim2.new(1, 0, 1, 0)
	textLabel.BackgroundTransparency = 1
	textLabel.TextColor3 = Color3.fromRGB(200, 50, 50)
	textLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
	textLabel.TextStrokeTransparency = 0.3
	textLabel.Font = Enum.Font.Code
	textLabel.TextScaled = true
	textLabel.Text = ""
	textLabel.TextTransparency = 1
	textLabel.Parent = billboard

	model:PivotTo(spawnCFrame + Vector3.new(0, 1.5, 0))
	CollectionService:AddTag(model, "NGMI")
	model.Parent = workspace

	-- Server-owned physics, so the lunge impulse and facing writes land on the
	-- authoritative copy instead of a nearby player's simulation.
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		pcall(function()
			root:SetNetworkOwner(nil)
		end)
	end

	return model
end

--------------------------------------------------------------------------------
-- NGMI Entity Registration
--------------------------------------------------------------------------------

--[[ Create an NGMIData record for a freshly spawned model. ]]
local function registerNGMI(model: Model): NGMIData
	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	local rootPart = model:FindFirstChild("HumanoidRootPart") :: BasePart
	local headPart = model:FindFirstChild("Head") :: BasePart
	local billboard = model:FindFirstChild("OverheadGui") :: BillboardGui

	local waypoints = buildPatrolWaypoints()

	local data: NGMIData = {
		model = model,
		humanoid = humanoid,
		rootPart = rootPart,
		headPart = headPart,
		state = "PATROL",
		health = SPRAY_HITS_TO_DEFEAT,
		maxHealth = SPRAY_HITS_TO_DEFEAT,
		targetPlayer = nil,
		stateTimer = 0,
		attackCooldown = 0,
		pathTimer = 0,
		patrolPauseRemaining = 0,
		patrolWaypoints = waypoints,
		currentWaypointIndex = math.random(1, #waypoints),
		billboardGui = billboard,
		mumbleTimer = math.random(3, 6),
		currentPath = nil,
		pathWaypointIndex = 1,
		attackPhase = nil,
		attackKind = "swipe_r",
		attackTimer = 0,
		attackSeq = 0,
		forceLunge = false,
	}

	ngmiEntities[model] = data
	model:SetAttribute("AIState", data.state)
	return data
end

--------------------------------------------------------------------------------
-- Detection System
--------------------------------------------------------------------------------

--[[ Check line-of-sight from NGMI head to a target position via raycast. ]]
local function hasLineOfSight(ngmi: NGMIData, targetPos: Vector3): boolean
	local origin = ngmi.headPart.Position
	local direction = targetPos - origin
	local distance = direction.Magnitude

	if distance < 0.1 then
		return true
	end

	-- Build exclusion list: all parts belonging to this NGMI model
	local excludeList: { Instance } = { ngmi.model }
	-- Also exclude other NGMI models to prevent them blocking each other
	for otherModel, _ in ngmiEntities do
		if otherModel ~= ngmi.model then
			table.insert(excludeList, otherModel)
		end
	end
	raycastParams.FilterDescendantsInstances = excludeList

	local result = workspace:Raycast(origin, direction.Unit * distance, raycastParams)

	-- If nothing was hit, line of sight is clear
	if result == nil then
		return true
	end

	-- If we hit something that is a descendant of a player character, that's the player
	for _, player in Players:GetPlayers() do
		local char = player.Character
		if char and result.Instance:IsDescendantOf(char) then
			return true
		end
	end

	return false
end

--[[ Check if targetPos is within the NGMI's vision cone (60° total). ]]
local function isInVisionCone(ngmi: NGMIData, targetPos: Vector3): boolean
	local lookDir = ngmi.rootPart.CFrame.LookVector
	local toTarget = (targetPos - ngmi.headPart.Position).Unit
	local dot = lookDir:Dot(toTarget)
	return dot >= VISION_CONE_DOT
end

--[[ Check if a player is sprinting (WalkSpeed above base). ]]
local function isPlayerSprinting(player: Player): boolean
	local char = player.Character
	if not char then
		return false
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return false
	end
	-- If MoveDirection magnitude is near zero, they aren't moving even if speed is high
	if hum.MoveDirection.Magnitude < 0.1 then
		return false
	end
	return hum.WalkSpeed > GameConfig.Player.walkSpeed
end

--[[ Check if a player is hiding. ]]
local function isPlayerHiding(player: Player): boolean
	-- Set only by InteractionManager's hiding-spot prompt (server side).
	return player:GetAttribute("Hiding") == true
end

--[[
	Scan all players and return the best detection target for this NGMI.
	Returns nil if no player is detectable.

	Detection rules:
	  1. Vision: within detectionRange AND in 60° cone AND line of sight
	  2. Sound: sprinting within 25 studs (ignores vision cone)
	  3. Hiding: hidden players are invisible unless NGMI is within 5 studs
]]
local function detectPlayer(ngmi: NGMIData): Player?
	local detectionRange = getEffectiveDetectionRange()
	local bestPlayer: Player? = nil
	local bestDistSq: number = math.huge

	for _, player in Players:GetPlayers() do
		local char = player.Character
		if not char then
			continue
		end
		local humanoid = char:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then
			continue
		end
		local playerHead = char:FindFirstChild("Head") :: BasePart?
		if not playerHead then
			continue
		end

		local delta = playerHead.Position - ngmi.headPart.Position
		local distSq = delta.Magnitude * delta.Magnitude
		local dist = delta.Magnitude

		local hiding = isPlayerHiding(player)

		-- Hidden players: only detectable within 5 studs
		if hiding then
			if dist > HIDING_DETECT_RANGE then
				continue
			end
			-- Within 5 studs, hidden players are detected regardless
			if distSq < bestDistSq then
				bestDistSq = distSq
				bestPlayer = player
			end
			continue
		end

		-- Sound detection: sprinting within 25 studs (no vision needed)
		if isPlayerSprinting(player) and dist <= SOUND_DETECT_RANGE then
			if distSq < bestDistSq then
				bestDistSq = distSq
				bestPlayer = player
			end
			continue
		end

		-- Close proximity: walk into an NGMI's personal space and it notices you,
		-- whichever way it's facing (no vision cone needed), as long as it can
		-- actually see you (not through a wall).
		if dist <= PROXIMITY_DETECT_RANGE and hasLineOfSight(ngmi, playerHead.Position) then
			if distSq < bestDistSq then
				bestDistSq = distSq
				bestPlayer = player
			end
			continue
		end

		-- Vision detection: range + cone + line of sight
		if dist <= detectionRange then
			if isInVisionCone(ngmi, playerHead.Position) then
				if hasLineOfSight(ngmi, playerHead.Position) then
					if distSq < bestDistSq then
						bestDistSq = distSq
						bestPlayer = player
					end
				end
			end
		end
	end

	return bestPlayer
end

--------------------------------------------------------------------------------
-- Overhead Text
--------------------------------------------------------------------------------

--[[ Flash text above an NGMI's head for a brief duration. ]]
local function showOverheadText(ngmi: NGMIData, text: string, duration: number): ()
	local label = ngmi.billboardGui:FindFirstChild("MumbleText") :: TextLabel?
	if not label then
		return
	end
	label.Text = text
	label.TextTransparency = 0

	task.delay(duration, function()
		-- Only hide if the text hasn't been changed since we set it
		if label and label.Text == text then
			label.TextTransparency = 1
			label.Text = ""
		end
	end)
end

--------------------------------------------------------------------------------
-- Pathfinding
--------------------------------------------------------------------------------

--[[ Compute a path from the NGMI to a target position and start walking. ]]
local function navigateTo(ngmi: NGMIData, targetPos: Vector3): ()
	local path = PathfindingService:CreatePath({
		AgentRadius = 2,
		AgentHeight = 5,
		AgentCanJump = true,
		AgentCanClimb = false,
	})

	local ok = pcall(function()
		path:ComputeAsync(ngmi.rootPart.Position, targetPos)
	end)

	if not ok or path.Status ~= Enum.PathStatus.Success then
		-- Fallback: walk directly toward target
		ngmi.humanoid:MoveTo(targetPos)
		ngmi.currentPath = nil
		return
	end

	local waypoints = path:GetWaypoints()
	ngmi.currentPath = path
	ngmi.pathWaypointIndex = 2 -- skip first waypoint (current position)

	if #waypoints >= 2 then
		local wp = waypoints[2]
		if wp.Action == Enum.PathWaypointAction.Jump then
			ngmi.humanoid.Jump = true
		end
		ngmi.humanoid:MoveTo(wp.Position)
	else
		ngmi.humanoid:MoveTo(targetPos)
	end
end

--[[ Advance to the next waypoint in the current path, if any. ]]
local function advancePathWaypoint(ngmi: NGMIData): boolean
	if not ngmi.currentPath then
		return false
	end

	local waypoints = ngmi.currentPath:GetWaypoints()
	ngmi.pathWaypointIndex += 1

	if ngmi.pathWaypointIndex > #waypoints then
		ngmi.currentPath = nil
		return false
	end

	local wp = waypoints[ngmi.pathWaypointIndex]
	if wp.Action == Enum.PathWaypointAction.Jump then
		ngmi.humanoid.Jump = true
	end
	ngmi.humanoid:MoveTo(wp.Position)
	return true
end

--------------------------------------------------------------------------------
-- State Machine: Transition Helpers
--------------------------------------------------------------------------------

local function transitionTo(ngmi: NGMIData, newState: AIState, target: Player?): ()
	ngmi.state = newState
	-- Replicated so NGMIAnimator (client) can switch body language per state.
	ngmi.model:SetAttribute("AIState", newState)
	ngmi.stateTimer = 0
	ngmi.targetPlayer = target
	ngmi.currentPath = nil
	if newState ~= "ATTACK" then
		ngmi.attackPhase = nil
		ngmi.forceLunge = false
	end

	if newState == "PATROL" then
		ngmi.humanoid.WalkSpeed = getEffectiveSpeed()
		ngmi.targetPlayer = nil
		ngmi.patrolPauseRemaining = 0
		ngmi.pathTimer = 0
		-- currentPath is already nil; updatePatrol will pathfind a nearby wander
		-- leg (NOT a straight MoveTo to a far spawn point, which walked them into
		-- walls).

	elseif newState == "ALERT" then
		ngmi.humanoid.WalkSpeed = 0
		-- Brief freeze before chase
		showOverheadText(ngmi, "...!", 1)

	elseif newState == "CHASE" then
		ngmi.humanoid.WalkSpeed = getEffectiveSpeed() * CHASE_SPEED_MULT
		ngmi.pathTimer = PATH_RECALC_INTERVAL -- force immediate path calc
		-- Scream a voice line
		showOverheadText(ngmi, randomPick(CHASE_LINES), 2)

	elseif newState == "ATTACK" then
		ngmi.humanoid.WalkSpeed = 0

	elseif newState == "STUNNED" then
		ngmi.humanoid.WalkSpeed = 0
		showOverheadText(ngmi, STUN_TEXT, STUN_DURATION)

	elseif newState == "RETREAT" then
		ngmi.humanoid.WalkSpeed = getEffectiveSpeed() * RETREAT_SPEED_MULT
		ngmi.targetPlayer = nil

	elseif newState == "LOST" then
		ngmi.humanoid.WalkSpeed = getEffectiveSpeed() * 0.7  -- slow cautious search
	end
end

--------------------------------------------------------------------------------
-- State Machine: Per-Frame Update
--------------------------------------------------------------------------------

local function updatePatrol(ngmi: NGMIData, dt: number): ()
	-- Periodic mumble text
	ngmi.mumbleTimer -= dt
	if ngmi.mumbleTimer <= 0 then
		showOverheadText(ngmi, randomPick(PATROL_MUMBLES), 2)
		ngmi.mumbleTimer = math.random(4, 8)
	end

	-- Check for player detection
	local detected = detectPlayer(ngmi)
	if detected then
		transitionTo(ngmi, "ALERT", detected)
		return
	end

	-- Dwelling at the end of a wander leg.
	if ngmi.patrolPauseRemaining > 0 then
		ngmi.patrolPauseRemaining -= dt
		return
	end

	ngmi.pathTimer += dt

	-- No active path → start a new wander leg toward a nearby point, navigating
	-- around walls via pathfinding (a straight MoveTo to a far spawn point used to
	-- send them face-first into walls).
	if not ngmi.currentPath then
		local ang = math.random() * math.pi * 2
		local rad = math.random(16, 32)
		local goal = ngmi.rootPart.Position + Vector3.new(math.cos(ang) * rad, 0, math.sin(ang) * rad)
		navigateTo(ngmi, goal)
		ngmi.pathTimer = 0
		if not ngmi.currentPath then
			-- pathfinding failed; brief dwell before trying a different direction
			ngmi.patrolPauseRemaining = 0.6
		end
		return
	end

	-- Abandon a leg we've been stuck on too long (re-path next).
	if ngmi.pathTimer > 6 then
		ngmi.currentPath = nil
		ngmi.patrolPauseRemaining = 0.4
		return
	end

	-- Follow the path, advancing through its waypoints.
	local wps = ngmi.currentPath:GetWaypoints()
	if ngmi.pathWaypointIndex <= #wps then
		local wpPos = wps[ngmi.pathWaypointIndex].Position
		if (ngmi.rootPart.Position - wpPos).Magnitude < 3.5 then
			if not advancePathWaypoint(ngmi) then
				-- arrived → dwell a moment, then pick a fresh wander leg
				ngmi.currentPath = nil
				ngmi.patrolPauseRemaining = PATROL_PAUSE_MIN + math.random() * (PATROL_PAUSE_MAX - PATROL_PAUSE_MIN)
			end
		end
	else
		ngmi.currentPath = nil
		ngmi.patrolPauseRemaining = PATROL_PAUSE_MIN
	end
end

local function updateAlert(ngmi: NGMIData, dt: number): ()
	ngmi.stateTimer += dt
	if ngmi.stateTimer >= ALERT_PAUSE then
		-- Transition to chase if we still have a target
		if ngmi.targetPlayer then
			transitionTo(ngmi, "CHASE", ngmi.targetPlayer)
		else
			transitionTo(ngmi, "PATROL", nil)
		end
	end
end

local function updateChase(ngmi: NGMIData, dt: number): ()
	local target = ngmi.targetPlayer
	if not target then
		transitionTo(ngmi, "PATROL", nil)
		return
	end

	-- Chase "for a bit", then break off and wander away even if still in sight,
	-- so a single NGMI doesn't hound the player forever.
	ngmi.stateTimer += dt
	if ngmi.stateTimer >= CHASE_MAX_DURATION then
		showOverheadText(ngmi, "...lost the thread.", 1.5)
		transitionTo(ngmi, "LOST", target)
		return
	end

	local char = target.Character
	if not char then
		transitionTo(ngmi, "LOST", target)
		return
	end
	local targetHumanoid = char:FindFirstChildOfClass("Humanoid")
	if not targetHumanoid or targetHumanoid.Health <= 0 then
		transitionTo(ngmi, "PATROL", nil)
		return
	end
	local targetRoot = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not targetRoot then
		transitionTo(ngmi, "LOST", target)
		return
	end

	local dist = (ngmi.rootPart.Position - targetRoot.Position).Magnitude

	-- If within attack range, switch to ATTACK
	if dist <= ATTACK_RANGE then
		transitionTo(ngmi, "ATTACK", target)
		return
	end

	-- Clicker leap: from a few strides out, sometimes launch straight at them.
	if dist <= LUNGE_RANGE and ngmi.attackCooldown <= 0 and math.random() < LUNGE_CHANCE * dt
		and hasLineOfSight(ngmi, targetRoot.Position) then
		transitionTo(ngmi, "ATTACK", target)
		ngmi.forceLunge = true
		return
	end

	-- If target is hiding and out of close range, lose them
	if isPlayerHiding(target) and dist > HIDING_DETECT_RANGE then
		transitionTo(ngmi, "LOST", target)
		return
	end

	-- Check line of sight periodically — if lost, start LOST timer
	if not hasLineOfSight(ngmi, targetRoot.Position) and not isPlayerSprinting(target) then
		-- Can't see or hear them — start losing track
		transitionTo(ngmi, "LOST", target)
		return
	end

	-- Recalculate path periodically
	ngmi.pathTimer += dt
	if ngmi.pathTimer >= PATH_RECALC_INTERVAL then
		ngmi.pathTimer = 0
		navigateTo(ngmi, targetRoot.Position)
		-- Yell periodically during chase
		if math.random() < 0.3 then
			showOverheadText(ngmi, randomPick(CHASE_LINES), 1.5)
		end
	end

	-- Advance waypoints if close to current one
	if ngmi.currentPath then
		local wps = ngmi.currentPath:GetWaypoints()
		if ngmi.pathWaypointIndex <= #wps then
			local wpPos = wps[ngmi.pathWaypointIndex].Position
			if (ngmi.rootPart.Position - wpPos).Magnitude < 3 then
				advancePathWaypoint(ngmi)
			end
		end
	end
end

local function startAttack(ngmi: NGMIData, dist: number)
	local kind: string
	if ngmi.forceLunge or (dist > ATTACK_RANGE * 0.7 and math.random() < 0.5) then
		kind = "lunge"
	else
		kind = if math.random() < 0.5 then "swipe_l" else "swipe_r"
	end
	ngmi.forceLunge = false
	ngmi.attackKind = kind
	ngmi.attackPhase = "windup"
	ngmi.attackTimer = WINDUP[kind]
	ngmi.attackSeq += 1
	ngmi.model:SetAttribute("AttackKind", kind)
	ngmi.model:SetAttribute("AttackSeq", ngmi.attackSeq)
end

local function landHit(ngmi: NGMIData, target: Player, targetHumanoid: Humanoid)
	PlayerDamaged:FireClient(target, BASE_DAMAGE, ngmi.model)
	-- Tag the cause so the death screen shows the right message, then apply
	-- damage to their Humanoid directly (server-authoritative).
	target:SetAttribute("DeathCause", "ngmi")
	targetHumanoid:TakeDamage(BASE_DAMAGE)
	if targetHumanoid.Health <= 0 then
		BadgeManager.award(target, GameConfig.BADGES.deathByNGMI)
	end
end

local function updateAttack(ngmi: NGMIData, dt: number): ()
	local target = ngmi.targetPlayer
	if not target then
		transitionTo(ngmi, "PATROL", nil)
		return
	end

	local char = target.Character
	if not char then
		transitionTo(ngmi, "PATROL", nil)
		return
	end
	local targetHumanoid = char:FindFirstChildOfClass("Humanoid")
	if not targetHumanoid or targetHumanoid.Health <= 0 then
		transitionTo(ngmi, "PATROL", nil)
		return
	end
	local targetRoot = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not targetRoot then
		transitionTo(ngmi, "PATROL", nil)
		return
	end

	local toTarget = targetRoot.Position - ngmi.rootPart.Position
	local dist = toTarget.Magnitude

	local function faceTarget()
		local flat = Vector3.new(toTarget.X, 0, toTarget.Z)
		if flat.Magnitude > 0.05 then
			ngmi.rootPart.CFrame = CFrame.lookAt(ngmi.rootPart.Position, ngmi.rootPart.Position + flat)
		end
	end

	if ngmi.attackPhase == "windup" then
		-- Coiled, tracking the target, committed to the swing.
		faceTarget()
		ngmi.attackTimer -= dt
		if ngmi.attackTimer <= 0 then
			ngmi.attackPhase = "strike"
			ngmi.attackTimer = STRIKE_DRIVE[ngmi.attackKind]
			-- Drive through the strike: a burst of speed toward where they are.
			ngmi.humanoid.WalkSpeed = STRIKE_SPEED[ngmi.attackKind]
			ngmi.humanoid:MoveTo(targetRoot.Position)
			if ngmi.attackKind == "lunge" then
				ngmi.rootPart.AssemblyLinearVelocity = toTarget.Unit * STRIKE_SPEED.lunge + Vector3.new(0, 9, 0)
			end
		end
		return
	elseif ngmi.attackPhase == "strike" then
		ngmi.attackTimer -= dt
		if ngmi.attackTimer <= 0 then
			ngmi.humanoid.WalkSpeed = 0
			ngmi.humanoid:MoveTo(ngmi.rootPart.Position)
			if dist <= ATTACK_RANGE * HIT_REACH then
				landHit(ngmi, target, targetHumanoid)
			end
			ngmi.attackPhase = "recover"
			ngmi.attackTimer = RECOVER_TIME
		end
		return
	elseif ngmi.attackPhase == "recover" then
		ngmi.attackTimer -= dt
		if ngmi.attackTimer <= 0 then
			ngmi.attackPhase = nil
			ngmi.attackCooldown = getEffectiveAttackCooldown()
		end
		return
	end

	-- Between attacks: break off to chase if they got away.
	if dist > ATTACK_RANGE * 1.5 and not ngmi.forceLunge then
		transitionTo(ngmi, "CHASE", target)
		return
	end

	faceTarget()
	if ngmi.attackCooldown <= 0 then
		startAttack(ngmi, dist)
	end
end

local function updateStunned(ngmi: NGMIData, dt: number): ()
	ngmi.stateTimer += dt
	-- Freeze in place
	ngmi.humanoid.WalkSpeed = 0
	ngmi.humanoid:MoveTo(ngmi.rootPart.Position)

	if ngmi.stateTimer >= STUN_DURATION then
		transitionTo(ngmi, "RETREAT", nil)
	end
end

local function updateRetreat(ngmi: NGMIData, dt: number): ()
	ngmi.stateTimer += dt

	-- Run away from the last known player direction
	if ngmi.stateTimer < 0.1 then
		-- Pick a direction: away from nearest player
		local awayDir = Vector3.new(0, 0, 1)
		local closestDistSq = math.huge
		for _, player in Players:GetPlayers() do
			local char = player.Character
			if char then
				local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
				if root then
					local delta = ngmi.rootPart.Position - root.Position
					local dSq = delta.Magnitude * delta.Magnitude
					if dSq < closestDistSq then
						closestDistSq = dSq
						awayDir = delta.Unit
					end
				end
			end
		end
		-- Move 50 studs in the away direction
		local retreatTarget = ngmi.rootPart.Position + awayDir * 50
		navigateTo(ngmi, retreatTarget)
	end

	if ngmi.stateTimer >= RETREAT_DURATION then
		transitionTo(ngmi, "PATROL", nil)
	end
end

local function updateLost(ngmi: NGMIData, dt: number): ()
	ngmi.stateTimer += dt

	-- Try to re-detect the target
	local target = ngmi.targetPlayer
	if target then
		local char = target.Character
		if char then
			local playerHead = char:FindFirstChild("Head") :: BasePart?
			if playerHead then
				local dist = (ngmi.headPart.Position - playerHead.Position).Magnitude
				if dist <= getEffectiveDetectionRange() and hasLineOfSight(ngmi, playerHead.Position) then
					transitionTo(ngmi, "CHASE", target)
					return
				end
			end
		end
	end

	-- Also scan for any other player
	local newDetected = detectPlayer(ngmi)
	if newDetected then
		transitionTo(ngmi, "ALERT", newDetected)
		return
	end

	-- Wander toward last known position briefly
	if ngmi.stateTimer < 1 and target then
		local char = target.Character
		if char then
			local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root then
				ngmi.humanoid:MoveTo(root.Position)
			end
		end
	end

	-- Give up after timeout
	if ngmi.stateTimer >= LOST_TIMEOUT then
		transitionTo(ngmi, "PATROL", nil)
	end
end

--------------------------------------------------------------------------------
-- Master Update (per NGMI, per frame)
--------------------------------------------------------------------------------

local function updateNGMI(ngmi: NGMIData, dt: number): ()
	-- Safety: if model was destroyed
	if not ngmi.model.Parent then
		ngmiEntities[ngmi.model] = nil
		return
	end

	-- Update attack cooldown globally
	if ngmi.attackCooldown > 0 then
		ngmi.attackCooldown -= dt
	end

	-- Dispatch to state handler
	if ngmi.state == "PATROL" then
		updatePatrol(ngmi, dt)
	elseif ngmi.state == "ALERT" then
		updateAlert(ngmi, dt)
	elseif ngmi.state == "CHASE" then
		updateChase(ngmi, dt)
	elseif ngmi.state == "ATTACK" then
		updateAttack(ngmi, dt)
	elseif ngmi.state == "STUNNED" then
		updateStunned(ngmi, dt)
	elseif ngmi.state == "RETREAT" then
		updateRetreat(ngmi, dt)
	elseif ngmi.state == "LOST" then
		updateLost(ngmi, dt)
	end
end

--------------------------------------------------------------------------------
-- Wave Spawning
--------------------------------------------------------------------------------

--[[ Spawn a wave of NGMIs at random spawn points. ]]
local function spawnWave(count: number): ()
	local spawns = getSpawnPoints()
	if #spawns == 0 then
		warn("[NGMIController] No NGMISpawn points found — cannot spawn wave")
		return
	end

	for _ = 1, count do
		local spawnPart = randomPick(spawns)
		local spawnCF = spawnPart.CFrame + Vector3.new(
			math.random(-3, 3),
			0,
			math.random(-3, 3)
		)

		local model = createNGMIModel(spawnCF)
		registerNGMI(model)
	end

	print(("[NGMIController] Spawned wave: %d NGMIs (total active: %d)"):format(
		count,
		-- count active
		(function()
			local n = 0
			for _ in ngmiEntities do
				n += 1
			end
			return n
		end)()
	))
end

--[[ Check if any waves should spawn based on elapsed Night2 time. ]]
local function checkWaveSpawns(): ()
	local elapsed = tick() - nightStartTime

	for i, wave in WAVE_SCHEDULE do
		if not wavesSpawned[i] and elapsed >= wave.time then
			wavesSpawned[i] = true
			spawnWave(wave.count)
		end
	end
end

--------------------------------------------------------------------------------
-- Difficulty Scaling
--------------------------------------------------------------------------------

local function updateDifficulty(): ()
	local elapsed = tick() - nightStartTime
	local tier = math.floor(elapsed / DIFFICULTY_INTERVAL)

	if tier > lastDifficultyTier then
		local tiers = tier - lastDifficultyTier
		difficultySpeed += SPEED_INCREASE * tiers
		difficultyRange += RANGE_INCREASE * tiers
		difficultyCooldownReduction += COOLDOWN_DECREASE * tiers
		lastDifficultyTier = tier

		-- Update all existing NGMI walk speeds
		for _, data in ngmiEntities do
			if data.state == "PATROL" then
				data.humanoid.WalkSpeed = getEffectiveSpeed()
			elseif data.state == "CHASE" then
				data.humanoid.WalkSpeed = getEffectiveSpeed() * CHASE_SPEED_MULT
			end
		end

		print(("[NGMIController] Difficulty increased! Tier %d — Speed: +%d, Range: +%d, Cooldown: -%.1f"):format(
			tier, difficultySpeed, difficultyRange, difficultyCooldownReduction
		))
	end
end

--------------------------------------------------------------------------------
-- Cleanup
--------------------------------------------------------------------------------

--[[ Destroy all NGMI models and reset state. ]]
local function cleanupAllNGMIs(): ()
	for model, _ in ngmiEntities do
		if model.Parent then
			model:Destroy()
		end
	end
	ngmiEntities = {}
	wavesSpawned = {}
	difficultySpeed = 0
	difficultyRange = 0
	difficultyCooldownReduction = 0
	lastDifficultyTier = 0
	print("[NGMIController] All NGMIs destroyed — Night 2 ended")
end

--------------------------------------------------------------------------------
-- Night 2 Lifecycle
--------------------------------------------------------------------------------

local function startNight2(): ()
	if isNight2Active then
		return
	end
	isNight2Active = true
	nightStartTime = tick()
	print("[NGMIController] ═══ NIGHT 2 ACTIVATED ═══")

	-- Main heartbeat loop: update all NGMI AI + check wave spawns
	heartbeatConn = RunService.Heartbeat:Connect(function(dt: number)
		if not isNight2Active then
			return
		end

		-- Check for wave spawns
		checkWaveSpawns()

		-- Update difficulty scaling
		updateDifficulty()

		-- Update each NGMI's state machine
		for _, data in ngmiEntities do
			updateNGMI(data, dt)
		end
	end)
end

local function stopNight2(): ()
	if not isNight2Active then
		return
	end
	isNight2Active = false

	if heartbeatConn then
		heartbeatConn:Disconnect()
		heartbeatConn = nil
	end

	cleanupAllNGMIs()
end

--------------------------------------------------------------------------------
-- Remote Event Handlers
--------------------------------------------------------------------------------

-- Listen for phase changes from the GameStateManager via the server phase bus
-- (ServerStorage.ServerComm.PhaseChanged). RemoteEvent.OnServerEvent cannot be
-- used here because the authority is the server, not a client.
do
	local serverComm = ServerStorage:WaitForChild("ServerComm")
	local phaseBus = serverComm:WaitForChild("PhaseChanged") :: BindableEvent
	phaseBus.Event:Connect(function(phase: number)
		if phase == PHASE_NIGHT2 then
			startNight2()
		elseif phase ~= PHASE_NIGHT2 and isNight2Active then
			stopNight2()
		end
	end)
end

-- InventoryManager fires WeaponUsed after it has spent the spray's ammo.
do
	local serverComm = ServerStorage:FindFirstChild("ServerComm")
	if not serverComm then
		serverComm = Instance.new("Folder")
		serverComm.Name = "ServerComm"
		serverComm.Parent = ServerStorage
	end
	local bus = serverComm:FindFirstChild("WeaponUsed")
	if not (bus and bus:IsA("BindableEvent")) then
		bus = Instance.new("BindableEvent")
		bus.Name = "WeaponUsed"
		bus.Parent = serverComm
	end
	;(bus :: BindableEvent).Event:Connect(function(player: Player, _itemId: string, kind: string)
		local reach = WEAPON_REACH[kind]
		if reach and typeof(player) == "Instance" and player:IsA("Player") then
			confirmedSprays[player] = { at = os.clock(), reach = reach }
		end
	end)
end

-- Deodorant stun: the user's client reports which NGMI its spray or melee swing
-- hit. The client only picks the target; the hit counts only against a use the
-- server confirmed, once per use, and only within that weapon's reach.
DeodorantSpray.OnServerEvent:Connect(function(player: Player, targetModel: Instance?)
	if not isNight2Active then
		return
	end
	local use = confirmedSprays[player]
	if not use or os.clock() - use.at > SPRAY_CLAIM_WINDOW then
		return
	end
	if typeof(targetModel) ~= "Instance" or not targetModel:IsA("Model") then
		return
	end

	local data = ngmiEntities[targetModel :: Model]
	if not data then
		return
	end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) or (root.Position - data.rootPart.Position).Magnitude > use.reach then
		return
	end
	confirmedSprays[player] = nil

	-- Each spray deals 1/8 of the NGMI's health and sends it fleeing.
	data.health -= 1

	-- Broadcast spray VFX/recoil to all clients
	NGMIStunned:FireAllClients(targetModel, player)

	if data.health <= 0 then
		-- Driven off for good — poof and despawn.
		local model = targetModel :: Model
		local pos = data.rootPart.Position
		ngmiEntities[model] = nil
		local poof = Instance.new("Explosion")
		poof.Position = pos
		poof.BlastRadius = 0
		poof.BlastPressure = 0
		poof.Parent = workspace
		for _, p in model:GetDescendants() do
			if p:IsA("BasePart") then
				p.CanCollide = false
			end
		end
		model:Destroy()
		print(("[NGMIController] NGMI driven off by %s"):format(player.Name))
		return
	end

	-- Recoil and flee from the sprayer.
	if data.state ~= "RETREAT" then
		transitionTo(data, "RETREAT", nil)
	else
		data.stateTimer = 0 -- another hit while fleeing → recompute the escape route
	end
	showOverheadText(data, STUN_TEXT, 1.5)

	print(("[NGMIController] NGMI sprayed by %s (%d/%d left)"):format(player.Name, data.health, data.maxHealth))
end)

Players.PlayerRemoving:Connect(function(player: Player)
	confirmedSprays[player] = nil
end)

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------
print("[NGMIController] Loaded — waiting for NIGHT2 phase")
