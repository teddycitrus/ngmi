--!strict
--------------------------------------------------------------------------------
-- Lobby/PartyPanel.luau
-- The right-hand column of the lobby menu: who is in your party, who may join
-- it, the start / ready button, the party code, invites and joining by code.
-- It only displays the server's state (LobbyManager) and sends actions back;
-- the server decides what is allowed.
--------------------------------------------------------------------------------

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local SocialService = game:GetService("SocialService")

local Parts = require(script.Parent:WaitForChild("Parts"))

local INK, MUTED = Parts.INK, Parts.MUTED
local LocalPlayer = Players.LocalPlayer

export type Member = { userId: number, name: string, displayName: string, leader: boolean, ready: boolean }
export type PartyState = {
	id: string,
	code: string,
	leaderId: number,
	mode: number,
	privacy: string,
	fill: boolean,
	status: string,
	searchSeconds: number?,
	members: { Member },
}
export type State = {
	party: PartyState?,
	open: { any },
	searching: { { mode: number, players: number } },
	rejoin: boolean,
	matchRunning: boolean,
	jobId: string,
}
export type Send = (action: string, payload: { [string]: any }?) -> ()

local SLOT_HEIGHT = 72
local PRIVACY = { { id = "public", label = "PUBLIC" }, { id = "friends", label = "FRIENDS" }, { id = "private", label = "PRIVATE" } }

local PartyPanel = {}

local function headshot(userId: number): string
	return string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150", userId)
end

local function clock(seconds: number): string
	return string.format("%d:%02d", seconds // 60, seconds % 60)
end

type Slot = {
	frame: Frame,
	avatar: ImageLabel,
	name: TextLabel,
	handle: TextLabel,
	tag: TextLabel,
	promote: TextButton,
	kick: TextButton,
	userId: number?,
}

local function smallTextButton(parent: Instance, text: string, x: number, onClick: () -> ()): TextButton
	local b = Instance.new("TextButton")
	b.AutoButtonColor = false
	b.BackgroundTransparency = 1
	b.Text = text
	b.TextSize = 18
	b.FontFace = Parts.BOLD
	b.TextColor3 = MUTED
	b.AnchorPoint = Vector2.new(1, 0.5)
	b.Position = UDim2.new(1, x, 0.5, 0)
	b.Size = UDim2.fromOffset(84, 32)
	b.MouseEnter:Connect(function()
		b.TextColor3 = INK
	end)
	b.MouseLeave:Connect(function()
		b.TextColor3 = MUTED
	end)
	b.Activated:Connect(onClick)
	b.Parent = parent
	return b
end

local function buildSlot(parent: Instance, order: number, send: Send): Slot
	local frame = Parts.box(parent, order, SLOT_HEIGHT)
	frame.Name = "Slot" .. order

	local rule = Instance.new("Frame")
	rule.AnchorPoint = Vector2.new(0, 1)
	rule.Position = UDim2.fromScale(0, 1)
	rule.Size = UDim2.new(1, 0, 0, 1)
	rule.BackgroundColor3 = INK
	rule.BackgroundTransparency = Parts.LINE_IDLE
	rule.BorderSizePixel = 0
	rule.Parent = frame

	local avatar = Instance.new("ImageLabel")
	avatar.Size = UDim2.fromOffset(56, 56)
	avatar.Position = UDim2.fromOffset(0, 6)
	avatar.BackgroundColor3 = INK
	avatar.BackgroundTransparency = 0.92
	avatar.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = avatar
	avatar.Parent = frame

	local name = Parts.text(frame, "", 28, Parts.LABEL, INK)
	name.Position = UDim2.fromOffset(72, 6)
	name.Size = UDim2.new(1, -330, 0, 32)
	name.TextTruncate = Enum.TextTruncate.AtEnd

	local handle = Parts.text(frame, "", 18, Parts.BODY, MUTED)
	handle.Position = UDim2.fromOffset(72, 40)
	handle.Size = UDim2.new(1, -330, 0, 22)
	handle.TextTruncate = Enum.TextTruncate.AtEnd

	local tag = Parts.text(frame, "", 18, Parts.BOLD, MUTED)
	tag.AnchorPoint = Vector2.new(1, 0.5)
	tag.Position = UDim2.new(1, 0, 0.5, 0)
	tag.Size = UDim2.fromOffset(130, 22)
	tag.TextXAlignment = Enum.TextXAlignment.Right

	local slot: Slot
	local kick = smallTextButton(frame, "KICK", -130, function()
		if slot.userId then
			send("kick", { userId = slot.userId })
		end
	end)
	local promote = smallTextButton(frame, "LEADER", -214, function()
		if slot.userId then
			send("promote", { userId = slot.userId })
		end
	end)
	slot = { frame = frame, avatar = avatar, name = name, handle = handle, tag = tag, promote = promote, kick = kick, userId = nil }
	return slot
end

local function invite(code: string, jobId: string)
	local ok, canInvite = pcall(function()
		return SocialService:CanSendGameInviteAsync(LocalPlayer)
	end)
	if not ok or not canInvite then
		return
	end
	local options = Instance.new("ExperienceInviteOptions")
	options.PromptMessage = "Join my party"
	options.LaunchData = HttpService:JSONEncode({ j = jobId, c = code })
	pcall(function()
		SocialService:PromptGameInvite(LocalPlayer, options)
	end)
end

export type Panel = { update: (State) -> (), tick: () -> () }

function PartyPanel.build(column: Frame, send: Send): Panel
	Parts.vlist(column, 14)
	local state: State? = nil
	local searchBase, searchAt = 0, 0

	-- Header
	local header = Parts.box(column, 1, 34)
	local title = Parts.text(header, "PARTY", 24, Parts.BOLD, MUTED)
	title.Size = UDim2.fromScale(0.5, 1)
	local size = Parts.text(header, "", 24, Parts.BOLD, INK)
	size.AnchorPoint = Vector2.new(1, 0)
	size.Position = UDim2.fromScale(1, 0)
	size.Size = UDim2.fromScale(0.5, 1)
	size.TextXAlignment = Enum.TextXAlignment.Right

	-- Who can join
	local privacyRow = Parts.box(column, 2, 48)
	Parts.hlist(privacyRow, 8)
	local privacyButtons: { [string]: TextButton } = {}
	for i, p in PRIVACY do
		local b = Instance.new("TextButton")
		b.LayoutOrder = i
		b.AutoButtonColor = false
		b.Size = UDim2.new(1 / 3, -6, 1, 0)
		b.BackgroundColor3 = INK
		b.BorderSizePixel = 0
		b.Text = p.label
		b.TextSize = 20
		b.FontFace = Parts.BOLD
		Instance.new("UICorner").Parent = b
		b.Activated:Connect(function()
			send("privacy", { privacy = p.id })
		end)
		b.Parent = privacyRow
		privacyButtons[p.id] = b
	end

	-- Members
	local slotsBox = Parts.box(column, 3, 4 * SLOT_HEIGHT + 3 * 6)
	Parts.vlist(slotsBox, 6)
	local slots: { Slot } = {}
	for i = 1, 4 do
		slots[i] = buildSlot(slotsBox, i, send)
	end

	local status = Parts.text(column, "", 24, Parts.LABEL, MUTED)
	status.LayoutOrder = 4

	local primary = Parts.button(column, "START MATCH", 68, true, function()
		local s = state
		local party = s and s.party
		if not party then
			return
		end
		local leader = party.leaderId == LocalPlayer.UserId
		if party.status == "searching" then
			send("cancel")
		elseif leader then
			send("start")
		else
			for _, m in party.members do
				if m.userId == LocalPlayer.UserId then
					send("ready", { ready = not m.ready })
				end
			end
		end
	end)
	primary.button.LayoutOrder = 5

	local secondaryRow = Parts.box(column, 6, 48)
	Parts.hlist(secondaryRow, 12)
	local leave = Parts.button(secondaryRow, "LEAVE PARTY", 48, false, function()
		send("leave")
	end)
	leave.button.Size = UDim2.new(0.5, -6, 1, 0)
	local startNow = Parts.button(secondaryRow, "START NOW", 48, false, function()
		send("startNow")
	end)
	startNow.button.Size = UDim2.new(0.5, -6, 1, 0)

	-- Fill toggle
	local fillRow = Parts.box(column, 7, 36)
	local check = Instance.new("TextButton")
	check.AutoButtonColor = false
	check.Text = ""
	check.Size = UDim2.fromOffset(30, 30)
	check.Position = UDim2.fromOffset(0, 3)
	check.BackgroundTransparency = 1
	local outline = Instance.new("UIStroke")
	outline.Color = INK
	outline.Transparency = 0.5
	outline.Thickness = 2
	outline.Parent = check
	local tick = Instance.new("Frame")
	tick.AnchorPoint = Vector2.new(0.5, 0.5)
	tick.Position = UDim2.fromScale(0.5, 0.5)
	tick.Size = UDim2.fromOffset(16, 16)
	tick.BackgroundColor3 = INK
	tick.BorderSizePixel = 0
	tick.Parent = check
	check.Parent = fillRow
	local fillLabel = Parts.text(fillRow, "Fill open slots with other players", 22, Parts.LABEL, INK)
	fillLabel.Position = UDim2.fromOffset(44, 5)
	fillLabel.Size = UDim2.new(1, -44, 0, 26)
	check.Activated:Connect(function()
		local party = state and state.party
		if party then
			send("fill", { fill = not party.fill })
		end
	end)

	-- Code and invites
	local codeRow = Parts.box(column, 8, 52)
	local codeCaption = Parts.text(codeRow, "CODE", 20, Parts.BOLD, MUTED)
	codeCaption.Position = UDim2.fromOffset(0, 14)
	codeCaption.Size = UDim2.fromOffset(70, 24)
	local code = Parts.text(codeRow, "", 38, Parts.MONO, INK)
	code.Position = UDim2.fromOffset(72, 4)
	code.Size = UDim2.fromOffset(200, 44)
	local inviteButton = Parts.button(codeRow, "INVITE FRIENDS", 48, false, function()
		local s = state
		if s and s.party then
			invite(s.party.code, s.jobId)
		end
	end)
	inviteButton.button.AnchorPoint = Vector2.new(1, 0)
	inviteButton.button.Position = UDim2.new(1, 0, 0, 2)
	inviteButton.button.Size = UDim2.fromOffset(240, 48)

	local joinRow = Parts.box(column, 9, 52)
	local input = Instance.new("TextBox")
	input.Size = UDim2.new(1, -144, 1, 0)
	input.BackgroundColor3 = INK
	input.BackgroundTransparency = 0.95
	input.BorderSizePixel = 0
	input.ClearTextOnFocus = false
	input.PlaceholderText = "Party code"
	input.PlaceholderColor3 = MUTED
	input.Text = ""
	input.TextSize = 26
	input.FontFace = Parts.MONO
	input.TextColor3 = INK
	input.TextXAlignment = Enum.TextXAlignment.Left
	Instance.new("UICorner").Parent = input
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 16)
	pad.Parent = input
	local inputStroke = Instance.new("UIStroke")
	inputStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	inputStroke.Color = INK
	inputStroke.Transparency = 0.7
	inputStroke.Parent = input
	input.Parent = joinRow
	local function submitCode()
		local text = string.gsub(input.Text, "%s", "")
		if text ~= "" then
			send("code", { code = text })
			input.Text = ""
		end
	end
	input.FocusLost:Connect(function(enter: boolean)
		if enter then
			submitCode()
		end
	end)
	local joinButton = Parts.button(joinRow, "JOIN", 52, false, submitCode)
	joinButton.button.AnchorPoint = Vector2.new(1, 0)
	joinButton.button.Position = UDim2.fromScale(1, 0)
	joinButton.button.Size = UDim2.fromOffset(130, 52)

	local function refreshStatus()
		local s = state
		local party = s and s.party
		if not s or not party then
			status.Text = ""
			return
		end
		if party.status == "searching" then
			local elapsed = searchBase + math.floor(os.clock() - searchAt)
			status.Text = string.format("Searching for players   %s", clock(elapsed))
			status.TextColor3 = INK
		elseif party.status == "countdown" or party.status == "launching" then
			status.Text = "Match starting"
			status.TextColor3 = Parts.GOOD
		elseif s.matchRunning then
			status.Text = "A match is running on this server"
			status.TextColor3 = Parts.WARN
		else
			local waiting = 0
			for _, m in party.members do
				if not m.ready then
					waiting += 1
				end
			end
			status.Text = if waiting > 0 then string.format("Waiting for %d to ready up", waiting) else ""
			status.TextColor3 = MUTED
		end
	end

	local function update(s: State)
		state = s
		local party = s.party
		if not party then
			return
		end
		local me = LocalPlayer.UserId
		local leader = party.leaderId == me
		local idle = party.status == "idle"
		local open = idle or party.status == "searching"
		if party.searchSeconds then
			searchBase, searchAt = party.searchSeconds, os.clock()
		end

		size.Text = string.format("%d / %d", #party.members, party.mode)

		for id, b in privacyButtons do
			local on = party.privacy == id
			b.BackgroundTransparency = if on then 0.86 else 0.97
			b.TextColor3 = if on then INK else MUTED
			b.AutoButtonColor = false
			b.Active = leader
		end

		for i, slot in slots do
			local m = party.members[i]
			slot.frame.Visible = i <= party.mode
			slot.userId = if m then m.userId else nil
			if m then
				slot.avatar.Image = headshot(m.userId)
				slot.name.Text = m.displayName .. (if m.userId == me then "  (you)" else "")
				slot.name.TextColor3 = INK
				slot.handle.Text = "@" .. m.name
				slot.tag.Text = if m.leader then "LEADER" elseif m.ready then "READY" else "NOT READY"
				slot.tag.TextColor3 = if m.leader then Parts.RED elseif m.ready then Parts.GOOD else MUTED
			else
				slot.avatar.Image = ""
				slot.name.Text = "Open slot"
				slot.name.TextColor3 = MUTED
				slot.handle.Text = ""
				slot.tag.Text = ""
			end
			local manage = leader and open and m ~= nil and m.userId ~= me
			slot.promote.Visible = manage
			slot.kick.Visible = manage
		end

		local allReady = true
		for _, m in party.members do
			if not m.ready then
				allReady = false
			end
		end
		local myReady = false
		for _, m in party.members do
			if m.userId == me then
				myReady = m.ready
			end
		end
		local short = party.mode - #party.members
		if s.matchRunning and idle then
			primary.set("MATCH IN PROGRESS", false)
		elseif party.status == "searching" then
			primary.set(if leader then "CANCEL SEARCH" else "SEARCHING", leader)
		elseif not open then
			primary.set("STARTING", false)
		elseif leader then
			if not allReady then
				primary.set("WAITING FOR READY", false)
			elseif short <= 0 then
				primary.set("START MATCH", true)
			elseif party.fill then
				primary.set(string.format("FIND %d MORE", short), true)
			else
				primary.set(string.format("START WITH %d", #party.members), true)
			end
		else
			primary.set(if myReady then "UNREADY" else "READY UP", true)
		end

		leave.button.Visible = #party.members > 1 and party.status ~= "launching"
		startNow.button.Visible = leader and party.status == "searching"
		startNow.set("START NOW", true)
		secondaryRow.Visible = leave.button.Visible or startNow.button.Visible

		tick.Visible = party.fill
		check.Active = leader and idle
		fillLabel.TextTransparency = if leader and idle then 0 else 0.4
		fillRow.Visible = party.mode > 1

		code.Text = party.code
		refreshStatus()
	end

	return { update = update, tick = refreshStatus }
end

return PartyPanel
