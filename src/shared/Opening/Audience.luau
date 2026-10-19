--!strict
--------------------------------------------------------------------------------
-- Opening/Audience.luau
-- The seated crowd for OpeningCinematic: finds the auditorium benches, seats
-- local extras along them (clear of the real NPCs), and picks the one who
-- checks their armpit on "deodorant".
--------------------------------------------------------------------------------

local Shared = script.Parent.Parent
local SpeakerChoreo = require(Shared.SpeakerChoreo)
local CutsceneActors = require(Shared.CutsceneActors)

local MAX_EXTRAS = 44
local SEAT_SPACING = 3.3
local V = Vector3.new

local Audience = {}

--------------------------------------------------------------------------------
-- Audience
--------------------------------------------------------------------------------

export type Extra = { actor: CutsceneActors.Actor, member: SpeakerChoreo.Member, pos: Vector3 }

function Audience.collectBenches(aud: { [string]: number }): { BasePart }
	local out: { BasePart } = {}
	local map = workspace:FindFirstChild("Map")
	if not map then
		return out
	end
	for _, d in map:GetDescendants() do
		if d:IsA("Seat") and d.Name == "BenchSeat" then
			local p = d.Position
			if p.X >= aud.minX and p.X <= aud.maxX and p.Z >= aud.minZ and p.Z <= aud.maxZ and p.Y < 16 then
				table.insert(out, d)
			end
		end
	end
	return out
end

--- Fill the middle of the raked seating with seated actors, leaving the
--- named NPCs' seats and the player's seat clear.
function Audience.buildAudience(parent: Instance, aud: { [string]: number }, cx: number, avoid: { Vector3 }): { Extra }
	local sources = CutsceneActors.gatherSources({ "AmbientPeople", "NPCs" })
	local extras: { Extra } = {}
	if #sources == 0 then
		return extras
	end
	local slots: { { pos: Vector3, top: number } } = {}
	for _, bench in Audience.collectBenches(aud) do
		local half = bench.Size.X * 0.5
		local top = bench.Position.Y + bench.Size.Y * 0.5
		local x = bench.Position.X - half + 1.8
		while x < bench.Position.X + half - 1.8 do
			if math.abs(x - cx) < 36 then
				local pos = V(x, top, bench.Position.Z)
				local clear = true
				for _, a in avoid do
					if (Vector3.new(a.X, 0, a.Z) - Vector3.new(pos.X, 0, pos.Z)).Magnitude < 2.8 then
						clear = false
						break
					end
				end
				if clear then
					table.insert(slots, { pos = pos, top = top })
				end
			end
			x += SEAT_SPACING
		end
	end
	-- Keep the rows nearest the stage fuller; those are the ones on camera.
	table.sort(slots, function(a, b)
		return a.pos.Z < b.pos.Z
	end)
	for i, slot in slots do
		if #extras >= MAX_EXTRAS then
			break
		end
		local keep = if i <= 18 then 0.85 else 0.55
		if math.random() < keep then
			local actor = CutsceneActors.spawn({
				source = sources[math.random(#sources)],
				parent = parent,
				cframe = CFrame.new(slot.pos + V(0, 3, 0)),
				repaint = true,
			})
			if actor then
				CutsceneActors.seat(actor, slot.pos, V(0, 0, -1), slot.top)
				table.insert(extras, {
					actor = actor,
					pos = slot.pos,
					member = {
						seed = math.random() * 100,
						lean = math.random() * 2 - 1,
						phone = math.random() < 0.12,
						keen = math.random(),
					},
				})
			end
		end
	end
	return extras
end

--- Pick the armpit-sniffer: someone in the first two rows near the centre,
--- and mark whoever sits right beside them.
function Audience.castSniffer(extras: { Extra }, cx: number): Extra?
	local best: Extra? = nil
	local bestScore = math.huge
	for _, e in extras do
		local score = math.abs(e.pos.X - (cx + 12)) + (e.pos.Z + 64) * 2
		if not e.member.phone and score < bestScore then
			best = e
			bestScore = score
		end
	end
	if best then
		best.member.sniffer = true
		for _, e in extras do
			if e ~= best and math.abs(e.pos.Z - best.pos.Z) < 1 and math.abs(e.pos.X - best.pos.X) < SEAT_SPACING * 1.6 then
				e.member.neighbourOfSniffer = if e.pos.X < best.pos.X then 1 else -1
				e.member.phone = false
			end
		end
	end
	return best
end

return Audience
