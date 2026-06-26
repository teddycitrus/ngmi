--!strict
--[[
	LightingProfiles.luau
	=====================
	Lighting & post-processing presets for every phase of Code Red.

	Each profile maps 1:1 with a visual "mood" the game can tween to.
	The LightingController (client) reads a profile and interpolates
	all Lighting service properties + post-processing effects.

	Profiles are frozen — you cannot accidentally mutate them at runtime.
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

export type LightingProfile = {
	-- Core Lighting service properties
	Ambient: Color3,
	Brightness: number,
	ClockTime: number,
	ColorShift_Bottom: Color3,
	ColorShift_Top: Color3,
	FogColor: Color3,
	FogEnd: number,
	FogStart: number,
	OutdoorAmbient: Color3,

	-- Post-processing effect targets
	PostProcessing: PostProcessingProfile,
}

----------------------------------------------------------------------
-- Profiles
----------------------------------------------------------------------

local Profiles: { [string]: LightingProfile } = {}

----------------------------------------------------------------------
-- DAY 1 — Bright late-afternoon sun. The hackathon just kicked off,
-- everyone's optimistic, free pizza is still warm. Golden hour vibes.
----------------------------------------------------------------------
Profiles.Day1_Bright = {
	Ambient            = Color3.fromRGB(200, 195, 180),
	Brightness         = 2.5,
	ClockTime          = 18,   -- 6 PM golden hour
	ColorShift_Bottom  = Color3.fromRGB(0, 0, 0),
	ColorShift_Top     = Color3.fromRGB(0, 0, 0),
	FogColor           = Color3.fromRGB(255, 245, 230),
	FogEnd             = 1000,
	FogStart           = 500,
	OutdoorAmbient     = Color3.fromRGB(200, 195, 180),
	PostProcessing     = {
		ColorCorrection = {
			Brightness = 0.05,
			Contrast   = 0.05,
			Saturation = 0.1,
			TintColor  = Color3.fromRGB(255, 250, 240),  -- warm golden
		},
		Bloom = {
			Intensity = 0.3,
			Size      = 24,
			Threshold = 1.0,
		},
		BlurSize = 0,
	},
}

----------------------------------------------------------------------
-- DAY 2 — Normal midday. Neutral-cool indoor fluorescent lighting.
-- Slightly less warm than Day 1 — the excitement has worn off and
-- people are heads-down coding.
----------------------------------------------------------------------
Profiles.Day2_Normal = {
	Ambient            = Color3.fromRGB(170, 170, 170),
	Brightness         = 2,
	ClockTime          = 12,   -- high noon
	ColorShift_Bottom  = Color3.fromRGB(0, 0, 0),
	ColorShift_Top     = Color3.fromRGB(0, 0, 0),
	FogColor           = Color3.fromRGB(190, 195, 210),
	FogEnd             = 800,
	FogStart           = 400,
	OutdoorAmbient     = Color3.fromRGB(160, 160, 170),
	PostProcessing     = {
		ColorCorrection = {
			Brightness = 0,
			Contrast   = 0.05,
			Saturation = 0,
			TintColor  = Color3.fromRGB(245, 248, 255),  -- slightly cool
		},
		Bloom = {
			Intensity = 0.2,
			Size      = 20,
			Threshold = 1.2,
		},
		BlurSize = 0,
	},
}

----------------------------------------------------------------------
-- DAY 2 CORRUPTION — The venue gets… wrong. Sickly purple haze rolls
-- in, shadows stretch where they shouldn't, and the fluorescent
-- lights start buzzing at the wrong frequency. Something smells bad.
----------------------------------------------------------------------
Profiles.Day2_Corruption = {
	Ambient            = Color3.fromRGB(80, 60, 90),
	Brightness         = 1,
	ClockTime          = 20,   -- 8 PM, light fading fast
	ColorShift_Bottom  = Color3.fromRGB(20, 10, 30),
	ColorShift_Top     = Color3.fromRGB(15, 5, 25),
	FogColor           = Color3.fromRGB(30, 20, 40),
	FogEnd             = 200,
	FogStart           = 50,
	OutdoorAmbient     = Color3.fromRGB(60, 40, 70),
	PostProcessing     = {
		ColorCorrection = {
			Brightness = -0.05,
			Contrast   = 0.2,
			Saturation = -0.3,
			TintColor  = Color3.fromRGB(180, 140, 200),  -- nauseating purple
		},
		Bloom = {
			Intensity = 0.5,
			Size      = 30,
			Threshold = 0.8,
		},
		BlurSize = 2,
	},
}

----------------------------------------------------------------------
-- NIGHT 2 — Full-on horror. Near-total darkness with red emergency
-- lighting. Oppressive fog swallows everything past arm's reach.
-- The only reliable light source is your phone flashlight.
----------------------------------------------------------------------
-- Base night is a cold, near-PITCH-BLACK dark — NO red. With the power cut, the
-- ambient is almost nothing, so until the floor's power boxes are fixed you can
-- barely see past your flashlight's reach (the restored ceiling lights and your
-- flashlight become the only real light). The blood-red wash is applied
-- dynamically by NGMIClient's proximity system, so the screen only goes red when
-- an NGMI is close / chasing you.
Profiles.Night2_Horror = {
	Ambient            = Color3.fromRGB(2, 2, 4),
	Brightness         = 0,
	ClockTime          = 0,    -- dead midnight
	ColorShift_Bottom  = Color3.fromRGB(3, 4, 7),
	ColorShift_Top     = Color3.fromRGB(2, 3, 6),
	-- Tight black fog so you genuinely can't see down the hallway with the power
	-- out — visibility falls off to nothing within a few studs, and your flashlight
	-- is what cuts a cone through it.
	FogColor           = Color3.fromRGB(0, 0, 1),
	FogEnd             = 26,
	FogStart           = 3,
	OutdoorAmbient     = Color3.fromRGB(2, 2, 4),
	PostProcessing     = {
		ColorCorrection = {
			Brightness = -0.2,
			Contrast   = 0.4,
			Saturation = -0.7,
			TintColor  = Color3.fromRGB(210, 216, 230),  -- neutral cold wash
		},
		Bloom = {
			Intensity = 0.3,
			Size      = 40,
			Threshold = 0.5,
		},
		BlurSize = 3,
	},
}

----------------------------------------------------------------------
-- DAY 3 — Dawn breaks. Warm golden sunrise floods the venue.
-- If you survived the night, this feels like redemption. Beautiful
-- volumetric light and soft bloom sell the "we made it" moment.
----------------------------------------------------------------------
Profiles.Day3_Dawn = {
	Ambient            = Color3.fromRGB(220, 200, 170),
	Brightness         = 3,
	ClockTime          = 8,    -- early morning sun
	ColorShift_Bottom  = Color3.fromRGB(40, 25, 10),
	ColorShift_Top     = Color3.fromRGB(30, 15, 5),
	FogColor           = Color3.fromRGB(255, 220, 170),
	FogEnd             = 2000,
	FogStart           = 500,
	OutdoorAmbient     = Color3.fromRGB(210, 190, 160),
	PostProcessing     = {
		ColorCorrection = {
			Brightness = 0.1,
			Contrast   = 0.1,
			Saturation = 0.15,
			TintColor  = Color3.fromRGB(255, 235, 200),  -- warm golden sunrise
		},
		Bloom = {
			Intensity = 0.6,
			Size      = 35,
			Threshold = 0.6,
		},
		BlurSize = 0,
	},
}

----------------------------------------------------------------------
-- Helper: Get a profile by name (returns nil for unknown profiles)
----------------------------------------------------------------------
local function getProfile(name: string): LightingProfile?
	return Profiles[name]
end

----------------------------------------------------------------------
-- Freeze all profiles to prevent runtime mutation
----------------------------------------------------------------------
-- Deep-freeze each profile's nested tables
for _, profile in Profiles do
	table.freeze(profile.PostProcessing.ColorCorrection)
	table.freeze(profile.PostProcessing.Bloom)
	table.freeze(profile.PostProcessing)
	table.freeze(profile)
end

----------------------------------------------------------------------
-- Module Export
----------------------------------------------------------------------
local LightingProfilesModule = {
	Profiles   = table.freeze(Profiles),
	getProfile = getProfile,
}

return table.freeze(LightingProfilesModule)
