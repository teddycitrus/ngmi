--!strict
--------------------------------------------------------------------------------
-- NPCDialogue.client.luau
-- Client-side NPC dialogue UI for Not Gonna Make It.
--
-- Responsibilities:
--   • Listen for NPCDialogueTrigger from server
--   • Display dialogue ScreenGui with typewriter text effect
--   • Show response options as styled buttons
--   • Lock player movement during dialogue
--   • Fire NPCDialogueChoice back to server on response selection
--   • Mobile-friendly: 44px+ touch targets
--------------------------------------------------------------------------------

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

-- Remotes
local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local NPCDialogueTrigger = Remotes:WaitForChild("NPCDialogueTrigger") :: RemoteEvent
local NPCDialogueChoice = Remotes:WaitForChild("NPCDialogueChoice") :: RemoteEvent

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui") :: PlayerGui

local CursorManager = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CursorManager"))

--------------------------------------------------------------------------------
-- Constants
--------------------------------------------------------------------------------

local TYPEWRITER_CHARS_PER_SEC = 30
local DIALOGUE_BOX_CORNER_RADIUS = 12
local BUTTON_CORNER_RADIUS = 8
local MIN_TOUCH_TARGET_PX = 44 -- minimum touch target for mobile accessibility
local FADE_DURATION = 0.25 -- seconds for GUI fade in/out

-- Colors
local BG_OVERLAY_COLOR = Color3.new(0, 0, 0)
local BG_OVERLAY_TRANSPARENCY = 0.5
local DIALOGUE_BG_COLOR = Color3.fromRGB(25, 25, 35)
local DIALOGUE_BG_TRANSPARENCY = 0.08
local TEXT_COLOR = Color3.fromRGB(230, 230, 230)
local BUTTON_BG_COLOR = Color3.fromRGB(40, 40, 55)
local BUTTON_HOVER_COLOR = Color3.fromRGB(60, 60, 80)
local BUTTON_TEXT_COLOR = Color3.fromRGB(200, 200, 200)
local CLOSE_BUTTON_COLOR = Color3.fromRGB(180, 50, 50)

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local currentGui: ScreenGui? = nil
local typewriterThread: thread? = nil
local isDialogueActive = false
local currentNpcId: string? = nil
local distanceConn: RBXScriptConnection? = nil
-- Whether we currently hold a CursorManager free-cursor for this conversation.
-- Tracked so an in-place dialogue refresh (same NPC, next node) doesn't double-push.
local cursorHeld = false

-- The player can walk around during a conversation; wander past this and it
-- breaks off on its own (the server makes the NPC turn and walk away).
local MAX_TALK_DISTANCE = 22

--------------------------------------------------------------------------------
-- NPC lookup
-- NPCManager parents the live NPC models under workspace.NPCs, each named after
-- its npc id, so we can find the one we're talking to for the distance check.
--------------------------------------------------------------------------------

local function findNpcModel(npcId: string): Model?
	local npcs = Workspace:FindFirstChild("NPCs")
	if not npcs then
		return nil
	end
	local m = npcs:FindFirstChild(npcId)
	if m and m:IsA("Model") then
		return m
	end
	return nil
end

--- Tell the server the conversation has ended (NPC turns and walks away).
local function notifyEnd()
	if currentNpcId then
		NPCDialogueChoice:FireServer({ npcId = currentNpcId, responseId = nil })
	end
end

--------------------------------------------------------------------------------
-- Typewriter Effect
-- Reveals text character by character at TYPEWRITER_CHARS_PER_SEC.
-- Returns the thread so it can be cancelled if player skips.
--------------------------------------------------------------------------------

local function startTypewriter(label: TextLabel, fullText: string, onComplete: (() -> ())?)
	-- Cancel any existing typewriter
	if typewriterThread then
		task.cancel(typewriterThread)
		typewriterThread = nil
	end

	label.Text = ""

	typewriterThread = task.spawn(function()
		local delay = 1.0 / TYPEWRITER_CHARS_PER_SEC
		for i = 1, #fullText do
			label.Text = string.sub(fullText, 1, i)
			task.wait(delay)
		end
		typewriterThread = nil
		if onComplete then
			onComplete()
		end
	end)
end

local function skipTypewriter(label: TextLabel, fullText: string)
	if typewriterThread then
		task.cancel(typewriterThread)
		typewriterThread = nil
	end
	label.Text = fullText
end

--------------------------------------------------------------------------------
-- GUI Construction
--------------------------------------------------------------------------------

local function createDialogueGui(data: any): ScreenGui
	local npcName = data.displayName :: string
	local nameColorData = data.nameColor :: { number }
	local nameColor = Color3.new(nameColorData[1], nameColorData[2], nameColorData[3])
	local dialogueText = data.text :: string
	local options = data.options :: { any }
	local npcId = data.npcId :: string

	-- ScreenGui
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "NPCDialogueGui"
	screenGui.ResetOnSpawn = false
	screenGui.DisplayOrder = 100
	screenGui.IgnoreGuiInset = true
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	-- Background overlay (dark semi-transparent)
	local overlay = Instance.new("Frame")
	overlay.Name = "Overlay"
	overlay.Size = UDim2.new(1, 0, 1, 0)
	overlay.Position = UDim2.new(0, 0, 0, 0)
	overlay.BackgroundColor3 = BG_OVERLAY_COLOR
	overlay.BackgroundTransparency = 1 -- will fade in
	overlay.BorderSizePixel = 0
	overlay.Parent = screenGui

	-- Dialogue box at bottom of screen
	local dialogueFrame = Instance.new("Frame")
	dialogueFrame.Name = "DialogueFrame"
	dialogueFrame.Size = UDim2.new(0.85, 0, 0, 0) -- height will be set dynamically
	dialogueFrame.Position = UDim2.new(0.075, 0, 1, 0) -- starts offscreen, will slide up
	dialogueFrame.AnchorPoint = Vector2.new(0, 1)
	dialogueFrame.BackgroundColor3 = DIALOGUE_BG_COLOR
	dialogueFrame.BackgroundTransparency = DIALOGUE_BG_TRANSPARENCY
	dialogueFrame.BorderSizePixel = 0
	dialogueFrame.ClipsDescendants = true
	dialogueFrame.Parent = screenGui

	-- Rounded corners
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, DIALOGUE_BOX_CORNER_RADIUS)
	corner.Parent = dialogueFrame

	-- Subtle border stroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(80, 80, 100)
	stroke.Thickness = 1.5
	stroke.Transparency = 0.5
	stroke.Parent = dialogueFrame

	-- Padding inside dialogue frame
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 16)
	padding.PaddingBottom = UDim.new(0, 16)
	padding.PaddingLeft = UDim.new(0, 20)
	padding.PaddingRight = UDim.new(0, 20)
	padding.Parent = dialogueFrame

	-- Layout for vertical stacking
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Vertical
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 10)
	layout.Parent = dialogueFrame

	-- NPC Name label
	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "NPCName"
	nameLabel.Size = UDim2.new(1, 0, 0, 28)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = npcName
	nameLabel.TextColor3 = nameColor
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextSize = 22
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.LayoutOrder = 1
	nameLabel.Parent = dialogueFrame

	-- Dialogue text label (typewriter target)
	local textLabel = Instance.new("TextLabel")
	textLabel.Name = "DialogueText"
	textLabel.Size = UDim2.new(1, 0, 0, 80)
	textLabel.BackgroundTransparency = 1
	textLabel.Text = ""
	textLabel.TextColor3 = TEXT_COLOR
	textLabel.Font = Enum.Font.Gotham
	textLabel.TextSize = 18
	textLabel.TextXAlignment = Enum.TextXAlignment.Left
	textLabel.TextYAlignment = Enum.TextYAlignment.Top
	textLabel.TextWrapped = true
	textLabel.LayoutOrder = 2
	textLabel.AutomaticSize = Enum.AutomaticSize.Y
	textLabel.Parent = dialogueFrame

	-- Response buttons container
	local buttonContainer = Instance.new("Frame")
	buttonContainer.Name = "ResponseButtons"
	buttonContainer.Size = UDim2.new(1, 0, 0, 0) -- auto-sized
	buttonContainer.BackgroundTransparency = 1
	buttonContainer.LayoutOrder = 3
	buttonContainer.AutomaticSize = Enum.AutomaticSize.Y
	buttonContainer.Parent = dialogueFrame

	local buttonLayout = Instance.new("UIListLayout")
	buttonLayout.FillDirection = Enum.FillDirection.Vertical
	buttonLayout.SortOrder = Enum.SortOrder.LayoutOrder
	buttonLayout.Padding = UDim.new(0, 8)
	buttonLayout.Parent = buttonContainer

	-- Create response buttons (initially hidden, shown after typewriter finishes)
	local responseButtons: { TextButton } = {}

	for i, option in options do
		local optionData = option :: any
		local btn = Instance.new("TextButton")
		btn.Name = "Response_" .. tostring(i)
		btn.Size = UDim2.new(1, 0, 0, math.max(MIN_TOUCH_TARGET_PX, 44))
		btn.BackgroundColor3 = BUTTON_BG_COLOR
		btn.Text = "  " .. (optionData.text :: string)
		btn.TextColor3 = BUTTON_TEXT_COLOR
		btn.Font = Enum.Font.Gotham
		btn.TextSize = 16
		btn.TextXAlignment = Enum.TextXAlignment.Left
		btn.TextWrapped = true
		btn.AutomaticSize = Enum.AutomaticSize.Y
		btn.LayoutOrder = i
		btn.Modal = true -- frees the mouse cursor even in first person, so options are clickable
		btn.BackgroundTransparency = 1 -- hidden initially
		btn.TextTransparency = 1
		btn.Parent = buttonContainer

		local btnCorner = Instance.new("UICorner")
		btnCorner.CornerRadius = UDim.new(0, BUTTON_CORNER_RADIUS)
		btnCorner.Parent = btn

		local btnPadding = Instance.new("UIPadding")
		btnPadding.PaddingTop = UDim.new(0, 10)
		btnPadding.PaddingBottom = UDim.new(0, 10)
		btnPadding.PaddingLeft = UDim.new(0, 12)
		btnPadding.PaddingRight = UDim.new(0, 12)
		btnPadding.Parent = btn

		local btnStroke = Instance.new("UIStroke")
		btnStroke.Color = Color3.fromRGB(70, 70, 90)
		btnStroke.Thickness = 1
		btnStroke.Transparency = 0.6
		btnStroke.Parent = btn

		-- Hover effect
		btn.MouseEnter:Connect(function()
			TweenService:Create(btn, TweenInfo.new(0.15), {
				BackgroundColor3 = BUTTON_HOVER_COLOR,
			}):Play()
		end)
		btn.MouseLeave:Connect(function()
			TweenService:Create(btn, TweenInfo.new(0.15), {
				BackgroundColor3 = BUTTON_BG_COLOR,
			}):Play()
		end)

		-- Click handler
		btn.Activated:Connect(function()
			local responseId = optionData.responseId -- may be nil (end dialogue)

			-- Fire choice to server
			NPCDialogueChoice:FireServer({
				npcId = npcId,
				responseId = responseId,
			})

			-- If responseId is nil, this ends the dialogue
			if not responseId then
				closeDialogue()
			end
			-- Otherwise, server will send next dialogue node via NPCDialogueTrigger
		end)

		table.insert(responseButtons, btn)
	end

	-- Close button (X) in top-right corner of dialogue frame
	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseButton"
	closeBtn.Size = UDim2.new(0, 36, 0, 36)
	closeBtn.Position = UDim2.new(1, 4, 0, -16)
	closeBtn.AnchorPoint = Vector2.new(1, 0)
	closeBtn.BackgroundColor3 = CLOSE_BUTTON_COLOR
	closeBtn.BackgroundTransparency = 0.3
	closeBtn.Text = "✕"
	closeBtn.TextColor3 = Color3.new(1, 1, 1)
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.TextSize = 18
	closeBtn.Modal = true
	closeBtn.LayoutOrder = -1 -- don't participate in layout, use absolute position
	closeBtn.Parent = dialogueFrame

	-- Remove from layout by making it not affected by UIListLayout
	closeBtn.AnchorPoint = Vector2.new(1, 0)

	local closeBtnCorner = Instance.new("UICorner")
	closeBtnCorner.CornerRadius = UDim.new(0, 18)
	closeBtnCorner.Parent = closeBtn

	closeBtn.Activated:Connect(function()
		NPCDialogueChoice:FireServer({
			npcId = npcId,
			responseId = nil, -- end dialogue
		})
		closeDialogue()
	end)

	-- Auto-size the dialogue frame based on content
	dialogueFrame.AutomaticSize = Enum.AutomaticSize.Y

	-- Store references for typewriter + button reveal
	screenGui:SetAttribute("FullText", dialogueText)
	screenGui:SetAttribute("NpcId", npcId)

	-- Animate in
	task.spawn(function()
		-- Fade overlay in
		TweenService:Create(overlay, TweenInfo.new(FADE_DURATION), {
			BackgroundTransparency = BG_OVERLAY_TRANSPARENCY,
		}):Play()

		-- Slide dialogue frame up from bottom
		dialogueFrame.Position = UDim2.new(0.075, 0, 1, 20) -- start below screen
		TweenService:Create(dialogueFrame, TweenInfo.new(FADE_DURATION, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Position = UDim2.new(0.075, 0, 1, -30), -- 30px from bottom
		}):Play()

		task.wait(FADE_DURATION)

		-- Start typewriter effect
		startTypewriter(textLabel, dialogueText, function()
			-- Reveal response buttons after text is done
			for idx, btn in responseButtons do
				task.wait(0.08) -- stagger button appearance
				TweenService:Create(btn, TweenInfo.new(0.2), {
					BackgroundTransparency = 0.1,
					TextTransparency = 0,
				}):Play()
			end
		end)
	end)

	-- Allow clicking dialogue text to skip typewriter
	textLabel.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			skipTypewriter(textLabel, dialogueText)
			-- Reveal buttons immediately
			for _, btn in responseButtons do
				btn.BackgroundTransparency = 0.1
				btn.TextTransparency = 0
			end
		end
	end)

	-- Also skip on any keyboard press
	local skipConnection: RBXScriptConnection? = nil
	skipConnection = UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed then return end
		if input.UserInputType == Enum.UserInputType.Keyboard then
			if typewriterThread then
				skipTypewriter(textLabel, dialogueText)
				for _, btn in responseButtons do
					btn.BackgroundTransparency = 0.1
					btn.TextTransparency = 0
				end
			end
		end
	end)

	-- Store cleanup connection
	screenGui.Destroying:Connect(function()
		if skipConnection then
			skipConnection:Disconnect()
			skipConnection = nil
		end
	end)

	return screenGui
end

--------------------------------------------------------------------------------
-- Open / Close Dialogue
--------------------------------------------------------------------------------

function closeDialogue()
	if not isDialogueActive then return end
	isDialogueActive = false

	-- Cancel typewriter
	if typewriterThread then
		task.cancel(typewriterThread)
		typewriterThread = nil
	end

	-- Stop watching the player↔NPC distance
	if distanceConn then
		distanceConn:Disconnect()
		distanceConn = nil
	end
	currentNpcId = nil

	-- Restore the first-person mouse-lock the game normally uses
	if cursorHeld then
		CursorManager.pop()
		cursorHeld = false
	end

	-- Fade out and destroy
	if currentGui then
		local gui = currentGui
		local overlay = gui:FindFirstChild("Overlay") :: Frame?
		local dialogueFrame = gui:FindFirstChild("DialogueFrame") :: Frame?

		-- Animate out
		if overlay then
			TweenService:Create(overlay, TweenInfo.new(FADE_DURATION), {
				BackgroundTransparency = 1,
			}):Play()
		end
		if dialogueFrame then
			TweenService:Create(dialogueFrame, TweenInfo.new(FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Position = UDim2.new(0.075, 0, 1, 20),
			}):Play()
		end

		task.delay(FADE_DURATION + 0.05, function()
			if gui and gui.Parent then
				gui:Destroy()
			end
		end)

		currentGui = nil
	end
end

local function openDialogue(data: any)
	-- Close existing dialogue if any
	if isDialogueActive then
		-- If same NPC, update in place (next dialogue node)
		if currentGui and currentGui:GetAttribute("NpcId") == data.npcId then
			-- Destroy old GUI and create new one with updated dialogue
			if currentGui then
				currentGui:Destroy()
				currentGui = nil
			end
		else
			closeDialogue()
			task.wait(FADE_DURATION + 0.1) -- wait for close animation
		end
	end

	isDialogueActive = true
	currentNpcId = data.npcId

	-- Free the mouse cursor so the player can click the response options. Guarded so
	-- an in-place refresh (same NPC, next dialogue node) doesn't push a second time.
	if not cursorHeld then
		CursorManager.push()
		cursorHeld = true
	end

	-- Create and show dialogue GUI
	currentGui = createDialogueGui(data)
	currentGui.Parent = playerGui

	-- Watch the distance to this NPC: the player keeps full movement, but if they
	-- wander too far the conversation ends on its own (server walks the NPC off).
	if distanceConn then
		distanceConn:Disconnect()
		distanceConn = nil
	end
	local npcModel = findNpcModel(data.npcId)
	distanceConn = RunService.Heartbeat:Connect(function()
		if not isDialogueActive then
			return
		end
		local character = player.Character
		local phrp = character and character:FindFirstChild("HumanoidRootPart")
		local nroot = npcModel and npcModel.Parent and npcModel:FindFirstChild("HumanoidRootPart")
		if not phrp or not nroot then
			closeDialogue()
			return
		end
		if ((phrp :: BasePart).Position - (nroot :: BasePart).Position).Magnitude > MAX_TALK_DISTANCE then
			notifyEnd()
			closeDialogue()
		end
	end)
end

--------------------------------------------------------------------------------
-- Remote Event Listener
--------------------------------------------------------------------------------

NPCDialogueTrigger.OnClientEvent:Connect(function(data: any)
	if typeof(data) ~= "table" then return end
	openDialogue(data)
end)

--------------------------------------------------------------------------------
-- Cleanup on character respawn (close dialogue if active)
--------------------------------------------------------------------------------

player.CharacterAdded:Connect(function(_character: Model)
	if isDialogueActive then
		closeDialogue()
	end
end)

print("[NPCDialogue] Client dialogue UI system initialized")
