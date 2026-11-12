--!strict
--[[
	Client entry point. This is the only LocalScript; everything else is a
	ModuleScript that this file loads.

	Each controller may have:
	  Init()   set itself up; must not rely on other controllers being ready
	  Start()  connect events and begin work; every controller has been Init'd

	PlotController starts last on purpose: it announces the plot (Ready,
	FossilAdded...) as soon as it finds it, and every other controller must be
	listening by then.
]]

local Controllers = script.Parent.Controllers
local DebugController = require(Controllers.DebugController)
local DigController = require(Controllers.DigController)
local EffectsController = require(Controllers.EffectsController)
local FossilController = require(Controllers.FossilController)
local HudController = require(Controllers.HudController)
local PlotController = require(Controllers.PlotController)
local ToolController = require(Controllers.ToolController)

local controllers: { any } = {
	EffectsController,
	ToolController,
	FossilController,
	DigController,
	HudController,
	DebugController,
	PlotController,
}

for _, controller in controllers do
	if controller.Init then
		controller.Init()
	end
end

for _, controller in controllers do
	if controller.Start then
		controller.Start()
	end
end
