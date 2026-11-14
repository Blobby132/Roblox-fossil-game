--!strict
--[[
	FossilService: the fossil parts inside a plot.

	A fossil goes through three stages (see PlotRules.FossilState):
	  Buried    no part exists, so nothing about it reaches any client
	  Encased   its cell was broken; it appears as a plain dirt crust
	  Revealed  brushed clean; the crust becomes the fossil's real shape

	Which fossil it is (DefId) is only written onto the part at Revealed.

	Revealing a fossil starts the extraction minigame (ExtractionService).
	Once it is extracted the fossil goes into the inventory, the part's Stage
	attribute becomes "Extracted", and the part is removed shortly after.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local DigRules = require(Shared.Dig.DigRules)
local FossilConfig = require(Shared.Config.FossilConfig)
local GridConfig = require(Shared.Config.GridConfig)

local Server = script.Parent.Parent
local PlotRules = require(Server.Dig.PlotRules)
local PlotService = require(script.Parent.PlotService)

local FossilService = {}

local function rotationOf(def: FossilConfig.FossilDef): CFrame
	return CFrame.Angles(
		math.rad(def.Rotation.X),
		math.rad(def.Rotation.Y),
		math.rad(def.Rotation.Z)
	)
end

-- Size of the upright box that fits around a rotated part.
local function boundsOf(size: Vector3, rotation: CFrame): Vector3
	local right, up, back = rotation.XVector, rotation.YVector, rotation.ZVector
	return Vector3.new(
		math.abs(right.X) * size.X + math.abs(up.X) * size.Y + math.abs(back.X) * size.Z,
		math.abs(right.Y) * size.X + math.abs(up.Y) * size.Y + math.abs(back.Y) * size.Z,
		math.abs(right.Z) * size.X + math.abs(up.Z) * size.Y + math.abs(back.Z) * size.Z
	)
end

-- Where something of this height rests on the floor of a cell.
local function restPosition(plot: PlotService.Plot, cellIndex: number, height: number): Vector3
	local center = DigRules.cellCenter(plot.Origin, cellIndex)
	return center + Vector3.new(0, -GridConfig.CellSize.Y / 2 + height / 2 + 0.05, 0)
end

-- The fossil's cell just broke: show it as a crust for the player to brush.
function FossilService.Expose(plot: PlotService.Plot, fossilIndex: number)
	local state = plot.State
	if state == nil or plot.FossilParts[fossilIndex] then
		return
	end
	local fossil = state.Fossils[fossilIndex]
	local def = FossilConfig.ById[fossil.DefId]
	local crust = FossilConfig.Crust
	local size = boundsOf(def.Size, rotationOf(def)) * crust.SizeScale

	local part = Instance.new("Part")
	part.Name = tostring(fossil.CellIndex)
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.Size = size
	part.Position = restPosition(plot, fossil.CellIndex, size.Y)
	part.Material = crust.Material
	part.Color = crust.DirtyColor
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part:SetAttribute("Stage", "Encased")
	part:SetAttribute("Clean", 0)
	part:SetAttribute("CleanNeeded", fossil.CleanNeeded)
	part.Parent = plot.FossilsFolder
	plot.FossilParts[fossilIndex] = part
end

-- A brush stroke landed but the fossil is not clean yet.
function FossilService.SetClean(plot: PlotService.Plot, fossilIndex: number, clean: number)
	local part = plot.FossilParts[fossilIndex]
	if part then
		part:SetAttribute("Clean", clean)
	end
end

-- The last stroke landed: turn the crust into the fossil. Returns the fossil's id.
function FossilService.Reveal(plot: PlotService.Plot, fossilIndex: number): string?
	local state = plot.State
	local part = plot.FossilParts[fossilIndex]
	if state == nil or part == nil then
		return nil
	end
	local fossil = state.Fossils[fossilIndex]
	local def = FossilConfig.ById[fossil.DefId]
	local rotation = rotationOf(def)
	local height = boundsOf(def.Size, rotation).Y

	part.Shape = def.Shape
	part.Size = def.Size
	part.CFrame = CFrame.new(restPosition(plot, fossil.CellIndex, height)) * rotation
	part.Material = FossilConfig.RevealedMaterial
	part.Color = def.Color
	part:SetAttribute("Clean", fossil.Clean)
	part:SetAttribute("DefId", def.Id)
	part:SetAttribute("Stage", "Revealed")

	plot.Model:SetAttribute("FossilsFound", state.FossilsFound)
	if PlotRules.isComplete(state) then
		PlotService.ScheduleRefill(plot)
	end
	return def.Id
end

-- The fossil has been extracted into the player's inventory. Its part stays
-- for `removeDelay` seconds so the client can animate it away, then goes.
-- Does nothing if the plot has been reseeded since (`generation` is stale).
function FossilService.MarkExtracted(
	plot: PlotService.Plot,
	fossilIndex: number,
	generation: number,
	removeDelay: number
)
	if plot.Generation ~= generation then
		return
	end
	local part = plot.FossilParts[fossilIndex]
	if part == nil then
		return
	end
	part:SetAttribute("Stage", "Extracted")
	task.delay(removeDelay, function()
		if plot.Generation == generation and plot.FossilParts[fossilIndex] == part then
			plot.FossilParts[fossilIndex] = nil
			part:Destroy()
		end
	end)
end

-- Cell indices of the fossils that are still not uncovered (debug only).
function FossilService.GetHiddenCells(plot: PlotService.Plot): { number }
	local result: { number } = {}
	local state = plot.State
	if state then
		for _, fossil in state.Fossils do
			if fossil.Stage ~= "Revealed" then
				table.insert(result, fossil.CellIndex)
			end
		end
	end
	return result
end

return FossilService
