--!strict
--------------------------------------------------------------------------------
-- Opening/Overlay.luau
-- The 2D layer over OpeningCinematic: letterbox bars (start collapsed), the
-- subtitle caption, and the title card. All text starts fully transparent;
-- the scene fades it in.
--------------------------------------------------------------------------------

local UITheme = require(script.Parent.Parent.UITheme)

export type Parts = {
	gui: ScreenGui,
	topBar: Frame,
	botBar: Frame,
	caption: TextLabel,
	title: TextLabel,
	subtitle: TextLabel,
}

local Overlay = {}

function Overlay.build(playerGui: PlayerGui): Parts
	local gui = Instance.new("ScreenGui")
	gui.Name = "OpeningCinematic"
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 400
	gui.Parent = playerGui

	local function bar(anchorY: number): Frame
		local f = Instance.new("Frame")
		f.BackgroundColor3 = Color3.new(0, 0, 0)
		f.BorderSizePixel = 0
		f.AnchorPoint = Vector2.new(0, anchorY)
		f.Position = UDim2.new(0, 0, anchorY, 0)
		f.Size = UDim2.new(1, 0, 0, 0)
		f.Parent = gui
		return f
	end

	local caption = Instance.new("TextLabel")
	caption.AnchorPoint = Vector2.new(0.5, 1)
	caption.Size = UDim2.new(0.82, 0, 0, 120)
	caption.Position = UDim2.new(0.5, 0, 0.86, 0)
	caption.BackgroundTransparency = 1
	caption.FontFace = UITheme.Font.Medium
	caption.TextSize = 24
	caption.TextColor3 = Color3.fromRGB(245, 245, 245)
	caption.TextStrokeTransparency = 0.5
	caption.TextWrapped = true
	caption.TextYAlignment = Enum.TextYAlignment.Bottom
	caption.TextTransparency = 1
	caption.Text = ""
	caption.Parent = gui

	local title = Instance.new("TextLabel")
	title.AnchorPoint = Vector2.new(0.5, 0.5)
	title.Size = UDim2.new(0.8, 0, 0, 60)
	title.Position = UDim2.new(0.5, 0, 0.44, 0)
	title.BackgroundTransparency = 1
	title.FontFace = UITheme.Font.Bold
	title.TextSize = 46
	title.TextColor3 = Color3.fromRGB(250, 250, 250)
	title.TextStrokeTransparency = 0.6
	title.TextTransparency = 1
	title.Text = "VESPERHACKS 2026"
	title.Parent = gui
	local subtitle = title:Clone()
	subtitle.Position = UDim2.new(0.5, 0, 0.51, 0)
	subtitle.FontFace = UITheme.Font.Regular
	subtitle.TextSize = 22
	subtitle.Text = "St. Vesper University  |  48 hours"
	subtitle.Parent = gui

	return {
		gui = gui,
		topBar = bar(0),
		botBar = bar(1),
		caption = caption,
		title = title,
		subtitle = subtitle,
	}
end

return Overlay
