--!strict
--[[
	LightingProfiles.luau
	=====================
	Lighting, atmosphere and post-processing presets for every phase of
	Not Gonna Make It.

	Each profile maps 1:1 with a visual "mood" the game can tween to. The
	LightingController (client) reads a profile and interpolates the Lighting
	service properties, the Atmosphere instance, and the post-processing stack.

	Rendering technology
	--------------------
	Every profile is authored for Enum.Technology.Future. Future is a voxel-free
	renderer: Ambient/OutdoorAmbient contribute far less than they do under
	ShadowMap, and tagged light fixtures do the actual illuminating with real
	shadows and attenuation. That is what makes the NIGHT2 blackout read as a
	true blackout rather than a grey wash.

	Lighting.Technology is NOT script-assignable at runtime (Roblox restricts
	write access), so the authoritative place it gets set is default.project.json
	under Lighting.$properties. TECHNOLOGY below is exported so the controller can
	assert the place is configured correctly and warn loudly if it is not.

	Naming
	------
	Profiles are keyed by canonical phase names (LOBBY, DAY1, DAY2, CORRUPTION,
	NIGHT2, DAY3). The pre-refactor names (Day1_Bright, Night2_Horror, ...) are
	kept as aliases pointing at the same frozen tables, because CutsceneManager
	resolves "Night2_Horror" by name and must keep working.

	Profiles are deep-frozen; you cannot accidentally mutate them at runtime.
]]

----------------------------------------------------------------------
-- Types
----------------------------------------------------------------------

export type ColorCorrectionProfile = {
	Brightness: number,
	Contrast: number,
	Saturation: number,
	TintColor: Color3,
}

export type BloomProfile = {
	Intensity: number,
	Size: number,
	Threshold: number,
}

export type PostProcessingProfile = {
	ColorCorrection: ColorCorrectionProfile,
	Bloom: BloomProfile,
	BlurSize: number,
}

--- Volumetric haze. Density is the headline dial: 0 is clear air, 0.7 is the
--- soup the venue fills with once corruption sets in.
export type AtmosphereProfile = {
	Density: number,
	Offset: number,
	Color: Color3,
	Decay: Color3,
	Glare: number,
	Haze: number,
}

export type LightingProfile = {
	-- Core Lighting service properties
	Ambient: Color3,
	Brightness: number,
	ClockTime: number,
	ColorShift_Bottom: Color3,
	ColorShift_Top: Color3,
	ExposureCompensation: number,
	FogColor: Color3,
	FogEnd: number,
	FogStart: number,
	OutdoorAmbient: Color3,

	-- Future-renderer surface response. ShadowSoftness 0 is a razor edge, 1 is
	-- a smear. The two Environment scales decide how much the sky contributes
	-- diffuse fill and specular reflection to PBR materials: diffuse is a flat
	-- ambient lift (kept low, see the exposure budget), specular is what makes
	-- wet floors, metal and glass read as wet floors, metal and glass.
	ShadowSoftness: number,
	EnvironmentDiffuseScale: number,
	EnvironmentSpecularScale: number,

	-- Volumetric atmosphere
	Atmosphere: AtmosphereProfile,

	-- Post-processing effect targets
	PostProcessing: PostProcessingProfile,
}

----------------------------------------------------------------------
-- Rendering technology (see header, applied via default.project.json)
----------------------------------------------------------------------

local TECHNOLOGY: Enum.Technology = Enum.Technology.Future

----------------------------------------------------------------------
-- Profiles
----------------------------------------------------------------------

local Profiles: { [string]: LightingProfile } = {}

----------------------------------------------------------------------
-- Exposure budget (read this before touching any number below)
----------------------------------------------------------------------
-- Under Future, Ambient is a flat fill every surface receives for free, and it
-- stacks on top of the 112 tagged ceiling fixtures. The venue corridors put
-- 3-4 overlapping point lights on any given wall, so an Ambient in the 130-220
-- range (what these profiles used to carry) pushes ordinary 0.85-albedo brick
-- straight past white and the whole game reads as a blank page. Ambient here is
-- therefore deliberately low: the practicals do the lighting, Ambient only
-- keeps unlit corners from going pure black.
--
-- Same reasoning for the haze. Atmosphere Color is a light grey, so Density and
-- Haze decide how fast distance turns into white soup; both stay low so a
-- corridor still has a visible far end.
----------------------------------------------------------------------

----------------------------------------------------------------------
-- LOBBY: the queue menu backdrop, the hall seen from the plaza in a night
-- storm (client/Lobby/Backdrop adds the rain and lightning). Cold and wet:
-- a low blue ambient, rain haze swallowing the skyline, and enough bloom
-- that the lit windows and plaza lamps are the warm points in the frame.
----------------------------------------------------------------------
Profiles.LOBBY = {
	Ambient = Color3.fromRGB(18, 20, 28),
	Brightness = 0.4,
	ClockTime = 0.4,
	ColorShift_Bottom = Color3.fromRGB(0, 0, 0),
	ColorShift_Top = Color3.fromRGB(0, 0, 0),
	ExposureCompensation = 0.1,
	FogColor = Color3.fromRGB(22, 26, 34),
	FogEnd = 600,
	FogStart = 40,
	OutdoorAmbient = Color3.fromRGB(52, 58, 78),
	ShadowSoftness = 0.4,
	EnvironmentDiffuseScale = 0.2,
	EnvironmentSpecularScale = 1,
	Atmosphere = {
		Density = 0.36,
		Offset = 0.08,
		Color = Color3.fromRGB(48, 54, 68),
		Decay = Color3.fromRGB(26, 30, 40),
		Glare = 0,
		Haze = 1.8,
	},
	PostProcessing = {
		ColorCorrection = {
			Brightness = 0,
			Contrast = 0.12,
			Saturation = -0.22,
			TintColor = Color3.fromRGB(206, 214, 236),
		},
		Bloom = {
			Intensity = 0.45,
			Size = 24,
			Threshold = 1.1,
		},
		BlurSize = 0,
	},
}

----------------------------------------------------------------------
-- DAY1: Friday evening. Warm, clinical university fluorescent light
-- over a venue that is still cheerful: free pizza, everyone optimistic,
-- nobody has read the judging criteria yet.
--
-- This profile is the calibration reference. It was tuned in-game against a
-- lit corridor and the other five are derived from it, so if the venue ever
-- needs a global exposure change, change DAY1 first and re-derive.
----------------------------------------------------------------------
Profiles.DAY1 = {
	Ambient = Color3.fromRGB(30, 30, 34),
	Brightness = 2.2,
	ClockTime = 18,
	ColorShift_Bottom = Color3.fromRGB(0, 0, 0),
	ColorShift_Top = Color3.fromRGB(14, 10, 4),
	ExposureCompensation = -0.2,
	FogColor = Color3.fromRGB(120, 120, 124),
	FogEnd = 400,
	FogStart = 60,
	OutdoorAmbient = Color3.fromRGB(64, 66, 74),
	ShadowSoftness = 0.18,
	EnvironmentDiffuseScale = 0.3,
	EnvironmentSpecularScale = 1,
	Atmosphere = {
		Density = 0.12,
		Offset = 0.1,
		Color = Color3.fromRGB(150, 154, 162),
		Decay = Color3.fromRGB(84, 88, 98),
		Glare = 0.03,
		Haze = 0.3,
	},
	PostProcessing = {
		ColorCorrection = {
			Brightness = 0,
			Contrast = 0.08,
			Saturation = -0.06,
			TintColor = Color3.fromRGB(248, 250, 255),
		},
		Bloom = {
			Intensity = 0.12,
			Size = 18,
			Threshold = 1.35,
		},
		BlurSize = 0,
	},
}

----------------------------------------------------------------------
-- DAY2: Saturday. The light is dimmer and colder, contrast is up, and
-- the haze has thickened. Nothing is overtly wrong yet; the room just
-- feels heavier than it did yesterday.
----------------------------------------------------------------------
Profiles.DAY2 = {
	Ambient = Color3.fromRGB(22, 23, 28),
	Brightness = 1.7,
	ClockTime = 12,
	ColorShift_Bottom = Color3.fromRGB(0, 0, 0),
	ColorShift_Top = Color3.fromRGB(6, 8, 14),
	ExposureCompensation = -0.3,
	FogColor = Color3.fromRGB(84, 88, 96),
	FogEnd = 300,
	FogStart = 40,
	OutdoorAmbient = Color3.fromRGB(48, 50, 58),
	ShadowSoftness = 0.15,
	EnvironmentDiffuseScale = 0.2,
	EnvironmentSpecularScale = 1,
	Atmosphere = {
		Density = 0.2,
		Offset = 0.1,
		Color = Color3.fromRGB(120, 128, 140),
		Decay = Color3.fromRGB(60, 66, 78),
		Glare = 0.04,
		Haze = 0.6,
	},
	PostProcessing = {
		ColorCorrection = {
			Brightness = -0.03,
			Contrast = 0.15,
			Saturation = -0.18,
			TintColor = Color3.fromRGB(232, 240, 252),
		},
		Bloom = {
			Intensity = 0.12,
			Size = 20,
			Threshold = 1.35,
		},
		BlurSize = 0,
	},
}

----------------------------------------------------------------------
-- CORRUPTION: fired at the DAY2 halfway mark. Colour drains out of the
-- venue, the tint goes cold and greenish-grey like a dead monitor, and
-- the haze triples. The controller drives this over ~10 seconds so you
-- watch it happen rather than cutting to it.
----------------------------------------------------------------------
Profiles.CORRUPTION = {
	Ambient = Color3.fromRGB(14, 17, 16),
	Brightness = 0.9,
	ClockTime = 20,
	ColorShift_Bottom = Color3.fromRGB(14, 20, 17),
	ColorShift_Top = Color3.fromRGB(10, 16, 13),
	ExposureCompensation = -0.35,
	FogColor = Color3.fromRGB(28, 34, 32),
	FogEnd = 220,
	FogStart = 25,
	OutdoorAmbient = Color3.fromRGB(26, 31, 30),
	ShadowSoftness = 0.12,
	EnvironmentDiffuseScale = 0.12,
	EnvironmentSpecularScale = 1,
	Atmosphere = {
		Density = 0.34,
		Offset = 0.2,
		Color = Color3.fromRGB(104, 118, 112),
		Decay = Color3.fromRGB(40, 48, 44),
		Glare = 0.08,
		Haze = 0.9,
	},
	PostProcessing = {
		ColorCorrection = {
			Brightness = -0.06,
			Contrast = 0.26,
			Saturation = -0.45,
			TintColor = Color3.fromRGB(180, 200, 190),
		},
		Bloom = {
			Intensity = 0.2,
			Size = 26,
			Threshold = 1.2,
		},
		BlurSize = 2,
	},
}

----------------------------------------------------------------------
-- NIGHT2: venue-wide blackout. Ambient and OutdoorAmbient are dropped
-- to almost nothing, so under Future the ONLY illumination left is the
-- tagged CeilingLight / EmergencyLight fixtures the players restore, and
-- their own flashlight. Fog is deliberately tight: with the power out you
-- genuinely cannot see down a hallway.
--
-- Bloom threshold stays above 1 on purpose. The venue carries roughly a
-- thousand Neon parts (fixtures, monitors, signage) and a low threshold lets
-- every one of them smear into a glow that lifts the blackout back to grey.
-- At 1.1 only the genuinely hot sources (emergency strobes, the flashlight
-- hotspot on a near wall, NGMI eyes) bloom.
--
-- ShadowSoftness is the lowest of any profile so the flashlight throws crisp,
-- hard-edged shadows, and EnvironmentSpecularScale stays at 1 so wet floors
-- still catch the beam even though the sky contributes no diffuse light.
----------------------------------------------------------------------
Profiles.NIGHT2 = {
	Ambient = Color3.fromRGB(2, 2, 4),
	Brightness = 0,
	ClockTime = 0,
	ColorShift_Bottom = Color3.fromRGB(3, 4, 7),
	ColorShift_Top = Color3.fromRGB(2, 3, 6),
	ExposureCompensation = -0.25,
	FogColor = Color3.fromRGB(0, 0, 1),
	FogEnd = 26,
	FogStart = 3,
	OutdoorAmbient = Color3.fromRGB(2, 2, 4),
	ShadowSoftness = 0.08,
	EnvironmentDiffuseScale = 0.05,
	EnvironmentSpecularScale = 1,
	Atmosphere = {
		Density = 0.38,
		Offset = 0.05,
		Color = Color3.fromRGB(10, 12, 18),
		Decay = Color3.fromRGB(3, 4, 7),
		Glare = 0,
		Haze = 0.9,
	},
	PostProcessing = {
		ColorCorrection = {
			-- Mild on purpose. At -0.18 / 0.38 the grade crushed every dim
			-- value to black, so each light ended in a hard ring instead of
			-- fading out; the blackout itself comes from the near-zero Ambient.
			Brightness = -0.08,
			Contrast = 0.22,
			Saturation = -0.6,
			-- Neutral cold wash. The blood-red proximity tint is layered on top
			-- by NGMIClient's own effect, so it only appears when one is close.
			TintColor = Color3.fromRGB(205, 214, 232),
		},
		Bloom = {
			Intensity = 0.22,
			Size = 30,
			Threshold = 1.1,
		},
		BlurSize = 3,
	},
}

----------------------------------------------------------------------
-- DAY3: dawn. Warm golden sunrise floods the venue. If you survived the
-- night this is meant to feel like relief, so it is the only profile that
-- goes brighter and more saturated than neutral.
----------------------------------------------------------------------
Profiles.DAY3 = {
	Ambient = Color3.fromRGB(46, 42, 36),
	Brightness = 3,
	ClockTime = 8,
	ColorShift_Bottom = Color3.fromRGB(40, 25, 10),
	ColorShift_Top = Color3.fromRGB(30, 15, 5),
	ExposureCompensation = -0.05,
	FogColor = Color3.fromRGB(190, 168, 138),
	FogEnd = 1400,
	FogStart = 300,
	OutdoorAmbient = Color3.fromRGB(96, 88, 74),
	ShadowSoftness = 0.25,
	EnvironmentDiffuseScale = 0.5,
	EnvironmentSpecularScale = 1,
	Atmosphere = {
		Density = 0.14,
		Offset = 0.3,
		Color = Color3.fromRGB(200, 184, 158),
		Decay = Color3.fromRGB(130, 108, 82),
		Glare = 0.25,
		Haze = 0.45,
	},
	PostProcessing = {
		ColorCorrection = {
			Brightness = 0.1,
			Contrast = 0.1,
			Saturation = 0.15,
			TintColor = Color3.fromRGB(255, 235, 200),
		},
		Bloom = {
			Intensity = 0.28,
			Size = 28,
			Threshold = 1,
		},
		BlurSize = 0,
	},
}
----------------------------------------------------------------------
-- Phase id → canonical profile name
----------------------------------------------------------------------
-- Mirrors GameConfig.Phase. Kept as plain numbers so this module stays
-- dependency-free and can be required from anywhere without a cycle.
----------------------------------------------------------------------
local PHASE_PROFILE: { [number]: string } = {
	[0] = "LOBBY",
	[1] = "DAY1",
	[2] = "DAY2",
	[3] = "NIGHT2",
	[4] = "DAY3",
}

----------------------------------------------------------------------
-- Legacy aliases
----------------------------------------------------------------------
-- Pre-refactor call sites resolve profiles by these names. CutsceneManager
-- asks for "Night2_Horror" by name, so these must keep resolving. They point
-- at the SAME frozen tables, not copies.
----------------------------------------------------------------------
local ALIASES: { [string]: string } = {
	Day1_Bright = "DAY1",
	Day2_Normal = "DAY2",
	Day2_Corruption = "CORRUPTION",
	Night2_Horror = "NIGHT2",
	Day3_Dawn = "DAY3",
}

for alias, canonical in ALIASES do
	Profiles[alias] = Profiles[canonical]
end

----------------------------------------------------------------------
-- Lookup helpers
----------------------------------------------------------------------

--- Resolve a profile by canonical name or legacy alias. Returns nil for
--- unknown names so callers can warn rather than crash.
local function getProfile(name: string): LightingProfile?
	return Profiles[name]
end

--- Resolve the profile for a GameConfig phase id. Falls back to LOBBY for
--- an unrecognised phase, so a bad id dims the venue instead of erroring.
local function getProfileForPhase(phase: number): LightingProfile
	local name = PHASE_PROFILE[phase] or "LOBBY"
	return Profiles[name]
end

--- Canonical profile name for a phase id, for logging and tween bookkeeping.
local function getProfileName(phase: number): string
	return PHASE_PROFILE[phase] or "LOBBY"
end

----------------------------------------------------------------------
-- Freeze
----------------------------------------------------------------------
-- Aliases share table identity with their canonical profile, so guard against
-- double-freezing the same table (table.freeze errors on an already-frozen
-- table).
----------------------------------------------------------------------
for _, profile in Profiles do
	if not table.isfrozen(profile) then
		table.freeze(profile.PostProcessing.ColorCorrection)
		table.freeze(profile.PostProcessing.Bloom)
		table.freeze(profile.PostProcessing)
		table.freeze(profile.Atmosphere)
		table.freeze(profile)
	end
end

----------------------------------------------------------------------
-- Module Export
----------------------------------------------------------------------
local LightingProfilesModule = {
	TECHNOLOGY = TECHNOLOGY,
	Profiles = table.freeze(Profiles),
	PHASE_PROFILE = table.freeze(PHASE_PROFILE),
	getProfile = getProfile,
	getProfileForPhase = getProfileForPhase,
	getProfileName = getProfileName,
}

return table.freeze(LightingProfilesModule)
