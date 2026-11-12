--!strict
--[[
	ToolController: which tool this player is holding, and the buttons to
	switch between them.

	Switching feels instant: the button and the dig prediction change at once,
	and the request goes to the server, which does the real equipping (see
	ToolService). The server stays the authority on what a swing does.

	Controls: tap a tool button, press its number key (1, 2), or press Q to
	swap to the next tool.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage.Shared
local Remotes = require(Shared.Remotes)
local Signal = require(Shared.Util.Signal)
local ToolConfig = require(Shared.Config.ToolConfig)

local Client = script.Parent.Parent
local SoundPlayer = require(Client.Effects.SoundPlayer)
local Ui = require(Client.Ui.Ui)

local SLOT_KEYS = {
	Enum.KeyCode.One,
	Enum.KeyCode.Two,
	Enum.KeyCode.Three,
	Enum.KeyCode.Four,
}
local NEXT_TOOL_KEY = Enum.KeyCode.Q

local SELECTED_COLOR = Color3.fromRGB(250, 246, 235)
local IDLE_COLOR = Color3.fromRGB(46, 46, 52)
local SELECTED_STROKE = Color3.fromRGB(255, 205, 70)
local IDLE_STROKE = Color3.fromRGB(20, 20, 24)
local WOOD = Color3.fromRGB(150, 104, 62)

type ToolButton = {
	Button: TextButton,
	Stroke: UIStroke,
	Scale: UIScale,
	Label: TextLabel,
}

local ToolController = {}

ToolController.Changed = Signal.new() -- (toolId: string)

local player = Players.LocalPlayer
local equipped: string = ToolConfig.DefaultTool
local toolIds: { string } = {} -- in hotbar order
local buttons: { [string]: ToolButton } = {}
local popInfo = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local nudgeInfo = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- Greybox pictograms made of plain frames, so no image assets are needed.
local function bar(position: UDim2, size: UDim2, rotation: number, color: Color3): Frame
	return Ui.create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = position,
		Size = size,
		Rotation = rotation,
		BackgroundColor3 = color,
		BorderSizePixel = 0,
	}, {
		Ui.create("UICorner", { CornerRadius = UDim.new(0.3, 0) }),
	})
end

local function buildIcon(toolId: string): { Instance }
	if toolId == "Pickaxe" then
		return {
			bar(UDim2.fromScale(0.46, 0.58), UDim2.fromScale(0.13, 0.78), 45, WOOD),
			bar(
				UDim2.fromScale(0.72, 0.31),
				UDim2.fromScale(0.14, 0.7),
				-45,
				Color3.fromRGB(110, 116, 128)
			),
		}
	elseif toolId == "Brush" then
		return {
			bar(UDim2.fromScale(0.4, 0.64), UDim2.fromScale(0.14, 0.56), 45, WOOD),
			bar(
				UDim2.fromScale(0.68, 0.36),
				UDim2.fromScale(0.34, 0.36),
				45,
				Color3.fromRGB(236, 214, 150)
			),
		}
	end
	return {}
end

local function refresh()
	for toolId, entry in buttons do
		local selected = toolId == equipped
		entry.Button.BackgroundColor3 = if selected then SELECTED_COLOR else IDLE_COLOR
		entry.Button.BackgroundTransparency = if selected then 0 else 0.25
		entry.Stroke.Color = if selected then SELECTED_STROKE else IDLE_STROKE
		entry.Label.TextColor3 = if selected then IDLE_COLOR else SELECTED_COLOR
		TweenService:Create(entry.Scale, popInfo, { Scale = if selected then 1.08 else 0.94 })
			:Play()
	end
end

local function buildToolBar()
	local count = #toolIds
	local toolBar = Ui.create("Frame", {
		Name = "ToolBar",
		-- Bottom centre: clear of the thumbstick (bottom left) and the jump
		-- button (bottom right) on phones.
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, 0.97),
		Size = UDim2.fromScale(0.5, 0.17),
		BackgroundTransparency = 1,
	}, {
		Ui.create("UIAspectRatioConstraint", {
			AspectRatio = count * 1.1,
			AspectType = Enum.AspectType.FitWithinMaxSize,
			DominantAxis = Enum.DominantAxis.Height,
		}),
		-- Stops the buttons becoming huge on desktop monitors.
		Ui.create("UISizeConstraint", { MaxSize = Vector2.new(count * 116, 106) }),
		Ui.create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0.06 / count, 0),
		}),
	}) :: Frame

	for slot, toolId in toolIds do
		local def = ToolConfig.Tools[toolId]
		local stroke = Ui.create("UIStroke", {
			Thickness = 3,
			ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
		}) :: UIStroke
		local scale = Ui.create("UIScale", { Scale = 1 }) :: UIScale
		local label = Ui.create("TextLabel", {
			Name = "ToolName",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.fromScale(0.5, 0.96),
			Size = UDim2.fromScale(0.9, 0.24),
			BackgroundTransparency = 1,
			Text = def.DisplayName,
			TextScaled = true,
			Font = Enum.Font.GothamBold,
		}) :: TextLabel
		local icon = Ui.create("Frame", {
			Name = "Icon",
			AnchorPoint = Vector2.new(0.5, 0),
			Position = UDim2.fromScale(0.5, 0.06),
			Size = UDim2.fromScale(0.66, 0.66),
			BackgroundTransparency = 1,
		}, buildIcon(toolId)) :: Frame

		local children: { Instance } = {
			Ui.create("UIAspectRatioConstraint", { AspectRatio = 1 }),
			Ui.create("UICorner", { CornerRadius = UDim.new(0.18, 0) }),
			stroke,
			scale,
			icon,
			label,
		}
		-- Number-key hint, only where there is a keyboard.
		if UserInputService.KeyboardEnabled then
			table.insert(
				children,
				Ui.create("TextLabel", {
					Name = "Key",
					Position = UDim2.fromScale(0.07, 0.05),
					Size = UDim2.fromScale(0.2, 0.2),
					BackgroundTransparency = 1,
					Text = tostring(slot),
					TextScaled = true,
					Font = Enum.Font.GothamBold,
					TextColor3 = Color3.fromRGB(150, 150, 150),
				})
			)
		end

		local button = Ui.create("TextButton", {
			Name = toolId,
			LayoutOrder = slot,
			Size = UDim2.fromScale(0.94 / count, 1),
			Text = "",
			AutoButtonColor = false,
			BorderSizePixel = 0,
		}, children) :: TextButton
		button.Activated:Connect(function()
			ToolController.equip(toolId)
		end)
		button.Parent = toolBar

		buttons[toolId] = { Button = button, Stroke = stroke, Scale = scale, Label = label }
	end

	toolBar.Parent = Ui.getHud()
	refresh()
end

-- Our own buttons replace Roblox's default tool hotbar.
local function hideDefaultHotbar()
	task.spawn(function()
		for _ = 1, 20 do
			local ok = pcall(function()
				StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
			end)
			if ok then
				return
			end
			task.wait(0.5)
		end
	end)
end

local function onInputBegan(input: InputObject, processedByUi: boolean)
	if processedByUi or input.UserInputType ~= Enum.UserInputType.Keyboard then
		return
	end
	if input.KeyCode == NEXT_TOOL_KEY then
		local current = table.find(toolIds, equipped) or 1
		ToolController.equip(toolIds[current % #toolIds + 1])
		return
	end
	local slot = table.find(SLOT_KEYS, input.KeyCode)
	if slot and toolIds[slot] then
		ToolController.equip(toolIds[slot])
	end
end

-- Public API ---------------------------------------------------------------

-- The tool this player has chosen. Used to predict what a swing will do.
function ToolController.getEquipped(): string
	return equipped
end

function ToolController.equip(toolId: string)
	if toolId == equipped or ToolConfig.Tools[toolId] == nil then
		return
	end
	equipped = toolId
	Remotes.get("EquipRequest"):FireServer(toolId)
	SoundPlayer.play("ToolSwitch")
	refresh()
	ToolController.Changed:Fire(toolId)
end

-- Pulses a tool's button to suggest switching to it. Used when the tool in
-- hand cannot affect what was hit, so players learn the tools without text.
function ToolController.nudge(toolId: string)
	local entry = buttons[toolId]
	if entry == nil or toolId == equipped then
		return
	end
	entry.Scale.Scale = 1.3
	entry.Stroke.Color = SELECTED_STROKE
	TweenService:Create(entry.Scale, nudgeInfo, { Scale = 0.94 }):Play()
	TweenService:Create(entry.Stroke, nudgeInfo, { Color = IDLE_STROKE }):Play()
end

-- Plays Roblox's built-in tool swing on the character. The default Animate
-- script watches the held Tool for a StringValue named "toolanim".
function ToolController.playSwing()
	local character = player.Character
	local tool = character and character:FindFirstChildOfClass("Tool")
	if tool then
		local request = Instance.new("StringValue")
		request.Name = "toolanim"
		request.Value = "Slash"
		request.Parent = tool
	end
end

function ToolController.Init()
	for toolId in ToolConfig.Tools do
		table.insert(toolIds, toolId)
	end
	table.sort(toolIds, function(a: string, b: string): boolean
		return ToolConfig.Tools[a].Slot < ToolConfig.Tools[b].Slot
	end)

	local fromServer = player:GetAttribute("EquippedTool")
	if typeof(fromServer) == "string" and ToolConfig.Tools[fromServer] then
		equipped = fromServer
	end
end

function ToolController.Start()
	hideDefaultHotbar()
	buildToolBar()
	UserInputService.InputBegan:Connect(onInputBegan)
end

return ToolController
