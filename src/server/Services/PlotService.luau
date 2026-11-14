--!strict
--[[
	PlotService: gives each player their own dig plot and owns the grid parts.

	  * Builds the greybox site once (WorldBuilder).
	  * Assigns a free plot when a player joins and frees it when they leave.
	  * Turns a plot's state (PlotRules.PlotState) into cell parts, and keeps
	    the parts in step as cells are damaged and broken.
	  * Refills and reseeds a plot once every fossil has been uncovered.

	Per-player plots are a prototype decision. To change it later, this is the
	only service that knows which plot belongs to whom: everything else asks
	PlotService.GetPlot(player).

	What clients can see is deliberately limited: a buried fossil has no part,
	and a cell only gets its hint look (tint and cracks) once it is exposed, so
	an exploiter cannot read fossil positions out of the workspace.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local DigRules = require(Shared.Dig.DigRules)
local GridConfig = require(Shared.Config.GridConfig)
local GridMath = require(Shared.Dig.GridMath)
local MaterialConfig = require(Shared.Config.MaterialConfig)
local WorldConfig = require(Shared.Config.WorldConfig)

local Server = script.Parent.Parent
local PlotGenerator = require(Server.Dig.PlotGenerator)
local PlotRules = require(Server.Dig.PlotRules)
local WorldBuilder = require(Server.World.WorldBuilder)

export type Plot = {
	Id: number,
	Model: Model,
	Origin: Vector3, -- centre of the pit's top surface
	CellsFolder: Folder,
	FossilsFolder: Folder,
	Cover: Part,
	Spawn: SpawnLocation,
	Owner: Player?,
	State: PlotRules.PlotState?,
	CellParts: { [number]: Part }, -- by cell index
	FossilParts: { [number]: Part }, -- by fossil index
	Dressed: { [number]: boolean }, -- cells that already show their hint
	Generation: number, -- goes up by one every time the plot is reseeded
	RefillToken: number, -- cancels a scheduled refill when it changes
	RefillHeld: boolean, -- true while an extraction is running (see SetRefillHeld)
	RefillPending: boolean, -- a refill came due while held; it runs once released
}

local PlotService = {}

local plots: { Plot } = {}
local plotByPlayer: { [Player]: Plot } = {}
local random = Random.new()

local function shade(color: Color3, amount: number): Color3
	return Color3.new(
		math.clamp(color.R * amount, 0, 1),
		math.clamp(color.G * amount, 0, 1),
		math.clamp(color.B * amount, 0, 1)
	)
end

local function buildCell(plot: Plot, index: number, cell: PlotRules.CellState)
	local material = MaterialConfig.Materials[cell.Material]
	local x, layer, z = GridMath.fromIndex(DigRules.Dims, index)
	local layerSettings = GridConfig.LayerSettings[layer]
	local amount = if layerSettings then layerSettings.Shade else 1
	if (x + layer + z) % 2 == 0 then
		amount *= GridConfig.CheckerShade
	end

	local part = Instance.new("Part")
	part.Name = tostring(index)
	part.Anchored = true
	part.Size = GridConfig.CellSize
	part.Position = DigRules.cellCenter(plot.Origin, index)
	part.Material = material.Material
	part.Color = shade(material.Color, amount)
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part:SetAttribute("Mat", cell.Material)
	part:SetAttribute("Health", cell.Health)
	part.Parent = plot.CellsFolder
	plot.CellParts[index] = part
end

-- Shows a cell's hint (tint and cracks). Called only once the cell is exposed.
local function dressCell(plot: Plot, index: number)
	local state = plot.State
	local part = plot.CellParts[index]
	if state == nil or part == nil or plot.Dressed[index] then
		return
	end
	local look = GridConfig.Hints.Levels[state.Cells[index].HintLevel]
	if look == nil then
		return
	end
	plot.Dressed[index] = true

	local hints = GridConfig.Hints
	part.Color = part.Color:Lerp(hints.Color, look.ColorBlend)

	local size = GridConfig.CellSize
	local span = math.min(size.X, size.Z)
	for _ = 1, look.Cracks do
		local length = span * random:NextNumber(hints.CrackLengthMin, hints.CrackLengthMax)
		-- Keep the whole strip on the cell's top face, whatever its angle.
		local reachX = math.max(size.X / 2 - length / 2, 0)
		local reachZ = math.max(size.Z / 2 - length / 2, 0)
		local offset = Vector3.new(
			random:NextNumber(-reachX, reachX),
			size.Y / 2 + 0.02,
			random:NextNumber(-reachZ, reachZ)
		)
		local crack = Instance.new("Part")
		crack.Name = "Crack"
		crack.Anchored = true
		crack.CanCollide = false
		crack.CanQuery = false
		crack.CanTouch = false
		crack.CastShadow = false
		crack.Size = Vector3.new(length, 0.06, hints.CrackThickness)
		crack.CFrame = CFrame.new(part.Position + offset)
			* CFrame.Angles(0, random:NextNumber(0, math.pi), 0)
		crack.Color = hints.CrackColor
		crack.Material = Enum.Material.SmoothPlastic
		crack.Parent = part
	end
end

-- Moves anyone standing in the pit up to the surface, so new cells never
-- appear around them.
local function liftCharactersOutOfPit(plot: Plot)
	local size = GridConfig.CellSize
	local halfX = GridConfig.Width * size.X / 2
	local halfZ = GridConfig.Length * size.Z / 2
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if character and root and root:IsA("BasePart") then
			local offset = root.Position - plot.Origin
			local inPit = math.abs(offset.X) <= halfX + 1 and math.abs(offset.Z) <= halfZ + 1
			if inPit and offset.Y < 3.5 then
				character:PivotTo(
					root.CFrame.Rotation
						+ Vector3.new(root.Position.X, plot.Origin.Y + 4, root.Position.Z)
				)
			end
		end
	end
end

local function clearGrid(plot: Plot)
	plot.RefillToken += 1
	plot.RefillPending = false
	plot.State = nil
	plot.CellsFolder:ClearAllChildren()
	plot.FossilsFolder:ClearAllChildren()
	table.clear(plot.CellParts)
	table.clear(plot.FossilParts)
	table.clear(plot.Dressed)
	plot.Model:SetAttribute("RefillAt", 0)
end

local function generate(plot: Plot)
	clearGrid(plot)
	liftCharactersOutOfPit(plot)

	local state = PlotGenerator.generate(function(): number
		return random:NextNumber()
	end)
	plot.State = state
	plot.Generation += 1

	for index, cell in state.Cells do
		buildCell(plot, index, cell)
	end
	-- Only the surface is exposed at the start.
	for index in state.Cells do
		if PlotRules.isExposed(state, index) then
			dressCell(plot, index)
		end
	end

	plot.Model:SetAttribute("FossilsTotal", #state.Fossils)
	plot.Model:SetAttribute("FossilsFound", 0)
	plot.Model:SetAttribute("Generation", plot.Generation)
end

local function spawnCFrame(plot: Plot): CFrame
	return plot.Spawn.CFrame + Vector3.new(0, 4, 0)
end

local function onCharacterAdded(player: Player, character: Model)
	local plot = plotByPlayer[player]
	local humanoid = character:WaitForChild("Humanoid", 10)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if
		humanoid == nil
		or root == nil
		or not humanoid:IsA("Humanoid")
		or not root:IsA("BasePart")
	then
		return
	end
	humanoid.UseJumpPower = false
	humanoid.JumpHeight = WorldConfig.Character.JumpHeight

	-- RespawnLocation normally puts the character on its own pad. This is the
	-- safety net for a character that loaded before the plot was assigned.
	if plot and plot.Owner == player then
		local padDistance = (root.Position - plot.Spawn.Position).Magnitude
		if padDistance > 30 then
			character:PivotTo(spawnCFrame(plot))
		end
	end
end

local function assign(player: Player)
	if plotByPlayer[player] then
		return
	end
	local free: Plot? = nil
	for _, plot in plots do
		if plot.Owner == nil then
			free = plot
			break
		end
	end
	if free == nil then
		warn(`[PlotService] No free plot for {player.Name}. Raise WorldConfig.MaxPlots.`)
		return
	end

	free.Owner = player
	plotByPlayer[player] = free
	free.Cover.Parent = nil
	-- With instance streaming on, keep the owner's own plot loaded at all
	-- times. This is only an optimisation, so a failure must not stop the
	-- player getting their plot.
	local model = free.Model
	pcall(function()
		model:AddPersistentPlayer(player)
	end)
	model:SetAttribute("OwnerUserId", player.UserId)
	generate(free)

	-- Taps and clicks dig, so they must never also walk the character.
	player.DevTouchMovementMode = Enum.DevTouchMovementMode.DynamicThumbstick
	player.DevComputerMovementMode = Enum.DevComputerMovementMode.KeyboardMouse

	player.RespawnLocation = free.Spawn
	player:SetAttribute("PlotName", free.Model.Name)

	player.CharacterAdded:Connect(function(character: Model)
		onCharacterAdded(player, character)
	end)
	local character = player.Character
	if character then
		task.spawn(onCharacterAdded, player, character)
	end
end

local function release(player: Player)
	local plot = plotByPlayer[player]
	if plot == nil then
		return
	end
	plotByPlayer[player] = nil
	plot.Owner = nil
	plot.RefillHeld = false
	clearGrid(plot)
	plot.Cover.Parent = plot.Model:FindFirstChild("Ground")
	local model = plot.Model
	pcall(function()
		model:RemovePersistentPlayer(player)
	end)
	model:SetAttribute("OwnerUserId", 0)
	model:SetAttribute("FossilsTotal", 0)
	model:SetAttribute("FossilsFound", 0)
end

-- Public API ---------------------------------------------------------------

function PlotService.GetPlot(player: Player): Plot?
	return plotByPlayer[player]
end

function PlotService.GetCellCenter(plot: Plot, index: number): Vector3
	return DigRules.cellCenter(plot.Origin, index)
end

-- A cell took damage but is still standing.
function PlotService.SetCellHealth(plot: Plot, index: number, health: number)
	local part = plot.CellParts[index]
	if part then
		part:SetAttribute("Health", health)
	end
end

-- A cell broke: remove its part and show the hints of the cells this exposes.
function PlotService.RemoveCell(plot: Plot, index: number)
	local part = plot.CellParts[index]
	if part then
		plot.CellParts[index] = nil
		part:Destroy()
	end
	for _, neighbor in GridMath.neighbors(DigRules.Dims, index) do
		dressCell(plot, neighbor)
	end
end

-- Refills and reseeds the plot right now.
function PlotService.Regenerate(plot: Plot)
	if plot.Owner == nil then
		return
	end
	generate(plot)
end

-- Refills and reseeds the plot after `delay` seconds (GridConfig.RefillDelay
-- by default). If the refill is held when it comes due, it waits for the release.
function PlotService.ScheduleRefill(plot: Plot, delay: number?)
	plot.RefillToken += 1
	local token = plot.RefillToken
	local seconds = delay or GridConfig.RefillDelay
	plot.Model:SetAttribute("RefillAt", Workspace:GetServerTimeNow() + seconds)
	task.delay(seconds, function()
		if plot.RefillToken ~= token or plot.Owner == nil then
			return
		end
		if plot.RefillHeld then
			plot.RefillPending = true
			plot.Model:SetAttribute("RefillAt", 0)
		else
			generate(plot)
		end
	end)
end

-- While held, a refill that comes due waits instead of running, so the ground
-- never refills under a fossil the player is still extracting. On release, a
-- waiting refill runs GridConfig.RefillDelayAfterExtraction seconds later.
function PlotService.SetRefillHeld(plot: Plot, held: boolean)
	plot.RefillHeld = held
	if not held and plot.RefillPending then
		plot.RefillPending = false
		PlotService.ScheduleRefill(plot, GridConfig.RefillDelayAfterExtraction)
	end
end

function PlotService.Init()
	for _, build in WorldBuilder.build() do
		table.insert(plots, {
			Id = build.Id,
			Model = build.Model,
			Origin = build.Origin,
			CellsFolder = build.CellsFolder,
			FossilsFolder = build.FossilsFolder,
			Cover = build.Cover,
			Spawn = build.Spawn,
			Owner = nil,
			State = nil,
			CellParts = {},
			FossilParts = {},
			Dressed = {},
			Generation = 0,
			RefillToken = 0,
			RefillHeld = false,
			RefillPending = false,
		})
	end
end

function PlotService.Start()
	Players.PlayerAdded:Connect(assign)
	Players.PlayerRemoving:Connect(release)
	for _, player in Players:GetPlayers() do
		task.spawn(assign, player)
	end
end

return PlotService
