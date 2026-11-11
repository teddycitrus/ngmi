--!strict
--------------------------------------------------------------------------------
-- ClosetGlow.client.luau
-- When an NGMI is after you, the free closets nearby glow faintly: a warm
-- edge and a dim light spilling out of the open door, so in the dark you can
-- find somewhere to hide. Only for the player being trailed (NGMIController
-- publishes each NGMI's TargetUserId), only closets nobody is in (the hiding
-- spot's Occupied attribute), and never once you are already hidden.
--------------------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local GameConfig = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("GameConfig"))

local player = Players.LocalPlayer

local RANGE = 70
local WARM = Color3.fromRGB(255, 222, 168)
local FADE = TweenInfo.new(0.8, Enum.EasingStyle.Sine)

type Glow = { highlight: Highlight, light: PointLight }
local glows: { [Instance]: Glow } = {}

local function trailed(): boolean
	for _, m in CollectionService:GetTagged("NGMI") do
		if m:GetAttribute("TargetUserId") == player.UserId then
			return true
		end
	end
	return false
end

local function glowFor(spot: BasePart): Glow
	local g = glows[spot]
	if g then
		return g
	end
	local closet = spot.Parent :: Instance
	local h = Instance.new("Highlight")
	h.Name = "ClosetGlow"
	h.FillColor = WARM
	h.OutlineColor = WARM
	h.FillTransparency = 1
	h.OutlineTransparency = 1
	h.DepthMode = Enum.HighlightDepthMode.Occluded
	h.Adornee = closet
	h.Parent = closet
	local l = Instance.new("PointLight")
	l.Name = "ClosetGlowLight"
	l.Color = WARM
	l.Brightness = 0
	l.Range = 9
	l.Shadows = false
	l.Parent = spot
	g = { highlight = h, light = l }
	glows[spot] = g
	return g
end

local function set(g: Glow, on: boolean)
	TweenService:Create(g.highlight, FADE, {
		FillTransparency = if on then 0.86 else 1,
		OutlineTransparency = if on then 0.55 else 1,
	}):Play()
	TweenService:Create(g.light, FADE, { Brightness = if on then 0.5 else 0 }):Play()
end

local lit: { [Instance]: boolean } = {}

task.spawn(function()
	while true do
		task.wait(0.3)
		local want: { [Instance]: boolean } = {}
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and player:GetAttribute("Hiding") ~= true and trailed() then
			for _, spot in CollectionService:GetTagged(GameConfig.TAGS.HIDING_SPOT) do
				if
					spot:IsA("BasePart")
					and spot:GetAttribute("Closet")
					and not spot:GetAttribute("Occupied")
					and (spot.Position - root.Position).Magnitude < RANGE
				then
					want[spot] = true
				end
			end
		end
		for spot in want do
			if not lit[spot] then
				set(glowFor(spot :: BasePart), true)
			end
		end
		for spot in lit do
			if not want[spot] and glows[spot] then
				set(glows[spot], false)
			end
		end
		lit = want
	end
end)
