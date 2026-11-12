--!strict
--[[
	PlotController: this player's view of their own dig plot.

	The server builds the plot and tells us its name (the "PlotName" attribute
	on the player). This controller finds it, keeps a lookup of the cell and
	fossil parts that currently exist, and answers "what did that click hit?".

	It also remembers which cells this client has predicted as broken, so the
	"is this cell exposed?" check matches what the player sees on screen.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local DigRules = require(Shared.Dig.DigRules)
local Signal = require(Shared.Util.Signal)

export type Target = {
	Kind: "Cell" | "Fossil",
	Part: BasePart,
	Index: number, -- cell index; a fossil uses the index of the cell it sits in
	Position: Vector3, -- where the click ray hit
	Normal: Vector3, -- which way that surface faces
}

local PlotController = {}

PlotController.Ready = Signal.new() -- (plot: Model)
PlotController.Regenerated = Signal.new() -- ()  the plot was refilled and reseeded
PlotController.CellRemoved = Signal.new() -- (index: number, part: BasePart)
PlotController.FossilAdded = Signal.new() -- (index: number, part: BasePart)
PlotController.FossilRemoved = Signal.new() -- (index: number, part: BasePart)

local player = Players.LocalPlayer

local plotModel: Model? = nil
local pitOrigin: Vector3? = nil
local cellsFolder: Instance? = nil
local fossilsFolder: Instance? = nil
local cellParts: { [number]: BasePart } = {}
local fossilParts: { [number]: BasePart } = {}
local locallyBroken: { [number]: boolean } = {}
local raycastParams = RaycastParams.new()

local function onCellAdded(child: Instance)
	local index = tonumber(child.Name)
	if index and child:IsA("BasePart") then
		cellParts[index] = child
		locallyBroken[index] = nil
	end
end

local function onCellRemoved(child: Instance)
	local index = tonumber(child.Name)
	if index and cellParts[index] == child then
		cellParts[index] = nil
		locallyBroken[index] = nil
		PlotController.CellRemoved:Fire(index, child)
	end
end

local function onFossilAdded(child: Instance)
	local index = tonumber(child.Name)
	if index and child:IsA("BasePart") then
		fossilParts[index] = child
		PlotController.FossilAdded:Fire(index, child)
	end
end

local function onFossilRemoved(child: Instance)
	local index = tonumber(child.Name)
	if index and fossilParts[index] == child then
		fossilParts[index] = nil
		PlotController.FossilRemoved:Fire(index, child)
	end
end

local function waitForPlotName(): string
	while true do
		local name = player:GetAttribute("PlotName")
		if typeof(name) == "string" then
			return name
		end
		player:GetAttributeChangedSignal("PlotName"):Wait()
	end
end

local function bind()
	local site = Workspace:WaitForChild("DigSite")
	local model = site:WaitForChild(waitForPlotName())
	local cells = model:WaitForChild("Cells")
	local fossils = model:WaitForChild("Fossils")
	if not model:IsA("Model") then
		return
	end

	local origin = model:GetAttribute("Origin")
	pitOrigin = if typeof(origin) == "Vector3" then origin else model:GetPivot().Position
	cellsFolder = cells
	fossilsFolder = fossils

	-- Clicks only ever test this plot, so other players and the character
	-- itself never block a swing.
	raycastParams.FilterType = Enum.RaycastFilterType.Include
	raycastParams.FilterDescendantsInstances = { model }

	cells.ChildAdded:Connect(onCellAdded)
	cells.ChildRemoved:Connect(onCellRemoved)
	fossils.ChildAdded:Connect(onFossilAdded)
	fossils.ChildRemoved:Connect(onFossilRemoved)
	for _, child in cells:GetChildren() do
		onCellAdded(child)
	end
	for _, child in fossils:GetChildren() do
		onFossilAdded(child)
	end

	model:GetAttributeChangedSignal("Generation"):Connect(function()
		PlotController.Regenerated:Fire()
	end)

	plotModel = model
	PlotController.Ready:Fire(model)
end

-- Public API ---------------------------------------------------------------

-- The plot model, or nil until the server has assigned one.
function PlotController.getPlot(): Model?
	return plotModel
end

-- Centre of the pit's top surface.
function PlotController.getOrigin(): Vector3?
	return pitOrigin
end

function PlotController.getCellCenter(index: number): Vector3?
	local origin = pitOrigin
	if origin == nil then
		return nil
	end
	return DigRules.cellCenter(origin, index)
end

function PlotController.getFossilPart(index: number): BasePart?
	return fossilParts[index]
end

-- A cell is solid while its part exists and we have not predicted it broken.
function PlotController.isSolid(index: number): boolean
	return cellParts[index] ~= nil and not locallyBroken[index]
end

function PlotController.isExposed(index: number): boolean
	return DigRules.isExposed(index, PlotController.isSolid)
end

function PlotController.setLocallyBroken(index: number, broken: boolean)
	locallyBroken[index] = if broken then true else nil
end

-- What a ray hits in this plot: a cell, a fossil, or nothing diggable.
function PlotController.raycast(origin: Vector3, direction: Vector3): Target?
	if plotModel == nil then
		return nil
	end
	local result = Workspace:Raycast(origin, direction, raycastParams)
	if result == nil then
		return nil
	end
	local hit = result.Instance
	local index = tonumber(hit.Name)
	if index == nil then
		return nil
	end
	local kind: "Cell" | "Fossil"
	if hit.Parent == cellsFolder then
		kind = "Cell"
	elseif hit.Parent == fossilsFolder then
		kind = "Fossil"
	else
		return nil
	end
	return {
		Kind = kind,
		Part = hit,
		Index = index,
		Position = result.Position,
		Normal = result.Normal,
	}
end

function PlotController.Start()
	task.spawn(bind)
end

return PlotController
