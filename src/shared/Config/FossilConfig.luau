--!strict
--[[
	FossilConfig: every fossil that can be buried in a plot.

	Weight controls how often a fossil is picked when a plot is seeded. With the
	defaults, each fossil slot is 48% Ammonite, 28% Small Dinosaur Bone and 24%
	a Triceratops piece (8% each). Raise the Triceratops weights while testing
	if you want to see the Rare reveal more often.
]]

export type FossilDef = {
	Id: string,
	DisplayName: string,
	Rarity: string, -- key in RarityConfig
	Weight: number, -- relative chance of being buried
	Set: string?, -- key in Sets, if this fossil is one piece of a set
	CleanStrokes: number, -- brush strokes needed to uncover it once it is exposed
	-- Greybox look once uncovered.
	Shape: Enum.PartType,
	Size: Vector3,
	Rotation: Vector3, -- degrees
	Color: Color3,
}

export type SetDef = {
	DisplayName: string,
	Pieces: { string }, -- fossil ids
}

local BONE = Color3.fromRGB(233, 224, 200)

-- A Cylinder's long axis is X, so the ammonite is rotated to lie flat.
local FOSSILS: { FossilDef } = {
	{
		Id = "Ammonite",
		DisplayName = "Ammonite",
		Rarity = "Common",
		Weight = 48,
		CleanStrokes = 4,
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.7, 2.4, 2.4),
		Rotation = Vector3.new(0, 0, 90),
		Color = Color3.fromRGB(205, 180, 140),
	},
	{
		Id = "SmallDinoBone",
		DisplayName = "Small Dinosaur Bone",
		Rarity = "Uncommon",
		Weight = 28,
		CleanStrokes = 5,
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(2.8, 0.6, 0.6),
		Rotation = Vector3.new(0, 30, 0),
		Color = BONE,
	},
	{
		Id = "TriceratopsHorn",
		DisplayName = "Triceratops Horn",
		Rarity = "Rare",
		Weight = 8,
		Set = "Triceratops",
		CleanStrokes = 7,
		Shape = Enum.PartType.Wedge,
		Size = Vector3.new(0.8, 0.9, 3),
		Rotation = Vector3.new(0, -25, 0),
		Color = BONE,
	},
	{
		Id = "TriceratopsSkull",
		DisplayName = "Triceratops Skull Fragment",
		Rarity = "Rare",
		Weight = 8,
		Set = "Triceratops",
		CleanStrokes = 7,
		Shape = Enum.PartType.Block,
		Size = Vector3.new(2.6, 1.2, 2.2),
		Rotation = Vector3.new(0, 20, 0),
		Color = BONE,
	},
	{
		Id = "TriceratopsClaw",
		DisplayName = "Triceratops Claw",
		Rarity = "Rare",
		Weight = 8,
		Set = "Triceratops",
		CleanStrokes = 7,
		Shape = Enum.PartType.CornerWedge,
		Size = Vector3.new(0.9, 0.9, 1.8),
		Rotation = Vector3.new(0, 40, 0),
		Color = BONE,
	},
}

local SETS: { [string]: SetDef } = {
	Triceratops = {
		DisplayName = "Triceratops",
		Pieces = { "TriceratopsHorn", "TriceratopsSkull", "TriceratopsClaw" },
	},
}

local byId: { [string]: FossilDef } = {}
for _, def in FOSSILS do
	byId[def.Id] = def
end

local FossilConfig = {
	List = FOSSILS,
	ById = byId,
	Sets = SETS,

	-- The dirt crust around a fossil after its cell is broken and before it has
	-- been brushed clean. The crust is a plain block, so its size hints at what
	-- is inside without giving it away.
	Crust = {
		SizeScale = 1.15, -- crust size compared with the fossil inside
		Material = Enum.Material.Sand,
		DirtyColor = Color3.fromRGB(92, 68, 46),
		CleanColor = Color3.fromRGB(184, 158, 118),
	},

	-- Material of an uncovered fossil.
	RevealedMaterial = Enum.Material.SmoothPlastic,
}

return FossilConfig
