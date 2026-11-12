--!strict
--[[
	PlotRules: the authoritative state of one dig plot, and what a swing does to it.

	This is plain data and pure logic: no parts, no players, no network. The
	services turn the outcome into parts and messages. Keeping it pure means the
	rules can be tested without Roblox running (see tests/).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DigRules = require(ReplicatedStorage.Shared.Dig.DigRules)

export type FossilStage = "Buried" | "Encased" | "Revealed"

export type CellState = {
	Material: string,
	Health: number,
	Broken: boolean,
	FossilIndex: number?, -- index into PlotState.Fossils, if a fossil sits in this cell
	HintLevel: number, -- 0 = no hint; otherwise an index into GridConfig.Hints.Levels
}

export type FossilState = {
	DefId: string,
	CellIndex: number,
	-- Buried:   still inside an unbroken cell.
	-- Encased:  its cell is broken; it shows as a dirt crust to brush clean.
	-- Revealed: fully uncovered.
	Stage: FossilStage,
	Clean: number, -- brush strokes done so far
	CleanNeeded: number,
}

export type PlotState = {
	Cells: { CellState },
	Fossils: { FossilState },
	FossilsFound: number,
}

export type SwingOutcome = {
	Ok: boolean,
	-- Ok:     Hit | Break | Clean | Reveal
	-- Not ok: WrongTool | NotExposed | NothingThere | AlreadyRevealed
	Code: string,
	Value: number, -- cell health left (Hit, Break) or strokes done (Clean, Reveal)
	FossilIndex: number?, -- the fossil involved, if any
}

local PlotRules = {}

local function fail(code: string): SwingOutcome
	return { Ok = false, Code = code, Value = 0 }
end

function PlotRules.isSolid(state: PlotState, index: number): boolean
	local cell = state.Cells[index]
	return cell ~= nil and not cell.Broken
end

function PlotRules.isExposed(state: PlotState, index: number): boolean
	return DigRules.isExposed(index, function(neighbor: number): boolean
		return PlotRules.isSolid(state, neighbor)
	end)
end

function PlotRules.isComplete(state: PlotState): boolean
	return state.FossilsFound >= #state.Fossils
end

-- Applies one swing to the plot and reports what happened.
-- The caller has already checked who is swinging, from where and how often.
function PlotRules.resolveSwing(state: PlotState, index: number, toolId: string): SwingOutcome
	local cell = state.Cells[index]
	if cell == nil then
		return fail("NothingThere")
	end

	-- An unbroken cell: dig it.
	if not cell.Broken then
		if not PlotRules.isExposed(state, index) then
			return fail("NotExposed")
		end
		local damage = DigRules.getDamage(toolId, cell.Material)
		if damage <= 0 then
			return fail("WrongTool")
		end
		cell.Health = math.max(0, cell.Health - damage)
		if cell.Health > 0 then
			return { Ok = true, Code = "Hit", Value = cell.Health }
		end
		cell.Broken = true
		local fossilIndex = cell.FossilIndex
		if fossilIndex then
			state.Fossils[fossilIndex].Stage = "Encased"
		end
		return { Ok = true, Code = "Break", Value = 0, FossilIndex = fossilIndex }
	end

	-- A broken cell: the only thing left to hit is a fossil's crust.
	local fossilIndex = cell.FossilIndex
	if fossilIndex == nil then
		return fail("NothingThere")
	end
	local fossil = state.Fossils[fossilIndex]
	if fossil.Stage == "Revealed" then
		return fail("AlreadyRevealed")
	end
	local power = DigRules.getCleanPower(toolId)
	if power <= 0 then
		return fail("WrongTool")
	end
	fossil.Clean = math.min(fossil.CleanNeeded, fossil.Clean + power)
	if fossil.Clean < fossil.CleanNeeded then
		return { Ok = true, Code = "Clean", Value = fossil.Clean, FossilIndex = fossilIndex }
	end
	fossil.Stage = "Revealed"
	state.FossilsFound += 1
	return { Ok = true, Code = "Reveal", Value = fossil.Clean, FossilIndex = fossilIndex }
end

return PlotRules
