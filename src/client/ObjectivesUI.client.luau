--!strict
--[[
	ObjectivesUI.client.luau
	Persistent objectives / quest-guide panel anchored to the right side of the
	screen. Shows phase-specific objectives that update as the game phase changes.

	Behaviour:
	  * Procedural per phase: the objective list is generated each phase from a
	    plan of anchors (always first), a pool of required tasks, and optional
	    bonus tasks that are randomly included and shuffled, so no two runs read
	    exactly the same.
	  * Gated final task: each coding phase has a final coding task that stays
	    hidden until every required (non-bonus) objective is complete, then pops
	    into the bar with a pulse.
	  * Toggle with J: press J to hide/show the whole panel. A small hint above
	    the panel always shows the keybind while objectives are active.
	  * Collapsible via header click; checkboxes fill green on completion.
	  * Red-tinted border during NIGHT2; mobile gets a narrower, collapsed panel.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UITheme = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UITheme"))
local Objectives = script.Parent:WaitForChild("Objectives")
local ObjectivePlan = require(Objectives:WaitForChild("ObjectivePlan"))
local ObjectivesPanel = require(Objectives:WaitForChild("ObjectivesPanel"))

type Objective = ObjectivePlan.Objective

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
local PANEL_WIDTH = if isMobile then 200 else 260
local PANEL_MARGIN = UITheme.Margin
local PANEL_TOP = 72
local HEADER_HEIGHT = 24
local ROW_HEIGHT = 22
local ROW_GAP = 2
local CHECK_SIZE = 8
local TOGGLE_KEY = Enum.KeyCode.J

local HEADER_COLOR_DEFAULT = UITheme.Color.Dim
local HEADER_COLOR_NIGHT = UITheme.Color.Danger
local TEXT_ACTIVE = UITheme.Color.Text
local TEXT_COMPLETED = UITheme.Color.Faint
local CHECK_PENDING = UITheme.Color.Dim
local CHECK_COMPLETED = UITheme.Color.Good

-- ============================================================
-- STATE
-- ============================================================
local currentPhase: number = 0
local isCollapsed: boolean = isMobile -- mobile starts collapsed
local userHidden: boolean = false -- toggled by the J key
local objectives: { Objective } = {}
local rowById: { [string]: Frame } = {}

-- ============================================================
-- OBJECTIVE LOOKUP
-- ============================================================
--- The objectives currently eligible to render (non-gated, or revealed gated).
local function visibleObjectives(): { Objective }
	local out: { Objective } = {}
	for _, obj in objectives do
		if obj.revealed then
			table.insert(out, obj)
		end
	end
	return out
end

local function findObjective(id: string): Objective?
	for _, obj in objectives do
		if obj.id == id then
			return obj
		end
	end
	return nil
end

-- ============================================================
-- GUI CREATION
-- ============================================================
local SCRIM_BLEED = 48 -- how far the edge wash reaches past the text, in px

local parts = ObjectivesPanel.build(playerGui, {
	width = PANEL_WIDTH,
	margin = PANEL_MARGIN,
	top = PANEL_TOP,
	headerHeight = HEADER_HEIGHT,
	rowGap = ROW_GAP,
	collapsed = isCollapsed,
})
local hintLabel = parts.hintLabel
local panel = parts.panel
local scrim = parts.scrim
local headerBtn = parts.headerBtn
local headerLabel = parts.headerLabel
local arrowLabel = parts.arrowLabel
local separator = parts.separator
local content = parts.content

-- ============================================================
-- LAYOUT HELPERS
-- ============================================================
local function computePanelHeight(): number
	if isCollapsed then
		return HEADER_HEIGHT
	end
	local rows = #visibleObjectives()
	return HEADER_HEIGHT + 6 + rows * ROW_HEIGHT + math.max(0, rows - 1) * ROW_GAP + 4
end

local function layoutPanel(animate: boolean)
	local h = computePanelHeight()
	local targetSize = UDim2.new(0, PANEL_WIDTH, 0, h)
	local targetPos = UDim2.new(1, -(PANEL_WIDTH + PANEL_MARGIN), 0, PANEL_TOP)
	local scrimSize = UDim2.fromOffset(PANEL_WIDTH + PANEL_MARGIN + SCRIM_BLEED, h + SCRIM_BLEED / 2)
	scrim.Position = UDim2.new(1, 0, 0, PANEL_TOP - SCRIM_BLEED / 4)

	if animate then
		local info = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(panel, info, {
			Size = targetSize,
			Position = targetPos,
		}):Play()
		TweenService:Create(scrim, info, { Size = scrimSize }):Play()
	else
		panel.Size = targetSize
		panel.Position = targetPos
		scrim.Size = scrimSize
	end
end

-- ============================================================
-- ROW RENDERING
-- ============================================================
--- Small square marker: outlined while pending, filled once complete.
local function styleCheckbox(checkbox: Frame, completed: boolean)
	checkbox.BackgroundColor3 = CHECK_COMPLETED
	checkbox.BackgroundTransparency = if completed then 0 else 1
	local stroke = checkbox:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Color = if completed then CHECK_COMPLETED else CHECK_PENDING
	end
end

local function labelText(obj: Objective): string
	local text = obj.dynamicText or obj.text
	return if obj.completed then "<s>" .. text .. "</s>" else text
end

local function createRow(order: number, obj: Objective): Frame
	local row = Instance.new("Frame")
	row.Name = "Row_" .. obj.id
	row.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	row.BackgroundTransparency = 1
	row.LayoutOrder = order
	row.Parent = content

	local checkbox = Instance.new("Frame")
	checkbox.Name = "Checkbox"
	checkbox.AnchorPoint = Vector2.new(0, 0.5)
	checkbox.Size = UDim2.fromOffset(CHECK_SIZE, CHECK_SIZE)
	checkbox.Position = UDim2.new(0, 1, 0.5, 0)
	checkbox.BorderSizePixel = 0
	checkbox.Parent = row
	UITheme.outline(checkbox, 0)
	styleCheckbox(checkbox, obj.completed)

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.new(1, -18, 1, 0)
	label.Position = UDim2.new(0, 18, 0, 0)
	label.BackgroundTransparency = 1
	label.RichText = true
	label.Text = labelText(obj)
	label.TextSize = if isMobile then 12 else 14
	label.FontFace = UITheme.Font.Regular
	label.TextColor3 = if obj.completed then TEXT_COMPLETED else TEXT_ACTIVE
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.TextTruncate = Enum.TextTruncate.AtEnd
	label.Parent = row
	UITheme.textShadow(label)

	return row
end

local function clearRows()
	for _, rf in rowById do
		if rf.Parent then
			rf:Destroy()
		end
	end
	table.clear(rowById)
end

local function rebuildRows()
	clearRows()
	local order = 0
	for _, obj in visibleObjectives() do
		order += 1
		rowById[obj.id] = createRow(order, obj)
	end
end

--- Push an objective's current state into its row (if it has one on screen).
local function refreshObjective(id: string)
	local obj = findObjective(id)
	local row = rowById[id]
	if not obj or not row then
		return
	end
	local checkbox = row:FindFirstChild("Checkbox") :: Frame?
	local label = row:FindFirstChild("Label") :: TextLabel?
	if not checkbox or not label then
		return
	end
	styleCheckbox(checkbox, obj.completed)
	label.Text = labelText(obj)
	label.TextColor3 = if obj.completed then TEXT_COMPLETED else TEXT_ACTIVE
end

local function pulseRow(id: string)
	local row = rowById[id]
	if not row then
		return
	end
	local label = row:FindFirstChild("Label") :: TextLabel?
	if not label then
		return
	end
	task.spawn(function()
		for _ = 1, 3 do
			TweenService:Create(label, TweenInfo.new(0.25, Enum.EasingStyle.Sine), {
				TextColor3 = UITheme.Color.Warn,
			}):Play()
			task.wait(0.3)
			TweenService:Create(label, TweenInfo.new(0.25, Enum.EasingStyle.Sine), {
				TextColor3 = TEXT_ACTIVE,
			}):Play()
			task.wait(0.3)
		end
	end)
end

-- ============================================================
-- GATED FINAL TASK
-- ============================================================
--- Every required (non-gated, non-bonus) objective is complete?
local function allRequiredComplete(): boolean
	local hasRequired = false
	for _, obj in objectives do
		if not obj.gated and not obj.optional and not obj.passive then
			hasRequired = true
			if not obj.completed then
				return false
			end
		end
	end
	return hasRequired
end

--- Reveal the gated final task once everything required is done.
local function maybeRevealGated()
	for _, obj in objectives do
		if obj.gated and not obj.revealed and allRequiredComplete() then
			obj.revealed = true
			rebuildRows()
			layoutPanel(true)
			refreshObjective(obj.id)
			pulseRow(obj.id)
		end
	end
end

-- ============================================================
-- VISIBILITY (phase gate + J toggle)
-- ============================================================
local function applyVisibility()
	local shouldShow = currentPhase >= 1 and currentPhase <= 3
	hintLabel.Visible = shouldShow
	hintLabel.Text = if userHidden then "J  objectives" else "J"
	panel.Visible = shouldShow and not userHidden
	scrim.Visible = panel.Visible
end

-- ============================================================
-- PHASE TRANSITION
-- ============================================================
local function setPhase(phase: number)
	currentPhase = phase

	-- Header turns red during NIGHT2.
	local headerTarget = if phase == 3 then HEADER_COLOR_NIGHT else HEADER_COLOR_DEFAULT
	TweenService:Create(headerLabel, TweenInfo.new(0.5), { TextColor3 = headerTarget }):Play()

	-- Regenerate this phase's objectives procedurally and rebuild the rows.
	objectives = ObjectivePlan.generate(phase)
	rebuildRows()
	layoutPanel(false)
	applyVisibility()

	-- Fade the new rows in and pulse the first one.
	if panel.Visible then
		for _, rf in rowById do
			local lbl = rf:FindFirstChild("Label") :: TextLabel?
			if lbl then
				lbl.TextTransparency = 1
				TweenService:Create(lbl, TweenInfo.new(0.3), { TextTransparency = 0 }):Play()
			end
		end
		local first = visibleObjectives()[1]
		if first then
			task.delay(0.4, function()
				if currentPhase == phase then
					pulseRow(first.id)
				end
			end)
		end
	end
end

-- ============================================================
-- COLLAPSE / EXPAND + J TOGGLE
-- ============================================================
headerBtn.Activated:Connect(function()
	isCollapsed = not isCollapsed
	arrowLabel.Text = if isCollapsed then "+" else "-"
	content.Visible = not isCollapsed
	separator.Visible = not isCollapsed
	layoutPanel(true)
end)

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.KeyCode == TOGGLE_KEY then
		userHidden = not userHidden
		applyVisibility()
	end
end)

-- ============================================================
-- REMOTE EVENT LISTENERS
-- ============================================================
GameStateChanged.OnClientEvent:Connect(function(data: { phase: number })
	setPhase(data.phase)
end)

-- Coding progress drives the coding objectives (and the gated final task).
CodingProgress.OnClientEvent:Connect(function(data: { completion: number, blocked: boolean? })
	local pct = math.floor(data.completion or 0)

	local w1 = findObjective("code_wave1")
	if w1 then
		w1.dynamicText = string.format("Coding sprint I: reach 50%% (%d%%)", pct)
		if pct >= 50 then
			w1.completed = true
		end
		refreshObjective("code_wave1")
	end

	local w2 = findObjective("code_wave2")
	if w2 then
		w2.dynamicText = string.format("Ship it: finish your project (%d%%)", pct)
		if pct >= 100 then
			w2.completed = true
		end
		refreshObjective("code_wave2")
	end

	local kc = findObjective("keep_coding")
	if kc then
		kc.dynamicText = string.format("Recompile: finish your project (%d%%)", pct)
		if pct >= 100 then
			kc.completed = true
		end
		refreshObjective("keep_coding")
	end

	maybeRevealGated()
end)

-- Generic objective updates from the server (ProgressionManager, QuestManager):
-- addressed by id, with an optional fresh label and/or completion flag.
QuestUpdate.OnClientEvent:Connect(function(data: {
	id: string,
	progress: number?,
	target: number?,
	completed: boolean?,
	text: string?,
})
	if typeof(data) ~= "table" or typeof(data.id) ~= "string" then
		return
	end
	local obj = findObjective(data.id)
	if not obj then
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
	refreshObjective(data.id)
	maybeRevealGated()
end)

-- ============================================================
-- INITIAL LAYOUT
-- ============================================================
content.Visible = not isCollapsed
separator.Visible = not isCollapsed
layoutPanel(false)

print("[ObjectivesUI] Initialized - procedural objectives ready (J to toggle)")
