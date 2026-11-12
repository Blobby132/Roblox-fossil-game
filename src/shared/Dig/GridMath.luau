--!strict
--[[
	GridMath: index and coordinate maths for the dig grid.

	Pure functions only, no Roblox instances, so the server and the client
	always agree on which cell is which.

	A cell is addressed two ways:
	  (x, layer, z)  x = 1..Width, layer = 1..Layers (1 is the surface), z = 1..Length
	  index          a single number, 1..cellCount, which is what goes over the network
]]

export type Dims = {
	Width: number,
	Length: number,
	Layers: number,
}

local GridMath = {}

function GridMath.cellCount(dims: Dims): number
	return dims.Width * dims.Length * dims.Layers
end

function GridMath.inBounds(dims: Dims, x: number, layer: number, z: number): boolean
	return x >= 1
		and x <= dims.Width
		and layer >= 1
		and layer <= dims.Layers
		and z >= 1
		and z <= dims.Length
end

function GridMath.toIndex(dims: Dims, x: number, layer: number, z: number): number
	return (layer - 1) * dims.Width * dims.Length + (z - 1) * dims.Width + x
end

function GridMath.fromIndex(dims: Dims, index: number): (number, number, number)
	local zeroBased = index - 1
	local perLayer = dims.Width * dims.Length
	local layer = zeroBased // perLayer + 1
	local inLayer = zeroBased % perLayer
	local z = inLayer // dims.Width + 1
	local x = inLayer % dims.Width + 1
	return x, layer, z
end

-- True only for whole numbers from 1 to cellCount. Rejects NaN, infinity and fractions.
function GridMath.isValidIndex(dims: Dims, index: number): boolean
	return index == index and index >= 1 and index <= GridMath.cellCount(dims) and index % 1 == 0
end

-- The up-to-six cells that share a face with this one.
function GridMath.neighbors(dims: Dims, index: number): { number }
	local x, layer, z = GridMath.fromIndex(dims, index)
	local result: { number } = {}
	local function add(nx: number, nLayer: number, nz: number)
		if GridMath.inBounds(dims, nx, nLayer, nz) then
			table.insert(result, GridMath.toIndex(dims, nx, nLayer, nz))
		end
	end
	add(x, layer - 1, z)
	add(x, layer + 1, z)
	add(x - 1, layer, z)
	add(x + 1, layer, z)
	add(x, layer, z - 1)
	add(x, layer, z + 1)
	return result
end

-- Centre of a cell, as an offset from the centre of the pit's top surface.
function GridMath.cellOffset(
	dims: Dims,
	sizeX: number,
	sizeY: number,
	sizeZ: number,
	index: number
): (number, number, number)
	local x, layer, z = GridMath.fromIndex(dims, index)
	local offsetX = (x - (dims.Width + 1) / 2) * sizeX
	local offsetY = -(layer - 0.5) * sizeY
	local offsetZ = (z - (dims.Length + 1) / 2) * sizeZ
	return offsetX, offsetY, offsetZ
end

return GridMath
