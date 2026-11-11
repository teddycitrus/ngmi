--!strict
--------------------------------------------------------------------------------
-- Boss/Attacks.luau
-- The poop monster's moves, each run as an action thread by Boss/PoopMonster
-- (`boss:act(fn)`). Every sleep returns false once the move was interrupted.
-- States set here drive the client animation (client/Boss/Animate); BossFX
-- events carry the one-shot visuals (warning rings, globs, splats).
--
-- Also the hazards that outlive a move: sludge puddles and the phase 3
-- minions ("clogs"), stepped every frame from the boss's Heartbeat.
--------------------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")

local Attacks = {}

type Boss = any
type Fighter = { player: Player, root: BasePart, humanoid: Humanoid }

local UP = Vector3.yAxis

local function now(): number
	return workspace:GetServerTimeNow()
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function outward(from: Vector3, to: Vector3): Vector3
	local d = flat(to - from)
	return if d.Magnitude > 0.1 then d.Unit else Vector3.new(0, 0, 1)
end

--------------------------------------------------------------------------------
-- Choosing a move
--------------------------------------------------------------------------------

local function nearCount(boss: Boss, r: number): number
	local n = 0
	for _, f in boss.fighters do
		if flat(f.root.Position - boss.pos).Magnitude <= r then
			n += 1
		end
	end
	return n
end

--- The next move for this distance to the target, or nil to keep walking.
function Attacks.choose(boss: Boss, dist: number): ((Boss, number) -> ())?
	local t = now()
	local pick: string? = nil
	local r = math.random()
	if boss.phase >= 2 and t - boss.lastVortex > 18 and nearCount(boss, 17) > 0 and r < 0.45 then
		pick = "vortex"
	elseif boss.phase >= 3 and t - boss.lastSummon > 16 and #boss.minions < 4 and r < 0.75 then
		pick = "summon"
	elseif dist <= 9.5 then
		pick = if math.random() < 0.6 then "swipe" else "slam"
	elseif dist <= 15 then
		local q = math.random()
		pick = if q < 0.45 then "slam" elseif q < 0.8 then "spit" else nil
	else
		pick = if math.random() < 0.55 then "spit" else nil
	end
	if not pick then
		boss.cooldownUntil = t + 0.5
		return nil
	end
	-- never the same move three times running
	if pick == boss.lastAttack then
		boss.repeatCount += 1
		if boss.repeatCount >= 2 then
			pick = if pick == "spit" then "slam" else "spit"
			boss.repeatCount = 0
		end
	else
		boss.repeatCount = 0
	end
	boss.lastAttack = pick
	return (Attacks :: any)[pick]
end

local function finish(boss: Boss, my: number)
	if boss.token == my then
		boss.cooldownUntil = now() + boss:phaseInfo().gap
	end
end

--------------------------------------------------------------------------------
-- Entrance, exit, phase change
--------------------------------------------------------------------------------

function Attacks.emerge(boss: Boss, my: number)
	local arena = boss.arena
	boss.invulnerable = true
	boss.awake = true
	boss.pos = arena:emergePoint()
	boss.look = arena.intoRoom
	boss:place()
	boss:setState("emerge", 3.6)
	boss:syncStats()
	boss:fx({ k = "geyser", pos = arena.home })
	if not boss:sleep(my, 0.45) then
		return
	end
	arena:flingDoor()
	boss:fx({ k = "roar", big = true })
	if not boss:sleep(my, 3.15) then
		return
	end
	boss.root.CanCollide = true
	boss.invulnerable = false
	boss.cooldownUntil = now() + 0.8
end

function Attacks.submerge(boss: Boss, my: number)
	boss.invulnerable = true
	boss.root.CanCollide = false
	boss:setState("submerge", 1.6)
	if not boss:sleep(my, 1.7) then
		return
	end
	boss.awake = false
	boss:hideBelow()
	boss:setState("dormant", 0)
	boss:syncStats()
end

function Attacks.rage(boss: Boss, my: number)
	boss.invulnerable = true
	boss:setState("rage", 2.6, { Phase = boss.phase })
	boss:syncStats()
	boss:fx({ k = "phase", n = boss.phase })
	boss:fx({ k = "roar", big = true })
	if not boss:sleep(my, 1.15) then
		boss.invulnerable = false
		return
	end
	-- a blast that throws everyone back without hurting them
	local c = boss.pos
	boss:fx({ k = "wave", pos = c, r = 15, harmless = true })
	for _, f in boss.fighters do
		local d = flat(f.root.Position - c).Magnitude
		if d <= 15 then
			boss:hurt(f, 0, outward(c, f.root.Position) * 70 + UP * 35)
		end
	end
	boss:sleep(my, 1.45)
	boss.invulnerable = false
	finish(boss, my)
end

--------------------------------------------------------------------------------
-- Swipe: a wide backhand at whoever is in front
--------------------------------------------------------------------------------

local SWIPE_REACH = 10.5
local SWIPE_COS = math.cos(math.rad(72))

function Attacks.swipe(boss: Boss, my: number)
	boss.armSide = if boss.armSide == "R" then "L" else "R"
	local windup = 0.62 * boss:phaseInfo().windup
	boss.tracking = true
	boss:setState("swipeWind", windup, { Arm = boss.armSide })
	if not boss:sleep(my, windup) then
		return
	end
	boss.tracking = false
	boss:setState("swipeStrike", 0.6, { Arm = boss.armSide })
	boss:fx({ k = "whoosh", pos = boss:center() })
	for _, f in boss.fighters do
		local rel = flat(f.root.Position - boss.pos)
		if rel.Magnitude <= SWIPE_REACH and (rel.Magnitude < 2 or boss.look:Dot(rel.Unit) >= SWIPE_COS) then
			local side = boss.look:Cross(UP) * (if boss.armSide == "R" then -1 else 1)
			boss:hurt(f, 22, (rel.Unit + side * 0.6).Unit * 60 + UP * 30)
		end
	end
	boss:sleep(my, 0.6)
	finish(boss, my)
end

--------------------------------------------------------------------------------
-- Slam: both fists into the floor. Jump to clear the shockwave. It gets
-- stuck afterwards with its core open.
--------------------------------------------------------------------------------

local SLAM_RADIUS = 12
local WAVE2_RADIUS = 22

function Attacks.slam(boss: Boss, my: number)
	local windup = 1.05 * boss:phaseInfo().windup
	local at = boss.arena:clamp(boss.pos + boss.look * 3)
	boss:setState("slamWind", windup)
	boss:fx({ k = "slamWarn", pos = at, r = SLAM_RADIUS, t = windup })
	if not boss:sleep(my, windup) then
		return
	end
	local stuck = if boss.phase >= 3 then 1.5 else 1.9
	boss.coreOpen = true
	boss:setState("slamImpact", stuck)
	boss:syncStats()
	boss:fx({ k = "slam", pos = at, r = SLAM_RADIUS })
	for _, f in boss.fighters do
		local d = flat(f.root.Position - at).Magnitude
		if d <= SLAM_RADIUS and boss:grounded(f) then
			boss:hurt(f, 30, outward(at, f.root.Position) * 45 + UP * 40)
		end
	end
	if boss.phase >= 3 then
		task.delay(0.55, function()
			if not boss.alive then
				return
			end
			boss:fx({ k = "wave", pos = at, r = WAVE2_RADIUS })
			for _, f in boss.fighters do
				local d = flat(f.root.Position - at).Magnitude
				if d > SLAM_RADIUS - 1 and d <= WAVE2_RADIUS and boss:grounded(f) then
					boss:hurt(f, 18, outward(at, f.root.Position) * 35 + UP * 30)
				end
			end
		end)
	end
	local ok = boss:sleep(my, stuck)
	if ok then
		boss.coreOpen = false
		boss:syncStats()
	end
	finish(boss, my)
end

--------------------------------------------------------------------------------
-- Spit: lobs globs of sludge at everyone; each leaves a burning puddle
--------------------------------------------------------------------------------

local GLOB_FLIGHT = 0.85
local GLOB_RADIUS = 4.5
local PUDDLE_RADIUS = 3.6
local PUDDLE_LIFE = 7
local PUDDLE_DAMAGE = 5 -- per tick
local PUDDLE_TICK = 0.5

local function landing(boss: Boss, f: Fighter?, i: number): Vector3
	local b = boss.arena.bounds
	local p: Vector3
	if f then
		local v = f.root.AssemblyLinearVelocity
		p = f.root.Position + flat(v) * GLOB_FLIGHT * 0.55
	else
		p = boss.pos + boss.look * 10
	end
	if i > #boss.fighters then
		local a = math.random() * math.pi * 2
		p += Vector3.new(math.cos(a), 0, math.sin(a)) * (4 + math.random() * 5)
	end
	return Vector3.new(math.clamp(p.X, b.minX + 1.5, b.maxX - 1.5), boss.arena.floorY, math.clamp(p.Z, b.minZ + 1.5, b.maxZ - 1.5))
end

local function globImpact(boss: Boss, at: Vector3)
	if not boss.model.Parent then
		return
	end
	boss:fx({ k = "splat", pos = at, r = GLOB_RADIUS })
	boss:fx({ k = "puddle", pos = at, r = PUDDLE_RADIUS, life = PUDDLE_LIFE })
	table.insert(boss.puddles, { pos = at, r = PUDDLE_RADIUS, untilT = os.clock() + PUDDLE_LIFE })
	if not boss.alive then
		return
	end
	for _, f in boss.fighters do
		local d = flat(f.root.Position - at).Magnitude
		if d <= GLOB_RADIUS and f.root.Position.Y - at.Y < 6 then
			boss:hurt(f, 16, outward(at, f.root.Position) * 20 + UP * 18)
		end
	end
end

function Attacks.spit(boss: Boss, my: number)
	boss.tracking = true
	boss:setState("spitWind", 0.55)
	if not boss:sleep(my, 0.55) then
		return
	end
	local n = boss:phaseInfo().globs
	boss:setState("spitFire", n * 0.2 + 0.35)
	for i = 1, n do
		local f = if #boss.fighters > 0 then boss.fighters[(i - 1) % #boss.fighters + 1] else nil
		local to = landing(boss, f, i)
		local from = boss.pos + UP * 7 + boss.look * 3
		boss:fx({ k = "glob", from = from, to = to, t = GLOB_FLIGHT })
		task.delay(GLOB_FLIGHT, globImpact, boss, to)
		if not boss:sleep(my, 0.2) then
			return
		end
	end
	boss.tracking = false
	boss:sleep(my, 0.35)
	finish(boss, my)
end

--------------------------------------------------------------------------------
-- Vortex (phase 2+): the floor becomes a flushing bowl that drags players in
-- (clients pull their own character), then a flush blasts anyone at the centre.
--------------------------------------------------------------------------------

local VORTEX_RADIUS = 19
local VORTEX_TIME = 3.6
local FLUSH_RADIUS = 7.5

function Attacks.vortex(boss: Boss, my: number)
	boss.lastVortex = now()
	boss:setState("vortexWind", 0.9)
	boss:fx({ k = "roar" })
	if not boss:sleep(my, 0.9) then
		return
	end
	local strength = if boss.phase >= 3 then 11 else 9
	boss:setState("vortex", VORTEX_TIME)
	boss:fx({ k = "vortex", pos = boss.pos, r = VORTEX_RADIUS, t = VORTEX_TIME, strength = strength })
	if not boss:sleep(my, VORTEX_TIME) then
		return
	end
	boss:setState("flush", 0.9)
	boss:fx({ k = "flush", pos = boss.pos, r = FLUSH_RADIUS })
	for _, f in boss.fighters do
		if flat(f.root.Position - boss.pos).Magnitude <= FLUSH_RADIUS then
			boss:hurt(f, 30, outward(boss.pos, f.root.Position) * 40 + UP * 65)
		end
	end
	boss:sleep(my, 0.9)
	finish(boss, my)
end

--------------------------------------------------------------------------------
-- Summon (phase 3): spits out little clogs that waddle at players and burst
--------------------------------------------------------------------------------

local MINION_SPEED = 14
local MINION_LIFE = 14
local MINION_BURST = 3.2
local MINION_DAMAGE = 12

type Minion = { part: Part, pos: Vector3, born: number, alive: boolean }

local function spawnMinion(boss: Boss, at: Vector3)
	local part = Instance.new("Part")
	part.Name = "Clog"
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(2, 2, 2)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.CFrame = CFrame.new(at + UP)
	part.Parent = boss.model
	CollectionService:AddTag(part, "BossMinion")
	table.insert(boss.minions, { part = part, pos = at, born = os.clock(), alive = true })
end

local function burst(boss: Boss, m: Minion, harmful: boolean)
	if not m.alive then
		return
	end
	m.alive = false
	boss:fx({ k = "pop", pos = m.pos + UP })
	if harmful then
		for _, f in boss.fighters do
			if (f.root.Position - (m.pos + UP)).Magnitude <= MINION_BURST + 1 then
				boss:hurt(f, MINION_DAMAGE, outward(m.pos, f.root.Position) * 30 + UP * 25)
			end
		end
	end
	m.part:Destroy()
end

function Attacks.summon(boss: Boss, my: number)
	boss.lastSummon = now()
	boss:setState("summon", 1.2)
	if not boss:sleep(my, 0.6) then
		return
	end
	local count = math.min(3, 5 - #boss.minions)
	for i = 1, count do
		local a = (i / count) * math.pi * 2 + math.random() * 0.6
		local at = boss.arena:clamp(boss.pos + boss.look * 4 + Vector3.new(math.cos(a), 0, math.sin(a)) * 4)
		boss:fx({ k = "glob", from = boss.pos + UP * 7 + boss.look * 3, to = at, t = 0.5, minion = true })
		task.delay(0.5, function()
			if boss.alive then
				spawnMinion(boss, at)
			end
		end)
	end
	boss:sleep(my, 0.6)
	finish(boss, my)
end

--- Weapons pop any clog in front of the player within reach.
function Attacks.hitMinions(boss: Boss, root: BasePart, kind: string)
	local reach = if kind == "spray" then 14 else 8
	for _, m in boss.minions do
		local to = (m.pos + UP) - root.Position
		if m.alive and to.Magnitude <= reach and (to.Magnitude < 2.5 or root.CFrame.LookVector:Dot(to.Unit) > 0.25) then
			burst(boss, m, false)
		end
	end
end

function Attacks.clearMinions(boss: Boss, pop: boolean)
	for _, m in boss.minions do
		if pop then
			burst(boss, m, false)
		elseif m.alive then
			m.alive = false
			m.part:Destroy()
		end
	end
	table.clear(boss.minions)
end

--------------------------------------------------------------------------------
-- Per-frame hazards
--------------------------------------------------------------------------------

function Attacks.stepHazards(boss: Boss, dt: number)
	local clock = os.clock()

	-- puddles burn whoever stands in them, once per tick per player
	if #boss.puddles > 0 then
		for i = #boss.puddles, 1, -1 do
			if clock > boss.puddles[i].untilT then
				table.remove(boss.puddles, i)
			end
		end
		for _, f in boss.fighters do
			if (boss.puddleTick[f.player] or 0) <= clock and boss:grounded(f) then
				for _, p in boss.puddles do
					if flat(f.root.Position - p.pos).Magnitude <= p.r then
						boss.puddleTick[f.player] = clock + PUDDLE_TICK
						boss:hurt(f, PUDDLE_DAMAGE, nil)
						break
					end
				end
			end
		end
	end

	-- clogs waddle at the nearest player and burst on contact
	if #boss.minions > 0 then
		local b = boss.arena.bounds
		for i = #boss.minions, 1, -1 do
			local m: Minion = boss.minions[i]
			if not m.alive then
				table.remove(boss.minions, i)
				continue
			end
			if clock - m.born > MINION_LIFE then
				burst(boss, m, false)
				table.remove(boss.minions, i)
				continue
			end
			local best: Fighter? = nil
			local bestD = math.huge
			for _, f in boss.fighters do
				local d = flat(f.root.Position - m.pos).Magnitude
				if d < bestD then
					best, bestD = f, d
				end
			end
			if best then
				if bestD <= MINION_BURST then
					burst(boss, m, true)
					table.remove(boss.minions, i)
					continue
				end
				local dir = flat(best.root.Position - m.pos).Unit
				local p = m.pos + dir * math.min(bestD, MINION_SPEED * dt)
				m.pos = Vector3.new(math.clamp(p.X, b.minX + 1, b.maxX - 1), m.pos.Y, math.clamp(p.Z, b.minZ + 1, b.maxZ - 1))
				m.part.CFrame = CFrame.lookAt(m.pos + UP, m.pos + UP + dir)
			end
		end
	end
end

return Attacks
