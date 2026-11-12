--!strict
--[[
	HudController: the placeholder heads-up display for Milestone 1.

	  * "Fossils 2 / 5": how many of this plot's fossils have been uncovered
	  * a countdown once the plot is complete and about to refill

	The proper interface (money, inventory, upgrades, pop-in tweens) arrives in
	Milestone 5. This already follows the UI rules in Ui.luau so it scales on
	phones.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local GridConfig = require(ReplicatedStorage.Shared.Config.GridConfig)

local Client = script.Parent.Parent
local EffectsController = require(script.Parent.EffectsController)
local PlotController = require(script.Parent.PlotController)
local Ui = require(Client.Ui.Ui)

local HudController = {}

local counterLabel: TextLabel? = nil
local statusLabel: TextLabel? = nil

local function numberAttribute(instance: Instance, name: string): number
	local value = instance:GetAttribute(name)
	return if typeof(value) == "number" then value else 0
end

local function build()
	local hud = Ui.getHud()

	local counter = Ui.create("TextLabel", {
		Name = "Counter",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "",
		TextScaled = true,
		Font = Enum.Font.GothamBold,
		TextColor3 = Color3.fromRGB(250, 246, 235),
	}) :: TextLabel
	counterLabel = counter

	local panel = Ui.create("Frame", {
		Name = "FossilCounter",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.02),
		Size = UDim2.fromScale(0.34, 0.07),
		BackgroundColor3 = Color3.fromRGB(46, 46, 52),
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
	}, {
		Ui.create("UIAspectRatioConstraint", {
			AspectRatio = 4.6,
			AspectType = Enum.AspectType.FitWithinMaxSize,
			DominantAxis = Enum.DominantAxis.Height,
		}),
		Ui.create("UISizeConstraint", { MaxSize = Vector2.new(260, 56) }),
		Ui.create("UICorner", { CornerRadius = UDim.new(0.3, 0) }),
		Ui.create("UIPadding", {
			PaddingTop = UDim.new(0.16, 0),
			PaddingBottom = UDim.new(0.16, 0),
			PaddingLeft = UDim.new(0.06, 0),
			PaddingRight = UDim.new(0.06, 0),
		}),
		counter,
	}) :: Frame
	panel.Parent = hud

	local status = Ui.create("TextLabel", {
		Name = "Status",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.11),
		Size = UDim2.fromScale(0.7, 0.06),
		BackgroundTransparency = 1,
		Text = "",
		TextScaled = true,
		Font = Enum.Font.GothamBold,
		TextColor3 = Color3.fromRGB(255, 225, 120),
		TextStrokeTransparency = 0.4,
		Visible = false,
	}, {
		Ui.create("UIAspectRatioConstraint", {
			AspectRatio = 12,
			AspectType = Enum.AspectType.FitWithinMaxSize,
			DominantAxis = Enum.DominantAxis.Height,
		}),
		Ui.create("UISizeConstraint", { MaxSize = Vector2.new(560, 46) }),
	}) :: TextLabel
	status.Parent = hud
	statusLabel = status
end

local function refresh()
	local plot = PlotController.getPlot()
	local counter = counterLabel
	local status = statusLabel
	if plot == nil or counter == nil or status == nil then
		return
	end

	local found = numberAttribute(plot, "FossilsFound")
	local total = numberAttribute(plot, "FossilsTotal")
	counter.Text = `Fossils {found} / {total}`

	local refillAt = numberAttribute(plot, "RefillAt")
	local remaining = refillAt - Workspace:GetServerTimeNow()
	if refillAt > 0 and remaining > 0 then
		status.Text = `All found! New dig site in {math.ceil(remaining)}...`
		status.Visible = true
	else
		status.Visible = false
	end
end

local function onPlotReady(plot: Model)
	plot:GetAttributeChangedSignal("FossilsFound"):Connect(refresh)
	plot:GetAttributeChangedSignal("FossilsTotal"):Connect(refresh)
	plot:GetAttributeChangedSignal("RefillAt"):Connect(refresh)
	refresh()
end

local function onRegenerated()
	local origin = PlotController.getOrigin()
	if origin then
		local depth = GridConfig.Layers * GridConfig.CellSize.Y
		EffectsController.plotRefilled(origin - Vector3.new(0, depth / 2, 0))
	end
	refresh()
end

function HudController.Start()
	build()
	PlotController.Ready:Connect(onPlotReady)
	PlotController.Regenerated:Connect(onRegenerated)

	-- Keeps the refill countdown ticking.
	task.spawn(function()
		while true do
			task.wait(0.25)
			refresh()
		end
	end)
end

return HudController
