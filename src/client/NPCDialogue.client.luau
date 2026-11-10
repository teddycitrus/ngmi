--!strict
--------------------------------------------------------------------------------
-- NPCDialogue.client.luau
-- Talking to a named NPC, in first person.
--
--   * The camera stays in your head and turns to hold their eyes; you stand
--     still for the conversation (movement is handed back when it ends).
--   * Their line types out as a caption over the lower screen, then the
--     replies appear numbered under it: press 1-9 or click one. Space, Enter
--     or a click finishes a line early.
--   * While they talk they gesture (Talk/Gestures): the node's gestures from
--     NPCConfig play across the line, then they hold a listening pose.
--
-- The server sends each node (NPCDialogueTrigger) and gets each choice back
-- (NPCDialogueChoice; a nil responseId ends the conversation and the NPC
-- walks off).
--------------------------------------------------------------------------------

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local NPCDialogueTrigger = Remotes:WaitForChild("NPCDialogueTrigger") :: RemoteEvent
local NPCDialogueChoice = Remotes:WaitForChild("NPCDialogueChoice") :: RemoteEvent

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CursorManager = require(Shared:WaitForChild("CursorManager"))
local NPCConfig = require(Shared:WaitForChild("NPCConfig"))
local UITheme = require(Shared:WaitForChild("UITheme"))
local Gestures = require(script.Parent:WaitForChild("Talk"):WaitForChild("Gestures"))

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local CHARS_PER_SEC = 42
local MAX_TALK_DISTANCE = 22 -- studs; past this (they got pulled away) it ends
local CAMERA_RENDER = "NPCDialogueCamera"
local KEYS_ACTION = "NPCDialogueKeys"
local CAM_EASE = 5 -- 1/s, how quickly the view settles on their eyes
local IN_DIALOGUE = "InDialogue" -- player attribute other input scripts check

local TEXT = Color3.fromRGB(242, 242, 242)
local DIM = UITheme.Color.Dim
local REPLY = Color3.fromRGB(206, 208, 214)
local FAINT = Color3.fromRGB(150, 152, 160)

local NUMBER_KEYS: { [Enum.KeyCode]: number } = {
	[Enum.KeyCode.One] = 1,
	[Enum.KeyCode.Two] = 2,
	[Enum.KeyCode.Three] = 3,
	[Enum.KeyCode.Four] = 4,
	[Enum.KeyCode.Five] = 5,
	[Enum.KeyCode.Six] = 6,
	[Enum.KeyCode.Seven] = 7,
	[Enum.KeyCode.Eight] = 8,
	[Enum.KeyCode.Nine] = 9,
	[Enum.KeyCode.KeypadOne] = 1,
	[Enum.KeyCode.KeypadTwo] = 2,
	[Enum.KeyCode.KeypadThree] = 3,
	[Enum.KeyCode.KeypadFour] = 4,
	[Enum.KeyCode.KeypadFive] = 5,
	[Enum.KeyCode.KeypadSix] = 6,
	[Enum.KeyCode.KeypadSeven] = 7,
	[Enum.KeyCode.KeypadEight] = 8,
	[Enum.KeyCode.KeypadNine] = 9,
}

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

type Option = { text: string, responseId: string? }

local active = false
local npcId: string? = nil
local npcModel: Model? = nil
local options: { Option } = {}
local optionButtons: { TextButton } = {}
local typing: thread? = nil
local choosing = false -- options are up and answerable
local camRot: CFrame? = nil
local watchConn: RBXScriptConnection? = nil

--------------------------------------------------------------------------------
-- Player controls
--------------------------------------------------------------------------------

local controls: any = nil
local function getControls(): any
	if controls then
		return controls
	end
	local ok, result = pcall(function()
		local module = player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 5)
		return module and (require(module :: ModuleScript) :: any):GetControls()
	end)
	if ok then
		controls = result
	end
	return controls
end

local function holdStill(on: boolean)
	local c = getControls()
	if c then
		if on then
			c:Disable()
		else
			c:Enable()
		end
	end
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if on and hum then
		hum:Move(Vector3.zero)
	end
	player:SetAttribute(IN_DIALOGUE, if on then true else nil)
end

--------------------------------------------------------------------------------
-- GUI
--------------------------------------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "NPCDialogueGui"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.DisplayOrder = 100
gui.Enabled = false

-- Their line is a subtitle along the bottom; the replies stand to the right
-- of centre, clear of their face and hands. A soft dark wash under the
-- subtitle keeps it readable on any background.
local shade = Instance.new("Frame")
shade.Name = "Shade"
shade.AnchorPoint = Vector2.new(0, 1)
shade.Position = UDim2.fromScale(0, 1)
shade.Size = UDim2.fromScale(1, 0.5)
shade.BackgroundColor3 = Color3.new(0, 0, 0)
shade.BorderSizePixel = 0
shade.Parent = gui
local shadeGradient = Instance.new("UIGradient")
shadeGradient.Rotation = 90
shadeGradient.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(1, 0.45),
})
shadeGradient.Parent = shade

local column = Instance.new("Frame")
column.Name = "Column"
column.AnchorPoint = Vector2.new(0.5, 1)
column.Position = UDim2.new(0.5, 0, 1, -112) -- clear of the hotbar
column.Size = UDim2.new(0.56, 0, 0, 0)
column.AutomaticSize = Enum.AutomaticSize.Y
column.BackgroundTransparency = 1
column.Parent = gui
local columnCap = Instance.new("UISizeConstraint")
columnCap.MaxSize = Vector2.new(720, math.huge)
columnCap.Parent = column
local columnLayout = Instance.new("UIListLayout")
columnLayout.SortOrder = Enum.SortOrder.LayoutOrder
columnLayout.Padding = UDim.new(0, 6)
columnLayout.Parent = column

local nameLabel = Instance.new("TextLabel")
nameLabel.Name = "Speaker"
nameLabel.LayoutOrder = 1
nameLabel.Size = UDim2.new(1, 0, 0, 18)
nameLabel.BackgroundTransparency = 1
nameLabel.FontFace = UITheme.Font.Bold
nameLabel.TextSize = 15
nameLabel.TextXAlignment = Enum.TextXAlignment.Center
nameLabel.TextStrokeTransparency = 0.75
nameLabel.Parent = column

local lineLabel = Instance.new("TextLabel")
lineLabel.Name = "Line"
lineLabel.LayoutOrder = 2
lineLabel.Size = UDim2.new(1, 0, 0, 0)
lineLabel.AutomaticSize = Enum.AutomaticSize.Y
lineLabel.BackgroundTransparency = 1
lineLabel.FontFace = UITheme.Font.Medium
lineLabel.TextSize = 22
lineLabel.LineHeight = 1.12
lineLabel.TextColor3 = TEXT
lineLabel.TextStrokeTransparency = 0.6
lineLabel.TextWrapped = true
lineLabel.RichText = true
lineLabel.TextXAlignment = Enum.TextXAlignment.Center
lineLabel.TextYAlignment = Enum.TextYAlignment.Top
lineLabel.Parent = column

-- the same wash, fading in from the left behind the replies
local replyShade = Instance.new("Frame")
replyShade.Name = "ReplyShade"
replyShade.AnchorPoint = Vector2.new(0, 0.5)
replyShade.Position = UDim2.fromScale(0.55, 0.52)
replyShade.Size = UDim2.fromScale(0.45, 0.36)
replyShade.BackgroundColor3 = Color3.new(0, 0, 0)
replyShade.BorderSizePixel = 0
replyShade.BackgroundTransparency = 1
replyShade.Parent = gui
local replyGradient = Instance.new("UIGradient")
replyGradient.Transparency = NumberSequence.new({
	NumberSequenceKeypoint.new(0, 1),
	NumberSequenceKeypoint.new(0.3, 0.55),
	NumberSequenceKeypoint.new(1, 0.5),
})
replyGradient.Parent = replyShade

local optionList = Instance.new("Frame")
optionList.Name = "Replies"
optionList.AnchorPoint = Vector2.new(0, 0.5)
optionList.Position = UDim2.fromScale(0.6, 0.52)
optionList.Size = UDim2.new(0.3, 0, 0, 0)
optionList.AutomaticSize = Enum.AutomaticSize.Y
optionList.BackgroundTransparency = 1
optionList.Parent = gui
local optionCap = Instance.new("UISizeConstraint")
optionCap.MaxSize = Vector2.new(420, math.huge)
optionCap.Parent = optionList
local optionLayout = Instance.new("UIListLayout")
optionLayout.SortOrder = Enum.SortOrder.LayoutOrder
optionLayout.Padding = UDim.new(0, 4)
optionLayout.Parent = optionList

gui.Parent = playerGui

local function hex(c: Color3): string
	return string.format("#%02x%02x%02x", math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5))
end

local function escape(s: string): string
	return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

--- The line as rich text: *stage directions* dimmed and in italics.
local function richLine(text: string): string
	local out = escape(text)
	out = out:gsub("%*(.-)%*", function(inner: string)
		return string.format('<i><font color="%s">%s</font></i>', hex(DIM), inner)
	end)
	return out
end

local function optionText(i: number, text: string, hot: boolean): string
	local num = if hot then hex(TEXT) else hex(FAINT)
	return string.format('<font face="RobotoMono" color="%s">%d</font>   %s', num, i, escape(text))
end

local function setHot(btn: TextButton, i: number, hot: boolean)
	local o = options[i]
	if not o then
		return
	end
	btn.Text = optionText(i, o.text, hot)
	btn.TextColor3 = if hot then TEXT else REPLY
end

local choose: (i: number) -> ()

local iconHeld = false
local function showCursor(on: boolean)
	if on ~= iconHeld then
		iconHeld = on
		if on then
			CursorManager.holdIcon()
		else
			CursorManager.releaseIcon()
		end
	end
end

local function clearOptions()
	for _, b in optionButtons do
		b:Destroy()
	end
	optionButtons = {}
	choosing = false
	showCursor(false)
	TweenService:Create(replyShade, TweenInfo.new(0.15), { BackgroundTransparency = 1 }):Play()
end

local function showOptions()
	clearOptions()
	for i in options do
		local btn = Instance.new("TextButton")
		btn.Name = "Reply" .. i
		btn.LayoutOrder = i
		btn.Size = UDim2.new(1, 0, 0, 30)
		btn.AutomaticSize = Enum.AutomaticSize.Y
		btn.BackgroundTransparency = 1
		btn.AutoButtonColor = false
		btn.Modal = true -- frees the cursor in first person while replies are up
		btn.FontFace = UITheme.Font.Regular
		btn.TextSize = 19
		btn.RichText = true
		btn.TextWrapped = true
		btn.TextXAlignment = Enum.TextXAlignment.Left
		btn.TextStrokeTransparency = 0.35
		btn.TextTransparency = 1
		setHot(btn, i, false)
		btn.MouseEnter:Connect(function()
			setHot(btn, i, true)
		end)
		btn.MouseLeave:Connect(function()
			setHot(btn, i, false)
		end)
		btn.Activated:Connect(function()
			choose(i)
		end)
		btn.Parent = optionList
		table.insert(optionButtons, btn)
		TweenService:Create(btn, TweenInfo.new(0.18), { TextTransparency = 0 }):Play()
	end
	choosing = true
	showCursor(true)
	TweenService:Create(replyShade, TweenInfo.new(0.2), { BackgroundTransparency = 0 }):Play()
end

--------------------------------------------------------------------------------
-- Lines
--------------------------------------------------------------------------------

local function finishLine()
	if typing then
		task.cancel(typing)
		typing = nil
	end
	lineLabel.MaxVisibleGraphemes = -1
	if npcModel then
		Gestures.listen(npcModel)
	end
	if not choosing then
		showOptions()
	end
end

local function sayLine(text: string)
	clearOptions()
	lineLabel.Text = richLine(text)
	lineLabel.MaxVisibleGraphemes = 0
	if typing then
		task.cancel(typing)
	end
	typing = task.spawn(function()
		local shown = 0
		local total = utf8.len(lineLabel.ContentText) or #text
		local t0 = os.clock()
		while shown < total do
			RunService.Heartbeat:Wait()
			shown = math.min(total, math.floor((os.clock() - t0) * CHARS_PER_SEC))
			lineLabel.MaxVisibleGraphemes = shown
		end
		typing = nil
		finishLine()
	end)
end

--- The node's gestures from NPCConfig, or a guess from the line.
local function gesturesFor(id: string, nodeId: string?, text: string): ({ string }, string)
	for _, def in NPCConfig.npcs do
		if def.id == id then
			local node = nodeId and def.dialogue[nodeId]
			if node and node.gestures then
				return node.gestures, node.listen or "rest"
			end
			break
		end
	end
	local seq = {}
	if nodeId == "start" then
		table.insert(seq, "wave")
	end
	table.insert(seq, if text:find("%?%s*$") then "shrug" else "explain")
	return seq, "rest"
end

--------------------------------------------------------------------------------
-- Camera
--------------------------------------------------------------------------------

--- Their eyes: a little above the middle of the head, toward the face.
local function eyesOf(model: Model): Vector3?
	local head = model:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return (head.CFrame * CFrame.new(0, head.Size.Y * 0.08, -head.Size.Z * 0.3)).Position
	end
	return nil
end

-- Runs right after the default camera each frame, from its result: the eye
-- stays where it put it (in the head), only the direction is taken over. The
-- default camera reads its own CFrame back next frame, so when this lets go,
-- the view carries on from wherever the conversation left it.
local function bindCamera()
	camRot = nil
	RunService:BindToRenderStep(CAMERA_RENDER, Enum.RenderPriority.Camera.Value + 1, function(dt: number)
		local cam = Workspace.CurrentCamera
		if not cam or cam.CameraType == Enum.CameraType.Scriptable or not npcModel then
			return -- a cutscene owns it
		end
		local target = eyesOf(npcModel)
		if not target then
			return
		end
		local eye = cam.CFrame.Position
		local goal = CFrame.lookAt(eye, target).Rotation
		local from = camRot or cam.CFrame.Rotation
		camRot = from:Lerp(goal, 1 - math.exp(-CAM_EASE * dt))
		cam.CFrame = CFrame.new(eye) * (camRot :: CFrame)
	end)
end

local function unbindCamera()
	pcall(function()
		RunService:UnbindFromRenderStep(CAMERA_RENDER)
	end)
	camRot = nil
end

--------------------------------------------------------------------------------
-- Open / close
--------------------------------------------------------------------------------

local function findNpcModel(id: string): Model?
	local npcs = Workspace:FindFirstChild("NPCs")
	local m = npcs and npcs:FindFirstChild(id)
	return if m and m:IsA("Model") then m else nil
end

local function close(tellServer: boolean)
	if not active then
		return
	end
	if tellServer and npcId then
		NPCDialogueChoice:FireServer({ npcId = npcId, responseId = nil })
	end
	active = false
	if typing then
		task.cancel(typing)
		typing = nil
	end
	clearOptions()
	if watchConn then
		watchConn:Disconnect()
		watchConn = nil
	end
	ContextActionService:UnbindAction(KEYS_ACTION)
	unbindCamera()
	holdStill(false)
	if npcModel then
		Gestures.finish(npcModel)
	end
	npcModel = nil
	npcId = nil
	local fade = TweenService:Create(lineLabel, TweenInfo.new(0.2), { TextTransparency = 1, TextStrokeTransparency = 1 })
	TweenService:Create(nameLabel, TweenInfo.new(0.2), { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	TweenService:Create(shade, TweenInfo.new(0.25), { BackgroundTransparency = 1 }):Play()
	fade:Play()
	fade.Completed:Once(function()
		if not active then
			gui.Enabled = false
		end
	end)
end

choose = function(i: number)
	local o = options[i]
	if not (active and choosing and o and npcId) then
		return
	end
	choosing = false
	NPCDialogueChoice:FireServer({ npcId = npcId, responseId = o.responseId })
	if not o.responseId then
		close(false)
		return
	end
	-- the next node arrives from the server; until then the reply stays lit
	for j, b in optionButtons do
		if j ~= i then
			TweenService:Create(b, TweenInfo.new(0.15), { TextTransparency = 1 }):Play()
		else
			setHot(b, j, true)
		end
	end
end

local function onKey(_: string, state: Enum.UserInputState, input: InputObject): Enum.ContextActionResult
	if state ~= Enum.UserInputState.Begin or not active then
		return Enum.ContextActionResult.Pass
	end
	local n = NUMBER_KEYS[input.KeyCode]
	if typing then
		if n or input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.Return then
			finishLine()
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end
	if n then
		choose(n)
		return Enum.ContextActionResult.Sink
	end
	return Enum.ContextActionResult.Pass
end

local function bindKeys()
	local keys: { Enum.KeyCode } = { Enum.KeyCode.Space, Enum.KeyCode.Return }
	for k in NUMBER_KEYS do
		table.insert(keys, k)
	end
	ContextActionService:BindActionAtPriority(KEYS_ACTION, onKey, false, Enum.ContextActionPriority.High.Value + 50, table.unpack(keys))
end

local function open(data: any)
	local id = data.npcId :: string
	if active and npcId ~= id then
		close(true)
	end
	local first = not active
	active = true
	npcId = id
	npcModel = findNpcModel(id)
	options = {}
	for _, o in (data.options or {}) :: { any } do
		table.insert(options, { text = tostring(o.text), responseId = o.responseId })
	end

	local c = data.nameColor :: { number }?
	nameLabel.TextColor3 = if c then Color3.new(c[1], c[2], c[3]) else TEXT
	nameLabel.Text = tostring(data.displayName or "")

	if first then
		gui.Enabled = true
		nameLabel.TextTransparency = 0
		nameLabel.TextStrokeTransparency = 0.75
		lineLabel.TextTransparency = 0
		lineLabel.TextStrokeTransparency = 0.6
		shade.BackgroundTransparency = 1
		TweenService:Create(shade, TweenInfo.new(0.3), { BackgroundTransparency = 0 }):Play()
		holdStill(true)
		bindCamera()
		bindKeys()
		watchConn = RunService.Heartbeat:Connect(function()
			local char = player.Character
			local me = char and char:FindFirstChild("HumanoidRootPart")
			local them = npcModel and npcModel.Parent and npcModel:FindFirstChild("HumanoidRootPart")
			local ok = me and them and me:IsA("BasePart") and them:IsA("BasePart")
			if not ok or ((me :: BasePart).Position - (them :: BasePart).Position).Magnitude > MAX_TALK_DISTANCE then
				close(true)
			end
		end)
	end

	local text = tostring(data.text or "")
	sayLine(text)
	if npcModel then
		local seq, listen = gesturesFor(id, data.dialogueNodeId, text)
		local plain = text:gsub("%*.-%*", "")
		local laugh = text:lower():find("laugh") ~= nil or text:find("Ha%. Ha") ~= nil or text:find("^Heh") ~= nil
		Gestures.say(npcModel, seq, #plain / CHARS_PER_SEC, listen, laugh)
	end
end

-- a click anywhere off the replies finishes the line
UserInputService.InputBegan:Connect(function(input: InputObject)
	if active and typing and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then
		finishLine()
	end
end)

NPCDialogueTrigger.OnClientEvent:Connect(function(data: any)
	if typeof(data) == "table" and typeof(data.npcId) == "string" then
		open(data)
	end
end)

player.CharacterAdded:Connect(function()
	close(true)
end)
