--!strict
--------------------------------------------------------------------------------
-- NGMI/Poses.luau
-- The pose pieces NGMIAnimator layers each frame: gait (stalk, sprint),
-- stance, tremor, the head rattle, mirroring and blending, and the attack
-- keys. All return RigPose poses in degrees; nothing here touches a rig.
--------------------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RigPose = require(Shared:WaitForChild("RigPose"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local NGMIVoice = require(script.Parent.Parent:WaitForChild("NGMIVoice"))

type Pose = RigPose.Pose
local V = Vector3.new
local add = RigPose.add
local noise = RigPose.noise

local WINDUP: { [string]: number } = GameConfig.NGMI.attackWindup
local STRIKE: { [string]: number } = GameConfig.NGMI.attackStrike
local RECOVER_LENGTH = 0.45

export type Rig = {
	model: Model,
	root: BasePart,
	rig: RigPose.Rig,
	voice: NGMIVoice.Voice?,
	seed: number,
	gait: number,
	head: Vector3, -- snapped head target (degrees)
	nextSnap: number,
	rattleAt: number,
	nextStumble: number,
	stumbleAt: number,
	stutterUntil: number,
	nextStutter: number,
	freezing: boolean,
	lastApply: number,
	state: string?,
	stateAt: number,
	attackKind: string?,
	attackAt: number,
	flinchAt: number,
}

local Poses = {}

Poses.RATTLE_LENGTH = 0.42

--------------------------------------------------------------------------------
-- Pose pieces
--------------------------------------------------------------------------------

function Poses.window(t: number, len: number): number
	if t < 0 or t > len then
		return 0
	end
	return math.sin(t / len * math.pi)
end

function Poses.tremor(r: Rig, t: number, deg: number, hz: number): Pose
	local function n(c: number): number
		return noise(r.seed, c, t * hz) * deg
	end
	return {
		waist = V(n(1), n(2), n(3)) * 0.4,
		neck = V(n(4), n(5), n(6)),
		rS = V(n(7), 0, n(8)),
		lS = V(n(9), 0, n(10)),
		rE = V(n(11), 0, 0),
		lE = V(n(12), 0, 0),
	}
end

--- The clicker head rattle, `t` seconds into a burst.
function Poses.rattle(t: number): Vector3
	local env = Poses.window(t, Poses.RATTLE_LENGTH)
	return V(math.sin(t * 55) * 8, math.sin(t * 71) * 30, math.sin(t * 63) * 18) * env
end

--- Limping stalk. `k` scales the stride with speed.
function Poses.stalk(r: Rig, k: number): Pose
	local g = r.gait
	local s = math.sin(g)
	local hitch = math.max(0, -s) ^ 2
	return {
		rH = V(-30 * s * k, 0, 3),
		lH = V(18 * s * k, 0, -4),
		rK = V((10 + 36 * math.max(0, math.cos(g))) * k + 6, 0, 0),
		lK = V((8 + 16 * math.max(0, -math.cos(g))) * k + 12, 0, 0),
		waist = V(24 + 4 * hitch * k, 8 * s * k, -6 * s * k),
		-- right arm curled dead against the chest, left swinging loose and late
		rS = V(36, 0, -16),
		rE = V(-104, 0, 0),
		rW = V(-30, 0, 0),
		lS = V(-6 + 16 * math.sin(g - 0.9) * k, 0, -6),
		lE = V(-14 - 12 * math.abs(math.sin(g - 0.9)) * k, 0, 0),
		neck = V(-14, 0, 0), -- head up off the hunch, looking ahead
		rootPos = V(0, -0.28 * hitch * k, 0),
	}
end

--- Bent-double sprint, arms flailing.
function Poses.sprint(r: Rig, k: number, t: number): Pose
	local g = r.gait
	local s = math.sin(g)
	return {
		rH = V(-52 * s * k, 0, 4),
		lH = V(52 * s * k, 0, -4),
		rK = V((20 + 62 * math.max(0, math.cos(g))) * k, 0, 0),
		lK = V((20 + 62 * math.max(0, -math.cos(g))) * k, 0, 0),
		waist = V(38 + 6 * math.abs(s), 10 * s, 0),
		rS = V(40 + 62 * math.sin(g + 0.4), 0, 34 + 14 * math.sin(t * 9)),
		lS = V(40 - 62 * math.sin(g + 0.4), 0, -34 - 14 * math.sin(t * 8)),
		rE = V(-36, 0, 0),
		lE = V(-48, 0, 0),
		neck = V(-30, 24 * noise(r.seed, 20, t * 3), 16 * noise(r.seed, 21, t * 2.4)),
		rootPos = V(0, -0.35 + 0.22 * math.abs(math.cos(g)), 0),
	}
end

--- Coiled, swaying crouch between strikes.
function Poses.stance(t: number): Pose
	local sway = math.sin(t * 3.1)
	return {
		rH = V(-26, 0, 8),
		lH = V(-18, 0, -8),
		rK = V(34, 0, 0),
		lK = V(28, 0, 0),
		waist = V(30, 10 * sway, 6 * sway),
		rS = V(64, 0, 34),
		lS = V(58, 0, -30),
		rE = V(-52, 0, 0),
		lE = V(-46, 0, 0),
		neck = V(-26, -8 * sway, 0),
		rootPos = V(0.25 * sway, -0.5, 0),
	}
end

function Poses.mirror(p: Pose): Pose
	local out: Pose = {}
	local swap = { rS = "lS", lS = "rS", rE = "lE", lE = "rE", rW = "lW", lW = "rW", rH = "lH", lH = "rH", rK = "lK", lK = "rK" }
	for key, v in p do
		local to = swap[key] or key
		if key == "rootPos" then
			out[to] = V(-v.X, v.Y, v.Z)
		else
			out[to] = V(v.X, -v.Y, -v.Z)
		end
	end
	return out
end

function Poses.blend3(a: Pose, b: Pose, u: number): Pose
	return RigPose.blend(a, b, u * u * (3 - 2 * u))
end

-- Right-hand swipe keys. Wind-up: arm drawn high over the shoulder, torso
-- loaded away. Strike: raked down across the body, torso snapping through.
local SWIPE_LOAD: Pose = {
	rS = V(158, 0, 52),
	rE = V(-74, 0, 0),
	lS = V(46, 0, -26),
	lE = V(-40, 0, 0),
	waist = V(14, -34, -10),
	neck = V(-20, 14, 0),
	rH = V(-20, 0, 6),
	lH = V(-30, 0, -6),
	rK = V(30, 0, 0),
	lK = V(36, 0, 0),
	rootPos = V(0, -0.4, 0.3),
}
local SWIPE_HIT: Pose = {
	rS = V(54, 0, -48),
	rE = V(-12, 0, 0),
	lS = V(30, 0, -18),
	lE = V(-60, 0, 0),
	waist = V(36, 38, 8),
	neck = V(-34, -18, 0),
	rH = V(-44, 0, 6),
	lH = V(-6, 0, -6),
	rK = V(40, 0, 0),
	lK = V(18, 0, 0),
	rootPos = V(0, -0.6, -0.5),
}
local LUNGE_LOAD: Pose = {
	rH = V(-62, 0, 10),
	lH = V(-54, 0, -10),
	rK = V(86, 0, 0),
	lK = V(80, 0, 0),
	waist = V(46, 0, 0),
	rS = V(-34, 0, 34),
	lS = V(-34, 0, -34),
	rE = V(-30, 0, 0),
	lE = V(-30, 0, 0),
	neck = V(-48, 0, 0),
	rootPos = V(0, -1.15, 0.2),
}
local LUNGE_HIT: Pose = {
	rH = V(18, 0, 4),
	lH = V(-56, 0, -4),
	rK = V(6, 0, 0),
	lK = V(40, 0, 0),
	waist = V(22, 0, 0),
	rS = V(104, 0, 16),
	lS = V(100, 0, -16),
	rE = V(-8, 0, 0),
	lE = V(-14, 0, 0),
	neck = V(-34, 0, 0),
	rootPos = V(0, 0.25, -0.6),
}

function Poses.attackPose(r: Rig, t: number, now: number): Pose?
	local kind = r.attackKind
	if not kind then
		return nil
	end
	local wind = WINDUP[kind] or 0.35
	local strike = STRIKE[kind] or 0.12
	local load, hit
	if kind == "lunge" then
		load, hit = LUNGE_LOAD, LUNGE_HIT
	elseif kind == "swipe_l" then
		load, hit = Poses.mirror(SWIPE_LOAD), Poses.mirror(SWIPE_HIT)
	else
		load, hit = SWIPE_LOAD, SWIPE_HIT
	end
	local base = Poses.stance(now)
	if t < wind then
		-- coil, trembling with it
		return add(Poses.blend3(base, load, math.min(1, t / (wind * 0.8))), Poses.tremor(r, now, 5, 14))
	elseif t < wind + strike then
		-- snap through: near-instant, the smoothing gets bypassed upstream
		return Poses.blend3(load, hit, math.min(1, (t - wind) / (strike * 0.6)))
	elseif t < wind + strike + RECOVER_LENGTH then
		local u = (t - wind - strike) / RECOVER_LENGTH
		return add(Poses.blend3(hit, base, u), { neck = Poses.rattle(t - wind - strike) })
	end
	return nil
end

Poses.SCREECH = {
	waist = V(-16, 0, 0),
	neck = V(-46, 0, 0),
	rS = V(-26, 0, 46),
	lS = V(-26, 0, -46),
	rE = V(-30, 0, 0),
	lE = V(-30, 0, 0),
	rH = V(-10, 0, 6),
	lH = V(-10, 0, -6),
	rK = V(14, 0, 0),
	lK = V(14, 0, 0),
}

Poses.FLINCH = {
	waist = V(-26, 0, 8),
	neck = V(-36, 18, 0),
	rS = V(132, 0, -26),
	lS = V(124, 0, 22),
	rE = V(-118, 0, 0),
	lE = V(-112, 0, 0),
	rK = V(24, 0, 0),
	lK = V(30, 0, 0),
	rootPos = V(0, -0.2, 0.5),
}

-- Arms up over the face, running.
Poses.COWER = {
	rS = V(126, 0, -24),
	lS = V(120, 0, 20),
	rE = V(-116, 0, 0),
	lE = V(-110, 0, 0),
	neck = V(14, 0, 0),
}

return Poses
