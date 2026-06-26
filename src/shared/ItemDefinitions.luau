--!strict
--[[
	ItemDefinitions.luau
	====================
	Central registry of every pick-up-able item in Not Gonna Make It.

	Each item has a canonical definition here — the server uses this to
	validate drops/pickups, and the client reads it for UI display.
	Items are keyed by a short string `id` that is used everywhere in
	network messages and save data.

	Item Types:
	  • weapon     – deals with NGMIs (deodorant cans, etc.)
	  • consumable – one-time use, removed from inventory on activation
	  • tool       – persistent utility (flashlight, etc.)
	  • quest      – key items required for quest completion
]]

----------------------------------------------------------------------
-- Types
----------------------------------------------------------------------

export type ItemType = "weapon" | "consumable" | "tool" | "quest"

export type ItemDefinition = {
	id: string,
	name: string,
	description: string,
	itemType: ItemType,
	maxStack: number,
	icon: string,

	-- Weapon-specific (only present when itemType == "weapon")
	ammo: number?,
	range: number?,
	rangeMultiplier: number?,
	stunMultiplier: number?,

	-- Consumable-specific (only present when itemType == "consumable")
	speedBoost: number?,
	duration: number?,
}

----------------------------------------------------------------------
-- Item Definitions
----------------------------------------------------------------------

local Items: { [string]: ItemDefinition } = {}

----------------------------------------------------------------------
-- SPRAY DEODORANT
-- The bread-and-butter anti-NGMI weapon. Spray it in their face and
-- they'll stumble back, stunned by the overwhelming scent of "Ocean
-- Breeze". Limited ammo — use it wisely or end up defenseless.
----------------------------------------------------------------------
Items.deodorant = {
	id          = "deodorant",
	name        = "Spray Deodorant",
	description = "Spray NGMIs in the face to stun them. Personal hygiene saves lives.",
	itemType    = "weapon",
	maxStack    = 1,
	icon        = "rbxassetid://0",  -- placeholder

	ammo        = 100,
	range       = nil,  -- uses default from GameConfig.Deodorant.range
}

----------------------------------------------------------------------
-- ENERGY BAR
-- The hackathon survival staple. Tastes terrible, but the sugar rush
-- lets you outrun things that want to eat your face.
----------------------------------------------------------------------
Items.energy_bar = {
	id          = "energy_bar",
	name        = "Energy Bar",
	description = "Grants 30% speed boost for 10 seconds. Tastes like cardboard.",
	itemType    = "consumable",
	maxStack    = 3,
	icon        = "rbxassetid://0",  -- placeholder

	speedBoost  = 1.3,
	duration    = 10,
}

----------------------------------------------------------------------
-- INDUSTRIAL AXE BODY SPRAY
-- The legendary weapon. When regular deodorant isn't enough, you
-- bring out the big guns. 3x everything. The nuclear option of
-- personal care products. Rare drop from the Poop Monster boss.
----------------------------------------------------------------------
Items.axe_spray = {
	id              = "axe_spray",
	name            = "Industrial Axe Body Spray",
	description     = "LEGENDARY. 3x range. 3x stun. The nuclear option of personal care.",
	itemType        = "weapon",
	maxStack        = 1,
	icon            = "rbxassetid://0",  -- placeholder

	ammo            = 50,
	rangeMultiplier = 3,
	stunMultiplier  = 3,
}

----------------------------------------------------------------------
-- BATTERY
-- Your phone's flashlight chews through charge on Night 2 (80s on a
-- full charge). Snap a battery in to top it back up to 100%.
----------------------------------------------------------------------
Items.battery = {
	id          = "battery",
	name        = "Battery",
	description = "Recharges your phone flashlight to a full 80-second charge.",
	itemType    = "consumable",
	maxStack    = 4,
	icon        = "rbxassetid://0",  -- placeholder
}

----------------------------------------------------------------------
-- PLUNGER
-- The Poop Monster's bane. Spray it with deodorant to stagger it,
-- then close in and plunge. Worthless if you skip the spray.
----------------------------------------------------------------------
Items.plunger = {
	id          = "plunger",
	name        = "Plunger",
	description = "Whack the staggered Poop Monster. Spray it first or it just shrugs you off.",
	itemType    = "weapon",
	maxStack    = 1,
	icon        = "rbxassetid://0",  -- placeholder
}

----------------------------------------------------------------------
-- CHAIR
-- A folding chair that a panicked dev crew desperately needs.
-- Quest item for the Chair Crew side-quest. Surprisingly heavy
-- for something so flimsy.
----------------------------------------------------------------------
Items.chair = {
	id          = "chair",
	name        = "Chair",
	description = "A folding chair. Someone needs this desperately.",
	itemType    = "quest",
	maxStack    = 1,
	icon        = "rbxassetid://0",  -- placeholder
}

----------------------------------------------------------------------
-- Lookup Helper
----------------------------------------------------------------------

--- Returns the ItemDefinition for the given id, or nil if unknown.
local function getItem(id: string): ItemDefinition?
	return Items[id]
end

----------------------------------------------------------------------
-- Freeze everything
----------------------------------------------------------------------
for _, item in Items do
	table.freeze(item)
end

----------------------------------------------------------------------
-- Module Export
----------------------------------------------------------------------
local ItemDefinitions = {
	Items   = table.freeze(Items),
	getItem = getItem,
}

return table.freeze(ItemDefinitions)
