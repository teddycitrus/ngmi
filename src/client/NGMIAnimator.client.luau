--!strict
--------------------------------------------------------------------------------
-- NGMIAnimator.client.luau
-- Procedural, deliberately wrong body language for every NGMI, plus its voice.
--
-- The server builds NGMIs from venue avatar rigs (NGMIController) and
-- replicates its AI state as the "AIState" attribute and each telegraphed
-- attack as "AttackKind" + "AttackSeq". This script poses the joints locally
-- every frame through RigPose; the edits never replicate, so the animation
-- costs no bandwidth and each player sees a smooth local result.
--
-- Movement is modelled on the Clickers from The Last of Us:
--   * Stalk (patrol): hunched, a limping uneven gait, one arm curled dead
--     against the chest and the other swinging loose a beat late. Every few
--     strides it stumbles: the torso pitches, a leg shoots out to catch it.
--   * Head rattle: bursts of violent side-to-side shaking, in time with the
--     clicking in its throat (NGMIVoice).
--   * Alert: it goes rigid, then throws its head back and screeches.
--   * Chase: a bent-double sprint, arms flailing out to the sides, the head
--     thrashing.
--   * Attack: a coiled crouch between strikes; swipes wind the arm back over
--     the shoulder and rake across the body; the lunge drops low and launches
--     with both hands out.
--   * Sprayed: a violent recoil, arms up over the face, then a cowering run.
--
-- Underneath everything sits NGMIMutation.TWIST, the same skeletal deformity
-- the night transition folds into the turned hackers.
--
-- NGMIs farther than CULL_DISTANCE from the camera are not posed at all.
--------------------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RigPose = require(Shared:WaitForChild("RigPose"))
local NGMIMutation = require(Shared:WaitForChild("NGMIMutation"))
local NGMIVoice = require(script.Parent:WaitForChild("NGMIVoice"))
local Poses = require(script.Parent:WaitForChild("NGMI"):WaitForChild("Poses"))

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local NGMIStunned = Remotes:WaitForChild("NGMIStunned") :: RemoteEvent

local camera = workspace.CurrentCamera

type Pose = RigPose.Pose
local V = Vector3.new
local add = RigPose.add

--------------------------------------------------------------------------------
-- Tunables
--------------------------------------------------------------------------------

local CULL_DISTANCE = 140

local STRIDE_LENGTH = 4.2 -- studs per full gait cycle at a stalk
local SPRINT_STRIDE = 7.5
local SHARPNESS = 16 -- pose smoothing
local SHARPNESS_ATTACK = 30

local SNAP_MIN, SNAP_MAX = 0.35, 2.4 -- head snap interval
local STUMBLE_MIN, STUMBLE_MAX = 3, 7
local STUMBLE_LENGTH = 0.65

local STUTTER_MIN_GAP, STUTTER_MAX_GAP = 4, 9
local STUTTER_FPS = 9
local FREEZE_CHANCE = 0.25

local SCREECH_LENGTH = 0.55
local FLINCH_LENGTH = 0.55


--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

type Rig = Poses.Rig

local rigs: { [Model]: Rig } = {}
local rng = Random.new()

local function register(model: Model)
	if rigs[model] or not model:IsA("Model") then
		return
	end
	local root = model:WaitForChild("HumanoidRootPart", 10)
	if not (root and root:IsA("BasePart")) then
		return
	end
	-- Joints replicate with the model, but give stragglers a moment.
	local poser = RigPose.new(model)
	local deadline = os.clock() + 5
	while next(poser.J) == nil and os.clock() < deadline do
		task.wait(0.2)
		poser = RigPose.new(model)
	end
	if next(poser.J) == nil then
		return
	end
	if not model:IsDescendantOf(workspace) then
		return
	end

	local now = os.clock()
	rigs[model] = {
		model = model,
		root = root,
		rig = poser,
		voice = NGMIVoice.attach(model),
		seed = rng:NextNumber(0, 1000),
		gait = rng:NextNumber(0, math.pi * 2),
		head = Vector3.zero,
		nextSnap = now + rng:NextNumber(SNAP_MIN, SNAP_MAX),
		rattleAt = -10,
		nextStumble = now + rng:NextNumber(STUMBLE_MIN, STUMBLE_MAX),
		stumbleAt = -10,
		stutterUntil = 0,
		nextStutter = now + rng:NextNumber(STUTTER_MIN_GAP, STUTTER_MAX_GAP),
		freezing = false,
		lastApply = 0,
		state = model:GetAttribute("AIState") :: string?,
		stateAt = now,
		attackKind = nil,
		attackAt = -10,
		flinchAt = -10,
	}

	model:GetAttributeChangedSignal("AttackSeq"):Connect(function()
		local r = rigs[model]
		if not r then
			return
		end
		r.attackKind = model:GetAttribute("AttackKind") :: string?
		r.attackAt = os.clock()
		if r.voice then
			r.voice:play(if r.attackKind == "lunge" then "screech" else "snarl")
		end
	end)
	model:GetAttributeChangedSignal("AIState"):Connect(function()
		local r = rigs[model]
		if not r then
			return
		end
		local state = model:GetAttribute("AIState") :: string?
		r.state = state
		r.stateAt = os.clock()
		if r.voice then
			if state == "ALERT" then
				r.voice:play("screech")
			elseif state == "CHASE" then
				r.voice:play("snarl")
			end
		end
	end)
	model.AncestryChanged:Connect(function()
		if not model:IsDescendantOf(workspace) then
			local r = rigs[model]
			if r and r.voice then
				r.voice:destroy()
			end
			rigs[model] = nil
		end
	end)
end

--------------------------------------------------------------------------------
-- Per-rig update
--------------------------------------------------------------------------------

local function updateRig(r: Rig, dt: number, now: number, camDist: number)
	local state = r.state
	local vel = r.root.AssemblyLinearVelocity
	local speed = Vector3.new(vel.X, 0, vel.Z).Magnitude

	-- voice first, so a click burst can drive the head this frame
	if r.voice then
		if r.voice:update(dt, state, camDist) == "click" then
			r.rattleAt = now
		end
	end

	-- Stop-motion stutter: the pose holds (freeze) or refreshes at ~9 fps for
	-- a beat while the body keeps sliding, so it reads as frames missing.
	-- Never during an attack, where the timing has to read.
	local attackT = now - r.attackAt
	local attacking = r.attackKind ~= nil and attackT < 1.6
	if now >= r.nextStutter then
		r.stutterUntil = now + rng:NextNumber(0.25, 0.6)
		r.nextStutter = r.stutterUntil + rng:NextNumber(STUTTER_MIN_GAP, STUTTER_MAX_GAP)
		r.freezing = rng:NextNumber() < FREEZE_CHANCE
	end
	if now < r.stutterUntil and not attacking then
		if r.freezing or now - r.lastApply < 1 / STUTTER_FPS then
			return
		end
		dt = now - r.lastApply
	end
	r.lastApply = now

	local sprinting = state == "CHASE" or state == "RETREAT"
	local strideLen = if sprinting then SPRINT_STRIDE else STRIDE_LENGTH
	r.gait += speed * dt / strideLen * math.pi * 2
	local k = math.clamp(speed / (if sprinting then 18 else 9), 0, 1)

	-- head snaps: jump to a new angle almost instantly, then hold dead still
	if now >= r.nextSnap then
		r.nextSnap = now + rng:NextNumber(SNAP_MIN, SNAP_MAX)
		r.head = V(rng:NextNumber(-20, 25), rng:NextNumber(-60, 60), rng:NextNumber(-30, 30))
		if rng:NextNumber() < 0.3 then
			r.rattleAt = now
		end
	end

	local pose: Pose
	local sharp = SHARPNESS
	local stateT = now - r.stateAt
	local atk = if attacking then Poses.attackPose(r, attackT, now) else nil

	if atk then
		pose = atk
		sharp = SHARPNESS_ATTACK
	elseif state == "CHASE" then
		pose = Poses.sprint(r, math.max(k, 0.5), now)
	elseif state == "ALERT" then
		-- rigid for a beat, then the screech
		local u = math.clamp((stateT - 0.08) / 0.12, 0, 1) * Poses.window(stateT - 0.08, SCREECH_LENGTH + 0.2) ^ 0.4
		pose = add(Poses.blend3(Poses.stalk(r, 0), Poses.SCREECH, u), Poses.tremor(r, now, 3 + 9 * u, 20))
		sharp = 24
	elseif state == "ATTACK" then
		pose = add(Poses.stance(now), { neck = r.head * 0.4 })
	elseif state == "RETREAT" or state == "STUNNED" then
		pose = add(Poses.sprint(r, math.max(k, 0.4), now), Poses.COWER)
		pose.waist = V(24, 0, 0)
	else
		-- PATROL / LOST: the stalk, head snapping around
		pose = Poses.stalk(r, k)
		local look = if state == "LOST" then V(-10, r.head.Y * 1.3, r.head.Z * 0.5) else r.head
		pose = add(pose, { neck = look })

		-- stumble: the torso pitches, a leg shoots out to catch it
		if k > 0.3 and now >= r.nextStumble then
			r.stumbleAt = now
			r.nextStumble = now + rng:NextNumber(STUMBLE_MIN, STUMBLE_MAX)
		end
		local st = Poses.window(now - r.stumbleAt, STUMBLE_LENGTH)
		if st > 0 then
			pose = add(pose, {
				waist = V(26 * st, 0, 10 * st),
				rH = V(-38 * st, 0, 0),
				lK = V(30 * st, 0, 0),
				rS = V(40 * st, 0, 30 * st),
				lS = V(50 * st, 0, -20 * st),
				rootPos = V(0, -0.45 * st, 0),
			})
		end
	end

	-- the clicker rattle rides on whatever the head is doing
	local rt = now - r.rattleAt
	if rt < Poses.RATTLE_LENGTH then
		pose = add(pose, { neck = Poses.rattle(rt) })
	end

	-- sprayed: violent recoil over the top of everything
	local ft = now - r.flinchAt
	if ft < FLINCH_LENGTH then
		pose = RigPose.blend(pose, add(Poses.FLINCH, Poses.tremor(r, now, 14, 24)), Poses.window(ft, FLINCH_LENGTH) ^ 0.5)
		sharp = 30
	end

	pose = add(add(pose, NGMIMutation.TWIST), Poses.tremor(r, now, 2.5, 4))
	r.rig:apply(pose, dt, sharp)
end

--------------------------------------------------------------------------------
-- Main loop
--------------------------------------------------------------------------------

RunService.RenderStepped:Connect(function(dt: number)
	local now = os.clock()
	local camPos = camera.CFrame.Position
	dt = math.min(dt, 1 / 15)
	for model, r in rigs do
		if not r.root.Parent then
			if r.voice then
				r.voice:destroy()
			end
			rigs[model] = nil
		else
			local d = (r.root.Position - camPos).Magnitude
			if d <= CULL_DISTANCE then
				updateRig(r, dt, now, d)
			end
		end
	end
end)

NGMIStunned.OnClientEvent:Connect(function(model: Instance)
	local r = if typeof(model) == "Instance" and model:IsA("Model") then rigs[model] else nil
	if r then
		r.flinchAt = os.clock()
		r.attackKind = nil
		if r.voice then
			r.voice:play("pain")
		end
	end
end)

CollectionService:GetInstanceAddedSignal("NGMI"):Connect(function(inst)
	if inst:IsA("Model") then
		task.spawn(register, inst)
	end
end)

CollectionService:GetInstanceRemovedSignal("NGMI"):Connect(function(inst)
	if inst:IsA("Model") then
		local r = rigs[inst]
		if r and r.voice then
			r.voice:destroy()
		end
		rigs[inst] = nil
	end
end)

for _, inst in CollectionService:GetTagged("NGMI") do
	if inst:IsA("Model") then
		task.spawn(register, inst)
	end
end

print("[NGMIAnimator] Initialised - clicker locomotion, attacks and voices ready")
