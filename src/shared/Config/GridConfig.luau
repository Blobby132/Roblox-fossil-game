--!strict
--[[
	GridConfig: size and contents of each player's dig plot.

	Changing Width / Length / Layers / CellSize resizes the pit automatically.
	The greybox ground is built around whatever these say.
]]

export type LayerSetting = {
	RockChance: number, -- chance (0-1) that a cell in this layer is rock, not dirt
	Shade: number, -- brightness multiplier, so deeper layers look darker
}

export type HintLook = {
	ColorBlend: number, -- how far (0-1) the cell colour shifts towards Hints.Color
	Cracks: number, -- number of dark crack strips drawn on the cell's top face
}

-- One entry per layer, top to bottom. Add or remove entries when you change Layers.
local LAYER_SETTINGS: { LayerSetting } = {
	{ RockChance = 0, Shade = 1 },
	{ RockChance = 0.25, Shade = 0.9 },
	{ RockChance = 0.45, Shade = 0.8 },
	{ RockChance = 0.65, Shade = 0.7 },
}

-- Index = hint level. Level 1 is the faintest, level 3 the strongest.
local HINT_LEVELS: { HintLook } = {
	{ ColorBlend = 0.14, Cracks = 0 },
	{ ColorBlend = 0.28, Cracks = 1 },
	{ ColorBlend = 0.45, Cracks = 3 },
}

local GridConfig = {
	-- Grid dimensions, in cells.
	Width = 8, -- cells along X
	Length = 8, -- cells along Z
	Layers = 4, -- cells deep; layer 1 is the surface

	-- Size of one cell in studs (X, Y, Z).
	-- Keep Layers * CellSize.Y below WorldConfig.Character.JumpHeight, so a
	-- player standing at the very bottom of the pit can always jump back out.
	CellSize = Vector3.new(4, 2, 4),

	LayerSettings = LAYER_SETTINGS,

	-- Every other cell is shaded by this amount so single cells read clearly.
	CheckerShade = 0.95,

	-- How many fossils are buried in a fresh plot.
	FossilsMin = 4,
	FossilsMax = 6,

	-- Fossils never sit above this layer ("below the surface").
	FossilMinLayer = 2,

	-- If true, one fossil is always placed at FossilMinLayer so a new player
	-- finds their first fossil quickly.
	GuaranteeShallowFossil = true,

	-- Seconds between the last fossil being uncovered and the plot refilling.
	RefillDelay = 8,

	-- The plot never refills while its owner is extracting a fossil. If the
	-- refill came due during an extraction, it happens this many seconds after
	-- the extraction ends instead.
	RefillDelayAfterExtraction = 3,

	-- Surface hints: cracked / discoloured cells above buried fossils.
	Hints = {
		-- Chance (0-1) that a fossil gives hints at all. Below 1, some fossils
		-- are complete surprises.
		Chance = 1,

		-- Hint level for a cell N layers above a fossil: index 1 = directly
		-- above, index 2 = two layers above, and so on. Cells further above
		-- than this list is long show no hint.
		LevelByDistance = { 3, 2, 1 },

		-- Hint level of the cell that actually holds the fossil.
		OwnCellLevel = 3,

		Levels = HINT_LEVELS,

		-- Hinted cells shift towards this pale, chalky colour.
		Color = Color3.fromRGB(222, 205, 160),

		CrackColor = Color3.fromRGB(46, 38, 30),
		CrackThickness = 0.14, -- studs
		CrackLengthMin = 0.3, -- fraction of the cell's width
		CrackLengthMax = 0.7,
	},
}

return GridConfig
