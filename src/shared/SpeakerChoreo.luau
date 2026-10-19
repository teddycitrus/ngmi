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
--                             the room's reaction to the current line
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
	sniffer: boolean?, -- the one who checks their armpit on "deodorant"
	neighbourOfSniffer: number?, -- -1 / 1: which side the sniffer is on
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

-- clap() and laugh() are deltas added over SEAT_BASE.
local CLAP_HZ = 4.4

local function clap(t: number, m: Member): Pose
	local c = math.sin(t * CLAP_HZ * math.pi * 2 + m.seed)
	return {
		rS = V(24, 0, -18 + 12 * c),
		lS = V(24, 0, 18 - 12 * c),
		rE = V(-22, 0, 0),
		lE = V(-22, 0, 0),
		neck = V(-4, 0, 0),
	}
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
--- the talk starts), `tLine` seconds into that line.
function SpeakerChoreo.crowd(t: number, m: Member, line: number, tLine: number): Pose
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

	local joins = function(threshold: number): boolean
		return m.keen > threshold
	end

	if line == 1 then
		-- a round of applause for the welcome, a few whoops with a fist up
		local w = window(tLine, 0.2, 2.2, 0.25)
		if joins(0.3) then
			p = RigPose.blend(p, add(p, clap(t, m)), w)
		end
		if m.keen > 0.88 then
			p = add(p, { rS = V(120 * w, 0, 10 * w), rE = V(40 * w, 0, 0) })
		end
	elseif line == 2 then
		if joins(0.5) then
			p = add(p, { neck = V(8 * math.max(0, math.sin(tLine * 6 + s)), 0, 0) })
		end
	elseif line == 3 then
		-- "...before the second night is over." Groans, hands on heads.
		local w = window(tLine, 1.5, 3.3, 0.3)
		if m.keen > 0.72 then
			p = add(p, { rS = V(118 * w, 0, -10 * w), lS = V(118 * w, 0, 10 * w), rE = V(-60 * w, 0, 0), lE = V(-60 * w, 0, 0), neck = V(-22 * w, 0, 0), waist = V(-8 * w, 0, 0) })
		elseif joins(0.35) then
			p = add(p, { neck = V(10 * w, 12 * w * math.sin(tLine * 5 + s), 0) })
		end
	elseif line == 4 then
		-- everyone looks toward the mentors in the front row
		local w = window(tLine, 0.8, 3.3, 0.4)
		p = add(p, { neck = V(10 * w, 0, 0), waist = V(4 * w, 0, 0) })
	elseif line == 5 then
		-- the sprint mime gets a laugh
		local w = window(tLine, 0.7, 3.2, 0.3)
		if joins(0.4) then
			p = RigPose.blend(p, add(p, laugh(t, m)), w)
		end
	elseif line == 6 then
		if m.sniffer then
			-- lifts an arm and checks
			local w = window(tLine, 1.7, 3.3, 0.25)
			p = add(p, { lS = V(40 * w, 0, -118 * w), lE = V(-60 * w, 0, 0), neck = V(32 * w, 52 * w, 14 * w), waist = V(6 * w, 20 * w, 12 * w) })
		elseif m.neighbourOfSniffer then
			-- the people beside them lean away and crack up
			local w = window(tLine, 2.0, 3.3, 0.3)
			local side = m.neighbourOfSniffer :: number
			p = add(p, add(RigPose.scale(laugh(t, m), w), { waist = V(0, 0, 10 * w * side), neck = V(0, -30 * w * side, 0) }))
		elseif joins(0.8) then
			local w = window(tLine, 2.2, 3.3, 0.3)
			p = RigPose.blend(p, add(p, laugh(t, m)), w * 0.7)
		end
	elseif line == 7 then
		-- "Good luck, hackers!" Big applause, fists in the air.
		local w = window(tLine, 1.3, 6, 0.3)
		if m.keen > 0.82 then
			p = RigPose.blend(p, add(SEAT_BASE, { rS = V(160, 0, 12), lS = V(150, 0, -14), rE = V(-20, 0, 0), lE = V(-30, 0, 0), waist = V(-6, 0, 0), neck = V(-14, 0, 0) }), w)
		elseif joins(0.12) then
			p = RigPose.blend(p, add(p, clap(t, m)), w)
		end
	end
	return p
end

--- Arm wave for the named mentors and judges in the front row. Layered over
--- their live sit animation, so only the arm and head move.
function SpeakerChoreo.wave(t: number, seed: number, w: number): Pose
	local s = math.sin(t * 9 + seed)
	return {
		rS = V(150 * w, 0, (14 + 22 * s) * w),
		rE = V(-30 * w, 0, 0),
		neck = V(-6 * w, 0, 0),
	}
end

return SpeakerChoreo
