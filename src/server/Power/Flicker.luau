--!strict
--------------------------------------------------------------------------------
-- Power/Flicker.luau
-- Sabotage brown-out for PowerManager's ceiling lights.
--
-- When the grid is sabotaged it browns out before it dies: the tubes buzz, dip,
-- cut out for a beat and come back. Two signals stacked give that without
-- looking like a regular strobe:
--   * a slow Perlin wander (math.noise) that drives the overall level and, when
--     it dips far enough, drops the tube out completely
--   * a fast sine buzz riding on top for the hum of a failing ballast
-- Each light gets its own noise seed, so a corridor fails raggedly rather than
-- every fixture blinking in lockstep.
--
-- Every tick scales each light's CURRENT power level (LightState.level, set by
-- PowerManager), not a snapshot taken when the flicker began. So a panel fixed
-- or a floor restored mid-flicker is kept, and the settle at the end lands on
-- the live state instead of rolling it back.
--
-- Bounded on purpose: one 12 Hz loop, only for the duration of the event, and
-- only over the affected floor's lights.
--------------------------------------------------------------------------------

export type LightState = {
	part: BasePart,
	light: PointLight?,
	brightness: number, -- the fixture's own full brightness
	level: number, -- share of `brightness` the current power state allows (0..1)
	color: Color3,
	material: Enum.Material,
	floor: number,
	on: boolean,
}

local FLICKER_TICK = 1 / 12 -- seconds between flicker updates
local FLICKER_DROPOUT = -0.28 -- noise value below which the tube cuts out entirely

local Flicker = {}

Flicker.DEFAULT_SECONDS = 6 -- how long a brown-out lasts if the sender doesn't say

local deadline = 0 -- os.clock() when the current flicker ends
local onlyFloor: number? = nil -- restrict to one floor, or nil for the venue
local running = false

--- Brightness multiplier in 0..1 for one fixture at time `t`.
local function levelAt(t: number, seed: number): number
	local wander = math.noise(t * 3.1, seed, 0) -- slow, -0.5..0.5
	if wander < FLICKER_DROPOUT then
		return 0 -- tube is out for this beat
	end
	local buzz = math.sin(t * 47 + seed) * 0.5 -- fast ballast hum
	return math.clamp(0.55 + wander * 1.2 + buzz * 0.18, 0, 1)
end

--- Flicker `lights` for `duration` seconds. `floor` limits it to one level;
--- nil hits the whole venue. Re-arming while a flicker is already running just
--- extends the deadline instead of stacking a second loop.
function Flicker.start(lights: { LightState }, duration: number, floor: number?)
	deadline = math.max(deadline, os.clock() + duration)
	onlyFloor = floor
	if running then
		return
	end
	running = true

	task.spawn(function()
		while os.clock() < deadline do
			local t = os.clock()
			for i, ls in lights do
				if ls.light and ls.on and (onlyFloor == nil or ls.floor == onlyFloor) then
					local level = levelAt(t, i * 12.9898)
					ls.light.Brightness = ls.brightness * ls.level * level
					-- Kill the emissive material too, or a dark fixture keeps
					-- glowing while its light is off.
					ls.part.Material = if level > 0.05 then Enum.Material.Neon else Enum.Material.SmoothPlastic
				end
			end
			task.wait(FLICKER_TICK)
		end

		-- Settle on whatever the power state is now.
		for _, ls in lights do
			if ls.light then
				ls.light.Brightness = ls.brightness * ls.level
				if ls.on then
					ls.part.Material = Enum.Material.Neon
				end
			end
		end

		running = false
		onlyFloor = nil
	end)
end

return Flicker
