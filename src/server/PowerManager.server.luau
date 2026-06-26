--!strict
--------------------------------------------------------------------------------
-- PowerManager.server.luau
-- NIGHT2 blackout + floor-by-floor restoration.
--
-- When the final night begins the venue's power is cut: every ceiling light goes
-- dark and the electrical panels are HIGHLIGHTED so players can find them. Then:
--   • Repairing a panel kicks ~1/5 of that panel's nearby lights back on, dim, as
--     if running on backup power.
--   • Repairing EVERY panel on a floor restores that whole floor's lights
--     (partially) and flags the floor's power as restored — which is when that
--     floor's work (coding at your desk, server repairs) can resume.
--
-- It identifies which panel was repaired by proximity to the repairing player, so
-- it needs no changes to the panel UI or unique panel ids. It exposes per-floor
-- power as workspace attributes (FloorPower0/1/2) for other systems to gate on.
--------------------------------------------------------------------------------

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage     = game:GetService("ServerStorage")
local CollectionService = game:GetService("CollectionService")

local GameConfig = require(ReplicatedStorage.Shared.GameConfig)
local TAGS = GameConfig.TAGS
local NIGHT2 = GameConfig.Phase.NIGHT2

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PanelRepaired = Remotes:WaitForChild("PanelRepaired") :: RemoteEvent
local QuestUpdate = Remotes:WaitForChild("QuestUpdate") :: RemoteEvent

--- Push an objective's live state to every client's objectives panel.
local function fireObjective(id: string, text: string, completed: boolean)
	for _, plr in Players:GetPlayers() do
		QuestUpdate:FireClient(plr, { id = id, name = id, description = "", progress = completed and 1 or 0, target = 1, completed = completed, active = true, text = text })
	end
end

local function floorIndex(y: number): number
	return math.clamp(math.floor(y / 18), 0, 2)
end

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
type LightState = {
	part: BasePart,
	light: PointLight?,
	brightness: number,
	color: Color3,
	material: Enum.Material,
	floor: number,
	on: boolean,
}
type PanelState = { part: BasePart, floor: number, fixed: boolean, highlight: Highlight? }
type ServerState = { model: Model, body: BasePart, prompt: ProximityPrompt, status: BasePart?, floor: number, fixed: boolean, highlight: Highlight? }

local lights: { LightState } = {}
local panels: { PanelState } = {}
local floorPanelCount: { [number]: number } = {}
local floorFixedCount: { [number]: number } = {}
local servers: { ServerState } = {}
local panelsFixed = 0
local serversFixed = 0
local active = false

local function panelObjText(): string
	return string.format("Restore the power: fix panels (%d/%d)", panelsFixed, #panels)
end
local function serverObjText(): string
	return string.format("Repair the servers (%d/%d)", serversFixed, #servers)
end

--- Publish whether EVERY panel and EVERY server is back online. CodingGameServer
--- gates the Night 2 "finish your project" recompile on NightSystemsRestored, so it
--- only unlocks once all the power AND all the servers are fixed.
local function refreshNightSystems()
	local allPower = (#panels == 0) or (panelsFixed >= #panels)
	local allServers = (#servers == 0) or (serversFixed >= #servers)
	workspace:SetAttribute("AllPowerRestored", allPower)
	workspace:SetAttribute("AllServersRestored", allServers)
	workspace:SetAttribute("NightSystemsRestored", allPower and allServers)
end

--------------------------------------------------------------------------------
-- Lights
--------------------------------------------------------------------------------
local OFF_COLOR = Color3.fromRGB(40, 42, 46)
local BACKUP_COLOR = Color3.fromRGB(120, 135, 160)

-- Even with a floor's power "restored", the grid is limping — only this fraction
-- of that floor's lights actually come back on; the rest stay dark.
local FLOOR_LIT_FRACTION = 0.35

local function gatherLights()
	table.clear(lights)
	for _, p in CollectionService:GetTagged(TAGS.CEILING_LIGHT) do
		if p:IsA("BasePart") then
			local pl = p:FindFirstChildOfClass("PointLight")
			table.insert(lights, {
				part = p,
				light = pl,
				brightness = pl and pl.Brightness or 1,
				color = p.Color,
				material = p.Material,
				floor = floorIndex(p.Position.Y),
				on = true,
			})
		end
	end
end

local function setLight(ls: LightState, mode: string)
	if mode == "off" then
		if ls.light then
			ls.light.Enabled = false
		end
		ls.part.Material = Enum.Material.SmoothPlastic
		ls.part.Color = OFF_COLOR
		ls.on = false
	elseif mode == "backup" then
		if ls.light then
			ls.light.Enabled = true
			ls.light.Brightness = ls.brightness * 0.35
		end
		ls.part.Material = Enum.Material.Neon
		ls.part.Color = BACKUP_COLOR
		ls.on = true
	else -- "floor": fuller (but still partial) restoration
		if ls.light then
			ls.light.Enabled = true
			ls.light.Brightness = ls.brightness * 0.6
		end
		ls.part.Material = Enum.Material.Neon
		ls.part.Color = ls.color
		ls.on = true
	end
end

local function restoreAllLights()
	for _, ls in lights do
		if ls.light then
			ls.light.Enabled = true
			ls.light.Brightness = ls.brightness
		end
		ls.part.Material = ls.material
		ls.part.Color = ls.color
		ls.on = true
	end
end

--------------------------------------------------------------------------------
-- Panels
--------------------------------------------------------------------------------
local function setupPanels()
	table.clear(panels)
	table.clear(floorPanelCount)
	table.clear(floorFixedCount)
	for _, p in CollectionService:GetTagged(TAGS.ELECTRICAL_PANEL) do
		if p:IsA("BasePart") then
			local f = floorIndex(p.Position.Y)
			local hl = Instance.new("Highlight")
			hl.Name = "PanelHighlight"
			hl.FillColor = Color3.fromRGB(255, 95, 40)
			hl.OutlineColor = Color3.fromRGB(255, 210, 130)
			hl.FillTransparency = 0.45
			hl.OutlineTransparency = 0
			hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			hl.Adornee = p
			hl.Parent = p
			table.insert(panels, { part = p, floor = f, fixed = false, highlight = hl })
			floorPanelCount[f] = (floorPanelCount[f] or 0) + 1
			floorFixedCount[f] = floorFixedCount[f] or 0
		end
	end
end

local function clearHighlights()
	for _, panel in panels do
		if panel.highlight then
			panel.highlight:Destroy()
			panel.highlight = nil
		end
	end
end

--------------------------------------------------------------------------------
-- Server racks (repairable once their floor has power)
--------------------------------------------------------------------------------
local function repairServer(srv: ServerState)
	if srv.fixed then
		return
	end
	srv.fixed = true
	srv.prompt.Enabled = false
	if srv.highlight then
		srv.highlight:Destroy()
		srv.highlight = nil
	end
	if srv.status then
		srv.status.Color = Color3.fromRGB(60, 210, 90) -- green = back online
	end
	serversFixed += 1
	fireObjective("repair_servers", serverObjText(), serversFixed >= #servers)
	refreshNightSystems()
end

local function setupServers()
	table.clear(servers)
	serversFixed = 0
	for _, m in CollectionService:GetTagged(TAGS.SERVER_RACK) do
		if m:IsA("Model") and m.PrimaryPart then
			local body = m.PrimaryPart
			local prompt = body:FindFirstChildOfClass("ProximityPrompt")
			if prompt then
				prompt.Enabled = false -- only once the floor has power
				local status = m:FindFirstChild("Status")
				if status and status:IsA("BasePart") then
					status.Color = Color3.fromRGB(220, 60, 50) -- red = down
				end
				local srv: ServerState = {
					model = m,
					body = body,
					prompt = prompt,
					status = (status and status:IsA("BasePart")) and status or nil,
					floor = floorIndex(body.Position.Y),
					fixed = false,
					highlight = nil,
				}
				prompt.Triggered:Connect(function()
					if active and prompt.Enabled then
						repairServer(srv)
					end
				end)
				table.insert(servers, srv)
			end
		end
	end
end

--- Power up (enable) the server prompts on a floor whose power was just restored,
--- and put a CYAN see-through-walls outline on each (distinct from the orange panel
--- highlight) so players can find the now-repairable racks.
local function enableFloorServers(f: number)
	for _, srv in servers do
		if srv.floor == f and not srv.fixed then
			srv.prompt.Enabled = true
			if srv.status then
				srv.status.Color = Color3.fromRGB(230, 180, 40) -- amber = powered, awaiting repair
			end
			if not srv.highlight then
				local hl = Instance.new("Highlight")
				hl.Name = "ServerHighlight"
				hl.FillColor = Color3.fromRGB(40, 170, 255)
				hl.OutlineColor = Color3.fromRGB(160, 230, 255)
				hl.FillTransparency = 0.5
				hl.OutlineTransparency = 0
				hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
				hl.Adornee = srv.model
				hl.Parent = srv.model
				srv.highlight = hl
			end
		end
	end
end

local function restoreFloorPower(f: number)
	-- Gather this floor's lights and only bring ~FLOOR_LIT_FRACTION of them back on
	-- (the grid never fully recovers); the rest are forced dark.
	local floorLights: { LightState } = {}
	for _, ls in lights do
		if ls.floor == f then
			table.insert(floorLights, ls)
		end
	end
	-- shuffle so the lit set is scattered around the floor, not clustered
	for i = #floorLights, 2, -1 do
		local j = math.random(1, i)
		floorLights[i], floorLights[j] = floorLights[j], floorLights[i]
	end
	local litCount = math.max(1, math.floor(#floorLights * FLOOR_LIT_FRACTION))
	for i, ls in floorLights do
		setLight(ls, if i <= litCount then "floor" else "off")
	end

	workspace:SetAttribute("FloorPower" .. f, true)
	enableFloorServers(f)
	print(string.format("[PowerManager] Floor %d power restored (partial — %d/%d lights) — work can resume here.", f, litCount, #floorLights))
end

--- Apply a repair to a specific panel: backup lights + objective + floor check.
local function applyPanelFix(best: PanelState)
	if best.fixed then
		return
	end
	best.fixed = true
	if best.highlight then
		best.highlight:Destroy()
		best.highlight = nil
	end
	-- Lock the panel down so its prompt can't re-open the puzzle, and give the
	-- familiar green "fixed" colour.
	best.part:SetAttribute("IsRepaired", true)
	local prompt = best.part:FindFirstChildOfClass("ProximityPrompt")
	if prompt then
		prompt.Enabled = false
	end
	best.part.Color = Color3.fromRGB(80, 200, 80)
	panelsFixed += 1
	fireObjective("repair_panels", panelObjText(), panelsFixed >= #panels)
	refreshNightSystems()

	-- backup power: bring ~1/5 of this floor's still-dark lights, nearest first
	local dark: { LightState } = {}
	for _, ls in lights do
		if ls.floor == best.floor and not ls.on then
			table.insert(dark, ls)
		end
	end
	table.sort(dark, function(a, b)
		return (a.part.Position - best.part.Position).Magnitude < (b.part.Position - best.part.Position).Magnitude
	end)
	local quota = math.max(1, math.floor(#dark / 5))
	for i = 1, math.min(quota, #dark) do
		setLight(dark[i], "backup")
	end

	-- whole-floor restoration once every panel on the floor is repaired
	floorFixedCount[best.floor] = (floorFixedCount[best.floor] or 0) + 1
	if floorFixedCount[best.floor] >= (floorPanelCount[best.floor] or 0) then
		restoreFloorPower(best.floor)
	end
end

--- Repair a specific panel instance (used by the server bus — exact identity).
local function fixPanelByPart(part: Instance)
	for _, panel in panels do
		if panel.part == part and not panel.fixed then
			applyPanelFix(panel)
			return
		end
	end
end

--- Repair the unfixed panel closest to the player (wire-puzzle solve path).
local function fixNearestPanel(player: Player)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp or not hrp:IsA("BasePart") then
		return
	end
	local best: PanelState? = nil
	local bestD = 30
	for _, panel in panels do
		if not panel.fixed then
			local d = (panel.part.Position - hrp.Position).Magnitude
			if d < bestD then
				bestD = d
				best = panel
			end
		end
	end
	if best then
		applyPanelFix(best)
	end
end

--------------------------------------------------------------------------------
-- Wiring
--------------------------------------------------------------------------------
-- Wire-puzzle solve fires PanelRepaired:FireServer (no panel id) → nearest panel.
PanelRepaired.OnServerEvent:Connect(function(player: Player, ...)
	if active then
		fixNearestPanel(player)
	end
end)

-- The InteractionManager "Repair" prompt fires this bus with the EXACT panel.
do
	local serverComm = ServerStorage:WaitForChild("ServerComm")
	local found = serverComm:FindFirstChild("PanelFixed")
	local panelFixedBus: BindableEvent
	if found and found:IsA("BindableEvent") then
		panelFixedBus = found
	else
		panelFixedBus = Instance.new("BindableEvent")
		panelFixedBus.Name = "PanelFixed"
		panelFixedBus.Parent = serverComm
	end
	panelFixedBus.Event:Connect(function(panelInstance: Instance)
		if active and typeof(panelInstance) == "Instance" then
			fixPanelByPart(panelInstance)
		end
	end)
end

local function onNight()
	active = true
	panelsFixed = 0
	for f = 0, 2 do
		workspace:SetAttribute("FloorPower" .. f, false)
	end
	gatherLights()
	for _, ls in lights do
		setLight(ls, "off")
	end
	setupPanels()
	setupServers()
	refreshNightSystems() -- everything starts down → NightSystemsRestored = false
	-- broadcast the NIGHT2 objectives' starting counts (after the panel loads)
	task.delay(1.2, function()
		if active then
			fireObjective("repair_panels", panelObjText(), false)
			fireObjective("repair_servers", serverObjText(), false)
		end
	end)
	print("[PowerManager] NIGHT2 — power cut. Find and repair the highlighted panels.")
end

local function onLeaveNight()
	if not active then
		return
	end
	active = false
	clearHighlights()
	for _, srv in servers do
		if srv.highlight then
			srv.highlight:Destroy()
			srv.highlight = nil
		end
	end
	restoreAllLights()
	for f = 0, 2 do
		workspace:SetAttribute("FloorPower" .. f, true)
	end
end

task.spawn(function()
	local serverComm = ServerStorage:WaitForChild("ServerComm")
	local phaseBus = serverComm:WaitForChild("PhaseChanged") :: BindableEvent
	phaseBus.Event:Connect(function(phase: number)
		if phase == NIGHT2 then
			onNight()
		else
			onLeaveNight()
		end
	end)
	print("[PowerManager] Ready — waiting for NIGHT2.")
end)
