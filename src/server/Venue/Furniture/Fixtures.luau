--!strict
--------------------------------------------------------------------------------
-- Fixtures.luau
-- Restroom fixtures and the hallway furniture of a university building:
-- lockers, bookshelves, fountains, trophy case, benches, bins and the small
-- wall-hung bits (extinguisher cabinet, clock, hand dryer).
--
-- Origin at floor level, front facing -Z. Wall-hung pieces (Urinal,
-- WaterFountain, NoticeBoard, FireCabinet, Clock, HandDryer) have their back
-- on the origin plane; the rest are centred on their footprint.
--------------------------------------------------------------------------------

local Kit = require(script.Parent.Parent.Kit)

local COLORS = Kit.COLORS
local V = Vector3.new
local CF = CFrame.new
local M = Enum.Material

local DARK = Color3.fromRGB(34, 35, 40)
local CHROME = Color3.fromRGB(196, 200, 206)
local PORCELAIN = COLORS.TOILET

-- Toilet: tank on the +Z wall side, bowl toward -Z.
local function toilet(): Model
	local m = Kit.model("Toilet")
	Kit.part(m, "Pedestal", V(1.0, 1.0, 1.2), CF(0, 0.5, 0.2), PORCELAIN, M.SmoothPlastic)
	Kit.blob(m, "Bowl", V(1.6, 0.9, 2.0), CF(0, 1.15, -0.2), PORCELAIN, M.SmoothPlastic, { collide = false })
	Kit.blob(m, "SeatRing", V(1.7, 0.14, 2.0), CF(0, 1.62, -0.22), Color3.fromRGB(232, 232, 236), M.SmoothPlastic, { collide = false })
	Kit.trim(m, "Lid", V(1.5, 1.7, 0.1), CF(0, 2.3, 0.58) * CFrame.Angles(math.rad(-12), 0, 0), Color3.fromRGB(232, 232, 236), M.SmoothPlastic)
	Kit.part(m, "Tank", V(1.8, 1.4, 0.7), CF(0, 2.15, 0.98), PORCELAIN, M.SmoothPlastic)
	Kit.trim(m, "TankLid", V(1.9, 0.14, 0.8), CF(0, 2.92, 0.98), PORCELAIN:Lerp(Color3.new(), 0.04), M.SmoothPlastic)
	Kit.trim(m, "Handle", V(0.42, 0.08, 0.1), CF(-0.65, 2.62, 0.6), CHROME, M.Metal)
	Kit.cylZ(m, "Supply", 0.6, 0.1, CF(0.55, 0.9, 1.35), CHROME, M.Metal, { collide = false })
	return m
end

local function urinal(): Model
	local m = Kit.model("Urinal")
	Kit.blob(m, "Body", V(1.6, 2.9, 1.3), CF(0, 3.0, -0.4), PORCELAIN, M.SmoothPlastic)
	Kit.blob(m, "Basin", V(1.2, 2.0, 0.5), CF(0, 2.8, -0.9), Color3.fromRGB(214, 218, 224), M.SmoothPlastic, { collide = false })
	Kit.cylY(m, "FlushPipe", 1.0, 0.14, CF(0, 5.0, -0.25), CHROME, M.Metal, { collide = false })
	Kit.blob(m, "FlushValve", V(0.36, 0.36, 0.36), CF(0, 4.4, -0.3), CHROME, M.Metal, { collide = false })
	Kit.trim(m, "Lever", V(0.36, 0.06, 0.06), CF(0.2, 4.4, -0.45), CHROME, M.Metal)
	Kit.cylZ(m, "Drain", 0.5, 0.18, CF(0, 1.55, -0.2), CHROME, M.Metal, { collide = false })
	return m
end

--- Four tall school lockers, one door left ajar.
local function locker(): Model
	local m = Kit.model("Locker")
	local body = Color3.fromRGB(70, 92, 112)
	Kit.part(m, "Body", V(8, 7, 2), CF(0, 3.9, 0.02), body, M.Metal)
	Kit.part(m, "Base", V(8, 0.4, 1.9), CF(0, 0.2, 0.05), DARK, M.Metal)
	Kit.trim(m, "Crown", V(8.1, 0.2, 2.1), CF(0, 7.5, 0), body:Lerp(Color3.new(), 0.25), M.Metal)
	for i = 0, 3 do
		local x = -3 + i * 2
		local hinge = CF(x - 0.93, 0, -1.03)
		local swing = if i == 2 then math.rad(28) else 0
		local door = hinge * CFrame.Angles(0, swing, 0) * CF(0.93, 0, 0)
		Kit.trim(m, "Door", V(1.84, 6.6, 0.07), door * CF(0, 3.85, 0), body:Lerp(Color3.new(1, 1, 1), 0.08), M.Metal)
		for v = 0, 2 do
			Kit.trim(m, "Vent", V(1.1, 0.06, 0.04), door * CF(0, 6.6 - v * 0.2, -0.05), DARK, M.Metal)
			Kit.trim(m, "Vent", V(1.1, 0.06, 0.04), door * CF(0, 1.3 - v * 0.2, -0.05), DARK, M.Metal)
		end
		Kit.trim(m, "Latch", V(0.24, 0.7, 0.1), door * CF(0.6, 3.8, -0.06), CHROME, M.Metal)
		Kit.trim(m, "NumberPlate", V(0.5, 0.22, 0.03), door * CF(0, 5.9, -0.05), CHROME, M.Metal)
		if i == 2 then
			Kit.trim(m, "Interior", V(1.84, 6.6, 0.05), CF(x, 3.85, -0.98), Color3.fromRGB(28, 30, 34), M.Metal)
			Kit.blob(m, "Hoodie", V(1.3, 2.4, 0.6), CF(x, 4.6, -0.5), Color3.fromRGB(120, 40, 50), M.Fabric, { collide = false })
		end
	end
	return m
end

local function bookshelf(): Model
	local m = Kit.model("Bookshelf")
	local wood = Color3.fromRGB(104, 74, 48)
	Kit.part(m, "Back", V(6, 9, 0.3), CF(0, 4.5, 0.83), wood:Lerp(Color3.new(), 0.2), M.Wood)
	for _, sx in { -1, 1 } do
		Kit.part(m, "Side", V(0.35, 9, 2), CF(sx * 2.85, 4.5, 0), wood, M.Wood)
	end
	Kit.trim(m, "Crown", V(6.4, 0.35, 2.2), CF(0, 9.1, 0), wood:Lerp(Color3.new(), 0.1), M.Wood)
	local cols = {
		Color3.fromRGB(150, 50, 46),
		Color3.fromRGB(52, 80, 140),
		Color3.fromRGB(60, 120, 72),
		Color3.fromRGB(190, 150, 60),
		Color3.fromRGB(120, 72, 140),
		Color3.fromRGB(84, 84, 94),
		Color3.fromRGB(220, 214, 196),
	}
	for s = 0, 3 do
		local sy = 0.5 + s * 2.2
		Kit.part(m, "Shelf", V(5.4, 0.25, 1.8), CF(0, sy, 0), wood, M.Wood)
		local x = -2.55
		local n = 0
		while x < 2.3 do
			n += 1
			local w = 0.4 + math.random() * 0.4
			local h = 1.1 + math.random() * 0.6
			local lean = if n % 9 == 0 then math.rad(14) else 0
			Kit.trim(m, "Book", V(w, h, 1.3), CF(x + w / 2, sy + 0.12 + h / 2, -0.1) * CFrame.Angles(0, 0, lean), Kit.pick(cols), M.SmoothPlastic)
			x += w + 0.03 + (if lean > 0 then 0.35 else 0)
			if s == 2 and n == 6 then
				-- a flat stack partway along one shelf
				for k = 0, 2 do
					Kit.trim(m, "Book", V(1.3, 0.24, 1.1), CF(x + 0.7, sy + 0.25 + k * 0.25, -0.1) * CFrame.Angles(0, math.rad(k * 7), 0), Kit.pick(cols), M.SmoothPlastic)
				end
				x += 1.5
			end
		end
	end
	return m
end

--- Stainless drinking fountain with a bottle filler above it.
local function waterFountain(): Model
	local m = Kit.model("WaterFountain")
	local steel = Color3.fromRGB(180, 184, 190)
	Kit.part(m, "Basin", V(2.4, 1.1, 1.6), CF(0, 3.3, -0.8), steel, M.Metal, { reflectance = 0.06 })
	Kit.trim(m, "Bowl", V(1.9, 0.08, 1.1), CF(0, 3.86, -0.85), Color3.fromRGB(110, 114, 120), M.Metal)
	Kit.blob(m, "Bubbler", V(0.24, 0.24, 0.3), CF(0.5, 3.98, -0.7), CHROME, M.Metal, { collide = false })
	Kit.trim(m, "Shroud", V(1.3, 1.9, 0.5), CF(0, 1.8, -0.25), steel:Lerp(Color3.new(), 0.1), M.Metal)
	Kit.part(m, "Filler", V(2.0, 2.6, 0.5), CF(0, 5.7, -0.25), steel, M.Metal)
	Kit.trim(m, "FillerRecess", V(1.4, 1.6, 0.06), CF(0, 5.5, -0.52), Color3.fromRGB(60, 64, 70), M.Metal)
	Kit.trim(m, "Counter", V(1.4, 0.3, 0.06), CF(0, 6.68, -0.52), Color3.fromRGB(40, 160, 80), M.Neon)
	return m
end

local function noticeBoard(): Model
	local m = Kit.model("NoticeBoard")
	Kit.part(m, "Frame", V(7, 5, 0.25), CF(0, 6, -0.13), COLORS.WOOD_TRIM, M.Wood)
	Kit.trim(m, "Cork", V(6.5, 4.5, 0.08), CF(0, 6, -0.28), COLORS.CORK, M.Fabric)
	local notes = {
		{ "LF teammate\nfrontend pls", Color3.fromRGB(250, 240, 160) },
		{ "LOST:\nUSB-C cable", Color3.fromRGB(220, 235, 250) },
		{ "pizza\n3rd floor", Color3.fromRGB(250, 214, 220) },
		{ "", Color3.fromRGB(226, 246, 220) },
		{ "rm -rf\nregrets", Color3.fromRGB(245, 245, 240) },
		{ "", Color3.fromRGB(250, 240, 160) },
		{ "WHO TOOK\nMY CHAIR", Color3.fromRGB(245, 245, 240) },
	}
	for i, n in notes do
		local x = -2.6 + ((i - 1) % 4) * 1.75 + (math.random() - 0.5) * 0.4
		local y = 7.1 - math.floor((i - 1) / 4) * 2.1 + (math.random() - 0.5) * 0.3
		local note = Kit.trim(m, "Note", V(1.3, 1.3, 0.03), CF(x, y, -0.34) * CFrame.Angles(0, 0, math.rad(math.random(-9, 9))), n[2], M.SmoothPlastic)
		if n[1] ~= "" and i <= 3 then
			Kit.label(note, Enum.NormalId.Front, n[1], Color3.fromRGB(40, 40, 60), nil, Enum.Font.PermanentMarker)
		end
		Kit.blob(m, "Pin", V(0.14, 0.14, 0.14), CF(x, y + 0.5, -0.38), Kit.pick({ Color3.fromRGB(220, 40, 40), Color3.fromRGB(40, 90, 220) }), M.SmoothPlastic, { collide = false })
	end
	return m
end

--- Glass trophy cabinet on a wooden base, lit from inside.
local function trophyCase(): Model
	local m = Kit.model("TrophyCase")
	local wood = Color3.fromRGB(72, 50, 34)
	Kit.part(m, "Cabinet", V(6, 3, 2.2), CF(0, 1.5, 0), wood, M.Wood)
	Kit.trim(m, "Kick", V(5.8, 0.3, 2.0), CF(0, 0.15, 0.08), DARK, M.Wood)
	Kit.part(m, "Cap", V(6.2, 0.4, 2.4), CF(0, 8.2, 0), wood, M.Wood)
	Kit.trim(m, "Backing", V(5.8, 5, 0.1), CF(0, 5.5, 1.0), COLORS.UNI_MAROON, M.Fabric)
	for _, sx in { -1, 1 } do
		Kit.trim(m, "Post", V(0.2, 5, 0.2), CF(sx * 2.9, 5.5, -1.0), wood, M.Wood)
		Kit.part(m, "SideGlass", V(0.08, 5, 2), CF(sx * 2.95, 5.5, 0), COLORS.GLASS, M.Glass, { transparency = 0.6 })
	end
	Kit.part(m, "Glass", V(5.6, 5, 0.08), CF(0, 5.5, -1.05), COLORS.GLASS, M.Glass, { transparency = 0.6, reflectance = 0.1 })
	local strip = Kit.trim(m, "Strip", V(5.4, 0.08, 0.2), CF(0, 7.94, -0.4), Color3.fromRGB(255, 236, 190), M.Neon)
	Kit.light(strip, 0.4, 7, Color3.fromRGB(255, 226, 170)).Shadows = false
	Kit.trim(m, "GlassShelf", V(5.6, 0.08, 1.8), CF(0, 5.6, 0), COLORS.GLASS, M.Glass, { transparency = 0.5 })
	for level, sy in { 3.0, 5.64 } do
		for t = -1, 1 do
			local x = t * 1.7
			local gold = if (t + level) % 3 == 0 then Color3.fromRGB(192, 192, 200) else COLORS.UNI_GOLD
			Kit.trim(m, "TrophyBase", V(0.7, 0.4, 0.7), CF(x, sy + 0.2, 0), DARK, M.Marble)
			Kit.cylY(m, "Stem", 0.6, 0.14, CF(x, sy + 0.7, 0), gold, M.Metal, { collide = false })
			Kit.cylY(m, "Cup", 0.7, 0.6, CF(x, sy + 1.3, 0), gold, M.Metal, { collide = false })
			for _, hx in { -1, 1 } do
				Kit.cylZ(m, "Handle", 0.06, 0.34, CF(x + hx * 0.38, sy + 1.35, 0), gold, M.Metal, { collide = false })
			end
		end
	end
	return m
end

--- Slatted hallway bench. The invisible Seat makes it sittable.
local function bench(): Model
	local m = Kit.model("Bench")
	local wood = Color3.fromRGB(150, 108, 66)
	local seat = Kit.seat(m, "Seat", V(5.6, 0.3, 1.4), CF(0, 1.58, -0.1), wood, M.Wood)
	seat.Transparency = 1
	for i = -1, 1 do
		Kit.trim(m, "Slat", V(6, 0.16, 0.42), CF(0, 1.65, -0.1 + i * 0.48), wood, M.Wood)
	end
	for _, sx in { -1, 1 } do
		Kit.trim(m, "Frame", V(0.2, 1.54, 1.5), CF(sx * 2.6, 0.77, -0.05), DARK, M.Metal)
		Kit.trim(m, "BackPost", V(0.2, 1.6, 0.2), CF(sx * 2.6, 2.34, 0.65) * CFrame.Angles(math.rad(10), 0, 0), DARK, M.Metal)
	end
	for _, y in { 2.29, 2.84 } do
		Kit.trim(m, "BackSlat", V(6, 0.36, 0.14), CF(0, y, 0.72) * CFrame.Angles(math.rad(10), 0, 0), wood, M.Wood)
	end
	return m
end

--- Landfill and recycling bins side by side.
local function trashBin(): Model
	local m = Kit.model("TrashBin")
	for i, spec in { { -0.78, Color3.fromRGB(70, 72, 78) }, { 0.78, Color3.fromRGB(40, 96, 170) } } do
		local x = spec[1] :: number
		local c = spec[2] :: Color3
		Kit.part(m, "Bin", V(1.45, 2.8, 1.4), CF(x, 1.4, 0), c, M.SmoothPlastic)
		Kit.trim(m, "BinLid", V(1.55, 0.2, 1.5), CF(x, 2.9, 0), c:Lerp(Color3.new(), 0.25), M.SmoothPlastic)
		Kit.cylY(m, "Opening", 0.04, 0.8, CF(x, 3.01, -0.1), DARK, M.SmoothPlastic, { collide = false })
		-- a band rather than a printed label: SurfaceGuis are budgeted
		Kit.trim(m, "BinBand", V(1.47, 0.3, 1.42), CF(x, 2.3, 0), if i == 1 then Color3.fromRGB(200, 200, 196) else Color3.new(1, 1, 1), M.SmoothPlastic)
	end
	return m
end

local function fireCabinet(): Model
	local m = Kit.model("FireCabinet")
	local red = Color3.fromRGB(176, 30, 30)
	Kit.part(m, "Box", V(1.9, 3.0, 0.4), CF(0, 4.6, -0.2), red, M.Metal)
	Kit.trim(m, "Inside", V(1.6, 2.4, 0.05), CF(0, 4.45, -0.42), Color3.fromRGB(230, 230, 226), M.SmoothPlastic)
	Kit.cylY(m, "Extinguisher", 1.7, 0.6, CF(0, 4.2, -0.5), Color3.fromRGB(200, 30, 30), M.SmoothPlastic, { collide = false })
	Kit.trim(m, "Nozzle", V(0.12, 0.5, 0.12), CF(0.25, 5.2, -0.55), DARK, M.Rubber)
	Kit.part(m, "Glass", V(1.7, 2.6, 0.04), CF(0, 4.45, -0.48), COLORS.GLASS, M.Glass, { transparency = 0.6, collide = false })
	Kit.trim(m, "Label", V(1.9, 0.4, 0.04), CF(0, 6.35, -0.06), Color3.fromRGB(236, 236, 232), M.SmoothPlastic)
	return m
end

local function clock(): Model
	local m = Kit.model("Clock")
	Kit.cylZ(m, "Rim", 0.24, 2.0, CF(0, 0, -0.12), DARK, M.SmoothPlastic, { collide = false })
	Kit.cylZ(m, "Face", 0.06, 1.75, CF(0, 0, -0.26), Color3.fromRGB(245, 245, 240), M.SmoothPlastic, { collide = false })
	for i = 0, 11 do
		local a = math.rad(i * 30)
		Kit.trim(m, "Tick", V(0.06, if i % 3 == 0 then 0.24 else 0.12, 0.03), CF(0, 0, -0.3) * CFrame.Angles(0, 0, a) * CF(0, 0.72, 0), DARK, M.SmoothPlastic)
	end
	-- 3:47. Always 3:47.
	Kit.trim(m, "HourHand", V(0.08, 0.5, 0.03), CF(0, 0, -0.32) * CFrame.Angles(0, 0, math.rad(-113)) * CF(0, 0.22, 0), DARK, M.SmoothPlastic)
	Kit.trim(m, "MinuteHand", V(0.06, 0.7, 0.03), CF(0, 0, -0.34) * CFrame.Angles(0, 0, math.rad(-282)) * CF(0, 0.32, 0), DARK, M.SmoothPlastic)
	-- the model's origin is the clock centre; lift it to its hanging height
	for _, d in m:GetChildren() do
		if d:IsA("BasePart") and d.Name ~= "Root" then
			d.CFrame = CF(0, 11, 0) * d.CFrame
		end
	end
	return m
end

local function handDryer(): Model
	local m = Kit.model("HandDryer")
	Kit.blob(m, "Body", V(1.3, 1.6, 0.9), CF(0, 4.6, -0.42), Color3.fromRGB(236, 238, 240), M.SmoothPlastic)
	Kit.trim(m, "Nozzle", V(0.4, 0.3, 0.3), CF(0, 3.85, -0.6), CHROME, M.Metal)
	return m
end

return {
	builders = {
		Toilet = toilet,
		Urinal = urinal,
		Locker = locker,
		Bookshelf = bookshelf,
		WaterFountain = waterFountain,
		NoticeBoard = noticeBoard,
		TrophyCase = trophyCase,
		Bench = bench,
		TrashBin = trashBin,
		FireCabinet = fireCabinet,
		Clock = clock,
		HandDryer = handDryer,
	} :: { [string]: () -> Model },
}
