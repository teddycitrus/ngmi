--!strict
--[[
	GameConfig.luau
	===============
	Shared constants for "Not Gonna Make It"

	Every tunable number in the game lives here. Server and client both
	require this module so balance changes only need to happen in one place.
	All tables are deep-frozen to prevent accidental mutation at runtime.
]]

export type PhaseId = number

----------------------------------------------------------------------
-- Phase Enum
----------------------------------------------------------------------
-- Represents the five distinct stages of a match:
--   LOBBY  → waiting room / queue screen
--   DAY1   → 3rd-person exploration, meet NPCs, learn the venue
--   DAY2   → coding & scavenging; corruption begins halfway through
--   NIGHT2 → 1st-person survival horror against NGMI entities
--   DAY3   → ending cutscene determined by player performance
----------------------------------------------------------------------
local Phase: { [string]: PhaseId } = {
	LOBBY  = 0,
	DAY1   = 1,
	DAY2   = 2,
	NIGHT2 = 3,
	DAY3   = 4,
}

----------------------------------------------------------------------
-- Phase Ordering (for state-machine transitions)
----------------------------------------------------------------------
local PHASE_ORDER: { PhaseId } = { Phase.LOBBY, Phase.DAY1, Phase.DAY2, Phase.NIGHT2, Phase.DAY3 }

----------------------------------------------------------------------
-- Phase Timing (real-world seconds each phase lasts)
----------------------------------------------------------------------
-- DAY3 is 0 because it's a non-interactive cutscene whose length is
-- driven by the cinematic system, not a countdown timer.
----------------------------------------------------------------------
local PhaseDuration: { [PhaseId]: number } = {
	[Phase.DAY1]   = 180,   -- 3 minutes
	[Phase.DAY2]   = 600,   -- 10 minutes
	[Phase.NIGHT2] = 900,   -- 15 minutes
	[Phase.DAY3]   = 0,     -- cutscene (no timer)
}

----------------------------------------------------------------------
-- In-Game Clock Ranges (hours, 0-24)
----------------------------------------------------------------------
-- The Lighting ClockTime is linearly interpolated between Start and
-- End over the duration of each phase so time "feels" like it passes.
----------------------------------------------------------------------
export type TimeRange = {
	Start: number,
	End: number,
}

local PhaseTimeRanges: { [PhaseId]: TimeRange } = {
	[Phase.DAY1]   = { Start = 18, End = 21 },  -- late afternoon → dusk
	[Phase.DAY2]   = { Start = 9,  End = 24 },  -- morning → midnight
	[Phase.NIGHT2] = { Start = 0,  End = 8 },   -- midnight → dawn
	[Phase.DAY3]   = { Start = 8,  End = 16 },  -- morning → afternoon
}

----------------------------------------------------------------------
-- Day 2 Corruption
----------------------------------------------------------------------
-- At this many seconds into Day 2 the venue starts warping. Lights
-- flicker, NPCs begin mutating, and the vibe gets *real* bad.
----------------------------------------------------------------------
local DAY2_CORRUPTION_START: number = 300  -- 5 minutes (halfway through Day 2)

----------------------------------------------------------------------
-- Player Configuration
----------------------------------------------------------------------
export type PlayerConfig = {
	walkSpeed: number,
	sprintSpeed: number,
	maxHealth: number,
	inventorySlots: number,
}

local Player: PlayerConfig = {
	walkSpeed      = 11,   -- ~30% slower than the old 16 for a heavier, tenser pace
	sprintSpeed    = 24,
	maxHealth      = 100,
	inventorySlots = 4,
}

----------------------------------------------------------------------
-- NGMI Entity Configuration
----------------------------------------------------------------------
-- NGMIs are mutated hackathon attendees. They shamble toward players,
-- deal contact damage, and can be stunned with deodorant spray.
----------------------------------------------------------------------
export type NGMIConfig = {
	baseDamage: number,
	stunDuration: number,
	baseSpeed: number,
	detectionRange: number,
	attackRange: number,
}

local NGMI: NGMIConfig = {
	baseDamage     = 25,    -- HP per hit
	stunDuration   = 3,     -- seconds incapacitated after deodorant
	baseSpeed      = 20,    -- studs/sec pursuit speed
	detectionRange = 40,    -- studs – radius of awareness
	attackRange    = 5,     -- studs – melee swipe distance
}

----------------------------------------------------------------------
-- Match Queue Sizes
----------------------------------------------------------------------
-- Supported party sizes for matchmaking. Solo is valid; duos or full
-- squads of 4 are also supported. No trios — odd numbers are cursed.
----------------------------------------------------------------------
local QueueSizes: { number } = { 1, 2, 4 }

----------------------------------------------------------------------
-- Lobby Countdown
----------------------------------------------------------------------
local LOBBY_COUNTDOWN: number = 10  -- seconds after enough players queue

----------------------------------------------------------------------
-- True Ending Threshold
----------------------------------------------------------------------
-- Combined project completion percentage across all surviving players
-- required to unlock the "true" (good) ending cutscene.
----------------------------------------------------------------------
local COMPLETION_THRESHOLD: number = 100

----------------------------------------------------------------------
-- Respawn
----------------------------------------------------------------------
local RESPAWN_DELAY: number = 3  -- seconds before player respawns

----------------------------------------------------------------------
-- Coding
----------------------------------------------------------------------
local CODING_SPEED_BASE: number = 1  -- completion % per second at desk

----------------------------------------------------------------------
-- Deodorant Spray Configuration
----------------------------------------------------------------------
-- The default ranged "weapon". Sprays a cone of aerosol that stuns
-- NGMI entities on contact. Ammo depletes continuously while firing.
----------------------------------------------------------------------
export type DeodorantConfig = {
	maxAmmo: number,
	sprayRate: number,
	stunCost: number,
	range: number,
}

local Deodorant: DeodorantConfig = {
	maxAmmo   = 100,    -- full can capacity
	sprayRate = 10,     -- ammo consumed per second while spraying
	stunCost  = 30,     -- ammo consumed per successful stun
	range     = 15,     -- studs – effective spray distance
}

----------------------------------------------------------------------
-- Energy Bar Configuration
----------------------------------------------------------------------
-- Consumable item that gives a temporary speed multiplier.
-- Stacks up to 3 in one inventory slot.
----------------------------------------------------------------------
export type EnergyBarConfig = {
	speedBoost: number,
	duration: number,
}

local EnergyBar: EnergyBarConfig = {
	speedBoost = 1.3,   -- multiplier applied to current move speed
	duration   = 10,    -- seconds the boost lasts
}

----------------------------------------------------------------------
-- Sabotage Configuration
----------------------------------------------------------------------
-- During Night 2, power panels are periodically sabotaged by NGMI
-- entities. Players must repair them to keep lights/systems running.
-- The interval is randomised between min and max to keep tension up.
----------------------------------------------------------------------
export type SabotageConfig = {
	intervalMin: number,
	intervalMax: number,
}

local Sabotage: SabotageConfig = {
	intervalMin = 180,   -- 3 minutes minimum between sabotage events
	intervalMax = 240,   -- 4 minutes maximum
}

----------------------------------------------------------------------
-- NGMI Spawning (Night 2)
----------------------------------------------------------------------
export type NGMISpawnConfig = {
	spawnInterval: number,
	maxCount: number,
}

local NGMISpawn: NGMISpawnConfig = {
	spawnInterval = 45,  -- seconds between NGMI waves in NIGHT2
	maxCount      = 8,   -- max simultaneous NGMIs on the map
}

----------------------------------------------------------------------
-- Map dimensions (studs) — used by MapBuilder
----------------------------------------------------------------------
local MAP = {
	MAIN_HALL       = { width = 200, depth = 150, wallHeight = 20, wallThickness = 2 },
	LOBBY_AREA      = { width = 60,  depth = 40,  wallHeight = 20, wallThickness = 2 },
	BATHROOM        = { width = 25,  depth = 20 },
	SERVER_CLOSET   = { width = 15,  depth = 12 },
	KITCHEN         = { width = 30,  depth = 20 },
	ELECTRICAL_ROOM = { width = 20,  depth = 15 },
	HALLWAY_WIDTH   = 10,
	DESK_SPACING    = 12,
	DESK_ROWS       = 5,
	DESKS_PER_ROW   = 4,
}

----------------------------------------------------------------------
-- Colors — corporate conference-centre palette
----------------------------------------------------------------------
local COLORS = {
	WALL           = Color3.fromRGB(220, 220, 225),
	WALL_TRIM      = Color3.fromRGB(180, 180, 185),
	FLOOR_WOOD     = Color3.fromRGB(139, 90, 43),
	FLOOR_TILE     = Color3.fromRGB(200, 200, 200),
	CEILING        = Color3.fromRGB(240, 240, 240),
	DESK           = Color3.fromRGB(160, 130, 100),
	CHAIR          = Color3.fromRGB(50, 50, 55),
	MONITOR        = Color3.fromRGB(30, 30, 30),
	SCREEN         = Color3.fromRGB(100, 180, 255),
	BANNER_RED     = Color3.fromRGB(200, 40, 40),
	BANNER_BLUE    = Color3.fromRGB(40, 80, 200),
	BANNER_GREEN   = Color3.fromRGB(40, 180, 80),
	PIPE           = Color3.fromRGB(120, 120, 125),
	EXIT_SIGN      = Color3.fromRGB(255, 30, 30),
	EMERGENCY      = Color3.fromRGB(255, 0, 0),
	ENERGY_DRINK_1 = Color3.fromRGB(0, 200, 80),
	ENERGY_DRINK_2 = Color3.fromRGB(0, 120, 255),
	ENERGY_DRINK_3 = Color3.fromRGB(255, 200, 0),
	SLEEPING_BAG_1 = Color3.fromRGB(50, 80, 160),
	SLEEPING_BAG_2 = Color3.fromRGB(160, 50, 50),
	SLEEPING_BAG_3 = Color3.fromRGB(50, 140, 50),
	GLASS          = Color3.fromRGB(200, 220, 240),
	PODIUM         = Color3.fromRGB(80, 50, 30),
	WHITEBOARD     = Color3.fromRGB(250, 250, 250),
	LOCKER         = Color3.fromRGB(100, 110, 120),
	SERVER_RACK    = Color3.fromRGB(40, 40, 45),
	TOILET         = Color3.fromRGB(240, 240, 245),
	COUNTER        = Color3.fromRGB(180, 180, 180),
	TILE_WALL      = Color3.fromRGB(225, 232, 236),
	TILE_FLOOR     = Color3.fromRGB(120, 132, 142),
	METAL_BRUSHED  = Color3.fromRGB(160, 165, 170),
	CORK           = Color3.fromRGB(150, 110, 66),
	WOOD_TRIM      = Color3.fromRGB(110, 80, 55),
	UNI_MAROON     = Color3.fromRGB(110, 28, 40),
	UNI_NAVY       = Color3.fromRGB(40, 50, 110),
	UNI_GOLD       = Color3.fromRGB(212, 175, 60),
}

----------------------------------------------------------------------
-- CollectionService Tags
----------------------------------------------------------------------
local TAGS = {
	PLAYER_DESK        = "PlayerDesk",
	NPC_SPAWN          = "NPCSpawn",
	NGMI_SPAWN         = "NGMISpawn",
	ITEM_SPAWN         = "ItemSpawn",
	HIDING_SPOT        = "HidingSpot",
	ELECTRICAL_PANEL   = "ElectricalPanel",
	CEILING_LIGHT      = "CeilingLight",
	EMERGENCY_LIGHT    = "EmergencyLight",
	QUEST_CHAIR        = "QuestChair",
	POOP_MONSTER_SPAWN = "PoopMonsterSpawn",
	DESK_SEAT          = "DeskSeat",   -- a desk chair an ambient typist NPC sits at
	LEAN_SPOT          = "LeanSpot",   -- a wall spot an ambient hacker leans against (has Face attr)
	COUCH_SEAT         = "CouchSeat",  -- a couch cushion an ambient hacker sleeps/lounges on
	SLEEP_SPOT         = "SleepSpot",  -- a floor spot for a sleeping bag + sleeping hacker (has Yaw attr)
	ELEVATOR_CAR       = "ElevatorCar",  -- a movable elevator car (Model, PrimaryPart = CarFloor)
	ELEVATOR_CALL      = "ElevatorCall", -- a call/destination button (has ElevatorId + TargetY attrs)
	ELEVATOR_DOOR      = "ElevatorDoor", -- a sliding shaft-door panel (ElevatorId/Level/Closed/Open attrs)
	SERVER_RACK        = "ServerRack",   -- a repairable server rack (NIGHT2, gated on floor power)
}

----------------------------------------------------------------------
-- Badges / Achievements
----------------------------------------------------------------------
-- Roblox badge IDs awarded for each ending + the secret boss kill. Create the
-- badges on the Creator Dashboard (Game ▸ Engagement ▸ Badges), then paste each
-- numeric ID here. An ID of 0 means "unconfigured" and is silently skipped, so
-- the game runs fine before the badges exist (see server/BadgeManager.luau).
local BADGES = {
	deathByPoop       = 0, -- "Flushed"   — killed by the Bathroom Monster
	deathByNGMI       = 0, -- "Caught"    — killed by an NGMI
	becameNGMI        = 0, -- "NGMI"      — survived the weekend but shipped nothing
	trueEnding        = 0, -- "Shipped It"— survived and shipped 100%
	killedPoopMonster = 0, -- "Plumber"   — defeated the Bathroom Monster
}

----------------------------------------------------------------------
-- Sabotage Types
----------------------------------------------------------------------
local SABOTAGE_TYPES: { string } = { "PowerOutage", "ServerCrash", "WiFiDrop" }

----------------------------------------------------------------------
-- Assemble & Freeze
----------------------------------------------------------------------
local GameConfig = {
	-- Phase system
	Phase                  = table.freeze(Phase),
	PHASE_ORDER            = table.freeze(PHASE_ORDER),
	PhaseDuration          = table.freeze(PhaseDuration),
	PhaseTimeRanges        = table.freeze(PhaseTimeRanges),

	-- Corruption
	DAY2_CORRUPTION_START  = DAY2_CORRUPTION_START,

	-- Player
	Player                 = table.freeze(Player),
	RESPAWN_DELAY          = RESPAWN_DELAY,
	CODING_SPEED_BASE      = CODING_SPEED_BASE,

	-- Enemies
	NGMI                   = table.freeze(NGMI),
	NGMISpawn              = table.freeze(NGMISpawn),

	-- Matchmaking
	QueueSizes             = table.freeze(QueueSizes),
	LOBBY_COUNTDOWN        = LOBBY_COUNTDOWN,

	-- Win condition
	COMPLETION_THRESHOLD   = COMPLETION_THRESHOLD,

	-- Badges / achievements
	BADGES                 = table.freeze(BADGES),

	-- Items / equipment
	Deodorant              = table.freeze(Deodorant),
	EnergyBar              = table.freeze(EnergyBar),

	-- Events
	Sabotage               = table.freeze(Sabotage),
	SABOTAGE_TYPES         = table.freeze(SABOTAGE_TYPES),

	-- World
	MAP                    = table.freeze(MAP),
	COLORS                 = table.freeze(COLORS),
	TAGS                   = table.freeze(TAGS),
}

return table.freeze(GameConfig)
