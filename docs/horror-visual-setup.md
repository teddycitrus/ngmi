# Horror Visual Setup

Reference for the lighting, post-processing, camera and VFX systems. All values
below are already applied by code; this page is what to tune and where.

## Where things live

| Concern | File | Runs in |
|---|---|---|
| Lighting / atmosphere / grade per phase | `src/shared/LightingProfiles.luau` | data (ReplicatedStorage.Shared) |
| Applies profiles, glitch + strobe loops | `src/client/LightingController.client.luau` | StarterPlayerScripts |
| Depth of field, Perlin shake, screen FX | `src/client/VFXManager.client.luau` | StarterPlayerScripts |
| Sway, turn lean, corner peek | `src/client/CameraController.client.luau` | StarterPlayerScripts |
| Reusable cutscene + jumpscare module | `src/shared/CinematicCamera.luau` | required by LocalScripts |
| Flashlight | `src/client/FlashlightController.client.luau` | StarterPlayerScripts |
| Dust motes, ground fog, light flicker + sparks | `src/client/AtmosphereFX.client.luau` | StarterPlayerScripts |
| Crouch + movement lean on player bodies | `src/client/CharacterAnimator.client.luau` | StarterPlayerScripts |
| Crouch state (input, speed) | `src/client/StaminaController.client.luau` | StarterPlayerScripts |
| Crouch replication | `src/server/CrouchReplicator.server.luau` | ServerScriptService |
| NGMI procedural animation (stalk, sprint, swipes, lunge, flinch) | `src/client/NGMIAnimator.client.luau` | StarterPlayerScripts |
| NGMI noises (clicks, growls, screech, snarls) | `src/client/NGMIVoice.luau` | StarterPlayerScripts (module) |
| NGMI rigs, AIState + AttackKind/AttackSeq attributes | `src/server/NGMIController.server.luau` | ServerScriptService |
| R15 joint posing (Motor6D or AnimationConstraint) | `src/shared/RigPose.luau` | ReplicatedStorage.Shared |
| NGMI mutation (growths, eyes, claws, skeletal twist) | `src/shared/NGMIMutation.luau` | ReplicatedStorage.Shared |
| Opening ceremony shots, speaker and crowd | `src/shared/OpeningCinematic.luau`, `SpeakerChoreo.luau` | ReplicatedStorage.Shared |
| Night transition breakdowns and turns | `src/shared/NGMIChoreo.luau`, `CutsceneActors.luau` | ReplicatedStorage.Shared |
| Grime, puddles, Night 2 blood | `src/server/SurfaceWeathering.server.luau` | ServerScriptService |
| Venue build (layout, walls, halls, rooms, stairs, elevators, exterior) | `src/server/Venue/` (entry: `Builder.luau`, dimensions: `Layout.luau`) | ServerScriptService (modules) |
| Furniture templates (office, lounge, fixtures) | `src/server/Venue/Furniture/`, resolved by `src/server/AssetLibrary.luau` | ServerScriptService (modules) |

## Step 1: Engine settings (default.project.json)

`Lighting.Technology` cannot be set from a script, so it lives in the project file.

| Property | Value |
|---|---|
| Technology | Future |
| GlobalShadows | true |
| ShadowSoftness | 0.2 (boot value; profiles take over) |
| EnvironmentDiffuseScale | 0.25 |
| EnvironmentSpecularScale | 0.6 |

## Step 2: Lighting per phase

| Property | LOBBY | DAY1 | DAY2 | CORRUPTION | NIGHT2 | DAY3 |
|---|---|---|---|---|---|---|
| Ambient (RGB) | 28,28,32 | 30,30,34 | 22,23,28 | 14,17,16 | 2,2,4 | 46,42,36 |
| Brightness | 2 | 2.2 | 1.7 | 0.9 | 0 | 3 |
| ExposureCompensation | -0.2 | -0.2 | -0.3 | -0.35 | -0.25 | -0.05 |
| ShadowSoftness | 0.2 | 0.18 | 0.15 | 0.12 | 0.08 | 0.25 |
| EnvironmentDiffuseScale | 0.25 | 0.3 | 0.2 | 0.12 | 0.05 | 0.5 |
| EnvironmentSpecularScale | 0.6 | 1 | 1 | 1 | 1 | 1 |
| FogStart / FogEnd | 60 / 420 | 60 / 400 | 40 / 300 | 25 / 220 | 3 / 26 | 300 / 1400 |

Ambient stays low on purpose. Under Future the tagged ceiling fixtures do the
lighting; a high Ambient stacks on top of them and washes walls out to white.

## Step 3: Post-processing per phase

| Effect | LOBBY | DAY1 | DAY2 | CORRUPTION | NIGHT2 | DAY3 |
|---|---|---|---|---|---|---|
| CC Brightness | 0 | 0 | -0.03 | -0.06 | -0.18 | 0.1 |
| CC Contrast | 0.03 | 0.08 | 0.15 | 0.26 | 0.38 | 0.1 |
| CC Saturation | 0 | -0.06 | -0.18 | -0.45 | -0.6 | 0.15 |
| CC Tint (RGB) | 255,252,246 | 248,250,255 | 232,240,252 | 180,200,190 | 205,214,232 | 255,235,200 |
| Bloom Intensity | 0.11 | 0.12 | 0.12 | 0.2 | 0.22 | 0.28 |
| Bloom Size | 20 | 18 | 20 | 26 | 30 | 28 |
| Bloom Threshold | 1.3 | 1.35 | 1.35 | 1.2 | 1.1 | 1 |
| Blur Size | 0 | 0 | 0 | 2 | 3 | 0 |

Bloom thresholds stay above 1 so only genuinely hot sources glow (strobes, the
flashlight hotspot on a near wall, NGMI eyes), not the roughly 1000 Neon parts.

## Step 4: Atmosphere per phase

| Property | DAY1 | DAY2 | CORRUPTION | NIGHT2 |
|---|---|---|---|---|
| Density | 0.12 | 0.2 | 0.34 | 0.38 |
| Offset | 0.1 | 0.1 | 0.2 | 0.05 |
| Color (RGB) | 150,154,162 | 120,128,140 | 104,118,112 | 10,12,18 |
| Decay (RGB) | 84,88,98 | 60,66,78 | 40,48,44 | 3,4,7 |
| Glare | 0.03 | 0.04 | 0.08 | 0 |
| Haze | 0.3 | 0.6 | 0.9 | 0.9 |

## Step 5: Depth of field (VFXManager)

Focus distance follows a raycast down the view direction every frame. The lens
eases toward these per phase:

| Phase | FarIntensity | NearIntensity | InFocusRadius |
|---|---|---|---|
| DAY1 | 0.12 | 0 | 22 |
| DAY2 | 0.22 | 0 | 16 |
| CORRUPTION | 0.35 | 0.03 | 12 |
| NIGHT2 | 0.55 | 0.05 | 9 |
| DAY3 | 0.08 | 0 | 30 |

A nearby NGMI (within 30 studs) shrinks InFocusRadius by up to 60% and adds up
to 0.25 FarIntensity: tunnel vision.

## Controls added

| Key | Action |
|---|---|
| C | Toggle crouch (walk 6, no sprint, won't stand up under low cover) |
| Z / X | Hold to peek left / right (Q and E are taken by the inventory) |

## Using CinematicCamera

```lua
local CinematicCamera = require(game.ReplicatedStorage.Shared.CinematicCamera)

local handle = CinematicCamera.play({
	shots = {
		{ cframe = CFrame.lookAt(a, target), duration = 0, fov = 60 },
		{ cframe = CFrame.lookAt(b, target), duration = 2.5, fov = 45, hold = 0.5 },
		{ cframe = CFrame.lookAt(c, target), duration = 0.3, fov = 30,
		  easing = Enum.EasingStyle.Back, direction = Enum.EasingDirection.Out },
	},
	cues = {
		{ at = 0.2, sound = "rbxassetid://12222030", volume = 0.8 },
		{ at = 2.8, shake = 0.7 },
		{ at = 2.8, aberration = 0.9, duration = 0.5 },
		{ at = 2.9, glitch = 0.4 },
	},
	letterbox = true,
})
handle.Completed:Wait()

-- One-line jumpscare: FOV slam, chromatic aberration, shake, bloom, static.
CinematicCamera.jumpscare(1, "rbxassetid://12222242")
```

## PBR materials (recommended next step)

The venue already uses Roblox's 2022 materials, which ship with normal and
roughness maps, assigned per surface role in `GameConfig.SURFACES`. To push
further:

1. In Studio, open Material Manager and create MaterialVariants (for example
   `WetConcrete`, `StainedPlaster`, `RustedMetal`) with ColorMap, NormalMap,
   RoughnessMap and MetalnessMap. Material Generator can produce these from a
   text prompt. Low roughness (0.1 to 0.3) on wet surfaces is what lets the
   flashlight leave a sharp specular highlight.
2. Set `MaterialService` overrides or assign `MaterialVariant` per part role in
   `Kit.surface` (`src/server/Venue/Kit.luau`).

MaterialVariant and SurfaceAppearance map properties can't be set from a
runtime script, so they have to be authored in Studio.
