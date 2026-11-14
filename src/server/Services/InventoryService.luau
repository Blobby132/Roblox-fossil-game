--!strict
--[[
	InventoryService: every fossil a player has extracted.

	The inventory is a list of entries (see InventoryLogic.Entry), one per find,
	kept in the player's data (DataService). The server owns it; clients get a
	copy and are told about every change:

	  InventoryRequest   client asks for the whole list (once, when it starts)
	  InventorySync      server sends the whole list
	  InventoryAdded     server sends one new entry

	Milestone 3 adds removing entries (placing in the museum, selling).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local FossilConfig = require(Shared.Config.FossilConfig)
local InventoryLogic = require(Shared.Inventory.InventoryLogic)
local Remotes = require(Shared.Remotes)

local DataService = require(script.Parent.DataService)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)

local InventoryService = {}

local limiter = RateLimiter.new(1, 3)

local function copyList(entries: { InventoryLogic.Entry }): { InventoryLogic.Entry }
	local copy: { InventoryLogic.Entry } = {}
	for index, entry in entries do
		copy[index] = InventoryLogic.copyEntry(entry)
	end
	return copy
end

-- Adds one find. Returns a copy of the new entry, or nil if the fossil is
-- unknown or the player's data is not loaded.
--   condition  1-100 (rounded and clamped here)
--   foundAt    os.time() when the fossil was uncovered
function InventoryService.Add(
	player: Player,
	fossilId: string,
	condition: number,
	foundAt: number
): InventoryLogic.Entry?
	local def = FossilConfig.ById[fossilId]
	local data = DataService.Get(player)
	if def == nil or data == nil then
		warn(`[InventoryService] Could not add {fossilId} for {player.Name}`)
		return nil
	end
	local entry: InventoryLogic.Entry = {
		Id = data.NextEntryId,
		FossilId = def.Id,
		Rarity = def.Rarity,
		Condition = math.clamp(math.round(condition), 1, 100),
		FoundAt = math.floor(foundAt),
	}
	data.NextEntryId += 1
	table.insert(data.Inventory, entry)
	Remotes.get("InventoryAdded"):FireClient(player, InventoryLogic.copyEntry(entry))
	return InventoryLogic.copyEntry(entry)
end

-- A copy of every entry, in the order they were found.
function InventoryService.GetEntries(player: Player): { InventoryLogic.Entry }
	local data = DataService.Get(player)
	return if data then copyList(data.Inventory) else {}
end

-- A copy of every entry, sorted for display (rarest, then best condition).
function InventoryService.GetSorted(player: Player): { InventoryLogic.Entry }
	return InventoryLogic.sorted(InventoryService.GetEntries(player))
end

function InventoryService.GetSetProgress(player: Player, setId: string): InventoryLogic.SetProgress?
	return InventoryLogic.setProgress(InventoryService.GetEntries(player), setId)
end

-- Sends the whole list to the player.
function InventoryService.Sync(player: Player)
	local data = DataService.Get(player)
	if data then
		Remotes.get("InventorySync"):FireClient(player, copyList(data.Inventory))
	end
end

-- Client -> server. Takes no arguments; anything sent is ignored.
local function onInventoryRequest(player: Player)
	if limiter:allow(player) then
		InventoryService.Sync(player)
	end
end

function InventoryService.Start()
	Remotes.get("InventoryRequest").OnServerEvent:Connect(onInventoryRequest)
	Players.PlayerRemoving:Connect(function(player: Player)
		limiter:forget(player)
	end)
end

return InventoryService
