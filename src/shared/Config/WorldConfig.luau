--!strict
--[[
	WorldConfig: the greybox dig site that the server builds at startup.

	Each player gets one plot: a ground tile with a pit in the middle, a spawn
	pad in front of the pit and a museum pad behind it. Plots sit side by side
	in a row.
]]

local WorldConfig = {
	-- Plots built at startup. Keep this at or above the place's max players;
	-- a player who joins when every plot is taken gets no plot.
	MaxPlots = 8,

	-- Height of the ground surface. It is raised so the pits clear the default
	-- Baseplate if this is run in a place that still has one.
	SurfaceY = 32,

	-- Ground on each side of the pit, and in front of it where the player spawns.
	PlotMargin = 14,

	-- Solid floor under the pit.
	BedrockThickness = 2,

	-- Studs from the pit's front edge to the centre of the spawn pad.
	SpawnDistance = 7,
	SpawnPadSize = Vector3.new(6, 1, 6),

	-- Placeholder for the Milestone 3 museum, so the walk from pit to museum
	-- can already be judged.
	Museum = {
		Size = Vector3.new(24, 0.4, 18),
		Gap = 6, -- studs between the pit's back edge and the museum pad
		BackMargin = 6,
		Color = Color3.fromRGB(196, 190, 176),
		SignText = "MUSEUM\n(Milestone 3)",
	},

	-- Flat ground around the whole row of plots.
	SurroundSize = 160,
	SurroundThickness = 4,

	Colors = {
		Ground = Color3.fromRGB(108, 142, 92),
		Surround = Color3.fromRGB(98, 130, 84),
		Bedrock = Color3.fromRGB(58, 58, 64),
		Cover = Color3.fromRGB(128, 112, 92), -- fills the pit of an unclaimed plot
		SpawnPad = Color3.fromRGB(235, 200, 90),
	},

	Character = {
		-- Higher than Roblox's default (7.2) so a player can always jump out of
		-- a fully dug pit. See the note on GridConfig.CellSize.
		JumpHeight = 9.5,
	},

	-- A bare place built by Rojo has dark default lighting, which hides the
	-- inside of the pit. Set Apply to false to keep the place's own lighting.
	Lighting = {
		Apply = true,
		Ambient = Color3.fromRGB(118, 118, 118),
		OutdoorAmbient = Color3.fromRGB(150, 150, 150),
		Brightness = 2,
		ClockTime = 13.5,
	},
}

return WorldConfig
