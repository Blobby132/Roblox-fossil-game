--!strict
--[[
	Server entry point. This is the only Script on the server; everything else
	is a ModuleScript that this file loads.

	Each service may have:
	  Init()   set itself up; must not rely on other services being ready
	  Start()  connect events and begin work; every service has been Init'd
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

-- Create every RemoteEvent before any service asks for one.
Remotes.createAll()

local Services = script.Parent.Services
local AnalyticsService = require(Services.AnalyticsService)
local DataService = require(Services.DataService)
local DebugService = require(Services.DebugService)
local DigService = require(Services.DigService)
local ExtractionService = require(Services.ExtractionService)
local FossilService = require(Services.FossilService)
local InventoryService = require(Services.InventoryService)
local PlotService = require(Services.PlotService)
local ToolService = require(Services.ToolService)

-- DataService starts first, so a joining player's data exists before any
-- other service handles them. Later milestones add MuseumService and
-- EconomyService here.
local services: { any } = {
	DataService,
	AnalyticsService,
	PlotService,
	FossilService,
	ToolService,
	InventoryService,
	ExtractionService,
	DigService,
	DebugService,
}

for _, service in services do
	if service.Init then
		service.Init()
	end
end

for _, service in services do
	if service.Start then
		service.Start()
	end
end
