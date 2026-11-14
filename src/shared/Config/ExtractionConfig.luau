--!strict
--[[
	ExtractionConfig: the extraction minigame that starts the moment a fossil
	is uncovered.

	A marker sweeps back and forth along a bar. The player stops it Hits times.
	Each stop is rated Perfect, Good or Miss by how close the marker is to the
	centre of the safe zone, and the ratings add up to the fossil's condition
	(1-100). A fossil is never destroyed: three misses still give the fossil,
	just in poor condition.

	Units:
	  positions and widths  fractions of the bar (0 = left end, 1 = right end)
	  speeds                bar lengths per second
	  times                 seconds

	The SERVER rates every tap using the rule values here (see ExtractionRules),
	so changing them changes real results. The Feel section only changes what
	this player sees and hears, and is safe to tune freely.
]]

export type RarityModifier = {
	SpeedScale: number, -- multiplies the marker speed
	ZoneScale: number, -- multiplies both zone widths
}

export type PointRange = {
	Min: number, -- condition points at the outer edge of this rating's band
	Max: number, -- condition points at the inner edge (the zone centre for Perfect)
}

export type Grade = {
	Min: number, -- lowest condition that earns this grade
	Name: string,
	Color: Color3,
}

export type RatingFeel = {
	Text: string, -- the popup above the bar
	Sound: string, -- key in SoundConfig
	Color: Color3,
	Flash: number, -- panel flash at its brightest: 0 = solid white, 1 = no flash
	Shake: number, -- camera shake, 0-1
	PanelShake: number, -- how far the panel jolts sideways (fraction of the screen)
	Chips: number, -- bits that fly off the fossil
	Sparkles: number, -- sparkle burst on the fossil (multiplier; 0 = none)
	Bump: number, -- how much the fossil swells for an instant (fraction of its size)
}

local RATING_FEEL: { [string]: RatingFeel } = {
	Perfect = {
		Text = "PERFECT!",
		Sound = "ExtractPerfect",
		Color = Color3.fromRGB(255, 214, 80),
		Flash = 0.35,
		Shake = 0,
		PanelShake = 0,
		Chips = 0,
		Sparkles = 0.6,
		Bump = 0.18,
	},
	Good = {
		Text = "GOOD",
		Sound = "ExtractGood",
		Color = Color3.fromRGB(130, 225, 120),
		Flash = 0.8,
		Shake = 0,
		PanelShake = 0,
		Chips = 0,
		Sparkles = 0,
		Bump = 0.08,
	},
	Miss = {
		Text = "MISS",
		Sound = "ExtractMiss",
		Color = Color3.fromRGB(235, 95, 85),
		Flash = 1,
		Shake = 0.3,
		PanelShake = 0.012,
		Chips = 5,
		Sparkles = 0,
		Bump = 0,
	},
}

local RARITY_MODIFIERS: { [string]: RarityModifier } = {
	Common = { SpeedScale = 1, ZoneScale = 1 },
	Uncommon = { SpeedScale = 1.07, ZoneScale = 0.93 },
	Rare = { SpeedScale = 1.15, ZoneScale = 0.85 },
}

-- Best first. A fossil gets the first grade whose Min its condition reaches.
local GRADES: { Grade } = {
	{ Min = 95, Name = "Pristine", Color = Color3.fromRGB(255, 214, 80) },
	{ Min = 80, Name = "Excellent", Color = Color3.fromRGB(120, 230, 140) },
	{ Min = 60, Name = "Fine", Color = Color3.fromRGB(185, 225, 120) },
	{ Min = 40, Name = "Fair", Color = Color3.fromRGB(235, 205, 110) },
	{ Min = 20, Name = "Worn", Color = Color3.fromRGB(235, 150, 90) },
	{ Min = 0, Name = "Damaged", Color = Color3.fromRGB(225, 100, 90) },
}

local ExtractionConfig = {
	-- Taps per extraction.
	Hits = 3,

	-- Seconds from the fossil being uncovered until the marker starts moving.
	-- Long enough for the reveal moment (slow motion and pop) to play first.
	StartDelay = 1.6,

	-- Marker speed on the first hit, in bar lengths per second.
	BaseSpeed = 0.95,

	-- Speed multiplier for each hit in turn, so the last hit is the hardest.
	-- Needs one entry per hit; a missing entry counts as the last one.
	SpeedPerHit = { 1, 1.08, 1.16 },

	-- After each tap the marker freezes this long, so the rating can be seen.
	HitPause = 0.45,

	-- The safe zone. Perfect is a narrow band in the middle of the Good band.
	-- Each hit gets a new zone at a random spot.
	Zone = {
		GoodWidth = 0.28,
		PerfectWidth = 0.09,
		EdgeMargin = 0.04, -- smallest gap between the zone and either end of the bar
		-- Each zone is at least this far from the previous zone (or from where
		-- the marker starts), so the marker never resumes already inside it.
		MinShift = 0.3,
	},

	-- Rarer fossils are harder: a faster marker and a smaller zone. A rarity
	-- missing from this list uses Common.
	ByRarity = RARITY_MODIFIERS,

	-- How the ratings become the fossil's condition:
	--   condition = Base + points from every hit, rounded, kept within 1-100.
	-- Within each rating, points scale with accuracy, so two Goods are rarely
	-- worth exactly the same. With these numbers, three dead-centre Perfects
	-- make exactly 100 and three bad misses make about 10.
	Condition = {
		Base = 1,
		Perfect = { Min = 30, Max = 33 } :: PointRange,
		Good = { Min = 18, Max = 26 } :: PointRange,
		Miss = { Min = 3, Max = 8 } :: PointRange,
		-- A Miss is worth Miss.Max just outside the Good band, falling to
		-- Miss.Min this far (bar fraction) beyond it.
		MissFalloff = 0.25,
	},

	-- Names for condition ranges, shown as "Ammonite: Excellent, 87%".
	Grades = GRADES,

	-- What the server tolerates. Every tap carries the moment the player
	-- tapped, in server time; the server rates the marker at that moment.
	Server = {
		-- How old a tap's timestamp may be when it arrives (network lag).
		-- Older timestamps are moved forward to this limit, never trusted as is.
		LagAllowance = 0.6,
		-- How far ahead of the server's clock a timestamp may be (clock sync jitter).
		ClockTolerance = 0.1,
		-- Taps arriving closer together than this are rejected as too fast.
		MinTapInterval = 0.15,
		-- An extraction left alone this long after the marker starts finishes
		-- by itself; missing taps count as misses.
		MaxDuration = 25,
		-- Flood protection, as in DigConfig.
		MaxRequestsPerSecond = 6,
		RequestBurst = 4,
		-- The uncovered fossil part is removed this long after extraction, so
		-- the client has time to play the "collected" animation.
		RemovePartDelay = 3,
	},

	-- Client-side presentation only.
	Feel = {
		OpenLead = 0.45, -- the bar appears this long before the marker starts
		OpenTime = 0.25, -- pop-in tween
		CloseTime = 0.2,
		OpenSound = "ExtractOpen",

		Ratings = RATING_FEEL,
		FlashTime = 0.3, -- seconds for a flash to fade
		PanelShakeTime = 0.25,
		PopupTime = 0.7, -- seconds the PERFECT / GOOD / MISS popup floats
		BumpTime = 0.2, -- seconds for the fossil's swell to settle

		-- The "Extracted!" moment.
		ExtractedSound = "Extracted",
		ExtractedShake = 0.2,
		ResultHoldTime = 2.8, -- seconds it stays up
		MinResultTime = 0.7, -- after this long, a tap closes it early
		CollectTime = 0.5, -- the fossil shrinks and flies away
		CollectRise = 5, -- studs it rises as it goes

		-- Give up waiting for the server's final result after this long.
		MaxWaitForServer = 4,

		Colors = {
			Panel = Color3.fromRGB(34, 32, 36),
			Stroke = Color3.fromRGB(14, 12, 14),
			Track = Color3.fromRGB(70, 62, 56),
			GoodZone = Color3.fromRGB(110, 190, 105),
			PerfectZone = Color3.fromRGB(255, 214, 80),
			Marker = Color3.fromRGB(250, 248, 240),
			PipEmpty = Color3.fromRGB(80, 76, 80),
			Text = Color3.fromRGB(250, 246, 235),
			Hint = Color3.fromRGB(190, 184, 172),
			Header = Color3.fromRGB(255, 214, 80),
		},
	},
}

return ExtractionConfig
