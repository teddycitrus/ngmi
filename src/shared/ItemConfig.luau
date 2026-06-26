--!strict
--[[
	ItemConfig.luau
	Shared configuration for all items in Not Gonna Make It.
	Defines item types, stack limits, ammo capacities, visual representation,
	and usage effect parameters.
]]

export type ItemDefinition = {
	id: string,
	displayName: string,
	description: string,
	icon: string, -- emoji for hotbar display
	maxStack: number,
	isUsable: boolean,
	isWeapon: boolean,
	ammoCapacity: number?, -- max ammo per stack (nil = not ammo-based)
	sprayCost: number?, -- ammo consumed per use (for spray weapons)
	useEffect: string?, -- effect identifier for server-side logic
	speedMultiplier: number?, -- for speed buff items
	buffDuration: number?, -- seconds the buff lasts
	stunDuration: number?, -- how long NGMIs are stunned
	stunRadius: number?, -- area of effect for stun
	modelColor: Color3, -- color of the world pickup Part
	modelSize: Vector3, -- size of the world pickup Part
}

export type ItemConfigType = {
	items: { [string]: ItemDefinition },
	pickupProximityDistance: number,
	dropOffset: Vector3,
	inventorySlots: number,
}

-- ============================================================================
-- ITEM DEFINITIONS
-- ============================================================================

local ItemConfig: ItemConfigType = {
	pickupProximityDistance = 8,
	dropOffset = Vector3.new(0, 1, -3), -- spawn in front of player, slightly above ground
	inventorySlots = 4,

	items = {
		deodorant = {
			id = "deodorant",
			displayName = "Deodorant",
			description = "Standard-issue hackathon deodorant. Repels NGMIs with its refreshing scent.",
			icon = "🧴",
			maxStack = 1,
			isUsable = true,
			isWeapon = true,
			ammoCapacity = 100,
			sprayCost = 10,
			useEffect = "spray",
			speedMultiplier = nil,
			buffDuration = nil,
			stunDuration = 2.0,
			stunRadius = 12,
			modelColor = Color3.fromRGB(100, 200, 255),
			modelSize = Vector3.new(1.1, 1.6, 1.1),
		},

		energy_bar = {
			id = "energy_bar",
			displayName = "Energy Bar",
			description = "Questionable nutrition, but it'll give you a burst of speed.",
			icon = "🍫",
			maxStack = 3,
			isUsable = true,
			isWeapon = false,
			ammoCapacity = nil,
			sprayCost = nil,
			useEffect = "speed_buff",
			speedMultiplier = 1.3,
			buffDuration = 10.0,
			stunDuration = nil,
			stunRadius = nil,
			modelColor = Color3.fromRGB(180, 120, 60),
			modelSize = Vector3.new(1.5, 0.5, 0.8),
		},

		axe_spray = {
			id = "axe_spray",
			displayName = "Axe Body Spray",
			description = "The nuclear option. Devastating to NGMIs (and noses everywhere).",
			icon = "💪",
			maxStack = 1,
			isUsable = true,
			isWeapon = true,
			ammoCapacity = 60,
			sprayCost = 15,
			useEffect = "spray",
			speedMultiplier = nil,
			buffDuration = nil,
			stunDuration = 4.0,
			stunRadius = 18,
			modelColor = Color3.fromRGB(30, 30, 30),
			modelSize = Vector3.new(1.2, 2.0, 1.2),
		},

		battery = {
			id = "battery",
			displayName = "Battery",
			description = "Snaps into your phone and tops the flashlight back to a full 80-second charge.",
			icon = "🔋",
			maxStack = 4,
			isUsable = true,
			isWeapon = false,
			ammoCapacity = nil,
			sprayCost = nil,
			useEffect = "recharge_flashlight",
			speedMultiplier = nil,
			buffDuration = nil,
			stunDuration = nil,
			stunRadius = nil,
			modelColor = Color3.fromRGB(60, 200, 90),
			modelSize = Vector3.new(0.7, 1.4, 0.7),
		},

		plunger = {
			id = "plunger",
			displayName = "Plunger",
			description = "A trusty bathroom plunger. Useless on its own, but spray the Poop Monster first, then whack it while it reels.",
			icon = "🪠",
			maxStack = 1,
			isUsable = true,
			isWeapon = true,
			ammoCapacity = nil,
			sprayCost = nil,
			useEffect = "melee",
			speedMultiplier = nil,
			buffDuration = nil,
			stunDuration = 1.0,
			stunRadius = 7,
			modelColor = Color3.fromRGB(120, 70, 40),
			modelSize = Vector3.new(0.8, 3.2, 0.8),
		},

		chair_leg = {
			id = "chair_leg",
			displayName = "Chair Leg",
			description = "Improvised melee weapon. Not elegant, but effective in a pinch.",
			icon = "🪑",
			maxStack = 1,
			isUsable = true,
			isWeapon = true,
			ammoCapacity = nil,
			sprayCost = nil,
			useEffect = "melee",
			speedMultiplier = nil,
			buffDuration = nil,
			stunDuration = 1.5,
			stunRadius = 6,
			modelColor = Color3.fromRGB(160, 120, 80),
			modelSize = Vector3.new(0.5, 3, 0.5),
		},
	},
}

return ItemConfig
