--!strict
--------------------------------------------------------------------------------
-- NPCPosture.client.luau
-- How standing NPCs hold themselves. The stock R15 idles were made for blocky
-- avatars: on the realistic bodies they sink into a half squat (knees bent
-- 15-35 degrees) with the arms held out from the hips. For rigs tagged
-- "StandPosture" (RigFactory.driveLocomotion / RigFactory.stand) this replaces
-- that idle, after the Animator has run each frame, with:
--   * straight legs, feet flat
--   * arms hanging at the sides, elbows soft
--   * slow breathing, a little weight shift and the odd look around, out of
--     step from one person to the next
-- While the rig walks the walk animation wins, with only the arms pulled in to
-- the body. Any other animation (sitting, a cutscene clip) is left alone, as
-- are RigPose offsets on the joints' attachments, which still layer on top.
--
-- Client only and local: nothing here replicates.
--------------------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local RigPose = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("RigPose"))

local TAG = "StandPosture"
local KEEP_ARMS = "PostureKeepArms"
local IDLE_ID = "rbxassetid://507766388" -- RigFactory's stock idle, which this replaces
local WALK_ID = "rbxassetid://507777826" -- RigFactory's walk
local RANGE = 140 -- studs from the camera
local SCAN_INTERVAL = 0.5
local TRACK_INTERVAL = 0.15 -- how often each rig's track weights are re-read

local ARM_IN = 8 -- degrees, when a body can't be measured
local ARM_IN_MAX = 30
local HAND_CLEAR = 0.04 -- studs of air between the hand and the thigh

local V = Vector3.new

type Joint = { key: string, handle: Instance } -- AnimationConstraint or Motor6D
type Entry = {
	model: Model,
	joints: { Joint },
	seed: number,
	keepArms: boolean,
	armIn: number, -- shoulder roll that brings this body's hands to its thighs
	walkW: number, -- 0 standing .. 1 walking, eased from the root's speed
	other: boolean, -- something else is playing (sit, cutscene): hands off
	nextRead: number,
}

local camera = workspace.CurrentCamera
local entries: { [Model]: Entry } = {}

local ARM_KEYS = { lS = true, rS = true, lE = true, rE = true, lW = true, rW = true }

local function seedOf(model: Model): number
	local h = 0
	for i = 1, #model.Name do
		h = (h * 31 + string.byte(model.Name, i)) % 100003
	end
	return (h % 1000) / 1000 * 100 + math.random()
end

--- The shoulder roll that hangs this body's hands just outside its thighs.
--- Bodies differ a lot (rest hands hang 0.6 to 1.2 studs out), so it is
--- solved through the arm's own joint frames rather than fixed.
local function fitArms(model: Model): number
	local torso = model:FindFirstChild("UpperTorso")
	local leg = model:FindFirstChild("LeftUpperLeg")
	local hand = model:FindFirstChild("LeftHand")
	if not (torso and torso:IsA("BasePart") and leg and leg:IsA("BasePart") and hand and hand:IsA("BasePart")) then
		return ARM_IN
	end
	local rig = RigPose.new(model)
	local thighOuter = math.abs(torso.CFrame:PointToObjectSpace(leg.Position).X) + leg.Size.X / 2
	local want = thighOuter + hand.Size.X / 2 + HAND_CLEAR
	for z = 0, ARM_IN_MAX do
		local h = rig:handIn("l", { lS = V(1.5, 0, z), lE = V(-11, 0, 0) })
		if not h then
			return ARM_IN
		end
		if math.abs(h.X) <= want then
			return z
		end
	end
	return ARM_IN_MAX
end

local function begin(model: Model): Entry?
	local joints: { Joint } = {}
	for key, names in RigPose.JOINTS do
		local part = model:FindFirstChild(names[1])
		if not part then
			continue
		end
		for _, c in part:GetChildren() do
			if c.Name == names[2] and (c:IsA("AnimationConstraint") or c:IsA("Motor6D")) then
				table.insert(joints, { key = key, handle = c })
				break
			end
		end
	end
	if #joints == 0 then
		return nil
	end
	local keepArms = model:GetAttribute(KEEP_ARMS) == true
	return {
		model = model,
		joints = joints,
		seed = seedOf(model),
		keepArms = keepArms,
		armIn = if keepArms then 0 else fitArms(model),
		walkW = 0,
		other = false,
		nextRead = 0,
	}
end

--- Whether anything besides the stock idle and walk is playing (sitting, a
--- scripted clip): those own the whole body.
---
--- Standing vs walking is NOT read from the tracks: on clients the walk's Stop
--- sometimes never arrives, and an NPC that has stopped stays frozen
--- mid-stride at full walk weight. The root's speed is the truth.
local function readTracks(e: Entry)
	local hum = e.model:FindFirstChildOfClass("Humanoid")
	local animator = hum and hum:FindFirstChildOfClass("Animator")
	local other = false
	if animator then
		for _, t in animator:GetPlayingAnimationTracks() do
			if t.WeightCurrent < 0.02 then
				continue
			end
			local id = t.Animation and t.Animation.AnimationId or ""
			if id ~= IDLE_ID and id ~= WALK_ID then
				other = true
			end
		end
	end
	e.other = other
end

--- The standing pose at time t, authored like any RigPose pose.
local function standing(t: number, s: number, arms: number): RigPose.Pose
	local breathe = math.sin(t * 1.45 + s) -- ~4.3 s a breath
	local shift = math.sin(t * 0.21 + s * 1.7) -- slow weight shift
	local look = math.sin(t * 0.13 + s * 2.3) * math.sin(t * 0.31 + s)
	local armIn = arms + 1.5 * math.sin(t * 0.17 + s)
	return {
		root = V(0, 0, 0.8 * shift),
		waist = V(1 + 0.7 * breathe, 2 * look, -1.2 * shift),
		neck = V(-1 - 0.5 * breathe, 9 * look, 0.6 * shift),
		lH = V(0, 0, -0.8 * shift),
		rH = V(0, 0, -0.8 * shift),
		lS = V(1.5 + 0.8 * breathe, 0, armIn),
		rS = V(1.5 + 0.8 * breathe, 0, -armIn),
		lE = V(-11 - 1.5 * breathe, 0, 0),
		rE = V(-11 - 1.5 * breathe, 0, 0),
	}
end

local function getT(j: Joint): CFrame
	return (j.handle :: any).Transform
end

local function setT(j: Joint, cf: CFrame)
	(j.handle :: any).Transform = cf
end

local scanAcc = SCAN_INTERVAL
RunService.PreSimulation:Connect(function(dt: number)
	local camPos = camera.CFrame.Position
	local now = os.clock()

	scanAcc += dt
	if scanAcc >= SCAN_INTERVAL then
		scanAcc = 0
		for _, inst in CollectionService:GetTagged(TAG) do
			if inst:IsA("Model") and not entries[inst] and inst:IsDescendantOf(workspace) then
				local root = inst:FindFirstChild("HumanoidRootPart")
				if root and root:IsA("BasePart") and (root.Position - camPos).Magnitude < RANGE then
					local e = begin(inst)
					if e then
						entries[inst] = e
					end
				end
			end
		end
	end

	for model, e in entries do
		local root = model:FindFirstChild("HumanoidRootPart")
		if not model:IsDescendantOf(workspace) or not (root and root:IsA("BasePart")) then
			entries[model] = nil
			continue
		end
		if (root.Position - camPos).Magnitude > RANGE + 20 then
			entries[model] = nil
			continue
		end
		if now >= e.nextRead then
			e.nextRead = now + TRACK_INTERVAL
			readTracks(e)
		end
		if e.other then
			continue
		end

		local v = root.AssemblyLinearVelocity
		local moving = not root.Anchored and Vector3.new(v.X, 0, v.Z).Magnitude > 1
		e.walkW += ((if moving then 1 else 0) - e.walkW) * math.min(1, dt * 6)
		local w = 1 - e.walkW
		local pose = standing(now, e.seed, e.armIn)
		for _, j in e.joints do
			local arm = ARM_KEYS[j.key]
			if arm and e.keepArms then
				continue
			end
			local anim = getT(j)
			local mine = RigPose.jointAngles(j.key, pose[j.key] or Vector3.zero)
			local out = if w >= 0.999 then mine else anim:Lerp(mine, w)
			-- walking: keep the stride, only bring the arms in to the body
			if e.walkW > 0 and (j.key == "lS" or j.key == "rS") then
				local z = (if j.key == "lS" then e.armIn else -e.armIn) * e.walkW
				out = out * RigPose.jointAngles(j.key, V(0, 0, z))
			end
			setT(j, out)
		end
	end
end)
