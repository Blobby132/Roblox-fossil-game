--!strict
--[[
	DigRules: the digging rules that the server and the client both need.

	The server uses these to decide what a swing does. The client uses the same
	functions to predict the result, so feedback plays instantly and
	almost always matches what the server decides a moment later.
]]

local Config = script.Parent.Parent.Config
local GridConfig = require(Config.GridConfig)
local GridMath = require(script.Parent.GridMath)
local ToolConfig = require(Config.ToolConfig)

local DigRules = {}

-- The grid dimensions, in the shape GridMath expects.
local dims: GridMath.Dims = {
	Width = GridConfig.Width,
	Length = GridConfig.Length,
	Layers = GridConfig.Layers,
}
DigRules.Dims = dims

-- Damage one swing of this tool does to this material. 0 means it can't break it.
function DigRules.getDamage(toolId: string, materialId: string): number
	local tool = ToolConfig.Tools[toolId]
	if tool == nil then
		return 0
	end
	return tool.Damage[materialId] or 0
end

-- Fossil cleaning strokes one swing of this tool does. 0 means it can't clean.
function DigRules.getCleanPower(toolId: string): number
	local tool = ToolConfig.Tools[toolId]
	if tool == nil then
		return 0
	end
	return tool.CleanPower
end

-- A cell can be dug when open air touches one of its faces: it is on the
-- surface, or a cell next to it has already been dug out. The pit walls and
-- floor do not count.
function DigRules.isExposed(index: number, isSolid: (index: number) -> boolean): boolean
	local _, layer = GridMath.fromIndex(dims, index)
	if layer == 1 then
		return true
	end
	for _, neighbor in GridMath.neighbors(dims, index) do
		if not isSolid(neighbor) then
			return true
		end
	end
	return false
end

-- Centre of a cell in world space, given the centre of the pit's top surface.
function DigRules.cellCenter(pitOrigin: Vector3, index: number): Vector3
	local size = GridConfig.CellSize
	local x, y, z = GridMath.cellOffset(dims, size.X, size.Y, size.Z, index)
	return pitOrigin + Vector3.new(x, y, z)
end

-- Distance from a point to the nearest point of a cell. Both sides measure
-- reach this way, from the character's root part.
function DigRules.distanceToCell(point: Vector3, cellCenter: Vector3): number
	local half = GridConfig.CellSize / 2
	local delta = point - cellCenter
	local dx = math.max(math.abs(delta.X) - half.X, 0)
	local dy = math.max(math.abs(delta.Y) - half.Y, 0)
	local dz = math.max(math.abs(delta.Z) - half.Z, 0)
	return math.sqrt(dx * dx + dy * dy + dz * dz)
end

return DigRules
