--!strict
--[[
	RarityConfig: the rarity tiers fossils belong to.

	How big the reveal moment is for each rarity lives in FeelConfig.Reveal.ByRarity.
	Museum income multipliers get added here in Milestone 3.
]]

export type RarityDef = {
	DisplayName: string,
	Order: number, -- 1 = most common
	Color: Color3, -- used for the glow, light and label when a fossil is uncovered
}

local RARITIES: { [string]: RarityDef } = {
	Common = {
		DisplayName = "Common",
		Order = 1,
		Color = Color3.fromRGB(235, 235, 225),
	},
	Uncommon = {
		DisplayName = "Uncommon",
		Order = 2,
		Color = Color3.fromRGB(95, 215, 120),
	},
	Rare = {
		DisplayName = "Rare",
		Order = 3,
		Color = Color3.fromRGB(80, 160, 255),
	},
}

local RarityConfig = {
	Rarities = RARITIES,
}

return RarityConfig
