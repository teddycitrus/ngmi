--!strict
--------------------------------------------------------------------------------
-- Lobby/Overlay.luau
-- Everything the lobby menu draws on top of itself:
--   * the match countdown: a card low on the screen with the number, who you
--     are playing with and a cancel button (or X / gamepad B); the menu stays
--     readable behind a light dim
--   * one-line notices at the bottom (joined a party, couldn't join, ...)
--   * the rejoin bar at the top when your last match is still running
--------------------------------------------------------------------------------

local UserInputService = game:GetService("UserInputService")

local Parts = require(script.Parent:WaitForChild("Parts"))

local INK = Parts.INK
local tween = Parts.tween

local TOAST_SECONDS = 3.5
local TONES: { [string]: Color3 } = {
	info = INK,
	good = Parts.GOOD,
	warn = Parts.WARN,
	bad = Parts.RED,
}

local Overlay = {}

export type Overlay = {
	countdown: (remaining: number, names: { string }) -> (),
	launching: () -> (),
	hideCountdown: () -> (),
	toast: (text: string, tone: string?) -> (),
	setRejoin: (visible: boolean) -> (),
}

--- `stage` is a 1600x900 frame scaled to the screen; `dim` is a full-screen
--- frame behind it (both above the menu).
function Overlay.build(stage: Frame, dim: Frame, send: (string, { [string]: any }?) -> ()): Overlay
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = 1
	dim.Visible = false

	-- Countdown --------------------------------------------------------------
	local CARD_W, CARD_H = 600, 300
	local card = Instance.new("Frame")
	card.AnchorPoint = Vector2.new(0.5, 1)
	card.Position = UDim2.new(0.5, 0, 1, -56)
	card.Size = UDim2.fromOffset(CARD_W, CARD_H)
	card.BackgroundColor3 = Parts.PANEL
	card.BackgroundTransparency = 0.06
	card.BorderSizePixel = 0
	card.Visible = false
	card.ZIndex = 4
	Instance.new("UICorner").Parent = card
	local cardStroke = Instance.new("UIStroke")
	cardStroke.Color = Parts.RED
	cardStroke.Transparency = 0.45
	cardStroke.Parent = card
	card.Parent = stage

	local heading = Parts.text(card, "MATCH FOUND", 26, Parts.BOLD, Parts.RED)
	heading.TextXAlignment = Enum.TextXAlignment.Center
	heading.Position = UDim2.fromOffset(0, 22)
	heading.ZIndex = 5

	-- TextSize stops at 100, so the number is drawn at 100 and sized with a
	-- UIScale, which also gives it its pop.
	local NUMBER_SCALE = 1.15
	local number = Parts.text(card, "", 100, Parts.SERIF, INK)
	number.TextXAlignment = Enum.TextXAlignment.Center
	number.AnchorPoint = Vector2.new(0.5, 0.5)
	number.Position = UDim2.new(0.5, 0, 0, 118)
	number.Size = UDim2.fromOffset(240, 104)
	number.ZIndex = 5
	local pop = Instance.new("UIScale")
	pop.Scale = NUMBER_SCALE
	pop.Parent = number

	local names = Parts.text(card, "", 24, Parts.LABEL, Parts.MUTED)
	names.TextXAlignment = Enum.TextXAlignment.Center
	names.Position = UDim2.fromOffset(24, 172)
	names.Size = UDim2.new(1, -48, 0, 28)
	names.TextTruncate = Enum.TextTruncate.AtEnd
	names.ZIndex = 5

	local counting = false
	local function cancel()
		if counting then
			counting = false
			send("cancelMatch")
		end
	end
	local cancelButton = Parts.button(card, "CANCEL  [X]", 52, false, cancel)
	cancelButton.button.AnchorPoint = Vector2.new(0.5, 1)
	cancelButton.button.Position = UDim2.new(0.5, 0, 1, -24)
	cancelButton.button.Size = UDim2.fromOffset(260, 52)
	cancelButton.button.ZIndex = 5

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or not card.Visible then
			return
		end
		if input.KeyCode == Enum.KeyCode.X or input.KeyCode == Enum.KeyCode.ButtonB then
			cancel()
		end
	end)

	local function showCountdown()
		if not dim.Visible then
			dim.Visible = true
			dim.BackgroundTransparency = 1
			tween(dim, { BackgroundTransparency = 0.45 }, 0.3)
		end
		card.Visible = true
	end

	-- Notices ----------------------------------------------------------------
	local toastFrame = Instance.new("Frame")
	toastFrame.AnchorPoint = Vector2.new(0.5, 1)
	toastFrame.Position = UDim2.new(0.5, 0, 1, -40)
	toastFrame.Size = UDim2.fromOffset(0, 60)
	toastFrame.AutomaticSize = Enum.AutomaticSize.X
	toastFrame.BackgroundColor3 = Parts.PANEL
	toastFrame.BackgroundTransparency = 0.08
	toastFrame.BorderSizePixel = 0
	toastFrame.Visible = false
	toastFrame.ZIndex = 5
	Instance.new("UICorner").Parent = toastFrame
	local toastStroke = Instance.new("UIStroke")
	toastStroke.Color = INK
	toastStroke.Transparency = 0.75
	toastStroke.Parent = toastFrame
	local toastPad = Instance.new("UIPadding")
	toastPad.PaddingLeft = UDim.new(0, 28)
	toastPad.PaddingRight = UDim.new(0, 28)
	toastPad.Parent = toastFrame
	toastFrame.Parent = stage
	local toastText = Parts.text(toastFrame, "", 28, Parts.LABEL, INK)
	toastText.Size = UDim2.fromScale(0, 1)
	toastText.AutomaticSize = Enum.AutomaticSize.X
	toastText.ZIndex = 6
	local toastId = 0

	-- Rejoin bar -------------------------------------------------------------
	local rejoin = Instance.new("Frame")
	rejoin.AnchorPoint = Vector2.new(0.5, 0)
	rejoin.Position = UDim2.new(0.5, 0, 0, 24)
	rejoin.Size = UDim2.fromOffset(820, 72)
	rejoin.BackgroundColor3 = Parts.PANEL
	rejoin.BackgroundTransparency = 0.08
	rejoin.BorderSizePixel = 0
	rejoin.Visible = false
	rejoin.ZIndex = 5
	Instance.new("UICorner").Parent = rejoin
	local rejoinStroke = Instance.new("UIStroke")
	rejoinStroke.Color = Parts.RED
	rejoinStroke.Transparency = 0.4
	rejoinStroke.Parent = rejoin
	rejoin.Parent = stage
	local rejoinText = Parts.text(rejoin, "Your last match is still running", 26, Parts.LABEL, INK)
	rejoinText.Position = UDim2.fromOffset(24, 21)
	rejoinText.Size = UDim2.new(1, -360, 0, 30)
	local back = Parts.button(rejoin, "REJOIN", 48, true, function()
		send("rejoin")
	end)
	back.button.AnchorPoint = Vector2.new(1, 0.5)
	back.button.Position = UDim2.new(1, -156, 0.5, 0)
	back.button.Size = UDim2.fromOffset(150, 48)
	local dismiss = Parts.button(rejoin, "DISMISS", 48, false, function()
		send("dismissRejoin")
	end)
	dismiss.button.AnchorPoint = Vector2.new(1, 0.5)
	dismiss.button.Position = UDim2.new(1, -14, 0.5, 0)
	dismiss.button.Size = UDim2.fromOffset(130, 48)

	return {
		countdown = function(remaining: number, list: { string })
			showCountdown()
			counting = true
			cancelButton.set("CANCEL  [X]", true)
			heading.Text = "MATCH FOUND"
			number.Text = tostring(remaining)
			pop.Scale = NUMBER_SCALE * 1.18
			tween(pop, { Scale = NUMBER_SCALE }, 0.35)
			names.Text = table.concat(list, ",  ")
		end,
		launching = function()
			showCountdown()
			counting = false
			cancelButton.set("STARTING", false)
			heading.Text = "MATCH FOUND"
			number.Text = "Go"
			pop.Scale = NUMBER_SCALE
		end,
		hideCountdown = function()
			counting = false
			card.Visible = false
			dim.Visible = false
		end,
		toast = function(text: string, tone: string?)
			toastId += 1
			local my = toastId
			toastText.Text = text
			toastText.TextColor3 = TONES[tone or "info"] or INK
			toastFrame.Visible = true
			toastText.TextTransparency = 0
			toastFrame.BackgroundTransparency = 0.08
			toastStroke.Transparency = 0.75
			task.delay(TOAST_SECONDS, function()
				if toastId ~= my then
					return
				end
				tween(toastText, { TextTransparency = 1 }, 0.4)
				tween(toastFrame, { BackgroundTransparency = 1 }, 0.4)
				tween(toastStroke, { Transparency = 1 }, 0.4)
				task.delay(0.45, function()
					if toastId == my then
						toastFrame.Visible = false
					end
				end)
			end)
		end,
		setRejoin = function(visible: boolean)
			rejoin.Visible = visible
		end,
	}
end

return Overlay
