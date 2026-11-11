--!strict
--------------------------------------------------------------------------------
-- MapBuilder.server.luau
-- Builds the 3-floor hackathon venue for "Not Gonna Make It" at server start.
--
-- The venue itself lives in Venue/ (Builder is the entry point; Layout holds
-- every dimension). This script only decides between the procedural build and
-- a hand-edited copy.
--------------------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local Builder = require(script.Parent.Venue.Builder)
local AssetLibrary = require(script.Parent.AssetLibrary)

for _, name in { "Baseplate", "SpawnLocation" } do
	local existing = workspace:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end
end

local t0 = os.clock()

-- Furniture the client-side night transition cutscene dresses its lounge with.
AssetLibrary.publish({
	"Couch",
	"Armchair",
	"CoffeeTable",
	"BistroTable",
	"BeanBag",
	"Plant",
	"PlantTall",
	"Vending",
	"WaterCooler",
	"Fridge",
	"FloorLamp",
	"Laptop",
	"TV",
	"Bookshelf",
	"TrashBin",
	"NoticeBoard",
}, "CutsceneProps")

-- HAND-EDIT THE WHOLE VENUE: save a finished map model as assets/Venue.rbxmx
-- (Rojo syncs it to ReplicatedStorage.Assets.Venue) and it is used verbatim
-- instead of the procedural build. Workflow: let it generate once, copy
-- Workspace.Map out of a play session, edit it, then "Save to File" into
-- assets/Venue.rbxmx.
local assets = ReplicatedStorage:FindFirstChild("Assets")
local prebuilt = assets and assets:FindFirstChild("Venue")
if prebuilt and prebuilt:IsA("Model") then
	local copy = prebuilt:Clone()
	copy.Name = "Map"
	copy.Parent = workspace
	print(string.format("[MapBuilder] Loaded hand-built Venue in %.2fs", os.clock() - t0))
	return
end

print("[MapBuilder] Building 3-floor hackathon venue...")
local map = Builder.build(workspace)

local n = 0
for _, d in map:GetDescendants() do
	if d:IsA("BasePart") then
		n += 1
	end
end
print(string.format("[MapBuilder] Venue built in %.2fs, %d parts", os.clock() - t0, n))
for _, tagName in GameConfig.TAGS do
	local c = #CollectionService:GetTagged(tagName)
	if c > 0 then
		print(string.format("  [Tag] %s: %d", tagName, c))
	end
end
