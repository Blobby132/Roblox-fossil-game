--!strict
--[[
	DebugController: developer shortcuts for playtesting (keys in DebugConfig).

	  R  refill and reseed your plot right now
	  X  show / hide a marker over every fossil that is still buried

	The keys only send a request. The server decides whether this player is
	allowed (see DebugService), so in a published game they do nothing for
	normal players.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage.Shared
local DebugConfig = require(Shared.Config.DebugConfig)
local Remotes = require(Shared.Remotes)

local Client = script.Parent.Parent
local EffectsRoot = require(Client.Effects.EffectsRoot)
local PlotController = require(script.Parent.PlotController)

local DebugController = {}

local markers: { Instance } = {}
local showing = false

local function clearMarkers()
	for _, marker in markers do
		marker:Destroy()
	end
	table.clear(markers)
end

local function newMarker(size: Vector3, position: Vector3, shape: Enum.PartType)
	local part = Instance.new("Part")
	part.Name = "FossilMarker"
	part.Shape = shape
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = DebugConfig.MarkerColor
	part.Size = size
	part.Position = position
	part.Parent = EffectsRoot.Folder
	table.insert(markers, part)
end

-- Server -> client: the cells that still hide a fossil.
local function onDebugFossils(cellIndices: any)
	clearMarkers()
	local origin = PlotController.getOrigin()
	if not showing or origin == nil or typeof(cellIndices) ~= "table" then
		return
	end
	for _, index in cellIndices do
		local center = if typeof(index) == "number"
			then PlotController.getCellCenter(index)
			else nil
		if center then
			-- A ball floating above the column, and a thin line down to the fossil.
			local top = Vector3.new(center.X, origin.Y + 3, center.Z)
			newMarker(Vector3.new(1.2, 1.2, 1.2), top, Enum.PartType.Ball)
			newMarker(
				Vector3.new(0.2, top.Y - center.Y, 0.2),
				(top + center) / 2,
				Enum.PartType.Block
			)
		end
	end
end

local function onInputBegan(input: InputObject, processedByUi: boolean)
	if processedByUi or input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	if input.KeyCode == DebugConfig.Keys.Reseed then
		Remotes.get("DebugRequest"):FireServer("Reseed")
	elseif input.KeyCode == DebugConfig.Keys.ShowFossils then
		showing = not showing
		if showing then
			Remotes.get("DebugRequest"):FireServer("ShowFossils")
		else
			clearMarkers()
		end
	end
end

function DebugController.Start()
	if not DebugConfig.Enabled then
		return
	end
	Remotes.get("DebugFossils").OnClientEvent:Connect(onDebugFossils)
	UserInputService.InputBegan:Connect(onInputBegan)

	-- A reseeded plot has new fossils: refresh the markers if they are on.
	PlotController.Regenerated:Connect(function()
		clearMarkers()
		if showing then
			Remotes.get("DebugRequest"):FireServer("ShowFossils")
		end
	end)
end

return DebugController
