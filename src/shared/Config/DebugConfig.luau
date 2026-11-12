--!strict
--[[
	DebugConfig: developer-only shortcuts for playtesting.

	The server decides who may use them (see DebugService): anyone while
	playing inside Roblox Studio if AllowInStudio is true, plus the UserIds
	listed here in a published game. Everyone else is ignored.
]]

local DebugConfig = {
	Enabled = true,
	AllowInStudio = true,

	-- Roblox UserIds allowed to use debug shortcuts in the published game.
	DeveloperUserIds = {} :: { number },

	Keys = {
		Reseed = Enum.KeyCode.R, -- refill and reseed your plot right now
		ShowFossils = Enum.KeyCode.X, -- toggle markers over every buried fossil
	},

	MarkerColor = Color3.fromRGB(255, 60, 200),
}

return DebugConfig
