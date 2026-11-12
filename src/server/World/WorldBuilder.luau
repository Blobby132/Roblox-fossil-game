--!strict
--[[
	WorldBuilder: builds the greybox dig site out of plain parts at startup.

	Nothing here is hand-placed in Studio and nothing comes from the Toolbox.
	Sizes come from WorldConfig and GridConfig, so changing the grid resizes
	the ground around it.

	One plot, seen from above (the player spawns facing the pit):

	        +--------------------------+
	        |        museum pad        |   back  (-Z)
	        |                          |
	        |      +------------+      |
	        |      |    pit     |      |
	        |      | (dig grid) |      |
	        |      +------------+      |
	        |        spawn pad         |   front (+Z)
	        +--------------------------+
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local GridConfig = require(Shared.Config.GridConfig)
local WorldConfig = require(Shared.Config.WorldConfig)

export type PlotBuild = {
	Id: number,
	Model: Model,
	Origin: Vector3, -- centre of the pit's top surface
	CellsFolder: Folder,
	FossilsFolder: Folder,
	Cover: Part, -- fills the pit while the plot has no owner
	Spawn: SpawnLocation,
}

local WorldBuilder = {}

local function newFolder(name: string, parent: Instance): Folder
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function newBlock(
	name: string,
	size: Vector3,
	position: Vector3,
	color: Color3,
	parent: Instance
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.Position = position
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function buildMuseumPlaceholder(parent: Instance, origin: Vector3, pitHalfZ: number)
	local museum = WorldConfig.Museum
	local padCenterZ = -pitHalfZ - museum.Gap - museum.Size.Z / 2
	newBlock(
		"Pad",
		museum.Size,
		origin + Vector3.new(0, museum.Size.Y / 2, padCenterZ),
		museum.Color,
		parent
	)

	-- A sign at the back of the pad, facing the pit.
	local sign = newBlock(
		"Sign",
		Vector3.new(12, 5, 0.5),
		origin + Vector3.new(0, museum.Size.Y + 2.5, padCenterZ - museum.Size.Z / 2 + 0.5),
		museum.Color,
		parent
	)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Back -- the +Z face, which looks at the pit
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	gui.Parent = sign
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = museum.SignText
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.fromRGB(60, 56, 50)
	label.Parent = gui
end

local function buildPlot(id: number, origin: Vector3, parent: Instance): PlotBuild
	local colors = WorldConfig.Colors
	local cell = GridConfig.CellSize
	local pitX = GridConfig.Width * cell.X
	local pitZ = GridConfig.Length * cell.Z
	local depth = GridConfig.Layers * cell.Y
	local halfX = pitX / 2
	local halfZ = pitZ / 2
	local margin = WorldConfig.PlotMargin
	local thickness = depth + WorldConfig.BedrockThickness
	local museum = WorldConfig.Museum
	local backDepth = museum.Gap + museum.Size.Z + museum.BackMargin
	local tileX = pitX + margin * 2

	local model = Instance.new("Model")
	model.Name = `Plot_{id}`
	-- If instance streaming is on: the owner always has their whole plot
	-- loaded (PlotService adds them as a persistent player), and everyone
	-- else receives it in one piece, never half a grid.
	model.ModelStreamingMode = Enum.ModelStreamingMode.PersistentPerPlayer
	model:SetAttribute("Origin", origin)
	model:SetAttribute("OwnerUserId", 0)
	model:SetAttribute("Generation", 0)
	model:SetAttribute("FossilsTotal", 0)
	model:SetAttribute("FossilsFound", 0)
	model:SetAttribute("RefillAt", 0)

	-- The ground is four slabs around the pit, so the pit is a real hole.
	local ground = newFolder("Ground", model)
	local slabY = -thickness / 2
	newBlock(
		"RimFront",
		Vector3.new(tileX, thickness, margin),
		origin + Vector3.new(0, slabY, halfZ + margin / 2),
		colors.Ground,
		ground
	)
	newBlock(
		"RimBack",
		Vector3.new(tileX, thickness, backDepth),
		origin + Vector3.new(0, slabY, -halfZ - backDepth / 2),
		colors.Ground,
		ground
	)
	newBlock(
		"RimLeft",
		Vector3.new(margin, thickness, pitZ),
		origin + Vector3.new(-halfX - margin / 2, slabY, 0),
		colors.Ground,
		ground
	)
	newBlock(
		"RimRight",
		Vector3.new(margin, thickness, pitZ),
		origin + Vector3.new(halfX + margin / 2, slabY, 0),
		colors.Ground,
		ground
	)
	newBlock(
		"Bedrock",
		Vector3.new(pitX, WorldConfig.BedrockThickness, pitZ),
		origin + Vector3.new(0, -depth - WorldConfig.BedrockThickness / 2, 0),
		colors.Bedrock,
		ground
	)
	local cover = newBlock(
		"Cover",
		Vector3.new(pitX, depth, pitZ),
		origin + Vector3.new(0, -depth / 2, 0),
		colors.Cover,
		ground
	)

	-- The spawn pad sits in front of the pit. A character spawns facing the
	-- pad's front (-Z), which is towards the pit.
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "Spawn"
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Duration = 0 -- no spawn forcefield
	spawn.Size = WorldConfig.SpawnPadSize
	spawn.Position = origin
		+ Vector3.new(0, WorldConfig.SpawnPadSize.Y / 2, halfZ + WorldConfig.SpawnDistance)
	spawn.Color = colors.SpawnPad
	spawn.Material = Enum.Material.SmoothPlastic
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.Parent = model

	buildMuseumPlaceholder(newFolder("Museum", model), origin, halfZ)

	local cellsFolder = newFolder("Cells", model)
	local fossilsFolder = newFolder("Fossils", model)

	model.Parent = parent

	return {
		Id = id,
		Model = model,
		Origin = origin,
		CellsFolder = cellsFolder,
		FossilsFolder = fossilsFolder,
		Cover = cover,
		Spawn = spawn,
	}
end

-- Flat ground around the whole row of plots, so nobody walks off an edge.
local function buildSurroundings(parent: Instance, rowWidth: number, frontZ: number, backZ: number)
	local size = WorldConfig.SurroundSize
	local thickness = WorldConfig.SurroundThickness
	local y = WorldConfig.SurfaceY - thickness / 2
	local color = WorldConfig.Colors.Surround
	local rowDepth = frontZ - backZ
	local centerZ = (frontZ + backZ) / 2

	newBlock(
		"West",
		Vector3.new(size, thickness, rowDepth + size * 2),
		Vector3.new(-rowWidth / 2 - size / 2, y, centerZ),
		color,
		parent
	)
	newBlock(
		"East",
		Vector3.new(size, thickness, rowDepth + size * 2),
		Vector3.new(rowWidth / 2 + size / 2, y, centerZ),
		color,
		parent
	)
	newBlock(
		"Front",
		Vector3.new(rowWidth, thickness, size),
		Vector3.new(0, y, frontZ + size / 2),
		color,
		parent
	)
	newBlock(
		"Back",
		Vector3.new(rowWidth, thickness, size),
		Vector3.new(0, y, backZ - size / 2),
		color,
		parent
	)
end

local function applyLighting()
	local settings = WorldConfig.Lighting
	if not settings.Apply then
		return
	end
	Lighting.Ambient = settings.Ambient
	Lighting.OutdoorAmbient = settings.OutdoorAmbient
	Lighting.Brightness = settings.Brightness
	Lighting.ClockTime = settings.ClockTime
end

-- Builds the whole site and returns one record per plot.
function WorldBuilder.build(): { PlotBuild }
	local site = newFolder("DigSite", Workspace)

	local cell = GridConfig.CellSize
	local pitX = GridConfig.Width * cell.X
	local halfZ = GridConfig.Length * cell.Z / 2
	local museum = WorldConfig.Museum
	local tileX = pitX + WorldConfig.PlotMargin * 2
	local frontZ = halfZ + WorldConfig.PlotMargin
	local backZ = -halfZ - (museum.Gap + museum.Size.Z + museum.BackMargin)
	local count = WorldConfig.MaxPlots

	local plots: { PlotBuild } = {}
	for id = 1, count do
		local x = (id - (count + 1) / 2) * tileX
		plots[id] = buildPlot(id, Vector3.new(x, WorldConfig.SurfaceY, 0), site)
	end

	buildSurroundings(newFolder("Surroundings", site), count * tileX, frontZ, backZ)
	applyLighting()

	return plots
end

return WorldBuilder
