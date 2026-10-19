--!strict
--------------------------------------------------------------------------------
-- VenueLights.luau
-- The venue's tagged light fixtures as LightingController switches them per
-- phase: ceiling lights on or off (with their Neon glow), emergency lights on
-- in red, and the Night 2 emergency strobe.
--------------------------------------------------------------------------------

local CollectionService = game:GetService("CollectionService")

local TAG_CEILING_LIGHT = "CeilingLight"
local TAG_EMERGENCY_LIGHT = "EmergencyLight"

-- Strobe timing (Night2 emergency lights)
local STROBE_MIN_INTERVAL = 0.5
local STROBE_MAX_INTERVAL = 2.0

local VenueLights = {}

local strobeToken = 0

--- Enable or disable every light source inside the fixtures carrying `tag`.
local function setTaggedLights(tag: string, enabled: boolean, color: Color3?)
	for _, fixture in CollectionService:GetTagged(tag) do
		for _, child in fixture:GetDescendants() do
			if child:IsA("PointLight") or child:IsA("SpotLight") or child:IsA("SurfaceLight") then
				child.Enabled = enabled
				if color then
					child.Color = color
				end
			end
		end
	end
end

function VenueLights.setCeiling(on: boolean)
	setTaggedLights(TAG_CEILING_LIGHT, on)
	-- Drop the emissive material too, so a dark fixture doesn't keep glowing.
	for _, fixture in CollectionService:GetTagged(TAG_CEILING_LIGHT) do
		if fixture:IsA("BasePart") then
			if on then
				fixture.Material = Enum.Material.Neon
			elseif fixture.Material == Enum.Material.Neon then
				fixture.Material = Enum.Material.SmoothPlastic
			end
		end
	end
end

function VenueLights.setEmergency(on: boolean)
	setTaggedLights(TAG_EMERGENCY_LIGHT, on, if on then Color3.fromRGB(255, 30, 30) else nil)
end

--- Token-guarded like the glitch loop: a new call or stopStrobe retires any
--- loop already running.
function VenueLights.stopStrobe()
	strobeToken += 1
end

function VenueLights.startStrobe()
	strobeToken += 1
	local token = strobeToken

	task.spawn(function()
		while token == strobeToken do
			local interval = math.random() * (STROBE_MAX_INTERVAL - STROBE_MIN_INTERVAL) + STROBE_MIN_INTERVAL
			task.wait(interval)
			if token ~= strobeToken then
				break
			end

			for _, fixture in CollectionService:GetTagged(TAG_EMERGENCY_LIGHT) do
				local light = fixture:FindFirstChildOfClass("PointLight") or fixture:FindFirstChildOfClass("SpotLight")
				if light then
					light.Enabled = not light.Enabled
				end
			end
		end
	end)
end

return VenueLights
