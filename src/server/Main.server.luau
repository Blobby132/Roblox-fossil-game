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
local DebugService = require(Services.DebugService)
local DigService = require(Services.DigService)
local FossilService = require(Services.FossilService)
local PlotService = require(Services.PlotService)
local ToolService = require(Services.ToolService)

-- Later milestones add MuseumService, EconomyService and DataService here.
local services: { any } = {
	PlotService,
	FossilService,
	ToolService,
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
