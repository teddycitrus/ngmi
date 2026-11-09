--!strict
--------------------------------------------------------------------------------
-- Lobby/Browser.luau
-- "Open parties" list under the mode rows: parties on this server with room
-- that you may join (public ones, and friends-only ones led by a friend).
--------------------------------------------------------------------------------

local Parts = require(script.Parent:WaitForChild("Parts"))

local INK, MUTED = Parts.INK, Parts.MUTED
local ROW_HEIGHT = 60
local MODE_NAMES = { [1] = "Solo", [2] = "Duo", [4] = "Team" }

export type OpenParty = {
	id: string,
	leaderName: string,
	leaderId: number,
	mode: number,
	count: number,
	privacy: string,
	searching: boolean,
}

local Browser = {}

export type List = { update: ({ OpenParty }) -> () }

function Browser.build(parent: Instance, order: number, height: number, send: (string, { [string]: any }?) -> ()): List
	local box = Parts.box(parent, order, height)
	box.Name = "OpenParties"

	local caption = Parts.text(box, "OPEN PARTIES", 20, Parts.BOLD, MUTED)
	caption.Size = UDim2.new(1, 0, 0, 24)

	local scroll = Instance.new("ScrollingFrame")
	scroll.Position = UDim2.fromOffset(0, 34)
	scroll.Size = UDim2.new(1, 0, 1, -34)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 4
	scroll.ScrollBarImageColor3 = INK
	scroll.ScrollBarImageTransparency = 0.6
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.Parent = box
	Parts.vlist(scroll, 4)

	local empty = Parts.text(box, "No open parties right now", 22, Parts.BODY, MUTED)
	empty.Position = UDim2.fromOffset(0, 40)

	local rows: { [string]: Frame } = {}

	local function makeRow(): Frame
		local row = Parts.box(scroll, 0, ROW_HEIGHT)
		row.Size = UDim2.new(1, -10, 0, ROW_HEIGHT)

		local avatar = Instance.new("ImageLabel")
		avatar.Name = "Avatar"
		avatar.Size = UDim2.fromOffset(44, 44)
		avatar.Position = UDim2.fromOffset(0, 8)
		avatar.BackgroundColor3 = INK
		avatar.BackgroundTransparency = 0.92
		avatar.BorderSizePixel = 0
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(1, 0)
		corner.Parent = avatar
		avatar.Parent = row

		local name = Parts.text(row, "", 26, Parts.LABEL, INK)
		name.Name = "Leader"
		name.Position = UDim2.fromOffset(58, 4)
		name.Size = UDim2.new(1, -250, 0, 30)
		name.TextTruncate = Enum.TextTruncate.AtEnd

		local info = Parts.text(row, "", 18, Parts.BODY, MUTED)
		info.Name = "Info"
		info.Position = UDim2.fromOffset(58, 34)
		info.Size = UDim2.new(1, -250, 0, 22)

		local join = Parts.button(row, "JOIN", 44, false, function()
			send("join", { partyId = row:GetAttribute("PartyId") })
		end)
		join.button.AnchorPoint = Vector2.new(1, 0.5)
		join.button.Position = UDim2.new(1, 0, 0.5, 0)
		join.button.Size = UDim2.fromOffset(120, 44)
		return row
	end

	local function update(list: { OpenParty })
		local seen: { [string]: boolean } = {}
		for i, p in list do
			seen[p.id] = true
			local row = rows[p.id] or makeRow()
			rows[p.id] = row
			row.LayoutOrder = i
			row:SetAttribute("PartyId", p.id)
			local avatar = row:FindFirstChild("Avatar") :: ImageLabel
			avatar.Image = string.format("rbxthumb://type=AvatarHeadShot&id=%d&w=150&h=150", p.leaderId)
			local name = row:FindFirstChild("Leader") :: TextLabel
			name.Text = p.leaderName .. "'s party"
			local info = row:FindFirstChild("Info") :: TextLabel
			local bits = { string.format("%s  %d / %d", MODE_NAMES[p.mode] or "Party", p.count, p.mode) }
			if p.privacy == "friends" then
				table.insert(bits, "friends")
			end
			if p.searching then
				table.insert(bits, "searching")
			end
			info.Text = table.concat(bits, "   ")
		end
		for id, row in rows do
			if not seen[id] then
				row:Destroy()
				rows[id] = nil
			end
		end
		empty.Visible = #list == 0
	end

	return { update = update }
end

return Browser
