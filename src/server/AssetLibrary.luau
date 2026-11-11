--!strict
--------------------------------------------------------------------------------
-- AssetLibrary.luau  (ModuleScript)
-- Single source of truth for every static model placed many times
-- (workstations, laptops, toilets, shelves...). MapBuilder and
-- AmbientPopulation CLONE these templates instead of building parts inline,
-- so re-modelling one template restyles every instance in the venue.
--
-- The procedural templates live in Venue/Furniture (Office, Lounge, Fixtures).
--
-- HOW TO REMODEL A TEMPLATE BY HAND (and keep your changes):
--   1. Press Play once. Each template appears under ServerStorage.AssetTemplates.
--   2. Stop. Copy the template you want (e.g. "Workstation") into Workspace and
--      edit it however you like in Studio.
--   3. Right-click it -> "Save to File..." and save it into this repo's
--      `assets/` folder as e.g. `assets/Workstation.rbxmx`.
--   4. Rojo syncs `assets/` into ReplicatedStorage.Assets. From then on the
--      AssetLibrary uses YOUR model (it prefers ReplicatedStorage.Assets.<name>
--      over the built-in template).
--
-- Keep a part named "Root" as the model's PrimaryPart at the model's floor-level
-- origin so it lines up when placed. Each Furniture module documents the
-- origin and the part names other scripts depend on.
--------------------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Furniture = script.Parent:WaitForChild("Venue"):WaitForChild("Furniture")
local Office = require(Furniture:WaitForChild("Office"))
local Lounge = require(Furniture:WaitForChild("Lounge"))
local Fixtures = require(Furniture:WaitForChild("Fixtures"))

local AssetLibrary = {}

local builders: { [string]: () -> Model } = {}
for _, set in { Office.builders, Lounge.builders, Fixtures.builders } do
	for name, fn in set do
		builders[name] = fn
	end
end

local cacheFolder: Folder? = nil
local templates: { [string]: Instance } = {}

local function cache(): Folder
	if cacheFolder and cacheFolder.Parent then
		return cacheFolder
	end
	local f = Instance.new("Folder")
	f.Name = "AssetTemplates"
	f.Parent = ServerStorage
	cacheFolder = f
	return f
end

--- Prefer a user model in ReplicatedStorage.Assets, else build the template.
--- The resolved template is parked in ServerStorage.AssetTemplates so it can
--- be grabbed and remodelled.
local function getTemplate(name: string): Instance?
	if templates[name] then
		return templates[name]
	end
	local tmpl: Instance? = nil
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local override = assets and assets:FindFirstChild(name)
	if override and (override:IsA("Model") or override:IsA("BasePart")) then
		tmpl = override:Clone()
	elseif builders[name] then
		tmpl = builders[name]()
	end
	if tmpl then
		tmpl.Parent = cache()
		templates[name] = tmpl
	end
	return tmpl
end

--- Clone an asset and (optionally) place it. Returns nil if the name is
--- unknown and has no user override.
function AssetLibrary.clone(name: string, pivot: CFrame?): Model?
	local tmpl = getTemplate(name)
	if not tmpl then
		return nil
	end
	local c = tmpl:Clone()
	if pivot then
		if c:IsA("Model") then
			c:PivotTo(pivot)
		elseif c:IsA("BasePart") then
			c.CFrame = pivot
		end
	end
	return c :: Model
end

--- Copy templates into ReplicatedStorage.<folderName> for client-only sets
--- (the night transition cutscene dresses its lounge from them). The copies
--- carry no CollectionService tags, so venue systems never pick them up, and
--- their Seats are disabled.
function AssetLibrary.publish(names: { string }, folderName: string)
	local CollectionService = game:GetService("CollectionService")
	local folder = ReplicatedStorage:FindFirstChild(folderName) or Instance.new("Folder")
	folder.Name = folderName
	for _, name in names do
		local c = if folder:FindFirstChild(name) then nil else AssetLibrary.clone(name)
		if c then
			for _, d in c:GetDescendants() do
				for _, tagName in CollectionService:GetTags(d) do
					CollectionService:RemoveTag(d, tagName)
				end
				if d:IsA("Seat") then
					d.Disabled = true
				end
			end
			c.Parent = folder
		end
	end
	folder.Parent = ReplicatedStorage
end

--- Drop the cached templates (used by the edit-mode preview so a rebuild
--- picks up template changes).
function AssetLibrary.reset()
	table.clear(templates)
	if cacheFolder then
		cacheFolder:Destroy()
		cacheFolder = nil
	end
end

return AssetLibrary
