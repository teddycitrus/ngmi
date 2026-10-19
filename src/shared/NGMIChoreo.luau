--!strict
--------------------------------------------------------------------------------
-- NGMIChoreo.luau
-- Performances for the night transition cast, as RigPose poses over time.
--
--   BREAKDOWN[role](t, actor)  the looping meltdown each hacker is in before
--                              they turn (one role per actor, never reused)
--   TURN[role]                 a one-shot transformation unique to that hacker:
--                              { length, mutateAt, fn(t, actor) }. The cutscene
--                              applies the mutation at `mutateAt`, under a
--                              flash, while the body is mid-convulsion.
--   idle(t, actor)             a turned NGMI waiting: breathing, head ticks and
--                              the odd clicker-style head-shake burst
--   shamble(t, actor)          the staggered exit walk
--
-- Every function returns a Pose in degrees; see RigPose for the axis notes.
--------------------------------------------------------------------------------

local RigPose = require(script.Parent.RigPose)

type Pose = RigPose.Pose
export type Actor = { phase: number, rate: number, amp: number, seated: boolean? }

local NGMIChoreo = {}

local V = Vector3.new
local noise = RigPose.noise
local add = RigPose.add

local SEATED: Pose = {
	rH = V(-80, 0, 0),
	lH = V(-80, 0, 0),
	rK = V(86, 0, 0),
	lK = V(86, 0, 0),
}
NGMIChoreo.SEATED = SEATED

--- 0 before t0, 1 after t1, smoothstep between.
local function ramp(t: number, t0: number, t1: number): number
	local u = math.clamp((t - t0) / (t1 - t0), 0, 1)
	return u * u * (3 - 2 * u)
end

--- Like ramp, but quantised into `n` hard steps: a body moving in jerks.
local function steps(t: number, t0: number, t1: number, n: number): number
	local u = math.clamp((t - t0) / (t1 - t0), 0, 1)
	return math.floor(u * n + 0.0001) / n
end

local function lerp(a: number, b: number, u: number): number
	return a + (b - a) * u
end

--- Per-joint spasm noise, `deg` degrees at most, faster with `hz`.
local function spasm(a: Actor, t: number, deg: number, hz: number): Pose
	local s = a.phase * 13
	local function n(c: number): number
		return noise(s, c, t * hz) * deg
	end
	return {
		waist = V(n(1), n(2), n(3)) * 0.5,
		neck = V(n(4), n(5), n(6)),
		rS = V(n(7), 0, n(8)),
		lS = V(n(9), 0, n(10)),
		rE = V(n(11), 0, 0),
		lE = V(n(12), 0, 0),
	}
end

--- A clicker head-shake: short violent bursts of side-to-side rattle.
local function clickerShake(a: Actor, t: number, every: number, length: number, deg: number): Vector3
	local local_t = (t + a.phase * 3) % every
	if local_t > length then
		return Vector3.zero
	end
	local env = math.sin(local_t / length * math.pi)
	return V(math.sin(local_t * 47) * deg * 0.3, math.sin(local_t * 61) * deg, math.sin(local_t * 53) * deg * 0.6) * env
end

local function seatedIf(a: Actor, p: Pose): Pose
	if a.seated then
		return add(SEATED, p)
	end
	return p
end

--------------------------------------------------------------------------------
-- Breakdowns (before the turn)
--------------------------------------------------------------------------------

NGMIChoreo.BREAKDOWN = {
	-- Hunched at the keyboard, repeatedly slamming both fists on the desk.
	slam = function(t: number, a: Actor): Pose
		local down = math.sin(t * 5 * a.rate + a.phase) > 0.5
		-- arms nearly straight, so the fists come down on the desk top
		local s = (if down then 58 else 104) * a.amp
		return add(SEATED, {
			waist = V((if down then 26 else 10) * a.amp, 0, 0),
			neck = V((if down then 30 else 6) * a.amp, 0, 0),
			rS = V(s, 0, -6),
			lS = V(s, 0, 6),
			rE = V(if down then -12 else -40, 0, 0),
			lE = V(if down then -12 else -40, 0, 0),
		})
	end,

	-- Face buried in hands, shaking their head "no, no, no".
	headshake = function(t: number, a: Actor): Pose
		local shake = math.sin(t * 9 * a.rate + a.phase) * a.amp
		return add(SEATED, {
			waist = V(30 + 3 * math.sin(t * 4 * a.rate), 4 * shake, 0),
			neck = V(22, 22 * shake, 7 * shake),
			rS = V(116, 0, -14),
			lS = V(116, 0, 14),
			rE = V(-104, 0, 0),
			lE = V(-104, 0, 0),
		})
	end,

	-- Both hands clutching and yanking at their hair, head thrashing.
	hair = function(t: number, a: Actor): Pose
		local yank = math.sin(t * 7 * a.rate + a.phase) * a.amp
		local jit = math.sin(t * 23 * a.rate + a.phase) * 6 * a.amp
		local s = 112 + 12 * yank + jit
		return {
			rS = V(s, 0, -28),
			lS = V(s, 0, 28),
			rE = V(-108, 0, 0),
			lE = V(-108, 0, 0),
			neck = V(-4 + 10 * yank, 11 * math.sin(t * 5 * a.rate), 0),
			waist = V(7 * math.abs(yank), 0, 0),
		}
	end,

	-- Arms wrapped around themselves, rocking, head down. Smaller and more
	-- inward than the rager: this is the one who breaks, so it has to build.
	unravel = function(t: number, a: Actor): Pose
		local rock = math.sin(t * 1.9 * a.rate + a.phase)
		local tremor = math.sin(t * 17 * a.rate + a.phase) * 1.8 * a.amp
		return {
			waist = V(18 + 5 * a.amp * math.abs(rock), 7 * rock, 5 * rock),
			neck = V(27 + tremor, -6 * rock, 0),
			rS = V(74 + 4 * rock, 0, -40),
			lS = V(74 - 4 * rock, 0, 40),
			rE = V(-98, 0, 0),
			lE = V(-98, 0, 0),
		}
	end,

	-- Given up entirely: forehead flat on the desk, arms sprawled past it.
	facedesk = function(t: number, a: Actor): Pose
		local breath = math.sin(t * 1.5 * a.rate + a.phase) * a.amp
		return add(SEATED, {
			waist = V(62 + 1.6 * breath, 0, 0),
			neck = V(18 + 1.2 * breath, 0, 0),
			rS = V(98, 0, -32),
			lS = V(98, 0, 32),
			rE = V(-14, 0, 0),
			lE = V(-14, 0, 0),
		})
	end,

	-- Tipped back, arms hanging dead, staring at the ceiling.
	stare = function(t: number, a: Actor): Pose
		local sway = math.sin(t * 0.85 * a.rate + a.phase) * a.amp
		return add(SEATED, {
			waist = V(-11 + 2 * sway, 0, 0),
			neck = V(-36 + 3 * sway, 7 * sway, 0),
			rS = V(-9, 0, -7),
			lS = V(-9, 0, 7),
			rE = V(-12, 0, 0),
			lE = V(-12, 0, 0),
		})
	end,

	-- Hands locked on top of the head, pacing. The cutscene moves the pivot;
	-- this is the body. `stride` is the walk phase in radians.
	pace = function(t: number, a: Actor, stride: number?): Pose
		local sw = 30 * a.amp * math.sin(stride or t * 5.4)
		return {
			rS = V(150, 0, -18),
			lS = V(150, 0, 18),
			rE = V(-106, 0, 0),
			lE = V(-106, 0, 0),
			waist = V(12, 0, 0),
			rH = V(sw, 0, 0),
			lH = V(-sw, 0, 0),
			rK = V(math.max(0, sw) * 0.8, 0, 0),
			lK = V(math.max(0, -sw) * 0.8, 0, 0),
			neck = V(0, 10 * math.sin(t * 3 * a.rate + a.phase), 0),
		}
	end,
} :: { [string]: (t: number, a: Actor, extra: number?) -> Pose }

--------------------------------------------------------------------------------
-- Turns (one per role, each its own idea)
--------------------------------------------------------------------------------

export type Turn = { length: number, mutateAt: number, fn: (t: number, a: Actor) -> Pose }

NGMIChoreo.TURN = {
	-- One last two-fisted slam, a dead freeze on the desk, then the head turns
	-- far past where a neck stops while the shoulders hitch up unevenly and the
	-- body hauls itself upright in jerks.
	slam = {
		length = 2.8,
		mutateAt = 0.95,
		fn = function(t: number, a: Actor): Pose
			local raise = ramp(t, 0, 0.45)
			local hit = ramp(t, 0.45, 0.55)
			local rise = steps(t, 1.4, 2.6, 5)
			local turn = ramp(t, 1.2, 2.5)
			local tremble = ramp(t, 0.6, 1.3)
			local p: Pose = {
				waist = V(lerp(lerp(14, -6, raise), 32, hit) * (1 - rise) + 4 * rise, 0, 0),
				neck = V(lerp(10, 30, hit) * (1 - rise), 85 * turn, -32 * turn),
				rS = V(lerp(lerp(60, 165, raise), 56, hit), 0, -6 + 24 * rise),
				lS = V(lerp(lerp(60, 165, raise), 56, hit), 0, 6 - 6 * rise),
				rE = V(lerp(-20, -40, raise) * (1 - hit) - 10 * hit, 0, 0),
				lE = V(lerp(-20, -40, raise) * (1 - hit) - 10 * hit, 0, 0),
			}
			return add(add(SEATED, p), spasm(a, t, 10 * tremble * (1 - rise * 0.6), 9))
		end,
	},

	-- The "no, no, no" accelerates into a blur and stops dead. Then the hands
	-- peel away from the face, very slowly, and the head lolls back.
	headshake = {
		length = 2.8,
		mutateAt = 1.05,
		fn = function(t: number, a: Actor): Pose
			local spin = if t < 1.0 then t * t * 26 + t * 9 else 0
			local amp = if t < 1.0 then lerp(22, 34, t) else 0
			local peel = ramp(t, 1.25, 2.1)
			local loll = ramp(t, 2.0, 2.6)
			local shake = math.sin(spin * a.rate + a.phase)
			return add(SEATED, {
				waist = V(lerp(30, 8, peel) - 14 * loll, 4 * shake, 0),
				neck = V(lerp(22, 4, peel) - 52 * loll, amp * shake, 7 * shake + 24 * loll),
				rS = V(lerp(116, 6, peel), 0, -14),
				lS = V(lerp(116, 14, peel), 0, 14),
				rE = V(lerp(-104, -8, peel), 0, 0),
				lE = V(lerp(-104, -30, peel), 0, 0),
			})
		end,
	},

	-- Yanks at the hair, throws the arms up and arches back in a scream, folds
	-- straight down at the knees, then rises crooked with the head down until
	-- it snaps up at the very end.
	hair = {
		length = 3.0,
		mutateAt = 1.15,
		fn = function(t: number, a: Actor): Pose
			local yank = if t < 0.8 then math.sin(t * 30) * 14 else 0
			local arch = ramp(t, 0.75, 1.05) * (1 - ramp(t, 1.35, 1.6))
			local fold = ramp(t, 1.35, 1.65)
			local rise = steps(t, 1.8, 2.7, 4)
			local snap = ramp(t, 2.72, 2.8)
			local down = fold * (1 - rise * 0.75)
			return add({
				rS = V(lerp(112 + yank, 168, arch) * (1 - fold) + 14 * fold, 0, lerp(-28, 46, arch)),
				lS = V(lerp(112 - yank, 168, arch) * (1 - fold) + 4 * fold, 0, lerp(28, -46, arch)),
				rE = V(lerp(-108, -10, arch) * (1 - fold) - 30 * fold, 0, 0),
				lE = V(lerp(-108, -10, arch) * (1 - fold) - 12 * fold, 0, 0),
				waist = V(-26 * arch + 72 * down, 0, 8 * fold),
				neck = V(-48 * arch + 28 * fold * (1 - snap) - 12 * snap, 0, 0),
				rH = V(-55 * down, 0, 0),
				lH = V(-48 * down, 0, 0),
				rK = V(70 * down, 0, 0),
				lK = V(62 * down, 0, 0),
				rootPos = V(0, -1.3 * down, 0),
			}, spasm(a, t, 12 * arch + 4, 11))
		end,
	},

	-- The victim. Doubled over, then the back arches violently with the arms
	-- flung wide, then it folds slowly into the hunch while the head rattles in
	-- clicker bursts.
	unravel = {
		length = 3.0,
		mutateAt = 0.95,
		fn = function(t: number, a: Actor): Pose
			local double = ramp(t, 0, 0.45) * (1 - ramp(t, 0.55, 0.75))
			local arch = ramp(t, 0.55, 0.8) * (1 - ramp(t, 1.3, 2.4))
			local hunch = ramp(t, 1.3, 2.4)
			local rattle = if t > 1.6 then clickerShake(a, t, 0.7, 0.32, 26) else Vector3.zero
			return add({
				waist = V(62 * double - 36 * arch + 26 * hunch, 0, 0),
				neck = V(20 * double - 62 * arch + 14 * hunch, 0, 0) + rattle,
				rS = V(lerp(74, 40, arch) * (1 - hunch) + 18 * hunch, 0, lerp(-40, 82, arch) * (1 - hunch)),
				lS = V(lerp(74, 40, arch) * (1 - hunch) + 6 * hunch, 0, lerp(40, -82, arch) * (1 - hunch)),
				rE = V(lerp(-98, -10, arch) * (1 - hunch), 0, 0),
				lE = V(lerp(-98, -10, arch) * (1 - hunch), 0, 0),
				rK = V(18 * double + 10 * hunch, 0, 0),
				lK = V(18 * double + 10 * hunch, 0, 0),
				rH = V(-14 * double, 0, 0),
				lH = V(-14 * double, 0, 0),
			}, spasm(a, t, 26 * arch + 8 * double, 14))
		end,
	},

	-- Mid-stride the knee goes. The body folds over at the waist and hangs,
	-- arms dangling, then the spine snaps back upright one vertebra at a time
	-- and the head comes up last.
	pace = {
		length = 2.8,
		mutateAt = 0.8,
		fn = function(t: number, a: Actor): Pose
			local buckle = ramp(t, 0, 0.3)
			local fold = ramp(t, 0.3, 0.75)
			local spine = steps(t, 1.2, 2.2, 4)
			local head = ramp(t, 2.25, 2.33)
			local handsOff = ramp(t, 0, 0.4)
			local w = 88 * fold * (1 - spine) + 14 * spine
			return add({
				rS = V(lerp(150, 0, handsOff) + w * 0.9, 0, -8),
				lS = V(lerp(150, 0, handsOff) + w * 0.9, 0, 8),
				rE = V(lerp(-106, -12, handsOff), 0, 0),
				lE = V(lerp(-106, -20, handsOff), 0, 0),
				waist = V(w, 0, 0),
				neck = V(lerp(14, 58, fold) * (1 - head) - 12 * head, 0, 0),
				rK = V(62 * buckle * (1 - spine * 0.7), 0, 0),
				rH = V(-30 * buckle * (1 - spine * 0.7), 0, 0),
				lK = V(12 * fold, 0, 0),
				rootPos = V(0, -0.85 * buckle * (1 - spine * 0.7), 0),
			}, spasm(a, t, 6 + 10 * (1 - spine) * fold, 8))
		end,
	},

	-- Forehead still on the desk while the arms start twitching on their own,
	-- fingers drumming. Then the head lifts, slowly, with the neck turned
	-- ninety degrees the wrong way.
	facedesk = {
		length = 2.9,
		mutateAt = 0.75,
		fn = function(t: number, a: Actor): Pose
			local twitch = ramp(t, 0, 0.5) * (1 - ramp(t, 1.2, 1.6))
			local lift = ramp(t, 1.1, 2.6)
			local drum = math.sin(t * 38) * 9 * twitch
			return add(SEATED, add({
				waist = V(lerp(62, 18, lift), 0, 0),
				neck = V(lerp(18, -6, lift), 88 * lift, 38 * lift),
				rS = V(lerp(98, 40, lift) + drum, 0, -32),
				lS = V(lerp(98, 30, lift) - drum, 0, 32),
				rE = V(-14 - math.abs(drum) * 2, 0, 0),
				lE = V(-14 - math.abs(drum) * 2, 0, 0),
				rW = V(drum * 3, 0, 0),
				lW = V(-drum * 3, 0, 0),
			}, spasm(a, t, 16 * twitch, 18)))
		end,
	},

	-- Head drops all the way back in a silent scream, arms lifting, the body
	-- juddering in the chair. Then the head snaps forward to stare straight
	-- down the lens.
	stare = {
		length = 2.6,
		mutateAt = 0.6,
		fn = function(t: number, a: Actor): Pose
			local scream = ramp(t, 0, 0.35)
			local snap = ramp(t, 1.75, 1.82)
			local judder = ramp(t, 0.3, 0.6) * (1 - snap)
			return add(SEATED, add({
				waist = V(-11 - 8 * scream * (1 - snap) + 14 * snap, 0, 0),
				neck = V(lerp(-36, -68, scream) * (1 - snap) + 10 * snap, 0, 14 * snap),
				rS = V(-9 + 40 * scream * (1 - snap) + 12 * snap, 0, -7 + 30 * scream * (1 - snap)),
				lS = V(-9 + 40 * scream * (1 - snap) + 6 * snap, 0, 7 - 30 * scream * (1 - snap)),
				rE = V(-12 - 50 * scream * (1 - snap), 0, 0),
				lE = V(-12 - 50 * scream * (1 - snap), 0, 0),
			}, spasm(a, t, 14 * judder, 22)))
		end,
	},
} :: { [string]: Turn }

--------------------------------------------------------------------------------
-- After the turn
--------------------------------------------------------------------------------

function NGMIChoreo.idle(t: number, a: Actor): Pose
	local breath = math.sin(t * 2.1 * a.rate + a.phase)
	local p: Pose = {
		waist = V(10 + 4 * breath, 0, 0),
		neck = V(6, 0, 0) + clickerShake(a, t, 1.6 + a.rate, 0.35, 22),
		rS = V(6 + 3 * breath, 0, 0),
		lS = V(6 + 3 * breath, 0, 0),
	}
	return seatedIf(a, add(p, spasm(a, t, 4, 3)))
end

--- Staggered exit walk. `gait` is the stride phase in radians (driven by
--- distance so the feet don't skate), `t` the clock for the head.
function NGMIChoreo.shamble(t: number, gait: number, a: Actor): Pose
	local step = math.sin(gait)
	-- the ruined right leg takes weight with a drop through the hip
	local hitch = math.max(0, -step) ^ 2
	-- every few strides it lurches: the torso pitches and catches itself
	local lurch = math.max(0, math.sin(gait * 0.37 + a.phase)) ^ 8
	return {
		rH = V(28 * step - 14 * lurch, 0, 0),
		lH = V(-16 * step, 0, 0),
		rK = V(6 + 22 * hitch, 0, 0),
		lK = V(10 + 20 * math.max(0, step) + 12 * lurch, 0, 0),
		rS = V(14 + 6 * step + 30 * lurch, 0, -6),
		lS = V(4 - 10 * step + 18 * lurch, 0, 8),
		rE = V(-10 - 14 * math.abs(step), 0, 0),
		lE = V(-6 - 8 * math.abs(step), 0, 0),
		waist = V(10 + 22 * lurch + 4 * hitch, 6 * step, -5 * step),
		neck = V(4 * math.sin(t * 2.1), 12 * math.sin(t * 1.3 + a.phase), -6) + clickerShake(a, t, 1.9, 0.3, 24),
		rootPos = V(0, -0.26 * hitch - 0.3 * lurch, 0),
	}
end

return NGMIChoreo
