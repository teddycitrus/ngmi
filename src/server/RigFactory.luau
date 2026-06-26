--!strict
--------------------------------------------------------------------------------
-- RigFactory.luau  (ModuleScript)
-- Produces real Roblox R15 avatar rigs for NPCs.
--
-- A single template avatar is generated once via CreateHumanoidModelFromDescription
-- and cloned per NPC (fast). Each clone gets randomised hoodie / skin / pant
-- colours so the crowd looks varied. If the avatar API is ever unavailable the
-- factory falls back to a simple blocky humanoid so the game never breaks.
--------------------------------------------------------------------------------

local Players = game:GetService("Players")

local RigFactory = {}

-- Public default R15 animation assets
local ANIM = {
	idle = "rbxassetid://507766388",
	walk = "rbxassetid://507777826",
	sit  = "rbxassetid://2506281703",
}

local HOODIES = {
	Color3.fromRGB(40, 90, 170), Color3.fromRGB(40, 160, 90), Color3.fromRGB(150, 60, 170),
	Color3.fromRGB(200, 120, 40), Color3.fromRGB(55, 60, 72), Color3.fromRGB(170, 50, 60),
	Color3.fromRGB(60, 150, 160), Color3.fromRGB(220, 200, 60),
}
local SKINS = {
	Color3.fromRGB(235, 200, 170), Color3.fromRGB(205, 165, 125),
	Color3.fromRGB(160, 115, 85), Color3.fromRGB(110, 80, 55),
}
local PANTS = { Color3.fromRGB(40, 44, 55), Color3.fromRGB(60, 62, 70), Color3.fromRGB(80, 70, 60) }

local TORSO_PARTS = { "UpperTorso", "LowerTorso" }
local ARM_PARTS = { "LeftUpperArm", "LeftLowerArm", "LeftHand", "RightUpperArm", "RightLowerArm", "RightHand" }
local SKIN_PARTS = { "Head" }
local LEG_PARTS = { "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "RightUpperLeg", "RightLowerLeg", "RightFoot" }

--------------------------------------------------------------------------------
-- Template
--------------------------------------------------------------------------------
local template: Model? = nil
local triedTemplate = false

local function buildTemplate(): Model?
	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R15)
	end)
	if ok and model and model:IsA("Model") then
		model.Name = "RigTemplate"
		-- Strip any default scripts that assume a player owns it.
		for _, d in model:GetDescendants() do
			if d:IsA("LuaSourceContainer") then
				d:Destroy()
			end
		end
		return model
	end
	return nil
end

local function getTemplate(): Model?
	if not triedTemplate then
		triedTemplate = true
		template = buildTemplate()
	end
	return template
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
	Instance.new("Decal", head).Name = "face"
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
	Instance.new("Animator", hum)
	model.PrimaryPart = root
	return model
end

--------------------------------------------------------------------------------
-- Colour a real rig
--------------------------------------------------------------------------------
local function recolor(model: Model)
	local hoodie = HOODIES[math.random(#HOODIES)]
	local skin = SKINS[math.random(#SKINS)]
	local pants = PANTS[math.random(#PANTS)]
	local function setColors(names: { string }, color: Color3)
		for _, n in names do
			local part = model:FindFirstChild(n)
			if part and part:IsA("BasePart") then
				part.Color = color
			end
		end
	end
	setColors(TORSO_PARTS, hoodie)
	setColors(ARM_PARTS, hoodie)
	setColors(SKIN_PARTS, skin)
	setColors(LEG_PARTS, pants)
end

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------

--- Create an NPC rig. Returns (model, humanoid). The caller positions it with
--- model:PivotTo(...) and parents it.
function RigFactory.create(): (Model, Humanoid)
	local t = getTemplate()
	local model: Model
	if t then
		model = t:Clone()
		recolor(model)
	else
		model = buildBlockRig()
	end
	local hum = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	hum.BreakJointsOnDeath = false
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	if not model.PrimaryPart then
		model.PrimaryPart = model:FindFirstChild("HumanoidRootPart") :: BasePart
	end
	return model, hum
end

local function getAnimator(hum: Humanoid): Animator
	local animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = hum
	end
	return animator
end

--- Play a looping animation on a humanoid; returns the track (or nil on failure).
function RigFactory.playLoop(hum: Humanoid, animId: string): AnimationTrack?
	local anim = Instance.new("Animation")
	anim.AnimationId = animId
	local ok, track = pcall(function()
		return getAnimator(hum):LoadAnimation(anim)
	end)
	if ok and track then
		track.Looped = true
		track:Play()
		return track
	end
	return nil
end

--- Make a seated NPC: anchor it in place and play the sit animation.
function RigFactory.sit(model: Model, hum: Humanoid)
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		root.Anchored = true
	end
	RigFactory.playLoop(hum, ANIM.sit)
end

--- Drive idle/walk animation for a roaming NPC based on its movement.
function RigFactory.driveLocomotion(hum: Humanoid)
	local idle = RigFactory.playLoop(hum, ANIM.idle)
	local walk: AnimationTrack? = nil
	hum.Running:Connect(function(speed: number)
		if speed > 0.5 then
			if not walk then
				walk = RigFactory.playLoop(hum, ANIM.walk)
			end
			if idle then idle:Stop() end
		else
			if walk then walk:Stop(); walk = nil end
			if idle then idle:Play() end
		end
	end)
end

return RigFactory
