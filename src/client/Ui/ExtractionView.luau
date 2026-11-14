--!strict
--[[
	ExtractionView: the extraction minigame's interface. It only draws and
	animates; the rules and timing live in ExtractionController.

	Built from Scale sizes and aspect-ratio constraints (see Ui.luau), so it is
	big and readable on a phone and capped on a monitor:
	  * TapCatcher  an invisible full-screen button: a click or tap anywhere counts
	  * Panel       sits just above the tool bar:
	      Play      title, one pip per hit, the bar (track, Good zone,
	                Perfect zone, marker) and a hint line
	      Result    the "Extracted!" moment
	      Flash     a white overlay for the Perfect flash
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local ExtractionConfig = require(ReplicatedStorage.Shared.Config.ExtractionConfig)

local Ui = require(script.Parent.Ui)

type Refs = {
	Catcher: TextButton,
	Panel: Frame,
	Scale: UIScale,
	Stroke: UIStroke,
	Play: Frame,
	Title: TextLabel,
	Pips: { Frame },
	GoodZone: Frame,
	PerfectZone: Frame,
	Marker: Frame,
	Popup: TextLabel,
	PopupScale: UIScale,
	Hint: TextLabel,
	Flash: Frame,
	Result: Frame,
	Header: TextLabel,
	HeaderScale: UIScale,
	Line: TextLabel,
	Sub: TextLabel,
}

local ExtractionView = {}

local feel = ExtractionConfig.Feel
local colors = feel.Colors

-- Bottom edge of the panel, just above the tool bar (which starts at about 0.8).
local PANEL_POSITION = UDim2.fromScale(0.5, 0.78)
local POPUP_Y = -0.15
local POPUP_RISE = 0.5

local refs: Refs? = nil
local openToken = 0
local isShown = false
local shakeLeft = 0
local shakeAmount = 0

local function text(name: string, properties: { [string]: any }, maxSize: number): TextLabel
	local props: { [string]: any } = {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0),
		BackgroundTransparency = 1,
		TextScaled = true,
		Font = Enum.Font.GothamBold,
		TextColor3 = colors.Text,
		TextStrokeTransparency = 0.6,
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

local function zone(name: string, color: Color3, zIndex: number): Frame
	return Ui.create("Frame", {
		Name = name,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.2, 1),
		BackgroundColor3 = color,
		BorderSizePixel = 0,
		ZIndex = zIndex,
	}, { corner(0.3) })
end

-- Builds the (hidden) interface. Call once.
function ExtractionView.build()
	local hud = Ui.getHud()

	local catcher = Ui.create("TextButton", {
		Name = "ExtractionTapCatcher",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		ZIndex = 40,
		Visible = false,
	}) :: TextButton

	local pips: { Frame } = {}
	local pipChildren: { Instance } = {
		Ui.create("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			HorizontalAlignment = Enum.HorizontalAlignment.Center,
			VerticalAlignment = Enum.VerticalAlignment.Center,
			SortOrder = Enum.SortOrder.LayoutOrder,
			Padding = UDim.new(0.06, 0),
		}),
	}
	for index = 1, ExtractionConfig.Hits do
		local pip = Ui.create("Frame", {
			Name = `Pip{index}`,
			LayoutOrder = index,
			Size = UDim2.fromScale(0.2, 1),
			BackgroundColor3 = colors.PipEmpty,
			BorderSizePixel = 0,
		}, {
			Ui.create("UIAspectRatioConstraint", { AspectRatio = 1 }),
			corner(0.5),
			Ui.create("UIStroke", { Thickness = 2, Color = colors.Stroke }),
		}) :: Frame
		pips[index] = pip
		table.insert(pipChildren, pip)
	end
	local pipRow = Ui.create("Frame", {
		Name = "Pips",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.29),
		Size = UDim2.fromScale(0.4, 0.15),
		BackgroundTransparency = 1,
	}, pipChildren) :: Frame

	local goodZone = zone("GoodZone", colors.GoodZone, 2)
	local perfectZone = zone("PerfectZone", colors.PerfectZone, 3)
	local marker = Ui.create("Frame", {
		Name = "Marker",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.016, 1.55),
		BackgroundColor3 = colors.Marker,
		BorderSizePixel = 0,
		ZIndex = 5,
	}, {
		corner(0.4),
		Ui.create("UIStroke", { Thickness = 2, Color = colors.Stroke }),
	}) :: Frame
	local popupScale = Ui.create("UIScale", { Scale = 1 }) :: UIScale
	local popup = text("Popup", {
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.fromScale(0.5, POPUP_Y),
		Size = UDim2.fromScale(0.4, 1.7),
		ZIndex = 6,
		TextStrokeTransparency = 0.2,
		TextTransparency = 1,
	}, 44)
	popupScale.Parent = popup

	local bar = Ui.create("Frame", {
		Name = "Bar",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromScale(0.9, 0.24),
		BackgroundColor3 = colors.Track,
		BorderSizePixel = 0,
		ZIndex = 1,
	}, {
		corner(0.3),
		Ui.create("UIStroke", { Thickness = 2, Color = colors.Stroke }),
		goodZone,
		perfectZone,
		marker,
		popup,
	}) :: Frame

	local title = text("Title", {
		Position = UDim2.fromScale(0.5, 0.06),
		Size = UDim2.fromScale(0.9, 0.2),
		RichText = true,
	}, 32)
	local hint = text("Hint", {
		Position = UDim2.fromScale(0.5, 0.82),
		Size = UDim2.fromScale(0.9, 0.13),
		TextColor3 = colors.Hint,
		Font = Enum.Font.Gotham,
	}, 22)

	local play = Ui.create("Frame", {
		Name = "Play",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
	}, { title, pipRow, bar, hint }) :: Frame

	local headerScale = Ui.create("UIScale", { Scale = 1 }) :: UIScale
	local header = text("Header", {
		Position = UDim2.fromScale(0.5, 0.08),
		Size = UDim2.fromScale(0.9, 0.32),
		Text = "EXTRACTED!",
		TextColor3 = colors.Header,
		TextStrokeTransparency = 0.3,
	}, 48)
	headerScale.Parent = header
	local line = text("Line", {
		Position = UDim2.fromScale(0.5, 0.44),
		Size = UDim2.fromScale(0.92, 0.24),
		RichText = true,
	}, 32)
	local sub = text("Sub", {
		Position = UDim2.fromScale(0.5, 0.72),
		Size = UDim2.fromScale(0.9, 0.15),
		TextColor3 = colors.Hint,
		Font = Enum.Font.Gotham,
	}, 22)
	local result = Ui.create("Frame", {
		Name = "Result",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		Visible = false,
	}, { header, line, sub }) :: Frame

	local flash = Ui.create("Frame", {
		Name = "Flash",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(1, 1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ZIndex = 20,
	}, { corner(0.12) }) :: Frame

	local scale = Ui.create("UIScale", { Scale = 1 }) :: UIScale
	local stroke = Ui.create("UIStroke", { Thickness = 3, Color = colors.Stroke }) :: UIStroke
	local panel = Ui.create("Frame", {
		Name = "ExtractionPanel",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = PANEL_POSITION,
		Size = UDim2.fromScale(0.8, 0.38),
		BackgroundColor3 = colors.Panel,
		BackgroundTransparency = 0.08,
		BorderSizePixel = 0,
		ZIndex = 50,
		Visible = false,
	}, {
		-- Wide and short, so it fits a landscape phone; capped on big screens.
		Ui.create("UIAspectRatioConstraint", {
			AspectRatio = 3.4,
			AspectType = Enum.AspectType.FitWithinMaxSize,
			DominantAxis = Enum.DominantAxis.Width,
		}),
		Ui.create("UISizeConstraint", { MaxSize = Vector2.new(800, 236) }),
		corner(0.12),
		stroke,
		scale,
		play,
		result,
		flash,
	}) :: Frame

	catcher.Parent = hud
	panel.Parent = hud

	refs = {
		Catcher = catcher,
		Panel = panel,
		Scale = scale,
		Stroke = stroke,
		Play = play,
		Title = title,
		Pips = pips,
		GoodZone = goodZone,
		PerfectZone = perfectZone,
		Marker = marker,
		Popup = popup,
		PopupScale = popupScale,
		Hint = hint,
		Flash = flash,
		Result = result,
		Header = header,
		HeaderScale = headerScale,
		Line = line,
		Sub = sub,
	}
end

-- The invisible full-screen button, and the panel: input on either is a tap.
function ExtractionView.getInputTargets(): { GuiObject }
	local r = refs
	return if r then { r.Catcher, r.Panel } else {}
end

-- Shows the panel with a pop. `title` may use RichText.
function ExtractionView.open(title: string, hint: string, rarityColor: Color3)
	local r = refs
	if r == nil then
		return
	end
	openToken += 1
	isShown = true
	shakeLeft = 0
	r.Title.Text = title
	r.Hint.Text = hint
	r.Stroke.Color = rarityColor
	r.Play.Visible = true
	r.Result.Visible = false
	r.Popup.TextTransparency = 1
	r.Flash.BackgroundTransparency = 1
	r.Panel.Position = PANEL_POSITION
	for index in r.Pips do
		ExtractionView.setPip(index, nil)
	end
	r.Catcher.Visible = true
	r.Panel.Visible = true
	r.Scale.Scale = 0.6
	local info = TweenInfo.new(feel.OpenTime, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	TweenService:Create(r.Scale, info, { Scale = 1 }):Play()
end

-- Hides the panel. Input goes back to the world at once.
function ExtractionView.close()
	local r = refs
	if r == nil or not isShown then
		return
	end
	isShown = false
	openToken += 1
	local token = openToken
	r.Catcher.Visible = false
	local info = TweenInfo.new(feel.CloseTime, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	TweenService:Create(r.Scale, info, { Scale = 0.6 }):Play()
	task.delay(feel.CloseTime, function()
		if openToken == token then
			r.Panel.Visible = false
		end
	end)
end

function ExtractionView.isOpen(): boolean
	return isShown
end

-- Places the safe zone. Positions and widths are fractions of the bar.
function ExtractionView.setZone(center: number, perfectWidth: number, goodWidth: number)
	local r = refs
	if r == nil then
		return
	end
	r.GoodZone.Position = UDim2.fromScale(center, 0.5)
	r.GoodZone.Size = UDim2.fromScale(goodWidth, 1)
	r.PerfectZone.Position = UDim2.fromScale(center, 0.5)
	r.PerfectZone.Size = UDim2.fromScale(perfectWidth, 1)
end

function ExtractionView.setMarker(position: number)
	local r = refs
	if r then
		r.Marker.Position = UDim2.fromScale(math.clamp(position, 0, 1), 0.5)
	end
end

-- Colours a hit's pip by its rating; nil empties it.
function ExtractionView.setPip(index: number, rating: string?)
	local r = refs
	local pip = r and r.Pips[index]
	if pip == nil then
		return
	end
	local ratingFeel = if rating then feel.Ratings[rating] else nil
	pip.BackgroundColor3 = if ratingFeel then ratingFeel.Color else colors.PipEmpty
end

-- The PERFECT / GOOD / MISS popup above the bar, plus flash and shake.
function ExtractionView.feedback(rating: string, position: number)
	local r = refs
	local ratingFeel = feel.Ratings[rating]
	if r == nil or ratingFeel == nil then
		return
	end
	local x = math.clamp(position, 0.15, 0.85)
	r.Popup.Text = ratingFeel.Text
	r.Popup.TextColor3 = ratingFeel.Color
	r.Popup.TextTransparency = 0
	r.Popup.Position = UDim2.fromScale(x, POPUP_Y)
	r.PopupScale.Scale = 1.5
	local pop = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	TweenService:Create(r.PopupScale, pop, { Scale = 1 }):Play()
	local float = TweenInfo.new(feel.PopupTime, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	TweenService:Create(r.Popup, float, {
		Position = UDim2.fromScale(x, POPUP_Y - POPUP_RISE),
		TextTransparency = 1,
	}):Play()

	if ratingFeel.Flash < 1 then
		r.Flash.BackgroundTransparency = ratingFeel.Flash
		local fade = TweenInfo.new(feel.FlashTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(r.Flash, fade, { BackgroundTransparency = 1 }):Play()
	end
	if ratingFeel.PanelShake > 0 then
		shakeLeft = feel.PanelShakeTime
		shakeAmount = ratingFeel.PanelShake
	end
end

-- Switches the panel to the "Extracted!" moment.
--   line  e.g. "Ammonite: Excellent, 87%" (may use RichText)
--   sub   a small line underneath
function ExtractionView.showResult(line: string, sub: string)
	local r = refs
	if r == nil then
		return
	end
	r.Play.Visible = false
	r.Result.Visible = true
	r.Line.Text = line
	r.Sub.Text = sub
	r.HeaderScale.Scale = 1.6
	local pop = TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	TweenService:Create(r.HeaderScale, pop, { Scale = 1 }):Play()
	r.Flash.BackgroundTransparency = 0.4
	local fade =
		TweenInfo.new(feel.FlashTime * 1.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(r.Flash, fade, { BackgroundTransparency = 1 }):Play()
end

-- Call every frame with the real frame time (drives the panel shake).
function ExtractionView.step(delta: number)
	local r = refs
	if r == nil or shakeLeft <= 0 then
		return
	end
	shakeLeft = math.max(0, shakeLeft - delta)
	local strength = shakeLeft / math.max(feel.PanelShakeTime, 0.01)
	local offset = math.sin(shakeLeft * 70) * shakeAmount * strength
	r.Panel.Position = PANEL_POSITION + UDim2.fromScale(offset, 0)
end

return ExtractionView
