--!strict
--------------------------------------------------------------------------------
-- DeskBeacon.client.luau
-- Draws a personal, always-visible beacon over the local player's assigned desk
-- so they can always find their way back to it.
--
-- How it knows which desk is "yours":
--   GameStateManager assigns each player a PlayerDesk at match start and writes
--   the desk's id to the player's `AssignedDeskId` attribute (which replicates
--   to this client). We resolve the matching tagged desk and build the beacon.
--
-- The beacon is built entirely on the client, so each player only ever sees
-- their OWN desk marker:
--   • a BillboardGui label (AlwaysOnTop → visible through walls) with live
--     distance, and
--   • a soft neon light column rising from the desk for a "homing beacon" feel.
--------------------------------------------------------------------------------

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local DESK_TAG = GameConfig.TAGS.PLAYER_DESK

local player = Players.LocalPlayer

-- Beacon tuning
local FLOAT_HEIGHT = 6 -- studs above the desk the label floats
local FADE_DISTANCE = 6 -- within this many studs the beacon hides (you're there)
local PILLAR_HEIGHT = 14
local BEACON_COLOR = Color3.fromRGB(90, 200, 255)

--------------------------------------------------------------------------------
-- Helpers
--------------------------------------------------------------------------------

--- Resolve the BasePart for the desk carrying the given DeskId.
local function resolveDeskPart(deskId: string): BasePart?
	for _, desk in CollectionService:GetTagged(DESK_TAG) do
		if desk:GetAttribute("DeskId") == deskId then
			if desk:IsA("BasePart") then
				return desk
			elseif desk:IsA("Model") then
				return desk.PrimaryPart or desk:FindFirstChildWhichIsA("BasePart")
			end
		end
	end
	return nil
end

local function getRootPart(): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	return character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

--------------------------------------------------------------------------------
-- Beacon construction
--------------------------------------------------------------------------------

local function buildBeacon(deskPart: BasePart)
	-- ── Light column (local-only world part) ─────────────────────────────────
	local pillar = Instance.new("Part")
	pillar.Name = "DeskBeaconPillar"
	pillar.Anchored = true
	pillar.CanCollide = false
	pillar.CanQuery = false
	pillar.CanTouch = false
	pillar.CastShadow = false
	pillar.Material = Enum.Material.Neon
	pillar.Color = BEACON_COLOR
	pillar.Transparency = 0.55
	pillar.Size = Vector3.new(0.4, PILLAR_HEIGHT, 0.4)
	pillar.CFrame = deskPart.CFrame * CFrame.new(0, PILLAR_HEIGHT / 2 + 1.5, 0)
	pillar.Parent = workspace

	-- ── Floating label (visible through walls) ───────────────────────────────
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DeskBeaconLabel"
	billboard.Adornee = deskPart
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.Size = UDim2.new(0, 130, 0, 52)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, FLOAT_HEIGHT, 0)
	billboard.Parent = deskPart

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, 26)
	title.BackgroundTransparency = 1
	title.Text = "📍 YOUR DESK"
	title.Font = Enum.Font.GothamBold
	title.TextSize = 16
	title.TextColor3 = BEACON_COLOR
	title.TextStrokeTransparency = 0.3
	title.TextStrokeColor3 = Color3.new(0, 0, 0)
	title.Parent = billboard

	local distLabel = Instance.new("TextLabel")
	distLabel.Name = "Distance"
	distLabel.Size = UDim2.new(1, 0, 0, 20)
	distLabel.Position = UDim2.new(0, 0, 0, 26)
	distLabel.BackgroundTransparency = 1
	distLabel.Text = ""
	distLabel.Font = Enum.Font.GothamMedium
	distLabel.TextSize = 13
	distLabel.TextColor3 = Color3.new(1, 1, 1)
	distLabel.TextStrokeTransparency = 0.4
	distLabel.TextStrokeColor3 = Color3.new(0, 0, 0)
	distLabel.Parent = billboard

	-- ── Per-frame distance + proximity fade ──────────────────────────────────
	RunService.RenderStepped:Connect(function()
		local root = getRootPart()
		if not root then
			return
		end

		local dist = (root.Position - deskPart.Position).Magnitude

		if dist <= FADE_DISTANCE then
			-- You're at the desk — get out of the way
			billboard.Enabled = false
			pillar.Transparency = 1
		else
			billboard.Enabled = true
			pillar.Transparency = 0.55
			distLabel.Text = string.format("%dm", math.floor(dist))
		end
	end)
end

--------------------------------------------------------------------------------
-- Wait for the server's desk assignment, then build the beacon (once)
--------------------------------------------------------------------------------

task.spawn(function()
	-- Wait until the server assigns us a desk
	local deskId = player:GetAttribute("AssignedDeskId") :: string?
	while not deskId do
		player:GetAttributeChangedSignal("AssignedDeskId"):Wait()
		deskId = player:GetAttribute("AssignedDeskId") :: string?
	end

	-- The desk may still be replicating in — poll briefly for it
	local deskPart: BasePart? = nil
	for _ = 1, 100 do
		deskPart = resolveDeskPart(deskId :: string)
		if deskPart then
			break
		end
		task.wait(0.2)
	end

	if not deskPart then
		warn("[DeskBeacon] Could not find assigned desk:", deskId)
		return
	end

	buildBeacon(deskPart)
	print("[DeskBeacon] Beacon active for", deskId)
end)
