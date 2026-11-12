--!strict
--[[
	DebugService: developer-only shortcuts for playtesting.

	The client can ask, but the server decides who is allowed: anyone while
	playing inside Roblox Studio (if DebugConfig.AllowInStudio), plus the
	UserIds in DebugConfig.DeveloperUserIds. Requests from anyone else are
	ignored, so these are safe to leave in a published game.

	Actions:
	  Reseed       refill and reseed the player's own plot right now
	  ShowFossils  send the player the cells that still hide a fossil
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local DebugConfig = require(Shared.Config.DebugConfig)
local Remotes = require(Shared.Remotes)

local FossilService = require(script.Parent.FossilService)
local PlotService = require(script.Parent.PlotService)
local RateLimiter = require(script.Parent.Parent.Util.RateLimiter)

local DebugService = {}

local limiter = RateLimiter.new(2, 4)

function DebugService.IsAllowed(player: Player): boolean
	if not DebugConfig.Enabled then
		return false
	end
	if DebugConfig.AllowInStudio and RunService:IsStudio() then
		return true
	end
	return table.find(DebugConfig.DeveloperUserIds, player.UserId) ~= nil
end

-- Client -> server. Every argument is untrusted.
local function onDebugRequest(player: Player, action: any)
	if typeof(action) ~= "string" then
		return
	end
	if not DebugService.IsAllowed(player) or not limiter:allow(player) then
		return
	end
	local plot = PlotService.GetPlot(player)
	if plot == nil then
		return
	end

	if action == "Reseed" then
		PlotService.Regenerate(plot)
	elseif action == "ShowFossils" then
		Remotes.get("DebugFossils"):FireClient(player, FossilService.GetHiddenCells(plot))
	end
end

function DebugService.Start()
	Remotes.get("DebugRequest").OnServerEvent:Connect(onDebugRequest)
end

return DebugService
