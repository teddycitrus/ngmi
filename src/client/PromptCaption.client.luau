--!strict
--------------------------------------------------------------------------------
-- PromptCaption.client.luau
-- Replaces Roblox's ProximityPrompt billboard with one small caption near the
-- bottom of the screen ("PRESS E TO TALK"). Every prompt is switched to the
-- Custom style locally, so the server scripts that create them are unchanged.
-- Hold prompts get a thin bar under the caption that fills while held. The
-- caption is hidden during a conversation. On touch the caption itself is the
-- button.
--------------------------------------------------------------------------------

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local UITheme = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("UITheme"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local BOTTOM_OFFSET = 132 -- px above the bottom edge, clear of the hotbar
local FADE = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

--------------------------------------------------------------------------------
-- Every prompt draws through here
--------------------------------------------------------------------------------
local function claim(d: Instance)
	if d:IsA("ProximityPrompt") then
		d.Style = Enum.ProximityPromptStyle.Custom
	end
end
for _, d in workspace:GetDescendants() do
	claim(d)
end
workspace.DescendantAdded:Connect(claim)

--------------------------------------------------------------------------------
-- Caption
--------------------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "PromptCaption"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 40
gui.Parent = playerGui

local caption = Instance.new("TextButton")
caption.Name = "Caption"
caption.AnchorPoint = Vector2.new(0.5, 1)
caption.Position = UDim2.new(0.5, 0, 1, -BOTTOM_OFFSET)
caption.Size = UDim2.fromOffset(0, 18)
caption.AutomaticSize = Enum.AutomaticSize.X
caption.BackgroundTransparency = 1
caption.AutoButtonColor = false
caption.Selectable = false
caption.FontFace = UITheme.Font.Medium
caption.TextSize = 14
caption.TextColor3 = UITheme.Color.Text
caption.TextStrokeColor3 = Color3.new(0, 0, 0)
caption.TextStrokeTransparency = 1
caption.TextTransparency = 1
caption.Text = ""
caption.Visible = false
caption.Parent = gui

local track = Instance.new("Frame")
track.Name = "Hold"
track.AnchorPoint = Vector2.new(0.5, 0)
track.Position = UDim2.new(0.5, 0, 1, 3)
track.Size = UDim2.new(1, 0, 0, 1)
track.BackgroundColor3 = Color3.new(1, 1, 1)
track.BackgroundTransparency = 0.8
track.BorderSizePixel = 0
track.Visible = false
track.Parent = caption

local fill = Instance.new("Frame")
fill.Name = "Fill"
fill.Size = UDim2.fromScale(0, 1)
fill.BackgroundColor3 = Color3.new(1, 1, 1)
fill.BorderSizePixel = 0
fill.Parent = track

local current: ProximityPrompt? = nil
local holdStart: number? = nil
local shown = false

local function keyName(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType): string
	if inputType == Enum.ProximityPromptInputType.Gamepad then
		return (prompt.GamepadKeyCode.Name:gsub("^Button", ""))
	end
	local name = prompt.KeyboardKeyCode.Name
	return if #name == 1 then name else name:upper()
end

local function textFor(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType): string
	local action = (if prompt.ActionText ~= "" then prompt.ActionText else "interact"):upper()
	local verb = if prompt.HoldDuration > 0 then "HOLD" else "PRESS"
	if inputType == Enum.ProximityPromptInputType.Touch then
		return (if prompt.HoldDuration > 0 then "HOLD HERE TO " else "TAP TO ") .. action
	end
	return verb .. " " .. keyName(prompt, inputType) .. " TO " .. action
end

local function setShown(on: boolean)
	if on == shown then
		return
	end
	shown = on
	if on then
		caption.Visible = true
	end
	local tween = TweenService:Create(caption, FADE, {
		TextTransparency = if on then 0.05 else 1,
		TextStrokeTransparency = if on then 0.55 else 1,
	})
	tween:Play()
	if not on then
		tween.Completed:Connect(function()
			if not shown then
				caption.Visible = false
			end
		end)
	end
end

local function refresh()
	local talking = player:GetAttribute("InDialogue") == true
	setShown(current ~= nil and not talking)
end

ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType)
	if prompt.Style ~= Enum.ProximityPromptStyle.Custom then
		return
	end
	current = prompt
	holdStart = nil
	caption.Text = textFor(prompt, inputType)
	track.Visible = prompt.HoldDuration > 0
	fill.Size = UDim2.fromScale(0, 1)
	refresh()
end)

ProximityPromptService.PromptHidden:Connect(function(prompt: ProximityPrompt)
	if prompt == current then
		current = nil
		holdStart = nil
		refresh()
	end
end)

ProximityPromptService.PromptButtonHoldBegan:Connect(function(prompt: ProximityPrompt)
	if prompt == current then
		holdStart = os.clock()
	end
end)

ProximityPromptService.PromptButtonHoldEnded:Connect(function(prompt: ProximityPrompt)
	if prompt == current then
		holdStart = nil
		fill.Size = UDim2.fromScale(0, 1)
	end
end)

ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt)
	if prompt == current then
		holdStart = nil
		fill.Size = UDim2.fromScale(0, 1)
	end
end)

player:GetAttributeChangedSignal("InDialogue"):Connect(refresh)

RunService.RenderStepped:Connect(function()
	local p = current
	if p and holdStart and p.HoldDuration > 0 then
		fill.Size = UDim2.fromScale(math.clamp((os.clock() - holdStart) / p.HoldDuration, 0, 1), 1)
	end
end)

-- touch: the caption is the button
caption.InputBegan:Connect(function(input: InputObject)
	local p = current
	if p and shown and input.UserInputType == Enum.UserInputType.Touch then
		p:InputHoldBegin()
	end
end)
caption.InputEnded:Connect(function(input: InputObject)
	local p = current
	if p and input.UserInputType == Enum.UserInputType.Touch then
		p:InputHoldEnd()
	end
end)

