--!strict
--------------------------------------------------------------------------------
-- NGMIChoreo.luau
-- Performances for the night transition cast, as RigPose poses over time.
--
--   BREAKDOWN[role](t, actor)  the looping meltdown each hacker is in before
--                              anything happens: slam, headshake, unravel
--   CLIP[name]                 one-shot (or long looping) performances:
--                              { length, mutateAt?, fn(t, actor) }
--     unravel                  the first hacker turns
--     attack                   the turned one lunges and claws at a neighbour
--     struck                   the neighbour, attacked in the chair
--     horror                   the witness jumps up, watches, twitches and turns
--   idle(t, actor)             a turned NGMI waiting: breathing, head ticks and
--                              the odd clicker-style head-shake burst
--
-- Every function returns a Pose in degrees; see RigPose for the axis notes.
--------------------------------------------------------------------------------

local RigPose = require(script.Parent.RigPose)

type Pose = RigPose.Pose
-- `fit` is the body's solved contacts (Shared.NGMIFit); without one the
-- original blocky-rig angles are used.
export type Actor = { phase: number, rate: number, amp: number, seated: boolean?, fit: { [string]: Pose }? }

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

--- The arms of a contact on this actor's body, else the authored fallback.
local function arms(a: Actor, name: string, fallback: Pose): Pose
	local f = a.fit
	return (f and f[name]) or fallback
end

local ZERO = Vector3.zero
local function k(p: Pose, key: string): Vector3
	return p[key] or ZERO
end

local FALLBACK = {
	face = { rS = V(116, 0, -14), lS = V(116, 0, 14), rE = V(-104, 0, 0), lE = V(-104, 0, 0) },
	hug = { rS = V(74, 0, -40), lS = V(74, 0, 40), rE = V(-98, 0, 0), lE = V(-98, 0, 0) },
	-- measured on the blocky rig: both hands over the mouth
	mouth = { rS = V(62, 0, -75), lS = V(62, 0, 75), rE = V(-100, 0, 0), lE = V(-100, 0, 0) },
	guard = { rS = V(118, 0, -20), lS = V(126, 0, 30), rE = V(-110, 0, 0), lE = V(-96, 0, 0) },
} :: { [string]: Pose }

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
		local f = arms(a, "face", FALLBACK.face)
		-- the hands ride the head as it shakes
		return add(SEATED, {
			waist = V(30 + 3 * math.sin(t * 4 * a.rate), 4 * shake, 0),
			neck = V(22, 6 * shake, 3 * shake),
			rS = k(f, "rS") + V(0, 0, 5 * shake),
			lS = k(f, "lS") + V(0, 0, 5 * shake),
			rE = k(f, "rE"),
			lE = k(f, "lE"),
			rW = k(f, "rW"),
			lW = k(f, "lW"),
		})
	end,

	-- Arms wrapped around themselves, rocking, head down. Smaller and more
	-- inward than the rager: this is the one who breaks, so it has to build.
	unravel = function(t: number, a: Actor): Pose
		local rock = math.sin(t * 1.9 * a.rate + a.phase)
		local tremor = math.sin(t * 17 * a.rate + a.phase) * 1.8 * a.amp
		local h = arms(a, "hug", FALLBACK.hug)
		return {
			waist = V(18 + 5 * a.amp * math.abs(rock), 7 * rock, 5 * rock),
			neck = V(27 + tremor, -6 * rock, 0),
			rS = k(h, "rS") + V(3 * rock, 0, 0),
			lS = k(h, "lS") - V(3 * rock, 0, 0),
			rE = k(h, "rE"),
			lE = k(h, "lE"),
			rW = k(h, "rW"),
			lW = k(h, "lW"),
		}
	end,

} :: { [string]: (t: number, a: Actor) -> Pose }

--------------------------------------------------------------------------------
-- The turn and what follows it (each `Clip` is { length, mutateAt?, fn }; the
-- cutscene applies the mutation at `mutateAt`, under a flash)
--------------------------------------------------------------------------------

export type Clip = { length: number, mutateAt: number?, fn: (t: number, a: Actor) -> Pose }

NGMIChoreo.CLIP = {
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
			-- out of the hug it was rocking in, into the arch (arms flung wide),
			-- then the hunch with the arms hanging
			local h = arms(a, "hug", FALLBACK.hug)
			-- hug -> flung while the arch builds; once it peaks, flung -> hung
			local opened = t >= 0.8
			local held = if opened then 0 else 1 - arch
			local function arm(key: string, flung: Vector3, hung: Vector3): Vector3
				local from = if opened then flung else k(h, key):Lerp(flung, arch)
				return from:Lerp(hung, hunch)
			end
			return add({
				waist = V(62 * double - 36 * arch + 26 * hunch, 0, 0),
				neck = V(20 * double - 62 * arch + 14 * hunch, 0, 0) + rattle,
				rS = arm("rS", V(40, 0, 82), V(18, 0, 0)),
				lS = arm("lS", V(40, 0, -82), V(6, 0, 0)),
				rE = arm("rE", V(-10, 0, 0), V(-8, 0, 0)),
				lE = arm("lE", V(-10, 0, 0), V(-8, 0, 0)),
				rW = k(h, "rW") * held,
				lW = k(h, "lW") * held,
				rK = V(18 * double + 10 * hunch, 0, 0),
				lK = V(18 * double + 10 * hunch, 0, 0),
				rH = V(-14 * double, 0, 0),
				lH = V(-14 * double, 0, 0),
			}, spasm(a, t, 26 * arch + 8 * double, 14))
		end,
	},

	-- The turned hacker goes for the nearest one: a lunge with both arms up,
	-- then clawing down at them in alternating swipes, head rattling. Loops
	-- for as long as the scene holds on it.
	attack = {
		length = 30,
		fn = function(t: number, a: Actor): Pose
			local lunge = ramp(t, 0, 0.3)
			local maul = ramp(t, 0.3, 0.45)
			local swipe = math.sin(t * 13 + a.phase)
			return add({
				waist = V(10 + 28 * lunge + 8 * maul * math.abs(swipe), 0, 0),
				neck = V(-12 * lunge, 0, 0) + clickerShake(a, t, 0.8, 0.35, 20),
				rS = V(lerp(10, 118, lunge) + 42 * maul * swipe, 0, -10),
				lS = V(lerp(10, 118, lunge) - 42 * maul * swipe, 0, 10),
				rE = V(-30 - 34 * maul * math.max(0, swipe), 0, 0),
				lE = V(-30 - 34 * maul * math.max(0, -swipe), 0, 0),
				rH = V(-30 * lunge, 0, 0),
				lH = V(12 * lunge, 0, 0),
				rK = V(32 * lunge, 0, 0),
				lK = V(14 * lunge, 0, 0),
				rootPos = V(0, -0.4 * lunge, 0),
			}, spasm(a, t, 6, 10))
		end,
	},

	-- Attacked in the chair from their left: flinches away with the arms up
	-- over the face, thrashes, and goes limp, slumped over to the right.
	struck = {
		length = 30,
		fn = function(t: number, a: Actor): Pose
			local flinch = ramp(t, 0, 0.15)
			local limp = ramp(t, 1.3, 1.9)
			local live = 1 - limp
			local thrash = math.sin(t * 24 + a.phase) * live
			local g = arms(a, "guard", FALLBACK.guard)
			local up = flinch * live
			return add(SEATED, {
				waist = V(lerp(-16 * flinch, 46, limp), 22 * flinch * live, -10 * flinch * live - 18 * limp),
				neck = V(lerp(-24 * flinch, 40, limp), 30 * flinch * live + 8 * thrash, 10 * thrash),
				rS = k(g, "rS") * up + V(8, 0, -6) * limp + V(14 * thrash, 0, 0),
				lS = k(g, "lS") * up + V(6, 0, 6) * limp - V(14 * thrash, 0, 0),
				rE = k(g, "rE") * up + V(-6, 0, 0) * limp,
				lE = k(g, "lE") * up + V(-6, 0, 0) * limp,
				rW = k(g, "rW") * up,
				lW = k(g, "lW") * up,
			})
		end,
	},

	-- The witness. Jumps up out of the chair with both hands to the mouth and
	-- stands frozen, watching. Then the twitches start: the head jerks, faster
	-- and harder, the body seizes with the arms flung out, the mutation lands,
	-- and the head snaps up to look straight down the lens. The cutscene moves
	-- the pivot from the seat to standing height over the first 0.3 s.
	horror = {
		length = 4.6,
		mutateAt = 3.1,
		fn = function(t: number, a: Actor): Pose
			local seat = 1 - ramp(t, 0, 0.3)
			local recoil = ramp(t, 0.15, 0.45)
			local twitch = ramp(t, 1.4, 3.0)
			local seize = ramp(t, 2.9, 3.2) * (1 - ramp(t, 3.7, 4.1))
			local snap = ramp(t, 4.15, 4.25)
			-- hands at the mouth from the recoil until the seizure throws them off
			local hold = recoil * (1 - ramp(t, 2.9, 3.2))
			local jerk = if twitch > 0 then clickerShake(a, t, 0.55 - 0.25 * twitch, 0.18 + 0.1 * twitch, 30 * twitch) else Vector3.zero
			local m = arms(a, "mouth", FALLBACK.mouth)
			return add({
				rH = V(-80 * seat, 0, 0),
				lH = V(-80 * seat, 0, 0),
				rK = V(86 * seat + 8 * recoil, 0, 0),
				lK = V(86 * seat + 8 * recoil, 0, 0),
				waist = V(-12 * hold + 30 * seize * (1 - snap) + 12 * snap, 0, 0),
				neck = V(-8 * hold - 40 * seize * (1 - snap) + 8 * snap, 0, 0) + jerk,
				-- both hands over the mouth (solved on this body), thrown off
				-- by the seizure
				rS = k(m, "rS") * hold + V(30 * seize, 0, 60 * seize),
				lS = k(m, "lS") * hold + V(30 * seize, 0, -60 * seize),
				rE = k(m, "rE") * hold + V(-10, 0, 0) * (1 - hold),
				lE = k(m, "lE") * hold + V(-10, 0, 0) * (1 - hold),
				rW = k(m, "rW") * hold,
				lW = k(m, "lW") * hold,
			}, spasm(a, t, 4 + 22 * twitch * (1 - snap) + 20 * seize, 9 + 12 * twitch))
		end,
	},
} :: { [string]: Clip }

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

return NGMIChoreo
