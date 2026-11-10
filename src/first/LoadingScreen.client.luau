--!strict
--------------------------------------------------------------------------------
-- LoadingScreen.client.luau (ReplicatedFirst)
-- Covers the screen from the first frame until the game is ready to be seen.
--
--   1. waits for the place snapshot, the venue (workspace.Map) and the
--      character
--   2. preloads the venue's, NPCs' and sky's meshes, textures and sounds
--   3. tells the server it is loaded (Remotes.ClientReady); a match server
--      holds the match start until every player has done this
--   4. on a match server, stays up until the opening cinematic has built its
--      set and is on its first frame (LocalPlayer attribute OpeningLive),
--      then fades out onto it
--
-- Lobby servers, Studio and players joining a match in progress skip step 4.
--------------------------------------------------------------------------------

local ContentProvider = game:GetService("ContentProvider")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedFirst = game:GetService("ReplicatedFirst")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

local PRELOAD_TIMEOUT = 40 -- seconds before we stop waiting on asset downloads
local OPENING_TIMEOUT = 30 -- seconds after loading to wait for the opening
local BATCH = 40 -- instances per PreloadAsync call

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "LoadingScreen"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 1000
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
-- cutscenes hide every other ScreenGui; this one has to stay over them
gui:SetAttribute("CutsceneExempt", true)

local bg = Instance.new("Frame")
bg.BackgroundColor3 = Color3.fromRGB(8, 8, 11)
bg.BorderSizePixel = 0
bg.Size = UDim2.fromScale(1, 1)
bg.Parent = gui

local title = Instance.new("TextLabel")
title.AnchorPoint = Vector2.new(0.5, 0.5)
title.Position = UDim2.fromScale(0.5, 0.44)
title.Size = UDim2.new(0.8, 0, 0, 56)
title.BackgroundTransparency = 1
title.FontFace = Font.fromEnum(Enum.Font.GothamBlack)
title.TextSize = 44
title.TextColor3 = Color3.fromRGB(240, 240, 244)
title.Text = "NOT GONNA MAKE IT"
title.Parent = bg

local track = Instance.new("Frame")
track.AnchorPoint = Vector2.new(0.5, 0.5)
track.Position = UDim2.fromScale(0.5, 0.53)
track.Size = UDim2.new(0, 320, 0, 4)
track.BackgroundColor3 = Color3.fromRGB(40, 40, 48)
track.BorderSizePixel = 0
track.Parent = bg
local trackCorner = Instance.new("UICorner")
trackCorner.CornerRadius = UDim.new(1, 0)
trackCorner.Parent = track

local fill = Instance.new("Frame")
fill.Size = UDim2.fromScale(0, 1)
fill.BackgroundColor3 = Color3.fromRGB(235, 235, 240)
fill.BorderSizePixel = 0
fill.Parent = track
local fillCorner = Instance.new("UICorner")
fillCorner.CornerRadius = UDim.new(1, 0)
fillCorner.Parent = fill

-- a short highlight sweeping the bar, so it reads as alive while a step stalls
local shimmer = Instance.new("Frame")
shimmer.AnchorPoint = Vector2.new(0.5, 0)
shimmer.Size = UDim2.new(0, 60, 1, 0)
shimmer.BackgroundColor3 = Color3.new(1, 1, 1)
shimmer.BackgroundTransparency = 0.75
shimmer.BorderSizePixel = 0
shimmer.Parent = track
local shimmerGrad = Instance.new("UIGradient")
shimmerGrad.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.5, 0),
	NumberSequenceKeypoint.new(1, 1),
})
shimmerGrad.Parent = shimmer
track.ClipsDescendants = true

local status = Instance.new("TextLabel")
status.AnchorPoint = Vector2.new(0.5, 0)
status.Position = UDim2.fromScale(0.5, 0.555)
status.Size = UDim2.new(0, 320, 0, 20)
status.BackgroundTransparency = 1
status.FontFace = Font.fromEnum(Enum.Font.Gotham)
status.TextSize = 14
status.TextColor3 = Color3.fromRGB(150, 150, 160)
status.Text = ""
status.Parent = bg

gui.Parent = playerGui
ReplicatedFirst:RemoveDefaultLoadingScreen()

local shown = 0 -- displayed progress, eased toward target
local target = 0
RunService.RenderStepped:Connect(function(dt: number)
	shown += (target - shown) * math.min(1, dt * 6)
	fill.Size = UDim2.fromScale(shown, 1)
	local t = (os.clock() * 0.6) % 1
	shimmer.Position = UDim2.new(t * 1.4 - 0.2, 0, 0, 0)
end)

local function setStep(text: string, progress: number)
	status.Text = text
	target = math.max(target, progress)
end

--------------------------------------------------------------------------------
-- Loading
--------------------------------------------------------------------------------
setStep("Connecting", 0.05)
if not game:IsLoaded() then
	game.Loaded:Wait()
end

setStep("Loading venue", 0.2)
local map = workspace:WaitForChild("Map", 60)
if not player.Character then
	player.CharacterAdded:Wait()
end

-- Everything with an asset of its own. PreloadAsync also walks descendants,
-- but listing the asset holders directly gives a real progress count.
local ASSET_CLASSES = {
	"MeshPart",
	"SpecialMesh",
	"Decal",
	"Texture",
	"SurfaceAppearance",
	"Sound",
	"ParticleEmitter",
	"Beam",
	"Trail",
	"ImageLabel",
	"ImageButton",
	"Sky",
	"Shirt",
	"Pants",
}
local function isAssetHolder(d: Instance): boolean
	for _, c in ASSET_CLASSES do
		if d:IsA(c) then
			return true
		end
	end
	return false
end

local holders: { Instance } = {}
local roots: { Instance? } = { map, workspace:FindFirstChild("NPCs"), Lighting, player.Character }
for _, root in roots do
	if root then
		for _, d in root:GetDescendants() do
			if isAssetHolder(d) then
				table.insert(holders, d)
			end
		end
	end
end

setStep("Loading assets", 0.3)
local done = 0
local preloadFinished = false
task.spawn(function()
	for i = 1, #holders, BATCH do
		local batch = table.move(holders, i, math.min(i + BATCH - 1, #holders), 1, {})
		pcall(function()
			ContentProvider:PreloadAsync(batch)
		end)
		done = math.min(i + BATCH - 1, #holders)
		target = math.max(target, 0.3 + 0.6 * (done / math.max(#holders, 1)))
	end
	preloadFinished = true
end)
local deadline = os.clock() + PRELOAD_TIMEOUT
while not preloadFinished and os.clock() < deadline do
	task.wait(0.1)
end

-- Phase at the moment we finish loading: still LOBBY means the match (and its
-- opening) has not started yet; anything else means we joined mid-match.
local phaseValue = ReplicatedStorage:FindFirstChild("CurrentPhase") :: IntValue?
local matchRunning = phaseValue ~= nil and phaseValue.Value ~= 0
local isMatchServer = ReplicatedStorage:GetAttribute("IsMatchServer") == true

local remotes = ReplicatedStorage:WaitForChild("Remotes", 30)
local clientReady = remotes and remotes:WaitForChild("ClientReady", 30)
if clientReady and clientReady:IsA("RemoteEvent") then
	clientReady:FireServer()
end

if isMatchServer and not matchRunning then
	setStep("Waiting for your team", 0.95)
	local opened = os.clock() + OPENING_TIMEOUT
	while not player:GetAttribute("OpeningLive") and os.clock() < opened do
		task.wait(0.05)
	end
else
	-- give the renderer a moment on the real scene before revealing it
	setStep("Starting", 0.95)
	task.wait(0.6)
end

--------------------------------------------------------------------------------
-- Reveal, and cover again for the match start
--------------------------------------------------------------------------------
local fadeInfo = TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local fadeTweens: { Tween } = {}

local function setVisible(alpha: number, tweenIt: boolean)
	for _, t in fadeTweens do
		t:Cancel()
	end
	table.clear(fadeTweens)
	local function set(inst: Instance, props: { [string]: number })
		if tweenIt then
			local t = TweenService:Create(inst, fadeInfo, props)
			t:Play()
			table.insert(fadeTweens, t)
		else
			for k, v in props do
				(inst :: any)[k] = v
			end
		end
	end
	set(bg, { BackgroundTransparency = alpha })
	set(title, { TextTransparency = alpha })
	set(status, { TextTransparency = alpha })
	set(track, { BackgroundTransparency = alpha })
	set(fill, { BackgroundTransparency = alpha })
	set(shimmer, { BackgroundTransparency = if alpha < 1 then 0.75 else 1 })
end

local function reveal()
	target = 1
	task.wait(0.15)
	setVisible(1, true)
	task.wait(0.75)
	gui.Enabled = false
end

reveal()

-- Leaving the mode menu starts the match: on this server (Studio, or a lobby
-- fallback) the phase flips to DAY1, or the lobby teleports the party to a
-- match server. Either way the screen goes straight back to this loader, with
-- no fade in, so nothing between the menu and the opening's first frame is
-- ever seen: not the menu fading, the HUD's day banner or the seat teleport.
local covering = false
local cancelled = false
local function coverUntilOpening(text: string)
	if covering or player:GetAttribute("OpeningLive") then
		return
	end
	covering = true
	cancelled = false
	shown, target = 0.9, 0.9
	status.Text = text
	gui.Enabled = true
	setVisible(0, false)
	local openBy = os.clock() + OPENING_TIMEOUT
	local phaseNow = ReplicatedStorage:FindFirstChild("CurrentPhase") :: IntValue?
	while not player:GetAttribute("OpeningLive") and not cancelled and os.clock() < openBy do
		-- an admin jump past DAY1 skips the opening; don't wait it out
		if phaseNow and phaseNow.Value > 1 then
			break
		end
		task.wait()
	end
	reveal()
	covering = false
end

local TeleportService = game:GetService("TeleportService")
local remotes2 = ReplicatedStorage:WaitForChild("Remotes")

-- Same-server start (Studio): StartGame, then the phase flips below.
local startGame = remotes2:WaitForChild("StartGame") :: RemoteEvent
startGame.OnClientEvent:Connect(function()
	task.spawn(coverUntilOpening, "Starting match")
end)

-- Lobby server: the party is being teleported to a match server. The cover
-- rides along as the teleport screen, so the match server's own loader takes
-- over from an identical screen. A failed teleport hands the menu back.
local queueUpdate = remotes2:WaitForChild("QueueUpdate") :: RemoteEvent
queueUpdate.OnClientEvent:Connect(function(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	if payload.type == "launching" then
		pcall(function()
			local carry = gui:Clone()
			carry.Enabled = true
			TeleportService:SetTeleportGui(carry)
		end)
		task.spawn(coverUntilOpening, "Starting match")
	elseif payload.type == "cancelled" and covering then
		cancelled = true
	end
end)

local phase = ReplicatedStorage:WaitForChild("CurrentPhase", 30) :: IntValue?
if phase then
	local last = phase.Value
	phase.Changed:Connect(function(value: number)
		local was = last
		last = value
		if value == 0 then
			-- back in the lobby: the next match plays its own opening
			player:SetAttribute("OpeningLive", nil)
		elseif was == 0 then
			task.spawn(coverUntilOpening, "Starting match")
		end
	end)
end
