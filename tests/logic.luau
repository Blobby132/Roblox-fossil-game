--[[
	Rule tests: the grid maths, plot seeding, dig rules, extraction maths and
	rules, and inventory logic, with no players or network involved.

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
local ExtractionConfig = requireModule(Shared.Config.ExtractionConfig)
local ExtractionMath = requireModule(Shared.Extraction.ExtractionMath)
local ExtractionRules = requireModule(Server.Extraction.ExtractionRules)
local InventoryLogic = requireModule(Shared.Inventory.InventoryLogic)
local RarityConfig = requireModule(Shared.Config.RarityConfig)

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

print("\nExtraction maths")

local function near(a: number, b: number, tolerance: number?): boolean
	return math.abs(a - b) <= (tolerance or 1e-6)
end

test("the marker starts where the segment says and moves the right way", function()
	local right = { Hit = 1, StartAt = 10, StartPos = 0.3, StartDir = 1, Speed = 0.5 }
	local position, direction = ExtractionMath.positionAt(right, 10)
	expect(near(position, 0.3), "start position")
	expectEqual(direction, 1, "start direction")
	expect(near(ExtractionMath.positionAt(right, 11), 0.8), "after one second moving right")
	-- Before the segment starts, the marker waits at its start.
	expect(near(ExtractionMath.positionAt(right, 5), 0.3), "position before the start")

	local left = { Hit = 1, StartAt = 10, StartPos = 0.3, StartDir = -1, Speed = 0.5 }
	position, direction = ExtractionMath.positionAt(left, 10.2)
	expect(near(position, 0.2), "after 0.2 s moving left")
	expectEqual(direction, -1, "still moving left")
end)

test("the marker bounces off both ends and never leaves the bar", function()
	local segment = { Hit = 1, StartAt = 0, StartPos = 0.9, StartDir = 1, Speed = 1 }
	local position, direction = ExtractionMath.positionAt(segment, 0.3)
	expect(near(position, 0.8), "bounced off the right end")
	expectEqual(direction, -1, "moving left after the bounce")
	position, direction = ExtractionMath.positionAt(segment, 1.3)
	expect(near(position, 0.2), "bounced off the left end")
	expectEqual(direction, 1, "moving right after the second bounce")
	for step = 0, 2000 do
		local t = step * 0.0137
		local p = ExtractionMath.positionAt(segment, t)
		expect(p >= 0 and p <= 1, `the marker left the bar at t={t}: {p}`)
	end
end)

test("a stop is rated by its distance from the zone centre", function()
	local perfectWidth, goodWidth = 0.1, 0.3
	local condition = ExtractionConfig.Condition
	local rating, points = ExtractionMath.rate(0.5, 0.5, perfectWidth, goodWidth)
	expectEqual(rating, "Perfect", "dead centre")
	expect(near(points, condition.Perfect.Max), "dead centre is worth the most")
	expectEqual(ExtractionMath.rate(0.549, 0.5, perfectWidth, goodWidth), "Perfect", "inner edge")
	expectEqual(
		ExtractionMath.rate(0.551, 0.5, perfectWidth, goodWidth),
		"Good",
		"just outside Perfect"
	)
	expectEqual(ExtractionMath.rate(0.351, 0.5, perfectWidth, goodWidth), "Good", "Good edge")
	expectEqual(
		ExtractionMath.rate(0.649, 0.5, perfectWidth, goodWidth),
		"Good",
		"Good edge, right"
	)
	expectEqual(ExtractionMath.rate(0.66, 0.5, perfectWidth, goodWidth), "Miss", "outside the zone")
	local _, far = ExtractionMath.rate(0, 0.9, perfectWidth, goodWidth)
	expect(near(far, condition.Miss.Min), "a far miss is worth the least")

	-- Points never go up as the stop moves away from the centre.
	local previous = math.huge
	for step = 0, 100 do
		local _, value = ExtractionMath.rate(0.5 + step * 0.005, 0.5, perfectWidth, goodWidth)
		expect(value <= previous + 1e-9, "points rose with distance")
		previous = value
	end
end)

test("condition is 1-100: three Perfects make 100, three misses still give a fossil", function()
	local condition = ExtractionConfig.Condition
	local best = { condition.Perfect.Max, condition.Perfect.Max, condition.Perfect.Max }
	expectEqual(ExtractionMath.condition(best), 100, "three dead-centre Perfects")
	local worst = { condition.Miss.Min, condition.Miss.Min, condition.Miss.Min }
	local worstCondition = ExtractionMath.condition(worst)
	expect(worstCondition >= 1, "three misses must still give a condition of at least 1")
	expect(worstCondition < 40, `three misses gave {worstCondition}, which is too generous`)
	expectEqual(ExtractionMath.condition({ 0, 0, 0 }), math.max(1, condition.Base), "no points")
	expectEqual(ExtractionMath.condition({ 500 }), 100, "capped at 100")
	expectEqual(ExtractionMath.condition({ -500 }), 1, "never below 1")
	local mixed = ExtractionMath.condition({ 32, 31, 22 })
	expect(mixed >= 80 and mixed < 95, `Perfect, Perfect, Good should be Excellent, got {mixed}`)
end)

test("grades read as intended", function()
	expectEqual(ExtractionMath.describe("Ammonite", 87), "Ammonite: Excellent, 87%", "describe")
	expectEqual(ExtractionMath.grade(100).Name, "Pristine", "100")
	expectEqual(ExtractionMath.grade(1).Name, "Damaged", "1")
	-- Grades are listed best first, and every condition gets one.
	local grades = ExtractionConfig.Grades
	for index = 2, #grades do
		expect(grades[index].Min < grades[index - 1].Min, "grades must be listed best first")
	end
	for value = 1, 100 do
		expect(value >= ExtractionMath.grade(value).Min, `condition {value} got a grade above it`)
	end
end)

test("rarer fossils have a faster marker and smaller zones", function()
	local rarities = {}
	for id, def in RarityConfig.Rarities do
		table.insert(rarities, { Id = id, Order = def.Order })
	end
	table.sort(rarities, function(a, b)
		return a.Order < b.Order
	end)
	local lastSpeed, lastGood, lastPerfect = 0, math.huge, math.huge
	for _, rarity in rarities do
		expect(ExtractionConfig.ByRarity[rarity.Id] ~= nil, rarity.Id .. " has no modifiers")
		local speeds = ExtractionMath.speedsFor(rarity.Id)
		local perfect, good = ExtractionMath.zoneWidthsFor(rarity.Id)
		expectEqual(#speeds, ExtractionConfig.Hits, "a speed for every hit")
		expect(speeds[1] >= lastSpeed, rarity.Id .. " is slower than a commoner rarity")
		expect(good <= lastGood and perfect <= lastPerfect, rarity.Id .. " has a bigger zone")
		expect(perfect < good, "the Perfect band must sit inside the Good band")
		lastSpeed, lastGood, lastPerfect = speeds[1], good, perfect
	end
	expectEqual(ExtractionConfig.Hits, 3, "hits per extraction")
end)

test("zones stay on the bar and move away from the last one", function()
	local random = seeded(99)
	local zone = ExtractionConfig.Zone
	for _ = 1, 2000 do
		local reference = random()
		local _, good = ExtractionMath.zoneWidthsFor("Common")
		local center = ExtractionMath.pickZone(random, reference, good)
		expect(center - good / 2 >= zone.EdgeMargin - 1e-9, "the zone hangs off the left end")
		expect(center + good / 2 <= 1 - zone.EdgeMargin + 1e-9, "the zone hangs off the right end")
		expect(
			math.abs(center - reference) >= zone.MinShift - 1e-9,
			`zone {center} is too close to {reference}`
		)
	end
end)

print("\nExtraction rules")

-- A fresh extraction, plus the server time its marker sets off.
local function newExtraction(rarity: string, seed: number)
	local state = ExtractionRules.new(rarity, 1000, seeded(seed))
	return state, state.Setup.StartAt
end

-- The first moment from `from` on when the marker is at `target`.
local function timeAt(segment: any, target: number, from: number): number
	local t = math.max(from, segment.StartAt)
	local step = 1 / 2000
	local previous = ExtractionMath.positionAt(segment, t) - target
	for _ = 1, 20000 do
		local nextT = t + step
		local value = ExtractionMath.positionAt(segment, nextT) - target
		if previous == 0 or (previous < 0) ~= (value < 0) then
			return nextT
		end
		t, previous = nextT, value
	end
	error("the marker never reached " .. target)
end

test("a new extraction is set up entirely by the server", function()
	for seed = 1, 50 do
		local state = ExtractionRules.new("Rare", 500, seeded(seed))
		local setup = state.Setup
		expectEqual(setup.Hits, ExtractionConfig.Hits, "hits")
		expect(near(setup.StartAt, 500 + ExtractionConfig.StartDelay), "start time")
		expect(setup.Deadline > setup.StartAt, "the deadline is after the start")
		expectEqual(#setup.Zones, setup.Hits, "a zone for every hit")
		expect(setup.StartDir == 1 or setup.StartDir == -1, "start direction")
		expectEqual(state.Segment.Hit, 1, "first segment")
		expect(not state.Finished, "a new extraction is not finished")
	end
end)

test("the server rates each tap where the marker really was", function()
	local state = newExtraction("Common", 3)
	local wanted = { "Perfect", "Good", "Miss" }
	local setup = state.Setup
	for hit, rating in wanted do
		local segment = state.Segment
		local center = setup.Zones[hit]
		local target = center
		if rating == "Good" then
			local offset = (setup.PerfectWidth + setup.GoodWidth) / 4
			target = if center + offset < 0.97 then center + offset else center - offset
		elseif rating == "Miss" then
			target = if center > 0.5 then 0.03 else 0.97
		end
		local at = timeAt(segment, target, segment.StartAt)
		local outcome = ExtractionRules.tap(state, at, at + 0.05)
		expect(outcome.Ok, `tap {hit} refused: {outcome.Code}`)
		expectEqual(outcome.Rating, rating, `tap {hit}`)
		expectEqual(outcome.Hit, hit, "hit number")
		expect(near(outcome.RatedAt, at), "rated at the claimed moment")
		if hit < #wanted then
			expect(
				near(state.Segment.StartAt, at + setup.HitPause),
				"the next segment waits a pause"
			)
			expect(
				near(state.Segment.StartPos, outcome.Position),
				"the next segment starts at the stop"
			)
		end
	end
	expect(state.Finished, "finished after three taps")
	local condition = ExtractionRules.condition(state)
	expectEqual(condition, ExtractionMath.condition(state.Points), "condition")
	expect(condition >= 1 and condition <= 100, "condition in range")
end)

test("taps before the marker moves, too fast, during the pause or extra are refused", function()
	local state, startAt = newExtraction("Common", 5)
	local early = ExtractionRules.tap(state, startAt - 1, startAt - 1)
	expect(not early.Ok and early.Code == "NotStarted", "a tap before the start")
	expectEqual(#state.Ratings, 0, "no hit recorded for an early tap")

	local first = ExtractionRules.tap(state, startAt + 0.3, startAt + 0.3)
	expect(first.Ok, "a normal tap")
	local burst = ExtractionRules.tap(state, startAt + 0.31, startAt + 0.31)
	expect(not burst.Ok and burst.Code == "TooFast", "a second tap 10 ms later")
	local paused = ExtractionRules.tap(state, startAt + 0.5, startAt + 0.5)
	expect(not paused.Ok and paused.Code == "TooFast", "a tap during the pause after a hit")
	expectEqual(#state.Ratings, 1, "refused taps add no hits")

	local resume = state.Segment.StartAt
	expect(ExtractionRules.tap(state, resume + 0.2, resume + 0.2).Ok, "second tap")
	resume = state.Segment.StartAt
	expect(ExtractionRules.tap(state, resume + 0.2, resume + 0.2).Ok, "third tap")
	expect(state.Finished, "finished")
	local extra = ExtractionRules.tap(state, resume + 2, resume + 2)
	expect(not extra.Ok and extra.Code == "Finished", "a fourth tap")
	expectEqual(#state.Ratings, 3, "still three hits")
end)

test("old and future timestamps are moved into the lag window", function()
	local limits = ExtractionConfig.Server
	local state, startAt = newExtraction("Common", 8)
	-- Claim a moment long gone (say, a known Perfect): rated at the window's edge.
	local arrival = startAt + 2
	local old = ExtractionRules.tap(state, startAt + 0.1, arrival)
	expect(old.Ok, "an old timestamp is still a tap")
	expect(near(old.RatedAt, arrival - limits.LagAllowance), "rated at the oldest allowed moment")

	local resume = state.Segment.StartAt
	local future = ExtractionRules.tap(state, resume + 30, resume + 1)
	expect(future.Ok, "a future timestamp is still a tap")
	expect(
		near(future.RatedAt, resume + 1 + limits.ClockTolerance),
		"rated at the newest allowed moment"
	)
end)

test("running out of time still gives the fossil, with misses for the missing taps", function()
	local state, startAt = newExtraction("Uncommon", 13)
	expect(ExtractionRules.tap(state, startAt + 0.4, startAt + 0.4).Ok, "one real tap")
	ExtractionRules.expire(state)
	expect(state.Finished and state.TimedOut, "finished by timeout")
	expectEqual(#state.Ratings, 3, "every hit has a rating")
	expectEqual(state.Ratings[2], "Miss", "missing tap 2")
	expectEqual(state.Ratings[3], "Miss", "missing tap 3")
	expect(ExtractionRules.condition(state) >= 1, "condition at least 1")

	local idle = newExtraction("Rare", 21)
	ExtractionRules.expire(idle)
	local condition = ExtractionRules.condition(idle)
	expect(condition >= 1, "an untouched extraction still gives a condition of at least 1")
	expectEqual(condition, ExtractionMath.condition({ 3, 3, 3 }), "three worst misses")
end)

print("\nInventory")

local function entry(id: number, fossilId: string, condition: number, foundAt: number)
	return {
		Id = id,
		FossilId = fossilId,
		Rarity = FossilConfig.ById[fossilId].Rarity,
		Condition = condition,
		FoundAt = foundAt,
	}
end

test("finds sort rarest first, then by condition, then newest", function()
	local list = {
		entry(1, "Ammonite", 90, 100),
		entry(2, "TriceratopsHorn", 40, 101),
		entry(3, "SmallDinoBone", 70, 102),
		entry(4, "Ammonite", 95, 103),
		entry(5, "TriceratopsClaw", 80, 104),
		entry(6, "Ammonite", 90, 105),
	}
	local sorted = InventoryLogic.sorted(list)
	local order = {}
	for index, item in sorted do
		order[index] = item.Id
	end
	expectEqual(table.concat(order, ","), "5,2,3,4,6,1", "sorted order")
	expectEqual(list[1].Id, 1, "sorted() must not reorder the original list")
end)

test("duplicates stay separate, and set progress counts distinct pieces", function()
	local list = {
		entry(1, "TriceratopsHorn", 50, 100),
		entry(2, "TriceratopsHorn", 90, 101),
		entry(3, "Ammonite", 60, 102),
	}
	expectEqual(#InventoryLogic.sorted(list), 3, "duplicates are kept as separate entries")
	local progress = InventoryLogic.setProgress(list, "Triceratops")
	expectEqual(progress.Owned, 1, "two horns are one piece")
	expectEqual(progress.Total, 3, "pieces in the set")
	table.insert(list, entry(4, "TriceratopsSkull", 20, 103))
	table.insert(list, entry(5, "TriceratopsClaw", 30, 104))
	expectEqual(InventoryLogic.setProgress(list, "Triceratops").Owned, 3, "a complete set")
	expect(InventoryLogic.setProgress(list, "NoSuchSet") == nil, "unknown set")
	expectEqual(#InventoryLogic.allSetProgress({}), 1, "one set defined")
end)

test("entries from the network are checked", function()
	local good = entry(7, "Ammonite", 55, 1700000000)
	expect(InventoryLogic.validate(good) ~= nil, "a real entry")
	local bad = {
		"text",
		42,
		{},
		{ Id = 1.5, FossilId = "Ammonite", Rarity = "Common", Condition = 50, FoundAt = 1 },
		{ Id = 1, FossilId = "Dragon", Rarity = "Common", Condition = 50, FoundAt = 1 },
		{ Id = 1, FossilId = "Ammonite", Rarity = "Mythic", Condition = 50, FoundAt = 1 },
		{ Id = 1, FossilId = "Ammonite", Rarity = "Common", Condition = 0, FoundAt = 1 },
		{ Id = 1, FossilId = "Ammonite", Rarity = "Common", Condition = 101, FoundAt = 1 },
		{ Id = 1, FossilId = "Ammonite", Rarity = "Common", Condition = 0 / 0, FoundAt = 1 },
		{ Id = 1, FossilId = "Ammonite", Rarity = "Common", Condition = 50, FoundAt = "now" },
	}
	for index, value in bad do
		expect(InventoryLogic.validate(value) == nil, `bad entry {index} was accepted`)
	end
end)

Harness.finish()
