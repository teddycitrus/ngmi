--!strict
--------------------------------------------------------------------------------
-- Opening/Audience.luau
-- The seated crowd for OpeningCinematic: finds the auditorium benches, seats
-- local extras along them (clear of the real NPCs), picks the pairs who
-- chat, and stands in for the seated named NPCs.
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

export type Extra = { actor: CutsceneActors.Actor, member: SpeakerChoreo.Member, pos: Vector3, id: string? }

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
				local member: SpeakerChoreo.Member = {
					seed = math.random() * 100,
					lean = math.random() * 2 - 1,
					phone = math.random() < 0.12,
					keen = math.random(),
				}
				SpeakerChoreo.fitClap(actor.rig, member)
				SpeakerChoreo.fitSeat(actor.rig, member)
				table.insert(extras, {
					actor = actor,
					pos = slot.pos,
					member = member,
				})
			end
		end
	end
	return extras
end

--- Pair up a few neighbours (front rows first, where the camera is) who chat
--- among themselves through the talk.
function Audience.castChatters(extras: { Extra }, count: number)
	local free: { Extra } = table.clone(extras)
	table.sort(free, function(a, b)
		if math.abs(a.pos.Z - b.pos.Z) > 1 then
			return a.pos.Z < b.pos.Z
		end
		return a.pos.X < b.pos.X
	end)
	local made = 0
	local i = 1
	while i < #free and made < count do
		local a, b = free[i], free[i + 1]
		if math.abs(a.pos.Z - b.pos.Z) < 1 and math.abs(a.pos.X - b.pos.X) < SEAT_SPACING * 1.6 and math.random() < 0.6 then
			-- the audience faces -Z, so a neighbour at higher X is on the right (neck yaw -)
			local seed = math.random() * 10
			a.member.chat, b.member.chat = -1, 1
			a.member.chatSeed, b.member.chatSeed = seed, seed
			a.member.chatLead = true
			a.member.phone, b.member.phone = false, false
			made += 1
			i += 3 -- leave a gap so pairs don't run together along a row
		else
			i += 1
		end
	end
end

--- The seated named NPCs play the server's sit animation, and RigPose offsets
--- layer under an animation, so poses on them never landed where intended
--- (their claps never met). For the scene each one is hidden locally and a
--- look-alike actor sits in its place, posed like the rest of the crowd.
--- Returns the stand-ins and a function that puts the real NPCs back.
function Audience.standIns(parent: Instance, ids: { string }): ({ Extra }, () -> ())
	local out: { Extra } = {}
	local hidden: { [BasePart]: number } = {}
	local names: { [Humanoid]: Enum.HumanoidDisplayDistanceType } = {}
	local npcs = workspace:FindFirstChild("NPCs")
	local map = workspace:FindFirstChild("Map")
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { map :: Instance }
	for _, id in ids do
		local npc = npcs and npcs:FindFirstChild(id)
		local root = npc and npc:FindFirstChild("HumanoidRootPart")
		if not (map and npc and npc:IsA("Model") and root and root:IsA("BasePart")) then
			continue
		end
		local hit = workspace:Raycast(root.Position, V(0, -6, 0), params)
		local actor = hit and CutsceneActors.spawn({ source = npc, parent = parent, cframe = npc:GetPivot() })
		if not (hit and actor) then
			continue
		end
		local pos = V(root.Position.X, hit.Position.Y, root.Position.Z)
		CutsceneActors.seat(actor, pos, root.CFrame.LookVector, hit.Position.Y)
		table.insert(out, {
			actor = actor,
			pos = pos,
			id = id,
			member = { seed = math.random() * 100, lean = math.random() * 0.6 - 0.3, phone = false, keen = 1 },
		})
		SpeakerChoreo.fitClap(actor.rig, out[#out].member)
		SpeakerChoreo.fitSeat(actor.rig, out[#out].member)
		for _, d in npc:GetDescendants() do
			if d:IsA("BasePart") then
				hidden[d] = d.LocalTransparencyModifier
				d.LocalTransparencyModifier = 1
			end
		end
		local hum = npc:FindFirstChildOfClass("Humanoid")
		if hum then
			names[hum] = hum.DisplayDistanceType
			hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		end
	end
	return out, function()
		for part, was in hidden do
			part.LocalTransparencyModifier = was
		end
		for hum, was in names do
			hum.DisplayDistanceType = was
		end
	end
end

return Audience
