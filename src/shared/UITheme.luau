--!strict
--------------------------------------------------------------------------------
-- UITheme.luau
-- Shared look for every HUD element: one type family, one palette, and a few
-- builders so each script draws the same thin, boxless style.
--
-- Rules the HUD follows:
--   * No filled panels over the world. Text sits directly on the scene with a
--     faint dark stroke so it stays readable on bright walls.
--   * Bars are 2 px hairlines on a faint track.
--   * Colour is reserved for state (danger red, low amber). Everything else is
--     off-white at a few opacity steps.
--------------------------------------------------------------------------------

local UITheme = {}

local SANS = Font.fromEnum(Enum.Font.BuilderSans).Family
local MONO = Font.fromEnum(Enum.Font.RobotoMono).Family

UITheme.Font = {
	Regular = Font.new(SANS, Enum.FontWeight.Regular),
	Medium = Font.new(SANS, Enum.FontWeight.Medium),
	Bold = Font.new(SANS, Enum.FontWeight.Bold),
	Mono = Font.new(MONO, Enum.FontWeight.Regular),
	MonoMedium = Font.new(MONO, Enum.FontWeight.Medium),
}

UITheme.Color = {
	Text = Color3.fromRGB(236, 236, 240),
	Dim = Color3.fromRGB(168, 170, 178),
	Faint = Color3.fromRGB(110, 112, 120),
	Surface = Color3.fromRGB(10, 11, 14),
	Line = Color3.fromRGB(255, 255, 255),
	Danger = Color3.fromRGB(226, 72, 72),
	Warn = Color3.fromRGB(232, 178, 92),
	Good = Color3.fromRGB(150, 214, 170),
	Shadow = Color3.new(0, 0, 0),
}

-- Opacity steps used as Transparency values.
UITheme.Alpha = {
	Surface = 0.45, -- the rare filled element (hotbar slot, dialogue)
	Track = 0.86, -- empty part of a bar
	Line = 0.88, -- hairline borders and separators
	Shadow = 0.72, -- text stroke
}

UITheme.Margin = 24
UITheme.Tween = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

export type LabelProps = {
	text: string?,
	size: number?,
	font: Font?,
	color: Color3?,
	transparency: number?,
	alignX: Enum.TextXAlignment?,
	alignY: Enum.TextYAlignment?,
	shadow: boolean?,
}

--- Transparent TextLabel in the theme font. `shadow` adds the dark text stroke
--- that keeps world-overlay text legible without a backing panel.
function UITheme.label(parent: Instance?, props: LabelProps): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.BorderSizePixel = 0
	l.Text = props.text or ""
	l.TextSize = props.size or 14
	l.FontFace = props.font or UITheme.Font.Medium
	l.TextColor3 = props.color or UITheme.Color.Text
	l.TextTransparency = props.transparency or 0
	l.TextXAlignment = props.alignX or Enum.TextXAlignment.Left
	l.TextYAlignment = props.alignY or Enum.TextYAlignment.Center
	if props.shadow ~= false then
		UITheme.textShadow(l)
	end
	l.Parent = parent
	return l
end

--- Thin dark outline on a text object.
function UITheme.textShadow(obj: TextLabel | TextButton): UIStroke
	local s = Instance.new("UIStroke")
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	s.Color = UITheme.Color.Shadow
	s.Thickness = 1
	s.Transparency = UITheme.Alpha.Shadow
	s.Parent = obj
	return s
end

function UITheme.corner(parent: Instance, radius: number?): UICorner
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 4)
	c.Parent = parent
	return c
end

--- 1 px hairline border around a frame.
function UITheme.outline(parent: Instance, transparency: number?, color: Color3?): UIStroke
	local s = Instance.new("UIStroke")
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Color = color or UITheme.Color.Line
	s.Thickness = 1
	s.Transparency = transparency or UITheme.Alpha.Line
	s.Parent = parent
	return s
end

function UITheme.padding(parent: Instance, x: number, y: number?): UIPadding
	local p = Instance.new("UIPadding")
	p.PaddingLeft = UDim.new(0, x)
	p.PaddingRight = UDim.new(0, x)
	p.PaddingTop = UDim.new(0, y or x)
	p.PaddingBottom = UDim.new(0, y or x)
	p.Parent = parent
	return p
end

export type Meter = {
	root: Frame,
	label: TextLabel,
	value: TextLabel,
	track: Frame,
	fill: Frame,
}

--- Caption + value on one line with a hairline bar under it:
---
---   ENERGY                 82
---   ━━━━━━━━━━━━━━━━━──────
---
--- Returns the parts so the owner can drive fill size and colour.
function UITheme.meter(parent: Instance?, caption: string, width: number): Meter
	local root = Instance.new("Frame")
	root.Name = caption
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromOffset(width, 20)

	local label = UITheme.label(root, {
		text = string.upper(caption),
		size = 11,
		font = UITheme.Font.Bold,
		color = UITheme.Color.Dim,
	})
	label.Name = "Caption"
	label.Size = UDim2.new(1, 0, 0, 12)

	local value = UITheme.label(root, {
		size = 11,
		font = UITheme.Font.MonoMedium,
		color = UITheme.Color.Dim,
		alignX = Enum.TextXAlignment.Right,
	})
	value.Name = "Value"
	value.Size = UDim2.new(1, 0, 0, 12)

	local track = Instance.new("Frame")
	track.Name = "Track"
	track.AnchorPoint = Vector2.new(0, 1)
	track.Position = UDim2.fromScale(0, 1)
	track.Size = UDim2.new(1, 0, 0, 2)
	track.BackgroundColor3 = UITheme.Color.Line
	track.BackgroundTransparency = UITheme.Alpha.Track
	track.BorderSizePixel = 0
	track.Parent = root

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = UITheme.Color.Text
	fill.BorderSizePixel = 0
	fill.Parent = track

	root.Parent = parent
	return { root = root, label = label, value = value, track = track, fill = fill }
end

--- Flat button: faint surface, hairline border, brightens on hover. Owners that
--- tint a button (toggles) set its "BaseTransparency" attribute so hover keeps
--- working relative to the tint.
--- Soft dark wash behind boxless text so it survives bright or busy scenery.
--- Fades out toward `fadeSide` ("left" or "right"); returns the frame so the
--- owner can size and position it.
function UITheme.scrim(parent: Instance, fadeSide: "left" | "right", strength: number?): Frame
	local f = Instance.new("Frame")
	f.Name = "Scrim"
	f.BackgroundColor3 = UITheme.Color.Surface
	f.BackgroundTransparency = 0
	f.BorderSizePixel = 0
	f.ZIndex = 0
	local g = Instance.new("UIGradient")
	local dark = 1 - (strength or 0.5)
	g.Transparency = if fadeSide == "left"
		then NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, dark) })
		else NumberSequence.new({ NumberSequenceKeypoint.new(0, dark), NumberSequenceKeypoint.new(1, 1) })
	g.Parent = f
	f.Parent = parent
	return f
end

function UITheme.button(parent: Instance?, text: string, height: number): TextButton
	local b = Instance.new("TextButton")
	b.AutoButtonColor = false
	b.Size = UDim2.new(1, 0, 0, height)
	b.BackgroundColor3 = UITheme.Color.Line
	b.BackgroundTransparency = 0.95
	b.BorderSizePixel = 0
	b.Text = text
	b.TextSize = 13
	b.FontFace = UITheme.Font.Medium
	b.TextColor3 = UITheme.Color.Text
	UITheme.corner(b, 4)
	UITheme.outline(b)
	local function base(): number
		return (b:GetAttribute("BaseTransparency") :: number?) or 0.95
	end
	b.MouseEnter:Connect(function()
		b.BackgroundTransparency = base() - 0.07
	end)
	b.MouseLeave:Connect(function()
		b.BackgroundTransparency = base()
	end)
	b.Parent = parent
	return b
end

return UITheme
