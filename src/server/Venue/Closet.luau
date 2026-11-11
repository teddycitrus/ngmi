--!strict
--------------------------------------------------------------------------------
-- Closet.luau
-- A tall storage closet a player can hide in on Night 2: a plain cabinet
-- shell with a louvered door on a hinge. Through the slats a hidden player
-- can still see out (and the light from the room falls in stripes).
--
-- The hiding itself is InteractionManager's: the "HideSpot" part inside is
-- tagged HidingSpot with Closet = true, and carries the CFrames it needs as
-- attributes (InsideCF is where the player stands, ExitCF where they step
-- out). The door is the "Door" model; `Closet.setDoor` swings it about its
-- hinge. Doors start ajar, the way a closet nobody is in looks.
--------------------------------------------------------------------------------

local Kit = require(script.Parent.Kit)

local V = Vector3.new
local CF = CFrame.new
local M = Enum.Material

local Closet = {}

Closet.W = 4.4 -- outside width
Closet.D = 3.2 -- outside depth
Closet.H = 8.2 -- outside height
Closet.AJAR = math.rad(68) -- how far an empty closet's door stands open

local BODY = Color3.fromRGB(142, 146, 150)
local DOOR = Color3.fromRGB(150, 154, 158)
local DARK = Color3.fromRGB(34, 36, 40)

--- Build a closet. `cf` sits at floor level in the middle of the footprint,
--- LookVector pointing out of the door into the room.
function Closet.build(parent: Instance, cf: CFrame): Model
	local W, D, H = Closet.W, Closet.D, Closet.H
	local m = Kit.model("Closet")
	m.PrimaryPart.CFrame = cf
	local t = 0.18 -- panel thickness
	local function panel(name: string, size: Vector3, at: Vector3, color: Color3?)
		return Kit.part(m, name, size, cf * CF(at), color or BODY, M.Metal)
	end
	-- Front is local -Z (the LookVector side).
	panel("ClosetBack", V(W, H, t), V(0, H / 2, D / 2 - t / 2))
	panel("ClosetSide", V(t, H, D - t), V(-(W / 2 - t / 2), H / 2, -t / 2))
	panel("ClosetSide", V(t, H, D - t), V(W / 2 - t / 2, H / 2, -t / 2))
	panel("ClosetTop", V(W - 2 * t, t, D - t), V(0, H - t / 2, -t / 2))
	panel("ClosetPlinth", V(W - 2 * t, 0.35, D - t), V(0, 0.175, -t / 2), DARK)
	-- the dark inside face of the back, a hair proud of the back panel
	Kit.trim(m, "ClosetInner", V(W - 2 * t - 0.02, H - 0.6, 0.04), cf * CF(0, H / 2, D / 2 - t - 0.03), DARK, M.SmoothPlastic)

	-- The door: a frame with angled slats, hinged on the left front edge.
	local door = Instance.new("Model")
	door.Name = "Door"
	local dw, dh = W - 2 * t - 0.06, H - 0.35 - t - 0.06
	local hingeLocal = V(-(W / 2 - t), 0.35 + 0.03 + dh / 2, -D / 2 + 0.09)
	local hinge = Kit.trim(door, "Hinge", V(0.2, dh, 0.2), cf * CF(hingeLocal), DARK, M.Metal)
	hinge.Transparency = 1
	door.PrimaryPart = hinge
	local function dpart(name: string, size: Vector3, offX: number, offY: number, angle: number?)
		local at = cf * CF(hingeLocal + V(offX, offY, 0)) * CFrame.Angles(angle or 0, 0, 0)
		return Kit.part(door, name, size, at, DOOR, M.Metal)
	end
	local stile = 0.4
	dpart("DoorStile", V(stile, dh, 0.14), stile / 2, 0)
	dpart("DoorStile", V(stile, dh, 0.14), dw - stile / 2, 0)
	dpart("DoorRail", V(dw - 2 * stile, 0.5, 0.14), dw / 2, dh / 2 - 0.25)
	dpart("DoorRail", V(dw - 2 * stile, 0.9, 0.14), dw / 2, -dh / 2 + 0.45)
	local slatTop, slatBottom = dh / 2 - 0.6, -dh / 2 + 1.0
	local n = 16
	for i = 0, n - 1 do
		local y = slatTop - (slatTop - slatBottom) * (i + 0.5) / n
		-- slats tipped down outward, like a vent: you see out, not in
		dpart("DoorSlat", V(dw - 2 * stile, 0.2, 0.08), dw / 2, y, math.rad(-35))
	end
	Kit.trim(door, "DoorHandle", V(0.12, 0.7, 0.12), cf * CF(hingeLocal + V(dw - 0.5, 0, -0.14)), DARK, M.Metal)
	door.Parent = m
	door:SetAttribute("ClosedCF", hinge.CFrame)

	-- Where the player goes, as attributes for InteractionManager.
	local spot = Kit.part(m, "HideSpot", V(W - 1, 5, D - 1), cf * CF(0, 3, 0.15), Color3.new(), nil, { collide = false, transparency = 1 })
	spot.CanQuery = false
	spot:SetAttribute("Closet", true)
	spot:SetAttribute("InsideCF", cf * CF(0, 3.3, 0.2))
	spot:SetAttribute("ExitCF", cf * CF(0, 3, -D / 2 - 2.2))
	Kit.tag(spot, Kit.TAGS.HIDING_SPOT)

	m.Parent = parent
	Closet.setDoor(m, Closet.AJAR)
	return m
end

--- Swing the door to `angle` radians open (0 = shut), instantly.
function Closet.setDoor(closet: Model, angle: number)
	local door = closet:FindFirstChild("Door")
	local closed = door and door:GetAttribute("ClosedCF")
	if door and door:IsA("Model") and typeof(closed) == "CFrame" then
		-- opens outward: the free edge swings toward the room (-Z)
		door:PivotTo(closed * CFrame.Angles(0, angle, 0))
		door:SetAttribute("Angle", angle)
	end
end

--- Swing the door to `angle` over `dur` seconds.
function Closet.swing(closet: Model, angle: number, dur: number)
	local door = closet:FindFirstChild("Door")
	if not door then
		return
	end
	local from = (door:GetAttribute("Angle") :: number?) or 0
	task.spawn(function()
		local steps = math.max(1, math.floor(dur * 30))
		for i = 1, steps do
			local u = i / steps
			Closet.setDoor(closet, from + (angle - from) * (u * u * (3 - 2 * u)))
			task.wait(dur / steps)
		end
	end)
end

return Closet
