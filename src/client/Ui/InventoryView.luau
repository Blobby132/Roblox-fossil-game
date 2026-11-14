--!strict
--[[
	InventoryView: the inventory button on the HUD and the panel it opens.
	It only draws; InventoryController owns the data.

	  * InventoryButton  right edge, clear of the jump button and thumbstick;
	                     a badge shows how many finds there are
	  * InventoryPanel   centred: a title, progress for each fossil set
	                     ("Triceratops 1/3"), and a scrolling list of finds with
	                     name, rarity colour and condition

	Everything is sized with Scale and aspect-ratio constraints (Ui.luau rules).
	List rows get their height from an aspect ratio, so the list's automatic
	canvas size works without any pixel sizes.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage.Shared
local ExtractionMath = require(Shared.Extraction.ExtractionMath)
local FossilConfig = require(Shared.Config.FossilConfig)
local InventoryLogic = require(Shared.Inventory.InventoryLogic)
local RarityConfig = require(Shared.Config.RarityConfig)

local Ui = require(script.Parent.Ui)

type Refs = {
	Button: TextButton,
	ButtonScale: UIScale,
	Badge: Frame,
	BadgeText: TextLabel,
	Panel: Frame,
	PanelScale: UIScale,
	Count: TextLabel,
	Close: TextButton,
	Sets: Frame,
	List: ScrollingFrame,
	Empty: TextLabel,
}

local InventoryView = {}

local PANEL_POSITION = UDim2.fromScale(0.5, 0.5)
local PANEL_START = UDim2.fromScale(0.5, 0.56)
local OPEN_TIME = 0.25
local CLOSE_TIME = 0.15

local DARK = Color3.fromRGB(34, 32, 36)
local CARD = Color3.fromRGB(52, 49, 54)
local CARD_ALT = Color3.fromRGB(60, 57, 62)
local STROKE = Color3.fromRGB(14, 12, 14)
local TEXT = Color3.fromRGB(250, 246, 235)
local DIM = Color3.fromRGB(150, 146, 140)
local GOLD = Color3.fromRGB(255, 214, 80)
local BONE = Color3.fromRGB(236, 226, 200)

local refs: Refs? = nil
local shown = false
local token = 0

local function hex(color: Color3): string
	return string.format(
		"#%02X%02X%02X",
		math.round(color.R * 255),
		math.round(color.G * 255),
		math.round(color.B * 255)
	)
end

local function text(name: string, properties: { [string]: any }, maxSize: number): TextLabel
	local props: { [string]: any } = {
		Name = name,
		BackgroundTransparency = 1,
		TextScaled = true,
		Font = Enum.Font.GothamBold,
		TextColor3 = TEXT,
		Text = "",
	}
	for key, value in properties do
		props[key] = value
	end
	return Ui.create("TextLabel", props, {
		Ui.create("UITextSizeConstraint", { MaxTextSize = maxSize }),
	})
end

local function corner(radius: number): UICorner
	return Ui.create("UICorner", { CornerRadius = UDim.new(radius, 0) })
end

local function blob(position: UDim2, size: UDim2): Frame
	return Ui.create("Frame", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = position,
		Size = size,
		BackgroundColor3 = BONE,
		BorderSizePixel = 0,
	}, { corner(0.5) })
end

-- A greybox bone made of frames, so no image assets are needed.
local function boneIcon(): Frame
	return Ui.create("Frame", {
		Name = "Icon",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.1),
		Size = UDim2.fromScale(0.7, 0.5),
		BackgroundTransparency = 1,
		Rotation = -30,
	}, {
		blob(UDim2.fromScale(0.5, 0.5), UDim2.fromScale(0.62, 0.22)),
		blob(UDim2.fromScale(0.18, 0.36), UDim2.fromScale(0.22, 0.3)),
		blob(UDim2.fromScale(0.18, 0.64), UDim2.fromScale(0.22, 0.3)),
		blob(UDim2.fromScale(0.82, 0.36), UDim2.fromScale(0.22, 0.3)),
		blob(UDim2.fromScale(0.82, 0.64), UDim2.fromScale(0.22, 0.3)),
	})
end

local function buildButton(onPressed: () -> ()): (TextButton, UIScale, Frame, TextLabel)
	local badgeText = text("Count", {
		Size = UDim2.fromScale(1, 1),
		TextColor3 = DARK,
	}, 20)
	local badge = Ui.create("Frame", {
		Name = "Badge",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.88, 0.12),
		Size = UDim2.fromScale(0.38, 0.38),
		BackgroundColor3 = GOLD,
		BorderSizePixel = 0,
		Visible = false,
		ZIndex = 3,
	}, {
		Ui.create("UIAspectRatioConstraint", { AspectRatio = 1 }),
		corner(0.5),
		Ui.create("UIStroke", { Thickness = 2, Color = STROKE }),
		badgeText,
	}) :: Frame
	local scale = Ui.create("UIScale", { Scale = 1 }) :: UIScale
	local button = Ui.create("TextButton", {
		Name = "InventoryButton",
		-- Right edge, above the jump button's corner on phones.
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(0.985, 0.42),
		Size = UDim2.fromScale(0.12, 0.15),
		BackgroundColor3 = DARK,
		BackgroundTransparency = 0.2,
		BorderSizePixel = 0,
		Text = "",
		AutoButtonColor = true,
	}, {
		Ui.create("UIAspectRatioConstraint", { AspectRatio = 1 }),
		Ui.create("UISizeConstraint", { MaxSize = Vector2.new(96, 96) }),
		corner(0.22),
		Ui.create("UIStroke", { Thickness = 3, Color = STROKE }),
		scale,
		boneIcon(),
		text("Label", {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.fromScale(0.5, 0.94),
			Size = UDim2.fromScale(0.86, 0.28),
		}, 20),
		badge,
	}) :: TextButton
	local label = button:FindFirstChild("Label") :: TextLabel
	label.Text = "Finds"
	button.Activated:Connect(onPressed)
	return button, scale, badge, badgeText
end

-- Builds the button and the (hidden) panel. Call once.
function InventoryView.build(onToggle: () -> (), onClose: () -> ())
	local hud = Ui.getHud()
	local button, buttonScale, badge, badgeText = buildButton(onToggle)

	local closeButton = Ui.create("TextButton", {
		Name = "Close",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(0.97, 0.03),
		Size = UDim2.fromScale(0.1, 0.1),
		BackgroundColor3 = Color3.fromRGB(200, 80, 70),
		BorderSizePixel = 0,
		Text = "X",
		TextScaled = true,
		Font = Enum.Font.GothamBold,
		TextColor3 = TEXT,
	}, {
		Ui.create("UIAspectRatioConstraint", { AspectRatio = 1 }),
		corner(0.25),
		Ui.create("UITextSizeConstraint", { MaxTextSize = 28 }),
	}) :: TextButton
	closeButton.Activated:Connect(onClose)

	local count = text("Count", {
		Position = UDim2.fromScale(0.05, 0.13),
		Size = UDim2.fromScale(0.6, 0.06),
		TextColor3 = DIM,
		Font = Enum.Font.Gotham,
		TextXAlignment = Enum.TextXAlignment.Left,
	}, 18)

	local sets = Ui.create("Frame", {
		Name = "Sets",
		Position = UDim2.fromScale(0.04, 0.21),
		Size = UDim2.fromScale(0.92, 0.12),
		BackgroundTransparency = 1,
	}, {
		Ui.create("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}) :: Frame

	local list = Ui.create("ScrollingFrame", {
		Name = "List",
		Position = UDim2.fromScale(0.04, 0.35),
		Size = UDim2.fromScale(0.92, 0.61),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		CanvasSize = UDim2.fromScale(0, 0),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = DIM,
	}, {
		Ui.create("UIListLayout", {
			FillDirection = Enum.FillDirection.Vertical,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	}) :: ScrollingFrame

	local empty = text("Empty", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.62),
		Size = UDim2.fromScale(0.8, 0.1),
		TextColor3 = DIM,
		Font = Enum.Font.Gotham,
		Text = "Nothing here yet. Uncover a fossil and extract it!",
	}, 22)

	local panelScale = Ui.create("UIScale", { Scale = 1 }) :: UIScale
	local panel = Ui.create("Frame", {
		Name = "InventoryPanel",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = PANEL_POSITION,
		Size = UDim2.fromScale(0.62, 0.8),
		BackgroundColor3 = DARK,
		BackgroundTransparency = 0.05,
		BorderSizePixel = 0,
		Active = true, -- clicks on the panel never reach the dig site behind it
		Visible = false,
		ZIndex = 30,
	}, {
		Ui.create("UIAspectRatioConstraint", {
			AspectRatio = 1.3,
			AspectType = Enum.AspectType.FitWithinMaxSize,
			DominantAxis = Enum.DominantAxis.Width,
		}),
		Ui.create("UISizeConstraint", { MaxSize = Vector2.new(660, 508) }),
		corner(0.05),
		Ui.create("UIStroke", { Thickness = 3, Color = STROKE }),
		panelScale,
		text("Title", {
			Position = UDim2.fromScale(0.05, 0.03),
			Size = UDim2.fromScale(0.6, 0.1),
			Text = "Your Finds",
			TextXAlignment = Enum.TextXAlignment.Left,
		}, 34),
		count,
		closeButton,
		sets,
		list,
		empty,
	}) :: Frame

	button.Parent = hud
	panel.Parent = hud

	refs = {
		Button = button,
		ButtonScale = buttonScale,
		Badge = badge,
		BadgeText = badgeText,
		Panel = panel,
		PanelScale = panelScale,
		Count = count,
		Close = closeButton,
		Sets = sets,
		List = list,
		Empty = empty,
	}
end

local function buildSetRow(progress: InventoryLogic.SetProgress, order: number): Frame
	local complete = progress.Owned >= progress.Total
	local pieceText: { string } = {}
	for _, piece in progress.Pieces do
		local color = if piece.Owned then GOLD else DIM
		table.insert(pieceText, `<font color="{hex(color)}">{piece.DisplayName}</font>`)
	end
	return Ui.create("Frame", {
		Name = progress.SetId,
		LayoutOrder = order,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, {
		text("Progress", {
			Size = UDim2.fromScale(0.32, 0.9),
			Text = `{progress.DisplayName} {progress.Owned}/{progress.Total}`,
			TextColor3 = if complete then GOLD else TEXT,
			TextXAlignment = Enum.TextXAlignment.Left,
		}, 24),
		text("Pieces", {
			Position = UDim2.fromScale(0.34, 0.15),
			Size = UDim2.fromScale(0.66, 0.6),
			RichText = true,
			Font = Enum.Font.Gotham,
			Text = table.concat(pieceText, "   "),
			TextXAlignment = Enum.TextXAlignment.Left,
		}, 18),
	}) :: Frame
end

local function buildRow(entry: InventoryLogic.Entry, order: number, isNew: boolean): Frame
	local def = FossilConfig.ById[entry.FossilId]
	local rarity = RarityConfig.Rarities[entry.Rarity]
	local rarityColor = if rarity then rarity.Color else TEXT
	local grade = ExtractionMath.grade(entry.Condition)
	local name = if def then def.DisplayName else entry.FossilId
	if isNew then
		name ..= ` <font color="{hex(GOLD)}">NEW</font>`
	end

	return Ui.create("Frame", {
		Name = `Entry{entry.Id}`,
		LayoutOrder = order,
		Size = UDim2.fromScale(1, 0.1),
		BackgroundTransparency = 1,
	}, {
		-- The row's height comes from its width, so no pixel sizes are needed.
		Ui.create("UIAspectRatioConstraint", {
			AspectRatio = 9,
			AspectType = Enum.AspectType.ScaleWithParentSize,
			DominantAxis = Enum.DominantAxis.Width,
		}),
		Ui.create("Frame", {
			Name = "Card",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.49, 0.5),
			Size = UDim2.fromScale(0.97, 0.86),
			BackgroundColor3 = if order % 2 == 0 then CARD_ALT else CARD,
			BorderSizePixel = 0,
		}, {
			corner(0.2),
			Ui.create("Frame", {
				Name = "Stripe",
				Size = UDim2.fromScale(0.014, 1),
				BackgroundColor3 = rarityColor,
				BorderSizePixel = 0,
			}),
			text("FossilName", {
				Position = UDim2.fromScale(0.035, 0.15),
				Size = UDim2.fromScale(0.47, 0.7),
				RichText = true,
				Text = name,
				TextXAlignment = Enum.TextXAlignment.Left,
			}, 22),
			text("Rarity", {
				Position = UDim2.fromScale(0.52, 0.2),
				Size = UDim2.fromScale(0.18, 0.6),
				Text = if rarity then rarity.DisplayName else entry.Rarity,
				TextColor3 = rarityColor,
			}, 20),
			text("Condition", {
				Position = UDim2.fromScale(0.71, 0.15),
				Size = UDim2.fromScale(0.27, 0.7),
				Text = `{grade.Name} {entry.Condition}%`,
				TextColor3 = grade.Color,
				TextXAlignment = Enum.TextXAlignment.Right,
			}, 22),
		}),
	}) :: Frame
end

-- Redraws the panel's contents.
--   entries  already sorted for display
--   newIds   entries to tag as NEW
function InventoryView.render(
	entries: { InventoryLogic.Entry },
	newIds: { [number]: boolean },
	sets: { InventoryLogic.SetProgress }
)
	local r = refs
	if r == nil then
		return
	end
	for _, child in r.List:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	for _, child in r.Sets:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end

	for order, progress in sets do
		local row = buildSetRow(progress, order)
		row.Size = UDim2.fromScale(1, 1 / math.max(#sets, 1))
		row.Parent = r.Sets
	end
	for order, entry in entries do
		buildRow(entry, order, newIds[entry.Id] == true).Parent = r.List
	end
	r.Count.Text = if #entries == 1 then "1 find" else `{#entries} finds`
	r.Empty.Visible = #entries == 0
end

-- The count on the HUD button's badge.
function InventoryView.setCount(count: number)
	local r = refs
	if r == nil then
		return
	end
	r.Badge.Visible = count > 0
	r.BadgeText.Text = if count > 99 then "99+" else tostring(count)
end

-- Makes the HUD button bounce, to show something was just added.
function InventoryView.pulse()
	local r = refs
	if r == nil then
		return
	end
	r.ButtonScale.Scale = 1.35
	local info = TweenInfo.new(0.45, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	TweenService:Create(r.ButtonScale, info, { Scale = 1 }):Play()
end

function InventoryView.open()
	local r = refs
	if r == nil or shown then
		return
	end
	shown = true
	token += 1
	r.Panel.Visible = true
	r.Panel.Position = PANEL_START
	r.PanelScale.Scale = 0.85
	local info = TweenInfo.new(OPEN_TIME, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	TweenService:Create(r.PanelScale, info, { Scale = 1 }):Play()
	TweenService:Create(r.Panel, info, { Position = PANEL_POSITION }):Play()
end

function InventoryView.close()
	local r = refs
	if r == nil or not shown then
		return
	end
	shown = false
	token += 1
	local current = token
	local info = TweenInfo.new(CLOSE_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	TweenService:Create(r.PanelScale, info, { Scale = 0.85 }):Play()
	task.delay(CLOSE_TIME, function()
		if token == current then
			r.Panel.Visible = false
		end
	end)
end

function InventoryView.isOpen(): boolean
	return shown
end

return InventoryView
