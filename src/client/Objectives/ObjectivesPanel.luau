--!strict
--------------------------------------------------------------------------------
-- Objectives/ObjectivesPanel.luau
-- Builds the ObjectivesUI instances: the ScreenGui, the J keybind hint, the
-- panel with its clickable header, separator and row container, and the dark
-- edge scrim behind it. Layout and rows stay in ObjectivesUI.
--------------------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local UITheme = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UITheme"))

export type Config = {
	width: number,
	margin: number,
	top: number,
	headerHeight: number,
	rowGap: number,
	collapsed: boolean,
}

export type Parts = {
	screenGui: ScreenGui,
	hintLabel: TextLabel,
	panel: Frame,
	scrim: Frame,
	headerBtn: TextButton,
	headerLabel: TextLabel,
	arrowLabel: TextLabel,
	separator: Frame,
	content: Frame,
}

local ObjectivesPanel = {}

function ObjectivesPanel.build(parentGui: Instance, cfg: Config): Parts
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "ObjectivesUI"
	screenGui.DisplayOrder = 15
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.Parent = parentGui

	-- Keybind hint (sits just above the panel; visible whenever objectives are active)
	local hintLabel = Instance.new("TextLabel")
	hintLabel.Name = "ToggleHint"
	hintLabel.Size = UDim2.new(0, cfg.width, 0, cfg.headerHeight)
	hintLabel.Position = UDim2.new(1, -(cfg.width + cfg.margin), 0, cfg.top)
	hintLabel.BackgroundTransparency = 1
	hintLabel.Text = "J"
	hintLabel.TextSize = 10
	hintLabel.FontFace = UITheme.Font.Mono
	hintLabel.TextColor3 = UITheme.Color.Faint
	hintLabel.TextXAlignment = Enum.TextXAlignment.Right
	hintLabel.ZIndex = 2
	UITheme.textShadow(hintLabel)
	hintLabel.Visible = false
	hintLabel.Parent = screenGui

	-- Main panel ------------------------------------------------
	local panel = Instance.new("Frame")
	panel.Name = "ObjectivesPanel"
	panel.BackgroundTransparency = 1
	panel.BorderSizePixel = 0
	panel.ClipsDescendants = true
	panel.Visible = false
	panel.Parent = screenGui

	-- Dark wash that bleeds in from the screen edge, so the list stays readable
	-- over lit signs and screens without a hard panel.
	local scrim = UITheme.scrim(screenGui, "left", 0.6)
	scrim.AnchorPoint = Vector2.new(1, 0)
	scrim.Visible = false

	-- Header (clickable) ----------------------------------------
	local headerBtn = Instance.new("TextButton")
	headerBtn.Name = "Header"
	headerBtn.Size = UDim2.new(1, 0, 0, cfg.headerHeight)
	headerBtn.Position = UDim2.new(0, 0, 0, 0)
	headerBtn.BackgroundTransparency = 1
	headerBtn.Text = ""
	headerBtn.Parent = panel

	local headerLabel = Instance.new("TextLabel")
	headerLabel.Name = "Title"
	headerLabel.Size = UDim2.new(1, -36, 1, 0)
	headerLabel.Position = UDim2.new(0, 0, 0, 0)
	headerLabel.BackgroundTransparency = 1
	headerLabel.Text = "OBJECTIVES"
	headerLabel.TextSize = 11
	headerLabel.FontFace = UITheme.Font.Bold
	headerLabel.TextColor3 = UITheme.Color.Dim
	headerLabel.TextXAlignment = Enum.TextXAlignment.Left
	headerLabel.Parent = headerBtn
	UITheme.textShadow(headerLabel)

	local arrowLabel = Instance.new("TextLabel")
	arrowLabel.Name = "Arrow"
	arrowLabel.Size = UDim2.new(0, 12, 1, 0)
	arrowLabel.Position = UDim2.new(1, -30, 0, 0)
	arrowLabel.BackgroundTransparency = 1
	arrowLabel.Text = if cfg.collapsed then "+" else "-"
	arrowLabel.TextSize = 12
	arrowLabel.FontFace = UITheme.Font.Mono
	arrowLabel.TextColor3 = UITheme.Color.Faint
	arrowLabel.Parent = headerBtn
	UITheme.textShadow(arrowLabel)

	-- Separator line under header
	local separator = Instance.new("Frame")
	separator.Name = "Separator"
	separator.Size = UDim2.new(1, 0, 0, 1)
	separator.Position = UDim2.new(0, 0, 0, cfg.headerHeight - 1)
	separator.BackgroundColor3 = UITheme.Color.Line
	separator.BackgroundTransparency = UITheme.Alpha.Line
	separator.BorderSizePixel = 0
	separator.Parent = panel

	-- Content area (holds objective rows) -----------------------
	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.new(1, 0, 1, -cfg.headerHeight - 6)
	content.Position = UDim2.new(0, 0, 0, cfg.headerHeight + 6)
	content.BackgroundTransparency = 1
	content.ClipsDescendants = true
	content.Parent = panel

	local listLayout = Instance.new("UIListLayout")
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, cfg.rowGap)
	listLayout.Parent = content

	return {
		screenGui = screenGui,
		hintLabel = hintLabel,
		panel = panel,
		scrim = scrim,
		headerBtn = headerBtn,
		headerLabel = headerLabel,
		arrowLabel = arrowLabel,
		separator = separator,
		content = content,
	}
end

return ObjectivesPanel
