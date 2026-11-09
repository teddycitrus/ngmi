--!strict
--------------------------------------------------------------------------------
-- Lobby/Parts.luau
-- Pieces of the lobby menu (LobbyUI): its type and colours, the mode rows,
-- buttons and toggles, and holding the gameplay HUD off the screen while the
-- menu is up. Sizes are in the menu's 1600x900 design space (LobbyUI scales
-- that to the screen).
--------------------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local UITheme = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UITheme"))

local Parts = {}

-- The menu has its own type: an old-style serif for the title and the mode
-- names (the same Garamond as the university's monument sign out front),
-- and a narrow grotesque for everything small.
local COND = Font.fromEnum(Enum.Font.RobotoCondensed).Family
Parts.SERIF = Font.fromEnum(Enum.Font.Garamond)
Parts.LABEL = Font.new(COND, Enum.FontWeight.Medium)
Parts.BOLD = Font.new(COND, Enum.FontWeight.Bold)
Parts.BODY = Font.new(COND, Enum.FontWeight.Regular)
Parts.MONO = UITheme.Font.MonoMedium
Parts.INK = Color3.fromRGB(238, 233, 224) -- warm off-white
Parts.MUTED = Color3.fromRGB(165, 162, 157)
Parts.RED = UITheme.Color.Danger
Parts.GOOD = UITheme.Color.Good
Parts.WARN = UITheme.Color.Warn
Parts.PANEL = Color3.fromRGB(14, 14, 17)

Parts.LINE_IDLE = 0.82
Parts.LINE_HOVER = 0.6
Parts.NAME_IDLE = 0.15
local HOVER_SHIFT = 10
local ROW_HEIGHT = 96

function Parts.tween(obj: Instance, props: { [string]: any }, t: number?)
	TweenService:Create(obj, TweenInfo.new(t or 0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props):Play()
end
local tween = Parts.tween

--- Plain text with the menu's defaults (no drop shadow).
function Parts.text(parent: Instance, text: string, size: number, font: Font?, color: Color3?): TextLabel
	local l = UITheme.label(parent, { text = text, size = size, font = font or Parts.LABEL, color = color or Parts.INK, shadow = false })
	l.Size = UDim2.new(1, 0, 0, size + 4)
	return l
end

export type Row = {
	button: TextButton,
	line: Frame,
	marker: Frame,
	name: TextLabel,
	count: TextLabel,
	setEnabled: (boolean) -> (),
}

--- One mode in the list: an open line of type over a hairline, not a card.
--- `isActive` says whether this is the party's mode; `onPick` runs on click.
function Parts.row(parent: Instance, order: number, queueSize: number, name: string, desc: string, isActive: () -> boolean, onPick: () -> ()): Row
	local enabled = true
	local button = Instance.new("TextButton")
	button.Name = "Mode_" .. queueSize
	button.LayoutOrder = order
	button.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
	button.BackgroundTransparency = 1
	button.AutoButtonColor = false
	button.BorderSizePixel = 0
	button.Text = ""
	button.Parent = parent

	local line = Instance.new("Frame")
	line.Name = "Rule"
	line.AnchorPoint = Vector2.new(0, 1)
	line.Position = UDim2.fromScale(0, 1)
	line.Size = UDim2.new(1, 0, 0, 1)
	line.BackgroundColor3 = Parts.INK
	line.BackgroundTransparency = Parts.LINE_IDLE
	line.BorderSizePixel = 0
	line.Parent = button

	-- Red bar at the left, shown for the party's mode
	local marker = Instance.new("Frame")
	marker.Name = "Marker"
	marker.Position = UDim2.fromOffset(-20, 18)
	marker.Size = UDim2.fromOffset(4, 56)
	marker.BackgroundColor3 = Parts.RED
	marker.BackgroundTransparency = 1
	marker.BorderSizePixel = 0
	marker.Parent = button

	local nameLabel = UITheme.label(button, { text = name, size = 50, font = Parts.SERIF, color = Parts.INK, transparency = Parts.NAME_IDLE, shadow = false })
	nameLabel.Position = UDim2.fromOffset(0, 6)
	nameLabel.Size = UDim2.new(1, -170, 0, 52)

	local descLabel = UITheme.label(button, { text = desc, size = 22, font = Parts.BODY, color = Parts.MUTED, shadow = false })
	descLabel.Position = UDim2.fromOffset(0, 60)
	descLabel.Size = UDim2.new(1, -170, 0, 24)

	local count = UITheme.label(button, {
		text = "",
		size = 22,
		font = Parts.LABEL,
		color = Parts.MUTED,
		alignX = Enum.TextXAlignment.Right,
		shadow = false,
	})
	count.Name = "QueueCount"
	count.AnchorPoint = Vector2.new(1, 0.5)
	count.Position = UDim2.new(1, 0, 0.5, 0)
	count.Size = UDim2.fromOffset(170, 24)

	local function hover(on: boolean)
		local lit = (on and enabled) or isActive()
		local shift = if lit then HOVER_SHIFT else 0
		tween(nameLabel, { Position = UDim2.fromOffset(shift, 6), TextTransparency = if lit then 0 else Parts.NAME_IDLE })
		tween(descLabel, { Position = UDim2.fromOffset(shift, 60) })
		tween(line, { BackgroundTransparency = if lit then Parts.LINE_HOVER else Parts.LINE_IDLE })
	end
	button.MouseEnter:Connect(function()
		hover(true)
	end)
	button.MouseLeave:Connect(function()
		hover(false)
	end)
	button.Activated:Connect(function()
		if enabled then
			onPick()
		end
	end)

	return {
		button = button,
		line = line,
		marker = marker,
		name = nameLabel,
		count = count,
		setEnabled = function(on: boolean)
			enabled = on
			button.AutoButtonColor = false
			hover(false)
		end,
	}
end

export type Button = {
	button: TextButton,
	set: (text: string, enabled: boolean?) -> (),
}

--- A menu button. `primary` is filled off-white with dark type; the rest are
--- outlined. Disabled buttons dim and ignore clicks.
function Parts.button(parent: Instance, text: string, height: number, primary: boolean?, onClick: () -> ()): Button
	local enabled = true
	local b = Instance.new("TextButton")
	b.AutoButtonColor = false
	b.Size = UDim2.new(1, 0, 0, height)
	b.BorderSizePixel = 0
	b.Text = text
	b.TextSize = math.floor(height * 0.4)
	b.FontFace = Parts.BOLD
	b.TextColor3 = if primary then Color3.fromRGB(16, 16, 18) else Parts.INK
	b.BackgroundColor3 = Parts.INK
	local idle = if primary then 0 else 0.94
	b.BackgroundTransparency = idle
	UITheme.corner(b, 6)
	if not primary then
		UITheme.outline(b, 0.7, Parts.INK)
	end
	b.MouseEnter:Connect(function()
		if enabled then
			tween(b, { BackgroundTransparency = if primary then 0.12 else 0.86 })
		end
	end)
	b.MouseLeave:Connect(function()
		tween(b, { BackgroundTransparency = if enabled then idle else (if primary then 0.7 else 0.97) })
	end)
	b.Activated:Connect(function()
		if enabled then
			onClick()
		end
	end)
	b.Parent = parent
	return {
		button = b,
		set = function(newText: string, on: boolean?)
			b.Text = newText
			enabled = on ~= false
			b.BackgroundTransparency = if enabled then idle else (if primary then 0.7 else 0.97)
			b.TextTransparency = if enabled then 0 else 0.45
		end,
	}
end

--- Horizontal list layout with a gap.
function Parts.hlist(parent: Instance, gap: number): UIListLayout
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Padding = UDim.new(0, gap)
	layout.Parent = parent
	return layout
end

--- Vertical list layout with a gap.
function Parts.vlist(parent: Instance, gap: number): UIListLayout
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, gap)
	layout.Parent = parent
	return layout
end

--- Transparent container frame.
function Parts.box(parent: Instance, order: number, height: number): Frame
	local f = Instance.new("Frame")
	f.LayoutOrder = order
	f.Size = UDim2.new(1, 0, 0, height)
	f.BackgroundTransparency = 1
	f.BorderSizePixel = 0
	f.Parent = parent
	return f
end

--- Keep every other ScreenGui (hotbar, meters) disabled until the returned
--- function is called, which turns back on exactly the ones it turned off.
--- Names in `keep` are left alone.
function Parts.holdHud(playerGui: Instance, keep: { [string]: boolean }): () -> ()
	local hidden: { ScreenGui } = {}
	local conns: { RBXScriptConnection } = {}
	local function hold(g: Instance)
		if not g:IsA("ScreenGui") or keep[g.Name] then
			return
		end
		local sg = g :: ScreenGui
		local function hide()
			if sg.Enabled then
				sg.Enabled = false
				if not table.find(hidden, sg) then
					table.insert(hidden, sg)
				end
			end
		end
		hide()
		table.insert(conns, sg:GetPropertyChangedSignal("Enabled"):Connect(hide))
	end
	for _, g in playerGui:GetChildren() do
		hold(g)
	end
	table.insert(conns, playerGui.ChildAdded:Connect(function(g)
		task.defer(hold, g)
	end))
	return function()
		for _, c in conns do
			c:Disconnect()
		end
		table.clear(conns)
		for _, sg in hidden do
			if sg.Parent then
				sg.Enabled = true
			end
		end
		table.clear(hidden)
	end
end

return Parts
