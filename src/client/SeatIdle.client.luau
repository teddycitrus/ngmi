--!strict
--------------------------------------------------------------------------------
-- SeatIdle.client.luau
-- Brings seated NPCs to life. The server seats them in a still posture solved
-- for each body (RigFactory.seatPosed, Shared.SeatPosture) and tags them
-- "SeatIdle" with the seat's measurements as attributes. Here each one near
-- the camera is rebuilt from those measurements and moved, every frame, on top
-- of that posture:
--   * typists work in bursts at the keys, reach for the mouse or trackpad,
--     pause to read, and lean back from the desk now and then, with every
--     hand target solved for their own arms against the real keyboard
--   * everyone breathes, shifts their weight and looks around a little
--   * phone users scroll, sleepers breathe slow and deep
--
-- Client only, through the joints' Transforms: nothing replicates, and the
-- neck stays free for HeadGlance's eye contact.
--------------------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RigPose = require(Shared:WaitForChild("RigPose"))
local SeatPosture = require(Shared:WaitForChild("SeatPosture"))

local TAG = "SeatIdle"
local REST_ATTRIBUTE = "RestFrame" -- RigFactory.REST_ATTRIBUTE
local RANGE = 110 -- studs from the camera
local SCAN_INTERVAL = 0.5
local BUILDS_PER_FRAME = 2 -- pose solves are a few ms; spread them out

local V = Vector3.new
local ZERO = Vector3.zero
local TAU = math.pi * 2

type Joint = { key: string, handle: Instance, a0: Attachment?, rest: CFrame }
type Entry = {
	model: Model,
	style: string,
	joints: { Joint },
	poses: { [string]: RigPose.Pose }, -- base, and for typists mouse / deskRest
	weights: { [string]: number },
	activity: string, -- "type", "pause", "mouse", "rest"
	nextSwitch: number,
	seed: number,
}

local camera = workspace.CurrentCamera
local entries: { [Model]: Entry } = {}
local pending: { Model } = {}
local queued: { [Model]: boolean } = {}

--------------------------------------------------------------------------------
-- Building
--------------------------------------------------------------------------------

local function contextOf(model: Model): SeatPosture.Context
	return {
		floor = model:GetAttribute("SeatFloor") :: number?,
		desk = model:GetAttribute("SeatDesk") :: number?,
		deskAt = model:GetAttribute("SeatKeys") :: Vector3?,
		mouseAt = model:GetAttribute("SeatMouse") :: Vector3?,
	}
end

local function build(model: Model): Entry?
	local style = model:GetAttribute("SeatStyle")
	if typeof(style) ~= "string" then
		return nil
	end
	local rig = RigPose.new(model)
	local joints: { Joint } = {}
	for key, names in RigPose.JOINTS do
		local part = model:FindFirstChild(names[1])
		if not part then
			continue
		end
		for _, c in part:GetChildren() do
			if c.Name ~= names[2] then
				continue
			end
			if c:IsA("AnimationConstraint") and c.Attachment0 then
				local a0 = c.Attachment0 :: Attachment
				local rest = a0:GetAttribute(REST_ATTRIBUTE)
				if typeof(rest) == "CFrame" then
					rig.base[key] = rest
					table.insert(joints, { key = key, handle = c, a0 = a0, rest = rest })
				end
				break
			elseif c:IsA("Motor6D") then
				local rest = c:GetAttribute(REST_ATTRIBUTE)
				if typeof(rest) == "CFrame" then
					rig.base[key] = rest
					table.insert(joints, { key = key, handle = c, rest = rest })
				end
				break
			end
		end
	end
	if #joints == 0 then
		return nil
	end
	local ctx = contextOf(model)
	local poses: { [string]: RigPose.Pose } = { base = SeatPosture.build(rig, style, ctx) }
	if style == "typing" or style == "deskRest" then
		poses.typing = if style == "typing" then poses.base else SeatPosture.build(rig, "typing", ctx)
		poses.mouse = SeatPosture.build(rig, "mouse", ctx)
		poses.deskRest = if style == "deskRest" then poses.base else SeatPosture.build(rig, "deskRest", ctx)
	end
	local seed = 0
	for i = 1, #model.Name do
		seed = (seed * 31 + string.byte(model.Name, i)) % 9973
	end
	return {
		model = model,
		style = style,
		joints = joints,
		poses = poses,
		weights = if poses.typing then { typing = if style == "typing" then 1 else 0, mouse = 0, deskRest = if style == "deskRest" then 1 else 0 } else { base = 1 },
		activity = if style == "deskRest" then "rest" else "type",
		nextSwitch = os.clock() + 2 + math.random() * 8,
		seed = seed / 97 + math.random() * 10,
	}
end

--------------------------------------------------------------------------------
-- Motion
--------------------------------------------------------------------------------

local function noise(seed: number, ch: number, t: number): number
	return math.clamp(math.noise(t, seed, ch) * 2, -1, 1)
end

--- The typist's next activity after `cur`.
local function nextActivity(cur: string): (string, number)
	if cur ~= "type" then
		return "type", 6 + math.random() * 12
	end
	local r = math.random()
	if r < 0.45 then
		return "mouse", 2.5 + math.random() * 4
	elseif r < 0.75 then
		return "pause", 1.5 + math.random() * 3
	end
	return "rest", 4 + math.random() * 6
end

local TARGET_POSE = { type = "typing", pause = "typing", mouse = "mouse", rest = "deskRest" }

local function add(p: RigPose.Pose, key: string, v: Vector3)
	p[key] = (p[key] or ZERO) + v
end

local function poseAt(e: Entry, t: number, dt: number): RigPose.Pose
	local s = e.seed
	local p: RigPose.Pose

	if e.poses.typing then
		if t >= e.nextSwitch then
			local nxt, dur = nextActivity(e.activity)
			e.activity, e.nextSwitch = nxt, t + dur
		end
		local want = TARGET_POSE[e.activity]
		local k = math.min(1, dt * 3.2)
		for name, w in e.weights do
			e.weights[name] = w + ((if name == want then 1 else 0) - w) * k
		end
		-- weighted mean of the variants, joint by joint
		p = {}
		local total = 0
		for name, w in e.weights do
			if w > 0.001 then
				total += w
				for key, v in e.poses[name] do
					p[key] = (p[key] or ZERO) + v * w
				end
			end
		end
		for key, v in p do
			p[key] = v / math.max(total, 1e-3)
		end

		local typing = e.weights.typing * (if e.activity == "type" then 1 else 0)
		if typing > 0.01 then
			-- bursts of keystrokes, each hand on its own rhythm
			local burst = math.clamp(noise(s, 1, t * 0.35) * 1.6 + 0.6, 0, 1) * typing
			local tapR = math.max(0, math.sin(t * TAU * 4.6 + s)) ^ 6 * burst
			local tapL = math.max(0, math.sin(t * TAU * 5.3 + s * 2)) ^ 6 * burst
			add(p, "rS", V(2.2 * tapR, 3 * noise(s, 2, t * 0.6), 0))
			add(p, "lS", V(2.2 * tapL, -3 * noise(s, 3, t * 0.6), 0))
			add(p, "rE", V(-4 * tapR, 0, 0))
			add(p, "lE", V(-4 * tapL, 0, 0))
			add(p, "rW", V(8 * tapR, 0, 0))
			add(p, "lW", V(8 * tapL, 0, 0))
			-- eyes between the screen and the keys
			add(p, "neck", V(4 * math.max(0, noise(s, 4, t * 0.25)), 0, 0))
		end
		if e.activity == "mouse" then
			local w = e.weights.mouse
			add(p, "rS", V(0, 2.2 * noise(s, 5, t * 0.9) * w, 1.2 * noise(s, 6, t * 0.7) * w))
			add(p, "rW", V(3 * math.max(0, math.sin(t * TAU * 1.1 + s)) ^ 12 * w, 0, 0)) -- clicks
		elseif e.activity == "pause" then
			add(p, "neck", V(-5, 0, 0)) -- reading the screen
		end
	else
		p = table.clone(e.poses.base)
		local st = e.style
		if st == "phone" then
			-- thumb scrolling: small flicks of the right hand
			local flick = math.max(0, math.sin(t * TAU * 0.7 + s)) ^ 16
			add(p, "rW", V(6 * flick, 0, 0))
			add(p, "neck", V(2 * noise(s, 7, t * 0.3), 0, 0))
		elseif st == "talking" then
			local g = math.clamp(noise(s, 8, t * 0.3) + 0.4, 0, 1)
			add(p, "rS", V(7 * math.sin(t * 2.3 + s) * g, 0, 4 * math.sin(t * 1.7 + s) * g))
			add(p, "rE", V(-6 * math.sin(t * 2.9 + s) * g, 0, 0))
			add(p, "neck", V(0, 6 * noise(s, 9, t * 0.2), 0))
		elseif st == "asleep" or st == "dozing" then
			-- slow, deep breaths and the odd nod
			local b = math.sin(t * 1.3 + s)
			add(p, "waist", V(1.4 * b, 0, 0))
			add(p, "neck", V(1.2 * b + 3 * math.max(0, noise(s, 10, t * 0.15)), 0, 0))
			return p
		elseif st == "chin" or st == "headHands" then
			add(p, "neck", V(0, 3 * noise(s, 11, t * 0.15), 0))
		end
	end

	-- everyone: breathing, a slow weight shift, and the odd look around
	local breathe = math.sin(t * 1.6 + s)
	local glance = math.max(0, noise(s, 12, t * 0.12) - 0.4) * 1.6
	add(p, "waist", V(0.8 * breathe, 0, 1.2 * noise(s, 13, t * 0.08)))
	add(p, "neck", V(-0.5 * breathe, 22 * glance * (if noise(s, 14, t * 0.05) > 0 then 1 else -1), 0))
	add(p, "rS", V(0.6 * breathe, 0, 0))
	add(p, "lS", V(0.6 * breathe, 0, 0))
	return p
end

local function setTransform(j: Joint, cf: CFrame)
	(j.handle :: any).Transform = cf
end

local function release(e: Entry)
	for _, j in e.joints do
		if j.handle.Parent then
			setTransform(j, CFrame.identity)
		end
	end
end

--- Write `p` through the Transforms: each joint ends up at rest * p[key],
--- whatever its Attachment0 currently holds (the server's still pose). The
--- neck only takes the idle motion's difference from the base, so a
--- HeadGlance turn on its attachment stays intact.
local function write(e: Entry, p: RigPose.Pose)
	local base = e.poses.base
	for _, j in e.joints do
		local key = j.key
		if key == "root" then
			continue
		end
		local target = p[key] or ZERO
		if key == "neck" then
			local d = target - (base.neck or ZERO)
			setTransform(j, RigPose.jointAngles(key, d))
			continue
		end
		local now = if j.a0 then j.a0.CFrame else (j.handle :: Motor6D).C0
		local want = j.rest * RigPose.jointAngles(key, target)
		setTransform(j, (now:Inverse() * want).Rotation)
	end
end

--------------------------------------------------------------------------------
-- Loop
--------------------------------------------------------------------------------

local scanAcc = SCAN_INTERVAL
RunService.PreSimulation:Connect(function(dt: number)
	local camPos = camera.CFrame.Position
	local now = os.clock()

	scanAcc += dt
	if scanAcc >= SCAN_INTERVAL then
		scanAcc = 0
		for _, inst in CollectionService:GetTagged(TAG) do
			if inst:IsA("Model") and not entries[inst] and not queued[inst] and inst:IsDescendantOf(workspace) then
				local root = inst:FindFirstChild("HumanoidRootPart")
				if root and root:IsA("BasePart") and (root.Position - camPos).Magnitude < RANGE then
					queued[inst] = true
					table.insert(pending, inst)
				end
			end
		end
	end

	for _ = 1, BUILDS_PER_FRAME do
		local model = table.remove(pending, 1)
		if not model then
			break
		end
		queued[model] = nil
		if model:IsDescendantOf(workspace) then
			local ok, e = pcall(build, model)
			if ok and e then
				entries[model] = e
			end
		end
	end

	for model, e in entries do
		local root = model:FindFirstChild("HumanoidRootPart")
		if not model:IsDescendantOf(workspace) or not (root and root:IsA("BasePart")) then
			entries[model] = nil
			continue
		end
		if (root.Position - camPos).Magnitude > RANGE + 20 or not CollectionService:HasTag(model, TAG) then
			release(e)
			entries[model] = nil
			continue
		end
		write(e, poseAt(e, now, dt))
	end
end)
