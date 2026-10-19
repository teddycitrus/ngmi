--[[
	Z-fight detector for the procedural venue. Paste into Studio's command bar
	(or run through the Studio MCP execute_luau tool) after workspace.Map exists,
	either in a Play session or after an Edit-mode preview build.

	Finds pairs of block parts whose faces share a plane, face the same way and
	overlap, then keeps only the pairs where the point just in front of the shared
	face is open air (a face buried inside another part can't flicker). Prints a
	count and the worst offenders by part-name pair, with a sample location.
]]

local map = workspace:FindFirstChild("Map")
assert(map, "no workspace.Map")

local buckets = {}
local function aligned(cf)
	for _, v in { cf.RightVector, cf.UpVector, cf.LookVector } do
		if math.max(math.abs(v.X), math.abs(v.Y), math.abs(v.Z)) < 0.9999 then
			return false
		end
	end
	return true
end

for _, p in map:GetDescendants() do
	if
		p:IsA("Part")
		and p.Shape == Enum.PartType.Block
		and p.Transparency < 0.99
		and not p:FindFirstChildOfClass("SpecialMesh")
		and aligned(p.CFrame)
	then
		local half, c, cf = p.Size / 2, p.Position, p.CFrame
		local e = {}
		for i, comp in { "X", "Y", "Z" } do
			e[i] = math.abs(cf.RightVector[comp]) * half.X
				+ math.abs(cf.UpVector[comp]) * half.Y
				+ math.abs(cf.LookVector[comp]) * half.Z
		end
		local mn = { c.X - e[1], c.Y - e[2], c.Z - e[3] }
		local mx = { c.X + e[1], c.Y + e[2], c.Z + e[3] }
		for a = 1, 3 do
			local b1, b2 = a % 3 + 1, (a + 1) % 3 + 1
			for _, sgn in { -1, 1 } do
				local plane = if sgn > 0 then mx[a] else mn[a]
				local key = a .. ":" .. sgn .. ":" .. math.floor(plane * 500 + 0.5)
				buckets[key] = buckets[key] or {}
				table.insert(buckets[key], { p, mn[b1], mx[b1], mn[b2], mx[b2], a, sgn, plane, b1, b2 })
			end
		end
	end
end

local params = OverlapParams.new()
params.FilterType = Enum.RaycastFilterType.Include
params.FilterDescendantsInstances = { map }
local function covered(pt, A, B)
	for _, q in workspace:GetPartBoundsInBox(CFrame.new(pt), Vector3.new(0.004, 0.004, 0.004), params) do
		if q ~= A and q ~= B and q.Transparency < 0.5 then
			return true
		end
	end
	return false
end

local hits, byName, samples = 0, {}, {}
for _, list in buckets do
	if #list > 1 and #list < 600 then
		for i = 1, #list - 1 do
			local A = list[i]
			for j = i + 1, #list do
				local B = list[j]
				local lo1, hi1 = math.max(A[2], B[2]), math.min(A[3], B[3])
				local lo2, hi2 = math.max(A[4], B[4]), math.min(A[5], B[5])
				if hi1 - lo1 > 0.03 and hi2 - lo2 > 0.03 then
					local visible = false
					for _, f in { { 0.5, 0.5 }, { 0.1, 0.1 }, { 0.9, 0.9 }, { 0.1, 0.9 }, { 0.9, 0.1 } } do
						local v = { 0, 0, 0 }
						v[A[6]] = A[8] + A[7] * 0.01
						v[A[9]] = lo1 + (hi1 - lo1) * f[1]
						v[A[10]] = lo2 + (hi2 - lo2) * f[2]
						if not covered(Vector3.new(v[1], v[2], v[3]), A[1], B[1]) then
							visible = true
							break
						end
					end
					if visible then
						hits += 1
						local nm = A[1].Name .. "+" .. B[1].Name
						byName[nm] = (byName[nm] or 0) + 1
						samples[nm] = samples[nm] or (tostring(A[1].Position) .. " in " .. A[1].Parent.Name)
					end
				end
			end
		end
	end
end

local arr = {}
for k, v in byName do
	table.insert(arr, { k, v })
end
table.sort(arr, function(a, b)
	return a[2] > b[2]
end)
print("visible coplanar overlaps: " .. hits)
for i = 1, math.min(40, #arr) do
	print(string.format("  %s x%d  e.g. %s", arr[i][1], arr[i][2], samples[arr[i][1]]))
end
