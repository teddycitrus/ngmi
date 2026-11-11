--!strict
--------------------------------------------------------------------------------
-- Director.luau
-- Where an NGMI goes on the last night when nothing has its attention.
--
-- Every NGMI belongs to the floor it spawned on. At first they all make
-- their way out to that floor's central corridor and take up a post along
-- it: the corridor is cut into one span per NGMI on the floor, and each
-- stands somewhere in its own span at a fixed random offset, so the line is
-- evenly spread but never single file. A player walking the corridor sees
-- them spaced out down its length in the dark.
--
-- Then the floor starts coming for you. After GATHER_TIME, a growing share
-- of the NGMIs on each floor with a player on it leave their posts and
-- stalk toward the nearest player on that floor, re-pathing as they move.
-- The share ramps from one NGMI to all of them over RAMP_TIME, so the night
-- gets steadily worse instead of all at once. Hidden players are stalked to
-- somewhere near their hiding spot, never straight to it.
--
-- NGMIController owns movement and the state machine; this only picks goals.
--------------------------------------------------------------------------------

local Players = game:GetService("Players")

local Director = {}

local LEVEL_H = 18
-- The central corridor (Venue/Layout: Z +-9, elevators at X -148, stair
-- shaft from X 130), kept a little clear of the walls and both ends.
local CORR_X0, CORR_X1 = -140, 122
local CORR_Z = 5.5

Director.GATHER_TIME = 70
Director.RAMP_TIME = 540
Director.ARRIVE = 3.5 -- studs from a post that counts as arrived
Director.LOITER = 3 -- shuffle radius around a post
Director.HIDDEN_FUZZ = 12 -- how close stalkers get to a hiding spot

export type Agent = {
	rootPart: BasePart,
	level: number,
	jx: number, -- -1..1, where in its span along the corridor
	jz: number, -- -1..1, across the corridor
	post: Vector3?,
	stalking: Player?,
	fuzz: Vector3, -- offset used while stalking a hidden player
}

function Director.levelOf(y: number): number
	return math.clamp(math.floor((y + 2) / LEVEL_H), 0, 2)
end

function Director.newAgent(rootPart: BasePart): Agent
	return {
		rootPart = rootPart,
		level = Director.levelOf(rootPart.Position.Y),
		jx = math.random() * 2 - 1,
		jz = math.random() * 2 - 1,
		post = nil,
		stalking = nil,
		fuzz = Vector3.zero,
	}
end

--- Live players who can be stalked, by floor.
local function playersByLevel(): { [number]: { { player: Player, root: BasePart } } }
	local out: { [number]: { { player: Player, root: BasePart } } } = { [0] = {}, [1] = {}, [2] = {} }
	for _, player in Players:GetPlayers() do
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local spared = player:GetAttribute("NightEncounter") == true or player:GetAttribute("NightGrace") == true
		if hum and hum.Health > 0 and root and root:IsA("BasePart") and not spared then
			table.insert(out[Director.levelOf(root.Position.Y)], { player = player, root = root })
		end
	end
	return out
end

--- Re-deal posts and stalkers. Cheap; call about once a second.
function Director.update(agents: { Agent }, elapsed: number)
	local byLevel: { [number]: { Agent } } = { [0] = {}, [1] = {}, [2] = {} }
	for _, a in agents do
		table.insert(byLevel[a.level], a)
	end
	local players = playersByLevel()
	local pressure = math.clamp((elapsed - Director.GATHER_TIME) / Director.RAMP_TIME, 0, 1)

	for level, list in byLevel do
		local n = #list
		if n == 0 then
			continue
		end

		-- Stalkers: the share of this floor that is hunting, closest first.
		-- Anyone already stalking keeps at it while the share allows, so the
		-- pack does not reshuffle every second.
		local here = players[level]
		local want = if pressure > 0 and #here > 0 then math.max(1, math.ceil(pressure * n)) else 0
		local function nearest(a: Agent): (Player?, number)
			local best, bestD = nil, math.huge
			for _, p in here do
				local d = (p.root.Position - a.rootPart.Position).Magnitude
				if d < bestD then
					best, bestD = p.player, d
				end
			end
			return best, bestD
		end
		local ranked: { { a: Agent, d: number, p: Player? } } = {}
		for _, a in list do
			local p, d = nearest(a)
			-- incumbents rank first
			table.insert(ranked, { a = a, p = p, d = if a.stalking then d - 1e6 else d })
		end
		table.sort(ranked, function(u, v)
			return u.d < v.d
		end)
		for i, r in ranked do
			local now = if i <= want then r.p else nil
			if now ~= r.a.stalking then
				r.a.fuzz = Vector3.new(math.random() * 2 - 1, 0, math.random() * 2 - 1).Unit * Director.HIDDEN_FUZZ
			end
			r.a.stalking = now
		end

		-- Posts for the rest: one span each, dealt in order of where they
		-- stand now so nobody crosses the corridor past the others. When a
		-- stalker leaves, the line re-spreads to cover the gap.
		local posted: { Agent } = {}
		for _, a in list do
			if not a.stalking then
				table.insert(posted, a)
			end
		end
		table.sort(posted, function(a, b)
			return a.rootPart.Position.X < b.rootPart.Position.X
		end)
		local span = (CORR_X1 - CORR_X0) / math.max(#posted, 1)
		local y = level * LEVEL_H + 3
		for i, a in posted do
			local x = CORR_X0 + span * (i - 0.5) + a.jx * span * 0.32
			a.post = Vector3.new(x, y, a.jz * CORR_Z)
		end
	end
end

--- Where this agent should be heading right now, and whether that is a
--- stalk (keep moving) or a post (loiter on arrival).
function Director.goal(a: Agent): (Vector3?, boolean)
	local p = a.stalking
	if p then
		local char = p.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local pos = root.Position
			if p:GetAttribute("Hiding") == true then
				pos += a.fuzz
			end
			return pos, true
		end
		a.stalking = nil
	end
	return a.post, false
end

return Director
