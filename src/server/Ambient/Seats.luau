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

-- Relaxed seated postures (Shared.SeatPosture styles, solved per body), weighted.
local STYLES: { { string | number } } = {
	{ "phone", 26 },
	{ "lap", 18 },
	{ "clasped", 14 },
	{ "crossed", 16 },
	{ "knees", 12 },
	{ "talking", 14 },
}

-- At a table (the conference room): forearms on it, chin on a hand.
local TABLE_STYLES: { { string | number } } = {
	{ "deskRest", 34 },
	{ "chin", 22 },
	{ "crossed", 26 },
	{ "lap", 18 },
}

local function pickStyle(list: { { string | number } }): string
	local total = 0
	for _, e in list do
		total += e[2] :: number
	end
	local r = math.random() * total
	for _, e in list do
		r -= e[2] :: number
		if r <= 0 then
			return e[1] :: string
		end
	end
	return list[1][1] :: string
end

--- A table top in front of the seat, at working height above it, if any.
local function tableAhead(pos: Vector3, face: Vector3, seatTop: number, model: Instance): BasePart?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { model }
	local hit = workspace:Raycast(pos + face * 1.9 + V(0, 3, 0), V(0, -5, 0), params)
	if hit and hit.Instance:IsA("BasePart") then
		local rise = hit.Position.Y - seatTop
		if rise > 0.6 and rise < 1.6 then
			return hit.Instance
		end
	end
	return nil
end

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
	local face = if flat.Magnitude > 0.01 then flat.Unit else V(0, 0, -1)
	local pos = spot.cf.Position
	model:PivotTo(CFrame.lookAt(pos, pos + face))
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		root.Anchored = true
	end
	hum.EvaluateStateMachine = false
	spot.seat.Disabled = true
	model.Parent = folder

	local seat = spot.seat
	local seatTop = seat.Position.Y + seat.Size.Y / 2
	local furniture = seat:FindFirstAncestorOfClass("Model") or seat
	local tableTop = tableAhead(pos, face, seatTop, furniture)
	local style = pickStyle(if tableTop then TABLE_STYLES else STYLES)
	-- the spot sits along the seat; its front edge is the seat's
	local frontDist = seat.CFrame:PointToObjectSpace(pos).Z + seat.Size.Z / 2
	RigFactory.seatPosed(model, hum, CFrame.lookAt(pos, pos + face), style, {
		seatTop = seatTop,
		seatFront = pos + face * frontDist,
		ignore = { furniture },
		desk = tableTop,
	})
	if style == "phone" then
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
	local isUsed: { [Seat]: boolean } = {}
	local spots = collectSpots(taken)
	local count = math.floor(#spots * FILL + 0.5)
	for i = 1, count do
		local spot = spots[i]
		table.insert(models, spawnSitter(spot, folder))
		if not isUsed[spot.seat] then
			isUsed[spot.seat] = true
			table.insert(used, spot.seat)
		end
		if i % SPAWN_BATCH == 0 then
			task.wait()
		end
	end
	return models, used
end

return Seats
