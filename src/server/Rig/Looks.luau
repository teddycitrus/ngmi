--!strict
--------------------------------------------------------------------------------
-- Rig/Looks.luau
-- What every venue person looks like. Every rig is an R15 rig on a realistic
-- body from the avatar shop (sculpted head and face, human proportions),
-- dressed in 3D layered clothing (shirts, jackets, pants, shoes that wrap the
-- body) and mesh hair from the catalog.
--
--   Looks.CROWD   4 everyday outfits the ambient crowd and bodies cycle through
--   Looks.NAMED   one outfit per named NPC (NPCConfig id), loud enough to pick
--                 out across a room but still something a person would wear
--   Looks.describe(look) -> HumanoidDescription
--
-- Every id was checked against the catalog (AvatarEditorService:SearchCatalog,
-- and AssetService:GetBundleDetailsAsync for the body and shoe bundles).
--------------------------------------------------------------------------------

local Looks = {}

-- Realistic bodies from the avatar shop: { torso, leftArm, rightArm, leftLeg,
-- rightLeg } plus the bundle's own head. The faces carry their skin tone in
-- their texture, so `skin` is matched to each face by eye and paints the
-- body to agree with it.
type Person = { parts: { number }, head: number, skin: Color3 }
local PERSON: { [string]: Person } = {
	-- Realistic Man (bundle 69789692964194)
	deshawn = { parts = { 138907177261262, 126046002303149, 118864558463272, 92711794919815, 91754700430259 }, head = 95348374554700, skin = Color3.fromRGB(96, 62, 44) },
	-- Fashion Model Man (bundle 148843544796522)
	kenji = { parts = { 136484138279485, 133656943925070, 99161622704680, 108570629440593, 94210819268147 }, head = 138914865792933, skin = Color3.fromRGB(226, 190, 160) },
	-- Model Man (bundle 261708299650319)
	luke = { parts = { 137818495202071, 94670898413446, 121780194799365, 116349841260868, 71235686557283 }, head = 108356625707649, skin = Color3.fromRGB(232, 196, 170) },
	-- January Model Man (bundle 272889456128840)
	mateo = { parts = { 106062650582720, 93273068870672, 123504742874685, 109637020907933, 108488675090572 }, head = 126811571812177, skin = Color3.fromRGB(188, 138, 102) },
	-- Realistic Model Woman Doll (bundle 64276026698783)
	emma = { parts = { 74203867041109, 89294577189357, 85761870061455, 72013766986908, 139331641629327 }, head = 139734314809040, skin = Color3.fromRGB(236, 202, 182) },
	-- Woman Fashion Model Doll (bundle 181282816119101)
	mei = { parts = { 122831550366162, 106832235837446, 95246976223366, 124333485905753, 86653892031792 }, head = 76846031172896, skin = Color3.fromRGB(238, 206, 186) },
	-- January Model Doll (bundle 75057502474636)
	sofia = { parts = { 71835459452885, 97633279696517, 89067250563417, 88496750791076, 114123828483948 }, head = 87394201185324, skin = Color3.fromRGB(214, 172, 140) },
	-- Brooklyn Doll (bundle 224122577429494)
	nia = { parts = { 92278383716524, 132260325803558, 111879510820046, 117428460379794, 117551628750694 }, head = 123932090578829, skin = Color3.fromRGB(140, 94, 64) },
	-- Candace Bombshell Model Doll (bundle 61735626675336)
	claire = { parts = { 132575045898664, 100245578215277, 77668477857770, 90161472817698, 100852877018675 }, head = 70787010654497, skin = Color3.fromRGB(240, 212, 196) },
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
	blackBuzz = 14631577537, -- Black Buzz Cut (sinks into the realistic heads; reads bald)
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
	person: Person,
	hair: { number },
	face: { number }?,
	clothes: { Item },
	shoes: { number },
	height: number?, -- multiplier on RigFactory's standing height
	width: number?,
}

local function look(key: string, person: Person, hair: number, clothes: { Item }, shoes: { number }, extra: { [string]: any }?): Look
	local l: any = { key = key, person = person, hair = { hair }, clothes = clothes, shoes = shoes }
	for k, v in extra or {} do
		l[k] = v
	end
	return l :: Look
end

-- The crowd: four plain hackathon outfits, each on its own person.
Looks.CROWD = {
	look("crowdA", PERSON.kenji, HAIR.brownLayered, { TOP.greyTee, TOP.zipBlack, BOTTOM.jeans }, SHOES.sneakerWhite),
	look("crowdB", PERSON.sofia, HAIR.brownBun, { TOP.knitBeige, BOTTOM.jeansDark }, SHOES.canvasWhite, { height = 0.95 }),
	look("crowdC", PERSON.deshawn, HAIR.blackCurly, { TOP.flannelGreen, BOTTOM.cargoBrown }, SHOES.bootsTan),
	look("crowdD", PERSON.nia, HAIR.blackCurly, { TOP.greyTee, TOP.hoodedGrey, BOTTOM.sweatsBlack }, SHOES.sneakerGrey, { height = 0.95 }),
} :: { Look }

-- The named NPCs: each one a colour and cut nobody in the crowd wears.
Looks.NAMED = {
	-- salmon blazer on stage, readable from the back row
	npc_organizer_sarah = look("sarah", PERSON.emma, HAIR.blonde, { TOP.stripeTeeWhite, TOP.coatSalmon, BOTTOM.formalBlack }, SHOES.flatsBlack, { height = 0.95 }),
	-- red ruffle skirt under a pinstripe coat
	npc_judge_priya = look("priya", PERSON.mei, HAIR.salonBun, { TOP.tieTopWhite, TOP.coatStripe, BOTTOM.ruffleRed }, SHOES.dressBlack, { face = { GLASSES }, height = 0.95 }),
	-- white leather jacket, the sponsor money look
	npc_sponsor_jordan = look("jordan", PERSON.deshawn, HAIR.buzzStache, { TOP.stripeTeeBlack, TOP.leatherWhite, BOTTOM.khaki }, SHOES.dressBrown, { height = 1.03 }),
	-- denim over a loud floral shirt
	npc_mentor_dev = look("dev", PERSON.mateo, HAIR.curlyTextured, { TOP.floralForest, TOP.denimLight, BOTTOM.beige }, SHOES.canvasGrey, { face = { GLASSES } }),
	-- volunteer orange, basketball shorts, red runners
	npc_volunteer_max = look("max", PERSON.luke, HAIR.redPart, { TOP.greyTee, TOP.zipOrange, BOTTOM.ballShortsBlue }, SHOES.runRed),
	-- teal hoodie and shades pushed up
	npc_hacker_alex = look("alex", PERSON.kenji, HAIR.shadesHair, { TOP.stripeTeeBlack, TOP.zipTeal, BOTTOM.cargoBlack }, SHOES.highWhite),
	-- black leather over red, white leather pants
	npc_rival_sam = look("sam", PERSON.claire, HAIR.grungePony, { TOP.longSleeveRed, TOP.leatherBlack, BOTTOM.leatherWhite }, SHOES.milBlack, { height = 0.95 }),
	-- all black, the guard
	npc_security_ron = look("ron", PERSON.mateo, HAIR.buzz, { TOP.knitBlack, BOTTOM.formalBlack }, SHOES.milBlack, { height = 1.04, width = 1.08 }),
} :: { [string]: Look }

function Looks.describe(l: Look): HumanoidDescription
	local d = Instance.new("HumanoidDescription")
	local p = l.person
	d.Torso, d.LeftArm, d.RightArm, d.LeftLeg, d.RightLeg = p.parts[1], p.parts[2], p.parts[3], p.parts[4], p.parts[5]
	d.Head = p.head
	d.HeadColor, d.TorsoColor = p.skin, p.skin
	d.LeftArmColor, d.RightArmColor, d.LeftLegColor, d.RightLegColor = p.skin, p.skin, p.skin, p.skin
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

	-- The bodies' own adult build. BodyTypeScale below 1 pulls a shop body
	-- toward classic Roblox proportions (big head, short legs), which is what
	-- made the crowd read as children. Overall size is set by RigFactory.
	d.HeightScale = 1
	d.WidthScale = l.width or 1
	d.DepthScale = 1
	d.HeadScale = 1
	d.BodyTypeScale = 1
	d.ProportionScale = 0
	return d
end

return Looks
