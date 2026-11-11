--!strict
--------------------------------------------------------------------------------
-- CutsceneHide.client.luau
-- Hides world-space UI while a cutscene owns the camera: the "your desk"
-- beacon (DeskBeacon's pillar and label) and NPC overhead speech (NPCManager's
-- BarkBubble and MutterBubble). Every cutscene (CinematicCamera, CutsceneManager)
-- switches the camera to Scriptable, so that is the signal. Changes are local:
-- the server's billboards stay enabled for everyone else.
--------------------------------------------------------------------------------

local WorldIndex = require(script.Parent:WaitForChild("Cutscene"):WaitForChild("WorldIndex"))

local camera = workspace.CurrentCamera

local HIDDEN_GUIS = WorldIndex.HIDDEN_GUIS
local HIDDEN_PARTS = WorldIndex.HIDDEN_PARTS

local inCutscene = false
local hidden: { [Instance]: any } = {} -- instance -> value to restore
local guards: { RBXScriptConnection } = {}

local function hide(inst: Instance)
	if hidden[inst] ~= nil then
		return
	end
	-- name first: this runs on every instance added mid-cutscene
	local name = inst.Name
	if HIDDEN_GUIS[name] and inst:IsA("BillboardGui") then
		hidden[inst] = inst.Enabled
		inst.Enabled = false
		-- NPCManager re-enables bubbles from the server mid-bark, which
		-- overwrites the local value, so keep pushing it back down.
		table.insert(guards, inst:GetPropertyChangedSignal("Enabled"):Connect(function()
			if inCutscene and inst.Enabled then
				hidden[inst] = true
				inst.Enabled = false
			end
		end))
	elseif HIDDEN_PARTS[name] and inst:IsA("BasePart") then
		hidden[inst] = inst.LocalTransparencyModifier
		inst.LocalTransparencyModifier = 1
	end
end

local function restore()
	for _, c in guards do
		c:Disconnect()
	end
	table.clear(guards)
	for inst, value in hidden do
		if inst.Parent then
			if inst:IsA("BillboardGui") then
				inst.Enabled = value
			elseif inst:IsA("BasePart") then
				inst.LocalTransparencyModifier = value
			end
		end
	end
	table.clear(hidden)
end

local function refresh()
	local now = camera.CameraType == Enum.CameraType.Scriptable
	if now == inCutscene then
		return
	end
	inCutscene = now
	if now then
		for _, d in WorldIndex.hideTargets() do
			hide(d)
		end
	else
		restore()
	end
end

camera:GetPropertyChangedSignal("CameraType"):Connect(refresh)
-- Bubbles an NPC says mid-scene are created after the scene starts.
workspace.DescendantAdded:Connect(function(d: Instance)
	if inCutscene then
		hide(d)
	end
end)
refresh()
