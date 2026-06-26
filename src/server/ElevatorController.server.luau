--!strict
--------------------------------------------------------------------------------
-- ElevatorController.server.luau
-- Drives the working elevator cars that MapBuilder constructs.
--
-- Contract (set up by MapBuilder.buildElevators):
--   • Each car is a Model tagged TAGS.ELEVATOR_CAR, with attribute ElevatorId and
--     a PrimaryPart named "CarFloor".
--   • Every button (per-floor call buttons in the shaft + destination buttons
--     inside the car) is a BasePart tagged TAGS.ELEVATOR_CALL carrying a child
--     ProximityPrompt plus attributes ElevatorId (string) and TargetY (number =
--     the world-Y the CarFloor should travel to).
--
-- Pressing any button rides that elevator to the requested Y, carrying along any
-- player standing inside the car. Load order with MapBuilder doesn't matter — we
-- pick up existing tagged instances and also listen for ones added later.
--------------------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")
local RunService        = game:GetService("RunService")
local TweenService      = game:GetService("TweenService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local TAGS = GameConfig.TAGS

local cars: { [string]: Model } = {}
local moving: { [string]: boolean } = {}

--- Is the floor containing world-Y `y` powered? During the NIGHT2 blackout the
--- PowerManager publishes FloorPower0/1/2 = false until each floor is restored; a
--- nil attribute (daytime, no blackout in effect) counts as powered. The elevator
--- is dead while its floor has no power.
local function floorPowered(y: number): boolean
	local f = math.clamp(math.floor(y / 18), 0, 2)
	local v = workspace:GetAttribute("FloorPower" .. f)
	if v == nil then
		return true
	end
	return v == true
end

--- Slide an elevator's shaft doors: the pair at floor `carY` open (if `open`),
--- every other floor's pair shut. Doors carry ClosedZ/OpenZ/CarY attributes.
local function setDoors(id: string, carY: number, open: boolean)
	for _, d in CollectionService:GetTagged(TAGS.ELEVATOR_DOOR) do
		if d:IsA("BasePart") and d:GetAttribute("ElevatorId") == id then
			local atThisFloor = math.abs((d:GetAttribute("CarY") :: number? or -999) - carY) < 1
			local targetZ = (open and atThisFloor) and d:GetAttribute("OpenZ") or d:GetAttribute("ClosedZ")
			if typeof(targetZ) == "number" then
				TweenService:Create(d, TweenInfo.new(0.5, Enum.EasingStyle.Quad), {
					Position = Vector3.new(d.Position.X, d.Position.Y, targetZ),
				}):Play()
			end
		end
	end
end

local function registerCar(model: Instance)
	if not model:IsA("Model") then
		return
	end
	local id = model:GetAttribute("ElevatorId")
	if typeof(id) == "string" and model.PrimaryPart then
		cars[id] = model
	end
end

--- Smoothly move car `id` so its CarFloor reaches world-Y `targetY`.
local function ride(id: string, targetY: number)
	local car = cars[id]
	if not car or not car.PrimaryPart or moving[id] then
		return
	end
	local pivot = car:GetPivot()
	local fromY = pivot.Position.Y
	if math.abs(fromY - targetY) < 0.4 then
		return
	end

	moving[id] = true
	-- shut the doors before departing, give them a moment to close
	setDoors(id, fromY, false)
	task.wait(0.55)

	local baseX, baseZ = pivot.Position.X, pivot.Position.Z
	local half = car.PrimaryPart.Size * 0.5
	local dur = 0.4 + math.abs(targetY - fromY) / 18 * 1.1
	local t0 = os.clock()
	local prevY = fromY

	local conn: RBXScriptConnection
	conn = RunService.Heartbeat:Connect(function()
		local a = math.clamp((os.clock() - t0) / dur, 0, 1)
		-- easeInOutQuad so the car accelerates and settles gently
		local e = if a < 0.5 then 2 * a * a else 1 - ((-2 * a + 2) ^ 2) / 2
		local newY = fromY + (targetY - fromY) * e
		car:PivotTo(CFrame.new(baseX, newY, baseZ))

		-- carry any rider standing on the car floor
		local dy = newY - prevY
		prevY = newY
		for _, plr in Players:GetPlayers() do
			local ch = plr.Character
			local hrp = ch and ch:FindFirstChild("HumanoidRootPart")
			if hrp and hrp:IsA("BasePart") then
				local rel = hrp.Position - Vector3.new(baseX, newY, baseZ)
				if math.abs(rel.X) < half.X + 1 and math.abs(rel.Z) < half.Z + 1 and rel.Y > -1 and rel.Y < 13 then
					hrp.CFrame = hrp.CFrame + Vector3.new(0, dy, 0)
				end
			end
		end

		if a >= 1 then
			conn:Disconnect()
			moving[id] = false
			-- arrived — open the doors at this floor
			setDoors(id, targetY, true)
		end
	end)
end

local function hookButton(part: Instance)
	if not part:IsA("BasePart") then
		return
	end
	local prompt = part:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then
		return
	end
	prompt.Triggered:Connect(function()
		local id = part:GetAttribute("ElevatorId")
		local ty = part:GetAttribute("TargetY")
		if typeof(id) == "string" and typeof(ty) == "number" then
			-- No power, no elevator: refuse if either the car's current floor or the
			-- destination floor is blacked out.
			local car = cars[id]
			local fromY = (car and car.PrimaryPart) and car:GetPivot().Position.Y or nil
			if fromY and (not floorPowered(fromY) or not floorPowered(ty)) then
				return
			end
			ride(id, ty)
		end
	end)
end

for _, m in CollectionService:GetTagged(TAGS.ELEVATOR_CAR) do
	registerCar(m)
end
CollectionService:GetInstanceAddedSignal(TAGS.ELEVATOR_CAR):Connect(registerCar)

for _, b in CollectionService:GetTagged(TAGS.ELEVATOR_CALL) do
	hookButton(b)
end
CollectionService:GetInstanceAddedSignal(TAGS.ELEVATOR_CALL):Connect(hookButton)

-- Cars park at the ground floor at the start, so open those doors and shut the
-- rest (gives a moment for the cars + doors to exist).
task.delay(1, function()
	for id, car in cars do
		setDoors(id, car:GetPivot().Position.Y, true)
	end
end)

print("[ElevatorController] Online.")
