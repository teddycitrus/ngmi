--!strict
--------------------------------------------------------------------------------
-- Cutscene/WorldIndex.luau
-- The workspace instances a cutscene switches off when it starts, kept in
-- sets fed by workspace.DescendantAdded, so a cutscene start no longer walks
-- the whole workspace (~30k venue parts plus the ambient rigs) for a handful.
--
--   hideTargets()  every BillboardGui named in HIDDEN_GUIS and every BasePart
--                  named in HIDDEN_PARTS in the workspace (CutsceneHide)
--   highlights()   every Highlight in the workspace (SceneHold)
--
-- The first call does the one full scan and starts listening. A name is
-- matched when the instance enters the workspace; DeskBeacon and NPCManager
-- name these before parenting them and never rename them.
--------------------------------------------------------------------------------

local WorldIndex = {}

WorldIndex.HIDDEN_GUIS = { DeskBeaconLabel = true, MutterBubble = true } :: { [string]: boolean }
WorldIndex.HIDDEN_PARTS = { DeskBeaconPillar = true } :: { [string]: boolean }

local targets: { [Instance]: boolean } = {}
local highlights: { [Instance]: boolean } = {}
local started = false

local function isTarget(d: Instance): boolean
	local name = d.Name
	return (WorldIndex.HIDDEN_GUIS[name] == true and d:IsA("BillboardGui"))
		or (WorldIndex.HIDDEN_PARTS[name] == true and d:IsA("BasePart"))
end

local function consider(d: Instance)
	if d:IsA("Highlight") then
		highlights[d] = true
	elseif isTarget(d) then
		targets[d] = true
	end
end

local function start()
	if started then
		return
	end
	started = true
	for _, d in workspace:GetDescendants() do
		consider(d)
	end
	workspace.DescendantAdded:Connect(consider)
end

--- The members of `set` still in the workspace that pass `keep`; the ones
--- that left are dropped (they are added again if they come back).
local function live(set: { [Instance]: boolean }, keep: ((Instance) -> boolean)?): { Instance }
	local out: { Instance } = {}
	for inst in set do
		if not inst:IsDescendantOf(workspace) then
			set[inst] = nil
		elseif not keep or keep(inst) then
			table.insert(out, inst)
		end
	end
	return out
end

function WorldIndex.hideTargets(): { Instance }
	start()
	return live(targets, isTarget)
end

function WorldIndex.highlights(): { Highlight }
	start()
	return live(highlights) :: any
end

return WorldIndex
