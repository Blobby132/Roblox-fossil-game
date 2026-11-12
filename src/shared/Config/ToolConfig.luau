--!strict
--[[
	ToolConfig: the digging tools.

	Time to break a cell = (material Health / Damage) * Cooldown.
	With the defaults: pickaxe on rock 1.8 s, pickaxe on dirt 1.35 s,
	brush on dirt 0.6 s, brush on rock never.
]]

export type ToolPart = {
	Name: string,
	Size: Vector3,
	Offset: CFrame, -- position relative to the handle (the first part)
	Color: Color3,
}

export type ToolDef = {
	DisplayName: string,
	Slot: number, -- hotbar position and number key
	Cooldown: number, -- seconds between swings
	Range: number, -- max studs from the character to the nearest point of the cell
	Damage: { [string]: number }, -- damage per swing, by material id; 0 = can't break it
	CleanPower: number, -- fossil cleaning strokes per swing; 0 = can't clean fossils
	Grip: CFrame, -- where the hand holds the handle
	Parts: { ToolPart }, -- greybox look; the first part is the handle
}

local WOOD = Color3.fromRGB(140, 98, 60)

local TOOLS: { [string]: ToolDef } = {
	Pickaxe = {
		DisplayName = "Pickaxe",
		Slot = 1,
		Cooldown = 0.45,
		Range = 11,
		Damage = { Dirt = 1, Rock = 1 },
		CleanPower = 0,
		Grip = CFrame.new(0, -0.9, 0),
		Parts = {
			{
				Name = "Handle",
				Size = Vector3.new(0.35, 3.2, 0.35),
				Offset = CFrame.new(),
				Color = WOOD,
			},
			{
				Name = "Head",
				Size = Vector3.new(0.4, 0.4, 2.4),
				Offset = CFrame.new(0, 1.4, 0),
				Color = Color3.fromRGB(95, 100, 110),
			},
		},
	},
	Brush = {
		DisplayName = "Brush",
		Slot = 2,
		Cooldown = 0.2,
		Range = 11,
		Damage = { Dirt = 1, Rock = 0 },
		CleanPower = 1,
		Grip = CFrame.new(0, -0.5, 0),
		Parts = {
			{
				Name = "Handle",
				Size = Vector3.new(0.35, 1.8, 0.35),
				Offset = CFrame.new(),
				Color = WOOD,
			},
			{
				Name = "Bristles",
				Size = Vector3.new(0.9, 0.7, 0.3),
				Offset = CFrame.new(0, 1.2, 0),
				Color = Color3.fromRGB(232, 214, 160),
			},
		},
	},
}

local ToolConfig = {
	-- The tool a player holds when they spawn.
	DefaultTool = "Pickaxe",

	Tools = TOOLS,
}

return ToolConfig
