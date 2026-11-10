--!strict
--------------------------------------------------------------------------------
-- Rig/Looks.luau
-- What every venue person wears. Every rig is an R15 body from Roblox's
-- generic NeoClassic v2 sets (smooth limbs, real hands) with a generic face,
-- dressed in 3D layered clothing (shirts, jackets, pants, shoes
-- that wrap the body) and mesh hair from the avatar catalog.
--
--   Looks.CROWD   4 everyday outfits the ambient crowd and bodies cycle through
--   Looks.NAMED   one outfit per named NPC (NPCConfig id), loud enough to pick
--                 out across a room but still something a person would wear
--   Looks.describe(look) -> HumanoidDescription
--
-- Every id was checked against the catalog (AvatarEditorService:SearchCatalog
-- and AssetService:GetBundleDetailsAsync for the shoe pairs).
--------------------------------------------------------------------------------

local Looks = {}

-- Body sets: { torso, leftArm, rightArm, leftLeg, rightLeg }
local BODY = {
	man = { 4637290950, 4637157175, 4637286849, 4637285693, 4637289137 }, -- NeoClassic Male v2
	woman = { 4637151279, 4637119437, 4637120775, 4637120072, 4637122096 }, -- NeoClassic Female v2
}

-- Generic dynamic heads (face included)
local HEAD = {
	man = 10725826963,
	woman = 10725626210,
}

Looks.SKIN = {
	Color3.fromRGB(241, 205, 178),
	Color3.fromRGB(224, 180, 145),
	Color3.fromRGB(196, 146, 110),
	Color3.fromRGB(160, 110, 78),
	Color3.fromRGB(118, 80, 56),
	Color3.fromRGB(86, 58, 42),
}

-- Layering slot: lower Order sits closer to the body. Pants go over shoes,
-- tops over pants, jackets over everything.
local SLOT = {
	shoeL = { Enum.AccessoryType.LeftShoe, 1 },
	shoeR = { Enum.AccessoryType.RightShoe, 1 },
	pants = { Enum.AccessoryType.Pants, 2 },
	shorts = { Enum.AccessoryType.Shorts, 2 },
	skirt = { Enum.AccessoryType.DressSkirt, 3 },
	tee = { Enum.AccessoryType.TShirt, 4 },
	shirt = { Enum.AccessoryType.Shirt, 5 },
	sweater = { Enum.AccessoryType.Sweater, 6 },
	jacket = { Enum.AccessoryType.Jacket, 7 },
}

type Item = { id: number, slot: string }

-- Tops
local TOP = {
	greyTee = { id = 9112474888, slot = "tee" }, -- Basic T-Shirt - Gray
	stripeTeeWhite = { id = 9112483644, slot = "tee" }, -- Striped T-Shirt - White
	stripeTeeBlack = { id = 9119670803, slot = "tee" }, -- Striped T-Shirt - Black
	tieTopWhite = { id = 9240752338, slot = "shirt" }, -- Tie-Front Top - White
	floralForest = { id = 9728267998, slot = "shirt" }, -- Floral Button Down - Forest
	flannelGreen = { id = 7178743190, slot = "shirt" }, -- Flannel - Green
	longSleeveRed = { id = 7178740556, slot = "shirt" }, -- Baseball Long Sleeve - Red
	knitBeige = { id = 6984769289, slot = "sweater" }, -- Knit Sweater - Beige
	knitBlack = { id = 9240757332, slot = "sweater" }, -- Knit Sweater - Black
	zipBlack = { id = 7192553841, slot = "jacket" }, -- Zip Hoodie - Black
	zipOrange = { id = 6984765766, slot = "jacket" }, -- Zip Hoodie - Orange
	zipTeal = { id = 8648389231, slot = "jacket" }, -- Zip Hoodie - Teal
	hoodedGrey = { id = 8516620262, slot = "jacket" }, -- Hooded Jacket - Gray
	coatSalmon = { id = 8516655378, slot = "jacket" }, -- Business Coat - Salmon
	coatStripe = { id = 8516648620, slot = "jacket" }, -- Business Coat - Striped Gray
	denimLight = { id = 8516609675, slot = "jacket" }, -- Denim Jacket - Light Wash
	leatherWhite = { id = 7192546798, slot = "jacket" }, -- Collared Leather Jacket - White
	leatherBlack = { id = 7192549218, slot = "jacket" }, -- Leather Jacket - Black
}

-- Bottoms
local BOTTOM = {
	jeans = { id = 75009694166375, slot = "pants" }, -- Blue Jeans
	jeansDark = { id = 95459003398035, slot = "pants" }, -- Jeans
	cargoBrown = { id = 6984740059, slot = "pants" }, -- Cargo Pants - Brown
	cargoBlack = { id = 17150164752, slot = "pants" }, -- Baggy Black Cargo Pants
	sweatsBlack = { id = 6984763785, slot = "pants" }, -- Casual Sweats - Black
	formalBlack = { id = 105174981876075, slot = "pants" }, -- Formal Black Pants
	khaki = { id = 84686856958118, slot = "pants" }, -- Khaki Business Pants
	beige = { id = 98874699034122, slot = "pants" }, -- Dress Suit Pants Beige
	leatherWhite = { id = 7192681239, slot = "pants" }, -- Textured Leather Pants - White
	ballShortsBlue = { id = 7192688494, slot = "shorts" }, -- Basketball Shorts - Blue
	ruffleRed = { id = 7192696851, slot = "skirt" }, -- Long Ruffle Skirt - Red
}

-- Shoe pairs { left, right } (from the Roblox shoe bundles)
local SHOES = {
	sneakerWhite = { 9614684090, 9614686845 }, -- Roblox Sneakers - White
	sneakerGrey = { 7193165925, 7193166879 }, -- Roblox Sneakers - Gray
	canvasWhite = { 9481782649, 9481786623 }, -- Canvas Shoes - White
	canvasGrey = { 9483690316, 9483697460 }, -- Canvas Shoes - Gray
	bootsTan = { 7193170137, 7193171232 }, -- Work Boots - Tan
	dressBlack = { 8044843668, 8044852814 }, -- Dress Shoes - Black
	dressBrown = { 8044823721, 8044826993 }, -- Dress Shoes - Brown
	flatsBlack = { 7193104827, 7193106211 }, -- Flats - Black
	runRed = { 8722108564, 8722044460 }, -- Roblox Running Shoes - Red
	highWhite = { 9542380884, 9542391112 }, -- High Tops - White
	milBlack = { 9614836327, 9614841343 }, -- Military Boots - Black
}

-- Hair (mesh hair accessories)
local HAIR = {
	brownLayered = 100202592246873, -- Brown Short Messy Layered Hair
	brownBun = 122117226947549, -- low messy bun in brown
	blackBuzz = 14631577537, -- Black Buzz Cut
	blackCurly = 76461613235817, -- Black Messy Curly Hair
	blonde = 107817078459185, -- Blonde Hair
	salonBun = 105162488813710, -- Black Classy Curly Salon Bun
	buzzStache = 80485322790011, -- Buzz Cut W Stash
	curlyTextured = 103856453215647, -- Black Curly Hair Textured
	redPart = 110492624668963, -- Red Stylish Middle Part Boy Hair
	shadesHair = 18116197878, -- Soft Short Raised Sunglasses Hair (Black)
	grungePony = 98408891453054, -- Messy Grunge Ponytail Bun, Light Bangs
	buzz = 118122971099393, -- Buzz Cut
}

local GLASSES = 301820310

export type Look = {
	key: string,
	body: { number },
	head: number,
	skin: Color3,
	hair: { number },
	face: { number }?,
	clothes: { Item },
	shoes: { number },
	height: number?,
	width: number?,
}

local function look(key: string, head: number, skin: number, hair: number, clothes: { Item }, shoes: { number }, extra: { [string]: any }?): Look
	local body = if head == HEAD.woman then BODY.woman else BODY.man
	local l: any = { key = key, body = body, head = head, skin = Looks.SKIN[skin], hair = { hair }, clothes = clothes, shoes = shoes }
	for k, v in extra or {} do
		l[k] = v
	end
	return l :: Look
end

-- The crowd: four plain hackathon outfits. RigFactory varies the skin tone
-- per rig so the repeats are harder to spot.
Looks.CROWD = {
	look("crowdA", HEAD.man, 2, HAIR.brownLayered, { TOP.greyTee, TOP.zipBlack, BOTTOM.jeans }, SHOES.sneakerWhite),
	look("crowdB", HEAD.woman, 1, HAIR.brownBun, { TOP.knitBeige, BOTTOM.jeansDark }, SHOES.canvasWhite),
	look("crowdC", HEAD.man, 5, HAIR.blackBuzz, { TOP.flannelGreen, BOTTOM.cargoBrown }, SHOES.bootsTan, { width = 1.04 }),
	look("crowdD", HEAD.woman, 4, HAIR.blackCurly, { TOP.hoodedGrey, BOTTOM.sweatsBlack }, SHOES.sneakerGrey, { height = 0.97 }),
} :: { Look }

-- The named NPCs: each one a colour and cut nobody in the crowd wears.
Looks.NAMED = {
	-- salmon blazer on stage, readable from the back row
	npc_organizer_sarah = look("sarah", HEAD.woman, 2, HAIR.blonde, { TOP.stripeTeeWhite, TOP.coatSalmon, BOTTOM.formalBlack }, SHOES.flatsBlack),
	-- red ruffle skirt under a pinstripe coat
	npc_judge_priya = look("priya", HEAD.woman, 4, HAIR.salonBun, { TOP.tieTopWhite, TOP.coatStripe, BOTTOM.ruffleRed }, SHOES.dressBlack, { face = { GLASSES } }),
	-- white leather jacket, the sponsor money look
	npc_sponsor_jordan = look("jordan", HEAD.man, 6, HAIR.buzzStache, { TOP.stripeTeeBlack, TOP.leatherWhite, BOTTOM.khaki }, SHOES.dressBrown, { height = 1.06 }),
	-- denim over a loud floral shirt
	npc_mentor_dev = look("dev", HEAD.man, 4, HAIR.curlyTextured, { TOP.floralForest, TOP.denimLight, BOTTOM.beige }, SHOES.canvasGrey, { face = { GLASSES } }),
	-- volunteer orange, basketball shorts, red runners
	npc_volunteer_max = look("max", HEAD.man, 3, HAIR.redPart, { TOP.greyTee, TOP.zipOrange, BOTTOM.ballShortsBlue }, SHOES.runRed),
	-- teal hoodie and shades pushed up
	npc_hacker_alex = look("alex", HEAD.man, 1, HAIR.shadesHair, { TOP.zipTeal, BOTTOM.cargoBlack }, SHOES.highWhite),
	-- black leather over red, white leather pants
	npc_rival_sam = look("sam", HEAD.woman, 5, HAIR.grungePony, { TOP.longSleeveRed, TOP.leatherBlack, BOTTOM.leatherWhite }, SHOES.milBlack),
	-- all black, the guard
	npc_security_ron = look("ron", HEAD.man, 5, HAIR.buzz, { TOP.knitBlack, BOTTOM.formalBlack }, SHOES.milBlack, { height = 1.08, width = 1.1 }),
} :: { [string]: Look }

function Looks.describe(l: Look): HumanoidDescription
	local d = Instance.new("HumanoidDescription")
	d.Torso, d.LeftArm, d.RightArm, d.LeftLeg, d.RightLeg = l.body[1], l.body[2], l.body[3], l.body[4], l.body[5]
	d.Head = l.head
	d.HeadColor, d.TorsoColor = l.skin, l.skin
	d.LeftArmColor, d.RightArmColor, d.LeftLegColor, d.RightLegColor = l.skin, l.skin, l.skin, l.skin
	d.HairAccessory = table.concat(l.hair, ",")
	if l.face then
		d.FaceAccessory = table.concat(l.face, ",")
	end

	local layered = {}
	local function add(id: number, slot: string)
		local s = SLOT[slot]
		table.insert(layered, { AssetId = id, AccessoryType = s[1], IsLayered = true, Order = s[2] })
	end
	for _, item in l.clothes do
		add(item.id, item.slot)
	end
	add(l.shoes[1], "shoeL")
	add(l.shoes[2], "shoeR")
	d:SetAccessories(layered, false)

	d.HeightScale = l.height or 1
	d.WidthScale = l.width or 1
	d.DepthScale = 1
	d.BodyTypeScale = 0.3
	d.ProportionScale = 1
	return d
end

return Looks
