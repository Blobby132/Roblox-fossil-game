--[[
	Rule tests: the grid maths, plot seeding and dig rules, with no players
	or network involved.

	Run from the project folder:   lune run tests/logic
]]

local Harness = require("./lib/Harness")

local test, expect, expectEqual = Harness.test, Harness.expect, Harness.expectEqual

local game = Harness.build()
local requireModule = Harness.newRequire("Server")

local Shared = game:GetService("ReplicatedStorage").Shared
local Server = game:GetService("ServerScriptService").Server

local GridConfig = requireModule(Shared.Config.GridConfig)
local FossilConfig = requireModule(Shared.Config.FossilConfig)
local MaterialConfig = requireModule(Shared.Config.MaterialConfig)
local ToolConfig = requireModule(Shared.Config.ToolConfig)
local WorldConfig = requireModule(Shared.Config.WorldConfig)
local GridMath = requireModule(Shared.Dig.GridMath)
local DigRules = requireModule(Shared.Dig.DigRules)
local PlotGenerator = requireModule(Server.Dig.PlotGenerator)
local PlotRules = requireModule(Server.Dig.PlotRules)

local dims = DigRules.Dims
local Vector3 = require("@lune/roblox").Vector3

-- A small repeatable random-number generator, so every run tests the same plots.
local function seeded(seed: number): () -> number
	local state = seed
	return function(): number
		state = (state * 1103515245 + 12345) % 2147483648
		return state / 2147483648
	end
end

-- The tool that can break this material fastest.
local function toolFor(materialId: string): string
	return if DigRules.getDamage("Brush", materialId) > 0 then "Brush" else "Pickaxe"
end

-- Digs straight down a column until the given cell is broken.
local function digDownTo(state: any, cellIndex: number)
	local x, layer, z = GridMath.fromIndex(dims, cellIndex)
	for depth = 1, layer do
		local index = GridMath.toIndex(dims, x, depth, z)
		local cell = state.Cells[index]
		local guard = 0
		while not cell.Broken do
			local outcome = PlotRules.resolveSwing(state, index, toolFor(cell.Material))
			expect(outcome.Ok, `swing at cell {index} was rejected: {outcome.Code}`)
			guard += 1
			expect(guard < 50, "cell never broke")
		end
	end
end

print("Grid maths")

test("every index converts to coordinates and back", function()
	for index = 1, GridMath.cellCount(dims) do
		local x, layer, z = GridMath.fromIndex(dims, index)
		expect(GridMath.inBounds(dims, x, layer, z), `index {index} maps outside the grid`)
		expectEqual(GridMath.toIndex(dims, x, layer, z), index, "round trip")
	end
end)

test("cell count matches the config", function()
	expectEqual(
		GridMath.cellCount(dims),
		GridConfig.Width * GridConfig.Length * GridConfig.Layers,
		"cell count"
	)
end)

test("bad cell numbers are rejected", function()
	local count = GridMath.cellCount(dims)
	for _, bad in { 0, -1, count + 1, 1.5, 0 / 0, math.huge, -math.huge } do
		expect(not GridMath.isValidIndex(dims, bad), `{bad} should be invalid`)
	end
	expect(GridMath.isValidIndex(dims, 1), "1 should be valid")
	expect(GridMath.isValidIndex(dims, count), "the last cell should be valid")
end)

test("neighbours share a face and stay inside the grid", function()
	local corner = GridMath.toIndex(dims, 1, 1, 1)
	expectEqual(#GridMath.neighbors(dims, corner), 3, "a top corner cell's neighbours")
	if dims.Width >= 3 and dims.Length >= 3 and dims.Layers >= 3 then
		local middle = GridMath.toIndex(dims, 2, 2, 2)
		expectEqual(#GridMath.neighbors(dims, middle), 6, "an inner cell's neighbours")
	end
	for index = 1, GridMath.cellCount(dims) do
		local x, layer, z = GridMath.fromIndex(dims, index)
		for _, neighbor in GridMath.neighbors(dims, index) do
			local nx, nLayer, nz = GridMath.fromIndex(dims, neighbor)
			local distance = math.abs(nx - x) + math.abs(nLayer - layer) + math.abs(nz - z)
			expectEqual(distance, 1, `cells {index} and {neighbor} are not adjacent`)
		end
	end
end)

test("the grid is centred on the pit and hangs below the surface", function()
	local size = GridConfig.CellSize
	local sumX, sumZ = 0, 0
	for index = 1, GridMath.cellCount(dims) do
		local x, y, z = GridMath.cellOffset(dims, size.X, size.Y, size.Z, index)
		sumX += x
		sumZ += z
		expect(y < 0, "a cell centre is above the surface")
		expect(y > -dims.Layers * size.Y, "a cell centre is below the pit floor")
	end
	expect(math.abs(sumX) < 1e-6 and math.abs(sumZ) < 1e-6, "the grid is off-centre")
end)

print("\nDig rules")

test("tools affect the right materials", function()
	expect(DigRules.getDamage("Pickaxe", "Rock") > 0, "the pickaxe must break rock")
	expect(DigRules.getDamage("Pickaxe", "Dirt") > 0, "the pickaxe must dig dirt")
	expect(DigRules.getDamage("Brush", "Dirt") > 0, "the brush must clear dirt")
	expectEqual(DigRules.getDamage("Brush", "Rock"), 0, "brush damage to rock")
	expect(DigRules.getCleanPower("Brush") > 0, "the brush must clean fossils")
	expectEqual(DigRules.getCleanPower("Pickaxe"), 0, "pickaxe cleaning power")
	expectEqual(DigRules.getDamage("NoSuchTool", "Dirt"), 0, "unknown tool damage")
	expectEqual(DigRules.getDamage("Pickaxe", "NoSuchMaterial"), 0, "unknown material damage")
end)

test("the brush clears dirt faster than the pickaxe", function()
	local health = MaterialConfig.Materials.Dirt.Health
	local function seconds(toolId: string): number
		local tool = ToolConfig.Tools[toolId]
		return math.ceil(health / tool.Damage.Dirt) * tool.Cooldown
	end
	expect(seconds("Brush") < seconds("Pickaxe"), "the pickaxe should be slow on dirt")
end)

test("only cells touching open air can be dug", function()
	local broken = {}
	local function isSolid(index: number): boolean
		return not broken[index]
	end
	local top = GridMath.toIndex(dims, 2, 1, 2)
	local below = GridMath.toIndex(dims, 2, 2, 2)
	local side = GridMath.toIndex(dims, 3, 2, 2)
	expect(DigRules.isExposed(top, isSolid), "surface cells are always exposed")
	expect(not DigRules.isExposed(below, isSolid), "a buried cell is not exposed")
	broken[top] = true
	expect(DigRules.isExposed(below, isSolid), "the cell under a hole is exposed")
	expect(not DigRules.isExposed(side, isSolid), "a cell beside it is still buried")
	broken[below] = true
	expect(DigRules.isExposed(side, isSolid), "digging down exposes the cell's side")
end)

test("reach is measured to the nearest point of the cell", function()
	local half = GridConfig.CellSize / 2
	local center = Vector3.new(10, 20, 30)
	expectEqual(DigRules.distanceToCell(center, center), 0, "inside the cell")
	local above = center + Vector3.new(0, half.Y + 5, 0)
	expect(
		math.abs(DigRules.distanceToCell(above, center) - 5) < 1e-6,
		"5 studs above the top face"
	)
end)

test("a player can always jump out of a fully dug pit", function()
	local depth = GridConfig.Layers * GridConfig.CellSize.Y
	expect(
		depth < WorldConfig.Character.JumpHeight,
		`the pit is {depth} studs deep but JumpHeight is {WorldConfig.Character.JumpHeight}`
	)
end)

print("\nPlot seeding")

test("200 seeded plots all follow the rules", function()
	for seed = 1, 200 do
		local state = PlotGenerator.generate(seeded(seed))
		expectEqual(#state.Cells, GridMath.cellCount(dims), "cells in the plot")
		expect(
			#state.Fossils >= GridConfig.FossilsMin and #state.Fossils <= GridConfig.FossilsMax,
			`seed {seed} buried {#state.Fossils} fossils`
		)

		local columns = {}
		for fossilIndex, fossil in state.Fossils do
			local x, layer, z = GridMath.fromIndex(dims, fossil.CellIndex)
			expect(layer >= GridConfig.FossilMinLayer, "a fossil is above FossilMinLayer")
			expect(FossilConfig.ById[fossil.DefId] ~= nil, "unknown fossil id " .. fossil.DefId)
			expectEqual(
				state.Cells[fossil.CellIndex].FossilIndex,
				fossilIndex,
				"cell's fossil link"
			)
			expectEqual(fossil.Stage, "Buried", "starting stage")
			local column = `{x},{z}`
			expect(not columns[column], "two fossils share a column")
			columns[column] = true
		end
		if GridConfig.GuaranteeShallowFossil then
			local _, layer = GridMath.fromIndex(dims, state.Fossils[1].CellIndex)
			expectEqual(layer, GridConfig.FossilMinLayer, "the guaranteed shallow fossil's layer")
		end

		for index, cell in state.Cells do
			local _, layer = GridMath.fromIndex(dims, index)
			expect(MaterialConfig.Materials[cell.Material] ~= nil, "unknown material")
			expectEqual(cell.Health, MaterialConfig.Materials[cell.Material].Health, "cell health")
			if GridConfig.LayerSettings[layer].RockChance == 0 then
				expectEqual(cell.Material, "Dirt", `layer {layer} material`)
			end
		end
	end
end)

test("hints sit above fossils and fade with distance", function()
	local hints = GridConfig.Hints
	for seed = 1, 100 do
		local state = PlotGenerator.generate(seeded(seed))
		local expected = {}
		for _, fossil in state.Fossils do
			local x, layer, z = GridMath.fromIndex(dims, fossil.CellIndex)
			expected[fossil.CellIndex] = hints.OwnCellLevel
			for above = layer - 1, 1, -1 do
				local index = GridMath.toIndex(dims, x, above, z)
				expected[index] = hints.LevelByDistance[layer - above] or 0
			end
		end
		for index, cell in state.Cells do
			-- With Hints.Chance below 1 a fossil may give no hint, so only
			-- check exact levels when every fossil hints.
			if hints.Chance >= 1 then
				expectEqual(cell.HintLevel, expected[index] or 0, `seed {seed} cell {index} hint`)
			else
				expect(cell.HintLevel == 0 or expected[index] ~= nil, "a hint with no fossil below")
			end
		end
	end
end)

test("every kind of fossil turns up", function()
	local seen = {}
	for seed = 1, 300 do
		for _, fossil in PlotGenerator.generate(seeded(seed)).Fossils do
			seen[fossil.DefId] = true
		end
	end
	for _, def in FossilConfig.List do
		expect(seen[def.Id], def.Id .. " was never buried in 300 plots")
	end
end)

test("the Triceratops set lists three real fossils", function()
	local set = FossilConfig.Sets.Triceratops
	expectEqual(#set.Pieces, 3, "pieces in the set")
	for _, id in set.Pieces do
		local def = FossilConfig.ById[id]
		expect(def ~= nil, "unknown set piece " .. id)
		expectEqual(def.Set, "Triceratops", id .. " set")
		expectEqual(def.Rarity, "Rare", id .. " rarity")
	end
end)

print("\nSwings")

test("a swing follows the rules from first hit to reveal", function()
	local state = PlotGenerator.generate(seeded(7))
	local fossil = state.Fossils[1]
	local x, layer, z = GridMath.fromIndex(dims, fossil.CellIndex)

	-- A buried cell cannot be hit.
	expectEqual(
		PlotRules.resolveSwing(state, fossil.CellIndex, "Pickaxe").Code,
		"NotExposed",
		"swing at a buried cell"
	)

	-- The surface cell is dirt: it takes Health hits, then breaks.
	local top = GridMath.toIndex(dims, x, 1, z)
	local health = state.Cells[top].Health
	for hit = 1, health - 1 do
		local outcome = PlotRules.resolveSwing(state, top, "Pickaxe")
		expectEqual(outcome.Code, "Hit", `hit {hit}`)
		expectEqual(outcome.Value, health - hit, "health left")
	end
	expectEqual(PlotRules.resolveSwing(state, top, "Pickaxe").Code, "Break", "final hit")
	expectEqual(PlotRules.resolveSwing(state, top, "Pickaxe").Code, "NothingThere", "empty cell")

	-- Dig down to the fossil.
	digDownTo(state, fossil.CellIndex)
	expectEqual(fossil.Stage, "Encased", "stage after its cell breaks")
	expect(layer >= 2, "fossil should be below the surface")

	-- Only the brush cleans it.
	expectEqual(
		PlotRules.resolveSwing(state, fossil.CellIndex, "Pickaxe").Code,
		"WrongTool",
		"pickaxe on a crust"
	)
	for stroke = 1, fossil.CleanNeeded - 1 do
		local outcome = PlotRules.resolveSwing(state, fossil.CellIndex, "Brush")
		expectEqual(outcome.Code, "Clean", `stroke {stroke}`)
		expectEqual(outcome.Value, stroke, "strokes done")
	end
	local final = PlotRules.resolveSwing(state, fossil.CellIndex, "Brush")
	expectEqual(final.Code, "Reveal", "final stroke")
	expectEqual(fossil.Stage, "Revealed", "stage after the final stroke")
	expectEqual(state.FossilsFound, 1, "fossils found")
	expectEqual(
		PlotRules.resolveSwing(state, fossil.CellIndex, "Brush").Code,
		"AlreadyRevealed",
		"brushing an uncovered fossil"
	)
end)

test("the brush cannot break rock", function()
	for seed = 1, 50 do
		local state = PlotGenerator.generate(seeded(seed))
		for index, cell in state.Cells do
			if cell.Material == "Rock" and PlotRules.isExposed(state, index) then
				expectEqual(
					PlotRules.resolveSwing(state, index, "Brush").Code,
					"WrongTool",
					"brush on rock"
				)
				expectEqual(cell.Health, MaterialConfig.Materials.Rock.Health, "rock health")
			end
		end
	end
end)

test("50 plots can each be dug to completion", function()
	for seed = 1, 50 do
		local state = PlotGenerator.generate(seeded(seed))
		expect(not PlotRules.isComplete(state), "a fresh plot is not complete")
		for _, fossil in state.Fossils do
			digDownTo(state, fossil.CellIndex)
			for _ = 1, fossil.CleanNeeded do
				expect(
					PlotRules.resolveSwing(state, fossil.CellIndex, "Brush").Ok,
					"brush stroke rejected"
				)
			end
			expectEqual(fossil.Stage, "Revealed", "fossil stage")
		end
		expect(PlotRules.isComplete(state), `seed {seed} is not complete after every fossil`)
	end
end)

Harness.finish()
