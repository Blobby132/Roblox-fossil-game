--!strict
--[[
	SoundConfig: every sound effect, as one or more layers.

	THESE ARE PLACEHOLDERS. They are built only from the handful of sounds
	that ship inside Roblox itself (rbxasset://sounds/...), re-pitched to tell
	materials apart, so they work with no uploads and no permissions.

	To use a real sound, replace a layer's Id with "rbxassetid://<number>" from
	the Creator Store (Audio tab) and set Pitch back to 1.

	Layer fields:
	  Id      sound asset
	  Volume  0-1
	  Pitch   playback speed; 1 = normal, 2 = an octave up
	  Delay   seconds after the sound is triggered (lets layers form a little tune)
	  Length  cut the layer off after this many seconds
]]

export type SoundLayer = {
	Id: string,
	Volume: number,
	Pitch: number,
	Delay: number?,
	Length: number?,
}

-- The sounds built into Roblox.
local THUD = "rbxasset://sounds/action_jump_land.mp3"
local RUSTLE = "rbxasset://sounds/action_get_up.mp3"
local WHUP = "rbxasset://sounds/action_jump.mp3"
local BOOM = "rbxasset://sounds/impact_explosion_03.mp3"
local TICK = "rbxasset://sounds/volume_slider.ogg"

local SOUNDS: { [string]: { SoundLayer } } = {
	-- Digging
	DirtHit = {
		{ Id = THUD, Volume = 0.45, Pitch = 1.35, Length = 0.3 },
	},
	DirtBreak = {
		{ Id = THUD, Volume = 0.6, Pitch = 0.95 },
		{ Id = BOOM, Volume = 0.12, Pitch = 2.6, Length = 0.35 },
	},
	RockHit = {
		{ Id = THUD, Volume = 0.6, Pitch = 2.1, Length = 0.25 },
		{ Id = TICK, Volume = 0.5, Pitch = 0.75 },
	},
	RockBreak = {
		{ Id = BOOM, Volume = 0.3, Pitch = 1.9, Length = 0.5 },
		{ Id = THUD, Volume = 0.7, Pitch = 0.75 },
	},
	BrushStroke = {
		{ Id = RUSTLE, Volume = 0.3, Pitch = 1.7, Length = 0.22 },
	},

	-- "That didn't work" cues
	WrongTool = {
		{ Id = TICK, Volume = 0.55, Pitch = 0.45 },
	},
	TooFar = {
		{ Id = TICK, Volume = 0.3, Pitch = 0.6 },
	},
	ToolSwitch = {
		{ Id = TICK, Volume = 0.4, Pitch = 1.3 },
	},

	-- A crusted fossil appears where a cell just broke.
	FossilFound = {
		{ Id = THUD, Volume = 0.5, Pitch = 0.7 },
		{ Id = TICK, Volume = 0.5, Pitch = 1.5, Delay = 0.08 },
		{ Id = TICK, Volume = 0.5, Pitch = 2, Delay = 0.18 },
	},

	-- The big moment. RevealStart plays as time slows; the chime plays as the
	-- fossil pops out. Rarer fossils get a longer rising chime.
	RevealStart = {
		{ Id = WHUP, Volume = 0.5, Pitch = 0.55 },
	},
	RevealCommon = {
		{ Id = TICK, Volume = 0.6, Pitch = 1 },
		{ Id = TICK, Volume = 0.6, Pitch = 1.26, Delay = 0.07 },
		{ Id = TICK, Volume = 0.6, Pitch = 1.5, Delay = 0.14 },
	},
	RevealUncommon = {
		{ Id = TICK, Volume = 0.65, Pitch = 1 },
		{ Id = TICK, Volume = 0.65, Pitch = 1.26, Delay = 0.07 },
		{ Id = TICK, Volume = 0.65, Pitch = 1.5, Delay = 0.14 },
		{ Id = TICK, Volume = 0.65, Pitch = 2, Delay = 0.21 },
	},
	RevealRare = {
		{ Id = BOOM, Volume = 0.25, Pitch = 0.8, Length = 0.8 },
		{ Id = TICK, Volume = 0.7, Pitch = 1 },
		{ Id = TICK, Volume = 0.7, Pitch = 1.19, Delay = 0.06 },
		{ Id = TICK, Volume = 0.7, Pitch = 1.5, Delay = 0.12 },
		{ Id = TICK, Volume = 0.7, Pitch = 1.78, Delay = 0.18 },
		{ Id = TICK, Volume = 0.7, Pitch = 2, Delay = 0.24 },
		{ Id = TICK, Volume = 0.7, Pitch = 2.52, Delay = 0.3 },
	},

	-- The plot refills with fresh ground.
	Refill = {
		{ Id = BOOM, Volume = 0.2, Pitch = 0.6, Length = 0.9 },
		{ Id = RUSTLE, Volume = 0.4, Pitch = 0.8 },
	},
}

local SoundConfig = {
	-- Scales every sound effect at once.
	MasterVolume = 1,

	Sounds = SOUNDS,
}

return SoundConfig
