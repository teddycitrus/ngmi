--!strict
--[[
	ObjectivesUI.client.luau
	Persistent objectives / quest-guide panel anchored to the right side of
	the screen.  Shows phase-specific objectives that update automatically
	when the game phase changes.

	Design:
	  • Dark semi-transparent glass panel matching the main HUD style
	  • Collapsible via header click
	  • Checkboxes that fill green as players complete objectives
	  • Smooth fade transitions between phases
	  • Red-tinted border during NIGHT2
	  • First objective pulses when a new phase begins
	  • Mobile: narrower panel, starts collapsed
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ============================================================
-- REMOTES
-- ============================================================
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local GameStateChanged = Remotes:WaitForChild("GameStateChanged") :: RemoteEvent
local CodingProgress = Remotes:WaitForChild("CodingProgress") :: RemoteEvent
local QuestUpdate = Remotes:WaitForChild("QuestUpdate") :: RemoteEvent

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local isMobile: boolean = UserInputService.TouchEnabled

-- ============================================================
-- CONSTANTS
-- ============================================================
local PANEL_WIDTH = if isMobile then 200 else 250
local PANEL_MARGIN = 16
local HEADER_HEIGHT = 34
local ROW_HEIGHT = 26
local ROW_GAP = 4
local CORNER_RADIUS = 12

local BG_COLOR = Color3.fromRGB(12, 15, 22)
local BG_TRANSPARENCY = 0.15
local STROKE_COLOR_DEFAULT = Color3.fromRGB(40, 45, 60)
local STROKE_COLOR_NIGHT = Color3.fromRGB(100, 30, 30)
local TEXT_ACTIVE = Color3.new(1, 1, 1)
local TEXT_COMPLETED = Color3.fromRGB(120, 130, 140)
local CHECK_COMPLETED = Color3.fromRGB(80, 220, 100)

-- ============================================================
-- OBJECTIVE DEFINITIONS PER PHASE
-- ============================================================
export type Objective = {
	id: string,
	text: string,
	completed: boolean,
	-- optional dynamic label (e.g. progress %)
	dynamicText: string?,
}

local function makeObjectives(defs: { { id: string, text: string } }): { Objective }
	local out: { Objective } = {}
	for _, d in defs do
		table.insert(out, { id = d.id, text = d.text, completed = false, dynamicText = nil })
	end
	return out
end

local PHASE_OBJECTIVES: { [number]: { Objective } } = {
	[1] = makeObjectives({
		{ id = "find_desk", text = "Find your desk" },
		{ id = "talk_npcs", text = "Meet the staff (0/2)" },
	}),
	[2] = makeObjectives({
		{ id = "code_wave1", text = "Coding sprint I: reach 50% (0%)" },
		{ id = "code_wave2", text = "Coding sprint II: reach 100% (0%)" },
		{ id = "collect_items", text = "Scavenge 3 supplies (0/3)" },
		{ id = "explore_rooms", text = "Explore all 3 floors (0/3)" },
		{ id = "poop_monster", text = "★ Bonus: defeat the Bathroom Monster" },
		{ id = "fix_computer", text = "★ Bonus: fix a frozen PC" },
	}),
	[3] = makeObjectives({
		{ id = "survive", text = "SURVIVE until dawn" },
		{ id = "repair_panels", text = "Restore the power: fix panels" },
		{ id = "repair_servers", text = "Repair the servers" },
		{ id = "keep_coding", text = "Finish your project" },
	}),
	[4] = makeObjectives({
		{ id = "present", text = "Present your project" },
	}),
}

-- ============================================================
-- STATE
-- ============================================================
local currentPhase: number = 0
local isCollapsed: boolean = isMobile -- mobile starts collapsed
local objectives: { Objective } = {}
local rowFrames: { Frame } = {}

-- ============================================================
-- GUI CREATION
-- ============================================================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "ObjectivesUI"
screenGui.DisplayOrder = 15
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.Parent = playerGui

-- Main panel ------------------------------------------------
local panel = Instance.new("Frame")
panel.Name = "ObjectivesPanel"
panel.BackgroundColor3 = BG_COLOR
panel.BackgroundTransparency = BG_TRANSPARENCY
panel.BorderSizePixel = 0
panel.ClipsDescendants = true
panel.Visible = false
panel.Parent = screenGui

local panelCorner = Instance.new("UICorner")
panelCorner.CornerRadius = UDim.new(0, CORNER_RADIUS)
panelCorner.Parent = panel

local panelStroke = Instance.new("UIStroke")
panelStroke.Color = STROKE_COLOR_DEFAULT
panelStroke.Thickness = 1
panelStroke.Parent = panel

-- Header (clickable) ----------------------------------------
local headerBtn = Instance.new("TextButton")
headerBtn.Name = "Header"
headerBtn.Size = UDim2.new(1, 0, 0, HEADER_HEIGHT)
headerBtn.Position = UDim2.new(0, 0, 0, 0)
headerBtn.BackgroundTransparency = 1
headerBtn.Text = ""
headerBtn.Parent = panel

local headerLabel = Instance.new("TextLabel")
headerLabel.Name = "Title"
headerLabel.Size = UDim2.new(1, -36, 1, 0)
headerLabel.Position = UDim2.new(0, 10, 0, 0)
headerLabel.BackgroundTransparency = 1
headerLabel.Text = "📋 OBJECTIVES"
headerLabel.TextSize = if isMobile then 12 else 14
headerLabel.Font = Enum.Font.GothamBold
headerLabel.TextColor3 = Color3.fromRGB(200, 200, 220)
headerLabel.TextXAlignment = Enum.TextXAlignment.Left
headerLabel.Parent = headerBtn

local arrowLabel = Instance.new("TextLabel")
arrowLabel.Name = "Arrow"
arrowLabel.Size = UDim2.new(0, 20, 1, 0)
arrowLabel.Position = UDim2.new(1, -28, 0, 0)
arrowLabel.BackgroundTransparency = 1
arrowLabel.Text = if isCollapsed then "▲" else "▼"
arrowLabel.TextSize = 12
arrowLabel.Font = Enum.Font.GothamBold
arrowLabel.TextColor3 = Color3.fromRGB(150, 150, 170)
arrowLabel.Parent = headerBtn

-- Separator line under header
local separator = Instance.new("Frame")
separator.Name = "Separator"
separator.Size = UDim2.new(1, -20, 0, 1)
separator.Position = UDim2.new(0, 10, 0, HEADER_HEIGHT - 1)
separator.BackgroundColor3 = Color3.fromRGB(40, 45, 60)
separator.BackgroundTransparency = 0.5
separator.BorderSizePixel = 0
separator.Parent = panel

-- Content area (holds objective rows) -----------------------
local content = Instance.new("Frame")
content.Name = "Content"
content.Size = UDim2.new(1, -16, 1, -HEADER_HEIGHT - 8)
content.Position = UDim2.new(0, 8, 0, HEADER_HEIGHT + 4)
content.BackgroundTransparency = 1
content.ClipsDescendants = true
content.Parent = panel

local listLayout = Instance.new("UIListLayout")
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Padding = UDim.new(0, ROW_GAP)
listLayout.Parent = content

-- ============================================================
-- HELPERS
-- ============================================================

--- Compute total panel height based on current objectives
local function computePanelHeight(): number
	if isCollapsed then
		return HEADER_HEIGHT
	end
	local rows = #objectives
	return HEADER_HEIGHT + 8 + rows * ROW_HEIGHT + math.max(0, rows - 1) * ROW_GAP + 8
end

--- Reposition & resize the panel with a tween
local function layoutPanel(animate: boolean)
	local h = computePanelHeight()
	local targetSize = UDim2.new(0, PANEL_WIDTH, 0, h)
	local targetPos = UDim2.new(1, -(PANEL_WIDTH + PANEL_MARGIN), 0, 80)

	if animate then
		TweenService:Create(panel, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = targetSize,
			Position = targetPos,
		}):Play()
	else
		panel.Size = targetSize
		panel.Position = targetPos
	end
end

--- Create a single objective row frame
local function createRow(index: number, obj: Objective): Frame
	local row = Instance.new("Frame")
	row.Name = "Row_" .. obj.id
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.BackgroundTransparency = 1
	row.LayoutOrder = index
	row.Parent = content

	-- Checkbox label
	local checkbox = Instance.new("TextLabel")
	checkbox.Name = "Checkbox"
	checkbox.Size = UDim2.new(0, 20, 1, 0)
	checkbox.Position = UDim2.new(0, 0, 0, 0)
	checkbox.BackgroundTransparency = 1
	checkbox.Text = if obj.completed then "☑" else "☐"
	checkbox.TextSize = if isMobile then 14 else 16
	checkbox.Font = Enum.Font.GothamBold
	checkbox.TextColor3 = if obj.completed then CHECK_COMPLETED else Color3.fromRGB(160, 165, 180)
	checkbox.TextYAlignment = Enum.TextYAlignment.Center
	checkbox.Parent = row

	-- Objective text
	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.new(1, -24, 1, 0)
	label.Position = UDim2.new(0, 24, 0, 0)
	label.BackgroundTransparency = 1
	label.Text = obj.dynamicText or obj.text
	label.TextSize = if isMobile then 11 else 13
	label.Font = Enum.Font.Gotham
	label.TextColor3 = if obj.completed then TEXT_COMPLETED else TEXT_ACTIVE
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Parent = row

	return row
end

--- Clear all row frames
local function clearRows()
	for _, rf in rowFrames do
		if rf.Parent then rf:Destroy() end
	end
	table.clear(rowFrames)
end

--- Rebuild all rows from current objectives
local function rebuildRows()
	clearRows()
	for i, obj in objectives do
		local row = createRow(i, obj)
		table.insert(rowFrames, row)
	end
end

--- Update a single row's visual state (checkbox + text color)
local function updateRowVisual(index: number)
	local row = rowFrames[index]
	local obj = objectives[index]
	if not row or not obj then return end

	local checkbox = row:FindFirstChild("Checkbox") :: TextLabel?
	local label = row:FindFirstChild("Label") :: TextLabel?
	if not checkbox or not label then return end

	checkbox.Text = if obj.completed then "☑" else "☐"
	checkbox.TextColor3 = if obj.completed then CHECK_COMPLETED else Color3.fromRGB(160, 165, 180)
	label.Text = obj.dynamicText or obj.text
	label.TextColor3 = if obj.completed then TEXT_COMPLETED else TEXT_ACTIVE

	-- Quick green flash on completion
	if obj.completed then
		TweenService:Create(checkbox, TweenInfo.new(0.3), {
			TextColor3 = CHECK_COMPLETED,
		}):Play()
	end
end

--- Pulse the first objective row to draw attention
local function pulseFirstRow()
	local row = rowFrames[1]
	if not row then return end

	local label = row:FindFirstChild("Label") :: TextLabel?
	if not label then return end

	-- Pulse: brighten then back to normal
	task.spawn(function()
		for _ = 1, 3 do
			TweenService:Create(label, TweenInfo.new(0.25, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
				TextColor3 = Color3.fromRGB(255, 255, 150),
			}):Play()
			task.wait(0.3)
			TweenService:Create(label, TweenInfo.new(0.25, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
				TextColor3 = TEXT_ACTIVE,
			}):Play()
			task.wait(0.3)
		end
	end)
end

-- ============================================================
-- FIND OBJECTIVE BY ID
-- ============================================================
local function findObjective(id: string): (number?, Objective?)
	for i, obj in objectives do
		if obj.id == id then
			return i, obj
		end
	end
	return nil, nil
end

-- ============================================================
-- PHASE TRANSITION
-- ============================================================
local function setPhase(phase: number)
	local prevPhase = currentPhase
	currentPhase = phase

	-- Visibility: hide during LOBBY(0) and DAY3(4)
	local shouldShow = phase >= 1 and phase <= 3
	if not shouldShow then
		-- Fade out
		TweenService:Create(panel, TweenInfo.new(0.3), { BackgroundTransparency = 1 }):Play()
		task.delay(0.3, function()
			if currentPhase == phase then -- still same phase
				panel.Visible = false
				panel.BackgroundTransparency = BG_TRANSPARENCY
			end
		end)
		return
	end

	-- Night 2 red tint
	if phase == 3 then
		TweenService:Create(panelStroke, TweenInfo.new(0.5), { Color = STROKE_COLOR_NIGHT }):Play()
	else
		TweenService:Create(panelStroke, TweenInfo.new(0.5), { Color = STROKE_COLOR_DEFAULT }):Play()
	end

	-- Deep-copy objectives for this phase so we can mutate completion state
	local phaseDefs = PHASE_OBJECTIVES[phase]
	if not phaseDefs then return end

	-- Fade out old rows, swap, fade in
	local fadeDuration = if prevPhase == 0 then 0 else 0.2

	-- Fade out content
	for _, rf in rowFrames do
		TweenService:Create(rf, TweenInfo.new(fadeDuration), {
			BackgroundTransparency = 1,
		}):Play()
		local lbl = rf:FindFirstChild("Label") :: TextLabel?
		local cb = rf:FindFirstChild("Checkbox") :: TextLabel?
		if lbl then TweenService:Create(lbl, TweenInfo.new(fadeDuration), { TextTransparency = 1 }):Play() end
		if cb then TweenService:Create(cb, TweenInfo.new(fadeDuration), { TextTransparency = 1 }):Play() end
	end

	task.delay(fadeDuration, function()
		if currentPhase ~= phase then return end -- phase changed during fade

		-- Build fresh objectives
		objectives = {}
		for _, def in phaseDefs do
			table.insert(objectives, {
				id = def.id,
				text = def.text,
				completed = false,
				dynamicText = nil,
			})
		end

		rebuildRows()
		layoutPanel(true)

		-- Make panel visible (might be first show)
		panel.Visible = true
		panel.BackgroundTransparency = BG_TRANSPARENCY

		-- Fade in new rows
		for _, rf in rowFrames do
			local lbl = rf:FindFirstChild("Label") :: TextLabel?
			local cb = rf:FindFirstChild("Checkbox") :: TextLabel?
			if lbl then
				lbl.TextTransparency = 1
				TweenService:Create(lbl, TweenInfo.new(0.3), { TextTransparency = 0 }):Play()
			end
			if cb then
				cb.TextTransparency = 1
				TweenService:Create(cb, TweenInfo.new(0.3), { TextTransparency = 0 }):Play()
			end
		end

		-- Pulse first objective
		task.delay(0.4, function()
			if currentPhase == phase then
				pulseFirstRow()
			end
		end)
	end)
end

-- ============================================================
-- COLLAPSE / EXPAND
-- ============================================================
headerBtn.Activated:Connect(function()
	isCollapsed = not isCollapsed
	arrowLabel.Text = if isCollapsed then "▲" else "▼"
	content.Visible = not isCollapsed
	separator.Visible = not isCollapsed
	layoutPanel(true)
end)

-- ============================================================
-- REMOTE EVENT LISTENERS
-- ============================================================

-- Phase changes
GameStateChanged.OnClientEvent:Connect(function(data: { phase: number })
	setPhase(data.phase)
end)

-- Coding progress — update the "Code at your desk" objective
CodingProgress.OnClientEvent:Connect(function(data: { completion: number, blocked: boolean? })
	local idx, obj = findObjective("code_desk")
	if idx and obj then
		local pct = math.floor(data.completion)
		obj.dynamicText = string.format("Code at your desk (%d%%)", pct)
		if pct >= 100 then
			obj.completed = true
		end
		updateRowVisual(idx)
	end

	-- Also update "keep_coding" in Night 2 if applicable
	local idx3, obj3 = findObjective("keep_coding")
	if idx3 and obj3 then
		local pct = math.floor(data.completion)
		if pct >= 100 then
			obj3.completed = true
			updateRowVisual(idx3)
		end
	end
end)

-- Quest / objective updates — generic. The server (ProgressionManager, QuestManager)
-- addresses an objective by id and optionally sends a fresh label (`text`) and/or
-- `completed`. We just apply whatever arrives to the matching row.
QuestUpdate.OnClientEvent:Connect(function(data: {
	id: string,
	name: string?,
	description: string?,
	progress: number?,
	target: number?,
	completed: boolean?,
	active: boolean?,
	text: string?,
})
	if typeof(data) ~= "table" or typeof(data.id) ~= "string" then
		return
	end
	local idx, obj = findObjective(data.id)
	if not idx or not obj then
		return
	end
	if typeof(data.text) == "string" then
		obj.dynamicText = data.text
	elseif typeof(data.progress) == "number" and typeof(data.target) == "number" and data.target > 1 then
		obj.dynamicText = string.format("%s (%d/%d)", obj.text, math.min(data.progress, data.target), data.target)
	end
	if data.completed then
		obj.completed = true
	end
	updateRowVisual(idx)
end)

-- ============================================================
-- INITIAL LAYOUT
-- ============================================================
content.Visible = not isCollapsed
separator.Visible = not isCollapsed
layoutPanel(false)

print("[ObjectivesUI] Initialized — objectives panel ready")
