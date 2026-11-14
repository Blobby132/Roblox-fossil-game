--[[
	Simulated play session: the real server and client code, wired together
	through fake remotes, digging a whole plot.

	It checks the things that would otherwise only show up in Studio:
	  * both sides start without errors and build what they should
	  * a full dig works end to end, by mouse and by touch
	  * every uncovered fossil is extracted by tapping (click, touch, Space)
	    and lands in the inventory, which the HUD panel lists
	  * the server refuses bad, far, fast, flooded and malformed requests,
	    and rates extraction taps itself
	  * the client undoes a prediction the server rejects
	  * the plot refills (but never mid-extraction), a respawn re-equips the
	    tool, a leaving player frees the plot and loses the inventory

	Run from the project folder:   lune run tests/sim
]]

local roblox = require("@lune/roblox")

local Harness = require("./lib/Harness")

local test, expect, expectEqual = Harness.test, Harness.expect, Harness.expectEqual
local Enum, Vector3, CFrame = roblox.Enum, roblox.Vector3, roblox.CFrame
local UDim2 = roblox.UDim2

local game = Harness.build()
local serverRequire = Harness.newRequire("Server")
local clientRequire = Harness.newRequire("Client")

local Workspace = game:GetService("Workspace")
local Shared = game:GetService("ReplicatedStorage").Shared
local Server = game:GetService("ServerScriptService").Server
local Client = game:GetService("StarterPlayer").StarterPlayerScripts.Client

-- The server's own copies of the config, so the test can shorten the refill.
local GridConfig = serverRequire(Shared.Config.GridConfig)
local DigConfig = serverRequire(Shared.Config.DigConfig)
local ToolConfig = serverRequire(Shared.Config.ToolConfig)
local WorldConfig = serverRequire(Shared.Config.WorldConfig)
local FossilConfig = serverRequire(Shared.Config.FossilConfig)
local GridMath = serverRequire(Shared.Dig.GridMath)
local DigRules = serverRequire(Shared.Dig.DigRules)
local ExtractionConfig = serverRequire(Shared.Config.ExtractionConfig)
local ExtractionMath = serverRequire(Shared.Extraction.ExtractionMath)
local InventoryLogic = serverRequire(Shared.Inventory.InventoryLogic)
local RarityConfig = serverRequire(Shared.Config.RarityConfig)
GridConfig.RefillDelay = 6
GridConfig.RefillDelayAfterExtraction = 6
-- Keep the test output clean; the analytics calls themselves still run.
serverRequire(Shared.Config.AnalyticsConfig).PrintInStudio = false

local dims = DigRules.Dims
local camera = roblox.Instance.new("Camera")
camera.Parent = Workspace
Workspace.CurrentCamera = camera

local player, character, plot, PlotService
local repliesFirst = false
local useTouch = false

local function rootPart()
	return character:FindFirstChild("HumanoidRootPart")
end

local function standAbove(cellIndex: number)
	local center = DigRules.cellCenter(plot.Origin, cellIndex)
	rootPart().CFrame = CFrame.new(center.X, plot.Origin.Y + 3, center.Z)
end

local function aimAt(part: any)
	Harness.raycastResult = {
		Instance = part,
		Position = part.Position + Vector3.new(0, part.Size.Y / 2, 0),
		Normal = Vector3.new(0, 1, 0),
	}
end

local function selectTool(toolId: string)
	Harness.keyPress(if toolId == "Pickaxe" then Enum.KeyCode.One else Enum.KeyCode.Two)
end

-- One swing at a part, a network round trip, then wait out the cooldown.
-- Alternates mouse / touch and the order in which replies arrive.
local function swing(part: any, toolId: string)
	aimAt(part)
	if useTouch then
		Harness.tap()
	else
		Harness.click()
	end
	useTouch = not useTouch
	repliesFirst = not repliesFirst
	local replies = Harness.roundTrip(repliesFirst)
	Harness.advance(ToolConfig.Tools[toolId].Cooldown)
	Harness.frame()
	return replies
end

local function toolFor(materialId: string): string
	return if DigRules.getDamage("Brush", materialId) > 0 then "Brush" else "Pickaxe"
end

-- Digs straight down a column, through the client, until this cell is gone.
local function digDownTo(cellIndex: number)
	local x, layer, z = GridMath.fromIndex(dims, cellIndex)
	standAbove(cellIndex)
	for depth = 1, layer do
		local index = GridMath.toIndex(dims, x, depth, z)
		local part = plot.CellParts[index]
		if part then
			local toolId = toolFor(part:GetAttribute("Mat"))
			selectTool(toolId)
			local guard = 0
			while plot.CellParts[index] ~= nil do
				swing(part, toolId)
				guard += 1
				expect(guard < 40, `cell {index} never broke`)
			end
		end
	end
end

local function playFrames(seconds: number)
	for _ = 1, math.ceil(seconds * 60) do
		Harness.frame()
	end
end

local function findReply(replies: any, seq: number)
	for _, message in replies do
		if message.remote.Name == "SwingResult" and message.args[1] == seq then
			return message.args
		end
	end
	return nil
end

-- Extraction helpers ---------------------------------------------------------

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function extractionState()
	return clientRequire(Client.Controllers.ExtractionController).getState()
end

local function hud()
	return player.PlayerGui.DigHud
end

-- Every GuiObject under `root` must be sized and placed with Scale only.
local function expectScaleOnly(root: any)
	for _, descendant in root:GetDescendants() do
		if descendant:IsA("GuiObject") then
			local size, position = descendant.Size, descendant.Position
			expect(
				size.X.Offset == 0 and size.Y.Offset == 0,
				descendant:GetFullName() .. " is sized with Offset"
			)
			expect(
				position.X.Offset == 0 and position.Y.Offset == 0,
				descendant:GetFullName() .. " is positioned with Offset"
			)
		end
	end
end

-- The first moment from `from` on when the marker passes `target`.
local function timeMarkerReaches(segment: any, target: number, from: number): number
	local t = math.max(from, segment.StartAt)
	local step = 1 / 480
	local previous = ExtractionMath.positionAt(segment, t) - target
	for _ = 1, 5000 do
		local nextT = t + step
		local value = ExtractionMath.positionAt(segment, nextT) - target
		if previous == 0 or (previous < 0) ~= (value < 0) then
			-- Narrow it down, so the tap lands right on the target.
			local low, high = t, nextT
			for _ = 1, 30 do
				local mid = (low + high) / 2
				local midValue = ExtractionMath.positionAt(segment, mid) - target
				if (midValue < 0) == (previous < 0) and midValue ~= 0 then
					low = mid
				else
					high = mid
				end
			end
			return high
		end
		t, previous = nextT, value
	end
	error("the marker never reached " .. target)
end

-- Where to stop the marker to earn a rating on this hit.
local function targetFor(info: any, hit: number, rating: string): number
	local center = info.Zones[hit]
	if rating == "Perfect" then
		return center
	elseif rating == "Good" then
		local offset = (info.PerfectWidth + info.GoodWidth) / 4
		return if center + offset <= 0.97 then center + offset else center - offset
	end
	return if center > 0.5 then 0.03 else 0.97
end

-- One extraction tap, by click, touch or the Space key.
local function extractionTap(method: string)
	if method == "space" then
		Harness.keyPress(Enum.KeyCode.Space)
	else
		local inputType = if method == "touch"
			then Enum.UserInputType.Touch
			else Enum.UserInputType.MouseButton1
		Harness.guiInput(hud().ExtractionTapCatcher, inputType)
	end
end

local function waitForExtractionBar()
	Harness.roundTrip()
	local guard = 0
	while true do
		local state = extractionState()
		if state and state.Opened then
			return state
		end
		Harness.frame()
		guard += 1
		expect(guard < 600, "the extraction bar never opened")
	end
end

local function findMessage(messages: any, remoteName: string)
	for _, message in messages do
		if message.remote.Name == remoteName then
			return message.args
		end
	end
	return nil
end

local extractedCount = 0

-- Plays the running extraction through the client: waits for the bar, then
-- taps when the marker is where each wanted rating needs it. Returns the
-- server's ExtractionFinished result.
local function playExtraction(wanted: { string }, methods: { string }?)
	local state = waitForExtractionBar()
	local finished = nil
	for hit, rating in wanted do
		state = extractionState()
		local segment = state.Segment
		expect(segment ~= nil, `no segment for hit {hit}`)
		expectEqual(segment.Hit, hit, "segment hit number")
		local at = timeMarkerReaches(segment, targetFor(state.Info, hit, rating), serverNow())
		Harness.advance(at - serverNow())
		extractionTap(if methods then methods[hit] else "click")
		expectEqual(extractionState().Ratings[hit], rating, `predicted rating for hit {hit}`)
		local replies = Harness.roundTrip()
		local reply = findMessage(replies, "ExtractionTapResult")
		expect(reply ~= nil, `no reply to tap {hit}`)
		expect(reply[2].Ok, `the server refused tap {hit}: {reply[2].Code}`)
		expectEqual(reply[2].Rating, rating, `server rating for hit {hit}`)
		finished = findMessage(replies, "ExtractionFinished") or finished
	end
	expect(finished ~= nil, "the server never sent ExtractionFinished")
	extractedCount += 1
	-- Let the last rating show, then the "Extracted!" moment.
	playFrames(ExtractionConfig.HitPause + 0.1)
	expect(extractionState().ResultShown, "the Extracted! moment did not show")
	return finished[2]
end

-- Ends the "Extracted!" moment early with a tap, as a player would.
local function closeExtraction()
	Harness.advance(ExtractionConfig.Feel.MinResultTime)
	extractionTap("click")
	Harness.frame()
	expect(extractionState() == nil, "the extraction is still open")
end

-- Digs up and brushes the next buried fossil through the client, which
-- starts its extraction. Reseeds the plot first if none is left.
local function uncoverNextFossil(): number
	-- A refill that is already counting down would rebuild the ground mid-dig.
	local refillAt = plot.Model:GetAttribute("RefillAt") or 0
	if refillAt > 0 then
		Harness.advance(math.max(refillAt - serverNow(), 0) + 0.1)
		Harness.roundTrip()
	end
	local function nextBuried()
		for index, fossil in plot.State.Fossils do
			if fossil.Stage ~= "Revealed" then
				return index, fossil
			end
		end
		return nil, nil
	end
	local index, fossil = nextBuried()
	if index == nil then
		Harness.advance(1)
		Harness.fireServer("DebugRequest", "Reseed")
		Harness.roundTrip()
		Harness.roundTrip()
		index, fossil = nextBuried()
	end
	digDownTo(fossil.CellIndex)
	local crust = plot.FossilParts[index]
	selectTool("Brush")
	local guard = 0
	while fossil.Stage ~= "Revealed" do
		swing(crust, "Brush")
		guard += 1
		expect(guard < 20, "the fossil was never uncovered")
	end
	return index
end

-- A surface cell that is still standing, away from the fossil columns.
local function freshSurfaceCell(skip: number?): number
	local taken = {}
	for _, fossil in plot.State.Fossils do
		local x, _, z = GridMath.fromIndex(dims, fossil.CellIndex)
		taken[`{x},{z}`] = true
	end
	local skipped = 0
	for z = 1, dims.Length do
		for x = 1, dims.Width do
			local index = GridMath.toIndex(dims, x, 1, z)
			local cell = plot.State.Cells[index]
			if not taken[`{x},{z}`] and not cell.Broken and cell.Health == 3 then
				if skipped >= (skip or 0) then
					return index
				end
				skipped += 1
			end
		end
	end
	error("no untouched surface cell left")
end

------------------------------------------------------------------------------
print("Startup")

test("the server starts and builds the dig site", function()
	Harness.runScript(Server.Main, "Server", serverRequire)
	local site = Workspace:FindFirstChild("DigSite")
	expect(site ~= nil, "Workspace.DigSite was not built")
	for id = 1, WorldConfig.MaxPlots do
		local model = site:FindFirstChild(`Plot_{id}`)
		expect(model ~= nil, `Plot_{id} is missing`)
		for _, name in { "Ground", "Cells", "Fossils", "Museum", "Spawn" } do
			expect(model:FindFirstChild(name) ~= nil, `Plot_{id}.{name} is missing`)
		end
		expect(model.Ground:FindFirstChild("Cover") ~= nil, "an unclaimed plot should be covered")
		expectEqual(#model.Cells:GetChildren(), 0, "cells in an unclaimed plot")
	end
	local remotes = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")
	expect(remotes ~= nil, "the Remotes folder was not created")
	expectEqual(#remotes:GetChildren(), 12, "remote events")
end)

test("a joining player gets a plot, a spawn pad and a pickaxe", function()
	PlotService = serverRequire(Server.Services.PlotService)
	player = Harness.addPlayer("Tester", 1001)
	plot = PlotService.GetPlot(player)
	expect(plot ~= nil, "no plot was assigned")
	expectEqual(player:GetAttribute("PlotName"), plot.Model.Name, "PlotName attribute")
	expectEqual(player.RespawnLocation, plot.Spawn, "RespawnLocation")
	expectEqual(#plot.CellsFolder:GetChildren(), GridMath.cellCount(dims), "cells in the plot")
	expectEqual(#plot.FossilsFolder:GetChildren(), 0, "fossil parts before any digging")
	expect(plot.Model.Ground:FindFirstChild("Cover") == nil, "the cover should be gone")
	expectEqual(plot.Model:GetAttribute("FossilsTotal"), #plot.State.Fossils, "FossilsTotal")

	character = Harness.spawnCharacter(player, plot.Spawn.Position + Vector3.new(0, 4, 0))
	Harness.advance(0.1)
	local tool = character:FindFirstChildOfClass("Tool")
	expect(tool ~= nil, "no tool was equipped on spawn")
	expectEqual(tool:GetAttribute("ToolId"), ToolConfig.DefaultTool, "starting tool")
	expect(tool:FindFirstChild("Handle") ~= nil, "the tool has no Handle part")
	expectEqual(
		character.Humanoid.JumpHeight,
		WorldConfig.Character.JumpHeight,
		"character jump height"
	)
end)

test("buried fossils and deep hints are not visible to clients", function()
	-- Nothing about a buried fossil may exist as an instance.
	expectEqual(#plot.FossilsFolder:GetChildren(), 0, "fossil parts")
	for index, part in plot.CellParts do
		local _, layer = GridMath.fromIndex(dims, index)
		expect(part:GetAttribute("FossilIndex") == nil, "a cell leaks its fossil")
		expect(part:GetAttribute("HintLevel") == nil, "a cell leaks its hint level")
		if layer > 1 then
			expectEqual(#part:GetChildren(), 0, `buried cell {index} already shows cracks`)
		end
	end
end)

test("surface cells above fossils show hints", function()
	local hinted = 0
	for _, fossil in plot.State.Fossils do
		local x, layer, z = GridMath.fromIndex(dims, fossil.CellIndex)
		local level = GridConfig.Hints.LevelByDistance[layer - 1] or 0
		local look = GridConfig.Hints.Levels[level]
		local surface = plot.CellParts[GridMath.toIndex(dims, x, 1, z)]
		if look then
			hinted += 1
			expectEqual(#surface:GetChildren(), look.Cracks, `cracks above a layer-{layer} fossil`)
		end
	end
	expect(hinted > 0, "no fossil produced a surface hint")
end)

test("the client starts and builds its interface", function()
	Harness.watchChildren(plot.CellsFolder)
	Harness.watchChildren(plot.FossilsFolder)
	Harness.runScript(Client.Main, "Client", clientRequire)
	Harness.roundTrip()
	playFrames(0.2)

	local hud = player.PlayerGui:FindFirstChild("DigHud")
	expect(hud ~= nil, "the HUD was not created")
	local toolBar = hud:FindFirstChild("ToolBar")
	expect(toolBar ~= nil, "the tool bar is missing")
	expect(toolBar:FindFirstChild("Pickaxe") ~= nil, "the Pickaxe button is missing")
	expect(toolBar:FindFirstChild("Brush") ~= nil, "the Brush button is missing")
	local counter = hud.FossilCounter.Counter
	expectEqual(counter.Text, `Fossils 0 / {#plot.State.Fossils}`, "counter text")

	-- Every piece of UI must be sized with Scale, not pixel Offset.
	for _, descendant in hud:GetDescendants() do
		if descendant:IsA("GuiObject") then
			local size, position = descendant.Size, descendant.Position
			expect(
				size.X.Offset == 0 and size.Y.Offset == 0,
				descendant:GetFullName() .. " is sized with Offset"
			)
			expect(
				position.X.Offset == 0 and position.Y.Offset == 0,
				descendant:GetFullName() .. " is positioned with Offset"
			)
		end
	end
	expect(toolBar:FindFirstChildOfClass("UIAspectRatioConstraint") ~= nil, "tool bar aspect ratio")

	-- Milestone 2: the inventory button shows; the panels are built but hidden.
	local button = hud:FindFirstChild("InventoryButton")
	expect(button ~= nil and button.Visible, "the inventory button is missing")
	expect(not button.Badge.Visible, "an empty inventory should show no badge")
	expect(not hud.InventoryPanel.Visible, "the inventory panel should start closed")
	expect(not hud.ExtractionPanel.Visible, "the extraction panel should start hidden")
	expect(not hud.ExtractionTapCatcher.Visible, "the tap catcher should start hidden")
	for _, name in { "InventoryButton", "InventoryPanel", "ExtractionPanel" } do
		expect(
			hud[name]:FindFirstChildOfClass("UIAspectRatioConstraint") ~= nil,
			name .. " has no aspect ratio constraint"
		)
	end
end)

------------------------------------------------------------------------------
print("\nDigging")

test("hitting a cell damages it, and the last hit breaks it", function()
	local index = freshSurfaceCell()
	local part = plot.CellParts[index]
	standAbove(index)
	selectTool("Pickaxe")

	local soundsBefore = Harness.stats.soundsPlayed
	local particlesBefore = Harness.stats.particlesEmitted
	swing(part, "Pickaxe")
	expectEqual(part:GetAttribute("Health"), 2, "health after one pickaxe hit")
	expect(Harness.stats.soundsPlayed > soundsBefore, "no hit sound played")
	expect(Harness.stats.particlesEmitted > particlesBefore, "no hit particles")

	swing(part, "Pickaxe")
	swing(part, "Pickaxe")
	expect(plot.CellParts[index] == nil, "the cell should be broken after three hits")
	expect(plot.State.Cells[index].Broken, "server state should say broken")
end)

test("the brush cannot break rock, on the client or the server", function()
	-- Find an exposed rock cell, or expose one.
	local rockIndex
	for index, cell in plot.State.Cells do
		local _, layer = GridMath.fromIndex(dims, index)
		if cell.Material == "Rock" and layer == 2 and cell.FossilIndex == nil then
			rockIndex = index
			break
		end
	end
	expect(rockIndex ~= nil, "this plot has no rock in layer 2")
	local x, _, z = GridMath.fromIndex(dims, rockIndex)
	digDownTo(GridMath.toIndex(dims, x, 1, z))

	local rock = plot.CellParts[rockIndex]
	selectTool("Brush")
	local pickaxeButton = player.PlayerGui.DigHud.ToolBar.Pickaxe
	local scale = pickaxeButton:FindFirstChildOfClass("UIScale")
	scale.Scale = 0
	local replies = swing(rock, "Brush")
	expectEqual(#replies, 0, "the client should not even send a brush-on-rock swing")
	expect(scale.Scale > 0, "the Pickaxe button did not pulse as a hint")
	expectEqual(rock:GetAttribute("Health"), 4, "rock health after a brush stroke")

	-- A tampered client sends it anyway.
	Harness.advance(1)
	Harness.fireServer("SwingRequest", 9001, rockIndex)
	local reply = findReply(Harness.roundTrip(), 9001)
	expect(reply ~= nil, "no reply to the forced swing")
	expectEqual(reply[3], "WrongTool", "server's ruling on brush versus rock")
	expectEqual(rock:GetAttribute("Health"), 4, "rock health after the forced swing")
	Harness.advance(1)
end)

test("every fossil can be dug up, brushed, revealed and extracted", function()
	local FossilController = clientRequire(Client.Controllers.FossilController)
	local TimeScale = clientRequire(Client.Effects.TimeScale)
	local InventoryService = serverRequire(Server.Services.InventoryService)
	local found = 0
	local generation = plot.Generation
	local patterns = {
		{ "Perfect", "Perfect", "Perfect" },
		{ "Perfect", "Good", "Miss" },
		{ "Good", "Good", "Good" },
		{ "Miss", "Perfect", "Good" },
	}
	local methods = { "click", "touch", "space" }

	for fossilIndex, fossil in plot.State.Fossils do
		local isLast = fossilIndex == #plot.State.Fossils
		if isLast then
			-- Make the refill come due while the last fossil is being extracted.
			GridConfig.RefillDelay = 1
		end
		digDownTo(fossil.CellIndex)
		expectEqual(fossil.Stage, "Encased", "stage once its cell breaks")

		local crust = plot.FossilParts[fossilIndex]
		expect(crust ~= nil, "no crust part appeared")
		expectEqual(crust:GetAttribute("Stage"), "Encased", "crust Stage attribute")
		expect(crust:GetAttribute("DefId") == nil, "the crust gives away which fossil it is")

		-- The pickaxe does nothing to a crust.
		selectTool("Pickaxe")
		expectEqual(#swing(crust, "Pickaxe"), 0, "pickaxe-on-crust should not be sent")

		selectTool("Brush")
		for stroke = 1, fossil.CleanNeeded do
			expect(not FossilController.isBusy(), "digging is locked before the last stroke")
			swing(crust, "Brush")
			if stroke < fossil.CleanNeeded then
				expectEqual(crust:GetAttribute("Clean"), stroke, "Clean attribute")
			end
		end

		-- The server has revealed it; the client is in its slow-motion moment.
		expectEqual(fossil.Stage, "Revealed", "server stage after the last stroke")
		expectEqual(crust:GetAttribute("DefId"), fossil.DefId, "DefId attribute")
		found += 1
		expectEqual(plot.Model:GetAttribute("FossilsFound"), found, "FossilsFound")

		playFrames(2.5)
		expect(not FossilController.isBusy(), "digging is still locked after the reveal")
		expectEqual(TimeScale.get(), 1, "time scale after the reveal")
		expectEqual(camera.FieldOfView, 70, "camera field of view after the reveal")
		expect(crust:FindFirstChildOfClass("Highlight") ~= nil, "no glow on the fossil")
		expect(crust:FindFirstChildOfClass("PointLight") ~= nil, "no light on the fossil")
		expect(crust:FindFirstChildOfClass("ParticleEmitter") ~= nil, "no sparkles on the fossil")
		local label = crust:FindFirstChild("FossilLabel")
		expect(label ~= nil, "no name tag on the fossil")
		expectEqual(label.FossilName.Text, FossilConfig.ById[fossil.DefId].DisplayName, "name tag")
		expect(crust.Position.Y > plot.Origin.Y, "the fossil should hover above the surface")

		local counter = player.PlayerGui.DigHud.FossilCounter.Counter
		expectEqual(counter.Text, `Fossils {found} / {#plot.State.Fossils}`, "counter text")

		-- Uncovering it started the extraction, which holds back the refill.
		if isLast then
			expect(plot.RefillPending, "the refill should wait for the running extraction")
			expectEqual(plot.Generation, generation, "the plot refilled during an extraction")
			expect(crust.Parent ~= nil, "the fossil vanished during its extraction")
		end
		local rotated = {}
		for hit = 1, 3 do
			rotated[hit] = methods[(fossilIndex + hit - 2) % #methods + 1]
		end
		local result = playExtraction(patterns[(fossilIndex - 1) % #patterns + 1], rotated)
		local entries = InventoryService.GetEntries(player)
		expectEqual(#entries, extractedCount, "inventory entries")
		local newest = entries[#entries]
		expectEqual(newest.FossilId, fossil.DefId, "the inventory got the wrong fossil")
		expectEqual(newest.Condition, result.Condition, "inventory condition")
		expectEqual(newest.Rarity, FossilConfig.ById[fossil.DefId].Rarity, "inventory rarity")
		closeExtraction()

		if isLast then
			expect(not plot.RefillPending, "the waiting refill was not rescheduled")
			expect(
				plot.Model:GetAttribute("RefillAt") > serverNow(),
				"no refill countdown after the extraction"
			)
			GridConfig.RefillDelay = 6
		end
	end
end)

------------------------------------------------------------------------------
print("\nRefill")

test("a finished plot counts down, then refills and reseeds", function()
	expect(plot.Model:GetAttribute("RefillAt") > 0, "no refill was scheduled")
	Harness.roundTrip()
	local status = player.PlayerGui.DigHud.Status
	playFrames(0.5)
	expect(status.Visible, "the refill countdown is not showing")

	-- Stand at the bottom of the pit: the refill must lift the player out.
	rootPart().CFrame = CFrame.new(plot.Origin + Vector3.new(0, -5, 0))
	local generation = plot.Generation
	Harness.advance(GridConfig.RefillDelay + 0.1)
	Harness.roundTrip()
	playFrames(0.5)

	expectEqual(plot.Generation, generation + 1, "generation")
	expectEqual(#plot.CellsFolder:GetChildren(), GridMath.cellCount(dims), "cells after the refill")
	expectEqual(#plot.FossilsFolder:GetChildren(), 0, "fossil parts after the refill")
	expectEqual(plot.Model:GetAttribute("FossilsFound"), 0, "FossilsFound after the refill")
	expect(rootPart().Position.Y > plot.Origin.Y, "the player was left inside the new ground")
	expect(not status.Visible, "the countdown is still showing")
	local counter = player.PlayerGui.DigHud.FossilCounter.Counter
	expectEqual(counter.Text, `Fossils 0 / {#plot.State.Fossils}`, "counter after the refill")
end)

------------------------------------------------------------------------------
print("\nServer checks")

test("malformed requests are ignored without errors", function()
	local huge = GridMath.cellCount(dims) + 1
	Harness.fireServer("SwingRequest")
	Harness.fireServer("SwingRequest", "abc", 5)
	Harness.fireServer("SwingRequest", 1, "five")
	Harness.fireServer("SwingRequest", 1, 0 / 0)
	Harness.fireServer("SwingRequest", 0 / 0, 1)
	Harness.fireServer("SwingRequest", 1, huge)
	Harness.fireServer("SwingRequest", 1, 0)
	Harness.fireServer("SwingRequest", 1, 2.5)
	Harness.fireServer("SwingRequest", 1.5, 2)
	Harness.fireServer("SwingRequest", {}, {})
	Harness.fireServer("SwingRequest", 1, math.huge)
	Harness.fireServer("EquipRequest")
	Harness.fireServer("EquipRequest", 42)
	Harness.fireServer("EquipRequest", "Jackhammer")
	Harness.fireServer("DebugRequest", {})
	Harness.fireServer("DebugRequest", "DeleteEverything")
	local replies = Harness.roundTrip()
	expectEqual(#replies, 0, "replies to malformed requests")
	Harness.advance(2)
end)

test("a swing from too far away is refused", function()
	local index = freshSurfaceCell()
	rootPart().CFrame = CFrame.new(plot.Origin + Vector3.new(0, 3, 200))
	Harness.fireServer("SwingRequest", 9100, index)
	local reply = findReply(Harness.roundTrip(), 9100)
	expect(reply ~= nil, "no reply")
	expectEqual(reply[2], false, "ok")
	expectEqual(reply[3], "TooFar", "code")
	expectEqual(plot.State.Cells[index].Health, 3, "cell health")
	Harness.advance(2)
end)

test("the reach limit is the tool's range plus the lag allowance", function()
	local index = freshSurfaceCell()
	local center = DigRules.cellCenter(plot.Origin, index)
	local top = center + Vector3.new(0, GridConfig.CellSize.Y / 2, 0)
	local limit = ToolConfig.Tools.Pickaxe.Range + DigConfig.RangeTolerance
	selectTool("Pickaxe")
	Harness.roundTrip()

	rootPart().CFrame = CFrame.new(top + Vector3.new(0, limit + 0.5, 0))
	Harness.fireServer("SwingRequest", 9150, index)
	expectEqual(findReply(Harness.roundTrip(), 9150)[3], "TooFar", "just outside the limit")
	Harness.advance(2)

	rootPart().CFrame = CFrame.new(top + Vector3.new(0, limit - 0.5, 0))
	Harness.fireServer("SwingRequest", 9151, index)
	expectEqual(findReply(Harness.roundTrip(), 9151)[3], "Hit", "just inside the limit")
	Harness.advance(2)
end)

test("swinging faster than the cooldown is refused", function()
	local index = freshSurfaceCell()
	standAbove(index)
	selectTool("Pickaxe")
	Harness.roundTrip()
	Harness.advance(2)

	-- Five swings in the same instant: only the first counts.
	for offset = 1, 5 do
		Harness.fireServer("SwingRequest", 9200 + offset, index)
	end
	local replies = Harness.roundTrip()
	expectEqual(findReply(replies, 9201)[3], "Hit", "first swing")
	for offset = 2, 5 do
		expectEqual(findReply(replies, 9200 + offset)[3], "Cooldown", `swing {offset}`)
	end
	expectEqual(plot.State.Cells[index].Health, 2, "cell health after the burst")

	-- Swinging steadily at half the cooldown: about half get through.
	Harness.advance(2)
	local cooldown = ToolConfig.Tools.Pickaxe.Cooldown
	local accepted = 0
	for step = 1, 20 do
		local target = freshSurfaceCell(step % 3)
		standAbove(target)
		Harness.fireServer("SwingRequest", 9300 + step, target)
		local reply = findReply(Harness.roundTrip(), 9300 + step)
		if reply and reply[2] then
			accepted += 1
		end
		Harness.advance(cooldown / 2 - 1 / 60)
	end
	expect(accepted <= 11, `a 2x speed hack landed {accepted} of 20 swings`)
	Harness.advance(2)
end)

test("a buried cell cannot be dug from above", function()
	local surface = freshSurfaceCell()
	local x, _, z = GridMath.fromIndex(dims, surface)
	local buried = GridMath.toIndex(dims, x, 3, z)
	standAbove(surface)
	Harness.fireServer("SwingRequest", 9400, buried)
	local reply = findReply(Harness.roundTrip(), 9400)
	expectEqual(reply[3], "NotExposed", "code")
	Harness.advance(2)
end)

test("a flood of requests is cut off", function()
	local index = freshSurfaceCell()
	standAbove(index)
	for offset = 1, 200 do
		Harness.fireServer("SwingRequest", 10000 + offset, index)
	end
	local replies = Harness.roundTrip()
	expect(
		#replies <= DigConfig.RequestBurst + 1,
		`the server answered {#replies} of 200 flooded requests`
	)
	Harness.advance(5)
end)

test("debug shortcuts work for a developer in Studio", function()
	Harness.fireServer("DebugRequest", "ShowFossils")
	local replies = Harness.roundTrip()
	expectEqual(#replies, 1, "DebugFossils replies")
	expectEqual(replies[1].remote.Name, "DebugFossils", "reply remote")
	expectEqual(#replies[1].args[1], #plot.State.Fossils, "hidden fossils reported")

	-- The X key shows markers; R reseeds the plot.
	local effects = Workspace:FindFirstChild("LocalEffects")
	Harness.keyPress(Enum.KeyCode.X)
	Harness.roundTrip()
	local markers = 0
	for _, child in effects:GetChildren() do
		if child.Name == "FossilMarker" then
			markers += 1
		end
	end
	expectEqual(markers, #plot.State.Fossils * 2, "marker parts")

	local generation = plot.Generation
	Harness.advance(2)
	Harness.keyPress(Enum.KeyCode.R)
	Harness.roundTrip()
	Harness.roundTrip()
	expectEqual(plot.Generation, generation + 1, "generation after pressing R")
	Harness.keyPress(Enum.KeyCode.X)
	Harness.advance(2)
end)

------------------------------------------------------------------------------
print("\nPrediction")

test("a predicted break is undone when the server refuses it", function()
	local index = freshSurfaceCell()
	local part = plot.CellParts[index]
	standAbove(index)
	selectTool("Pickaxe")
	swing(part, "Pickaxe")
	swing(part, "Pickaxe")
	expectEqual(part:GetAttribute("Health"), 1, "health before the last hit")

	-- Click (the client predicts the break and hides the cell), then move the
	-- character out of reach before the request arrives.
	aimAt(part)
	Harness.click()
	expectEqual(part.Transparency, 1, "the predicted break should hide the cell")
	expectEqual(part.CanQuery, false, "a hidden cell should not be clickable")
	rootPart().CFrame = CFrame.new(plot.Origin + Vector3.new(0, 3, 200))
	local replies = Harness.roundTrip()
	expectEqual(replies[1].args[3], "TooFar", "server's ruling")

	expect(plot.CellParts[index] ~= nil, "the server should still have the cell")
	expectEqual(part.Transparency, 0, "the cell should be visible again")
	expectEqual(part.CanQuery, true, "the cell should be clickable again")
	expectEqual(part.CanCollide, true, "the cell should be solid again")

	-- And it still breaks normally afterwards.
	Harness.advance(2)
	standAbove(index)
	swing(part, "Pickaxe")
	expect(plot.CellParts[index] == nil, "the cell should break on a real last hit")
end)

test("a predicted reveal is cancelled when the server refuses it", function()
	local FossilController = clientRequire(Client.Controllers.FossilController)
	local TimeScale = clientRequire(Client.Effects.TimeScale)
	local fossil = plot.State.Fossils[1]
	digDownTo(fossil.CellIndex)
	local crust = plot.FossilParts[1]
	selectTool("Brush")
	for _ = 1, fossil.CleanNeeded - 1 do
		swing(crust, "Brush")
	end

	aimAt(crust)
	Harness.click()
	expect(FossilController.isBusy(), "the reveal should have started")
	expect(TimeScale.get() < 1, "time should have slowed")
	rootPart().CFrame = CFrame.new(plot.Origin + Vector3.new(0, 3, 200))
	Harness.roundTrip()

	expect(not FossilController.isBusy(), "the cancelled reveal still locks digging")
	expectEqual(TimeScale.get(), 1, "time scale after the cancel")
	expectEqual(fossil.Stage, "Encased", "server stage")
	expect(crust:FindFirstChildOfClass("Highlight") == nil, "a cancelled reveal left a glow")
	playFrames(1)
	expectEqual(camera.FieldOfView, 70, "camera field of view after the cancel")

	-- The real last stroke still works.
	Harness.advance(2)
	standAbove(fossil.CellIndex)
	swing(crust, "Brush")
	expectEqual(fossil.Stage, "Revealed", "server stage after a real last stroke")
	playFrames(2.5)
	expect(crust:FindFirstChildOfClass("Highlight") ~= nil, "no glow after the real reveal")
	playExtraction({ "Good", "Good", "Good" })
	closeExtraction()
end)

test("an unanswered swing is forgotten after the timeout", function()
	local index = freshSurfaceCell()
	local part = plot.CellParts[index]
	standAbove(index)
	selectTool("Pickaxe")
	Harness.roundTrip()
	swing(part, "Pickaxe")
	swing(part, "Pickaxe")

	-- The last hit is predicted, but the request never reaches the server.
	aimAt(part)
	Harness.click()
	expectEqual(part.Transparency, 1, "predicted break")
	Harness.dropMessages()
	playFrames(DigConfig.PendingTimeout + 1)

	expectEqual(part.Transparency, 0, "the cell should be visible again after the timeout")
	expectEqual(part.CanQuery, true, "the cell should be clickable again after the timeout")
	expectEqual(part:GetAttribute("Health"), 1, "server health is unchanged")
end)

------------------------------------------------------------------------------
print("\nTouch")

test("a touch-only device digs by tapping and switches tools with the buttons", function()
	Harness.setInputDevices(false, false, true)
	Harness.lastInputType = Enum.UserInputType.Touch

	local toolBar = player.PlayerGui.DigHud.ToolBar
	Harness.press(toolBar.Brush)
	Harness.roundTrip()
	local tool = character:FindFirstChildOfClass("Tool")
	expectEqual(tool:GetAttribute("ToolId"), "Brush", "tool after tapping the Brush button")

	local index = freshSurfaceCell()
	local part = plot.CellParts[index]
	standAbove(index)
	for _ = 1, 3 do
		aimAt(part)
		Harness.tap()
		Harness.roundTrip()
		Harness.advance(ToolConfig.Tools.Brush.Cooldown)
		Harness.frame()
	end
	expect(plot.CellParts[index] == nil, "three brush taps should clear a dirt cell")

	local hover = Workspace.LocalEffects:FindFirstChild("Hover")
	expect(hover == nil or not hover.Visible, "the hover outline should be hidden on touch")

	-- A tap on something out of reach gives the "too far" cue, not a swing.
	local far = freshSurfaceCell()
	rootPart().CFrame = CFrame.new(plot.Origin + Vector3.new(0, 3, 200))
	aimAt(plot.CellParts[far])
	Harness.tap()
	expectEqual(#Harness.roundTrip(), 0, "an out-of-reach tap should not be sent")
	local flash = Workspace.LocalEffects:FindFirstChild("TooFarFlash")
	expect(flash ~= nil and flash.Visible, "no too-far flash")
	Harness.advance(1)
	expect(not flash.Visible, "the too-far flash never went away")

	Harness.press(toolBar.Pickaxe)
	Harness.roundTrip()
	Harness.setInputDevices(true, true, false)
	Harness.lastInputType = Enum.UserInputType.MouseButton1
	Harness.advance(2)
end)

------------------------------------------------------------------------------
print("\nExtraction")

test("uncovering a fossil starts its extraction, and digging waits for it", function()
	local ExtractionService = serverRequire(Server.Services.ExtractionService)
	local index = uncoverNextFossil()
	local active = ExtractionService.GetActive(player)
	expect(active ~= nil, "the server did not start an extraction")
	expectEqual(active.FossilIndex, index, "the extraction is for the wrong fossil")

	-- The same fossil can never start twice, and nothing else starts meanwhile.
	expect(not ExtractionService.Begin(player, plot, index), "the same fossil started twice")
	for otherIndex in plot.State.Fossils do
		expect(not ExtractionService.Begin(player, plot, otherIndex), "a second extraction started")
	end

	local state = waitForExtractionBar()
	local panel = hud().ExtractionPanel
	expect(panel.Visible, "the extraction panel is not showing")
	expect(hud().ExtractionTapCatcher.Visible, "the tap catcher is not showing")
	expectScaleOnly(panel)
	local action = Harness.boundActions.ExtractionTap
	expect(action and table.find(action.inputs, Enum.KeyCode.Space), "Space is not bound")
	local name = FossilConfig.ById[state.Info.FossilId].DisplayName
	expect(string.find(panel.Play.Title.Text, name, 1, true), "the title does not name the fossil")

	-- Digging is paused: a click sends nothing, and a forced swing is refused.
	local cell = freshSurfaceCell()
	standAbove(cell)
	selectTool("Pickaxe")
	aimAt(plot.CellParts[cell])
	Harness.click()
	expect(
		findMessage(Harness.roundTrip(), "SwingResult") == nil,
		"a swing was sent mid-extraction"
	)
	expectEqual(plot.State.Cells[cell].Health, 3, "a cell was dug during extraction")
	Harness.fireServer("SwingRequest", 9600, cell)
	expectEqual(findReply(Harness.roundTrip(), 9600)[3], "Extracting", "forced swing ruling")

	-- Play it: one tap by click, one by touch, one by Space.
	local part = plot.FossilParts[index]
	local serverState = active.State
	local sounds = Harness.stats.soundsPlayed
	local result = playExtraction({ "Perfect", "Good", "Miss" }, { "click", "touch", "space" })
	expect(Harness.stats.soundsPlayed >= sounds + 4, "rating and Extracted! sounds did not play")
	expectEqual(table.concat(result.Ratings, ","), "Perfect,Good,Miss", "server ratings")
	expectEqual(result.Condition, ExtractionMath.condition(serverState.Points), "condition")
	local feel = ExtractionConfig.Feel.Ratings
	expectEqual(panel.Play.Pips.Pip1.BackgroundColor3, feel.Perfect.Color, "Perfect pip")
	expectEqual(panel.Play.Pips.Pip3.BackgroundColor3, feel.Miss.Color, "Miss pip")
	expectEqual(panel.Play.Bar.Popup.Text, feel.Miss.Text, "last popup")

	-- The "Extracted!" moment: "Ammonite: Excellent, 87%".
	expect(panel.Result.Visible, "the result is not showing")
	local line = string.gsub(panel.Result.Line.Text, "<[^>]+>", "")
	expectEqual(line, ExtractionMath.describe(name, result.Condition), "result line")

	-- The fossil flies off, then the server removes it.
	playFrames(ExtractionConfig.Feel.CollectTime + 0.1)
	expectEqual(part.Transparency, 1, "the extracted fossil is still showing")
	expectEqual(part:GetAttribute("Stage"), "Extracted", "Stage attribute")
	closeExtraction()
	expect(not hud().ExtractionTapCatcher.Visible, "the tap catcher is still up")
	expect(Harness.boundActions.ExtractionTap == nil, "Space is still bound")
	Harness.advance(ExtractionConfig.Server.RemovePartDelay)
	expect(plot.FossilParts[index] == nil and part.Parent == nil, "the fossil part was not removed")
	expect(not ExtractionService.Begin(player, plot, index), "an extracted fossil started again")

	-- Digging works again.
	standAbove(cell)
	swing(plot.CellParts[cell], "Pickaxe")
	expectEqual(plot.State.Cells[cell].Health, 2, "digging after the extraction")
end)

test("three misses still give the fossil", function()
	local InventoryService = serverRequire(Server.Services.InventoryService)
	local before = #InventoryService.GetEntries(player)
	uncoverNextFossil()
	local result = playExtraction({ "Miss", "Miss", "Miss" }, { "touch", "touch", "touch" })
	expect(result.Condition >= 1, "condition below 1")
	expect(result.Condition < 40, `three misses gave condition {result.Condition}`)
	expectEqual(#InventoryService.GetEntries(player), before + 1, "the fossil was not added")
	closeExtraction()
end)

test("the server rates taps itself and refuses bad ones", function()
	local ExtractionService = serverRequire(Server.Services.ExtractionService)
	local InventoryService = serverRequire(Server.Services.InventoryService)
	local limits = ExtractionConfig.Server
	Harness.advance(2)
	uncoverNextFossil()
	Harness.roundTrip()
	local active = ExtractionService.GetActive(player)
	local id, state = active.Id, active.State
	local setup = state.Setup

	local function tapReply(claimed: number)
		Harness.fireServer("ExtractionTap", id, claimed)
		local reply = findMessage(Harness.roundTrip(), "ExtractionTapResult")
		expect(reply ~= nil, "no reply to a tap")
		return reply[2]
	end

	-- Malformed taps are ignored outright.
	Harness.fireServer("ExtractionTap")
	Harness.fireServer("ExtractionTap", "x", 1)
	Harness.fireServer("ExtractionTap", id, "now")
	Harness.fireServer("ExtractionTap", id, 0 / 0)
	Harness.fireServer("ExtractionTap", id, math.huge)
	Harness.fireServer("ExtractionTap", 1.5, serverNow())
	Harness.fireServer("ExtractionTap", 0 / 0, serverNow())
	Harness.fireServer("ExtractionTap", {}, {})
	expect(
		findMessage(Harness.roundTrip(), "ExtractionTapResult") == nil,
		"a malformed tap got a reply"
	)
	expectEqual(#state.Ratings, 0, "a malformed tap was rated")

	-- Before the marker sets off.
	expect(serverNow() < setup.StartAt, "the test is too slow: the marker already started")
	expectEqual(tapReply(serverNow()).Code, "NotStarted", "a tap before the start")

	-- A normal tap, then one straight after it, then one during the pause.
	Harness.advance(setup.StartAt - serverNow() + 0.3)
	local first = tapReply(serverNow())
	expect(first.Ok, "a normal tap was refused")
	expectEqual(extractionState().Ratings[1], first.Rating, "the client shows the server's rating")
	expectEqual(tapReply(serverNow()).Code, "TooFast", "a second tap at the same moment")
	Harness.advance(limits.MinTapInterval + 0.05)
	expectEqual(tapReply(serverNow()).Code, "TooFast", "a tap during the pause")
	expectEqual(#state.Ratings, 1, "refused taps were counted")

	-- Claiming a Perfect moment that is long gone: rated at the lag limit instead.
	local segment = state.Segment
	local perfectAt = timeMarkerReaches(segment, setup.Zones[2], segment.StartAt)
	Harness.advance(perfectAt - serverNow() + limits.LagAllowance + 0.4)
	local arrival = serverNow()
	local old = tapReply(perfectAt)
	expect(old.Ok, "an old tap was refused")
	expect(
		math.abs(old.RatedAt - (arrival - limits.LagAllowance)) < 1e-6,
		"an old timestamp was trusted"
	)
	local position = ExtractionMath.positionAt(segment, arrival - limits.LagAllowance)
	local expected =
		ExtractionMath.rate(position, setup.Zones[2], setup.PerfectWidth, setup.GoodWidth)
	expectEqual(old.Rating, expected, "rating at the adjusted moment")

	-- Someone else's extraction cannot be tapped.
	local rival = Harness.addPlayer("Rival", 1003)
	local rivalPlot = PlotService.GetPlot(rival)
	rivalPlot.State.Fossils[1].Stage = "Revealed"
	expect(ExtractionService.Begin(rival, rivalPlot, 1), "the rival's extraction did not start")
	local rivalExtraction = ExtractionService.GetActive(rival)
	Harness.advance(1)
	Harness.fireServer("ExtractionTap", rivalExtraction.Id, serverNow())
	local stolen = findMessage(Harness.roundTrip(), "ExtractionTapResult")[2]
	expect(not stolen.Ok and stolen.Code == "NotYours", "tapped someone else's extraction")
	expectEqual(#rivalExtraction.State.Ratings, 0, "the rival's extraction was changed")
	Harness.removePlayer(rival)
	expect(ExtractionService.GetActive(rival) == nil, "a leaving player's extraction was kept")
	expect(not rivalPlot.RefillHeld, "a leaving player's refill hold was kept")

	-- A timestamp from the future: rated at the clock tolerance.
	Harness.advance(0.5)
	local now = serverNow()
	local future = tapReply(now + 5)
	expect(future.Ok, "a future tap was refused")
	expect(
		math.abs(future.RatedAt - (now + limits.ClockTolerance)) < 1e-6,
		"a future timestamp was trusted"
	)
	expect(ExtractionService.GetActive(player) == nil, "three rated taps did not finish it")
	extractedCount += 1

	-- Extra taps after the end change nothing.
	local count = #InventoryService.GetEntries(player)
	Harness.advance(1)
	expect(not tapReply(serverNow()).Ok, "an extra tap was accepted")
	expectEqual(#InventoryService.GetEntries(player), count, "an extra tap added a fossil")

	-- A flood is cut off.
	Harness.advance(2)
	for _ = 1, 50 do
		Harness.fireServer("ExtractionTap", id, serverNow())
	end
	local replies = 0
	for _, message in Harness.roundTrip() do
		if message.remote.Name == "ExtractionTapResult" then
			replies += 1
		end
	end
	expect(replies <= limits.RequestBurst + 1, `the server answered {replies} of 50 flooded taps`)

	playFrames(ExtractionConfig.Feel.ResultHoldTime + 0.5)
	expect(extractionState() == nil, "the extraction never closed")
	Harness.advance(2)
end)

test("an extraction left alone finishes by itself and still gives the fossil", function()
	local InventoryService = serverRequire(Server.Services.InventoryService)
	local before = #InventoryService.GetEntries(player)
	uncoverNextFossil()
	Harness.roundTrip()
	Harness.advance(ExtractionConfig.StartDelay + ExtractionConfig.Server.MaxDuration + 0.5)
	local finished = findMessage(Harness.roundTrip(), "ExtractionFinished")
	expect(finished ~= nil, "the extraction never finished")
	expect(finished[2].TimedOut, "not marked as timed out")
	expectEqual(table.concat(finished[2].Ratings, ","), "Miss,Miss,Miss", "ratings")
	expectEqual(#InventoryService.GetEntries(player), before + 1, "the fossil was not added")
	extractedCount += 1

	playFrames(0.5)
	expect(extractionState().ResultShown, "the result did not show")
	local sub = hud().ExtractionPanel.Result.Sub.Text
	expect(string.find(sub, "Out of time", 1, true), "no out-of-time message")
	playFrames(ExtractionConfig.Feel.ResultHoldTime + 0.3)
	expect(extractionState() == nil, "the result never closed by itself")
end)

------------------------------------------------------------------------------
print("\nInventory")

test("every find is its own entry, on the server and the client", function()
	local InventoryService = serverRequire(Server.Services.InventoryService)
	local InventoryController = clientRequire(Client.Controllers.InventoryController)
	local entries = InventoryService.GetEntries(player)
	expectEqual(#entries, extractedCount, "server entries")
	local ids = {}
	for _, entry in entries do
		expect(not ids[entry.Id], "two entries share an id")
		ids[entry.Id] = true
		expect(InventoryLogic.validate(entry) ~= nil, "an invalid entry")
		expectEqual(entry.Rarity, FossilConfig.ById[entry.FossilId].Rarity, "entry rarity")
		expect(math.abs(entry.FoundAt - os.time()) < 3600, "FoundAt is not a real time")
	end

	-- Duplicates in different condition stay separate.
	InventoryService.Add(player, "Ammonite", 41, os.time())
	InventoryService.Add(player, "Ammonite", 92, os.time())
	InventoryService.Add(player, "TriceratopsHorn", 77, os.time())
	extractedCount += 3
	Harness.roundTrip()
	expectEqual(#InventoryController.getEntries(), extractedCount, "client entries")
	expectEqual(hud().InventoryButton.Badge.Count.Text, tostring(extractedCount), "badge count")

	-- Asking again sends the whole list, which matches.
	Harness.advance(2)
	Harness.fireServer("InventoryRequest")
	local sync = findMessage(Harness.roundTrip(), "InventorySync")
	expect(sync ~= nil, "no InventorySync reply")
	expectEqual(#sync[1], extractedCount, "synced entries")
	expectEqual(#InventoryController.getEntries(), extractedCount, "client entries after a sync")
end)

test("the inventory panel lists finds sorted, with Triceratops set progress", function()
	local InventoryService = serverRequire(Server.Services.InventoryService)
	local button = hud().InventoryButton
	local panel = hud().InventoryPanel
	Harness.press(button)
	Harness.frame()
	expect(panel.Visible, "the panel did not open")
	expectEqual(panel.UIScale.Scale, 1, "the panel did not tween in")
	expectEqual(panel.Position, UDim2.fromScale(0.5, 0.5), "the panel did not slide into place")
	expectScaleOnly(panel)

	local sorted = InventoryService.GetSorted(player)
	local rows = {}
	for _, child in panel.List:GetChildren() do
		if child:IsA("Frame") then
			table.insert(rows, child)
		end
	end
	table.sort(rows, function(a, b)
		return a.LayoutOrder < b.LayoutOrder
	end)
	expectEqual(#rows, #sorted, "rows in the list")
	for index, entry in sorted do
		expectEqual(rows[index].Name, `Entry{entry.Id}`, `row {index}`)
		expect(
			rows[index]:FindFirstChildOfClass("UIAspectRatioConstraint") ~= nil,
			"row aspect ratio"
		)
	end
	-- Rarest first, then best condition.
	for index = 2, #sorted do
		local a, b = sorted[index - 1], sorted[index]
		local orderA = RarityConfig.Rarities[a.Rarity].Order
		local orderB = RarityConfig.Rarities[b.Rarity].Order
		expect(orderA > orderB or (orderA == orderB and a.Condition >= b.Condition), "badly sorted")
	end

	local top, card = sorted[1], rows[1].Card
	expect(
		string.find(card.FossilName.Text, FossilConfig.ById[top.FossilId].DisplayName, 1, true),
		"row name"
	)
	expect(string.find(card.FossilName.Text, "NEW", 1, true), "a new find is not tagged NEW")
	expectEqual(card.Rarity.TextColor3, RarityConfig.Rarities[top.Rarity].Color, "rarity colour")
	expectEqual(
		card.Stripe.BackgroundColor3,
		RarityConfig.Rarities[top.Rarity].Color,
		"rarity stripe"
	)
	local grade = ExtractionMath.grade(top.Condition)
	expectEqual(card.Condition.Text, `{grade.Name} {top.Condition}%`, "condition text")

	local progress = InventoryService.GetSetProgress(player, "Triceratops")
	expect(progress.Owned >= 1, "the test added a horn, so at least one piece is owned")
	expectEqual(
		panel.Sets.Triceratops.Progress.Text,
		`Triceratops {progress.Owned}/3`,
		"set progress"
	)

	-- Close with X; reopening shows no NEW tags.
	Harness.press(panel.Close)
	Harness.advance(0.3)
	expect(not panel.Visible, "the panel did not close")
	Harness.press(button)
	Harness.frame()
	for _, child in panel.List:GetChildren() do
		if child:IsA("Frame") then
			expect(
				not string.find(child.Card.FossilName.Text, "NEW", 1, true),
				"NEW was not cleared"
			)
		end
	end

	-- Uncovering a fossil closes the panel, so the extraction can be seen.
	uncoverNextFossil()
	Harness.roundTrip()
	Harness.advance(0.3)
	expect(not panel.Visible, "the panel stayed open during an extraction")
	playExtraction({ "Perfect", "Perfect", "Good" }, { "space", "space", "space" })
	closeExtraction()
end)

------------------------------------------------------------------------------
print("\nAnalytics")

test("the onboarding funnel logs each step once, in order", function()
	local AnalyticsService = serverRequire(Server.Services.AnalyticsService)
	local steps = table.concat(AnalyticsService.GetLoggedSteps(player), ",")
	expectEqual(steps, "Joined,FirstSwing,FirstFossilUncovered,FirstExtraction", "logged steps")
	AnalyticsService.LogOnboardingStep(player, "FirstSwing")
	expectEqual(#AnalyticsService.GetLoggedSteps(player), 4, "a step was logged twice")
	local newcomer = Harness.addPlayer("Newcomer", 1004)
	expectEqual(table.concat(AnalyticsService.GetLoggedSteps(newcomer), ","), "Joined", "newcomer")
	Harness.removePlayer(newcomer)
end)

------------------------------------------------------------------------------
print("\nLifecycle")

test("a second player gets a separate plot", function()
	local second = Harness.addPlayer("Second", 1002)
	local other = PlotService.GetPlot(second)
	expect(other ~= nil, "the second player got no plot")
	expect(other ~= plot, "two players share a plot")
	expectEqual(
		#other.CellsFolder:GetChildren(),
		GridMath.cellCount(dims),
		"cells in the second plot"
	)
	expectEqual(second.RespawnLocation, other.Spawn, "second player's RespawnLocation")
	expect(
		(other.Origin - plot.Origin).Magnitude > GridConfig.Width * GridConfig.CellSize.X,
		"the two plots overlap"
	)
	Harness.removePlayer(second)
	expectEqual(#other.CellsFolder:GetChildren(), 0, "cells left in the freed plot")
end)

test("a full server leaves the extra player without a plot, without errors", function()
	local extras = {}
	for offset = 1, WorldConfig.MaxPlots do
		table.insert(extras, Harness.addPlayer("Extra" .. offset, 2000 + offset))
	end
	local withPlot = 0
	for _, extra in extras do
		if PlotService.GetPlot(extra) then
			withPlot += 1
		end
	end
	expectEqual(withPlot, WorldConfig.MaxPlots - 1, "extra players who got a plot")
	for _, extra in extras do
		Harness.removePlayer(extra)
	end
end)

test("a respawned character gets its tool back", function()
	local old = character
	character = Harness.spawnCharacter(player, plot.Spawn.Position + Vector3.new(0, 4, 0))
	old.Parent = nil
	Harness.advance(0.2)
	Harness.roundTrip()
	local tool = character:FindFirstChildOfClass("Tool")
	expect(tool ~= nil, "no tool after respawning")

	local index = freshSurfaceCell()
	standAbove(index)
	Harness.fireServer("SwingRequest", 9500, index)
	local reply = findReply(Harness.roundTrip(), 9500)
	expectEqual(reply[2], true, "swing accepted after the respawn")
	Harness.advance(2)
end)

test("a leaving player's plot is cleared and covered again", function()
	local model = plot.Model
	Harness.removePlayer(player)
	expect(PlotService.GetPlot(player) == nil, "the plot is still assigned")
	expectEqual(#model.Cells:GetChildren(), 0, "cells left behind")
	expectEqual(#model.Fossils:GetChildren(), 0, "fossils left behind")
	expect(model.Ground:FindFirstChild("Cover") ~= nil, "the cover was not put back")
	expectEqual(model:GetAttribute("OwnerUserId"), 0, "OwnerUserId")
end)

test("the inventory resets on rejoin (no saving until Milestone 4)", function()
	local DataService = serverRequire(Server.Services.DataService)
	local InventoryService = serverRequire(Server.Services.InventoryService)
	expect(DataService.Get(player) == nil, "the leaving player's data was kept")
	local again = Harness.addPlayer("Tester", 1001)
	expectEqual(#InventoryService.GetEntries(again), 0, "a rejoining player's inventory")
	Harness.removePlayer(again)
end)

test("no hidden errors were raised anywhere", function()
	expectEqual(#Harness.errors, 0, "errors raised inside game code")
end)

Harness.finish()
