--!strict
--------------------------------------------------------------------------------
-- VFX/Focus.luau
-- Raycast-driven depth of field for VFXManager. One ray per frame down the
-- camera's look vector picks the focus distance; the lens (in-focus radius and
-- blur strength) eases toward a per-phase profile and tightens as an NGMI gets
-- close. Runs only while started: the lobby is a full-screen menu, so racking
-- focus behind it would just burn a raycast every frame.
--------------------------------------------------------------------------------

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local NAME_DEPTH_OF_FIELD = "VFXDepthOfField"

local DOF_MAX_DISTANCE = 500 -- studs; ray length for focus probing
local DOF_MIN_FOCUS = 4 -- never rack focus closer than this
local DOF_SMOOTHING = 6 -- higher converges faster (exponential, fps-independent)
local DOF_LENS_SMOOTHING = 1.5 -- lens changes ease in over ~2s
-- Tunnel vision: a close NGMI shrinks the in-focus pocket by up to this share.
local DOF_PROXIMITY_SQUEEZE = 0.6

-- Per-phase lens. Focus stays on what is right in front of you; the further
-- the story goes, the smaller the in-focus pocket and the softer everything
-- beyond it. NearIntensity stays tiny so nothing held close turns to mush.
type DofProfile = { far: number, near: number, radius: number }
local DOF_BY_PHASE: { [number]: DofProfile } = {
	[1] = { far = 0.12, near = 0, radius = 22 }, -- DAY1
	[2] = { far = 0.22, near = 0, radius = 16 }, -- DAY2
	[3] = { far = 0.55, near = 0.05, radius = 9 }, -- NIGHT2
	[4] = { far = 0.08, near = 0, radius = 30 }, -- DAY3
}
local DOF_CORRUPTION: DofProfile = { far = 0.35, near = 0.03, radius = 12 }
local DOF_DEFAULT: DofProfile = { far = 0.15, near = 0, radius = 18 }

local Focus = {}

local depthOfField: DepthOfFieldEffect
local focusDistance = DOF_MAX_DISTANCE
local dofTarget: DofProfile = DOF_DEFAULT
local closeness = 0 -- 0..1, nearest NGMI, fed by VFXManager's proximity poll
local params = RaycastParams.new()
local connection: RBXScriptConnection? = nil

--- Create (or adopt, by its unique name) the DepthOfFieldEffect.
function Focus.init()
	local existing = Lighting:FindFirstChild(NAME_DEPTH_OF_FIELD)
	if existing and existing:IsA("DepthOfFieldEffect") then
		depthOfField = existing
	else
		depthOfField = Instance.new("DepthOfFieldEffect")
		depthOfField.Name = NAME_DEPTH_OF_FIELD
		depthOfField.Parent = Lighting
	end
	depthOfField.FarIntensity = DOF_DEFAULT.far
	depthOfField.NearIntensity = DOF_DEFAULT.near
	depthOfField.FocusDistance = DOF_MAX_DISTANCE
	depthOfField.InFocusRadius = DOF_DEFAULT.radius
	depthOfField.Enabled = false
end

--- Rebuild the raycast filter. The local character must be excluded or the ray
--- instantly hits the player's own head and racks focus to zero.
function Focus.refreshFilter()
	local filter: { Instance } = {}
	if player.Character then
		table.insert(filter, player.Character)
	end
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = filter
	params.IgnoreWater = true
end

--- Hit distance becomes the focus target, smoothed exponentially so focus
--- racks rather than snaps. Decorative VFX parts set CanQuery = false, so they
--- never steal focus.
local function update(deltaTime: number)
	local origin = camera.CFrame.Position
	local result = workspace:Raycast(origin, camera.CFrame.LookVector * DOF_MAX_DISTANCE, params)
	local target = if result then math.max(result.Distance, DOF_MIN_FOCUS) else DOF_MAX_DISTANCE

	local alpha = 1 - math.exp(-DOF_SMOOTHING * deltaTime)
	focusDistance += (target - focusDistance) * alpha
	depthOfField.FocusDistance = focusDistance

	-- Ease the lens toward the phase profile, squeezed by NGMI proximity.
	local lensAlpha = 1 - math.exp(-DOF_LENS_SMOOTHING * deltaTime)
	local radius = dofTarget.radius * (1 - closeness * DOF_PROXIMITY_SQUEEZE)
	local far = math.min(1, dofTarget.far + closeness * 0.25)
	depthOfField.InFocusRadius += (radius - depthOfField.InFocusRadius) * lensAlpha
	depthOfField.FarIntensity += (far - depthOfField.FarIntensity) * lensAlpha
	depthOfField.NearIntensity += (dofTarget.near - depthOfField.NearIntensity) * lensAlpha
end

--- Lens for a phase; the lobby stops tracking and disables the effect.
function Focus.setPhase(phase: number, isLobby: boolean)
	dofTarget = DOF_BY_PHASE[phase] or DOF_DEFAULT
	depthOfField.Enabled = not isLobby
	if isLobby then
		if connection then
			connection:Disconnect()
			connection = nil
		end
	elseif not connection then
		Focus.refreshFilter()
		connection = RunService.RenderStepped:Connect(update)
	end
end

function Focus.setCorruption()
	dofTarget = DOF_CORRUPTION
end

function Focus.setCloseness(value: number)
	closeness = value
end

return Focus
