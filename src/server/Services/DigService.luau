--!strict
--[[
	DigService: rules on every swing.

	The client only ever says "I swung at cell N of my plot". It never says
	which tool, how much damage, or what was found. For each request the server
	checks, in order:

	  1. the request is well formed (right types, a real cell number)
	  2. the player is not flooding the remote
	  3. the player has a plot and is not in the middle of an extraction
	  4. the player has a living character and a tool in hand
	  5. the tool's cooldown has passed
	  6. the character is close enough to the cell
	  7. the cell can be hit: it exists, is exposed, and the tool affects it

	Only then does it change the plot, and it always answers with SwingResult
	so the client can correct its prediction. The swing that uncovers a
	fossil also starts its extraction (ExtractionService).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local DigConfig = require(Shared.Config.DigConfig)
local DigRules = require(Shared.Dig.DigRules)
local GridMath = require(Shared.Dig.GridMath)
local Remotes = require(Shared.Remotes)
local ToolConfig = require(Shared.Config.ToolConfig)

local Server = script.Parent.Parent
local AnalyticsService = require(script.Parent.AnalyticsService)
local ExtractionService = require(script.Parent.ExtractionService)
local FossilService = require(script.Parent.FossilService)
local PlotRules = require(Server.Dig.PlotRules)
local PlotService = require(script.Parent.PlotService)
local RateLimiter = require(Server.Util.RateLimiter)
local ToolService = require(script.Parent.ToolService)

local DigService = {}

local limiter = RateLimiter.new(DigConfig.MaxRequestsPerSecond, DigConfig.RequestBurst)

-- The earliest time each player's next swing is due.
local nextSwingAt: { [Player]: number } = {}

-- Decides one swing. Returns ok, code, value, defId (see Remotes), and the
-- index of the fossil this swing uncovered, if it uncovered one.
local function resolve(
	player: Player,
	cellIndex: number
): (boolean, string, number, string?, number?)
	local plot = PlotService.GetPlot(player)
	local state = plot and plot.State
	if plot == nil or state == nil then
		return false, "NoPlot", 0, nil, nil
	end
	if ExtractionService.IsActive(player) then
		return false, "Extracting", 0, nil, nil
	end

	local toolId = ToolService.GetEquipped(player)
	local tool = toolId and ToolConfig.Tools[toolId]
	if toolId == nil or tool == nil then
		return false, "NoTool", 0, nil, nil
	end

	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid == nil or humanoid.Health <= 0 or root == nil or not root:IsA("BasePart") then
		return false, "NoCharacter", 0, nil, nil
	end

	-- Cooldown. A swing may arrive a little early (network jitter), but each
	-- accepted swing pushes the next one a full cooldown later, so over time
	-- nobody swings faster than the tool allows.
	local now = os.clock()
	local dueAt = nextSwingAt[player] or 0
	if now < dueAt - DigConfig.CooldownTolerance then
		return false, "Cooldown", 0, nil, nil
	end

	-- Reach, measured by the server from where it sees the character.
	local cellCenter = PlotService.GetCellCenter(plot, cellIndex)
	local distance = DigRules.distanceToCell(root.Position, cellCenter)
	if distance > tool.Range + DigConfig.RangeTolerance then
		return false, "TooFar", 0, nil, nil
	end

	local outcome = PlotRules.resolveSwing(state, cellIndex, toolId)
	if outcome.Ok or outcome.Code == "WrongTool" then
		-- A swing was spent, whether or not it did anything.
		nextSwingAt[player] = math.max(now, dueAt) + tool.Cooldown
	end

	local defId: string? = nil
	local uncovered: number? = nil
	if outcome.Code == "Hit" then
		PlotService.SetCellHealth(plot, cellIndex, outcome.Value)
	elseif outcome.Code == "Break" then
		PlotService.RemoveCell(plot, cellIndex)
		if outcome.FossilIndex then
			FossilService.Expose(plot, outcome.FossilIndex)
		end
	elseif outcome.Code == "Clean" and outcome.FossilIndex then
		FossilService.SetClean(plot, outcome.FossilIndex, outcome.Value)
	elseif outcome.Code == "Reveal" and outcome.FossilIndex then
		defId = FossilService.Reveal(plot, outcome.FossilIndex)
		uncovered = outcome.FossilIndex
	end

	if outcome.Ok then
		AnalyticsService.LogOnboardingStep(player, "FirstSwing")
	end
	if uncovered then
		AnalyticsService.LogOnboardingStep(player, "FirstFossilUncovered")
	end
	return outcome.Ok, outcome.Code, outcome.Value, defId, uncovered
end

-- Client -> server. Every argument is untrusted.
local function onSwingRequest(player: Player, seq: any, cellIndex: any)
	if typeof(seq) ~= "number" or typeof(cellIndex) ~= "number" then
		return
	end
	if seq ~= seq or seq % 1 ~= 0 then
		return
	end
	if not GridMath.isValidIndex(DigRules.Dims, cellIndex) then
		return
	end
	if not limiter:allow(player) then
		return
	end

	local ok, code, value, defId, uncovered = resolve(player, cellIndex)
	Remotes.get("SwingResult"):FireClient(player, seq, ok, code, value, defId)

	-- Answer the swing first, so the client confirms the reveal before the
	-- extraction arrives.
	local plot = PlotService.GetPlot(player)
	if uncovered and plot then
		ExtractionService.Begin(player, plot, uncovered)
	end
end

function DigService.Start()
	Remotes.get("SwingRequest").OnServerEvent:Connect(onSwingRequest)
	Players.PlayerRemoving:Connect(function(player: Player)
		nextSwingAt[player] = nil
		limiter:forget(player)
	end)
end

return DigService
