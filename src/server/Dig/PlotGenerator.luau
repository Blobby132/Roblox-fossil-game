--!strict
--[[
	PlotGenerator: seeds a fresh plot. Decides each cell's material, where
	the fossils are buried, and which cells show hints.

	Pure logic: it takes a random-number function and returns plain data. Where
	the fossils are stays on the server; clients only ever see what has been
	exposed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local DigRules = require(Shared.Dig.DigRules)
local FossilConfig = require(Shared.Config.FossilConfig)
local GridConfig = require(Shared.Config.GridConfig)
local GridMath = require(Shared.Dig.GridMath)
local MaterialConfig = require(Shared.Config.MaterialConfig)
local PlotRules = require(script.Parent.PlotRules)

local PlotGenerator = {}

-- Whole number from min to max inclusive.
local function randomInt(nextNumber: () -> number, min: number, max: number): number
	if max <= min then
		return min
	end
	return min + math.min(math.floor(nextNumber() * (max - min + 1)), max - min)
end

local function pickFossil(nextNumber: () -> number): FossilConfig.FossilDef
	local total = 0
	for _, def in FossilConfig.List do
		total += def.Weight
	end
	local roll = nextNumber() * total
	for _, def in FossilConfig.List do
		roll -= def.Weight
		if roll < 0 then
			return def
		end
	end
	return FossilConfig.List[#FossilConfig.List]
end

-- nextNumber must return a random number from 0 (inclusive) to 1 (exclusive).
function PlotGenerator.generate(nextNumber: () -> number): PlotRules.PlotState
	local dims = DigRules.Dims
	local cells: { PlotRules.CellState } = {}
	local fossils: { PlotRules.FossilState } = {}

	-- 1. Materials.
	for index = 1, GridMath.cellCount(dims) do
		local _, layer = GridMath.fromIndex(dims, index)
		local settings = GridConfig.LayerSettings[layer]
		local rockChance = if settings then settings.RockChance else 0
		local materialId = if nextNumber() < rockChance then "Rock" else "Dirt"
		cells[index] = {
			Material = materialId,
			Health = MaterialConfig.Materials[materialId].Health,
			Broken = false,
			FossilIndex = nil,
			HintLevel = 0,
		}
	end

	-- 2. Fossils: at most one per column, so every hint points at one fossil.
	local minLayer = math.clamp(GridConfig.FossilMinLayer, 1, dims.Layers)
	local columns: { number } = {}
	for column = 1, dims.Width * dims.Length do
		columns[column] = column
	end
	local wanted = randomInt(nextNumber, GridConfig.FossilsMin, GridConfig.FossilsMax)
	local count = math.clamp(wanted, 0, #columns)

	for fossilIndex = 1, count do
		-- Take a random column that is still free.
		local slot = randomInt(nextNumber, 1, #columns)
		local column = columns[slot]
		columns[slot] = columns[#columns]
		columns[#columns] = nil

		local x = (column - 1) % dims.Width + 1
		local z = (column - 1) // dims.Width + 1
		local layer = randomInt(nextNumber, minLayer, dims.Layers)
		if fossilIndex == 1 and GridConfig.GuaranteeShallowFossil then
			layer = minLayer
		end

		local def = pickFossil(nextNumber)
		local cellIndex = GridMath.toIndex(dims, x, layer, z)
		cells[cellIndex].FossilIndex = fossilIndex
		fossils[fossilIndex] = {
			DefId = def.Id,
			CellIndex = cellIndex,
			Stage = "Buried",
			Clean = 0,
			CleanNeeded = def.CleanStrokes,
		}

		-- 3. Hints: the fossil's own cell and the cells above it, fading with distance.
		if nextNumber() < GridConfig.Hints.Chance then
			local hints = GridConfig.Hints
			local maxLevel = #hints.Levels
			cells[cellIndex].HintLevel = math.clamp(hints.OwnCellLevel, 0, maxLevel)
			for above = layer - 1, 1, -1 do
				local level = hints.LevelByDistance[layer - above] or 0
				local aboveCell = cells[GridMath.toIndex(dims, x, above, z)]
				aboveCell.HintLevel = math.max(aboveCell.HintLevel, math.clamp(level, 0, maxLevel))
			end
		end
	end

	return {
		Cells = cells,
		Fossils = fossils,
		FossilsFound = 0,
	}
end

return PlotGenerator
