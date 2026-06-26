--!strict
--------------------------------------------------------------------------------
-- NPCManager.server.luau
-- Server-side NPC lifecycle manager for Not Gonna Make It.
--
-- Responsibilities:
--   • Spawn NPC humanoid models at DAY1 start from NPCConfig data
--   • Patrol NPCs between waypoints using PathfindingService
--   • Handle ProximityPrompt dialogue triggers → fire to client
--   • Corruption phase: stress visuals, syntax muttering
--   • Night2 transition: despawn mutatable NPCs, cower sane ones
--------------------------------------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local NPCConfig = require(ReplicatedStorage.Shared.NPCConfig)
local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local RigFactory = require(script.Parent.RigFactory)

-- Remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local NPCDialogueTrigger = Remotes:WaitForChild("NPCDialogueTrigger") :: RemoteEvent
local NPCDialogueChoice = Remotes:WaitForChild("NPCDialogueChoice") :: RemoteEvent
local GameStateChanged = Remotes:WaitForChild("GameStateChanged") :: RemoteEvent
local CorruptionStarted = Remotes:WaitForChild("CorruptionStarted") :: RemoteEvent

--------------------------------------------------------------------------------
-- Types
--------------------------------------------------------------------------------

type NPCState = "IDLE" | "WALKING" | "TALKING" | "CORRUPTING" | "COWERING" | "DESPAWNED"

type NPCRuntime = {
	definition: NPCConfig.NPCDefinition,
	model: Model?,
	state: NPCState,
	currentWaypointIndex: number,
	patrolThread: thread?,
	corruptionThread: thread?,
	barkThread: thread?,
	facingThread: thread?,
	talkingPlayer: Player?,
	isActive: boolean,
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local npcFolder: Folder = Instance.new("Folder")
npcFolder.Name = "NPCs"
npcFolder.Parent = workspace

-- All active NPC runtime data, keyed by NPC id
local activeNPCs: { [string]: NPCRuntime } = {}

-- Track which players are currently in dialogue and with which NPC
local playerDialogueState: { [Player]: string } = {} -- player → npcId

--------------------------------------------------------------------------------
-- NPC Model Builder
-- Creates a simple humanoid NPC model from Parts welded together.
-- Head, Torso, Left/Right Arms, Left/Right Legs, Humanoid, HumanoidRootPart.
--------------------------------------------------------------------------------

local function resolveSpawnCFrame(def: NPCConfig.NPCDefinition): CFrame
	-- Try to find an NPCSpawn-tagged part whose Name matches the NPC id
	local spawnParts = CollectionService:GetTagged("NPCSpawn")
	for _, part in spawnParts do
		if part:IsA("BasePart") and part.Name == def.id then
			return (part :: BasePart).CFrame + Vector3.new(0, 3, 0)
		end
	end
	-- Fallback: use the position defined in NPCConfig
	return CFrame.new(def.spawnPosition)
end

--------------------------------------------------------------------------------
-- Per-NPC appearance. Instead of a floating name tag, each named NPC gets a
-- distinct look (skin tone, hair / beanie / cap, glasses / headphones) built
-- from welded parts, so they read as individual people.
--------------------------------------------------------------------------------
local HAIR_COLORS = {
	Color3.fromRGB(28, 20, 16), Color3.fromRGB(82, 54, 32), Color3.fromRGB(120, 86, 50),
	Color3.fromRGB(38, 38, 44), Color3.fromRGB(178, 142, 90), Color3.fromRGB(150, 45, 45),
	Color3.fromRGB(70, 70, 78), Color3.fromRGB(210, 200, 180),
}
local SKIN_COLORS = {
	Color3.fromRGB(236, 200, 170), Color3.fromRGB(208, 166, 126),
	Color3.fromRGB(170, 122, 90), Color3.fromRGB(120, 86, 60),
}
local PANTS_COLORS = {
	Color3.fromRGB(40, 42, 52), Color3.fromRGB(60, 50, 42), Color3.fromRGB(45, 55, 60), Color3.fromRGB(30, 30, 34),
}

local function hashId(id: string): number
	local h = 5381
	for i = 1, #id do
		h = (h * 33 + string.byte(id, i)) % 1000003
	end
	return h
end

local function attachToHead(head: BasePart, name: string, size: Vector3, offset: CFrame, color: Color3)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.CanCollide = false
	p.CanQuery = false
	p.Massless = true
	p.CastShadow = false
	p.CFrame = head.CFrame * offset
	p.Parent = head.Parent
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = head
	weld.Part1 = p
	weld.Parent = p
end

local function applyAppearance(model: Model, def: NPCConfig.NPCDefinition)
	local head = model:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		return
	end
	local h = hashId(def.id)

	local skin = SKIN_COLORS[(h % #SKIN_COLORS) + 1]
	for _, n in { "Head", "LeftHand", "RightHand", "LeftLowerArm", "RightLowerArm" } do
		local pt = model:FindFirstChild(n)
		if pt and pt:IsA("BasePart") then pt.Color = skin end
	end
	local pants = PANTS_COLORS[((h // 7) % #PANTS_COLORS) + 1]
	for _, n in { "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "RightUpperLeg", "RightLowerLeg", "RightFoot" } do
		local pt = model:FindFirstChild(n)
		if pt and pt:IsA("BasePart") then pt.Color = pants end
	end

	local hairColor = HAIR_COLORS[((h // 3) % #HAIR_COLORS) + 1]
	local style = h % 5
	if style == 0 then
		attachToHead(head, "Hair", Vector3.new(1.3, 0.55, 1.32), CFrame.new(0, 0.5, 0.02), hairColor)
	elseif style == 1 then
		attachToHead(head, "Hair", Vector3.new(1.25, 0.85, 1.25), CFrame.new(0, 0.62, 0.05), hairColor)
	elseif style == 2 then
		attachToHead(head, "Hair", Vector3.new(1.32, 0.5, 1.32), CFrame.new(0, 0.48, 0), hairColor)
		attachToHead(head, "Bangs", Vector3.new(1.32, 0.4, 0.22), CFrame.new(0, 0.22, -0.6), hairColor)
	elseif style == 3 then
		attachToHead(head, "Beanie", Vector3.new(1.4, 0.75, 1.4), CFrame.new(0, 0.45, 0), def.hoodieColor)
	end
	-- style == 4 → short/clean, no extra hair

	local acc = (h // 11) % 4
	if acc == 0 then
		attachToHead(head, "Glasses", Vector3.new(1.08, 0.2, 0.1), CFrame.new(0, 0.1, -0.62), Color3.fromRGB(22, 22, 26))
	elseif acc == 1 then
		attachToHead(head, "HpL", Vector3.new(0.22, 0.6, 0.6), CFrame.new(-0.64, 0.05, 0), Color3.fromRGB(28, 28, 32))
		attachToHead(head, "HpR", Vector3.new(0.22, 0.6, 0.6), CFrame.new(0.64, 0.05, 0), Color3.fromRGB(28, 28, 32))
		attachToHead(head, "HpBand", Vector3.new(0.2, 1.2, 0.45), CFrame.new(0, 0.5, 0.05), Color3.fromRGB(28, 28, 32))
	elseif acc == 2 then
		attachToHead(head, "CapBrim", Vector3.new(1.25, 0.12, 0.7), CFrame.new(0, 0.32, -0.7), def.hoodieColor)
	end
	-- acc == 3 → no face accessory
end

local function createNPCModel(def: NPCConfig.NPCDefinition): Model
	-- Real Roblox R15 avatar rig (falls back to a block rig if the avatar API
	-- is unavailable — see RigFactory).
	local model, humanoid = RigFactory.create()
	model.Name = def.id
	humanoid.WalkSpeed = 8 -- casual patrol speed

	-- Tint the torso/sleeves with this NPC's signature hoodie colour so the
	-- named characters are recognisable.
	for _, partName in { "UpperTorso", "LowerTorso", "LeftUpperArm", "RightUpperArm", "Torso" } do
		local part = model:FindFirstChild(partName)
		if part and part:IsA("BasePart") then
			part.Color = def.hoodieColor
		end
	end

	-- Give each named NPC a distinct look (skin/hair/accessories) so they read as
	-- individual people instead of identical hoodie rigs.
	applyAppearance(model, def)

	model:PivotTo(resolveSpawnCFrame(def))

	-- Default idle/walk animation driver so they don't slide while patrolling.
	RigFactory.driveLocomotion(humanoid)

	return model
end

--------------------------------------------------------------------------------
-- BillboardGui — name label above NPC head
--------------------------------------------------------------------------------

local function createNameTag(model: Model, def: NPCConfig.NPCDefinition): BillboardGui
	local head = model:FindFirstChild("Head") :: Part?
	if not head then
		warn("[NPCManager] No Head found on model: " .. def.id)
		-- Fallback: attach to root
		head = model:FindFirstChild("HumanoidRootPart") :: Part
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "NameTag"
	billboard.Adornee = head
	billboard.Size = UDim2.new(0, 200, 0, 30)
	billboard.StudsOffset = NPCConfig.nameTagOffset
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 40
	billboard.Parent = head

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "NameLabel"
	nameLabel.Size = UDim2.new(1, 0, 1, 0)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = def.displayName
	nameLabel.TextColor3 = def.nameColor
	nameLabel.TextStrokeTransparency = 0.5
	nameLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextScaled = true
	nameLabel.Parent = billboard

	return billboard
end

--------------------------------------------------------------------------------
-- Corruption muttering BillboardGui (separate from name tag)
--------------------------------------------------------------------------------

local function createMutterLabel(model: Model): TextLabel
	local head = model:FindFirstChild("Head") :: Part?
	if not head then
		return Instance.new("TextLabel") -- fallback, should not happen
	end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "MutterBubble"
	billboard.Adornee = head
	billboard.Size = UDim2.new(0, 250, 0, 40)
	billboard.StudsOffset = Vector3.new(0, 4.5, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 25
	billboard.Parent = head

	local label = Instance.new("TextLabel")
	label.Name = "MutterText"
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundTransparency = 1
	label.Text = ""
	label.TextColor3 = NPCConfig.corruptionParticleColor
	label.TextStrokeTransparency = 0.2
	label.TextStrokeColor3 = Color3.new(0, 0, 0)
	label.Font = Enum.Font.Code
	label.TextScaled = true
	label.TextTransparency = 0.3
	label.Parent = billboard

	return label
end

--------------------------------------------------------------------------------
-- Corruption particle emitter (purple smoke on torso)
--------------------------------------------------------------------------------

local function attachCorruptionParticles(model: Model): ParticleEmitter
	local torso = (model:FindFirstChild("UpperTorso") or model:FindFirstChild("Torso")) :: Part?
	if not torso then
		torso = model:FindFirstChild("HumanoidRootPart") :: Part
	end

	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "CorruptionSmoke"
	emitter.Color = ColorSequence.new(NPCConfig.corruptionParticleColor)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 2),
	})
	emitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	emitter.Lifetime = NumberRange.new(1, 2)
	emitter.Rate = 8
	emitter.Speed = NumberRange.new(0.5, 1.5)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Enabled = true
	emitter.Parent = torso

	return emitter
end

--------------------------------------------------------------------------------
-- ProximityPrompt for dialogue interaction
--------------------------------------------------------------------------------

local function createDialoguePrompt(model: Model, def: NPCConfig.NPCDefinition): ProximityPrompt
	local rootPart = model:FindFirstChild("HumanoidRootPart") :: Part
	
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "DialoguePrompt"
	prompt.ActionText = "Talk"
	prompt.ObjectText = def.displayName
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = NPCConfig.dialogueProximityDistance
	-- The prompt lives on the HumanoidRootPart, which is buried inside the NPC's
	-- own torso. With line-of-sight on, the character's own parts occlude the
	-- prompt and the "Talk" hint never appears — so it's disabled here.
	prompt.RequiresLineOfSight = false
	prompt.Parent = rootPart

	return prompt
end

--------------------------------------------------------------------------------
-- Idle wander — every 5-7s the NPC ambles to a random point within ~5 studs of
-- wherever it's standing, then settles. Pauses while it's anchored, mid-chat, or
-- under cutscene control.
--------------------------------------------------------------------------------

local function startPatrol(runtime: NPCRuntime)
	if not runtime.model or not runtime.isActive then return end

	runtime.patrolThread = task.spawn(function()
		local model = runtime.model :: Model
		local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
		-- We ignore the hand-authored waypoints (they were drawn for the old map and
		-- now walk NPCs into walls). Every NPC just gently mills around wherever it
		-- settles: every 5-7s it strolls to a random point within ~5 studs of home.
		-- `home` is captured lazily, and re-captured whenever the NPC is moved far
		-- (e.g. relocated to its floor after the opening cutscene), so they always
		-- wander around their CURRENT spot rather than a stale spawn point.
		local home: Vector3? = nil
		while runtime.isActive and runtime.model do
			task.wait(5 + math.random() * 2) -- 5-7s between strolls
			if not runtime.isActive or not runtime.model then break end

			local rootPart = model:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not rootPart or not rootPart.Parent then break end

			-- Stay out of the way while another system is driving this NPC: a
			-- conversation / corruption / cower (state ~= IDLE), a deliberate anchor,
			-- or the opening cutscene (flagged on the model while it controls them).
			if runtime.state ~= "IDLE" then continue end
			if rootPart.Anchored then continue end
			if model:GetAttribute("CutsceneControlled") then continue end

			-- Anchor home to the current spot on first run or after a big relocation
			-- (threshold well above the wander radius so normal strolls don't reset it).
			if not home or (rootPart.Position - home).Magnitude > 45 then
				home = rootPart.Position
			end

			local ang = math.random() * math.pi * 2
			local rad = 7 + math.random() * 11 -- ~7-18 studs from home
			local target = (home :: Vector3) + Vector3.new(math.cos(ang) * rad, 0, math.sin(ang) * rad)

			runtime.state = "WALKING"
			local prevSpeed = humanoid.WalkSpeed
			humanoid.WalkSpeed = 6 -- a slow amble
			humanoid:MoveTo(target)
			humanoid.MoveToFinished:Wait()
			humanoid.WalkSpeed = prevSpeed
			if runtime.state == "WALKING" then
				runtime.state = "IDLE"
			end
		end
	end)
end

local function stopPatrol(runtime: NPCRuntime)
	if runtime.patrolThread then
		task.cancel(runtime.patrolThread)
		runtime.patrolThread = nil
	end
end

--------------------------------------------------------------------------------
-- Corruption behavior — muttering broken syntax + purple smoke
--------------------------------------------------------------------------------

local function startCorruption(runtime: NPCRuntime)
	local def = runtime.definition
	if not def.canMutate or not def.corruptionLines then return end
	if not runtime.model then return end

	local model = runtime.model :: Model

	-- Attach purple particle emitter
	attachCorruptionParticles(model)

	-- Create mutter label
	local mutterLabel = createMutterLabel(model)

	runtime.state = "CORRUPTING"

	-- Cycle through corruption lines in overhead text
	runtime.corruptionThread = task.spawn(function()
		local lines = def.corruptionLines :: { string }
		local lineIndex = 1

		while runtime.isActive and runtime.model do
			mutterLabel.Text = lines[lineIndex]
			lineIndex = (lineIndex % #lines) + 1

			-- Flash the text in and out
			for i = 0, 10 do
				if not runtime.isActive then return end
				mutterLabel.TextTransparency = 0.3 + 0.05 * math.abs(i - 5)
				task.wait(0.2)
			end

			-- Brief pause between lines
			task.wait(math.random() * 2 + 1)
		end
	end)
end

local function stopCorruption(runtime: NPCRuntime)
	if runtime.corruptionThread then
		task.cancel(runtime.corruptionThread)
		runtime.corruptionThread = nil
	end
end

--------------------------------------------------------------------------------
-- Idle barks — unique overhead one-liners for the named NPCs
--------------------------------------------------------------------------------

local function startBarks(runtime: NPCRuntime)
	local def = runtime.definition
	if not def.idleBarks or #def.idleBarks == 0 then return end
	local model = runtime.model
	if not model then return end
	local head = model:FindFirstChild("Head") :: BasePart?
	if not head then return end

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "BarkBubble"
	billboard.Adornee = head
	billboard.Size = UDim2.new(0, 240, 0, 50)
	billboard.StudsOffset = Vector3.new(0, 2.8, 0)
	billboard.AlwaysOnTop = true
	billboard.MaxDistance = 35
	billboard.Parent = head

	local label = Instance.new("TextLabel")
	label.Size = UDim2.new(1, 0, 1, 0)
	label.BackgroundColor3 = Color3.fromRGB(20, 22, 30)
	label.BackgroundTransparency = 1
	label.TextColor3 = Color3.new(1, 1, 1)
	label.Font = Enum.Font.GothamMedium
	label.TextScaled = true
	label.Text = ""
	label.TextTransparency = 1
	label.Parent = billboard
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = label

	runtime.barkThread = task.spawn(function()
		local lines = def.idleBarks :: { string }
		while runtime.isActive and runtime.model do
			task.wait(math.random(7, 15))
			if runtime.isActive and (runtime.state == "IDLE" or runtime.state == "WALKING") then
				label.Text = lines[math.random(#lines)]
				label.TextTransparency = 0
				label.BackgroundTransparency = 0.25
				task.wait(3.5)
				label.TextTransparency = 1
				label.BackgroundTransparency = 1
			end
		end
	end)
end

local function stopBarks(runtime: NPCRuntime)
	if runtime.barkThread then
		task.cancel(runtime.barkThread)
		runtime.barkThread = nil
	end
end

--------------------------------------------------------------------------------
-- Conversation behaviour — face the player while talking, then turn and walk off
--------------------------------------------------------------------------------

--- Begin a conversation: stop wandering, anchor in place and smoothly rotate to
--- face the player for as long as the chat lasts.
local function startTalking(runtime: NPCRuntime, player: Player)
	local model = runtime.model
	if not model then return end

	runtime.state = "TALKING"
	runtime.talkingPlayer = player
	stopPatrol(runtime)

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if humanoid then
		humanoid.AutoRotate = false
		humanoid:Move(Vector3.zero)
	end
	-- Anchor the root so setting its CFrame each frame rotates the NPC cleanly
	-- (without the physics sim fighting the turn or making it drift/walk).
	if root and root:IsA("BasePart") then
		root.Anchored = true
	end

	if runtime.facingThread then
		task.cancel(runtime.facingThread)
		runtime.facingThread = nil
	end
	runtime.facingThread = task.spawn(function()
		while runtime.isActive and runtime.state == "TALKING" and runtime.model do
			local r = runtime.model:FindFirstChild("HumanoidRootPart")
			local char = player.Character
			local phrp = char and char:FindFirstChild("HumanoidRootPart")
			if r and r:IsA("BasePart") and phrp and phrp:IsA("BasePart") then
				local p = r.Position
				local look = Vector3.new(phrp.Position.X, p.Y, phrp.Position.Z)
				if (look - p).Magnitude > 0.3 then
					r.CFrame = r.CFrame:Lerp(CFrame.lookAt(p, look), 0.3)
				end
			end
			task.wait(0.05)
		end
	end)
end

--- End a conversation: the NPC turns away from the player and ambles off a few
--- studs, then settles back into idle.
local function endTalk(runtime: NPCRuntime?)
	if not runtime or runtime.state ~= "TALKING" then return end

	if runtime.facingThread then
		task.cancel(runtime.facingThread)
		runtime.facingThread = nil
	end
	runtime.state = "IDLE"

	local model = runtime.model
	local player = runtime.talkingPlayer
	runtime.talkingPlayer = nil
	if not model then return end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.Anchored = false
	end
	if not humanoid or not root or not root:IsA("BasePart") then return end
	humanoid.AutoRotate = true

	task.spawn(function()
		local pos = root.Position
		-- direction pointing away from the player (flattened to the floor plane)
		local awayDir = root.CFrame.LookVector
		local pchar = player and player.Character
		local pr = pchar and pchar:FindFirstChild("HumanoidRootPart")
		if pr and pr:IsA("BasePart") then
			local d = pos - pr.Position
			d = Vector3.new(d.X, 0, d.Z)
			if d.Magnitude > 0.1 then
				awayDir = d.Unit
			end
		end
		awayDir = Vector3.new(awayDir.X, 0, awayDir.Z)
		if awayDir.Magnitude < 0.1 then return end
		awayDir = awayDir.Unit
		-- turn to face away, then stroll off
		root.CFrame = CFrame.lookAt(pos, pos + awayDir)
		humanoid:MoveTo(pos + awayDir * 12)
		humanoid.MoveToFinished:Wait()
	end)

	-- Resume gentle idle wandering once the chat is over.
	startPatrol(runtime)
end

--------------------------------------------------------------------------------
-- NPC Spawning
--------------------------------------------------------------------------------

local function spawnNPC(def: NPCConfig.NPCDefinition): NPCRuntime
	local model = createNPCModel(def)
	model.Parent = npcFolder

	-- Tag with CollectionService
	CollectionService:AddTag(model, "NPC")

	-- No floating name tag — NPCs are identified by their distinct look and the
	-- talk prompt that appears when you get close.

	-- Add dialogue prompt
	local prompt = createDialoguePrompt(model, def)

	-- Wire up ProximityPrompt → fire dialogue to triggering player
	prompt.Triggered:Connect(function(player: Player)
		if not player then return end

		-- Don't start dialogue if NPC is corrupting or despawned
		local runtime = activeNPCs[def.id]
		if not runtime or runtime.state == "CORRUPTING" or runtime.state == "DESPAWNED" then
			return
		end

		-- Don't start if player is already in dialogue
		if playerDialogueState[player] then return end

		playerDialogueState[player] = def.id

		-- Turn to face the player and hold the conversation
		startTalking(runtime, player)

		-- Send initial dialogue to client
		NPCDialogueTrigger:FireClient(player, {
			npcId = def.id,
			displayName = def.displayName,
			npcType = def.npcType,
			nameColor = { def.nameColor.R, def.nameColor.G, def.nameColor.B },
			dialogueNodeId = "start",
			text = def.dialogue["start"].text,
			options = def.dialogue["start"].options,
		})
	end)

	local runtime: NPCRuntime = {
		definition = def,
		model = model,
		state = "IDLE",
		currentWaypointIndex = 1,
		patrolThread = nil,
		corruptionThread = nil,
		barkThread = nil,
		facingThread = nil,
		talkingPlayer = nil,
		isActive = true,
	}

	activeNPCs[def.id] = runtime
	startBarks(runtime)
	return runtime
end

local function despawnNPC(runtime: NPCRuntime)
	runtime.isActive = false
	runtime.state = "DESPAWNED"
	stopPatrol(runtime)
	stopCorruption(runtime)
	stopBarks(runtime)

	if runtime.model then
		runtime.model:Destroy()
		runtime.model = nil
	end
end

--------------------------------------------------------------------------------
-- Phase Handlers
--------------------------------------------------------------------------------

local function onDAY1Start()
	-- Idempotent: a phase can be (re)entered (e.g. admin "skip to Day 1"), so clear
	-- any cast spawned by a previous entry first — otherwise we end up with two of
	-- every named NPC.
	local previous = {}
	for _, runtime in activeNPCs do
		table.insert(previous, runtime)
	end
	for _, runtime in previous do
		despawnNPC(runtime)
	end
	table.clear(activeNPCs)
	for _, m in npcFolder:GetChildren() do
		m:Destroy()
	end

	-- Spawn all NPCs defined in NPCConfig, then set them gently milling about their
	-- spot (startPatrol ignores the old hand-authored waypoints, which walked NPCs
	-- into walls, and just strolls them within ~5 studs of home every 5-7s).
	for _, def in NPCConfig.npcs do
		local runtime = spawnNPC(def)
		runtime.state = "IDLE"
		startPatrol(runtime)
	end

	print("[NPCManager] DAY1: Spawned", #NPCConfig.npcs, "NPCs (idle wander)")
end

local function onCorruptionStart()
	-- Mutatable NPCs start showing corruption stress
	for _, runtime in activeNPCs do
		if runtime.definition.canMutate and runtime.isActive then
			stopPatrol(runtime)
			startCorruption(runtime)

			-- Disable dialogue prompt during corruption
			if runtime.model then
				local rootPart = runtime.model:FindFirstChild("HumanoidRootPart")
				if rootPart then
					local prompt = rootPart:FindFirstChild("DialoguePrompt") :: ProximityPrompt?
					if prompt then
						prompt.Enabled = false
					end
				end
			end

			print("[NPCManager] Corruption started for:", runtime.definition.id)
		end
	end
end

local function onNIGHT2Start()
	-- Mutatable NPCs despawn (replaced by NGMI spawns handled by NGMIController)
	for _, runtime in activeNPCs do
		if runtime.definition.canMutate then
			print("[NPCManager] NIGHT2: Despawning mutated NPC:", runtime.definition.id)
			despawnNPC(runtime)
		end
	end

	-- Sane NPCs flee to hiding spots and cower
	for _, runtime in activeNPCs do
		if runtime.isActive and runtime.definition.hidingSpot then
			stopPatrol(runtime)
			runtime.state = "COWERING"

			-- Disable dialogue during Night2
			if runtime.model then
				local rootPart = runtime.model:FindFirstChild("HumanoidRootPart")
				if rootPart then
					local prompt = rootPart:FindFirstChild("DialoguePrompt") :: ProximityPrompt?
					if prompt then
						prompt.Enabled = false
					end
				end
			end

			-- Move to hiding spot
			task.spawn(function()
				if not runtime.model then return end
				local humanoid = runtime.model:FindFirstChildOfClass("Humanoid") :: Humanoid?
				if not humanoid then return end

				local hidingSpot = runtime.definition.hidingSpot :: Vector3
				humanoid:MoveTo(hidingSpot)
				humanoid.MoveToFinished:Wait()

				-- Play cowering animation (crouch/idle) by reducing walkspeed to 0
				humanoid.WalkSpeed = 0

				-- Make NPC crouch by adjusting root part height
				local rootPart = runtime.model:FindFirstChild("HumanoidRootPart") :: Part?
				if rootPart then
					-- Slight downward shift to simulate crouching
					rootPart.CFrame = rootPart.CFrame * CFrame.new(0, -0.5, 0)
				end

				print("[NPCManager] NPC cowering at hiding spot:", runtime.definition.id)
			end)
		end
	end
end

local function onDAY3Start()
	-- Clean up all remaining NPCs
	for _, runtime in activeNPCs do
		despawnNPC(runtime)
	end
	table.clear(activeNPCs)
	print("[NPCManager] DAY3: All NPCs cleaned up")
end

--------------------------------------------------------------------------------
-- Dialogue Choice Handler
-- When a player picks a dialogue option, send the next node or end dialogue.
--------------------------------------------------------------------------------

NPCDialogueChoice.OnServerEvent:Connect(function(player: Player, data: any)
	if typeof(data) ~= "table" then return end

	local npcId = data.npcId :: string?
	local responseId = data.responseId :: string?

	if not npcId then return end

	-- Validate player is in dialogue with this NPC
	if playerDialogueState[player] ~= npcId then return end

	-- If responseId is nil, dialogue is ending
	if not responseId then
		playerDialogueState[player] = nil
		endTalk(activeNPCs[npcId]) -- NPC turns and walks away
		return
	end

	-- Look up the NPC definition
	local runtime = activeNPCs[npcId]
	if not runtime then
		playerDialogueState[player] = nil
		return
	end

	local def = runtime.definition
	local nextNode = def.dialogue[responseId]
	if not nextNode then
		-- Invalid response, end dialogue
		playerDialogueState[player] = nil
		return
	end

	-- Send next dialogue node to client
	NPCDialogueTrigger:FireClient(player, {
		npcId = def.id,
		displayName = def.displayName,
		npcType = def.npcType,
		nameColor = { def.nameColor.R, def.nameColor.G, def.nameColor.B },
		dialogueNodeId = responseId,
		text = nextNode.text,
		options = nextNode.options,
	})
end)

--------------------------------------------------------------------------------
-- Game State Listener
-- Responds to phase transitions to manage NPC lifecycle.
--------------------------------------------------------------------------------

GameStateChanged.OnServerEvent:Connect(function(_player: Player, data: any)
	-- This event is typically fired by the GameLoop server script, not clients.
	-- We also listen for server-side signals. For safety, ignore client fires.
end)

-- Expose a module-style API that GameLoop can call directly via BindableEvents
-- or we listen for a simple attribute-based phase tracking on a shared object.
-- For now, we use a simple polling approach on a Value object, or the GameLoop
-- can require this module. Let's use BindableEvents instead.

local function setupPhaseListeners()
	-- Reuse the shared ServerComm folder if another system (e.g. GameStateManager)
	-- already created it. Creating a *second* folder here was a real bug: this
	-- listener would bind to its own private PhaseChanged bindable while
	-- GameStateManager fired the one in the original folder, so onDAY1Start never
	-- ran and the named NPCs never spawned.
	local serverStorage = game:GetService("ServerStorage")
	local existingComm = serverStorage:FindFirstChild("ServerComm")
	local serverComm: Folder
	if existingComm and existingComm:IsA("Folder") then
		serverComm = existingComm
	else
		serverComm = Instance.new("Folder")
		serverComm.Name = "ServerComm"
		serverComm.Parent = serverStorage
	end

	-- Check if phase events already exist, create if not
	local function getOrCreateBindable(name: string): BindableEvent
		local existing = serverComm:FindFirstChild(name)
		if existing and existing:IsA("BindableEvent") then
			return existing :: BindableEvent
		end
		local bindable = Instance.new("BindableEvent")
		bindable.Name = name
		bindable.Parent = serverComm
		return bindable
	end

	local phaseChanged = getOrCreateBindable("PhaseChanged")
	local corruptionTriggered = getOrCreateBindable("CorruptionTriggered")

	phaseChanged.Event:Connect(function(phase: number)
		if phase == 1 then
			onDAY1Start()
		elseif phase == 3 then
			onNIGHT2Start()
		elseif phase == 4 then
			onDAY3Start()
		end
	end)

	corruptionTriggered.Event:Connect(function()
		onCorruptionStart()
	end)

	print("[NPCManager] Phase listeners ready")
end

--------------------------------------------------------------------------------
-- Player cleanup — remove dialogue state when player leaves
--------------------------------------------------------------------------------

Players.PlayerRemoving:Connect(function(player: Player)
	local talkingWith = playerDialogueState[player]
	if talkingWith then
		endTalk(activeNPCs[talkingWith])
	end
	playerDialogueState[player] = nil
end)

--------------------------------------------------------------------------------
-- Initialization
--------------------------------------------------------------------------------

setupPhaseListeners()

-- Also listen for GameStateChanged remote as a fallback
-- (The GameLoop fires this to all clients; server scripts can also listen
--  if GameLoop fires it server-side via a BindableEvent pattern)
GameStateChanged.OnServerEvent:Connect(function(_player: Player, _data: any)
	-- Clients should not be driving phase changes — ignore
end)

print("[NPCManager] Initialized — waiting for DAY1 phase to spawn NPCs")
