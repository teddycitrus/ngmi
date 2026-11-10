--!strict
--------------------------------------------------------------------------------
-- SpeakerChoreo.luau
-- Body language for the DAY1 opening ceremony, as RigPose poses over time.
--
--   GESTURES[name]            a keyframed clip the organizer performs over one
--                             caption line (~3.4s). The server picks which one
--                             goes with which line.
--   talk(t, seed)             what rides on top of every gesture: head nods on
--                             the speech rhythm, scanning the room, weight
--                             shifting between feet
--   walk(gait)                legs for crossing the stage
--   crowd(t, member, line, tLine)  a seated audience member: idle fidget plus
--                             the room's reaction to the current line (or a
--                             chat with the neighbour), and the applause
--   idle(t, member)           sitting idle, the base every crowd pose builds on
--   wave(pose, t, seed, w)    a front-row mentor waving over `pose`
--
-- Poses are in RigPose's authoring convention (degrees).
--------------------------------------------------------------------------------

local RigPose = require(script.Parent.RigPose)

type Pose = RigPose.Pose
type Clip = RigPose.Clip

local SpeakerChoreo = {}

local V = Vector3.new
local noise = RigPose.noise
local add = RigPose.add

-- Hands loosely in front at chest height, how people stand when they talk.
local REST: Pose = {
	rS = V(16, 0, 6),
	lS = V(16, 0, -6),
	rE = V(-38, 0, 0),
	lE = V(-38, 0, 0),
}

local function k(t: number, pose: Pose, ease: string?): RigPose.Key
	return { t = t, pose = add(REST, pose), ease = ease }
end

SpeakerChoreo.GESTURES = {
	-- "Welcome to VesperHacks!" Arms thrown wide, chest up, then palms open.
	welcome = {
		length = 3.4,
		keys = {
			k(0, {}),
			k(0.35, { rS = V(48, 0, 62), lS = V(48, 0, -62), rE = V(24, 0, 0), lE = V(24, 0, 0), waist = V(-7, 0, 0), neck = V(-9, 0, 0) }, "snap"),
			k(1.5, { rS = V(54, 0, 58), lS = V(54, 0, -58), rE = V(20, 0, 0), lE = V(20, 0, 0), waist = V(-5, 0, 0), neck = V(-6, 0, 0) }),
			k(2.2, { rS = V(26, 0, 22), lS = V(26, 0, -22), rE = V(-22, 0, 0), lE = V(-22, 0, 0) }),
			k(3.4, {}),
		},
	},

	-- "Follow the glowing marker." Turns and points out over the room toward
	-- the doors, gives it a couple of little jabs, comes back.
	point = {
		length = 3.4,
		keys = {
			k(0, {}),
			k(0.4, { rS = V(84, 0, 46), rE = V(32, 0, 0), waist = V(0, -18, 0), neck = V(-4, -32, 0), lS = V(10, 0, -4) }, "snap"),
			k(1.0, { rS = V(92, 0, 44), rE = V(36, 0, 0), waist = V(0, -20, 0), neck = V(-6, -34, 0), lS = V(10, 0, -4) }),
			k(1.25, { rS = V(84, 0, 46), rE = V(32, 0, 0), waist = V(0, -20, 0), neck = V(-4, -34, 0), lS = V(10, 0, -4) }, "snap"),
			k(1.6, { rS = V(92, 0, 44), rE = V(36, 0, 0), waist = V(0, -18, 0), neck = V(-6, -30, 0), lS = V(10, 0, -4) }, "snap"),
			k(2.4, { rS = V(30, 0, 14), rE = V(-30, 0, 0), waist = V(0, -4, 0), neck = V(0, -8, 0) }),
			k(3.4, {}),
		},
	},

	-- "Code there... ship it before the second night." Mimes typing, then
	-- chops the air twice on the deadline.
	emphasis = {
		length = 3.4,
		keys = {
			k(0, {}),
			k(0.3, { rS = V(40, 0, -4), lS = V(40, 0, 4), rE = V(-22, 0, 0), lE = V(-22, 0, 0), waist = V(8, 0, 0), neck = V(10, 0, 0) }),
			k(0.45, { rS = V(43, 0, -4), lS = V(38, 0, 4), rE = V(-26, 0, 0), lE = V(-18, 0, 0), waist = V(8, 0, 0), neck = V(10, 0, 0) }),
			k(0.6, { rS = V(38, 0, -4), lS = V(43, 0, 4), rE = V(-18, 0, 0), lE = V(-26, 0, 0), waist = V(8, 0, 0), neck = V(10, 0, 0) }),
			k(0.75, { rS = V(43, 0, -4), lS = V(38, 0, 4), rE = V(-26, 0, 0), lE = V(-18, 0, 0), waist = V(8, 0, 0), neck = V(10, 0, 0) }),
			k(0.9, { rS = V(38, 0, -4), lS = V(43, 0, 4), rE = V(-18, 0, 0), lE = V(-26, 0, 0), waist = V(8, 0, 0), neck = V(10, 0, 0) }),
			k(1.5, { rS = V(78, 0, 12), rE = V(-70, 0, 0), waist = V(-4, 6, 0), neck = V(-4, 0, 0) }),
			k(1.75, { rS = V(44, 0, 10), rE = V(-2, 0, 0), waist = V(6, 6, 0), neck = V(10, 0, 0) }, "snap"),
			k(2.1, { rS = V(78, 0, 12), rE = V(-70, 0, 0), waist = V(-2, 6, 0), neck = V(-2, 0, 0) }),
			k(2.35, { rS = V(44, 0, 10), rE = V(-2, 0, 0), waist = V(8, 6, 0), neck = V(12, 0, 0) }, "snap"),
			k(3.4, {}),
		},
	},

	-- "Stuck?" A shrug with the palms up and the head cocked, then one arm
	-- sweeps the whole room: mentors and judges are everywhere.
	shrug_sweep = {
		length = 3.4,
		keys = {
			k(0, {}),
			k(0.35, { rS = V(24, 0, 30), lS = V(24, 0, -30), rE = V(-12, 0, 0), lE = V(-12, 0, 0), waist = V(0, 0, 5), neck = V(-4, 0, 14) }, "snap"),
			k(0.9, { rS = V(22, 0, 32), lS = V(22, 0, -32), rE = V(-46, 0, 0), lE = V(-46, 0, 0), waist = V(0, 0, 5), neck = V(-4, 0, 14) }),
			k(1.35, { rS = V(76, 0, -10), rE = V(-14, 0, 0), waist = V(0, 24, 0), neck = V(0, 26, 0) }),
			k(2.5, { rS = V(78, 0, 56), rE = V(-10, 0, 0), waist = V(0, -24, 0), neck = V(0, -28, 0) }),
			k(3.4, {}),
		},
	},

	-- "Hold Shift to sprint." Pumps the arms like a runner; the cutscene
	-- jogs her out from behind the lectern while she does it.
	sprint = {
		length = 3.4,
		loop = false,
		keys = (function()
			local keys = { k(0, {}) }
			for i = 1, 10 do
				local s = if i % 2 == 0 then 1 else -1
				table.insert(keys, k(0.15 + i * 0.26, {
					rS = V(40 + 48 * s, 0, 6),
					lS = V(40 - 48 * s, 0, -6),
					rE = V(-52, 0, 0),
					lE = V(-52, 0, 0),
					waist = V(12, -8 * s, 0),
				}))
			end
			table.insert(keys, k(3.4, {}))
			return keys
		end)(),
	},

	-- "Raid the supply closets." Counts the items off on one hand, then wafts
	-- a hand under the nose on the deodorant.
	count = {
		length = 3.4,
		keys = {
			k(0, {}),
			k(0.3, { lS = V(54, 0, 6), lE = V(-62, 0, 0), rS = V(40, 0, -18), rE = V(-44, 0, 0), neck = V(8, 6, 0) }),
			k(0.5, { lS = V(54, 0, 6), lE = V(-62, 0, 0), rS = V(46, 0, -20), rE = V(-52, 0, 0), neck = V(10, 6, 0) }, "snap"),
			k(0.8, { lS = V(54, 0, 6), lE = V(-62, 0, 0), rS = V(40, 0, -18), rE = V(-44, 0, 0), neck = V(2, 6, 0) }),
			k(1.0, { lS = V(54, 0, 6), lE = V(-62, 0, 0), rS = V(46, 0, -20), rE = V(-52, 0, 0), neck = V(10, 6, 0) }, "snap"),
			k(1.3, { lS = V(54, 0, 6), lE = V(-62, 0, 0), rS = V(40, 0, -18), rE = V(-44, 0, 0), neck = V(2, 6, 0) }),
			k(1.5, { lS = V(54, 0, 6), lE = V(-62, 0, 0), rS = V(46, 0, -20), rE = V(-52, 0, 0), neck = V(10, 6, 0) }, "snap"),
			k(2.0, { rS = V(64, 0, -6), rE = V(-88, 0, 0), neck = V(-6, -10, 0), waist = V(-4, 0, 0) }),
			k(2.25, { rS = V(64, 0, 10), rE = V(-82, 0, 0), neck = V(-8, -12, 0), waist = V(-4, 0, 0) }),
			k(2.5, { rS = V(64, 0, -6), rE = V(-88, 0, 0), neck = V(-6, -10, 0), waist = V(-4, 0, 0) }),
			k(2.75, { rS = V(64, 0, 10), rE = V(-82, 0, 0), neck = V(-8, -12, 0), waist = V(-4, 0, 0) }),
			k(3.4, {}),
		},
	},

	-- "Good luck, hackers!" Both fists up, a little hop, then a big wave.
	cheer = {
		length = 3.4,
		keys = {
			k(0, {}),
			k(1.2, { rS = V(30, 0, 20), lS = V(30, 0, -20), rE = V(-12, 0, 0), lE = V(-12, 0, 0) }),
			k(1.55, { rS = V(166, 0, 12), lS = V(166, 0, -12), rE = V(10, 0, 0), lE = V(10, 0, 0), waist = V(-8, 0, 0), neck = V(-12, 0, 0), rootPos = V(0, 0.35, 0) }, "snap"),
			k(1.8, { rS = V(160, 0, 14), lS = V(160, 0, -14), rE = V(4, 0, 0), lE = V(4, 0, 0), waist = V(-6, 0, 0), neck = V(-10, 0, 0) }),
			k(2.2, { rS = V(150, 0, 34), lS = V(20, 0, -8), rE = V(14, 0, 0), waist = V(-4, 0, 0), neck = V(-6, 0, 0) }),
			k(2.5, { rS = V(150, 0, 4), lS = V(20, 0, -8), rE = V(0, 0, 0), waist = V(-4, 0, 0), neck = V(-6, 0, 0) }),
			k(2.8, { rS = V(150, 0, 34), lS = V(20, 0, -8), rE = V(14, 0, 0), waist = V(-4, 0, 0), neck = V(-6, 0, 0) }),
			k(3.1, { rS = V(150, 0, 4), lS = V(20, 0, -8), rE = V(0, 0, 0), waist = V(-4, 0, 0), neck = V(-6, 0, 0) }),
			k(3.4, { rS = V(150, 0, 30), lS = V(20, 0, -8), rE = V(12, 0, 0) }),
		},
	},
} :: { [string]: Clip }

SpeakerChoreo.REST = REST

--- Talking overlay: nods on the speech rhythm, scanning across the room, and
--- a slow weight shift. Layered on every gesture.
function SpeakerChoreo.talk(t: number, seed: number): Pose
	-- syllable-ish beats: fast nods whose depth wanders
	local beat = math.sin(t * 7.3) * (0.5 + 0.5 * noise(seed, 1, t * 0.8))
	local scan = noise(seed, 2, t * 0.35) * 22
	local shift = math.sin(t * 0.9 + seed)
	return {
		neck = V(3 * beat, scan, 4 * noise(seed, 3, t * 0.5)),
		waist = V(1.5 * beat, scan * 0.35, 2.5 * shift),
		rootPos = V(0.12 * shift, 0, 0),
		rH = V(0, 0, 2 * shift),
		lH = V(0, 0, 2 * shift),
		rK = V(math.max(0, -shift) * 6, 0, 0),
		lK = V(math.max(0, shift) * 6, 0, 0),
	}
end

--- Legs for walking. `gait` is the stride phase in radians.
function SpeakerChoreo.walk(gait: number): Pose
	local s = math.sin(gait)
	return {
		rH = V(-26 * s, 0, 0),
		lH = V(26 * s, 0, 0),
		rK = V(math.max(0, s) * 40 + 6, 0, 0),
		lK = V(math.max(0, -s) * 40 + 6, 0, 0),
		rootPos = V(0, math.abs(math.cos(gait)) * 0.12, 0),
	}
end

--------------------------------------------------------------------------------
-- The audience
--------------------------------------------------------------------------------

export type Member = {
	seed: number,
	lean: number, -- -1 slouched back .. 1 perched forward
	phone: boolean, -- half-listening, eyes on their lap
	keen: number, -- 0..1, how readily they join a reaction
	chat: number?, -- -1 / 1: neck yaw sign toward the neighbour they chat with
	chatSeed: number?, -- shared by both halves of a pair, so they take turns
	chatLead: boolean?, -- which half of the pair speaks first
	clapShut: number?, -- shoulder roll that brings this body's palms together (fitClap)
}

local SEAT_BASE: Pose = {
	rH = V(-88, 0, 2),
	lH = V(-88, 0, -2),
	rK = V(88, 0, 0),
	lK = V(88, 0, 0),
	rS = V(28, 0, -4),
	lS = V(28, 0, 4),
	rE = V(-52, 0, 0),
	lE = V(-52, 0, 0),
}

-- Applause: shoulders raised 50, elbows at -60, and the shoulders rolled in
-- until the palms meet. Where they meet depends on the body (measured -43 to
-- -46 on most, -58 on the long-armed Realistic Man), so each actor's closing
-- roll is solved by fitClap; CLAP_SHUT is the fallback. The open end of the
-- swing is CLAP_SWING short of it.
local CLAP_SHUT = -47
local CLAP_SWING = 17
local CLAP_SHOULDER = 50
local CLAP_ELBOW = -60

local function clapArms(z: number): Pose
	return {
		rS = V(CLAP_SHOULDER, 0, z),
		lS = V(CLAP_SHOULDER, 0, -z),
		rE = V(CLAP_ELBOW, 0, 0),
		lE = V(CLAP_ELBOW, 0, 0),
	}
end

--- Solve the shoulder roll at which this actor's palms touch, into m.clapShut.
function SpeakerChoreo.fitClap(rig: RigPose.Rig, m: Member)
	local lh = rig.model:FindFirstChild("LeftHand")
	local rh = rig.model:FindFirstChild("RightHand")
	if not (lh and lh:IsA("BasePart") and rh and rh:IsA("BasePart")) then
		return
	end
	-- centres a hand's thickness apart is palm to palm; a little less presses
	local touch = (lh.Size.X + rh.Size.X) / 2 * 0.85
	local best, bestGap = CLAP_SHUT, math.huge
	for z = -30, -85, -1 do
		local pose = clapArms(z)
		local l, r = rig:handIn("l", pose), rig:handIn("r", pose)
		if not (l and r) then
			return
		end
		local gap = (l - r).Magnitude
		if gap <= touch then
			best = z
			break
		end
		if gap < bestGap then
			best, bestGap = z, gap
		end
	end
	m.clapShut = best
end

--- Both arms clapping, replacing whatever the arms were doing in `p`.
--- The swing is clipped at both ends, so the hands rest together for about a
--- fifth of each beat: a pure sine only touches for an instant, which a frame
--- (or the caller's smoothing) easily misses, and the hands never meet.
local function clapping(p: Pose, t: number, m: Member): Pose
	local hz = 3.3 + (m.seed % 1) * 0.9
	local c = math.cos((t * hz + m.seed) * math.pi * 2)
	local s = math.clamp(0.5 + 0.75 * c, 0, 1)
	local shut = m.clapShut or CLAP_SHUT
	local z = shut + CLAP_SWING * (1 - s)
	local out = table.clone(p)
	for key, v in clapArms(z) do
		out[key] = v
	end
	out.neck = (p.neck or Vector3.zero) * V(0.3, 0.3, 0.3) + V(-4, 0, 0)
	return out
end

--- Turned toward the neighbour, taking turns to talk: the speaker nods and
--- talks with one hand, the listener nods along now and then.
local function chatting(p: Pose, t: number, m: Member): Pose
	local side = m.chat or 1
	local seed = m.chatSeed or m.seed
	local turn = math.floor((t + seed) / 2.2) % 2 == 0
	local talking = if m.chatLead then turn else not turn
	local out = add(p, { waist = V(2, 9 * side, 0) })
	-- replaces the idle head, so nobody looks down at a phone mid-conversation
	local nod = if talking then 5 * math.sin(t * 6.5 + seed) else 4 * math.max(0, math.sin(t * 2.4 + m.seed))
	out.neck = V(4 + nod + 2 * noise(m.seed, 21, t * 0.6), 36 * side + 5 * noise(m.seed, 22, t * 0.4), 3 * side)
	if talking then
		-- talks with the hand on the partner's side, swung out toward them
		local outward = if side > 0 then -1 else 1
		out[if side > 0 then "lS" else "rS"] = V(38 + 8 * math.sin(t * 2.3 + seed), 0, (12 + 6 * math.sin(t * 3.1)) * outward)
		out[if side > 0 then "lE" else "rE"] = V(-78 + 14 * math.sin(t * 3.7 + seed), 0, 0)
	end
	return out
end

local function laugh(t: number, m: Member): Pose
	local shake = math.sin(t * 52 + m.seed)
	return {
		waist = V(-6 + 2.5 * shake, 0, 0),
		neck = V(-14 + 3 * shake, 6 * math.sin(m.seed), 0),
		rS = V(8, 0, -8),
		rE = V(-34, 0, 0),
	}
end

--- Window helper: 0..1..0 over [t0, t1] with `edge` second ramps.
local function window(t: number, t0: number, t1: number, edge: number): number
	if t < t0 or t > t1 then
		return 0
	end
	return math.min(1, (t - t0) / edge, (t1 - t) / edge)
end

--- A seated audience member at time `t`, during caption `line` (0 = before
--- the talk starts), `tLine` seconds into that line. The second return is the
--- applause weight: clapping is too fast for the crowd's usual pose smoothing,
--- so the caller eases harder while it is above 0.
function SpeakerChoreo.crowd(t: number, m: Member, line: number, tLine: number): (Pose, number)
	if m.chat then
		-- a pair talking among themselves through the speech; they still
		-- laugh at the sprint and join both rounds of applause
		local p = chatting(SpeakerChoreo.idle(t, m), t, m)
		local clapW = 0
		if line == 1 then
			clapW = window(tLine, 0.1, 2.6, 0.25)
		elseif line == 7 then
			clapW = window(tLine, 1.35, 6, 0.3)
		elseif line == 5 then
			p = add(p, RigPose.scale(laugh(t, m), window(tLine, 0.7, 3.2, 0.3)))
		end
		return RigPose.blend(p, clapping(p, t, m), clapW), clapW
	end
	local p = SpeakerChoreo.idle(t, m)
	local s = m.seed
	local clapW = 0
	if line == 1 then
		-- everyone applauds the welcome, for as long as the applause plays
		clapW = window(tLine, 0.1, 2.6, 0.25)
		p = RigPose.blend(p, clapping(p, t, m), clapW)
	elseif line == 2 then
		if m.keen > 0.5 then
			p = add(p, { neck = V(8 * math.max(0, math.sin(tLine * 6 + s)), 0, 0) })
		end
	elseif line == 3 then
		-- "...before the second night is over." Groans, hands on heads.
		local w = window(tLine, 1.5, 3.3, 0.3)
		if m.keen > 0.72 then
			p = add(p, { rS = V(118 * w, 0, -10 * w), lS = V(118 * w, 0, 10 * w), rE = V(-60 * w, 0, 0), lE = V(-60 * w, 0, 0), neck = V(-22 * w, 0, 0), waist = V(-8 * w, 0, 0) })
		elseif m.keen > 0.35 then
			p = add(p, { neck = V(10 * w, 12 * w * math.sin(tLine * 5 + s), 0) })
		end
	elseif line == 4 then
		-- everyone looks toward the mentors in the front row
		local w = window(tLine, 0.8, 3.3, 0.4)
		p = add(p, { neck = V(10 * w, 0, 0), waist = V(4 * w, 0, 0) })
	elseif line == 5 then
		-- the sprint mime gets a laugh
		local w = window(tLine, 0.7, 3.2, 0.3)
		if m.keen > 0.4 then
			p = RigPose.blend(p, add(p, laugh(t, m)), w)
		end
	elseif line == 6 then
		-- a few chuckle at the deodorant
		if m.keen > 0.8 then
			local w = window(tLine, 2.2, 3.3, 0.3)
			p = RigPose.blend(p, add(p, laugh(t, m)), w * 0.7)
		end
	elseif line == 7 then
		-- "Good luck, hackers!" The whole room applauds through the applause.
		clapW = window(tLine, 1.35, 6, 0.3)
		p = RigPose.blend(p, clapping(p, t, m), clapW)
	end
	return p, clapW
end

--- Sitting idle: breathing, a slow weight shift, the odd glance around, and
--- for the phone users, eyes on the screen in their lap.
function SpeakerChoreo.idle(t: number, m: Member): Pose
	local s = m.seed
	local breath = math.sin(t * 1.7 + s)
	local glance = math.max(0, noise(s, 9, t * 0.18) - 0.35) * 2.2 -- occasional
	local glanceSide = if noise(s, 10, t * 0.05) > 0 then 1 else -1

	local p: Pose = add(SEAT_BASE, {
		waist = V(4 + 10 * m.lean + 1.2 * breath, 0, 0),
		neck = V(
			(if m.phone then 34 else -2) + 3 * noise(s, 11, t * 0.4),
			7 * noise(s, 12, t * 0.3) + 45 * glance * glanceSide,
			3 * noise(s, 13, t * 0.25)
		),
	})
	if m.phone then
		p = add(p, { rS = V(-6, 0, 2), lS = V(-6, 0, -2), rE = V(-42, 0, 0), lE = V(-42, 0, 0) })
	end
	-- hands drift a little on the lap, so nobody sits frozen
	p = add(p, {
		rS = V(3 * noise(s, 14, t * 0.3), 0, 2 * noise(s, 15, t * 0.25)),
		lS = V(3 * noise(s, 16, t * 0.3), 0, 2 * noise(s, 17, t * 0.25)),
	})
	return p
end

--- Arm wave for the named mentors and judges in the front row: the right arm
--- up and waving, blended in by `w` over whatever the arms were doing.
function SpeakerChoreo.wave(p: Pose, t: number, seed: number, w: number): Pose
	local s = math.sin(t * 9 + seed)
	local up = table.clone(p)
	up.rS = V(150, 0, 14 + 22 * s)
	up.rE = V(-30, 0, 0)
	up.neck = (p.neck or Vector3.zero) + V(-6, 0, 0)
	return RigPose.blend(p, up, w)
end

return SpeakerChoreo
