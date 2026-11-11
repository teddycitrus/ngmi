--!strict
--------------------------------------------------------------------------------
-- Cutscene/SceneHold.luau
-- Puts the player "in a cutscene" and back: controls and prompts off, every
-- other ScreenGui and the through-wall panel highlights hidden, the
-- character anchored and kept out of the lens, and gameplay NGMIs hidden so
-- the only creature on screen is the scripted one.
--
--   local release = SceneHold.hold(character, keepGui)
--   ...
--   release()   -- restores exactly what it changed
--------------------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RunService = game:GetService("RunService")

local WorldIndex = require(script.Parent:WaitForChild("WorldIndex"))

local SceneHold = {}

function SceneHold.controls(on: boolean)
	local player = Players.LocalPlayer
	local ok, module = pcall(function()
		return require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 3) :: ModuleScript)
	end)
	local c = ok and module and (module :: any):GetControls()
	if c then
		if on then
			c:Enable()
		else
			c:Disable()
		end
	end
end

function SceneHold.hold(char: Model, keep: ScreenGui?): () -> ()
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	SceneHold.controls(false)
	ProximityPromptService.Enabled = false

	local guis: { ScreenGui } = {}
	for _, g in playerGui:GetChildren() do
		if g:IsA("ScreenGui") and g ~= keep and g.Enabled then
			g.Enabled = false
			table.insert(guis, g)
		end
	end
	local highlights: { Highlight } = {}
	for _, d in WorldIndex.highlights() do
		if d.Enabled then
			d.Enabled = false
			table.insert(highlights, d)
		end
	end
	local root = char:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.Anchored = true
	end

	local hiddenNgmi: { [BasePart]: boolean } = {}
	local conn = RunService.RenderStepped:Connect(function()
		for _, d in char:GetDescendants() do
			if d:IsA("BasePart") or d:IsA("Decal") then
				d.LocalTransparencyModifier = 1
			end
		end
		for _, m in CollectionService:GetTagged("NGMI") do
			for _, d in m:GetDescendants() do
				if d:IsA("BasePart") then
					d.LocalTransparencyModifier = 1
					hiddenNgmi[d] = true
				end
			end
		end
	end)

	local released = false
	return function()
		if released then
			return
		end
		released = true
		conn:Disconnect()
		for p in hiddenNgmi do
			if p.Parent then
				p.LocalTransparencyModifier = 0
			end
		end
		for _, d in char:GetDescendants() do
			if d:IsA("BasePart") or d:IsA("Decal") then
				d.LocalTransparencyModifier = 0
			end
		end
		if root and root:IsA("BasePart") then
			root.Anchored = false
		end
		for _, g in guis do
			if g.Parent then
				g.Enabled = true
			end
		end
		for _, h in highlights do
			if h.Parent then
				h.Enabled = true
			end
		end
		ProximityPromptService.Enabled = true
		SceneHold.controls(true)
	end
end

return SceneHold
