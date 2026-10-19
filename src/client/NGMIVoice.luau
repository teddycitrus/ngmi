--!strict
--------------------------------------------------------------------------------
-- NGMIVoice.luau  (ModuleScript, required by NGMIAnimator)
-- The noises an NGMI makes, played locally as 3D sounds from its head.
--
-- Clicker-style: a wet, ratcheting click in the throat while it searches,
-- growls and slobbering mutters on patrol, a screech when it spots you, snarls
-- through a chase and on every swing, and a tortured whimper when sprayed.
-- All of it runs through one SoundGroup with distortion and a long reverb, so
-- the venue's corridors carry it.
--
-- Every id is a public ProSoundEffects asset from the Creator Store, pitched
-- and slowed into something that isn't an animal any more.
--------------------------------------------------------------------------------

local SoundService = game:GetService("SoundService")

local NGMIVoice = {}

type Bank = { ids: { string }, speed: NumberRange, volume: number }

local BANKS: { [string]: Bank } = {
	-- "Sprite Chitter": ratchety insect clicks, slowed into a throat click
	click = {
		ids = { "rbxassetid://9119532149", "rbxassetid://9119531802", "rbxassetid://9119532174", "rbxassetid://9119532554" },
		speed = NumberRange.new(0.48, 0.66),
		volume = 1.1,
	},
	-- "Creature Vocal Spider Growls"
	growl = {
		ids = { "rbxassetid://9113989724", "rbxassetid://9113989720", "rbxassetid://9113989715", "rbxassetid://9113989805" },
		speed = NumberRange.new(0.62, 0.82),
		volume = 0.9,
	},
	-- "Robot Vocal Wet Slobbery Mumbled Nonsense"
	mutter = {
		ids = { "rbxassetid://9118546600" },
		speed = NumberRange.new(0.5, 0.7),
		volume = 0.8,
	},
	-- "Creature Vocal Spider Growl Belch Hiss Snarl"
	snarl = {
		ids = { "rbxassetid://9125475729", "rbxassetid://9125475724", "rbxassetid://9125475751", "rbxassetid://9125476000" },
		speed = NumberRange.new(0.82, 1.0),
		volume = 1.2,
	},
	-- a snarl pitched up, and a chimp bark dragged down into a shriek
	screech = {
		ids = { "rbxassetid://9125476001", "rbxassetid://9113793916" },
		speed = NumberRange.new(0.66, 1.2),
		volume = 1.4,
	},
	-- "Robot Vocal Tortured Vocalizations"
	pain = {
		ids = { "rbxassetid://9125833623" },
		speed = NumberRange.new(0.62, 0.78),
		volume = 1.0,
	},
}

local HEAR_RANGE = 95

local group: SoundGroup? = nil
local function getGroup(): SoundGroup
	if group and group.Parent then
		return group
	end
	local g = Instance.new("SoundGroup")
	g.Name = "NGMIVoice"
	g.Volume = 0.9
	local dist = Instance.new("DistortionSoundEffect")
	dist.Level = 0.32
	dist.Priority = 2
	dist.Parent = g
	local verb = Instance.new("ReverbSoundEffect")
	verb.DecayTime = 2.2
	verb.Density = 0.8
	verb.Diffusion = 0.9
	verb.DryLevel = -2
	verb.WetLevel = -9
	verb.Priority = 1
	verb.Parent = g
	g.Parent = SoundService
	group = g
	return g
end

export type Voice = {
	play: (self: Voice, kind: string) -> (),
	update: (self: Voice, dt: number, state: string?, distance: number) -> string?,
	destroy: (self: Voice) -> (),
}

local rng = Random.new()

--- Attach a voice to an NGMI. Sounds live on its head, one per bank.
function NGMIVoice.attach(model: Model): Voice?
	local head = model:FindFirstChild("Head")
	if not (head and head:IsA("BasePart")) then
		return nil
	end
	local sounds: { [string]: Sound } = {}
	local nextAmbient = rng:NextNumber(1, 4)

	local function soundFor(kind: string): Sound
		local s = sounds[kind]
		if s and s.Parent then
			return s
		end
		local snd = Instance.new("Sound")
		snd.Name = "NGMI_" .. kind
		snd.SoundGroup = getGroup()
		snd.RollOffMode = Enum.RollOffMode.InverseTapered
		snd.RollOffMinDistance = 7
		snd.RollOffMaxDistance = HEAR_RANGE
		snd.Parent = head
		sounds[kind] = snd
		return snd
	end

	local voice = {} :: any

	function voice.play(_self: Voice, kind: string)
		local bank = BANKS[kind]
		if not bank then
			return
		end
		local snd = soundFor(kind)
		snd.SoundId = bank.ids[rng:NextInteger(1, #bank.ids)]
		snd.PlaybackSpeed = rng:NextNumber(bank.speed.Min, bank.speed.Max)
		snd.Volume = bank.volume * rng:NextNumber(0.85, 1.1)
		snd.TimePosition = 0
		snd:Play()
	end

	--- Ambient chatter for the current AI state. Returns "click" on the frame
	--- a click burst starts, so the animator can rattle the head in time.
	function voice.update(self: Voice, dt: number, state: string?, distance: number): string?
		nextAmbient -= dt
		if nextAmbient > 0 or distance > HEAR_RANGE then
			return nil
		end
		local r = rng:NextNumber()
		local event: string? = nil
		if state == "CHASE" then
			nextAmbient = rng:NextNumber(1.2, 2.4)
			if r < 0.6 then
				self:play("snarl")
			else
				self:play("click")
				event = "click"
			end
		elseif state == "LOST" or state == "ALERT" then
			-- searching: clicking to find you
			nextAmbient = rng:NextNumber(0.9, 2.2)
			self:play("click")
			event = "click"
		elseif state == "RETREAT" or state == "STUNNED" then
			nextAmbient = rng:NextNumber(1.2, 2.0)
			self:play("pain")
		elseif state == "ATTACK" then
			nextAmbient = rng:NextNumber(1.5, 2.5)
		else
			nextAmbient = rng:NextNumber(2.2, 5.5)
			if r < 0.5 then
				self:play("click")
				event = "click"
			elseif r < 0.82 then
				self:play("growl")
			else
				self:play("mutter")
			end
		end
		return event
	end

	function voice.destroy(_self: Voice)
		for _, s in sounds do
			s:Destroy()
		end
		table.clear(sounds)
	end

	return voice :: Voice
end

return NGMIVoice
