--!strict
--------------------------------------------------------------------------------
-- Objectives/ObjectivePlan.luau
-- What ObjectivesUI shows each phase. The list is generated per phase from a
-- plan of anchors (always first), a pool of required tasks, and optional bonus
-- tasks that are randomly included and shuffled, so no two runs read exactly
-- the same. Each coding phase also has a gated final task that stays hidden
-- until every required task is done.
--------------------------------------------------------------------------------

local ObjectivePlan = {}

export type Objective = {
	id: string,
	text: string,
	completed: boolean,
	dynamicText: string?,
	optional: boolean, -- bonus task: shown but does NOT block the gated final task
	gated: boolean, -- the final coding task: hidden until all required tasks are done
	revealed: boolean, -- a gated task becomes revealed once unlocked
	passive: boolean, -- headline/end-of-phase task (e.g. SURVIVE): shown but does NOT block the gate
}

type ObjDef = { id: string, text: string, passive: boolean? }

-- Per-phase plan that procedural generation draws from:
--   anchors : always shown, in order, at the top
--   pool    : required tasks; shuffled in after the anchors
--   bonus   : optional tasks; each is randomly included, then shuffled in
--   final   : the gated final coding task, revealed only once everything
--             required (anchors + pool) is complete
type PhasePlan = {
	anchors: { ObjDef },
	pool: { ObjDef },
	bonus: { ObjDef },
	final: ObjDef?,
}

local PHASE_PLAN: { [number]: PhasePlan } = {
	[1] = {
		anchors = { { id = "find_desk", text = "Find your desk" } },
		pool = { { id = "talk_npcs", text = "Meet the staff (0/2)" } },
		bonus = {},
		final = nil,
	},
	[2] = {
		anchors = { { id = "code_wave1", text = "Coding sprint I: reach 50%" } },
		pool = {
			{ id = "collect_items", text = "Scavenge 3 supplies (0/3)" },
			{ id = "explore_rooms", text = "Explore all 3 floors (0/3)" },
		},
		bonus = {
			{ id = "poop_monster", text = "Bonus: defeat the Bathroom Monster" },
			{ id = "fix_computer", text = "Bonus: fix a frozen PC" },
			{ id = "chair_hoarder", text = "Bonus: hoard folding chairs (0/4)" },
		},
		final = { id = "code_wave2", text = "Ship it: finish your project (100%)" },
	},
	[3] = {
		anchors = { { id = "survive", text = "SURVIVE until dawn", passive = true } },
		pool = {
			{ id = "repair_panels", text = "Restore the power: fix panels" },
			{ id = "repair_servers", text = "Repair the servers" },
		},
		bonus = {},
		final = { id = "keep_coding", text = "Recompile: finish your project" },
	},
	[4] = {
		anchors = { { id = "present", text = "Present your project" } },
		pool = {},
		bonus = {},
		final = nil,
	},
}

local function shuffle<T>(list: { T }): { T }
	for i = #list, 2, -1 do
		local j = math.random(i)
		list[i], list[j] = list[j], list[i]
	end
	return list
end

local function makeObjective(def: ObjDef, optional: boolean, gated: boolean): Objective
	return {
		id = def.id,
		text = def.text,
		completed = false,
		dynamicText = nil,
		optional = optional,
		gated = gated,
		revealed = not gated, -- non-gated objectives are visible immediately
		passive = def.passive == true,
	}
end

--- Build a fresh, procedurally-ordered objective list for a phase.
function ObjectivePlan.generate(phase: number): { Objective }
	local plan = PHASE_PLAN[phase]
	if not plan then
		return {}
	end

	local out: { Objective } = {}

	-- Anchors first, in their defined order.
	for _, def in plan.anchors do
		table.insert(out, makeObjective(def, false, false))
	end

	-- Required pool + a random subset of bonus tasks, shuffled together so the
	-- middle of the list reads differently each run.
	local middle: { Objective } = {}
	for _, def in plan.pool do
		table.insert(middle, makeObjective(def, false, false))
	end
	for _, def in plan.bonus do
		if math.random() < 0.65 then -- ~65% chance each bonus shows up
			table.insert(middle, makeObjective(def, true, false))
		end
	end
	shuffle(middle)
	for _, obj in middle do
		table.insert(out, obj)
	end

	-- The gated final coding task lives at the end of the list but stays hidden
	-- until everything required is done.
	if plan.final then
		table.insert(out, makeObjective(plan.final, false, true))
	end

	return out
end

return ObjectivePlan
