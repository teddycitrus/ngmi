--!strict
--------------------------------------------------------------------------------
-- Boss/PoopMonster.luau
-- Server brain of the bathroom boss. The server model is only an invisible
-- hitbox ("Torso") plus attributes; every client builds the body itself
-- (client/PoopMonster) and animates it from those attributes, and one-shot
-- effects go out on the BossFX remote. So the fight costs almost nothing to
-- replicate, and the server stays the authority on every hit.
--
-- Model attributes (read by clients and tests):
--   State, StateT (server time it began), Dur, Arm ("L"/"R"), Phase (1-3),
--   Health, MaxHealth, Poise (0-100), PoiseLocked, Core (weak point open),
--   Awake, Beacon, Home, FloorY
--
-- The fight: spray builds the stagger meter (Poise); a full meter staggers it
-- and opens the core, and so does getting stuck after a slam. The plunger
-- does triple damage to an open core. Phase 2 at 60% adds the flush vortex,
-- phase 3 at 25% adds a second shockwave and exploding minions.
--------------------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))
local BadgeManager = require(script.Parent.Parent:WaitForChild("BadgeManager"))
local Arena = require(script.Parent:WaitForChild("Arena"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PlayerDamaged = Remotes:WaitForChild("PlayerDamaged") :: RemoteEvent
local BossFX: RemoteEvent
do
	local found = Remotes:FindFirstChild("BossFX")
	if found and found:IsA("RemoteEvent") then
		BossFX = found
	else
		BossFX = Instance.new("RemoteEvent")
		BossFX.Name = "BossFX"
		BossFX.Parent = Remotes
	end
	-- Clients never send on it; keep a listener so nothing queues.
	BossFX.OnServerEvent:Connect(function() end)
end

local HITBOX = Vector3.new(7, 10, 7)
local BASE_HEALTH = 300
local HEALTH_PER_EXTRA_FIGHTER = 180
local PHASE2_AT = 0.6
local PHASE3_AT = 0.25

local POISE_MAX = 100
local POISE_DECAY = 9 -- per second, after POISE_HOLD without a spray
local POISE_HOLD = 2
local STAGGER_TIME = 4
local POISE_LOCK_AFTER = 4 -- seconds after a stagger before the meter fills again

local SPRAY_REACH = 18 -- from the boss's centre
local MELEE_REACH = 10.5
local LEAVE_GRACE = 6 -- seconds with nobody inside before it sinks back
local DORMANT_REGEN = 6 -- health per second while sunk in its toilet

export type Phase = { speed: number, gap: number, globs: number, windup: number }
local PHASES: { Phase } = {
	{ speed = 9, gap = 1.5, globs = 3, windup = 1 },
	{ speed = 11, gap = 1.15, globs = 5, windup = 0.85 },
	{ speed = 13, gap = 0.85, globs = 5, windup = 0.72 },
}

export type Callbacks = {
	onDefeated: (killer: Player) -> (),
}

local PoopMonster = {}
PoopMonster.__index = PoopMonster
PoopMonster.PHASES = PHASES
PoopMonster.FX = BossFX

export type Boss = typeof(setmetatable(
	{} :: {
		model: Model,
		root: Part,
		arena: Arena.Arena,
		callbacks: Callbacks,
		alive: boolean,
		awake: boolean,
		busy: boolean,
		token: number,
		state: string,
		phase: number,
		health: number,
		maxHealth: number,
		scaledFor: number,
		poise: number,
		lastSpray: number,
		poiseLockedUntil: number,
		coreOpen: boolean,
		invulnerable: boolean,
		pos: Vector3, -- floor-level position
		look: Vector3, -- flat facing
		tracking: boolean,
		target: Arena.Fighter?,
		fighters: { Arena.Fighter },
		emptyFor: number,
		cooldownUntil: number,
		lastAttack: string,
		repeatCount: number,
		lastVortex: number,
		lastSummon: number,
		armSide: string,
		puddles: { { pos: Vector3, r: number, untilT: number } },
		puddleTick: { [Player]: number },
		minions: { any },
		conn: RBXScriptConnection?,
		attacks: any,
	},
	PoopMonster
))

local function now(): number
	return workspace:GetServerTimeNow()
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

function PoopMonster.spawn(marker: BasePart, callbacks: Callbacks): Boss
	local arena = Arena.new(marker)

	local model = Instance.new("Model")
	model.Name = "PoopMonster"
	local root = Instance.new("Part")
	root.Name = "Torso"
	root.Size = HITBOX
	root.Anchored = true
	root.CanCollide = false
	root.CanTouch = false
	root.Transparency = 1
	root.CastShadow = false
	root.Parent = model
	model.PrimaryPart = root

	local self = setmetatable({
		model = model,
		root = root,
		arena = arena,
		callbacks = callbacks,
		alive = true,
		awake = false,
		busy = false,
		token = 0,
		state = "dormant",
		phase = 1,
		health = BASE_HEALTH,
		maxHealth = BASE_HEALTH,
		scaledFor = 1,
		poise = 0,
		lastSpray = 0,
		poiseLockedUntil = 0,
		coreOpen = false,
		invulnerable = true,
		pos = arena.home,
		look = arena.intoRoom,
		tracking = false,
		target = nil,
		fighters = {},
		emptyFor = 0,
		cooldownUntil = 0,
		lastAttack = "",
		repeatCount = 0,
		lastVortex = 0,
		lastSummon = 0,
		armSide = "R",
		puddles = {},
		puddleTick = {},
		minions = {},
		conn = nil,
		attacks = nil,
	}, PoopMonster)
	self.attacks = require(script.Parent:WaitForChild("Attacks"))

	model:SetAttribute("Home", arena.home)
	model:SetAttribute("FloorY", arena.floorY)
	model:SetAttribute("IntoRoom", arena.intoRoom)
	self:hideBelow()
	self:setState("dormant", 0)
	self:syncStats()
	model.Parent = workspace
	CollectionService:AddTag(model, "BathroomMonster")

	self.conn = RunService.Heartbeat:Connect(function(dt: number)
		self:step(dt)
	end)
	return self
end

--------------------------------------------------------------------------------
-- State and stats
--------------------------------------------------------------------------------

function PoopMonster.setState(self: Boss, state: string, dur: number, attrs: { [string]: any }?)
	self.state = state
	local m = self.model
	m:SetAttribute("State", state)
	m:SetAttribute("StateT", now())
	m:SetAttribute("Dur", dur)
	if attrs then
		for k, v in attrs do
			m:SetAttribute(k, v)
		end
	end
end

function PoopMonster.syncStats(self: Boss)
	local m = self.model
	m:SetAttribute("Health", math.max(0, math.floor(self.health + 0.5)))
	m:SetAttribute("MaxHealth", self.maxHealth)
	m:SetAttribute("Poise", math.floor(self.poise + 0.5))
	m:SetAttribute("PoiseLocked", now() < self.poiseLockedUntil)
	m:SetAttribute("Phase", self.phase)
	m:SetAttribute("Core", self.coreOpen)
	m:SetAttribute("Awake", self.awake)
end

function PoopMonster.fx(_self: Boss, payload: { [string]: any })
	BossFX:FireAllClients(payload)
end

function PoopMonster.phaseInfo(self: Boss): Phase
	return PHASES[self.phase]
end

--- The hitbox's world CFrame for a floor position and facing.
function PoopMonster.place(self: Boss)
	local p = self.pos + Vector3.new(0, HITBOX.Y / 2, 0)
	self.root.CFrame = CFrame.lookAt(p, p + self.look)
end

function PoopMonster.hideBelow(self: Boss)
	self.root.CanCollide = false
	self.pos = self.arena.home
	self.look = self.arena.intoRoom
	self.root.CFrame = CFrame.new(self.arena.home - Vector3.new(0, 14, 0))
end

--- Centre of the body at chest height, for reach checks.
function PoopMonster.center(self: Boss): Vector3
	return self.pos + Vector3.new(0, 4, 0)
end

--------------------------------------------------------------------------------
-- Action threads. Each attack runs in its own thread with a token; anything
-- that interrupts (stagger, a phase change, death) bumps the token and every
-- sleep in the old thread then reports false so it stops where it is.
--------------------------------------------------------------------------------

function PoopMonster.act(self: Boss, fn: (Boss, number) -> ())
	self.token += 1
	local my = self.token
	self.busy = true
	task.spawn(function()
		fn(self, my)
		if self.token == my and self.alive then
			self.busy = false
			self.tracking = false
			if self.awake then
				self:setState("idle", 0)
			end
		end
	end)
end

function PoopMonster.sleep(self: Boss, my: number, t: number): boolean
	task.wait(t)
	return self.alive and self.token == my
end

function PoopMonster.interrupt(self: Boss)
	self.token += 1
	self.busy = false
	self.tracking = false
	self.coreOpen = false
end

--------------------------------------------------------------------------------
-- Hurting players
--------------------------------------------------------------------------------

function PoopMonster.grounded(self: Boss, f: Arena.Fighter): boolean
	return f.root.Position.Y - self.arena.floorY < 4.4
end

function PoopMonster.hurt(_self: Boss, f: Arena.Fighter, damage: number, knock: Vector3?)
	if f.humanoid.Health <= 0 then
		return
	end
	if damage <= 0 then
		if knock then
			BossFX:FireClient(f.player, { k = "knock", v = knock })
		end
		return
	end
	f.player:SetAttribute("DeathCause", "poop")
	PlayerDamaged:FireClient(f.player, { damage = damage, source = "BathroomMonster" })
	f.humanoid:TakeDamage(damage)
	if f.humanoid.Health <= 0 then
		BadgeManager.award(f.player, GameConfig.BADGES.deathByPoop)
	end
	if knock then
		BossFX:FireClient(f.player, { k = "knock", v = knock })
	end
end

--------------------------------------------------------------------------------
-- Taking damage
--------------------------------------------------------------------------------

function PoopMonster.damage(self: Boss, player: Player, amount: number, core: boolean, kind: string, at: Vector3)
	if not self.alive or not self.awake or self.invulnerable then
		return
	end
	self.health -= amount
	self:fx({ k = "hit", pos = at, dmg = amount, core = core, kind = kind })

	if self.health <= 0 then
		self:die(player)
		return
	end
	local frac = self.health / self.maxHealth
	local wanted = if frac <= PHASE3_AT then 3 elseif frac <= PHASE2_AT then 2 else 1
	if wanted > self.phase then
		self.phase = wanted
		self:interrupt()
		self:act(self.attacks.rage)
	end
	self:syncStats()
end

function PoopMonster.stagger(self: Boss)
	self.poise = 0
	self:interrupt()
	self:act(function(boss: Boss, my: number)
		boss.coreOpen = true
		boss:setState("stagger", STAGGER_TIME)
		boss:fx({ k = "stagger" })
		boss:syncStats()
		boss:sleep(my, STAGGER_TIME)
		if boss.token == my then
			boss.coreOpen = false
			boss.poiseLockedUntil = now() + POISE_LOCK_AFTER
			boss.cooldownUntil = now() + 0.4
			boss:syncStats()
		end
	end)
end

--- A weapon use from InventoryManager's WeaponUsed bus.
function PoopMonster.onWeapon(self: Boss, player: Player, itemId: string, kind: string)
	if not self.alive then
		return
	end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not (root and root:IsA("BasePart")) then
		return
	end
	self.attacks.hitMinions(self, root, kind)
	if not self.awake then
		return
	end

	local to = self:center() - root.Position
	local dist = to.Magnitude
	local facing = if dist > 0.01 then root.CFrame.LookVector:Dot(to.Unit) else 1
	local hitAt = self:center() - to.Unit * 3

	if kind == "spray" then
		if dist > SPRAY_REACH or facing < 0.3 then
			return
		end
		local axe = itemId == "axe_spray"
		self.lastSpray = os.clock()
		if now() >= self.poiseLockedUntil and self.state ~= "stagger" and not self.invulnerable then
			self.poise = math.min(POISE_MAX, self.poise + (if axe then 55 else 34))
		end
		self:damage(player, if axe then 6 else 3, false, "spray", hitAt)
		if self.poise >= POISE_MAX and self.alive and not self.invulnerable then
			self:stagger()
		end
		self:syncStats()
	elseif kind == "melee" then
		if dist > MELEE_REACH or facing < 0.2 then
			return
		end
		local plunger = itemId == "plunger"
		local core = self.coreOpen
		local base = if plunger then 12 else 5
		self:damage(player, if core then base * 3 else base, core, "melee", hitAt)
	end
end

--------------------------------------------------------------------------------
-- Waking, sleeping, dying
--------------------------------------------------------------------------------

function PoopMonster.rescale(self: Boss)
	local n = math.max(1, #self.fighters)
	if n > self.scaledFor then
		local extra = HEALTH_PER_EXTRA_FIGHTER * (n - self.scaledFor)
		self.maxHealth += extra
		self.health += extra
		self.scaledFor = n
	end
end

function PoopMonster.die(self: Boss, killer: Player)
	if not self.alive then
		return
	end
	self.health = 0
	self:interrupt()
	self.alive = false
	self.invulnerable = true
	self.root.CanCollide = false
	self:syncStats()
	self.attacks.clearMinions(self, true)
	self:setState("dying", 2.8)
	self:fx({ k = "dying", pos = self:center() })
	task.delay(2.8, function()
		self:setState("dead", 0)
		self:fx({ k = "death", pos = self:center() })
		self.callbacks.onDefeated(killer)
		task.delay(1.5, function()
			self:destroy()
		end)
	end)
end

--- Leave the fight: sink back into the toilet if it's up, then remove it.
function PoopMonster.despawn(self: Boss)
	if not self.model.Parent then
		return
	end
	if self.alive and self.awake then
		self:interrupt()
		self.alive = false
		self:setState("submerge", 1.6)
		task.delay(1.7, function()
			self:destroy()
		end)
	else
		self.alive = false
		self:destroy()
	end
end

function PoopMonster.destroy(self: Boss)
	self.alive = false
	if self.conn then
		self.conn:Disconnect()
		self.conn = nil
	end
	self.attacks.clearMinions(self, false)
	self.model:Destroy()
	self.arena:restoreDoor()
end

function PoopMonster.setBeacon(self: Boss)
	if not self.alive or self.model:GetAttribute("Beacon") then
		return
	end
	self.model:SetAttribute("Beacon", true)
	local home = self.arena.home
	local beam = Instance.new("Part")
	beam.Name = "BossBeacon"
	beam.Anchored = true
	beam.CanCollide = false
	beam.CanQuery = false
	beam.CanTouch = false
	beam.CastShadow = false
	beam.Size = Vector3.new(3, 70, 3)
	beam.Position = home + Vector3.new(0, 35, 0)
	beam.Color = Color3.fromRGB(190, 220, 80)
	beam.Material = Enum.Material.Neon
	beam.Transparency = 0.55
	local light = Instance.new("PointLight")
	light.Color = beam.Color
	light.Range = 20
	light.Brightness = 2
	light.Parent = beam
	beam.Parent = self.model
end

--------------------------------------------------------------------------------
-- Per-frame
--------------------------------------------------------------------------------

function PoopMonster.chooseTarget(self: Boss): Arena.Fighter?
	local best, bestDist = nil, math.huge
	for _, f in self.fighters do
		local d = flat(f.root.Position - self.pos).Magnitude
		if d < bestDist then
			best, bestDist = f, d
		end
	end
	return best
end

function PoopMonster.step(self: Boss, dt: number)
	if not self.model.Parent then
		self:destroy()
		return
	end
	self.fighters = if self.alive then self.arena:fighters() else {}
	self.attacks.stepHazards(self, dt)
	if not self.alive then
		return
	end

	-- the stagger meter drains once the spraying stops
	if self.poise > 0 and os.clock() - self.lastSpray > POISE_HOLD and self.state ~= "stagger" then
		local before = math.floor(self.poise + 0.5)
		self.poise = math.max(0, self.poise - POISE_DECAY * dt)
		if math.floor(self.poise + 0.5) ~= before then
			self.model:SetAttribute("Poise", math.floor(self.poise + 0.5))
		end
	end
	local locked = now() < self.poiseLockedUntil
	if self.model:GetAttribute("PoiseLocked") ~= locked then
		self.model:SetAttribute("PoiseLocked", locked)
	end

	if not self.awake then
		if self.health < self.maxHealth then
			self.health = math.min(self.maxHealth, self.health + DORMANT_REGEN * dt)
		end
		if #self.fighters > 0 and not self.busy then
			self:rescale()
			self:act(self.attacks.emerge)
		end
		return
	end

	if #self.fighters == 0 then
		self.emptyFor += dt
		if self.emptyFor > LEAVE_GRACE and not self.busy then
			self:act(self.attacks.submerge)
		end
		return
	end
	self.emptyFor = 0
	self:rescale()

	self.target = self:chooseTarget()
	local target = self.target
	if not target then
		return
	end
	local to = flat(target.root.Position - self.pos)
	local dist = to.Magnitude

	if self.busy then
		if self.tracking and dist > 0.1 then
			self:turnToward(to.Unit, dt, 5)
			self:place()
		end
		return
	end

	-- close in to striking distance, always facing the target
	if dist > 0.1 then
		self:turnToward(to.Unit, dt, 4)
	end
	if dist > 6.5 then
		local step = math.min(dist - 6.5, self:phaseInfo().speed * dt)
		self.pos = self.arena:clamp(self.pos + to.Unit * step)
	end
	self:place()

	if now() >= self.cooldownUntil then
		local pick = self.attacks.choose(self, dist)
		if pick then
			self:act(pick)
		end
	end
end

function PoopMonster.turnToward(self: Boss, dir: Vector3, dt: number, rate: number)
	local k = 1 - math.exp(-rate * dt)
	local blended = self.look:Lerp(dir, k)
	if blended.Magnitude > 0.01 then
		self.look = blended.Unit
	end
end

return PoopMonster
