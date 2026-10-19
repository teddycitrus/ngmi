--!strict
--[[
    QuestManager.server.luau
    Server-side quest tracking for side quests:
    1. The Chair Hoarder - collect 4 folding chairs scattered on the ground floor
    2. Bathroom Poop Monster - boss fight in the bathroom
]]

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local BadgeManager = require(script.Parent:WaitForChild("BadgeManager"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local QuestUpdate = Remotes:WaitForChild("QuestUpdate") :: RemoteEvent
local QuestComplete = Remotes:WaitForChild("QuestComplete") :: RemoteEvent
local PlayerDamaged = Remotes:WaitForChild("PlayerDamaged") :: RemoteEvent

-- Server bus (handled by InventoryManager) to drop reward items into inventory.
local grantItemBus: BindableEvent
do
    local sc = ServerStorage:FindFirstChild("ServerComm")
    if not sc then
        sc = Instance.new("Folder")
        sc.Name = "ServerComm"
        sc.Parent = ServerStorage
    end
    local b = sc:FindFirstChild("GrantItem")
    if b and b:IsA("BindableEvent") then
        grantItemBus = b
    else
        grantItemBus = Instance.new("BindableEvent")
        grantItemBus.Name = "GrantItem"
        grantItemBus.Parent = sc
    end
end

-- Server bus: tell InventoryManager the boss is dead so every plunger is removed.
local poopDefeatedBus: BindableEvent
do
    local sc = ServerStorage:FindFirstChild("ServerComm")
    if not sc then
        sc = Instance.new("Folder")
        sc.Name = "ServerComm"
        sc.Parent = ServerStorage
    end
    local b = sc:FindFirstChild("PoopMonsterDefeated")
    if b and b:IsA("BindableEvent") then
        poopDefeatedBus = b
    else
        poopDefeatedBus = Instance.new("BindableEvent")
        poopDefeatedBus.Name = "PoopMonsterDefeated"
        poopDefeatedBus.Parent = sc
    end
end

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

type PlayerQuests = {
    chairHoarder: QuestState,
    bathroomMonster: QuestState,
}

-- ============================================================
-- STATE
-- ============================================================
local playerQuests: { [Player]: PlayerQuests } = {}
local currentPhase = 0
local bathroomMonsterAlive = true
local bossDefeated = false -- once killed it stays dead for the match (no respawn)
local MONSTER_MAX_HEALTH = 100
local bathroomMonsterHealth = MONSTER_MAX_HEALTH
local bathroomMonsterModel: Model? = nil
-- The monster never leaves its restroom — it stays within MONSTER_LEASH studs of
-- its spawn (the stall). It only emerges to chase a player who steps inside.
local MONSTER_LEASH = 17
local bathroomMonsterHome: Vector3? = nil
-- Deodorant staggers the boss; the plunger only bites while it's staggered.
local monsterStaggerUntil = 0

-- ============================================================
-- QUEST INITIALIZATION
-- ============================================================
local function createPlayerQuests(): PlayerQuests
    return {
        chairHoarder = {
            id = "chair_hoarder",
            name = "The Chair Hoarder",
            description = "Grab 4 folding chairs stashed around the ground floor before anyone else does.",
            progress = 0,
            target = 4,
            completed = false,
            active = false,
        },
        bathroomMonster = {
            id = "bathroom_monster",
            name = "The Poop Monster",
            description = "A terrifying creature lurks in the bathroom. Defeat it... if you dare.",
            progress = 0,
            target = 1,
            completed = false,
            active = false,
        },
    }
end

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

-- Chair Hoarder: picking up quest chairs
local function onChairPickup(player: Player)
    local quests = playerQuests[player]
    if not quests then return end

    local quest = quests.chairHoarder
    if quest.completed then return end

    -- Activate quest on first chair
    if not quest.active then
        quest.active = true
    end

    quest.progress = math.min(quest.progress + 1, quest.target)
    sendQuestState(player, quest)

    if quest.progress >= quest.target then
        -- Quest complete!
        quest.completed = true
        sendQuestState(player, quest)

        -- Reward: 2 Energy Bars
        grantItemBus:Fire(player, "energy_bar", 2)
        QuestComplete:FireClient(player, {
            questId = quest.id,
            rewards = {
                { itemId = "energy_bar", count = 2 },
            },
        })
    end
end

-- Bathroom Monster Boss Fight
-- A minute into Day 2 we light up a beacon so players can actually find the boss:
-- a tall glowing pillar over its restroom plus a see-through-walls outline on the
-- monster itself. Both are parented to the monster, so they vanish when it dies.
local function addMonsterBeacon()
    local monster = bathroomMonsterModel
    if not (monster and monster.Parent and bathroomMonsterAlive) then return end
    if monster:FindFirstChild("BossBeacon") then return end -- already lit
    local torso = monster:FindFirstChild("Torso") :: BasePart?
    local home = bathroomMonsterHome or (torso and torso.Position)
    if not home then return end

    -- See-through-walls glow on the boss. Adornee the TORSO (his body) rather than
    -- the whole model — adorning the model would also light up the tall BossBeacon
    -- pillar we add below, making the entire light-shaft glow.
    if torso then
        local hl = Instance.new("Highlight")
        hl.Name = "BeaconHighlight"
        hl.FillColor = Color3.fromRGB(120, 80, 30)
        hl.FillTransparency = 0.5
        hl.OutlineColor = Color3.fromRGB(255, 210, 90)
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Adornee = torso
        hl.Parent = torso
    end

    -- Tall light pillar over the restroom, visible from across the venue.
    local beam = Instance.new("Part")
    beam.Name = "BossBeacon"
    beam.Anchored = true
    beam.CanCollide = false
    beam.CastShadow = false
    beam.Size = Vector3.new(3, 70, 3)
    beam.Position = Vector3.new(home.X, home.Y + 34, home.Z)
    beam.Color = Color3.fromRGB(255, 190, 70)
    beam.Material = Enum.Material.Neon
    beam.Transparency = 0.55
    beam.Parent = monster
    local pl = Instance.new("PointLight")
    pl.Color = Color3.fromRGB(255, 190, 70)
    pl.Range = 20
    pl.Brightness = 2
    pl.Parent = beam
end

local function createBathroomMonster()
    if bathroomMonsterModel then return end

    -- Find bathroom spawn point (MapBuilder tags the boss restroom marker with
    -- POOP_MONSTER_SPAWN). The old code looked for an NPCSpawn named
    -- "BathroomMonsterSpawn" that the map never creates, so the boss never spawned.
    local spawnPoints = CollectionService:GetTagged(GameConfig.TAGS.POOP_MONSTER_SPAWN)
    local bathroomSpawn: BasePart? = nil
    for _, sp in spawnPoints do
        if sp:IsA("BasePart") then
            bathroomSpawn = sp
            break
        end
    end

    if not bathroomSpawn then
        return
    end

    bathroomMonsterAlive = true
    bathroomMonsterHealth = MONSTER_MAX_HEALTH
    bathroomMonsterHome = bathroomSpawn.Position
    monsterStaggerUntil = 0

    -- Create boss model
    local monster = Instance.new("Model")
    monster.Name = "PoopMonster"

    -- Body (brown, blob-like)
    local torso = Instance.new("Part")
    torso.Name = "Torso"
    torso.Size = Vector3.new(5, 6, 5)
    torso.Color = Color3.fromRGB(101, 67, 33)
    torso.Material = Enum.Material.SmoothPlastic
    torso.Shape = Enum.PartType.Ball
    torso.Anchored = false
    torso.Parent = monster

    -- Head (smaller brown sphere)
    local head = Instance.new("Part")
    head.Name = "Head"
    head.Size = Vector3.new(3, 3, 3)
    head.Color = Color3.fromRGB(80, 50, 25)
    head.Material = Enum.Material.SmoothPlastic
    head.Shape = Enum.PartType.Ball
    head.Parent = monster

    local headWeld = Instance.new("Weld")
    headWeld.Part0 = torso
    headWeld.Part1 = head
    headWeld.C0 = CFrame.new(0, 4, 0)
    headWeld.Parent = head

    -- Eyes (angry red)
    for _, offset in { Vector3.new(-0.8, 0.5, -1.2), Vector3.new(0.8, 0.5, -1.2) } do
        local eye = Instance.new("Part")
        eye.Name = "Eye"
        eye.Size = Vector3.new(0.8, 0.8, 0.8)
        eye.Color = Color3.fromRGB(255, 0, 0)
        eye.Material = Enum.Material.Neon
        eye.Shape = Enum.PartType.Ball
        eye.Parent = monster

        local eyeWeld = Instance.new("Weld")
        eyeWeld.Part0 = head
        eyeWeld.Part1 = eye
        eyeWeld.C0 = CFrame.new(offset)
        eyeWeld.Parent = eye
    end

    -- Humanoid for health tracking
    local humanoid = Instance.new("Humanoid")
    humanoid.MaxHealth = MONSTER_MAX_HEALTH
    humanoid.Health = MONSTER_MAX_HEALTH
    humanoid.WalkSpeed = 13
    humanoid.Parent = monster

    -- Stink particles
    local stinkEmitter = Instance.new("ParticleEmitter")
    stinkEmitter.Color = ColorSequence.new(Color3.fromRGB(100, 120, 0))
    stinkEmitter.Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.5),
        NumberSequenceKeypoint.new(1, 2),
    })
    stinkEmitter.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.3),
        NumberSequenceKeypoint.new(1, 1),
    })
    stinkEmitter.Lifetime = NumberRange.new(1, 3)
    stinkEmitter.Rate = 20
    stinkEmitter.Speed = NumberRange.new(1, 3)
    stinkEmitter.SpreadAngle = Vector2.new(180, 180)
    stinkEmitter.Parent = torso

    -- Billboard name
    local billboard = Instance.new("BillboardGui")
    billboard.Size = UDim2.new(8, 0, 2, 0)
    billboard.StudsOffset = Vector3.new(0, 5, 0)
    billboard.Adornee = head
    billboard.Parent = head

    local nameLabel = Instance.new("TextLabel")
    nameLabel.Size = UDim2.new(1, 0, 0.5, 0)
    nameLabel.BackgroundTransparency = 1
    nameLabel.Text = "💩 THE POOP MONSTER"
    nameLabel.TextSize = 22
    nameLabel.Font = Enum.Font.GothamBold
    nameLabel.TextColor3 = Color3.fromRGB(255, 100, 50)
    nameLabel.TextStrokeTransparency = 0.3
    nameLabel.Parent = billboard

    -- Health bar
    local healthBG = Instance.new("Frame")
    healthBG.Name = "HealthBG"
    healthBG.Size = UDim2.new(0.8, 0, 0.15, 0)
    healthBG.Position = UDim2.new(0.1, 0, 0.55, 0)
    healthBG.BackgroundColor3 = Color3.fromRGB(40, 0, 0)
    healthBG.BorderSizePixel = 0
    healthBG.Parent = billboard

    local healthFill = Instance.new("Frame")
    healthFill.Name = "HealthFill"
    healthFill.Size = UDim2.new(1, 0, 1, 0)
    healthFill.BackgroundColor3 = Color3.fromRGB(255, 50, 50)
    healthFill.BorderSizePixel = 0
    healthFill.Parent = healthBG

    monster.PrimaryPart = torso
    monster:PivotTo(bathroomSpawn.CFrame + Vector3.new(0, 3, 0))
    monster.Parent = workspace

    bathroomMonsterModel = monster
    CollectionService:AddTag(monster, "BathroomMonster")

    -- ── Chase AI (confined to the restroom) ──────────────────────────────
    -- The monster sits in its stall until a player steps into the bathroom,
    -- then lunges out and chases them — but it is leashed to MONSTER_LEASH
    -- studs of its spawn, so it can NEVER follow you out the door.
    local home = bathroomSpawn.Position
    local homeFloorY = home.Y

    --- Find the closest player currently inside the bathroom (within leash of
    --- home and on roughly the same floor), or nil.
    local function findIntruder(): (Player?, Vector3?)
        local best: Player? = nil
        local bestPos: Vector3? = nil
        local bestDist = math.huge
        for _, p in Players:GetPlayers() do
            local character = p.Character
            local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
            local hum = character and character:FindFirstChildOfClass("Humanoid")
            if root and hum and hum.Health > 0 then
                local flat = (root.Position - home) * Vector3.new(1, 0, 1)
                local dist = flat.Magnitude
                if dist <= MONSTER_LEASH and math.abs(root.Position.Y - homeFloorY) <= 10 then
                    if dist < bestDist then
                        bestDist = dist
                        best = p
                        bestPos = root.Position
                    end
                end
            end
        end
        return best, bestPos
    end

    --- Clamp a target position so the monster stays within its leash radius.
    local function clampToLeash(pos: Vector3): Vector3
        local flat = (pos - home) * Vector3.new(1, 0, 1)
        if flat.Magnitude > MONSTER_LEASH then
            flat = flat.Unit * MONSTER_LEASH
        end
        return home + flat + Vector3.new(0, pos.Y - home.Y, 0)
    end

    local attackCooldown = 0
    task.spawn(function()
        while bathroomMonsterAlive and monster.Parent do
            local dt = RunService.Heartbeat:Wait()
            if not bathroomMonsterAlive then break end
            attackCooldown = math.max(0, attackCooldown - dt)

            -- Hard containment: if physics ever nudges it past the leash, drag
            -- it back so it physically cannot escape the restroom.
            local flat = (torso.Position - home) * Vector3.new(1, 0, 1)
            if flat.Magnitude > MONSTER_LEASH + 2 then
                local pulled = home + flat.Unit * MONSTER_LEASH + Vector3.new(0, torso.Position.Y - home.Y, 0)
                monster:PivotTo(CFrame.new(pulled))
            end

            -- Staggered by deodorant → freeze in place, reeling.
            if os.clock() < monsterStaggerUntil then
                humanoid.WalkSpeed = 0
                humanoid:MoveTo(torso.Position)
                continue
            end
            humanoid.WalkSpeed = 13

            local intruder, intruderPos = findIntruder()
            if intruder and intruderPos then
                -- Emerge from the stall and chase, but never past the leash.
                humanoid:MoveTo(clampToLeash(intruderPos))
                local dist = (intruderPos - torso.Position).Magnitude
                if dist < 6 and attackCooldown <= 0 then
                    attackCooldown = 1.5
                    PlayerDamaged:FireClient(intruder, { damage = 15, source = "BathroomMonster" })
                    -- Real damage so it registers on the default health bar + the
                    -- on-screen damage effects (and can actually down the player).
                    local ic = intruder.Character
                    local ih = ic and ic:FindFirstChildOfClass("Humanoid")
                    if ih then
                        -- Tag the cause so the death screen knows it was the monster.
                        intruder:SetAttribute("DeathCause", "poop")
                        ih:TakeDamage(15)
                        if ih.Health <= 0 then
                            BadgeManager.award(intruder, GameConfig.BADGES.deathByPoop)
                        end
                    end
                end
            else
                -- No one in the bathroom — slink back to the stall.
                if (torso.Position - home).Magnitude > 3 then
                    humanoid:MoveTo(home)
                end
            end
        end
    end)

    -- The boss spawns ~5s into Day 2; light the beacon about a minute in.
    task.delay(55, addMonsterBeacon)
end

local function damageBathroomMonster(player: Player, damage: number)
    if not bathroomMonsterAlive then return end

    bathroomMonsterHealth -= damage

    -- Update health bar
    if bathroomMonsterModel then
        local head = bathroomMonsterModel:FindFirstChild("Head")
        if head then
            local billboard = head:FindFirstChildOfClass("BillboardGui")
            if billboard then
                local healthBG = billboard:FindFirstChild("HealthBG") :: Frame?
                if healthBG then
                    local healthFill = healthBG:FindFirstChild("HealthFill") :: Frame?
                    if healthFill then
                        healthFill.Size = UDim2.new(math.max(0, bathroomMonsterHealth / MONSTER_MAX_HEALTH), 0, 1, 0)
                    end
                end
            end
        end
    end

    if bathroomMonsterHealth <= 0 then
        -- Boss defeated!
        bathroomMonsterAlive = false
        bossDefeated = true -- don't let the spawn loop bring it back

        -- Every plunger vanishes now that the boss is dead.
        poopDefeatedBus:Fire()

        -- Destroy model with explosion
        if bathroomMonsterModel then
            local torso = bathroomMonsterModel:FindFirstChild("Torso") :: BasePart?
            if torso then
                local explosion = Instance.new("Explosion")
                explosion.Position = torso.Position
                explosion.BlastRadius = 0 -- visual only
                explosion.BlastPressure = 0
                explosion.Parent = workspace
            end

            task.delay(0.5, function()
                if bathroomMonsterModel then
                    bathroomMonsterModel:Destroy()
                    bathroomMonsterModel = nil
                end
            end)
        end

        -- Achievement: the player who landed the killing blow defeated the boss.
        BadgeManager.award(player, GameConfig.BADGES.killedPoopMonster)

        -- Complete quest for the player who got the killing blow
        local quests = playerQuests[player]
        if quests then
            quests.bathroomMonster.active = true
            quests.bathroomMonster.progress = 1
            quests.bathroomMonster.completed = true
            sendQuestState(player, quests.bathroomMonster)

            -- Reward: a small random combo (1-2 items) of batteries / energy bars,
            -- dropped straight into the player's inventory.
            local pool = { "battery", "energy_bar" }
            local tally: { [string]: number } = {}
            for _ = 1, math.random(1, 2) do
                local itemId = pool[math.random(#pool)]
                tally[itemId] = (tally[itemId] or 0) + 1
                grantItemBus:Fire(player, itemId, 1)
            end
            local rewardsList = {}
            for itemId, c in tally do
                table.insert(rewardsList, { itemId = itemId, count = c })
            end

            QuestComplete:FireClient(player, {
                questId = "bathroom_monster",
                rewards = rewardsList,
            })
        end
    end
end

-- ============================================================
-- POOP MONSTER COMBO COMBAT
-- Deodorant on its own only staggers the boss; the plunger only bites while
-- it's reeling. You need BOTH — spray to stun, then plunge while it's dazed.
-- ============================================================
local function monsterTorso(): BasePart?
    if not bathroomMonsterModel then return nil end
    return bathroomMonsterModel:FindFirstChild("Torso") :: BasePart?
end

--- Briefly flash the monster's body to telegraph a stagger.
local function flashMonster(color: Color3)
    local torso = monsterTorso()
    if not torso then return end
    local original = torso.Color
    torso.Color = color
    task.delay(0.25, function()
        local t = monsterTorso()
        if t then
            t.Color = original
        end
    end)
end

local function onWeaponUsedNearMonster(player: Player, itemId: string, kind: string)
    if not bathroomMonsterAlive then return end
    local torso = monsterTorso()
    if not torso then return end

    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
    if not root then return end
    if (root.Position - torso.Position).Magnitude > 14 then return end -- must be up close

    if kind == "spray" then
        -- Deodorant staggers it (and chips a little). Axe spray hits harder.
        monsterStaggerUntil = os.clock() + 3
        flashMonster(Color3.fromRGB(180, 220, 90))
        damageBathroomMonster(player, itemId == "axe_spray" and 12 or 5)
    elseif itemId == "plunger" then
        -- Classic-sword slash: a forward swing that bites the monster directly, no
        -- spray-stagger required. The player just has to be close and facing it.
        local toMonster = torso.Position - root.Position
        if toMonster.Magnitude <= 12 and root.CFrame.LookVector:Dot(toMonster.Unit) > 0.2 then
            flashMonster(Color3.fromRGB(255, 240, 120))
            damageBathroomMonster(player, 20)
        end
    elseif kind == "melee" then
        -- Other melee weapons barely scratch it.
        damageBathroomMonster(player, 3)
    end
end

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
    ;(bus :: BindableEvent).Event:Connect(function(player: Player, itemId: string, kind: string)
        if typeof(player) == "Instance" and typeof(itemId) == "string" and typeof(kind) == "string" then
            onWeaponUsedNearMonster(player, itemId, kind)
        end
    end)
end

-- ============================================================
-- EVENT LISTENERS
-- ============================================================
Players.PlayerAdded:Connect(function(player: Player)
    playerQuests[player] = createPlayerQuests()
end)

Players.PlayerRemoving:Connect(function(player: Player)
    playerQuests[player] = nil
end)

-- Chair pickups arrive from InteractionManager's prompt handler, never from a
-- client remote, so the reward can't be farmed by firing the remote.
do
    local serverComm = ServerStorage:FindFirstChild("ServerComm")
    if not serverComm then
        serverComm = Instance.new("Folder")
        serverComm.Name = "ServerComm"
        serverComm.Parent = ServerStorage
    end
    local bus = serverComm:FindFirstChild("QuestItemCollected")
    if not (bus and bus:IsA("BindableEvent")) then
        bus = Instance.new("BindableEvent")
        bus.Name = "QuestItemCollected"
        bus.Parent = serverComm
    end
    ;(bus :: BindableEvent).Event:Connect(function(player: Player, questId: string)
        if typeof(player) == "Instance" and questId == "chair_hoarder" then
            onChairPickup(player)
        end
    end)
end

-- Spawn boss when Day2 starts — exactly once. Once it's been defeated it stays
-- dead; the flag only resets for a fresh match (back at lobby / Day1).
task.spawn(function()
    while true do
        task.wait(1)
        if currentPhase <= 1 then
            bossDefeated = false -- new match incoming
        elseif currentPhase == 2 and not bathroomMonsterModel and not bossDefeated then
            task.wait(5) -- Small delay after day2 starts
            createBathroomMonster()
        end
    end
end)

-- Listen for phase changes from GameStateManager
-- The GameStateManager broadcasts phase changes; we track it here

-- We need a way to know the current phase on the server. We'll use a module approach:
-- For now, track via attribute on a shared value
task.spawn(function()
    while true do
        local phaseValue = ReplicatedStorage:FindFirstChild("CurrentPhase")
        if phaseValue and phaseValue:IsA("IntValue") then
            currentPhase = phaseValue.Value
            phaseValue.Changed:Connect(function(newPhase)
                currentPhase = newPhase
                -- New match: the chairs go back out (InteractionManager), so the
                -- race starts over for everyone.
                if newPhase == GameConfig.Phase.DAY1 then
                    for p, quests in playerQuests do
                        quests.chairHoarder = createPlayerQuests().chairHoarder
                        sendQuestState(p, quests.chairHoarder)
                    end
                end
            end)
            break
        end
        task.wait(0.5)
    end
end)

-- Initialize quests for existing players
for _, p in Players:GetPlayers() do
    if not playerQuests[p] then
        playerQuests[p] = createPlayerQuests()
    end
end

print("[QuestManager] Initialized - Chair Hoarder + Bathroom Monster quests ready")
