--!strict
--------------------------------------------------------------------------------
-- CutsceneActors.luau
-- Client-local performer rigs for cutscenes. Clones a real venue avatar (the
-- dialogue NPCs, falling back to the ambient crowd), strips everything that
-- would make it behave like a live NPC, builds its joints if the clone never
-- got any, and wraps it in a RigPose poser.
--
-- Actors are anchored at the root and posed purely through Motor6D C0s, so
-- they cost no physics and never replicate.
--------------------------------------------------------------------------------

local RigPose = require(script.Parent.RigPose)

local CutsceneActors = {}

export type Actor = {
	model: Model,
	root: BasePart?,
	rig: RigPose.Rig,
	phase: number,
	rate: number,
	amp: number,
	seated: boolean?,
	role: string?,
	facing: Vector3,
	right: Vector3,
	setPivot: (CFrame) -> (),
	head: () -> BasePart?,
	[string]: any,
}

local HOODIE = {
	Color3.fromRGB(40, 80, 150),
	Color3.fromRGB(45, 120, 75),
	Color3.fromRGB(120, 55, 140),
	Color3.fromRGB(165, 90, 45),
	Color3.fromRGB(55, 105, 120),
	Color3.fromRGB(95, 95, 110),
	Color3.fromRGB(170, 50, 60),
	Color3.fromRGB(200, 180, 60),
}
local SKIN = {
	Color3.fromRGB(235, 200, 170),
	Color3.fromRGB(205, 165, 125),
	Color3.fromRGB(160, 115, 85),
	Color3.fromRGB(110, 80, 55),
}

local STRIP = {
	"LuaSourceContainer",
	"ProximityPrompt",
	"BillboardGui",
	"Sound",
	"IKControl",
	"Animator",
	"ClickDetector",
}

local function shouldStrip(d: Instance): boolean
	for _, cls in STRIP do
		if d:IsA(cls) then
			return true
		end
	end
	return false
end

--- Every rig in the named workspace folders that is a usable R15 source.
function CutsceneActors.gatherSources(folders: { string }): { Model }
	local out: { Model } = {}
	for _, name in folders do
		local f = workspace:FindFirstChild(name)
		if f then
			for _, m in f:GetChildren() do
				if
					m:IsA("Model")
					and m:FindFirstChildOfClass("Humanoid")
					and m:FindFirstChild("HumanoidRootPart")
					and m:FindFirstChild("UpperTorso")
				then
					table.insert(out, m)
				end
			end
		end
		if #out > 0 then
			break
		end
	end
	return out
end

export type SpawnOpts = {
	source: Model?,
	parent: Instance,
	cframe: CFrame,
	repaint: boolean?, -- fresh hoodie / skin so a crowd of clones doesn't repeat
	stripClothes: boolean?,
	shadows: boolean?,
}

--- Build an actor. Returns nil when there is no source to clone.
function CutsceneActors.spawn(opts: SpawnOpts): Actor?
	local source = opts.source
	if not source then
		return nil
	end
	local wasArchivable = source.Archivable
	source.Archivable = true
	local model = source:Clone()
	source.Archivable = wasArchivable
	if not model then
		return nil
	end

	for _, d in model:GetDescendants() do
		local clothes = d:IsA("Shirt") or d:IsA("Pants") or d:IsA("ShirtGraphic")
		if shouldStrip(d) or (opts.stripClothes and clothes) then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = opts.shadows == true
			d.Massless = true
		end
	end

	if opts.repaint then
		local hoodie = HOODIE[math.random(#HOODIE)]
		local skin = SKIN[math.random(#SKIN)]
		local pants = Color3.fromRGB(math.random(36, 70), math.random(38, 64), math.random(46, 70))
		local function paint(names: { string }, col: Color3)
			for _, n in names do
				local pt = model:FindFirstChild(n)
				if pt and pt:IsA("BasePart") then
					pt.Color = col
				end
			end
		end
		paint({ "UpperTorso", "LowerTorso", "LeftUpperArm", "LeftLowerArm", "RightUpperArm", "RightLowerArm" }, hoodie)
		paint({ "Head", "LeftHand", "RightHand" }, skin)
		paint({ "LeftUpperLeg", "LeftLowerLeg", "LeftFoot", "RightUpperLeg", "RightLowerLeg", "RightFoot" }, pants)
	end

	RigPose.ensureMotors(model)

	local hum = model:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		hum.AutoRotate = false
		hum.BreakJointsOnDeath = false
		hum.PlatformStand = true
		hum:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
	end
	model.Name = "Actor"

	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		root.Anchored = true
		root.Transparency = 1
	end
	model:PivotTo(opts.cframe)
	model.Parent = opts.parent

	local cf = opts.cframe
	local actor: any = {
		model = model,
		root = root,
		rig = RigPose.new(model),
		-- Per-actor tempo and amplitude. Phase alone only slides two rigs apart
		-- in time; they would still move identically, and the eye reads that as
		-- the same person twice.
		phase = math.random() * 6.283,
		rate = 0.84 + math.random() * 0.34,
		amp = 0.82 + math.random() * 0.38,
		facing = cf.LookVector,
		right = cf.RightVector,
	}
	function actor.setPivot(p: CFrame)
		model:PivotTo(p)
		if root then
			root.Anchored = true
		end
		actor.facing = p.LookVector
		actor.right = p.RightVector
	end
	function actor.head(): BasePart?
		local h = model:FindFirstChild("Head")
		if h and h:IsA("BasePart") then
			return h
		end
		return nil
	end
	return actor :: Actor
end

--- Sit an actor on a surface: pose the hips and knees, then drop the root so
--- the underside of the thighs lands exactly on `seatTopY`.
function CutsceneActors.seat(actor: Actor, seatPos: Vector3, look: Vector3, seatTopY: number)
	actor.seated = true
	actor.rig:write({
		rH = Vector3.new(-90, 0, 0),
		lH = Vector3.new(-90, 0, 0),
		rK = Vector3.new(90, 0, 0),
		lK = Vector3.new(90, 0, 0),
	})
	local y = seatTopY + actor.rig:seatOffset()
	local p = Vector3.new(seatPos.X, y, seatPos.Z)
	actor.setPivot(CFrame.lookAt(p, p + Vector3.new(look.X, 0, look.Z)))
end

return CutsceneActors
