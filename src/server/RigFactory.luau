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
local RunService = game:GetService("RunService")

local RigFactory = {}

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

-- The shop bodies stand 6.3 to 7.5 studs; the venue (desk chairs, couches,
-- the seated root offsets in Ambient/Seats and AmbientPopulation) was fitted
-- to a ~5.4-stud R15. Every look is scaled to that height.
local TARGET_HEIGHT = 5.4

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

local function getTemplate(look: Looks.Look): Model?
	local t = templates[look.key]
	if t == nil then
		local built = buildTemplate(Looks.describe(look), look.key)
		if built then
			local h = standingHeight(built)
			if h > 0 and math.abs(h - TARGET_HEIGHT) > 0.05 then
				built:ScaleTo(built:GetScale() * TARGET_HEIGHT / h)
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
local baseTemplate: Model | false | nil = nil

--- A blank body for NGMIMutation to build a style on.
function RigFactory.createBase(): (Model, Humanoid)
	if baseTemplate == nil then
		baseTemplate = buildTemplate(Instance.new("HumanoidDescription"), "ngmi") or false
	end
	return finish(if baseTemplate then baseTemplate else nil)
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
RigFactory.enableFootPlacement = IK.enableFootPlacement
RigFactory.HEAD_TRACK_SUSPEND = IK.SUSPEND_ATTRIBUTE
RigFactory.articulate = Articulation.articulate
RigFactory.resetArticulation = Articulation.resetArticulation
RigFactory.rampArticulation = Articulation.rampArticulation

return RigFactory
