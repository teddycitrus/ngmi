--!strict
--[[
	NPCConfig.luau
	Shared configuration for all NPCs in Code Red: The Hackathon Horror.
	Defines NPC types, spawn positions, patrol waypoints, dialogue trees,
	and corruption/mutation behavior parameters.
]]

export type DialogueOption = {
	text: string,
	responseId: string?, -- nil = end conversation
}

export type DialogueNode = {
	text: string,
	options: { DialogueOption },
}

export type NPCDefinition = {
	id: string,
	displayName: string,
	npcType: string, -- "organizer" | "mentor" | "hacker" | "sponsor"
	hoodieColor: Color3,
	nameColor: Color3,
	canMutate: boolean,
	spawnPosition: Vector3,
	waypoints: { Vector3 },
	hidingSpot: Vector3?, -- where they flee during Night2 if sane
	dialogue: { [string]: DialogueNode }, -- keyed by dialogue node ID
	corruptionLines: { string }?, -- broken syntax they mutter when corrupting
	idleBarks: { string }?, -- unique one-liners shown above their head while idle
}

export type NPCConfigType = {
	npcs: { NPCDefinition },
	patrolIdleMin: number,
	patrolIdleMax: number,
	corruptionParticleColor: Color3,
	corruptionStartMinute: number, -- minute within Day2 when corruption begins
	nameTagOffset: Vector3,
	dialogueProximityDistance: number,
}

-- ============================================================================
-- NPC DEFINITIONS
-- ============================================================================

local NPCConfig: NPCConfigType = {
	-- Patrol timing
	patrolIdleMin = 3,
	patrolIdleMax = 5,

	-- Corruption FX
	corruptionParticleColor = Color3.fromRGB(128, 0, 255),
	corruptionStartMinute = 5, -- 5 minutes into Day2

	-- BillboardGui offset above head
	nameTagOffset = Vector3.new(0, 3, 0),

	-- ProximityPrompt max distance
	dialogueProximityDistance = 8,

	npcs = {
		-- ================================================================
		-- ORGANIZER NPCs (blue hoodies, run the event)
		-- ================================================================
		{
			id = "npc_organizer_sarah",
			displayName = "Sarah (Organizer)",
			npcType = "organizer",
			hoodieColor = Color3.fromRGB(30, 100, 200),
			nameColor = Color3.fromRGB(100, 180, 255),
			canMutate = false,
			spawnPosition = Vector3.new(-120, 3, 0),
			waypoints = {
				Vector3.new(-120, 3, 0),
				Vector3.new(-60, 3, 5),
				Vector3.new(-100, 3, -5),
				Vector3.new(-30, 3, 0),
			},
			hidingSpot = Vector3.new(-150, 3, 0),
			dialogue = {
				start = {
					text = "Welcome to VesperHacks! 48 hours to build something amazing. Find a desk and get started, but maybe talk to the mentors first.",
					options = {
						{ text = "Any tips for a first-timer?", responseId = "tips" },
						{ text = "Where do I find supplies?", responseId = "supplies" },
						{ text = "How do I stay safe after dark?", responseId = "survival_hint" },
						{ text = "Thanks, I'll look around.", responseId = nil },
					},
				},
				survival_hint = {
					text = "Heh. 'Safe.' Okay, real talk: if something comes at you, SPRINT. Hold Shift, just watch your energy bar (an energy bar refills it instantly). A faceful of deodorant stuns them. Duck into a hiding spot if you must. And keep shipping your project at YOUR desk. Follow the marker to find it.",
					options = {
						{ text = "...You're serious.", responseId = "warning" },
						{ text = "Good to know, thanks.", responseId = nil },
					},
				},
				tips = {
					text = "Pace yourself. Seriously. People who pull all-nighters on day one always burn out. Also... stay hydrated. The vending machines have some, uh, interesting options.",
					options = {
						{ text = "Noted. Anything else?", responseId = "warning" },
						{ text = "Got it, thanks!", responseId = nil },
					},
				},
				supplies = {
					text = "Check the supply closets around the venue. Snacks, energy drinks, deodorant... you'd be surprised what becomes valuable at 3 AM.",
					options = {
						{ text = "Deodorant? Really?", responseId = "deodorant_hint" },
						{ text = "I'll keep an eye out.", responseId = nil },
					},
				},
				warning = {
					text = "One more thing. If someone starts acting... off... just give them space. Sleep deprivation does weird things to people.",
					options = {
						{ text = "That's ominous.", responseId = nil },
					},
				},
				deodorant_hint = {
					text = "Trust me. By hour 30, it's the most powerful weapon in the building. *laughs nervously* I mean... socially.",
					options = {
						{ text = "Right... thanks.", responseId = nil },
					},
				},
			},
			corruptionLines = nil,
			idleBarks = {
				"Badges at the front desk, folks!",
				"WiFi password is 'hunter2', all lowercase.",
				"Pace yourselves. It's a long couple of days.",
				"Demos are Sunday at 4. Don't be late!",
				"Has anyone seen the other organizer? ...weird.",
			},
		},

		-- ================================================================
		-- MENTOR NPCs (green hoodies, give coding advice)
		-- ================================================================
		{
			id = "npc_mentor_dev",
			displayName = "Dev (Mentor)",
			npcType = "mentor",
			hoodieColor = Color3.fromRGB(30, 180, 80),
			nameColor = Color3.fromRGB(80, 255, 120),
			canMutate = true,
			spawnPosition = Vector3.new(-20, 3, 0),
			waypoints = {
				Vector3.new(-20, 3, 0),
				Vector3.new(-80, 3, 0),
				Vector3.new(40, 3, 5),
			},
			hidingSpot = nil, -- mutates, no hiding spot needed
			dialogue = {
				start = {
					text = "Hey! Need help with your project? I've been mentoring hackathons for years. What are you working on?",
					options = {
						{ text = "I'm building a survival game.", responseId = "survival" },
						{ text = "Still figuring it out.", responseId = "figuring" },
						{ text = "Just exploring, thanks.", responseId = nil },
					},
				},
				survival = {
					text = "Survival, huh? Make sure your game loop is tight. Players need clear goals and constant tension. Kind of like... this hackathon. *scratches neck*",
					options = {
						{ text = "Are you okay?", responseId = "okay" },
						{ text = "Good advice, thanks!", responseId = nil },
					},
				},
				figuring = {
					text = "No rush. Best projects come from unexpected inspiration. Just... don't wait too long. Time moves differently here after midnight.",
					options = {
						{ text = "What do you mean?", responseId = "okay" },
						{ text = "I'll figure something out.", responseId = nil },
					},
				},
				okay = {
					text = "Yeah, yeah, I'm fine. Just... haven't slept. The code keeps... whispering? No, that's not right. Forget I said that.",
					options = {
						{ text = "Maybe you should take a break.", responseId = nil },
					},
				},
			},
			corruptionLines = {
				"while(true) { CONSUME(); }",
				"ERROR: humanity not found",
				"segfault in soul.exe",
				"npm install --save madness",
				"git commit -m 'lost myself'",
				"undefined is not a person",
				"STACK OVERFLOW in consciousness",
			},
			idleBarks = {
				"Need help? I've debugged worse than your code.",
				"Have you tried turning it off and on again?",
				"Commit early, commit often, people.",
				"Coffee is the real package manager.",
				"My fifth energy drink is hitting different...",
			},
		},

		-- ================================================================
		-- HACKER NPCs (purple hoodies, fellow participants)
		-- ================================================================
		{
			id = "npc_hacker_alex",
			displayName = "Alex (Hacker)",
			npcType = "hacker",
			hoodieColor = Color3.fromRGB(140, 60, 180),
			nameColor = Color3.fromRGB(200, 130, 255),
			canMutate = true,
			spawnPosition = Vector3.new(40, 3, 0),
			waypoints = {
				Vector3.new(40, 3, 0),
				Vector3.new(110, 3, 0),
				Vector3.new(0, 3, -5),
			},
			hidingSpot = nil,
			dialogue = {
				start = {
					text = "Shh, I'm in the zone. My neural network is almost sentient. Just need more training data... more data... MORE DATA.",
					options = {
						{ text = "That sounds... ambitious.", responseId = "ambitious" },
						{ text = "I'll leave you to it.", responseId = nil },
					},
				},
				ambitious = {
					text = "Ambitious? No. Inevitable. The code wants to be written. I'm just the vessel. Don't you feel it too? The pull?",
					options = {
						{ text = "You should probably sleep.", responseId = "sleep" },
						{ text = "Nope. Good luck though!", responseId = nil },
					},
				},
				sleep = {
					text = "Sleep is just your brain's garbage collector. I've optimized mine. No need for sleep when you're... becoming... the algorithm...",
					options = {
						{ text = "Okay, that's terrifying. Bye.", responseId = nil },
					},
				},
			},
			corruptionLines = {
				"TRAINING EPOCH ∞",
				"loss = NaN",
				"model.predict(FLESH)",
				"tensor overflow in cortex",
				"backpropagating through reality",
				"gradient descent into madness",
			},
			idleBarks = {
				"Almost have AGI. Just need more compute.",
				"Sleep is a skill issue.",
				"My model is SO close to sentient. So close.",
				"More data. I just need MORE data.",
				"Don't talk to me, I'm in the zone.",
			},
		},

		-- ================================================================
		-- SPONSOR NPC (yellow hoodie, corporate rep)
		-- ================================================================
		{
			id = "npc_sponsor_jordan",
			displayName = "Jordan (Sponsor)",
			npcType = "sponsor",
			hoodieColor = Color3.fromRGB(220, 180, 30),
			nameColor = Color3.fromRGB(255, 220, 80),
			canMutate = false,
			spawnPosition = Vector3.new(-90, 3, 0),
			waypoints = {
				Vector3.new(-90, 3, 0),
				Vector3.new(-140, 3, 0),
				Vector3.new(-40, 3, 5),
				Vector3.new(-90, 3, -5),
			},
			hidingSpot = Vector3.new(-150, 3, 5),
			dialogue = {
				start = {
					text = "Hey there! I'm Jordan from MegaCorp. We're sponsoring the API challenge. Build something cool with our SDK and win a prize!",
					options = {
						{ text = "What's the prize?", responseId = "prize" },
						{ text = "What does MegaCorp do?", responseId = "megacorp" },
						{ text = "Maybe later, thanks.", responseId = nil },
					},
				},
				prize = {
					text = "Top prize is a year of free cloud credits and... well, the real prize is the experience, right? *corporate smile*",
					options = {
						{ text = "Sure... thanks.", responseId = nil },
					},
				},
				megacorp = {
					text = "We provide enterprise solutions for... actually, between you and me, even I don't fully understand what we do. But the API is solid!",
					options = {
						{ text = "Honest. I respect that.", responseId = nil },
					},
				},
			},
			corruptionLines = nil,
			idleBarks = {
				"Ask me about the MegaCorp API challenge!",
				"We're hiring, by the way. Always hiring.",
				"Synergy. Disruption. Blockchain. You get it.",
				"Swing by our booth for free stickers!",
				"Per my last email... wait, wrong crowd.",
			},
		},

		-- ================================================================
		-- JUDGE NPC (deep purple blazer, evaluates the projects)
		-- ================================================================
		{
			id = "npc_judge_priya",
			displayName = "Priya (Judge)",
			npcType = "judge",
			hoodieColor = Color3.fromRGB(120, 40, 160),
			nameColor = Color3.fromRGB(210, 150, 255),
			canMutate = false,
			spawnPosition = Vector3.new(-95, 3, 0),
			waypoints = { Vector3.new(-95, 3, 0) },
			hidingSpot = Vector3.new(-150, 3, -5),
			dialogue = {
				start = {
					text = "I'm one of the judges. I've reviewed nine hundred demos in my career, and I can tell you the secret to a winning project in three words.",
					options = {
						{ text = "What are they?", responseId = "secret" },
						{ text = "How's the judging work?", responseId = "process" },
						{ text = "No pressure then. Bye.", responseId = nil },
					},
				},
				secret = {
					text = "\"Make it work.\" A flashy slide deck won't save a broken build. Ship something that runs (at YOUR desk, follow the marker) and you're already ahead of half the room.",
					options = {
						{ text = "Solid advice.", responseId = nil },
						{ text = "And after midnight?", responseId = "midnight" },
					},
				},
				process = {
					text = "We score on completion, originality and... survival. That last one's new this year. Management insisted. I didn't ask why.",
					options = {
						{ text = "Survival? That's a weird metric.", responseId = "midnight" },
						{ text = "Noted. Thanks.", responseId = nil },
					},
				},
				midnight = {
					text = "Just... finish your project before the second night. The judges who stayed late last year didn't submit anything. We never found their entries. Or them.",
					options = {
						{ text = "...I'll hurry.", responseId = nil },
					},
				},
			},
			corruptionLines = nil,
			idleBarks = {
				"Completion beats ambition. Every time.",
				"I've seen a to-do app win. It worked, that's why.",
				"Demos at four. Working demos.",
				"Don't gold-plate a sinking ship.",
			},
		},

		-- ================================================================
		-- VOLUNTEER NPC (teal vest, runs the coffee bar)
		-- ================================================================
		{
			id = "npc_volunteer_max",
			displayName = "Max (Volunteer)",
			npcType = "volunteer",
			hoodieColor = Color3.fromRGB(20, 150, 150),
			nameColor = Color3.fromRGB(120, 240, 240),
			canMutate = false,
			spawnPosition = Vector3.new(15, 3, 0),
			waypoints = { Vector3.new(15, 3, 0) },
			hidingSpot = Vector3.new(-150, 3, 5),
			dialogue = {
				start = {
					text = "Coffee bar's that way, but between us the machine's been making the weirdest noises since last night. Want a cup anyway?",
					options = {
						{ text = "Sure, I need the caffeine.", responseId = "coffee" },
						{ text = "What kind of noises?", responseId = "noises" },
						{ text = "I'll pass, thanks.", responseId = nil },
					},
				},
				coffee = {
					text = "Atta dev. Pro tip: grab an energy bar from the supply rooms too. It instantly refills your sprint energy when you're running on empty. Or running, period.",
					options = {
						{ text = "Running from what?", responseId = "noises" },
						{ text = "Good looking out. Thanks!", responseId = nil },
					},
				},
				noises = {
					text = "Like... whispering? In the grinder? I keep telling the organizers and they keep changing the subject. I'm a volunteer, man, this is above my pay grade. Which is zero.",
					options = {
						{ text = "Maybe report it again.", responseId = nil },
						{ text = "Stay safe, Max.", responseId = nil },
					},
				},
			},
			corruptionLines = nil,
			idleBarks = {
				"Fresh pot's brewing! Probably.",
				"Refills are free, sleep is not.",
				"Energy bars by the supply closet, folks.",
				"Did the lights just flicker, or is that me?",
			},
		},

		-- ================================================================
		-- RIVAL HACKER NPC (red hoodie, fellow participant, mutates)
		-- ================================================================
		{
			id = "npc_rival_sam",
			displayName = "Sam (Rival)",
			npcType = "hacker",
			hoodieColor = Color3.fromRGB(200, 50, 50),
			nameColor = Color3.fromRGB(255, 120, 120),
			canMutate = true,
			spawnPosition = Vector3.new(75, 3, 0),
			waypoints = { Vector3.new(75, 3, 0) },
			hidingSpot = nil,
			dialogue = {
				start = {
					text = "Oh, YOU'RE the competition? Cute. I've got a forty-thousand-line monorepo and zero working features. We're basically the same.",
					options = {
						{ text = "Forty thousand lines?!", responseId = "lines" },
						{ text = "Good luck out there.", responseId = nil },
					},
				},
				lines = {
					text = "Most of it's auto-generated. Some of it generated itself. I didn't write the last commit. I... don't remember writing the last commit. Have you slept? I haven't slept.",
					options = {
						{ text = "You should rest, Sam.", responseId = "rest" },
						{ text = "That's a you problem. Bye.", responseId = nil },
					},
				},
				rest = {
					text = "Rest is for projects that compile. I'll sleep when it ships, or when it ships ME. Ha. Ha. ...that wasn't a joke. Why isn't it a joke?",
					options = {
						{ text = "Okay, I'm going now.", responseId = nil },
					},
				},
			},
			corruptionLines = {
				"merge conflict in self/identity",
				"rm -rf ~/conscience",
				"40000 lines, 0 humans",
				"who wrote this. who wrote ME.",
				"fork(): cannot allocate soul",
			},
			idleBarks = {
				"My repo is bigger than yours.",
				"Sleep is a merge conflict I keep deferring.",
				"I'm not behind, YOU'RE behind.",
				"The commit history is... watching me.",
			},
		},

		-- ================================================================
		-- SECURITY NPC (navy uniform, knows the building)
		-- ================================================================
		{
			id = "npc_security_ron",
			displayName = "Ron (Security)",
			npcType = "security",
			hoodieColor = Color3.fromRGB(30, 45, 90),
			nameColor = Color3.fromRGB(140, 170, 230),
			canMutate = false,
			spawnPosition = Vector3.new(100, 3, 0),
			waypoints = { Vector3.new(100, 3, 0) },
			hidingSpot = Vector3.new(145, 3, 0),
			dialogue = {
				start = {
					text = "Evening. I work the night shift here. Word of advice: learn where the exits and hiding spots are NOW, while the lights are still on.",
					options = {
						{ text = "Hiding spots? From who?", responseId = "who" },
						{ text = "Where are the panels?", responseId = "panels" },
						{ text = "Thanks, officer.", responseId = nil },
					},
				},
				who = {
					text = "Couldn't tell you. But I've patrolled this building twelve years and the third floor never used to have a third floor. During Night Two, if the power drops, you do NOT want to be caught in the open.",
					options = {
						{ text = "How do I fight back?", responseId = "fight" },
						{ text = "Comforting. Thanks.", responseId = nil },
					},
				},
				panels = {
					text = "Electrical panels are in the supply rooms, one per floor. If something trips the power at night, you repair the panel to bring the lights back. Lights matter. Trust me on that.",
					options = {
						{ text = "What about defending myself?", responseId = "fight" },
						{ text = "Got it. Thanks, Ron.", responseId = nil },
					},
				},
				fight = {
					text = "Deodorant. I know how that sounds, but a faceful stuns 'em long enough to run. Keep one on you at all times after dark. And SPRINT, don't try to be a hero.",
					options = {
						{ text = "I owe you one, Ron.", responseId = nil },
					},
				},
			},
			corruptionLines = nil,
			idleBarks = {
				"Keep them exits clear, people.",
				"Twelve years here. Never seen a third floor till now.",
				"Lights go out, you find a hiding spot. Simple.",
				"Badge stays on you at all times.",
			},
		},
	},
}

return NPCConfig
