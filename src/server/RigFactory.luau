--!strict
--------------------------------------------------------------------------------
-- RigFactory.luau  (ModuleScript)
-- Produces real Roblox R15 avatar rigs for NPCs.
--
-- Template avatars are generated once per outfit (Rig/Looks) via
-- CreateHumanoidModelFromDescription and cloned per NPC (fast). If the avatar
-- API is ever unavailable the factory falls back to a simple blocky humanoid so
-- the game never breaks.
--------------------------------------------------------------------------------

local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RigPose = require(ReplicatedStorage.Shared.RigPose)
local SeatPosture = require(ReplicatedStorage.Shared.SeatPosture)

local RigFactory = {}

-- CFrame attribute: a joint's rest Attachment0 frame (or Motor6D C0).
RigFactory.REST_ATTRIBUTE = "RestFrame"

-- Public default R15 animation assets
local ANIM = {
	idle = "rbxassetid://507766388",
	walk = "rbxassetid://507777826",
	sit = "rbxassetid://2506281703",
}

local HOODIES = {
	Color3.fromRGB(40, 90, 170),
	Color3.fromRGB(40, 160, 90),
	Color3.fromRGB(150, 60, 170),
	Color3.fromRGB(200, 120, 40),
	Color3.fromRGB(55, 60, 72),
	Color3.fromRGB(170, 50, 60),
	Color3.fromRGB(60, 150, 160),
	Color3.fromRGB(220, 200, 60),
}
local SKINS = {
	Color3.fromRGB(235, 200, 170),
	Color3.fromRGB(205, 165, 125),
	Color3.fromRGB(160, 115, 85),
	Color3.fromRGB(110, 80, 55),
}
local PANTS = { Color3.fromRGB(40, 44, 55), Color3.fromRGB(60, 62, 70), Color3.fromRGB(80, 70, 60) }

--------------------------------------------------------------------------------
-- Templates: one per look (Rig/Looks), built once and cloned per rig
--------------------------------------------------------------------------------
local Looks = require(script.Parent:WaitForChild("Rig"):WaitForChild("Looks"))
local templates: { [string]: Model | false } = {}

local function buildTemplate(desc: HumanoidDescription, key: string): Model?
	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
	end)
	if not ok and #desc:GetAccessories(false) > 0 then
		-- one catalog item gone (taken off sale, moderated) fails the whole
		-- build; keep the person, drop the clothes
		warn("[RigFactory] look " .. key .. " clothes failed, retrying without: " .. tostring(model))
		desc:SetAccessories({}, false)
		ok, model = pcall(function()
			return Players:CreateHumanoidModelFromDescription(desc, Enum.HumanoidRigType.R15)
		end)
	end
	if ok and model and model:IsA("Model") then
		model.Name = "RigTemplate"
		-- Strip any default scripts that assume a player owns it.
		for _, d in model:GetDescendants() do
			if d:IsA("LuaSourceContainer") then
				d:Destroy()
			end
		end
		model:SetAttribute("Look", key)
		return model
	end
	warn("[RigFactory] look " .. key .. " failed: " .. tostring(model))
	return nil
end

-- The shop bodies come in at 6.3 to 7.5 studs. Every look is scaled to an
-- adult 6.4 (times the look's own height multiplier), tall next to the player
-- avatar. Seated placement still fits: at this build the seated hip sits only
-- ~0.1 stud higher above the root than on the old 5.4-stud bodies.
local TARGET_HEIGHT = 6.4

local function standingHeight(model: Model): number
	local head = model:FindFirstChild("Head") :: BasePart?
	local low = math.huge
	for _, n in { "LeftFoot", "RightFoot" } do
		local foot = model:FindFirstChild(n) :: BasePart?
		if foot then
			low = math.min(low, foot.Position.Y - foot.Size.Y / 2)
		end
	end
	if not head or low == math.huge then
		return TARGET_HEIGHT
	end
	return head.Position.Y + head.Size.Y / 2 - low
end

local BLOCKY_MAX = 5.9 -- unscaled height under which a body didn't load

local getTemplate: (look: Looks.Look) -> Model?

-- The look's outfit on the first stand-in body that builds (Looks.substitute),
-- cached under the look's own key. A stand-in never chains to another.
local function useStandIn(look: Looks.Look): Model?
	local t: Model? = nil
	if not look.key:find("_sub%d+$") then
		warn("[RigFactory] look " .. look.key .. " body failed to load, using a stand-in")
		local n = 1
		local sub = Looks.substitute(look, n)
		while sub and not t do
			t = getTemplate(sub)
			n += 1
			sub = if t then nil else Looks.substitute(look, n)
		end
	end
	templates[look.key] = t or false
	return t
end

function getTemplate(look: Looks.Look): Model?
	local t = templates[look.key]
	if t == nil then
		local built = buildTemplate(Looks.describe(look), look.key)
		if not built then
			return useStandIn(look)
		end
		do
			-- Joints only settle once the rig is in the workspace: measured
			-- unparented, the height read 10-15% high. Park it out of sight,
			-- pinned, for a frame.
			local root = built:FindFirstChild("HumanoidRootPart") :: BasePart?
			local wasAnchored = root and root.Anchored
			if root then
				root.Anchored = true
			end
			built:PivotTo(CFrame.new(0, 5000, 0))
			built.Parent = workspace
			task.wait()
			-- A bundle body that fails to load (taken off sale, moderated)
			-- leaves Roblox's default blocky R15 parts, ~5.2 studs against the
			-- shop bodies' 6.3 to 7.5.
			if standingHeight(built) < BLOCKY_MAX then
				built:Destroy()
				return useStandIn(look)
			end
			local want = TARGET_HEIGHT * (look.height or 1)
			for _ = 1, 2 do
				local h = standingHeight(built)
				if h <= 0 or math.abs(h - want) < 0.05 then
					break
				end
				built:ScaleTo(built:GetScale() * want / h)
				task.wait()
			end
			local fit = look.hairFit
			local head = built:FindFirstChild("Head")
			local anchor = head and head:FindFirstChild("HairAttachment")
			if fit and anchor and anchor:IsA("Attachment") then
				-- Humanoid rescaling rebuilds accessory sizes and attachment
				-- positions from their Original* values, so those move too
				-- or the next rescale throws the fit away.
				local function scaleValue(parent: Instance, name: string, k: number)
					local v = parent:FindFirstChild(name)
					if v and v:IsA("Vector3Value") then
						v.Value *= k
					end
				end
				for _, acc in built:GetChildren() do
					local handle = acc:IsA("Accessory") and acc.AccessoryType == Enum.AccessoryType.Hair and acc:FindFirstChild("Handle")
					if handle and handle:IsA("BasePart") then
						-- grow about the attachment point so the hair stays seated
						handle.Size *= fit.scale
						scaleValue(handle, "OriginalSize", fit.scale)
						for _, a in handle:GetChildren() do
							if a:IsA("Attachment") then
								a.Position *= fit.scale
								scaleValue(a, "OriginalPosition", fit.scale)
							end
						end
					end
				end
				anchor.Position += fit.offset
				local orig = anchor:FindFirstChild("OriginalPosition")
				local hum = built:FindFirstChildOfClass("Humanoid")
				local headScale = hum and hum:FindFirstChild("HeadScale")
				if orig and orig:IsA("Vector3Value") then
					local k = if headScale and headScale:IsA("NumberValue") and headScale.Value > 0 then headScale.Value else 1
					orig.Value += fit.offset / k
				end
			end
			built.Parent = nil
			if root then
				root.Anchored = wasAnchored :: boolean
			end
			-- Each joint's rest frame, kept on the attachment. The shop bodies'
			-- joint attachments are rotated, so a clone that was posed (RigPose
			-- folds poses into these attachments) can't get back to rest by
			-- zeroing them the way a classic R15 could; it reads this instead.
			for _, d in built:GetDescendants() do
				if d:IsA("AnimationConstraint") and d.Attachment0 then
					d.Attachment0:SetAttribute(RigFactory.REST_ATTRIBUTE, d.Attachment0.CFrame)
				elseif d:IsA("Motor6D") then
					d:SetAttribute(RigFactory.REST_ATTRIBUTE, d.C0)
				end
			end
		end
		t = built or false
		templates[look.key] = t
	end
	return if t then t else nil
end

--- Build every outfit's template up front, in parallel, so the first wave of
--- rigs doesn't stall on one catalog fetch after another. Returns once all
--- are built or `timeout` seconds pass.
function RigFactory.preloadLooks(timeout: number)
	local all: { Looks.Look } = table.clone(Looks.CROWD)
	for _, l in Looks.NAMED do
		table.insert(all, l)
	end
	local pending = #all
	for _, l in all do
		task.spawn(function()
			getTemplate(l)
			pending -= 1
		end)
	end
	local deadline = os.clock() + timeout
	while pending > 0 and os.clock() < deadline do
		task.wait(0.1)
	end
end

--------------------------------------------------------------------------------
-- Fallback blocky rig (R6) — only used if the avatar API is unavailable
--------------------------------------------------------------------------------
local function blockPart(model: Model, name: string, size: Vector3, cf: CFrame, color: Color3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Anchored = false
	p.CanCollide = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = model
	return p
end

local function weld(a: BasePart, b: BasePart, c0: CFrame)
	local w = Instance.new("Weld")
	w.Part0 = a
	w.Part1 = b
	w.C0 = c0
	w.Parent = a
end

local function buildBlockRig(): Model
	local model = Instance.new("Model")
	local skin = SKINS[math.random(#SKINS)]
	local hoodie = HOODIES[math.random(#HOODIES)]
	local pants = PANTS[math.random(#PANTS)]
	local origin = CFrame.new(0, 3, 0)

	local root = blockPart(model, "HumanoidRootPart", Vector3.new(2, 2, 1), origin, hoodie)
	root.Transparency = 1
	local torso = blockPart(model, "Torso", Vector3.new(2, 2, 1), origin, hoodie)
	weld(root, torso, CFrame.new())
	local head = blockPart(model, "Head", Vector3.new(1.2, 1.2, 1.2), origin * CFrame.new(0, 1.6, 0), skin)
	head.Shape = Enum.PartType.Ball
	weld(torso, head, CFrame.new(0, 1.6, 0))
	local face = Instance.new("Decal")
	face.Name = "face"
	face.Parent = head
	local function limb(name: string, off: CFrame, color: Color3)
		local l = blockPart(model, name, Vector3.new(1, 2, 1), origin * off, color)
		weld(torso, l, off)
	end
	limb("Left Arm", CFrame.new(-1.5, 0, 0), hoodie)
	limb("Right Arm", CFrame.new(1.5, 0, 0), hoodie)
	limb("Left Leg", CFrame.new(-0.5, -2, 0), pants)
	limb("Right Leg", CFrame.new(0.5, -2, 0), pants)

	local hum = Instance.new("Humanoid")
	hum.Parent = model
	local animator = Instance.new("Animator")
	animator.Parent = hum
	model.PrimaryPart = root
	return model
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

local function finish(t: Model?): (Model, Humanoid)
	local model = if t then t:Clone() else buildBlockRig()
	local hum = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	hum.BreakJointsOnDeath = false
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	if not model.PrimaryPart then
		model.PrimaryPart = model:FindFirstChild("HumanoidRootPart") :: BasePart
	end
	return model, hum
end

--- Create an NPC rig. Returns (model, humanoid). The caller positions it with
--- model:PivotTo(...) and parents it. `id` picks a named NPC's own outfit
--- (Looks.NAMED, keyed by NPCConfig id); anything else gets one of the
--- crowd's four.
function RigFactory.create(id: string?): (Model, Humanoid)
	local look = (id and Looks.NAMED[id]) or Looks.CROWD[math.random(#Looks.CROWD)]
	return finish(getTemplate(look))
end

-- The NGMI base: Roblox's plain default R15 body and head, with no bundle
-- parts, hair, accessories or clothes, so an NGMI is only ever its mutation
-- style and never carries a venue person's items.
local blankTemplate: Model | false | nil = nil

--- A body for NGMIMutation to build a style on: one of the venue's realistic
--- people with nothing on (Looks.BARE), so NGMIs share the crowd's adult
--- proportions. `pick` chooses the body (random when nil). The default blocky
--- R15 is only the fallback for when the avatar API can't build any of them.
function RigFactory.createBase(pick: number?): (Model, Humanoid)
	local bare = Looks.BARE
	if #bare > 0 then
		local first = if pick then (pick - 1) % #bare + 1 else math.random(#bare)
		for k = 0, #bare - 1 do
			local t = getTemplate(bare[(first + k - 1) % #bare + 1])
			if t then
				return finish(t)
			end
		end
	end
	if blankTemplate == nil then
		blankTemplate = buildTemplate(Instance.new("HumanoidDescription"), "ngmi") or false
	end
	return finish(if blankTemplate then blankTemplate else nil)
end

--- One dressed rig per crowd look, for client cutscenes to cast from when the
--- venue has no people in it (a session that starts on the final night).
function RigFactory.createCast(): { Model }
	local out = {}
	for _, look in Looks.CROWD do
		local t = getTemplate(look)
		if t then
			local m = finish(t)
			table.insert(out, m)
		end
	end
	return out
end

local function getAnimator(hum: Humanoid): Animator
	local animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = hum
	end
	return animator
end

-- One Animation object per id, shared by every rig that loads it.
local animations: { [string]: Animation } = {}

local function animation(animId: string): Animation
	local anim = animations[animId]
	if not anim then
		anim = Instance.new("Animation")
		anim.AnimationId = animId
		animations[animId] = anim
	end
	return anim
end

--- Load a looping animation without starting it (nil on failure).
local function loadLoop(hum: Humanoid, animId: string): AnimationTrack?
	local anim = animation(animId)
	local ok, track = pcall(function()
		return getAnimator(hum):LoadAnimation(anim)
	end)
	if ok and track then
		track.Looped = true
		return track
	end
	return nil
end

--- Play a looping animation on a humanoid; returns the track (or nil on failure).
function RigFactory.playLoop(hum: Humanoid, animId: string): AnimationTrack?
	local track = loadLoop(hum, animId)
	if track then
		track:Play()
	end
	return track
end

--- Make a seated NPC: anchor it in place and play the sit animation.
function RigFactory.sit(model: Model, hum: Humanoid)
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		root.Anchored = true
	end
	RigFactory.playLoop(hum, ANIM.sit)
end

export type SeatOptions = {
	seatTop: number, -- world Y of the seat's top face
	seatFront: Vector3?, -- a point on the seat's front edge: deep seats slide the sitter up to it
	ignore: { Instance }?, -- skipped when finding the floor (the chair itself)
	desk: Instance?, -- furniture to find a desk top in, for the desk styles
	keysAt: Vector3?, -- middle of the keyboard's keys, on their surface, world space
	mouseAt: Vector3?, -- the mouse or trackpad, on its surface, world space
}

-- Client/SeatIdle animates rigs with this tag on top of their seated pose,
-- rebuilding it from these attributes (all root space).
RigFactory.SEAT_TAG = "SeatIdle"

local FRONT_KEEP = 0.45 -- studs the root stays back from the seat's front edge

--- The forward-most face (root-space Z, forward is -Z) of the furniture the
--- rig sits on, between the cushion top and 0.8 studs under it, and how
--- high that face reaches. Parts that do not reach back under the body (a
--- desk pedestal in front of the chair) are not the seat.
local function seatFrontOf(model: Model, at: CFrame, opts: SeatOptions, seatTopY: number): (number?, number?)
	local front, top = nil, nil
	if opts.seatFront then
		front = at:PointToObjectSpace(opts.seatFront).Z
		top = seatTopY
	end
	local box = CFrame.new(0, seatTopY - 0.41, -1.2)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local skip: { Instance } = { model }
	local people = workspace:FindFirstChild("AmbientPeople")
	if people then
		table.insert(skip, people)
	end
	params.FilterDescendantsInstances = skip
	for _, part in workspace:GetPartBoundsInBox(at * box, Vector3.new(1.4, 0.78, 2.4), params) do
		if not part.CanCollide or part.Transparency >= 1 then
			continue
		end
		local cf = at:ToObjectSpace(part.CFrame)
		local h = part.Size / 2
		local zmin, zmax, ymax = math.huge, -math.huge, -math.huge
		for _, sx in { -1, 1 } do
			for _, sy in { -1, 1 } do
				for _, sz in { -1, 1 } do
					local c = (cf * CFrame.new(h.X * sx, h.Y * sy, h.Z * sz)).Position
					zmin = math.min(zmin, c.Z)
					zmax = math.max(zmax, c.Z)
					ymax = math.max(ymax, c.Y)
				end
			end
		end
		if zmax > -0.3 and zmin > -2.4 then
			if not front or zmin < front then
				front = zmin
			end
			top = math.max(top or -math.huge, math.min(ymax, seatTopY))
		end
	end
	return front, top
end

--- Seat an NPC in a posture built for its body (Shared.SeatPosture): no
--- animation, thighs level on the seat, feet on the floor, hands placed per
--- `style`. `look` gives the position (X, Z) and facing; the height is solved
--- from the seat top. Returns the pose written.
function RigFactory.seatPosed(model: Model, hum: Humanoid, look: CFrame, style: string, opts: SeatOptions): RigPose.Pose
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		root.Anchored = true
	end
	local animator = hum:FindFirstChildOfClass("Animator")
	if animator then
		for _, t in animator:GetPlayingAnimationTracks() do
			t:Stop(0)
		end
	end
	local rig = RigPose.new(model)
	local p = look.Position
	local at = CFrame.new(p.X, opts.seatTop + rig:seatOffset(), p.Z) * look.Rotation
	-- The seat's front face under the knees: the cushion edge, or whatever
	-- reaches further forward below it (a couch base, a seat pan). Sit
	-- forward until the shins clear it, but no closer than FRONT_KEEP to the
	-- edge; SeatPosture angles the shins forward for the rest.
	local seatTopY = opts.seatTop - at.Position.Y
	local front, frontTop = seatFrontOf(model, at, opts, seatTopY)
	if front then
		local shinR = 0.3
		local shin = model:FindFirstChild("RightLowerLeg")
		if shin and shin:IsA("BasePart") then
			shinR = shin.Size.Z / 2
		end
		local slide = math.min(-front + shinR + 0.06 - SeatPosture.kneeReach(rig), -front - FRONT_KEEP, 1.2)
		if slide > 0 then
			at *= CFrame.new(0, 0, -slide)
			front += slide
		end
	end
	local toPivot = if root then root.CFrame:ToObjectSpace(model:GetPivot()) else CFrame.identity
	model:PivotTo(at * toPivot)

	local exclude = RaycastParams.new()
	exclude.FilterType = Enum.RaycastFilterType.Exclude
	local skip: { Instance } = { model }
	for _, i in opts.ignore or {} do
		table.insert(skip, i)
	end
	local people = workspace:FindFirstChild("AmbientPeople")
	if people then
		table.insert(skip, people)
	end
	exclude.FilterDescendantsInstances = skip
	local ctx: SeatPosture.Context = {}
	-- the floor under the feet: skip anything standing well above it (a
	-- coffee table in front of the couch)
	local origin = at * Vector3.new(0, 0, -1.4)
	for _ = 1, 4 do
		local hit = workspace:Raycast(origin, Vector3.new(0, -8, 0), exclude)
		if not hit then
			break
		end
		if hit.Position.Y < opts.seatTop - 0.9 then
			ctx.floor = hit.Position.Y - at.Position.Y
			break
		end
		table.insert(skip, hit.Instance)
		exclude.FilterDescendantsInstances = skip
	end
	if opts.desk then
		local only = RaycastParams.new()
		only.FilterType = Enum.RaycastFilterType.Include
		only.FilterDescendantsInstances = { opts.desk }
		local hit = workspace:Raycast(at * Vector3.new(0, 3, -1.9), Vector3.new(0, -5, 0), only)
		local top = hit and hit.Position.Y - at.Position.Y
		if top and top > -0.5 and top < 2.5 then
			ctx.desk = top
			if opts.keysAt then
				ctx.deskAt = at:PointToObjectSpace(opts.keysAt)
			end
			if opts.mouseAt then
				ctx.mouseAt = at:PointToObjectSpace(opts.mouseAt)
			end
		end
	end
	ctx.seatTop = seatTopY
	ctx.front = front
	ctx.frontTop = frontTop
	local pose = SeatPosture.build(rig, style, ctx)
	rig:apply(pose)

	model:SetAttribute("SeatStyle", style)
	model:SetAttribute("SeatFloor", ctx.floor)
	model:SetAttribute("SeatDesk", ctx.desk)
	model:SetAttribute("SeatKeys", ctx.deskAt)
	model:SetAttribute("SeatMouse", ctx.mouseAt)
	model:SetAttribute("SeatTop", ctx.seatTop)
	model:SetAttribute("SeatFront", ctx.front)
	model:SetAttribute("SeatFrontTop", ctx.frontTop)
	CollectionService:AddTag(model, RigFactory.SEAT_TAG)
	return pose
end

--- Undo sit(): stop the sit animation. Left playing, it keeps the knees
--- folded under whatever the rig does next, so a standing NPC wall-sits.
function RigFactory.unsit(hum: Humanoid)
	local animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		return
	end
	for _, track in animator:GetPlayingAnimationTracks() do
		if track.Animation and track.Animation.AnimationId == ANIM.sit then
			track:Stop(0.3)
		end
	end
end

-- Client/NPCPosture replaces the stock idle on these rigs (straight legs,
-- arms hanging at the sides): the stock R15 idles were made for blocky
-- bodies and hold these narrow realistic ones in a half squat, arms out.
RigFactory.POSTURE_TAG = "StandPosture"
-- Model attribute: keep the animation's own arms (for rigs whose arm poses
-- were authored over the stock idle, like the wall leaners).
RigFactory.POSTURE_KEEP_ARMS = "PostureKeepArms"

-- Ground speed the default R15 walk covers at playback speed 1. Measured by
-- pinning a rig and timing the planted foot: it slides back at 15.7-17.4
-- studs/s. Playing it at speed 1 for an NPC strolling at 6 cycled the legs
-- nearly three times too fast, which is what made the gait look wrong.
local WALK_NATURAL_SPEED = 16

--- Drive idle/walk animation for a roaming NPC from how fast its root is
--- actually moving: walk playback is scaled so the feet match the ground, and
--- the two tracks crossfade instead of snapping.
---
--- This reads velocity every frame rather than listening to Humanoid.Running:
--- Running dips to ~0 at every path waypoint, which restarted the walk over
--- and over (on clients the NPCs often slid along on the idle animation).
--- Hysteresis keeps the walk going through those dips.
function RigFactory.driveLocomotion(hum: Humanoid)
	local model = hum.Parent
	if model then
		CollectionService:AddTag(model, RigFactory.POSTURE_TAG)
	end
	local idle = RigFactory.playLoop(hum, ANIM.idle)
	local walk = loadLoop(hum, ANIM.walk)
	local moving = false
	local stillFor = 0
	local lastRate = -1
	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function(dt: number)
		local root = hum.RootPart
		if not hum.Parent or not root then
			conn:Disconnect()
			return
		end
		local v = root.AssemblyLinearVelocity
		local speed = if root.Anchored then 0 else Vector3.new(v.X, 0, v.Z).Magnitude
		-- "WalkIntent" lets a caller start the cycle just before moving off, so
		-- the animation reaches clients by the time the body does.
		if speed > 1.5 or hum:GetAttribute("WalkIntent") == true then
			stillFor = 0
			-- Rate from the speed the NPC is walking at, not this frame's
			-- velocity: on the first frames it is still accelerating, and a
			-- burst of AdjustSpeed calls doesn't reliably reach clients.
			local rate = math.clamp(hum.WalkSpeed / WALK_NATURAL_SPEED, 0.3, 1.4)
			if not moving then
				moving = true
				lastRate = rate
				if walk then
					walk:Play(0.3, 1, rate)
				end
				if idle then
					idle:Stop(0.3)
				end
			elseif walk and math.abs(rate - lastRate) > 0.04 then
				walk:AdjustSpeed(rate)
				lastRate = rate
			end
		elseif moving then
			stillFor += dt
			if stillFor > 0.3 then
				moving = false
				if walk then
					walk:Stop(0.35)
				end
				if idle then
					idle:Play(0.35)
				end
			end
		end
	end)
end

--- A standing NPC that stays put: anchored, idling.
function RigFactory.stand(model: Model, hum: Humanoid)
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		root.Anchored = true
	end
	CollectionService:AddTag(model, RigFactory.POSTURE_TAG)
	local idle = RigFactory.playLoop(hum, ANIM.idle)
	if idle then
		-- out of step with everyone else, so a hallway doesn't breathe in unison
		idle.TimePosition = math.random() * math.max(idle.Length, 0.1)
	end
end

--------------------------------------------------------------------------------
-- Split-out parts, re-exported so callers keep using RigFactory.*
--------------------------------------------------------------------------------
local Rig = script.Parent:WaitForChild("Rig")
local Hair = require(Rig:WaitForChild("Hair"))
local IK = require(Rig:WaitForChild("IK"))
local Articulation = require(Rig:WaitForChild("Articulation"))

export type HeadPieceOpts = Hair.HeadPieceOpts

Hair.knitColors = HOODIES

RigFactory.attachToHead = Hair.attachToHead
-- Look rigs wear real hair accessories; the old part-built hair is only for
-- the block fallback.
function RigFactory.applyHair(model: Model, ...: any): string?
	if model:GetAttribute("Look") then
		return nil
	end
	return Hair.applyHair(model, ...)
end
RigFactory.enableHeadTracking = IK.enableHeadTracking
RigFactory.enableBodyTurn = IK.enableBodyTurn
RigFactory.enableFootPlacement = IK.enableFootPlacement
RigFactory.HEAD_TRACK_SUSPEND = IK.SUSPEND_ATTRIBUTE
RigFactory.articulate = Articulation.articulate
RigFactory.resetArticulation = Articulation.resetArticulation
RigFactory.rampArticulation = Articulation.rampArticulation

return RigFactory
