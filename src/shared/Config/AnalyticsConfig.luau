--!strict
--[[
	AnalyticsConfig: what AnalyticsService (the server-side wrapper) reports
	to Roblox's analytics.

	The onboarding funnel shows in the Creator Dashboard under Analytics ->
	Funnels once the game is published and has players. Each step is logged at
	most once per player per session, in the order listed here; Roblox numbers
	them 1, 2, 3...

	Milestone 5 extends this into the full funnel.
]]

local AnalyticsConfig = {
	-- Onboarding funnel steps, in order. The names are what the dashboard shows.
	-- "Joined" is the baseline the other steps are measured against.
	OnboardingSteps = {
		"Joined",
		"FirstSwing",
		"FirstFossilUncovered",
		"FirstExtraction",
	},

	-- In Studio, events are not sent to Roblox (they would mix test sessions
	-- into real data). Set to true only to test the real calls.
	SendInStudio = false,

	-- In Studio, print each event to the Output window instead.
	PrintInStudio = true,
}

return AnalyticsConfig
