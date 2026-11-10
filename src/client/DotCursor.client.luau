--!strict
--------------------------------------------------------------------------------
-- DotCursor.client.luau
-- The mouse cursor is a small white dot, the same as the first-person reticle.
-- The system arrow is swapped for a blank texture and the dot is drawn where
-- the mouse is. Whether a cursor shows at all is still decided by whoever sets
-- UserInputService.MouseIconEnabled (CursorManager, HUDController), so this
-- only changes what it looks like.
--------------------------------------------------------------------------------

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

if not UserInputService.MouseEnabled then
	return
end

local BLANK = "rbxasset://textures/Blank.png"
local SIZE = 7

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local gui = Instance.new("ScreenGui")
gui.Name = "DotCursor"
gui.IgnoreGuiInset = true
gui.ResetOnSpawn = false
gui.DisplayOrder = 10000
gui:SetAttribute("CutsceneExempt", true)
gui.Parent = playerGui

local dot = Instance.new("Frame")
dot.Name = "Dot"
dot.AnchorPoint = Vector2.new(0.5, 0.5)
dot.Size = UDim2.fromOffset(SIZE, SIZE)
dot.BackgroundColor3 = Color3.new(1, 1, 1)
dot.BorderSizePixel = 0
dot.Active = false
dot.Visible = false
dot.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(1, 0)
corner.Parent = dot

-- a soft dark ring so it survives a white wall behind it
local ring = Instance.new("UIStroke")
ring.Color = Color3.new(0, 0, 0)
ring.Thickness = 1
ring.Transparency = 0.45
ring.Parent = dot

RunService:BindToRenderStep("DotCursor", Enum.RenderPriority.Last.Value, function()
	-- the Roblox menu draws over every game GUI, so it keeps the real arrow
	local menu = GuiService.MenuIsOpen
	local icon = if menu then "" else BLANK
	if UserInputService.MouseIcon ~= icon then
		UserInputService.MouseIcon = icon
	end
	-- MouseIconEnabled is the signal: HUDController turns it off whenever the
	-- mouse is pinned to the centre. MouseBehavior can't be used, it still
	-- reads LockCenter while a Modal button has the mouse freed.
	local free = not menu and UserInputService.MouseIconEnabled
	dot.Visible = free
	if free then
		local at = UserInputService:GetMouseLocation()
		dot.Position = UDim2.fromOffset(at.X, at.Y)
	end
end)
