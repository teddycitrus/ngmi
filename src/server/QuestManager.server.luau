--!strict
--[[
    QuestManager.server.luau
    Server-side quest tracking for side quests:
    1. The Chair Hoarder - collect 4 folding chairs scattered on the ground floor
    2. The Poop Monster - boss fight in the boss restroom (Boss/PoopMonster)

    Both are team quests: one shared progress for everyone in the match, every
    chair or kill counts for the whole team, and on completion every teammate
    sees it ticked and gets the reward.
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local BadgeManager = require(script.Parent:WaitForChild("BadgeManager"))
local ServerComm = require(script.Parent:WaitForChild("ServerComm"))
local PoopMonster = require(script.Parent:WaitForChild("Boss"):WaitForChild("PoopMonster"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local QuestUpdate = Remotes:WaitForChild("QuestUpdate") :: RemoteEvent
local QuestComplete = Remotes:WaitForChild("QuestComplete") :: RemoteEvent

-- Server bus (handled by InventoryManager) to drop reward items into inventory.
local grantItemBus = ServerComm.bus("GrantItem")
-- Server bus: the boss is dead (InventoryManager removes every plunger,
-- ProgressionManager ticks the bonus objective).
local poopDefeatedBus = ServerComm.bus("PoopMonsterDefeated")

-- ============================================================
-- TYPES
-- ============================================================
type QuestState = {
    id: string,
    name: string,
    description: string,
    progress: number,
    target: number,
    completed: boolean,
    active: boolean,
}

type TeamQuests = {
    chairHoarder: QuestState,
    bathroomMonster: QuestState,
}

-- ============================================================
-- STATE
-- ============================================================
local team: TeamQuests
local boss: PoopMonster.Boss? = nil
local bossDefeated = false -- once killed it stays dead for the match (no respawn)
local spawnToken = 0 -- bumped on every phase change so stale spawn timers stand down

local BOSS_SPAWN_DELAY = 5 -- seconds into Day 2
local BEACON_DELAY = 55 -- seconds after it spawns, light the way to it

-- ============================================================
-- QUEST INITIALIZATION
-- ============================================================
local function createTeamQuests(): TeamQuests
    return {
        chairHoarder = {
            id = "chair_hoarder",
            name = "The Chair Hoarder",
            description = "Grab 4 folding chairs stashed around the ground floor before the other teams do.",
            progress = 0,
            target = 4,
            completed = false,
            active = false,
        },
        bathroomMonster = {
            id = "bathroom_monster",
            name = "The Poop Monster",
            description = "Something huge is backing up the restroom drains. Spray it to stagger it, then plunge its core.",
            progress = 0,
            target = 1,
            completed = false,
            active = false,
        },
    }
end

team = createTeamQuests()

-- ============================================================
-- QUEST LOGIC
-- ============================================================
local function sendQuestState(player: Player, quest: QuestState)
    QuestUpdate:FireClient(player, {
        id = quest.id,
        -- ObjectivesUI row label (QuestUI reads name/description instead)
        text = if quest.id == "chair_hoarder"
            then string.format("Bonus: hoard folding chairs (%d/%d)", quest.progress, quest.target)
            else nil,
        name = quest.name,
        description = quest.description,
        progress = quest.progress,
        target = quest.target,
        completed = quest.completed,
        active = quest.active,
    })
end

local function broadcastQuestState(quest: QuestState)
    for _, p in Players:GetPlayers() do
        sendQuestState(p, quest)
    end
end

-- Chair Hoarder: picking up quest chairs (anyone's pickup counts for the team)
local function onChairPickup(_player: Player)
    local quest = team.chairHoarder
    if quest.completed then return end

    quest.active = true
    quest.progress = math.min(quest.progress + 1, quest.target)

    if quest.progress >= quest.target then
        quest.completed = true
        -- Reward: 2 Energy Bars for every teammate
        for _, p in Players:GetPlayers() do
            grantItemBus:Fire(p, "energy_bar", 2)
            QuestComplete:FireClient(p, {
                questId = quest.id,
                rewards = {
                    { itemId = "energy_bar", count = 2 },
                },
            })
        end
    end
    broadcastQuestState(quest)
end

-- ============================================================
-- THE POOP MONSTER
-- ============================================================
local function onBossDefeated(player: Player)
    bossDefeated = true
    boss = nil
    poopDefeatedBus:Fire()

    print("[QuestManager] Poop Monster defeated by", player.Name)
    local quest = team.bathroomMonster
    quest.active = true
    quest.progress = 1
    quest.completed = true
    broadcastQuestState(quest)

    -- The whole team beat it: everyone gets the badge and a small random
    -- combo (1-2 items) of batteries / energy bars in their inventory.
    local pool = { "battery", "energy_bar" }
    for _, p in Players:GetPlayers() do
        BadgeManager.award(p, GameConfig.BADGES.killedPoopMonster)
        local tally: { [string]: number } = {}
        for _ = 1, math.random(1, 2) do
            local itemId = pool[math.random(#pool)]
            tally[itemId] = (tally[itemId] or 0) + 1
            grantItemBus:Fire(p, itemId, 1)
        end
        local rewardsList = {}
        for itemId, c in tally do
            table.insert(rewardsList, { itemId = itemId, count = c })
        end
        QuestComplete:FireClient(p, {
            questId = "bathroom_monster",
            rewards = rewardsList,
        })
    end
end

local function spawnBoss()
    if boss or bossDefeated then return end
    -- MapBuilder tags the boss restroom's marker with POOP_MONSTER_SPAWN.
    local marker: BasePart? = nil
    for _, sp in CollectionService:GetTagged(GameConfig.TAGS.POOP_MONSTER_SPAWN) do
        if sp:IsA("BasePart") then
            marker = sp
            break
        end
    end
    if not marker then
        warn("[QuestManager] No PoopMonsterSpawn marker; the boss can't spawn")
        return
    end
    local spawned = PoopMonster.spawn(marker, { onDefeated = onBossDefeated })
    boss = spawned
    task.delay(BEACON_DELAY, function()
        if boss == spawned then
            spawned:setBeacon()
        end
    end)
end

local function despawnBoss()
    if boss then
        boss:despawn()
        boss = nil
    end
end

-- Weapon uses arrive from InventoryManager after its own ammo and cooldown
-- checks; the boss does the range, facing and weak-point maths.
ServerComm.bus("WeaponUsed").Event:Connect(function(player: Player, itemId: string, kind: string)
    if boss and typeof(player) == "Instance" and typeof(itemId) == "string" and typeof(kind) == "string" then
        boss:onWeapon(player, itemId, kind)
    end
end)

-- ============================================================
-- EVENT LISTENERS
-- ============================================================
-- A player joining mid-match (rejoin, late teleport) sees the team's progress.
Players.PlayerAdded:Connect(function(player: Player)
    task.delay(3, function()
        if player.Parent and team.chairHoarder.active then
            sendQuestState(player, team.chairHoarder)
        end
        if player.Parent and team.bathroomMonster.completed then
            sendQuestState(player, team.bathroomMonster)
        end
    end)
end)

-- Chair pickups arrive from InteractionManager's prompt handler, never from a
-- client remote, so the reward can't be farmed by firing the remote.
ServerComm.bus("QuestItemCollected").Event:Connect(function(player: Player, questId: string)
    if typeof(player) == "Instance" and questId == "chair_hoarder" then
        onChairPickup(player)
    end
end)

-- The boss lives for Day 2 only: it rises a few seconds in and sinks away
-- when the phase moves on. A defeat sticks until the next match.
local function onPhase(phase: number)
    spawnToken += 1
    local my = spawnToken
    if phase == GameConfig.Phase.DAY2 then
        task.delay(BOSS_SPAWN_DELAY, function()
            if spawnToken == my then
                spawnBoss()
            end
        end)
    else
        despawnBoss()
    end
    if phase == GameConfig.Phase.LOBBY or phase == GameConfig.Phase.DAY1 then
        bossDefeated = false -- new match incoming
        team.bathroomMonster = createTeamQuests().bathroomMonster
    end
    -- New match: the chairs go back out (InteractionManager), so the hunt
    -- starts over.
    if phase == GameConfig.Phase.DAY1 then
        team.chairHoarder = createTeamQuests().chairHoarder
        broadcastQuestState(team.chairHoarder)
    end
end

ServerComm.bus("PhaseChanged").Event:Connect(onPhase)
do
    local phaseValue = ReplicatedStorage:FindFirstChild("CurrentPhase")
    if phaseValue and phaseValue:IsA("IntValue") and phaseValue.Value == GameConfig.Phase.DAY2 then
        onPhase(phaseValue.Value)
    end
end

print("[QuestManager] Initialized - Chair Hoarder + Poop Monster ready")
