--!strict
--[[
	MaterialConfig: what the dig grid is made of.

	How each material sounds and feels when hit lives in FeelConfig.Materials.
	How much damage each tool does to each material lives in ToolConfig.
]]

export type MaterialDef = {
	DisplayName: string,
	Health: number, -- total damage needed to break one cell
	Color: Color3,
	Material: Enum.Material,
}

local MATERIALS: { [string]: MaterialDef } = {
	Dirt = {
		DisplayName = "Dirt",
		Health = 3,
		Color = Color3.fromRGB(148, 108, 70),
		Material = Enum.Material.Sand,
	},
	Rock = {
		DisplayName = "Rock",
		Health = 4,
		Color = Color3.fromRGB(122, 124, 130),
		Material = Enum.Material.Slate,
	},
}

local MaterialConfig = {
	Materials = MATERIALS,
}

return MaterialConfig
