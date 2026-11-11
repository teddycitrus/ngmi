--!strict
--------------------------------------------------------------------------------
-- DotCursor.client.luau
-- The only mouse cursor in the game is a small white dot. The system cursor
-- is turned off for good (Roblox swaps in its own pointer over buttons even
-- with a custom icon, so a custom icon alone isn't enough), and the dot is
-- drawn where the mouse is, only while something needs a cursor:
--   * a scene holding it through CursorManager (dialogue replies, terminals,
--     panels, ending screens, the admin panel)
--   * the lobby menu
--   * the mouse free outside a cutscene
-- First-person gameplay has HUDController's centre dot instead.
--------------------------------------------------------------------------------

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

if not UserInputService.MouseEnabled then
	return
end

local CursorManager = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CursorManager"))

local SIZE = 7
local LOBBY = 0

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

local function lobbyMenu(): boolean
	if ReplicatedStorage:GetAttribute("IsMatchServer") == true then
		return false
	end
	local phase = ReplicatedStorage:FindFirstChild("CurrentPhase")
	return phase ~= nil and phase:IsA("IntValue") and phase.Value == LOBBY
end

local function needed(): boolean
	if CursorManager.isOpen() or lobbyMenu() then
		return true
	end
	local camera = workspace.CurrentCamera
	local cutscene = camera ~= nil and camera.CameraType == Enum.CameraType.Scriptable
	return not cutscene
		and player.CameraMode ~= Enum.CameraMode.LockFirstPerson
		and UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter
end

RunService:BindToRenderStep("DotCursor", Enum.RenderPriority.Last.Value, function()
	-- the Roblox menu draws over every game GUI, so it keeps the real arrow
	local menu = GuiService.MenuIsOpen
	if UserInputService.MouseIconEnabled ~= menu then
		UserInputService.MouseIconEnabled = menu
	end
	local show = not menu and needed()
	dot.Visible = show
	if show then
		local at = UserInputService:GetMouseLocation()
		dot.Position = UDim2.fromOffset(at.X, at.Y)
	end
end)
