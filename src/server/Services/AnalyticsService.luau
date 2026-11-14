--!strict
--[[
	AnalyticsService: a small, safe wrapper around Roblox's AnalyticsService.

	Game code calls this module, never the engine service directly, so:
	  * a failing or unavailable analytics call can never break gameplay
	    (every engine call is wrapped in pcall)
	  * nothing is sent from Studio unless AnalyticsConfig.SendInStudio is on;
	    events are printed to the Output instead
	  * each onboarding step is logged at most once per player per session

	Onboarding steps are listed in AnalyticsConfig.OnboardingSteps.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local AnalyticsConfig = require(ReplicatedStorage.Shared.Config.AnalyticsConfig)

local AnalyticsService = {}

-- Steps logged so far for each player, in the order they were logged.
local logged: { [Player]: { string } } = {}

local function engine(): any
	local ok, service = pcall(function()
		return game:GetService("AnalyticsService")
	end)
	return if ok then service else nil
end

local function stepNumber(stepName: string): number?
	return table.find(AnalyticsConfig.OnboardingSteps, stepName)
end

-- Sends one call to the engine, or prints it in Studio. Never throws.
local function send(description: string, call: (service: any) -> ())
	if RunService:IsStudio() and not AnalyticsConfig.SendInStudio then
		if AnalyticsConfig.PrintInStudio then
			print(`[Analytics] {description}`)
		end
		return
	end
	local service = engine()
	if service == nil then
		return
	end
	local ok, err = pcall(call, service)
	if not ok then
		warn(`[Analytics] {description} failed: {err}`)
	end
end

-- Logs an onboarding funnel step (a name from AnalyticsConfig.OnboardingSteps)
-- the first time this player reaches it. Later calls do nothing.
function AnalyticsService.LogOnboardingStep(player: Player, stepName: string)
	local step = stepNumber(stepName)
	if step == nil then
		warn(`[Analytics] Unknown onboarding step "{stepName}"`)
		return
	end
	local history = logged[player]
	if history == nil then
		history = {}
		logged[player] = history
	end
	if table.find(history, stepName) then
		return
	end
	table.insert(history, stepName)
	send(`{player.Name} onboarding step {step} {stepName}`, function(service: any)
		service:LogOnboardingFunnelStepEvent(player, step, stepName)
	end)
end

-- The steps this player has reached, in order (a copy).
function AnalyticsService.GetLoggedSteps(player: Player): { string }
	local history = logged[player]
	return if history then table.clone(history) else {}
end

function AnalyticsService.Start()
	local function onPlayerAdded(player: Player)
		AnalyticsService.LogOnboardingStep(player, "Joined")
	end
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(function(player: Player)
		logged[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
end

return AnalyticsService
