--!strict
--[[
	DataService: where each player's data lives while they are in the game.

	This is the ONLY module that knows how player data is stored. Everything
	else (InventoryService, and later the museum and upgrades) asks
	DataService.Get(player) and changes the table it gets back.

	Milestone 2: data is kept in memory only. It starts from TEMPLATE when a
	player joins and is thrown away when they leave, so the inventory resets
	on rejoin.

	Milestone 4: swap the inside of this module for ProfileStore. Load the
	profile on join (using TEMPLATE as its template), return profile.Data from
	Get, and end the session on leave. Get may then return nil for a moment
	while a profile loads, which callers already handle.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local InventoryLogic = require(ReplicatedStorage.Shared.Inventory.InventoryLogic)

export type PlayerData = {
	Inventory: { InventoryLogic.Entry },
	NextEntryId: number, -- id for the next inventory entry; ids are never reused
}

local DataService = {}

-- A brand-new player's data. Add new fields here with a sensible default.
local TEMPLATE: PlayerData = {
	Inventory = {},
	NextEntryId = 1,
}

local loaded: { [Player]: PlayerData } = {}

local function deepCopy<T>(value: T): T
	if typeof(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, child in value :: any do
		copy[key] = deepCopy(child)
	end
	return copy :: any
end

local function load(player: Player)
	if loaded[player] == nil then
		loaded[player] = deepCopy(TEMPLATE)
	end
end

local function release(player: Player)
	loaded[player] = nil
end

-- The player's data, or nil if it is not loaded (yet, or any more).
function DataService.Get(player: Player): PlayerData?
	return loaded[player]
end

function DataService.Start()
	Players.PlayerAdded:Connect(load)
	Players.PlayerRemoving:Connect(release)
	for _, player in Players:GetPlayers() do
		load(player)
	end
end

return DataService
