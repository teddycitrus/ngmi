--!strict
--------------------------------------------------------------------------------
-- Ambient/Seats.luau
-- Fills the venue's real Seats (couches, armchairs, stools, benches, beanbags,
-- meeting-room office chairs) with seated ambient hackers for
-- AmbientPopulation. Desk typists and sleepers are AmbientPopulation's own.
--
-- Every furniture template faces -Z and its Seat is unrotated in the model, so
-- the Seat's LookVector is the way a sitter faces. A seated R15 root sits about
-- 0.6 studs above the seat's top face (measured on the couch cushions).
--
-- Rigs are cheap statics: root anchored before parenting (a Seat would weld a
-- touching humanoid), the Seat disabled so it can't grab a player either, the
-- humanoid state machine off, and head tracking on only a share of them.
--------------------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local RigPose = require(ReplicatedStorage.Shared.RigPose)
local RigFactory = require(script.Parent.Parent.RigFactory)

local V = Vector3.new

-- Share of eligible seat spots that get someone; the rest stay free for players.
local FILL = 0.85
-- Share of sitters whose head follows a passing player (cost scales with it).
local HEAD_TRACK_SHARE = 0.4
local ROOT_ABOVE_SEAT = 0.6
local SPAWN_BATCH = 12 -- rigs per frame, so a full venue doesn't hitch

-- Seat name inside a furniture model -> lateral spots along it (studs, model X).
local SPOTS: { [string]: { [string]: { number } } } = {
	Couch = { CushionL = { 0 }, CushionR = { 0 } },
	Armchair = { Cushion = { 0 } },
	Stool = { Seat = { 0 } },
	Bench = { Seat = { -1.4, 1.4 } },
	BeanBag = { Bag = { 0 } },
	OfficeChair = { Seat = { 0 } },
}

-- Relaxed seated postures (RigPose conventions: waist/neck X+ forward,
-- shoulders X+ raise forward, elbows X- flex).
local POSES: { RigPose.Pose } = {
	-- scrolling a phone held low in both hands
	{ neck = V(28, 0, 0), rS = V(34, 0, -10), lS = V(34, 0, 10), rE = V(-92, 0, 0), lE = V(-92, 0, 0) },
	-- arms folded, leaning back
	{ waist = V(-8, 0, 0), rS = V(26, 0, -30), lS = V(26, 0, 30), rE = V(-112, 0, 0), lE = V(-112, 0, 0) },
	-- elbows on knees, hunched forward
	{ waist = V(26, 0, 0), neck = V(-10, 0, 0), rS = V(48, 0, -6), lS = V(48, 0, 6), rE = V(-70, 0, 0), lE = V(-70, 0, 0) },
	-- slumped back, head tipped up
	{ waist = V(-16, 0, 0), neck = V(-18, 0, 0), rS = V(8, 0, 8), lS = V(8, 0, -8) },
	-- mid-conversation, one hand gesturing
	{ neck = V(4, 0, 12), rS = V(40, 0, -20), rE = V(-80, 0, 0), lS = V(10, 0, 6), lE = V(-30, 0, 0) },
}

local Seats = {}

--- A phone in the right hand, screen toward the face, welded so it follows
--- the idle sway. Also used by AmbientPopulation's leaners.
function Seats.givePhone(model: Model)
	local hand = model:FindFirstChild("RightHand")
	local head = model:FindFirstChild("Head")
	if not (hand and hand:IsA("BasePart") and head and head:IsA("BasePart")) then
		return
	end
	local phone = Instance.new("Part")
	phone.Name = "Phone"
	phone.Size = V(0.5, 0.9, 0.08)
	phone.Color = Color3.fromRGB(24, 24, 28)
	phone.Material = Enum.Material.SmoothPlastic
	local screen = Instance.new("Part")
	screen.Name = "PhoneScreen"
	screen.Size = V(0.42, 0.8, 0.02)
	screen.Color = Color3.fromRGB(120, 190, 255)
	screen.Material = Enum.Material.Neon
	local at = hand.Position + (head.Position - hand.Position).Unit * 0.35
	phone.CFrame = CFrame.lookAt(at, head.Position) * CFrame.Angles(math.rad(-20), 0, 0)
	screen.CFrame = phone.CFrame * CFrame.new(0, 0, -0.05)
	for _, p in { phone, screen } do
		p.CanCollide = false
		p.CanTouch = false
		p.CanQuery = false
		p.Massless = true
		local w = Instance.new("WeldConstraint")
		w.Part0 = hand
		w.Part1 = p
		w.Parent = p
		p.Parent = model
	end
end

type Spot = { seat: Seat, cf: CFrame }

--- Every free seat spot, shuffled. `taken` holds seats other ambient code
--- already uses (couch sleepers), which are skipped.
local function collectSpots(taken: { [Instance]: boolean }): { Spot }
	local spots: { Spot } = {}
	local map = workspace:FindFirstChild("Map")
	if not map then
		return spots
	end
	for _, d in map:GetDescendants() do
		if d:IsA("Seat") and not taken[d] and not d.Disabled and d:GetAttribute("QuestId") == nil then
			local model = d:FindFirstAncestorOfClass("Model")
			local offsets = model and SPOTS[model.Name] and SPOTS[model.Name][d.Name]
			if offsets and not CollectionService:HasTag(d, GameConfig.TAGS.COUCH_SEAT) then
				local top = d.CFrame * CFrame.new(0, d.Size.Y / 2 + ROOT_ABOVE_SEAT, 0)
				for _, x in offsets do
					table.insert(spots, { seat = d, cf = top * CFrame.new(x, 0, 0) })
				end
			end
		end
	end
	for i = #spots, 2, -1 do
		local j = math.random(i)
		spots[i], spots[j] = spots[j], spots[i]
	end
	return spots
end

local function spawnSitter(spot: Spot, folder: Instance): Model
	local model, hum = RigFactory.create()
	RigFactory.applyHair(model, math.random(0, 999999))
	-- Face the seat's front, upright, regardless of any tilt in the furniture.
	local look = spot.seat.CFrame.LookVector
	local flat = V(look.X, 0, look.Z)
	local pos = spot.cf.Position
	model:PivotTo(CFrame.lookAt(pos, pos + (if flat.Magnitude > 0.01 then flat.Unit else V(0, 0, -1))))
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		root.Anchored = true
	end
	hum.EvaluateStateMachine = false
	spot.seat.Disabled = true
	model.Parent = folder
	RigFactory.sit(model, hum)

	local which = math.random(#POSES)
	RigPose.new(model):rebase(POSES[which])
	if which == 1 then
		task.defer(Seats.givePhone, model)
	end
	if math.random() < HEAD_TRACK_SHARE then
		RigFactory.enableHeadTracking(model, hum)
	end
	return model
end

--- Seat FILL of the free spots. Returns the models it placed (for clearing)
--- and the seats it disabled (to re-enable on clear).
function Seats.populate(folder: Instance, taken: { [Instance]: boolean }): ({ Model }, { Seat })
	local models: { Model } = {}
	local used: { Seat } = {}
	local spots = collectSpots(taken)
	local count = math.floor(#spots * FILL + 0.5)
	for i = 1, count do
		local spot = spots[i]
		table.insert(models, spawnSitter(spot, folder))
		if not table.find(used, spot.seat) then
			table.insert(used, spot.seat)
		end
		if i % SPAWN_BATCH == 0 then
			task.wait()
		end
	end
	return models, used
end

return Seats
