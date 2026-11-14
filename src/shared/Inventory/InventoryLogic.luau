--!strict
--[[
	InventoryLogic: what an inventory entry is, how a list of them is sorted,
	and how far along a fossil set is. Pure logic shared by the server (which
	owns the inventory) and the client (which displays it).

	Every find is its own entry, so two Ammonites in different condition are
	two entries.
]]

local Shared = script.Parent.Parent
local FossilConfig = require(Shared.Config.FossilConfig)
local RarityConfig = require(Shared.Config.RarityConfig)

export type Entry = {
	Id: number, -- unique within this player's inventory, never reused
	FossilId: string, -- key in FossilConfig
	Rarity: string, -- key in RarityConfig, stored so old finds keep their rarity
	Condition: number, -- 1-100
	FoundAt: number, -- os.time() when the fossil was uncovered
}

export type SetPiece = {
	FossilId: string,
	DisplayName: string,
	Owned: boolean,
}

export type SetProgress = {
	SetId: string,
	DisplayName: string,
	Owned: number, -- distinct pieces owned
	Total: number,
	Pieces: { SetPiece },
}

local InventoryLogic = {}

local function rarityOrder(rarity: string): number
	local def = RarityConfig.Rarities[rarity]
	return if def then def.Order else 0
end

-- True if `a` should be listed before `b`: rarest first, then best
-- condition, then newest, then the order they were found.
function InventoryLogic.comesBefore(a: Entry, b: Entry): boolean
	local rarityA, rarityB = rarityOrder(a.Rarity), rarityOrder(b.Rarity)
	if rarityA ~= rarityB then
		return rarityA > rarityB
	end
	if a.Condition ~= b.Condition then
		return a.Condition > b.Condition
	end
	if a.FoundAt ~= b.FoundAt then
		return a.FoundAt > b.FoundAt
	end
	return a.Id < b.Id
end

-- A sorted copy of the list. The original is left untouched.
function InventoryLogic.sorted(entries: { Entry }): { Entry }
	local copy = table.clone(entries)
	table.sort(copy, InventoryLogic.comesBefore)
	return copy
end

function InventoryLogic.copyEntry(entry: Entry): Entry
	return {
		Id = entry.Id,
		FossilId = entry.FossilId,
		Rarity = entry.Rarity,
		Condition = entry.Condition,
		FoundAt = entry.FoundAt,
	}
end

-- How many distinct pieces of a set appear in the list.
function InventoryLogic.setProgress(entries: { Entry }, setId: string): SetProgress?
	local set = FossilConfig.Sets[setId]
	if set == nil then
		return nil
	end
	local owned: { [string]: boolean } = {}
	for _, entry in entries do
		owned[entry.FossilId] = true
	end
	local pieces: { SetPiece } = {}
	local count = 0
	for _, fossilId in set.Pieces do
		local def = FossilConfig.ById[fossilId]
		local has = owned[fossilId] == true
		if has then
			count += 1
		end
		table.insert(pieces, {
			FossilId = fossilId,
			DisplayName = if def then def.DisplayName else fossilId,
			Owned = has,
		})
	end
	return {
		SetId = setId,
		DisplayName = set.DisplayName,
		Owned = count,
		Total = #set.Pieces,
		Pieces = pieces,
	}
end

-- Progress for every set, in a stable (alphabetical) order.
function InventoryLogic.allSetProgress(entries: { Entry }): { SetProgress }
	local ids: { string } = {}
	for setId in FossilConfig.Sets do
		table.insert(ids, setId)
	end
	table.sort(ids)
	local result: { SetProgress } = {}
	for _, setId in ids do
		local progress = InventoryLogic.setProgress(entries, setId)
		if progress then
			table.insert(result, progress)
		end
	end
	return result
end

local function isWholeNumber(value: any): boolean
	return typeof(value) == "number" and value == value and value % 1 == 0
end

-- Checks a value really is an entry (the client uses this on data from the
-- network). Returns a clean copy, or nil.
function InventoryLogic.validate(value: any): Entry?
	if typeof(value) ~= "table" then
		return nil
	end
	local fossilId, rarity, condition = value.FossilId, value.Rarity, value.Condition
	if not isWholeNumber(value.Id) or not isWholeNumber(value.FoundAt) then
		return nil
	end
	if typeof(fossilId) ~= "string" or FossilConfig.ById[fossilId] == nil then
		return nil
	end
	if typeof(rarity) ~= "string" or RarityConfig.Rarities[rarity] == nil then
		return nil
	end
	if not isWholeNumber(condition) or condition < 1 or condition > 100 then
		return nil
	end
	return {
		Id = value.Id,
		FossilId = fossilId,
		Rarity = rarity,
		Condition = condition,
		FoundAt = value.FoundAt,
	}
end

return InventoryLogic
