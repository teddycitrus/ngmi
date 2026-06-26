--!strict
--[[
	LobbyUI.client.luau
	LocalScript — Full-screen lobby interface for Code Red
	
	Creates a premium, horror-themed lobby menu entirely via code:
	  • Glitchy red title with pulsing animation
	  • Typing-animation subtitle
	  • Three "hackathon team card" queue buttons with live counts
	  • Leave Queue button when actively queued
	  • Matchmaking status bar (searching → match found → countdown)
	  • Animated dark background with pulsing red vignette
	  • Responsive UDim2 sizing for desktop & mobile
	  • Hover effects via MouseEnter / MouseLeave
	
	Communicates with LobbyManager via:
	  PlayerJoinedLobby (client → server)
	  QueueUpdate       (server → client)
	  MatchFound        (server → client)
	  StartGame         (server → client)
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

--------------------------------------------------------------------------------
-- Remote Events
--------------------------------------------------------------------------------

local Remotes = ReplicatedStorage:WaitForChild("Remotes")
local PlayerJoinedLobbyRemote = Remotes:WaitForChild("PlayerJoinedLobby") :: RemoteEvent
local QueueUpdateRemote       = Remotes:WaitForChild("QueueUpdate") :: RemoteEvent
local MatchFoundRemote        = Remotes:WaitForChild("MatchFound") :: RemoteEvent
local StartGameRemote         = Remotes:WaitForChild("StartGame") :: RemoteEvent
local GameStateChangedRemote  = Remotes:WaitForChild("GameStateChanged") :: RemoteEvent

--------------------------------------------------------------------------------
-- Color Palette & Style Constants
--------------------------------------------------------------------------------

local COLORS = {
	background     = Color3.fromRGB(10, 10, 14),
	cardBackground = Color3.fromRGB(22, 22, 30),
	cardHover      = Color3.fromRGB(34, 28, 36),
	cardBorder     = Color3.fromRGB(60, 20, 25),
	redAccent      = Color3.fromRGB(200, 30, 40),
	redGlow        = Color3.fromRGB(255, 50, 60),
	redDark        = Color3.fromRGB(120, 15, 20),
	white          = Color3.fromRGB(230, 230, 230),
	dimText        = Color3.fromRGB(140, 140, 150),
	green          = Color3.fromRGB(50, 200, 80),
	yellow         = Color3.fromRGB(220, 200, 50),
	leaveRed       = Color3.fromRGB(150, 30, 35),
}

local FONT_TITLE = Font.fromEnum(Enum.Font.GothamBold)
local FONT_BODY  = Font.fromEnum(Enum.Font.Gotham)
local FONT_MONO  = Font.fromEnum(Enum.Font.Code)

local CORNER_RADIUS = UDim.new(0, 10)
local CARD_CORNER   = UDim.new(0, 12)

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

local currentQueue: number? = nil      -- Which queue we're in (1, 2, 4) or nil
local isMatchFound: boolean = false
local queueCounts: { [number]: number } = { [1] = 0, [2] = 0, [4] = 0 }

-- References to UI elements we need to update
local queueCountLabels: { [number]: TextLabel } = {}
local queueButtons: { [number]: TextButton } = {}
local statusLabel: TextLabel = nil :: any
local leaveButton: TextButton = nil :: any
local lobbyGui: ScreenGui = nil :: any

--------------------------------------------------------------------------------
-- UI Construction Helpers
--------------------------------------------------------------------------------

--[[
	Shorthand to add UICorner with specified radius.
]]
local function addCorner(parent: GuiObject, radius: UDim?): UICorner
	local corner = Instance.new("UICorner")
	corner.CornerRadius = radius or CORNER_RADIUS
	corner.Parent = parent
	return corner
end

--[[
	Shorthand to add UIStroke (border glow).
]]
local function addStroke(parent: GuiObject, color: Color3, thickness: number?, transparency: number?): UIStroke
	local stroke = Instance.new("UIStroke")
	stroke.Color = color
	stroke.Thickness = thickness or 1
	stroke.Transparency = transparency or 0.5
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = parent
	return stroke
end

--[[
	Shorthand to add UIPadding.
]]
local function addPadding(parent: GuiObject, top: number, right: number, bottom: number, left: number): UIPadding
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, top)
	padding.PaddingRight = UDim.new(0, right)
	padding.PaddingBottom = UDim.new(0, bottom)
	padding.PaddingLeft = UDim.new(0, left)
	padding.Parent = parent
	return padding
end

--------------------------------------------------------------------------------
-- Build the Lobby GUI
--------------------------------------------------------------------------------

local function buildLobbyGui(): ScreenGui
	-- ── ScreenGui ───────────────────────────────────────────────────────
	local screenGui = Instance.new("ScreenGui")
	screenGui.Name = "LobbyGui"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.DisplayOrder = 100
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	-- ── Background ──────────────────────────────────────────────────────
	local bg = Instance.new("Frame")
	bg.Name = "Background"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = COLORS.background
	bg.BorderSizePixel = 0
	bg.Parent = screenGui

	-- Pulsing red vignette overlay
	local vignette = Instance.new("ImageLabel")
	vignette.Name = "Vignette"
	vignette.Size = UDim2.fromScale(1, 1)
	vignette.BackgroundTransparency = 1
	vignette.Image = "rbxassetid://1166862856" -- radial gradient
	vignette.ImageColor3 = COLORS.redAccent
	vignette.ImageTransparency = 0.85
	vignette.ScaleType = Enum.ScaleType.Stretch
	vignette.ZIndex = 1
	vignette.Parent = bg

	-- Animate vignette pulse
	task.spawn(function()
		while vignette and vignette.Parent do
			local tweenIn = TweenService:Create(vignette, TweenInfo.new(2.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
				ImageTransparency = 0.7,
			})
			tweenIn:Play()
			tweenIn.Completed:Wait()

			local tweenOut = TweenService:Create(vignette, TweenInfo.new(2.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
				ImageTransparency = 0.9,
			})
			tweenOut:Play()
			tweenOut.Completed:Wait()
		end
	end)

	-- ── Content Container ───────────────────────────────────────────────
	local content = Instance.new("Frame")
	content.Name = "Content"
	content.Size = UDim2.fromScale(1, 1)
	content.BackgroundTransparency = 1
	content.ZIndex = 2
	content.Parent = bg

	-- ── Title ───────────────────────────────────────────────────────────
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(0.9, 0, 0, 60)
	title.Position = UDim2.new(0.05, 0, 0.06, 0)
	title.BackgroundTransparency = 1
	title.RichText = true
	title.Text = '<font color="#CC1E28"><b>not gonna make it</b></font>'
	title.FontFace = FONT_TITLE
	title.TextScaled = true
	title.TextColor3 = COLORS.white
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.ZIndex = 3
	title.Parent = content

	-- Glitch animation on title — periodically shift color/offset
	task.spawn(function()
		while title and title.Parent do
			task.wait(3 + math.random() * 4)
			-- Quick glitch burst
			for _ = 1, 3 do
				title.Position = UDim2.new(0.05 + (math.random() - 0.5) * 0.01, 0, 0.06 + (math.random() - 0.5) * 0.005, 0)
				title.TextColor3 = Color3.fromRGB(255, math.random(20, 60), math.random(40, 80))
				task.wait(0.05)
			end
			title.Position = UDim2.new(0.05, 0, 0.06, 0)
			title.TextColor3 = COLORS.white
		end
	end)

	-- ── Subtitle with typing animation ──────────────────────────────────
	local subtitle = Instance.new("TextLabel")
	subtitle.Name = "Subtitle"
	subtitle.Size = UDim2.new(0.8, 0, 0, 28)
	subtitle.Position = UDim2.new(0.1, 0, 0.14, 0)
	subtitle.BackgroundTransparency = 1
	subtitle.Text = ""
	subtitle.FontFace = FONT_MONO
	subtitle.TextSize = 20
	subtitle.TextColor3 = COLORS.dimText
	subtitle.TextXAlignment = Enum.TextXAlignment.Center
	subtitle.ZIndex = 3
	subtitle.Parent = content

	-- Type out the subtitle text
	task.spawn(function()
		task.wait(0.8) -- Slight delay after GUI appears
		local fullText = "> A 48-Hour Nightmare_"
		for i = 1, #fullText do
			if not subtitle or not subtitle.Parent then
				break
			end
			subtitle.Text = string.sub(fullText, 1, i)
			task.wait(0.06)
		end
		-- Blinking cursor
		while subtitle and subtitle.Parent do
			subtitle.Text = "> A 48-Hour Nightmare_"
			task.wait(0.5)
			subtitle.Text = "> A 48-Hour Nightmare "
			task.wait(0.5)
		end
	end)

	-- ── Queue Cards Container ───────────────────────────────────────────
	local cardsFrame = Instance.new("Frame")
	cardsFrame.Name = "QueueCards"
	cardsFrame.Size = UDim2.new(0.88, 0, 0.45, 0)
	cardsFrame.Position = UDim2.new(0.06, 0, 0.22, 0)
	cardsFrame.BackgroundTransparency = 1
	cardsFrame.ZIndex = 3
	cardsFrame.Parent = content

	local cardsLayout = Instance.new("UIListLayout")
	cardsLayout.FillDirection = Enum.FillDirection.Horizontal
	cardsLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	cardsLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	cardsLayout.Padding = UDim.new(0, 18)
	cardsLayout.Parent = cardsFrame

	-- Card data
	local cardDefs = {
		{
			queueSize = 1,
			title = "SOLO HACKER",
			icon = "💻",
			desc = "Go it alone.\nOne keyboard.\nNo backup.",
			accent = COLORS.green,
		},
		{
			queueSize = 2,
			title = "DUO DEBUGGING",
			icon = "👥",
			desc = "Pair programming\nunder pressure.\nTrust no one.",
			accent = COLORS.yellow,
		},
		{
			queueSize = 4,
			title = "FULL STACK TEAM",
			icon = "🏢",
			desc = "Full squad.\nFull chaos.\nFull horror.",
			accent = COLORS.redAccent,
		},
	}

	for _, def in cardDefs do
		local card = Instance.new("TextButton")
		card.Name = "Card_" .. def.queueSize
		card.Size = UDim2.new(0.3, 0, 0.92, 0)
		card.BackgroundColor3 = COLORS.cardBackground
		card.AutoButtonColor = false
		card.BorderSizePixel = 0
		card.Text = "" -- We'll build content manually inside
		card.ZIndex = 4
		card.Parent = cardsFrame

		addCorner(card, CARD_CORNER)
		local cardStroke = addStroke(card, def.accent, 1.5, 0.6)
		addPadding(card, 16, 16, 16, 16)

		-- Icon
		local iconLabel = Instance.new("TextLabel")
		iconLabel.Name = "Icon"
		iconLabel.Size = UDim2.new(1, 0, 0, 44)
		iconLabel.Position = UDim2.fromOffset(0, 6)
		iconLabel.BackgroundTransparency = 1
		iconLabel.Text = def.icon
		iconLabel.TextSize = 38
		iconLabel.FontFace = FONT_BODY
		iconLabel.TextColor3 = COLORS.white
		iconLabel.ZIndex = 5
		iconLabel.Parent = card

		-- Title
		local cardTitle = Instance.new("TextLabel")
		cardTitle.Name = "CardTitle"
		cardTitle.Size = UDim2.new(1, 0, 0, 26)
		cardTitle.Position = UDim2.new(0, 0, 0, 56)
		cardTitle.BackgroundTransparency = 1
		cardTitle.Text = def.title
		cardTitle.FontFace = FONT_TITLE
		cardTitle.TextSize = 20
		cardTitle.TextColor3 = def.accent
		cardTitle.ZIndex = 5
		cardTitle.Parent = card

		-- Description
		local cardDesc = Instance.new("TextLabel")
		cardDesc.Name = "Description"
		cardDesc.Size = UDim2.new(1, 0, 0, 60)
		cardDesc.Position = UDim2.new(0, 0, 0, 88)
		cardDesc.BackgroundTransparency = 1
		cardDesc.Text = def.desc
		cardDesc.FontFace = FONT_MONO
		cardDesc.TextSize = 13
		cardDesc.TextColor3 = COLORS.dimText
		cardDesc.TextWrapped = true
		cardDesc.ZIndex = 5
		cardDesc.Parent = card

		-- Queue count label (e.g., "0/4 in queue")
		local countLabel = Instance.new("TextLabel")
		countLabel.Name = "QueueCount"
		countLabel.Size = UDim2.new(1, 0, 0, 22)
		countLabel.Position = UDim2.new(0, 0, 1, -52)
		countLabel.BackgroundTransparency = 1
		countLabel.Text = "0/" .. def.queueSize .. " in queue"
		countLabel.FontFace = FONT_MONO
		countLabel.TextSize = 14
		countLabel.TextColor3 = COLORS.dimText
		countLabel.ZIndex = 5
		countLabel.Parent = card

		-- "JOIN" indicator at the bottom of the card
		local joinIndicator = Instance.new("TextLabel")
		joinIndicator.Name = "JoinIndicator"
		joinIndicator.Size = UDim2.new(0.7, 0, 0, 30)
		joinIndicator.Position = UDim2.new(0.15, 0, 1, -34)
		joinIndicator.BackgroundColor3 = def.accent
		joinIndicator.BackgroundTransparency = 0.7
		joinIndicator.Text = "[ JOIN ]"
		joinIndicator.FontFace = FONT_TITLE
		joinIndicator.TextSize = 14
		joinIndicator.TextColor3 = COLORS.white
		joinIndicator.ZIndex = 5
		joinIndicator.Parent = card
		addCorner(joinIndicator, UDim.new(0, 6))

		-- Store references for later updates
		queueCountLabels[def.queueSize] = countLabel
		queueButtons[def.queueSize] = card

		-- ── Hover Effects ───────────────────────────────────────────────
		card.MouseEnter:Connect(function()
			TweenService:Create(card, TweenInfo.new(0.2), {
				BackgroundColor3 = COLORS.cardHover,
			}):Play()
			TweenService:Create(cardStroke, TweenInfo.new(0.2), {
				Transparency = 0.1,
			}):Play()
			TweenService:Create(joinIndicator, TweenInfo.new(0.2), {
				BackgroundTransparency = 0.3,
			}):Play()
		end)

		card.MouseLeave:Connect(function()
			TweenService:Create(card, TweenInfo.new(0.3), {
				BackgroundColor3 = COLORS.cardBackground,
			}):Play()
			TweenService:Create(cardStroke, TweenInfo.new(0.3), {
				Transparency = 0.6,
			}):Play()
			TweenService:Create(joinIndicator, TweenInfo.new(0.3), {
				BackgroundTransparency = 0.7,
			}):Play()
		end)

		-- ── Click → Join Queue ──────────────────────────────────────────
		card.Activated:Connect(function()
			if currentQueue ~= nil or isMatchFound then
				return -- Already queued or in a match
			end
			PlayerJoinedLobbyRemote:FireServer({
				action = "join",
				queueSize = def.queueSize,
			})
		end)
	end

	-- ── Status Section ──────────────────────────────────────────────────
	local statusFrame = Instance.new("Frame")
	statusFrame.Name = "StatusFrame"
	statusFrame.Size = UDim2.new(0.7, 0, 0, 40)
	statusFrame.Position = UDim2.new(0.15, 0, 0.72, 0)
	statusFrame.BackgroundColor3 = COLORS.cardBackground
	statusFrame.BackgroundTransparency = 0.3
	statusFrame.BorderSizePixel = 0
	statusFrame.ZIndex = 3
	statusFrame.Visible = false
	statusFrame.Parent = content
	addCorner(statusFrame)
	addStroke(statusFrame, COLORS.redAccent, 1, 0.7)

	local statusText = Instance.new("TextLabel")
	statusText.Name = "StatusText"
	statusText.Size = UDim2.fromScale(1, 1)
	statusText.BackgroundTransparency = 1
	statusText.Text = "Searching for players..."
	statusText.FontFace = FONT_MONO
	statusText.TextSize = 16
	statusText.TextColor3 = COLORS.dimText
	statusText.ZIndex = 4
	statusText.Parent = statusFrame

	statusLabel = statusText

	-- ── Leave Queue Button ──────────────────────────────────────────────
	local leaveBtn = Instance.new("TextButton")
	leaveBtn.Name = "LeaveQueue"
	leaveBtn.Size = UDim2.new(0.35, 0, 0, 38)
	leaveBtn.Position = UDim2.new(0.325, 0, 0.79, 0)
	leaveBtn.BackgroundColor3 = COLORS.leaveRed
	leaveBtn.BackgroundTransparency = 0.3
	leaveBtn.AutoButtonColor = false
	leaveBtn.Text = "✕  LEAVE QUEUE"
	leaveBtn.FontFace = FONT_TITLE
	leaveBtn.TextSize = 15
	leaveBtn.TextColor3 = COLORS.white
	leaveBtn.BorderSizePixel = 0
	leaveBtn.ZIndex = 3
	leaveBtn.Visible = false
	leaveBtn.Parent = content
	addCorner(leaveBtn)
	addStroke(leaveBtn, COLORS.redAccent, 1, 0.5)

	leaveBtn.MouseEnter:Connect(function()
		TweenService:Create(leaveBtn, TweenInfo.new(0.2), {
			BackgroundTransparency = 0,
		}):Play()
	end)
	leaveBtn.MouseLeave:Connect(function()
		TweenService:Create(leaveBtn, TweenInfo.new(0.3), {
			BackgroundTransparency = 0.3,
		}):Play()
	end)

	leaveBtn.Activated:Connect(function()
		if currentQueue == nil or isMatchFound then
			return
		end
		PlayerJoinedLobbyRemote:FireServer({ action = "leave" })
	end)

	leaveButton = leaveBtn

	-- ── Footer / version tag ────────────────────────────────────────────
	local footer = Instance.new("TextLabel")
	footer.Name = "Footer"
	footer.Size = UDim2.new(0.6, 0, 0, 18)
	footer.Position = UDim2.new(0.2, 0, 0.95, 0)
	footer.BackgroundTransparency = 1
	footer.Text = "v0.1.0 · ALPHA BUILD · © 2026"
	footer.FontFace = FONT_MONO
	footer.TextSize = 11
	footer.TextColor3 = Color3.fromRGB(60, 60, 70)
	footer.ZIndex = 3
	footer.Parent = content

	-- Store GUI reference
	lobbyGui = screenGui
	screenGui.Parent = PlayerGui

	return screenGui
end

--------------------------------------------------------------------------------
-- UI Update Functions
--------------------------------------------------------------------------------

--[[
	Refreshes the queue count labels on each card and the status section visibility.
]]
local function updateQueueDisplay(): ()
	for queueSize, label in queueCountLabels do
		label.Text = tostring(queueCounts[queueSize] or 0) .. "/" .. tostring(queueSize) .. " in queue"
	end

	-- Highlight the card the player is currently in
	for queueSize, button in queueButtons do
		if queueSize == currentQueue then
			-- Active card — brighter border
			local stroke = button:FindFirstChildOfClass("UIStroke")
			if stroke then
				stroke.Transparency = 0
				stroke.Thickness = 2.5
			end
			button.BackgroundColor3 = COLORS.cardHover
		else
			local stroke = button:FindFirstChildOfClass("UIStroke")
			if stroke then
				stroke.Transparency = 0.6
				stroke.Thickness = 1.5
			end
			button.BackgroundColor3 = COLORS.cardBackground
		end
	end
end

--[[
	Enters the "queued" UI state — show status bar and leave button.
]]
local function showQueuedState(queueSize: number): ()
	currentQueue = queueSize

	-- Show status section
	local statusFrame = statusLabel.Parent :: Frame
	statusFrame.Visible = true
	statusLabel.Text = "🔍 Searching for players... (" .. tostring(queueCounts[queueSize] or 1) .. "/" .. tostring(queueSize) .. ")"
	statusLabel.TextColor3 = COLORS.dimText

	-- Show leave button
	leaveButton.Visible = true

	updateQueueDisplay()
end

--[[
	Returns to the idle lobby state (not queued).
]]
local function showIdleState(): ()
	currentQueue = nil
	isMatchFound = false

	local statusFrame = statusLabel.Parent :: Frame
	statusFrame.Visible = false
	leaveButton.Visible = false

	updateQueueDisplay()
end

--[[
	Match found state — update status, hide leave button.
]]
local function showMatchFoundState(data: any): ()
	isMatchFound = true

	local statusFrame = statusLabel.Parent :: Frame
	statusFrame.Visible = true
	statusLabel.Text = "🎯  MATCH FOUND!"
	statusLabel.TextColor3 = COLORS.green

	leaveButton.Visible = false

	-- Flash the status frame
	local frame = statusLabel.Parent :: Frame
	TweenService:Create(frame, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 2, true), {
		BackgroundTransparency = 0,
	}):Play()

	updateQueueDisplay()
end

--[[
	Countdown tick — update status with remaining seconds.
]]
local function showCountdownState(remaining: number): ()
	statusLabel.Text = "⏱  Starting in " .. tostring(remaining) .. "..."
	statusLabel.TextColor3 = COLORS.yellow

	-- Pulse effect per tick
	TweenService:Create(statusLabel, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		TextSize = 20,
	}):Play()
	task.delay(0.15, function()
		if statusLabel and statusLabel.Parent then
			TweenService:Create(statusLabel, TweenInfo.new(0.15), {
				TextSize = 16,
			}):Play()
		end
	end)
end

--[[
	Hides the entire lobby GUI with a fade-out.
]]
local function hideLobby(): ()
	if not lobbyGui then
		return
	end

	local bg = lobbyGui:FindFirstChild("Background") :: Frame?
	if bg then
		-- Fade out
		TweenService:Create(bg, TweenInfo.new(1.0, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			BackgroundTransparency = 1,
		}):Play()

		-- Fade all children
		for _, child in bg:GetDescendants() do
			if child:IsA("TextLabel") or child:IsA("TextButton") then
				TweenService:Create(child, TweenInfo.new(0.8), {
					TextTransparency = 1,
					BackgroundTransparency = 1,
				}):Play()
			elseif child:IsA("Frame") then
				TweenService:Create(child, TweenInfo.new(0.8), {
					BackgroundTransparency = 1,
				}):Play()
			elseif child:IsA("ImageLabel") then
				TweenService:Create(child, TweenInfo.new(0.8), {
					ImageTransparency = 1,
				}):Play()
			end
		end

		task.delay(1.2, function()
			if lobbyGui then
				-- Destroy (not just disable): this stops the vignette/title/subtitle
				-- animation loops (they check .Parent) and guarantees nothing can
				-- re-enable the menu later (e.g. the opening cutscene restoring GUIs).
				lobbyGui:Destroy()
				lobbyGui = nil :: any
			end
		end)
	else
		lobbyGui:Destroy()
		lobbyGui = nil :: any
	end
end

--------------------------------------------------------------------------------
-- Server Event Handlers
--------------------------------------------------------------------------------

QueueUpdateRemote.OnClientEvent:Connect(function(payload: any)
	if typeof(payload) ~= "table" then
		return
	end

	local msgType = payload.type

	if msgType == "counts" then
		-- Periodic queue count broadcast
		local counts = payload.counts
		if typeof(counts) == "table" then
			for k, v in counts :: { [any]: any } do
				if typeof(k) == "number" and typeof(v) == "number" then
					queueCounts[k] = v
				end
			end
		end
		updateQueueDisplay()

		-- Update searching status if we're in a queue
		if currentQueue and not isMatchFound then
			statusLabel.Text = "🔍 Searching for players... (" 
				.. tostring(queueCounts[currentQueue] or 1) 
				.. "/" .. tostring(currentQueue) .. ")"
		end

	elseif msgType == "joinResult" then
		if payload.success then
			showQueuedState(payload.queueSize)
		else
			-- Failed to join — show error briefly in status
			local statusFrame = statusLabel.Parent :: Frame
			statusFrame.Visible = true
			statusLabel.Text = "⚠ " .. tostring(payload.message or "Could not join queue")
			statusLabel.TextColor3 = COLORS.redAccent
			task.delay(2, function()
				if currentQueue == nil and not isMatchFound then
					statusFrame.Visible = false
				end
			end)
		end

	elseif msgType == "leaveResult" then
		if payload.success then
			showIdleState()
		end

	elseif msgType == "queueChanged" then
		-- Another player joined/left our queue
		local qs = payload.queueSize
		local cc = payload.currentCount
		if typeof(qs) == "number" and typeof(cc) == "number" then
			queueCounts[qs] = cc
		end
		updateQueueDisplay()

		if currentQueue and not isMatchFound then
			statusLabel.Text = "🔍 Searching for players... (" 
				.. tostring(queueCounts[currentQueue] or 1) 
				.. "/" .. tostring(currentQueue) .. ")"
		end

	elseif msgType == "countdown" then
		showCountdownState(payload.remaining or 0)

	elseif msgType == "matchCancelled" then
		-- A player dropped during countdown — back to lobby
		statusLabel.Text = "⚠ " .. tostring(payload.reason or "Match cancelled")
		statusLabel.TextColor3 = COLORS.redAccent
		isMatchFound = false
		currentQueue = nil
		leaveButton.Visible = false

		task.delay(2.5, function()
			if currentQueue == nil and not isMatchFound then
				showIdleState()
			end
		end)
	end
end)

MatchFoundRemote.OnClientEvent:Connect(function(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	showMatchFoundState(payload)
end)

StartGameRemote.OnClientEvent:Connect(function(_payload: any)
	-- Game is starting! Hide the lobby.
	hideLobby()
end)

-- Also hide the lobby whenever the game leaves the LOBBY phase. On a reserved
-- match server the match begins via this phase change (not StartGame), so this
-- is what dismisses the menu after the party teleports in.
GameStateChangedRemote.OnClientEvent:Connect(function(payload: any)
	local phase = if typeof(payload) == "table" then payload.phase else payload
	if typeof(phase) == "number" and phase ~= 0 then -- 0 == LOBBY
		hideLobby()
	end
end)

--------------------------------------------------------------------------------
-- Initialize
--------------------------------------------------------------------------------

buildLobbyGui()

print("[LobbyUI] Lobby interface loaded ✓")
