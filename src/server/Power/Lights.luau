--!strict
--------------------------------------------------------------------------------
-- Power/Lights.luau
-- The power states of PowerManager's ceiling lights: off, backup (a dim cold
-- trickle), floor (the limping partial grid) and full (the fixture as built).
--------------------------------------------------------------------------------

local Flicker = require(script.Parent:WaitForChild("Flicker"))

type LightState = Flicker.LightState

local Lights = {}

local OFF_COLOR = Color3.fromRGB(40, 42, 46)
local BACKUP_COLOR = Color3.fromRGB(120, 135, 160)

--- Put one light in a power state: "off", "backup", "floor" or "full".
function Lights.set(ls: LightState, mode: string)
	if mode == "off" then
		if ls.light then
			ls.light.Enabled = false
		end
		ls.part.Material = Enum.Material.SmoothPlastic
		ls.part.Color = OFF_COLOR
		ls.level = 0
		ls.on = false
		return
	end
	local level = if mode == "backup" then 0.35 elseif mode == "floor" then 0.6 else 1
	if ls.light then
		ls.light.Enabled = true
		ls.light.Brightness = ls.brightness * level
	end
	ls.part.Material = if mode == "full" then ls.material else Enum.Material.Neon
	ls.part.Color = if mode == "backup" then BACKUP_COLOR else ls.color
	ls.level = level
	ls.on = true
end

--- Every light (or every light on `floor`) back to full.
function Lights.restore(lights: { LightState }, floor: number?)
	for _, ls in lights do
		if floor == nil or ls.floor == floor then
			Lights.set(ls, "full")
		end
	end
end

return Lights
