--!strict
--------------------------------------------------------------------------------
-- Lighting/Blackout.luau
-- Night 2's power cut for everything in the venue that glows on its own:
-- neon signs, monitor and laptop screens, the vending backlights, posters
-- and labels drawn at full brightness. With the power out none of it should
-- show in the dark, only where a light (the flashlight, the player's own
-- glow, a restored ceiling light) actually falls on it. So, locally:
--
--   SurfaceGuis   LightInfluence 1, lit by the scene like any surface
--   Neon parts    SmoothPlastic, and any light inside them switched off
--   other lights  off (stage spots, TV and screen glows)
--
-- Ceiling and emergency fixtures are left alone: VenueLights, PowerManager
-- and the emergency strobe own those. Everything is put back when the night
-- ends.
--------------------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")

local Blackout = {}

local OWNED_TAGS = { "CeilingLight", "EmergencyLight" }

local saved: { [Instance]: any } = {}
local active = false

local function ownedFixture(inst: Instance): boolean
	local node: Instance? = inst
	while node and node ~= workspace do
		for _, tag in OWNED_TAGS do
			if CollectionService:HasTag(node, tag) then
				return true
			end
		end
		node = node.Parent
	end
	return false
end

function Blackout.set(on: boolean)
	if on == active then
		return
	end
	active = on
	if not on then
		for inst, was in saved do
			if inst.Parent then
				if inst:IsA("SurfaceGui") then
					inst.LightInfluence = was
				elseif inst:IsA("BasePart") then
					inst.Material = was
				elseif inst:IsA("Light") then
					inst.Enabled = was
				end
			end
		end
		table.clear(saved)
		return
	end
	local map = workspace:FindFirstChild("Map")
	if not map then
		return
	end
	for _, d in map:GetDescendants() do
		if d:IsA("SurfaceGui") then
			if d.LightInfluence < 1 then
				saved[d] = d.LightInfluence
				d.LightInfluence = 1
			end
		elseif d:IsA("BasePart") then
			if d.Material == Enum.Material.Neon and not ownedFixture(d) then
				saved[d] = d.Material
				d.Material = Enum.Material.SmoothPlastic
			end
		elseif d:IsA("Light") then
			if d.Enabled and not ownedFixture(d) then
				saved[d] = true
				d.Enabled = false
			end
		end
	end
end

return Blackout
