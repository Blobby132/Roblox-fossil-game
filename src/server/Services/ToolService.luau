--!strict
--[[
	ToolService: gives players their digging tools and tracks which one each
	player is holding.

	The server is the authority on the equipped tool. The client asks with
	EquipRequest; the server checks the request and does the equipping, and
	DigService reads GetEquipped() when it rules on a swing.

	Tools are built from greybox parts described in ToolConfig. They are real
	Roblox Tool objects so the character holds and swings them with Roblox's
	built-in animations, but the default hotbar is replaced by our own buttons
	(see ToolController on the client).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local DigConfig = require(Shared.Config.DigConfig)
local Remotes = require(Shared.Remotes)
local ToolConfig = require(Shared.Config.ToolConfig)

local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)

local ToolService = {}

-- The tool each player asked to hold. GetEquipped() checks it is really in hand.
local wantedId: { [Player]: string } = {}
local toolsByPlayer: { [Player]: { [string]: Tool } } = {}
local limiter = RateLimiter.new(DigConfig.MaxRequestsPerSecond, DigConfig.RequestBurst)

local function buildTool(toolId: string): Tool
	local def = ToolConfig.Tools[toolId]
	local tool = Instance.new("Tool")
	tool.Name = def.DisplayName
	tool.CanBeDropped = false
	tool.ManualActivationOnly = true -- our own input code decides when a swing happens
	tool.RequiresHandle = true
	tool.Grip = def.Grip
	tool:SetAttribute("ToolId", toolId)

	local handle: Part? = nil
	for index, partDef in def.Parts do
		local part = Instance.new("Part")
		part.Name = if index == 1 then "Handle" else partDef.Name
		part.Size = partDef.Size
		part.Color = partDef.Color
		part.Material = Enum.Material.SmoothPlastic
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Massless = true
		part.CFrame = partDef.Offset
		if handle then
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = handle
			weld.Part1 = part
			weld.Parent = part
		else
			handle = part
		end
		part.Parent = tool
	end
	return tool
end

-- The player's tool of this kind, rebuilt if it was destroyed (for example
-- when the character died).
local function getTool(player: Player, toolId: string): Tool
	local tools = toolsByPlayer[player]
	if tools == nil then
		tools = {}
		toolsByPlayer[player] = tools
	end
	local tool = tools[toolId]
	if tool == nil or tool.Parent == nil then
		tool = buildTool(toolId)
		tools[toolId] = tool
	end
	return tool
end

-- Puts the player's wanted tool in their hand, if they have a living character.
local function equip(player: Player)
	local toolId = wantedId[player] or ToolConfig.DefaultTool
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if character == nil or humanoid == nil or humanoid.Health <= 0 then
		return
	end
	if not character:IsDescendantOf(Workspace) then
		return
	end
	-- EquipTool also puts whatever was held before back in the Backpack.
	humanoid:EquipTool(getTool(player, toolId))
	player:SetAttribute("EquippedTool", toolId)
end

local function onCharacterAdded(player: Player, character: Model)
	local humanoid = character:WaitForChild("Humanoid", 10)
	if humanoid == nil then
		return
	end
	-- A tool can only be held once the character is in the world.
	local deadline = os.clock() + 10
	while not character:IsDescendantOf(Workspace) do
		if os.clock() > deadline or player.Character ~= character then
			return
		end
		task.wait()
	end
	equip(player)
end

local function onPlayerAdded(player: Player)
	wantedId[player] = ToolConfig.DefaultTool
	player:SetAttribute("EquippedTool", ToolConfig.DefaultTool)
	player.CharacterAdded:Connect(function(character: Model)
		onCharacterAdded(player, character)
	end)
	local character = player.Character
	if character then
		task.spawn(onCharacterAdded, player, character)
	end
end

local function onPlayerRemoving(player: Player)
	wantedId[player] = nil
	toolsByPlayer[player] = nil
	limiter:forget(player)
end

-- Client -> server. Every argument is untrusted.
local function onEquipRequest(player: Player, toolId: any)
	if typeof(toolId) ~= "string" or ToolConfig.Tools[toolId] == nil then
		return
	end
	if not limiter:allow(player) then
		return
	end
	wantedId[player] = toolId
	equip(player)
end

local function isHolding(player: Player, toolId: string): boolean
	local tools = toolsByPlayer[player]
	local character = player.Character
	local tool = tools and tools[toolId]
	return character ~= nil and tool ~= nil and tool.Parent == character
end

-- The id of the tool the player is really holding right now, or nil.
-- If their chosen tool has slipped out of their hand (it was unequipped some
-- other way), the server puts it back first.
function ToolService.GetEquipped(player: Player): string?
	local toolId = wantedId[player]
	if toolId == nil then
		return nil
	end
	if not isHolding(player, toolId) then
		equip(player)
	end
	return if isHolding(player, toolId) then toolId else nil
end

function ToolService.Start()
	Remotes.get("EquipRequest").OnServerEvent:Connect(onEquipRequest)
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
end

return ToolService
