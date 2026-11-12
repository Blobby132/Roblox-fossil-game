--[[
	Simulated play session: the real server and client code, wired together
	through fake remotes, digging a whole plot.

	It checks the things that would otherwise only show up in Studio:
	  * both sides start without errors and build what they should
	  * a full dig works end to end, by mouse and by touch
	  * the server refuses bad, far, fast, flooded and malformed requests
	  * the client undoes a prediction the server rejects
	  * the plot refills, a respawn re-equips the tool, a leaving player frees the plot

	Run from the project folder:   lune run tests/sim
]]

local roblox = require("@lune/roblox")

local Harness = require("./lib/Harness")

local test, expect, expectEqual = Harness.test, Harness.expect, Harness.expectEqual
local Enum, Vector3, CFrame = roblox.Enum, roblox.Vector3, roblox.CFrame

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
GridConfig.RefillDelay = 6

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
	expectEqual(#remotes:GetChildren(), 5, "remote events")
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

test("every fossil can be dug up, brushed and revealed", function()
	local FossilController = clientRequire(Client.Controllers.FossilController)
	local TimeScale = clientRequire(Client.Effects.TimeScale)
	local found = 0

	for fossilIndex, fossil in plot.State.Fossils do
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

test("no hidden errors were raised anywhere", function()
	expectEqual(#Harness.errors, 0, "errors raised inside game code")
end)

Harness.finish()
