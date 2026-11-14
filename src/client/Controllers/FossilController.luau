--!strict
--[[
	FossilController: the fossil side of digging on this client. The crust
	appearing, and above all the big moment when a fossil is uncovered.

	The reveal, step by step:
	  1. The final brush stroke lands. We know it is the last one (the crust
	     tells us how many strokes it needs), so time slows at once: crust
	     shards burst off in slow motion, the camera pushes in, digging pauses.
	  2. Meanwhile the server confirms the reveal and tells us WHICH fossil it
	     is. The slow motion hides that short wait.
	  3. Time snaps back: the fossil pops out of the ground and spins up to
	     hover above the plot, glowing in its rarity colour, with sparkles, a
	     rising chime and a name tag. Rarer fossils hold the slow motion a
	     beat longer and get a bigger burst.

	Everything here is cosmetic and local. If the server does not confirm, the
	moment is quietly cancelled.

	The uncovered fossil then hovers while the player extracts it
	(ExtractionController). Each extraction hit makes it react (a swell and
	sparkles for a good hit, chips flying off for a miss), and once it is
	extracted it shrinks and flies away into the collection.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage.Shared
local ExtractionConfig = require(Shared.Config.ExtractionConfig)
local FeelConfig = require(Shared.Config.FeelConfig)
local FossilConfig = require(Shared.Config.FossilConfig)
local RarityConfig = require(Shared.Config.RarityConfig)

local Client = script.Parent.Parent
local CameraFx = require(Client.Effects.CameraFx)
local CellVisuals = require(Client.Effects.CellVisuals)
local DebrisField = require(Client.Effects.DebrisField)
local EffectsController = require(script.Parent.EffectsController)
local ParticlePool = require(Client.Effects.ParticlePool)
local PlotController = require(script.Parent.PlotController)
local SoundPlayer = require(Client.Effects.SoundPlayer)
local TimeScale = require(Client.Effects.TimeScale)

-- A reveal that has started but whose fossil has not popped out yet.
type PendingReveal = {
	Index: number,
	Part: BasePart,
	StartedAt: number,
	DefId: string?, -- set once the server confirms
}

-- An uncovered fossil on display above the plot.
type Display = {
	Part: BasePart,
	Rotation: CFrame,
	Size: Vector3,
	From: Vector3,
	To: Vector3,
	PopStart: number, -- 0 once the pop has finished
	Angle: number,
	Light: PointLight,
	Highlight: Highlight,
	Intensity: number,
	Color: Color3, -- the rarity colour
	BumpStart: number, -- extraction hit reaction; 0 = none
	BumpAmount: number,
	CollectStart: number, -- extracted and flying away; 0 = not yet
}

local RECENT_BREAK_WINDOW = 3 -- seconds
local COLLECT_SPIN = 720 -- degrees per second while flying away

local FossilController = {}

local reveal = FeelConfig.Reveal
local extractFeel = ExtractionConfig.Feel
local pending: PendingReveal? = nil
local lockedUntil = 0
local displays: { [BasePart]: Display } = {}
local recentBreaks: { [number]: number } = {}

local function rotationOf(def: FossilConfig.FossilDef): CFrame
	return CFrame.Angles(
		math.rad(def.Rotation.X),
		math.rad(def.Rotation.Y),
		math.rad(def.Rotation.Z)
	)
end

local function easeOut(alpha: number): number
	return 1 - (1 - alpha) * (1 - alpha)
end

-- Scale during the pop: grows past full size, then settles back.
local function popScale(alpha: number): number
	local peak = 0.6
	if alpha < peak then
		return reveal.PopStartScale
			+ (reveal.PopOvershoot - reveal.PopStartScale) * easeOut(alpha / peak)
	end
	return reveal.PopOvershoot + (1 - reveal.PopOvershoot) * easeOut((alpha - peak) / (1 - peak))
end

local function buildLabel(
	part: BasePart,
	def: FossilConfig.FossilDef,
	rarity: RarityConfig.RarityDef
)
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "FossilLabel"
	billboard.Adornee = part
	-- For a BillboardGui, Scale is measured in studs, so the tag keeps its
	-- size in the world on every screen.
	billboard.Size = UDim2.fromScale(reveal.LabelWidth, reveal.LabelHeight)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, reveal.LabelOffset, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.MaxDistance = 150

	local scale = Instance.new("UIScale")
	scale.Scale = 0
	scale.Parent = billboard

	local name = Instance.new("TextLabel")
	name.Name = "FossilName"
	name.Size = UDim2.fromScale(1, 0.6)
	name.BackgroundTransparency = 1
	name.Text = def.DisplayName
	name.TextScaled = true
	name.Font = Enum.Font.GothamBold
	name.TextColor3 = Color3.new(1, 1, 1)
	name.TextStrokeTransparency = 0.3
	name.Parent = billboard

	local tier = Instance.new("TextLabel")
	tier.Name = "Rarity"
	tier.Position = UDim2.fromScale(0, 0.6)
	tier.Size = UDim2.fromScale(1, 0.4)
	tier.BackgroundTransparency = 1
	tier.Text = rarity.DisplayName
	tier.TextScaled = true
	tier.Font = Enum.Font.GothamBold
	tier.TextColor3 = rarity.Color
	tier.TextStrokeTransparency = 0.3
	tier.Parent = billboard

	billboard.Parent = part
	local popIn = TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	TweenService:Create(scale, popIn, { Scale = 1 }):Play()
end

-- Turns an uncovered fossil into a glowing, labelled display piece.
--   animate  true = play the pop; false = it was already uncovered when we first saw it
local function display(index: number, part: BasePart, defId: string, animate: boolean)
	local def = FossilConfig.ById[defId]
	local origin = PlotController.getOrigin()
	local cellCenter = PlotController.getCellCenter(index)
	if def == nil or origin == nil or cellCenter == nil or displays[part] then
		return
	end
	local rarity = RarityConfig.Rarities[def.Rarity]
	local feel = reveal.ByRarity[def.Rarity]
	if rarity == nil or feel == nil then
		return
	end

	-- From here on this controller animates the part.
	CellVisuals.forget(part)
	-- Make it look like the fossil right away, in case the server's own
	-- update of the part has not reached us yet.
	if part:IsA("Part") then
		part.Shape = def.Shape
	end
	part.Material = FossilConfig.RevealedMaterial
	part.Color = def.Color
	part.CanQuery = false -- a display piece never blocks a click on the grid

	local light = Instance.new("PointLight")
	light.Color = rarity.Color
	light.Range = reveal.LightRange
	light.Brightness = reveal.LightBrightnessStart * feel.Intensity
	light.Parent = part

	local highlight = Instance.new("Highlight")
	highlight.Adornee = part
	highlight.FillColor = rarity.Color
	highlight.OutlineColor = Color3.new(1, 1, 1)
	highlight.FillTransparency = reveal.FillTransparencyStart
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = part

	local sparkles = ParticlePool.newEmitter(reveal.SparkleParticles, part)
	if sparkles then
		sparkles.Color = ColorSequence.new(rarity.Color)
		sparkles.Speed = NumberRange.new(1, 3)
		sparkles.Rate = reveal.IdleSparkleRate
		sparkles.Enabled = true
	end

	buildLabel(part, def, rarity)

	local hover = Vector3.new(cellCenter.X, origin.Y + reveal.HoverHeight, cellCenter.Z)
	local entry: Display = {
		Part = part,
		Rotation = rotationOf(def),
		Size = def.Size,
		From = cellCenter,
		To = hover,
		PopStart = if animate then os.clock() else 0,
		Angle = 0,
		Light = light,
		Highlight = highlight,
		Intensity = feel.Intensity,
		Color = rarity.Color,
		BumpStart = 0,
		BumpAmount = 0,
		CollectStart = 0,
	}
	displays[part] = entry

	if animate then
		local fade =
			TweenInfo.new(reveal.GlowFadeTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(light, fade, { Brightness = reveal.LightBrightnessEnd }):Play()
		TweenService:Create(highlight, fade, { FillTransparency = reveal.FillTransparencyEnd })
			:Play()
		task.delay(reveal.GlowFadeTime, function()
			highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		end)

		CameraFx.setFovOffset(0, reveal.FovRelease)
		CameraFx.shake(feel.Shake)
		SoundPlayer.play(feel.Sound)
		ParticlePool.emit(reveal.SparkleParticles, hover, nil, feel.Intensity, rarity.Color)
	else
		light.Brightness = reveal.LightBrightnessEnd
		highlight.FillTransparency = reveal.FillTransparencyEnd
		highlight.DepthMode = Enum.HighlightDepthMode.Occluded
		part.Size = def.Size
		part.CFrame = CFrame.new(hover) * entry.Rotation
	end
end

-- Hides an extracted fossil on this client. The server removes the part
-- itself shortly after.
local function hidePart(part: BasePart)
	part.Transparency = 1
	for _, child in part:GetChildren() do
		local isEffect = child:IsA("PointLight")
			or child:IsA("Highlight")
			or child:IsA("ParticleEmitter")
			or child:IsA("BillboardGui")
		if isEffect then
			(child :: any).Enabled = false
		end
	end
end

local function finishPending(current: PendingReveal, defId: string)
	pending = nil
	lockedUntil = os.clock() + reveal.InputLockAfterPop
	if current.Part.Parent ~= nil then
		display(current.Index, current.Part, defId, true)
	else
		CameraFx.setFovOffset(0, reveal.FovRelease)
	end
end

local function abandonPending()
	pending = nil
	TimeScale.cancel()
	CameraFx.setFovOffset(0, reveal.FovRelease)
end

local function step(delta: number)
	local now = os.clock()

	local current = pending
	if current then
		local defId = current.DefId
		if defId then
			if now >= TimeScale.holdEndsAt() then
				finishPending(current, defId)
			end
		elseif now - current.StartedAt > reveal.MaxWaitForServer then
			abandonPending()
		end
	end

	for part, entry in displays do
		if part.Parent == nil then
			displays[part] = nil
			continue
		end
		local position = entry.To
		local scale = 1
		if entry.PopStart > 0 then
			local alpha = math.clamp((now - entry.PopStart) / reveal.PopDuration, 0, 1)
			position = entry.From:Lerp(entry.To, easeOut(alpha))
			scale = popScale(alpha)
			entry.Angle = reveal.SpinTurns * math.pi * 2 * easeOut(alpha)
			if alpha >= 1 then
				entry.PopStart = 0
			end
		else
			entry.Angle += math.rad(reveal.IdleSpinSpeed) * delta
		end

		-- An extraction hit: swell for an instant, then settle.
		if entry.BumpStart > 0 then
			local alpha = math.clamp((now - entry.BumpStart) / extractFeel.BumpTime, 0, 1)
			scale *= 1 + entry.BumpAmount * (1 - alpha) * (1 - alpha)
			if alpha >= 1 then
				entry.BumpStart = 0
			end
		end

		-- Extracted: spin up, rise, shrink away.
		if entry.CollectStart > 0 then
			local alpha = math.clamp((now - entry.CollectStart) / extractFeel.CollectTime, 0, 1)
			local eased = alpha * alpha
			position += Vector3.new(0, extractFeel.CollectRise * eased, 0)
			scale *= math.max(1 - eased, 0.01)
			entry.Angle += math.rad(COLLECT_SPIN) * delta
			if alpha >= 1 then
				displays[part] = nil
				hidePart(part)
				continue
			end
		end

		part.Size = entry.Size * scale
		part.CFrame = CFrame.new(position) * CFrame.Angles(0, entry.Angle, 0) * entry.Rotation
	end
end

local function onFossilAdded(index: number, part: BasePart)
	local defId = part:GetAttribute("DefId")
	if part:GetAttribute("Stage") == "Extracted" then
		hidePart(part)
		return
	end
	if part:GetAttribute("Stage") == "Revealed" and typeof(defId) == "string" then
		display(index, part, defId, false)
		return
	end

	local clean = part:GetAttribute("Clean")
	local needed = part:GetAttribute("CleanNeeded")
	if typeof(clean) == "number" and typeof(needed) == "number" and needed > 0 then
		CellVisuals.setCrustClean(part, clean / needed)
	end

	-- Celebrate only a crust that our own digging just exposed.
	local brokenAt = recentBreaks[index]
	if brokenAt and os.clock() - brokenAt < RECENT_BREAK_WINDOW then
		recentBreaks[index] = nil
		EffectsController.fossilFound(part)
	end
end

local function onFossilRemoved(_index: number, part: BasePart)
	displays[part] = nil
	CellVisuals.forget(part)
	local current = pending
	if current and current.Part == part then
		abandonPending()
	end
end

-- Public API ---------------------------------------------------------------

-- True while the reveal moment is playing; digging is paused.
function FossilController.isBusy(): boolean
	return pending ~= nil or os.clock() < lockedUntil
end

-- DigController calls this when it predicts a cell has broken, so we know a
-- crust appearing there is the player's own find.
function FossilController.noteBreak(index: number)
	recentBreaks[index] = os.clock()
end

-- Step 1: the final brush stroke was just predicted.
function FossilController.beginReveal(index: number, part: BasePart)
	if pending then
		return
	end
	pending = { Index = index, Part = part, StartedAt = os.clock(), DefId = nil }

	-- The server is about to reshape this part into the fossil. Stop our own
	-- brush wobble so it does not fight that update.
	CellVisuals.stopReaction(part)

	TimeScale.slow(reveal.SlowTimeScale, reveal.SlowDuration, reveal.RecoverDuration)
	CameraFx.setFovOffset(reveal.FovKick, reveal.FovAttack)
	SoundPlayer.play(reveal.StartSound)
	DebrisField.burst(
		part.Position,
		part.Size,
		FossilConfig.Crust.CleanColor,
		FossilConfig.Crust.Material,
		reveal.CrustShards
	)
end

-- Step 2: the server confirmed the reveal and named the fossil.
function FossilController.confirmReveal(index: number, defId: string)
	local current = pending
	if current == nil or current.Index ~= index then
		-- The server uncovered a fossil we were not expecting. Play the whole
		-- moment now, from the top.
		local part = PlotController.getFossilPart(index)
		if part == nil or displays[part] then
			return
		end
		if current then
			abandonPending()
		end
		FossilController.beginReveal(index, part)
		current = pending
	end
	if current == nil then
		return
	end
	current.DefId = defId

	local def = FossilConfig.ById[defId]
	local feel = def and reveal.ByRarity[def.Rarity]
	if feel and feel.ExtraSlow > 0 then
		TimeScale.extend(feel.ExtraSlow)
	end
end

-- An extraction hit landed on the fossil in this cell: make it react.
function FossilController.extractionHit(index: number, rating: string)
	local part = PlotController.getFossilPart(index)
	local entry = part and displays[part]
	local feel = extractFeel.Ratings[rating]
	if part == nil or entry == nil or feel == nil then
		return
	end
	if feel.Bump > 0 then
		entry.BumpStart = os.clock()
		entry.BumpAmount = feel.Bump
	end
	if feel.Sparkles > 0 then
		ParticlePool.emit(reveal.SparkleParticles, part.Position, nil, feel.Sparkles, entry.Color)
	end
	if feel.Chips > 0 then
		local chipSize = Vector3.new(1, 1, 1) * math.min(entry.Size.X, entry.Size.Y, entry.Size.Z)
		DebrisField.burst(part.Position, chipSize, part.Color, part.Material, feel.Chips)
	end
end

-- The fossil in this cell has been extracted: send it flying into the collection.
function FossilController.collect(index: number)
	local part = PlotController.getFossilPart(index)
	local entry = part and displays[part]
	if part == nil or entry == nil or entry.CollectStart > 0 then
		return
	end
	entry.CollectStart = os.clock()
	entry.BumpStart = 0
	ParticlePool.emit(reveal.SparkleParticles, part.Position, nil, entry.Intensity, entry.Color)
end

-- The server did not agree that the fossil is uncovered yet.
function FossilController.cancelReveal(index: number)
	local current = pending
	if current and current.Index == index and current.DefId == nil then
		abandonPending()
	end
end

function FossilController.Start()
	PlotController.FossilAdded:Connect(onFossilAdded)
	PlotController.FossilRemoved:Connect(onFossilRemoved)
	RunService.RenderStepped:Connect(step)
end

return FossilController
