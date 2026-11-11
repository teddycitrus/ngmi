--!strict
--------------------------------------------------------------------------------
-- Cutscene/Encounter.luau
-- Choreography and set-finding for the Night 2 encounter cutscene
-- (NightEncounter.client): the staff member's performance, the NGMI's, and
-- the geometry the scene needs from wherever in the venue it happens to play
-- (a corner for the NGMI to come round, and an open line to run down).
--
-- Poses are RigPose degrees (see RigPose for the axis conventions).
--------------------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RigPose = require(Shared:WaitForChild("RigPose"))
local NGMIMutation = require(Shared:WaitForChild("NGMIMutation"))
local UITheme = require(Shared:WaitForChild("UITheme"))

type Pose = RigPose.Pose
local V = Vector3.new
local add = RigPose.add

local Encounter = {}

--------------------------------------------------------------------------------
-- The staff member
--------------------------------------------------------------------------------

--- Out of breath and frantic: chest heaving, hands going while they talk.
--- `glance` 0..1 turns the head and shoulders to look back over the left
--- shoulder.
function Encounter.talk(t: number, glance: number): Pose
	local heave = math.sin(t * 6.5)
	local g = glance
	-- hands kept low and in close: at conversation distance anything raised
	-- toward the player fills the lens
	return {
		waist = V(8 + 4 * heave, 8 * math.sin(t * 1.7) + 34 * g, 0),
		neck = V(-6 + 3 * math.sin(t * 5.2) - 6 * g, 12 * math.sin(t * 1.3) + 52 * g, 0),
		rS = V(14 + 10 * math.sin(t * 3.3), 0, -8),
		rE = V(-52 + 16 * math.sin(t * 3.3 + 1.1), 0, 0),
		lS = V(8 + 8 * math.sin(t * 2.4 + 2) - 10 * g, 0, 8),
		lE = V(-36 + 10 * math.sin(t * 2.4), 0, 0),
		rH = V(-4, 0, 3),
		lH = V(-2, 0, -3),
		rK = V(6, 0, 0),
		lK = V(6, 0, 0),
	}
end

--- Seized from behind: back arched, head thrown back, both arms flung out
--- toward the player.
function Encounter.grabbed(t: number): Pose
	local thrash = math.sin(t * 22)
	return {
		waist = V(-24, 6 * thrash, 4 * thrash),
		neck = V(-28 + 6 * thrash, 10 * thrash, 0),
		rS = V(104 + 10 * thrash, 0, -6),
		lS = V(98 - 10 * thrash, 0, 6),
		rE = V(-14, 0, 0),
		lE = V(-18, 0, 0),
		rH = V(-26, 0, 0),
		lH = V(12, 0, 0),
		rK = V(24, 0, 0),
		lK = V(8, 0, 0),
	}
end

--- Being hauled away backwards: heels dragging, arms clawing at the air.
function Encounter.dragged(t: number): Pose
	local claw = math.sin(t * 13)
	return {
		waist = V(-32, 4 * claw, 0),
		neck = V(-10, 14 * math.sin(t * 3), 0),
		rS = V(112 + 26 * claw, 0, -12),
		lS = V(106 - 26 * claw, 0, 12),
		rE = V(-30 - 20 * math.max(0, claw), 0, 0),
		lE = V(-30 - 20 * math.max(0, -claw), 0, 0),
		rH = V(-48, 0, 4),
		lH = V(-38, 0, -4),
		rK = V(12, 0, 0),
		lK = V(22, 0, 0),
	}
end

--------------------------------------------------------------------------------
-- The NGMI
--------------------------------------------------------------------------------

--- The hunched limping stalk, `g` the gait phase in radians. `tw` is the
--- NGMI's style twist (NGMIMutation.twistOf), the original one by default.
function Encounter.stalk(g: number, t: number, tw: Pose?): Pose
	local s = math.sin(g)
	local hitch = math.max(0, -s) ^ 2
	return add({
		rH = V(-30 * s, 0, 3),
		lH = V(18 * s, 0, -4),
		rK = V(16 + 36 * math.max(0, math.cos(g)), 0, 0),
		lK = V(20 + 16 * math.max(0, -math.cos(g)), 0, 0),
		waist = V(28 + 4 * hitch, 8 * s, -6 * s),
		rS = V(36, 0, -16),
		rE = V(-104, 0, 0),
		lS = V(-6 + 16 * math.sin(g - 0.9), 0, -6),
		lE = V(-14 - 12 * math.abs(math.sin(g - 0.9)), 0, 0),
		neck = V(-18, 18 * math.sin(t * 0.9), 0),
		rootPos = V(0, -0.28 * hitch, 0),
	}, tw or NGMIMutation.TWIST)
end

--- Hands clamped on the shoulders of someone standing in front of it, at arm's
--- length: torso pulled upright (cancelling most of the twist's hunch) and the
--- head held back, so nothing of it passes through them. Only the arms reach.
function Encounter.grab(t: number, twist: Pose?): Pose
	local jerk = math.sin(t * 19)
	local tw = twist or NGMIMutation.TWIST
	local Z = Vector3.zero
	return {
		waist = V(-12, 0, 0) + (tw.waist or Z),
		neck = V(-32, 6 * jerk, 4 * jerk) + (tw.neck or Z),
		rS = V(86, 0, 6),
		lS = V(86, 0, -6),
		rE = V(-12, 0, 0),
		lE = V(-12, 0, 0),
		rW = V(-30, 0, 0),
		lW = V(-30, 0, 0),
		rH = V(-14, 0, 0) + (tw.rH or Z),
		lH = V(8, 0, 0) + (tw.lH or Z),
		rK = V(16, 0, 0) + (tw.rK or Z),
		lK = V(12, 0, 0) + (tw.lK or Z),
	}
end

--- Root-to-root distance at which the NGMI's grab lands its hands on the
--- back of `victim`'s shoulders, measured on both bodies: how far forward the
--- grab pose puts this NGMI's hands, plus half the victim's torso depth.
--- `fallback` when either rig can't be measured.
function Encounter.grabGap(ngmi: any, victim: Model, fallback: number): number
	local SeatPosture = require(Shared:WaitForChild("SeatPosture"))
	local f = SeatPosture.frames(ngmi.rig, Encounter.grab(0, ngmi.twist))
	local r, l = f.RightHand, f.LeftHand
	local torso = victim:FindFirstChild("UpperTorso")
	local hand = ngmi.model:FindFirstChild("RightHand")
	if not (r and l and torso and torso:IsA("BasePart") and hand and hand:IsA("BasePart")) then
		return fallback
	end
	-- the root faces -Z
	local reach = -(r.Position.Z + l.Position.Z) / 2
	return reach + torso.Size.Z / 2 + hand.Size.Z / 2
end

--- Hauling someone backwards: the grab held through the arms and chest while
--- the legs keep walking (backwards, so the stride runs the other way).
function Encounter.drag(g: number, t: number, twist: Pose?): Pose
	local s = math.sin(-g)
	local tw = twist or NGMIMutation.TWIST
	local Z = Vector3.zero
	local p = Encounter.grab(t, tw)
	p.waist = V(-8, 0, 0) + (tw.waist or Z)
	p.rH = V(-26 * s, 0, 3) + (tw.rH or Z)
	p.lH = V(26 * s, 0, -4) + (tw.lH or Z)
	p.rK = V(18 + 30 * math.max(0, math.cos(g)), 0, 0) + (tw.rK or Z)
	p.lK = V(18 + 30 * math.max(0, -math.cos(g)), 0, 0) + (tw.lK or Z)
	return p
end

--- The scene's NGMI actor at `route.corner`, facing the mouth. A clone of a
--- real NGMI if one exists (already turned), else the blank NGMI body the
--- server publishes (ReplicatedStorage.NGMIBase) turned here, else `fallback`.
--- Lit by its style's eye glow and a cold rim so it reads as a shape in the dark.
--- Returns the actor (or nil) and its standing root height.
function Encounter.makeNgmi(fallback: Model, parent: Instance, route: Route): (any, number)
	local CollectionService = game:GetService("CollectionService")
	local CutsceneActors = require(Shared:WaitForChild("CutsceneActors"))
	local source: Model? = nil
	for _, m in CollectionService:GetTagged("NGMI") do
		if m:IsA("Model") and m:FindFirstChild("UpperTorso") then
			source = m
			break
		end
	end
	local base = game:GetService("ReplicatedStorage"):FindFirstChild("NGMIBase")
	if base and base:IsA("Model") then
		fallback = base
	end
	local lift = Encounter.standLift(source or fallback)
	local start = route.corner + V(0, lift, 0)
	local ngmi = CutsceneActors.spawn({
		source = source or fallback,
		parent = parent,
		cframe = CFrame.lookAt(start, route.mouth + V(0, lift, 0)),
		repaint = source == nil,
		stripClothes = source == nil,
	}) :: any
	if not ngmi then
		return nil, lift
	end
	if not source then
		NGMIMutation.apply(ngmi.model, math.random(1, 1000000), { fx = true })
	end
	ngmi.twist = NGMIMutation.twistOf(ngmi.model)
	-- arms hang at the thighs on this body, so the authored poses read right
	require(Shared:WaitForChild("NGMIFit")).armsIn(ngmi.rig)
	local h = ngmi.head()
	if h and not h:FindFirstChildWhichIsA("Light") then
		local glow = Instance.new("PointLight")
		glow.Color = NGMIMutation.styleOf(ngmi.model).eye
		glow.Brightness = 2
		glow.Range = 10
		glow.Parent = h
	end
	local torso = ngmi.model:FindFirstChild("UpperTorso")
	if torso then
		local rim = Instance.new("PointLight")
		rim.Color = Color3.fromRGB(150, 168, 210)
		rim.Brightness = 0.7
		rim.Range = 7
		rim.Parent = torso
	end
	return ngmi, lift
end

--- A warm practical on `parent` (the staff member's torso in the cut shots,
--- where the lens lamp is behind the NGMI and would leave him black).
function Encounter.keyLight(parent: Instance): PointLight
	local l = Instance.new("PointLight")
	l.Color = Color3.fromRGB(236, 210, 166)
	l.Brightness = 1.4
	l.Range = 9
	l.Parent = parent
	return l
end

--- A camera behind and above the right shoulder of a rig at `piv`, aimed at
--- `target`, pulled in short of any wall between it and the rig's head.
function Encounter.overShoulder(piv: CFrame, target: Vector3, rp: RaycastParams): CFrame
	local headAt = piv.Position + V(0, 1.6, 0)
	local want = headAt - piv.LookVector * 3.4 + piv.RightVector * 1.5 + V(0, 0.7, 0)
	local hit = workspace:Raycast(headAt, want - headAt, rp)
	if hit then
		want = hit.Position + (headAt - want).Unit * 0.5
	end
	return CFrame.lookAt(want, target)
end

--------------------------------------------------------------------------------
-- Screams
--------------------------------------------------------------------------------

-- ProSoundEffects (Roblox's licensed library), like the rest of the audio.
Encounter.SCREAMS = {
	female = { "rbxassetid://9114397739", "rbxassetid://9114397912" },
	male = { "rbxassetid://9125652432", "rbxassetid://9125652466", "rbxassetid://9125652949" },
}
local FEMALE = { Sarah = true, Priya = true }

--- The scream bank that fits the staff member by name.
function Encounter.screamsFor(name: string): { string }
	return if FEMALE[name] then Encounter.SCREAMS.female else Encounter.SCREAMS.male
end

--------------------------------------------------------------------------------
-- Finding the set
--------------------------------------------------------------------------------

local function params(exclude: { Instance }): RaycastParams
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	p.FilterDescendantsInstances = exclude
	p.IgnoreWater = true
	return p
end

local function floorAt(pos: Vector3, p: RaycastParams): Vector3?
	local hit = workspace:Raycast(pos + V(0, 2, 0), V(0, -8, 0), p)
	return hit and hit.Position
end

export type Route = {
	corner: Vector3, -- where the NGMI starts, out of the player's sight
	mouth: Vector3, -- where it steps out into view
	hidden: boolean, -- true when `corner` really is round a corner
	side: number, -- which side of the line it comes from (+1 right, -1 left)
}

--- A place behind `npcPos` (on the far side from `eye`) the NGMI can come
--- round: a point down a side opening that the player cannot see from where
--- they stand, plus the point on the line behind the NPC where it steps out.
--- Falls back to a spot further back down the line, in the dark.
--- Positions are at floor height.
function Encounter.findCorner(eye: Vector3, npcPos: Vector3, floorY: number, exclude: { Instance }): Route
	local p = params(exclude)
	local back = V(npcPos.X - eye.X, 0, npcPos.Z - eye.Z).Unit
	local right = back:Cross(V(0, 1, 0)).Unit
	local chest = V(0, 2.5, 0)
	local base = V(npcPos.X, floorY, npcPos.Z)

	-- close enough that, over its shoulder, they read as a person and not a
	-- speck at the end of the hall
	for _, d in { 10, 13, 16, 19 } do
		local mouth = base + back * d
		if workspace:Raycast(base + chest, back * d, p) then
			break -- the line behind the NPC is blocked from here on
		end
		for _, off in { 7, 10, 13 } do
			for _, side in { 1, -1 } do
				local corner = mouth + right * side * off
				local seenFromEye = workspace:Raycast(eye, corner + chest - eye, p) == nil
				local reachable = workspace:Raycast(mouth + chest, right * side * off, p) == nil
				if not seenFromEye and reachable then
					local f = floorAt(corner, p)
					if f and math.abs(f.Y - floorY) < 2 then
						return { corner = V(corner.X, floorY, corner.Z), mouth = mouth, hidden = true, side = side }
					end
				end
			end
		end
	end

	-- No corner: it comes out of the dark straight down the line.
	local hit = workspace:Raycast(base + chest, back * 30, p)
	local free = math.min(if hit then hit.Distance - 2 else 16, 16)
	local far = base + back * math.max(free, 8)
	return { corner = far, mouth = base + back * math.max(free * 0.6, 6), hidden = false, side = 1 }
end

--- The most open direction to run, as near to straight away from `threat`
--- as the building allows. Returns the unit direction and how far is clear.
function Encounter.runDirection(origin: Vector3, threat: Vector3, exclude: { Instance }): (Vector3, number)
	local p = params(exclude)
	local away = V(origin.X - threat.X, 0, origin.Z - threat.Z).Unit
	local best, bestScore, bestFree = away, -math.huge, 0
	for i = -7, 7 do
		local a = math.rad(i * 15)
		local dir = (CFrame.Angles(0, a, 0) * CFrame.lookAt(Vector3.zero, away)).LookVector
		dir = V(dir.X, 0, dir.Z).Unit
		local hit = workspace:Raycast(origin, dir * 40, p)
		local free = if hit then hit.Distance else 40
		local score = free - math.abs(i) * 1.5
		if score > bestScore then
			best, bestScore, bestFree = dir, score, free
		end
	end
	return best, bestFree
end

--------------------------------------------------------------------------------
-- Overlay: letterbox, subtitles, a thought line, and the black
--------------------------------------------------------------------------------

export type Overlay = { gui: ScreenGui, say: (string?, string?) -> (), think: (string?) -> (), black: Frame, bars: (boolean) -> () }

function Encounter.overlay(playerGui: Instance): Overlay
	local gui = Instance.new("ScreenGui")
	gui.Name = "NightEncounter"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 640
	gui.Parent = playerGui

	local function bar(anchorY: number): Frame
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0, anchorY)
		f.Position = UDim2.fromScale(0, anchorY)
		f.Size = UDim2.fromScale(1, 0)
		f.BackgroundColor3 = Color3.new()
		f.BorderSizePixel = 0
		f.ZIndex = 5
		f.Parent = gui
		return f
	end
	local top, bottom = bar(0), bar(1)

	local black = Instance.new("Frame")
	black.Size = UDim2.fromScale(1, 1)
	black.BackgroundColor3 = Color3.new()
	black.BackgroundTransparency = 1
	black.BorderSizePixel = 0
	black.ZIndex = 8
	black.Parent = gui

	local line = UITheme.label(gui, { size = 24, font = UITheme.Font.Medium, alignX = Enum.TextXAlignment.Center })
	line.AnchorPoint = Vector2.new(0.5, 1)
	line.Position = UDim2.new(0.5, 0, 1, -110)
	line.Size = UDim2.new(0.7, 0, 0, 64)
	line.TextWrapped = true
	line.RichText = true
	line.TextYAlignment = Enum.TextYAlignment.Bottom
	line.ZIndex = 10

	-- the player muttering to themselves: small, low on the screen
	local thought = UITheme.label(gui, { size = 18, font = UITheme.Font.Regular, color = UITheme.Color.Dim, alignX = Enum.TextXAlignment.Center })
	thought.AnchorPoint = Vector2.new(0.5, 1)
	thought.Position = UDim2.fromScale(0.5, 0.92)
	thought.Size = UDim2.new(0.6, 0, 0, 48)
	thought.TextYAlignment = Enum.TextYAlignment.Bottom
	thought.TextWrapped = true
	thought.ZIndex = 10

	local o = {} :: any
	o.gui = gui
	o.black = black
	function o.say(who: string?, text: string?)
		line.Text = if text then string.format('<font color="#E24848">%s</font>   %s', string.upper(who or ""), text) else ""
	end
	function o.think(text: string?)
		thought.Text = text or ""
	end
	function o.bars(on: boolean)
		local goal = { Size = UDim2.fromScale(1, if on then 0.11 else 0) }
		TweenService:Create(top, TweenInfo.new(0.5), goal):Play()
		TweenService:Create(bottom, TweenInfo.new(0.5), goal):Play()
	end
	return o :: Overlay
end

--- Height of a standing rig's root above the floor.
function Encounter.standLift(src: Model): number
	local hum = src:FindFirstChildOfClass("Humanoid")
	local root = src:FindFirstChild("HumanoidRootPart")
	if hum and root and root:IsA("BasePart") and hum.HipHeight > 0 then
		return hum.HipHeight + root.Size.Y / 2
	end
	return 3
end

return Encounter
