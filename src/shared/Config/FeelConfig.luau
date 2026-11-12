--!strict
--[[
	FeelConfig: everything about how digging FEELS. Nothing in here changes
	the rules of the game; it is all client-side feedback, so it is safe to
	tune freely while playtesting.

	Sounds are named here and defined in SoundConfig.
]]

export type MaterialFeel = {
	HitSound: string,
	BreakSound: string,
	HitParticles: string,
	BreakParticles: string,
	HitShake: number, -- camera shake added per hit, 0-1
	BreakShake: number, -- camera shake added when the cell breaks, 0-1
	DebrisCount: number, -- crumble pieces thrown when the cell breaks
}

export type RarityFeel = {
	Sound: string,
	Intensity: number, -- scales sparkle count and light brightness
	Shake: number, -- camera shake as the fossil pops out, 0-1
	ExtraSlow: number, -- extra seconds of slow motion before the pop
}

export type ParticleDef = {
	Texture: string,
	Color: Color3,
	Count: number,
	Lifetime: NumberRange,
	Speed: NumberRange,
	SizeStart: number,
	SizeEnd: number,
	TransparencyStart: number,
	TransparencyEnd: number,
	SpreadAngle: number, -- degrees around the surface that was hit
	Acceleration: Vector3,
	Drag: number,
	RotSpeed: NumberRange,
	LightEmission: number,
}

-- Particle textures built into Roblox.
local SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"

local MATERIALS: { [string]: MaterialFeel } = {
	Dirt = {
		HitSound = "DirtHit",
		BreakSound = "DirtBreak",
		HitParticles = "DirtPuff",
		BreakParticles = "DirtBurst",
		HitShake = 0,
		BreakShake = 0.1,
		DebrisCount = 6,
	},
	Rock = {
		HitSound = "RockHit",
		BreakSound = "RockBreak",
		HitParticles = "RockChips",
		BreakParticles = "RockBurst",
		HitShake = 0.25,
		BreakShake = 0.45,
		DebrisCount = 9,
	},
}

local RARITY_FEEL: { [string]: RarityFeel } = {
	Common = { Sound = "RevealCommon", Intensity = 1, Shake = 0.2, ExtraSlow = 0 },
	Uncommon = { Sound = "RevealUncommon", Intensity = 1.35, Shake = 0.35, ExtraSlow = 0.1 },
	Rare = { Sound = "RevealRare", Intensity = 1.9, Shake = 0.6, ExtraSlow = 0.3 },
}

local PARTICLES: { [string]: ParticleDef } = {
	DirtPuff = {
		Texture = SMOKE,
		Color = Color3.fromRGB(150, 115, 80),
		Count = 5,
		Lifetime = NumberRange.new(0.25, 0.5),
		Speed = NumberRange.new(4, 9),
		SizeStart = 0.8,
		SizeEnd = 1.8,
		TransparencyStart = 0.4,
		TransparencyEnd = 1,
		SpreadAngle = 50,
		Acceleration = Vector3.new(0, -10, 0),
		Drag = 3,
		RotSpeed = NumberRange.new(-120, 120),
		LightEmission = 0,
	},
	DirtBurst = {
		Texture = SMOKE,
		Color = Color3.fromRGB(150, 115, 80),
		Count = 14,
		Lifetime = NumberRange.new(0.4, 0.8),
		Speed = NumberRange.new(7, 15),
		SizeStart = 1.2,
		SizeEnd = 3,
		TransparencyStart = 0.3,
		TransparencyEnd = 1,
		SpreadAngle = 80,
		Acceleration = Vector3.new(0, -14, 0),
		Drag = 3,
		RotSpeed = NumberRange.new(-120, 120),
		LightEmission = 0,
	},
	RockChips = {
		Texture = SMOKE,
		Color = Color3.fromRGB(172, 174, 180),
		Count = 6,
		Lifetime = NumberRange.new(0.2, 0.4),
		Speed = NumberRange.new(8, 16),
		SizeStart = 0.5,
		SizeEnd = 1,
		TransparencyStart = 0.2,
		TransparencyEnd = 1,
		SpreadAngle = 60,
		Acceleration = Vector3.new(0, -30, 0),
		Drag = 2,
		RotSpeed = NumberRange.new(-200, 200),
		LightEmission = 0,
	},
	RockBurst = {
		Texture = SMOKE,
		Color = Color3.fromRGB(172, 174, 180),
		Count = 16,
		Lifetime = NumberRange.new(0.4, 0.8),
		Speed = NumberRange.new(9, 18),
		SizeStart = 1,
		SizeEnd = 2.6,
		TransparencyStart = 0.25,
		TransparencyEnd = 1,
		SpreadAngle = 80,
		Acceleration = Vector3.new(0, -24, 0),
		Drag = 2.5,
		RotSpeed = NumberRange.new(-200, 200),
		LightEmission = 0,
	},
	CrustDust = {
		Texture = SMOKE,
		Color = Color3.fromRGB(190, 165, 125),
		Count = 4,
		Lifetime = NumberRange.new(0.3, 0.6),
		Speed = NumberRange.new(2, 6),
		SizeStart = 0.6,
		SizeEnd = 1.6,
		TransparencyStart = 0.5,
		TransparencyEnd = 1,
		SpreadAngle = 70,
		Acceleration = Vector3.new(0, 2, 0),
		Drag = 4,
		RotSpeed = NumberRange.new(-90, 90),
		LightEmission = 0,
	},
	FossilGlint = {
		Texture = SPARKLE,
		Color = Color3.fromRGB(255, 245, 200),
		Count = 8,
		Lifetime = NumberRange.new(0.4, 0.8),
		Speed = NumberRange.new(3, 7),
		SizeStart = 0.5,
		SizeEnd = 0,
		TransparencyStart = 0,
		TransparencyEnd = 1,
		SpreadAngle = 180,
		Acceleration = Vector3.new(0, 0, 0),
		Drag = 2,
		RotSpeed = NumberRange.new(-180, 180),
		LightEmission = 1,
	},
	-- Colour is replaced by the fossil's rarity colour.
	RevealSparkle = {
		Texture = SPARKLE,
		Color = Color3.fromRGB(255, 255, 255),
		Count = 26,
		Lifetime = NumberRange.new(0.7, 1.4),
		Speed = NumberRange.new(6, 14),
		SizeStart = 0.9,
		SizeEnd = 0,
		TransparencyStart = 0,
		TransparencyEnd = 1,
		SpreadAngle = 180,
		Acceleration = Vector3.new(0, -6, 0),
		Drag = 2.5,
		RotSpeed = NumberRange.new(-180, 180),
		LightEmission = 1,
	},
	RefillDust = {
		Texture = SMOKE,
		Color = Color3.fromRGB(150, 115, 80),
		Count = 30,
		Lifetime = NumberRange.new(0.6, 1.2),
		Speed = NumberRange.new(10, 24),
		SizeStart = 3,
		SizeEnd = 8,
		TransparencyStart = 0.4,
		TransparencyEnd = 1,
		SpreadAngle = 85,
		Acceleration = Vector3.new(0, -8, 0),
		Drag = 2,
		RotSpeed = NumberRange.new(-60, 60),
		LightEmission = 0,
	},
}

local FeelConfig = {
	-- Rising pitch on consecutive hits.
	Combo = {
		Window = 1.2, -- a gap longer than this (seconds) resets the pitch
		PitchStep = 0.04, -- pitch added per consecutive hit
		MaxSteps = 10, -- pitch stops rising after this many hits
		PitchJitter = 0.03, -- random +/- so repeated hits never sound identical
	},

	CameraShake = {
		Enabled = true,
		MaxOffset = 0.35, -- studs, at full strength
		MaxRoll = 1, -- degrees, at full strength
		Decay = 4.5, -- strength lost per second
		Frequency = 26, -- how fast it rattles
	},

	Materials = MATERIALS,

	-- How a cell reacts to each hit before it breaks.
	CellHit = {
		PunchSquash = 0.1, -- cell shrinks by this fraction for an instant
		PunchDrop = 0.2, -- and is knocked down this many studs
		PunchTime = 0.1, -- seconds to spring back
		DamageShrink = 0.07, -- shrink (fraction) as a cell nears breaking
		DamageDarken = 0.18, -- darkening (fraction) as a cell nears breaking
		DamageTilt = 3, -- degrees of wobble as a cell nears breaking
	},

	-- The crumble when a cell breaks: small pieces thrown out, then shrinking away.
	Crumble = {
		Gravity = 60,
		SpeedMin = 7,
		SpeedMax = 16,
		Upward = 12, -- extra upward speed, so pieces fly out of the hole
		Lifetime = 0.75,
		SizeMin = 0.4, -- piece size, studs
		SizeMax = 1,
		Spin = 9, -- radians per second
		MaxPieces = 80, -- pooled; older pieces are reused past this
	},

	-- Hitting something with a tool that can't affect it.
	WrongTool = {
		Sound = "WrongTool",
		Wiggle = 0.12, -- studs the cell shakes sideways
		WiggleTime = 0.2,
	},

	-- Clicking or tapping something out of reach.
	TooFar = {
		Sound = "TooFar",
		Color = Color3.fromRGB(255, 90, 90),
		FlashTime = 0.25,
		RetryDelay = 0.25, -- seconds before another "too far" cue can play
	},

	-- PC only: outline on the cell under the cursor.
	Hover = {
		Enabled = true,
		LineThickness = 0.04,
		ValidColor = Color3.fromRGB(255, 255, 255),
		WrongToolColor = Color3.fromRGB(255, 170, 60),
		TooFarColor = Color3.fromRGB(120, 120, 120),
	},

	-- The crusted fossil, from the moment its cell breaks until it is brushed clean.
	Crust = {
		FoundSound = "FossilFound",
		FoundParticles = "FossilGlint",
		BrushSound = "BrushStroke",
		BrushParticles = "CrustDust",
		Wobble = 0.1, -- studs the crust shakes on each brush stroke
		WobbleTime = 0.14,
		ShrinkWhenClean = 0.12, -- crust shrinks by this fraction as it is cleaned
	},

	-- The big moment when a fossil is fully uncovered.
	Reveal = {
		-- Brief slow motion. This is local to the player who found the fossil:
		-- it slows their effects and pauses their digging, not the server.
		StartSound = "RevealStart",
		SlowTimeScale = 0.2, -- 0.2 = effects run at one fifth speed
		SlowDuration = 0.4, -- seconds (real time)
		RecoverDuration = 0.2, -- seconds to ease back to normal speed
		SlowPitch = 0.6, -- sounds played during slow motion are pitched down to this

		-- Camera zoom during the slow motion.
		FovKick = -9, -- degrees; negative zooms in
		FovAttack = 0.12,
		FovRelease = 0.35,

		-- Crust pieces that burst off as time slows.
		CrustShards = 10,

		-- The fossil popping out of the ground.
		PopDuration = 0.55,
		PopStartScale = 0.3,
		PopOvershoot = 1.35,
		HoverHeight = 2.5, -- studs above the plot's surface where it comes to rest
		SpinTurns = 1,
		InputLockAfterPop = 0.35, -- seconds before digging works again

		-- After the pop it hovers and turns slowly.
		IdleSpinSpeed = 30, -- degrees per second
		IdleSparkleRate = 3, -- sparkles per second

		-- Glow.
		FillTransparencyStart = 0.1,
		FillTransparencyEnd = 0.8,
		GlowFadeTime = 1.2,
		LightBrightnessStart = 8,
		LightBrightnessEnd = 1.5,
		LightRange = 12,

		SparkleParticles = "RevealSparkle",

		-- Name tag above the fossil (size in studs).
		LabelWidth = 9,
		LabelHeight = 2.4,
		LabelOffset = 2.6,

		-- Give up on the moment if the server has not confirmed it by then.
		MaxWaitForServer = 1.5,

		ByRarity = RARITY_FEEL,
	},

	Refill = {
		Sound = "Refill",
		Particles = "RefillDust",
	},

	Particles = PARTICLES,
}

return FeelConfig
