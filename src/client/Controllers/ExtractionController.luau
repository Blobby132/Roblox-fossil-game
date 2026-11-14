--!strict
--[[
	ExtractionController: the extraction minigame on this client.

	The server starts it (ExtractionStarted) the moment a fossil is uncovered,
	and sends everything needed to draw it: the marker's speeds, start and
	direction, each hit's zone, and when the marker sets off (in server time).
	The client draws the marker from Workspace:GetServerTimeNow(), so what the
	player sees matches what the server will rate.

	On each tap:
	  1. PREDICT the rating with the same maths the server uses (ExtractionMath)
	     and play the feedback at once: a crisp sound and flash for Perfect, a
	     softer sound for Good, a dull thunk and a shake for Miss.
	  2. Send the server only the moment of the tap (ExtractionTap).
	  3. The server answers with its own rating (ExtractionTapResult). It
	     normally agrees; if not, the pip is corrected. A refused tap is undone.
	When the server sends ExtractionFinished, the "Extracted!" moment plays:
	the fossil's name in its rarity colour and its condition, e.g.
	"Ammonite: Excellent, 87%", and the fossil flies off into the collection.

	Only one tap is ever waiting for an answer, which keeps the prediction
	simple to correct. Digging is paused while an extraction runs (DigController
	asks isBusy()).

	Controls: tap or click anywhere, or press Space (gamepad: A). Space is
	taken over during extraction, so it does not make the character jump.
]]

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local ExtractionConfig = require(Shared.Config.ExtractionConfig)
local ExtractionMath = require(Shared.Extraction.ExtractionMath)
local FossilConfig = require(Shared.Config.FossilConfig)
local RarityConfig = require(Shared.Config.RarityConfig)
local Remotes = require(Shared.Remotes)

local Client = script.Parent.Parent
local CameraFx = require(Client.Effects.CameraFx)
local ExtractionView = require(Client.Ui.ExtractionView)
local FossilController = require(script.Parent.FossilController)
local InventoryController = require(script.Parent.InventoryController)
local SoundPlayer = require(Client.Effects.SoundPlayer)

-- What the server sent in ExtractionStarted, after checking.
export type Info = {
	FossilId: string,
	Rarity: string,
	CellIndex: number,
	Hits: number,
	StartAt: number,
	Deadline: number,
	Speeds: { number },
	StartPos: number,
	StartDir: number,
	Zones: { number },
	PerfectWidth: number,
	GoodWidth: number,
	HitPause: number,
}

export type Result = {
	FossilId: string,
	Rarity: string,
	Condition: number,
	Ratings: { string },
	TimedOut: boolean,
}

type Active = {
	Id: number,
	Info: Info,
	Segment: ExtractionMath.Segment?, -- what the marker is doing; nil once every hit is taken
	Ratings: { string }, -- shown so far (predicted, then confirmed by the server)
	AwaitingReply: boolean, -- a tap has been sent and not answered yet
	FrozenUntil: number, -- server time; the marker is paused after a hit until then
	FrozenPos: number,
	Opened: boolean,
	LastTapAt: number, -- os.clock() of the last tap sent
	Result: Result?,
	ResultShownAt: number, -- os.clock(); 0 = not shown yet
	FinishedAt: number, -- os.clock() of the last hit; 0 = still playing
}

local ACTION_NAME = "ExtractionTap"
local TAP_KEYS = { Enum.KeyCode.Space, Enum.KeyCode.ButtonA }

local ExtractionController = {}

local feel = ExtractionConfig.Feel
local active: Active? = nil

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

local function isNumber(value: any): boolean
	return typeof(value) == "number" and value == value and math.abs(value) ~= math.huge
end

local function numberList(value: any, count: number): { number }?
	if typeof(value) ~= "table" then
		return nil
	end
	local list: { number } = {}
	for index = 1, count do
		local item = value[index]
		if not isNumber(item) then
			return nil
		end
		list[index] = item
	end
	return list
end

-- Checks the server's ExtractionStarted payload.
local function readInfo(raw: any): Info?
	if typeof(raw) ~= "table" then
		return nil
	end
	local hits = raw.Hits
	if not isNumber(hits) or hits < 1 or hits > 10 or hits % 1 ~= 0 then
		return nil
	end
	local fossilId, rarity = raw.FossilId, raw.Rarity
	if typeof(fossilId) ~= "string" or FossilConfig.ById[fossilId] == nil then
		return nil
	end
	if typeof(rarity) ~= "string" then
		return nil
	end
	local speeds = numberList(raw.Speeds, hits)
	local zones = numberList(raw.Zones, hits)
	for _, key in { "CellIndex", "StartAt", "Deadline", "StartPos", "StartDir" } do
		if not isNumber(raw[key]) then
			return nil
		end
	end
	for _, key in { "PerfectWidth", "GoodWidth", "HitPause" } do
		if not isNumber(raw[key]) then
			return nil
		end
	end
	if speeds == nil or zones == nil then
		return nil
	end
	return {
		FossilId = fossilId,
		Rarity = rarity,
		CellIndex = raw.CellIndex,
		Hits = hits,
		StartAt = raw.StartAt,
		Deadline = raw.Deadline,
		Speeds = speeds,
		StartPos = raw.StartPos,
		StartDir = raw.StartDir,
		Zones = zones,
		PerfectWidth = raw.PerfectWidth,
		GoodWidth = raw.GoodWidth,
		HitPause = raw.HitPause,
	}
end

local function readSegment(raw: any): ExtractionMath.Segment?
	if typeof(raw) ~= "table" then
		return nil
	end
	for _, key in { "Hit", "StartAt", "StartPos", "StartDir", "Speed" } do
		if not isNumber(raw[key]) then
			return nil
		end
	end
	return {
		Hit = raw.Hit,
		StartAt = raw.StartAt,
		StartPos = raw.StartPos,
		StartDir = raw.StartDir,
		Speed = raw.Speed,
	}
end

local function rarityColor(rarity: string): Color3
	local def = RarityConfig.Rarities[rarity]
	return if def then def.Color else Color3.new(1, 1, 1)
end

-- "#RRGGBB", for RichText colour tags.
local function hex(color: Color3): string
	return string.format(
		"#%02X%02X%02X",
		math.round(color.R * 255),
		math.round(color.G * 255),
		math.round(color.B * 255)
	)
end

local function displayName(fossilId: string): string
	local def = FossilConfig.ById[fossilId]
	return if def then def.DisplayName else fossilId
end

local function hintText(): string
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "Tap to stop the marker in the gold!"
	end
	return "Click or press Space to stop the marker in the gold!"
end

local function showZone(current: Active, hit: number)
	local info = current.Info
	local center = info.Zones[math.clamp(hit, 1, info.Hits)]
	ExtractionView.setZone(center, info.PerfectWidth, info.GoodWidth)
end

local function bindKeys()
	ContextActionService:BindActionAtPriority(
		ACTION_NAME,
		function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
			if state == Enum.UserInputState.Begin then
				ExtractionController.tap()
			end
			return Enum.ContextActionResult.Sink
		end,
		false,
		Enum.ContextActionPriority.High.Value,
		table.unpack(TAP_KEYS)
	)
end

local function unbindKeys()
	ContextActionService:UnbindAction(ACTION_NAME)
end

local function close()
	if active == nil then
		return
	end
	active = nil
	unbindKeys()
	ExtractionView.close()
end

local function open(current: Active)
	current.Opened = true
	local info = current.Info
	local color = rarityColor(info.Rarity)
	local title = `Extract the <font color="{hex(color)}">{displayName(info.FossilId)}</font>!`
	ExtractionView.open(title, hintText(), color)
	showZone(current, 1)
	for index, rating in current.Ratings do
		ExtractionView.setPip(index, rating)
	end
	SoundPlayer.play(feel.OpenSound)
	bindKeys()
end

local function playFeedback(current: Active, rating: string, position: number)
	local ratingFeel = feel.Ratings[rating]
	if ratingFeel == nil then
		return
	end
	SoundPlayer.play(ratingFeel.Sound)
	CameraFx.shake(ratingFeel.Shake)
	ExtractionView.feedback(rating, position)
	FossilController.extractionHit(current.Info.CellIndex, rating)
end

local function showResult(current: Active, result: Result)
	current.ResultShownAt = os.clock()
	local color = rarityColor(result.Rarity)
	local grade = ExtractionMath.grade(result.Condition)
	local line = string.format(
		'<font color="%s">%s</font>: <font color="%s">%s</font>, %d%%',
		hex(color),
		displayName(result.FossilId),
		hex(grade.Color),
		grade.Name,
		result.Condition
	)
	local sub = table.concat(result.Ratings, "  ·  ")
	if result.TimedOut then
		sub = "Out of time! Added to your collection anyway."
	end
	ExtractionView.showResult(line, sub)
	for index, rating in result.Ratings do
		ExtractionView.setPip(index, rating)
	end
	SoundPlayer.play(feel.ExtractedSound)
	CameraFx.shake(feel.ExtractedShake)
	FossilController.collect(current.Info.CellIndex)
	InventoryController.pulse()
end

-- One tap (click, touch or Space). Public so the input bindings and tests
-- share one path.
function ExtractionController.tap()
	local current = active
	if current == nil or not current.Opened then
		return
	end

	-- During the "Extracted!" moment a tap closes it early.
	if current.ResultShownAt > 0 then
		if os.clock() - current.ResultShownAt >= feel.MinResultTime then
			close()
		end
		return
	end

	local segment = current.Segment
	local now = serverNow()
	if segment == nil or current.AwaitingReply or now < current.FrozenUntil then
		return
	end
	if now < segment.StartAt then
		return -- the marker has not set off yet
	end

	local info = current.Info
	local position, direction = ExtractionMath.positionAt(segment, now)
	local rating =
		ExtractionMath.rate(position, info.Zones[segment.Hit], info.PerfectWidth, info.GoodWidth)
	current.Ratings[segment.Hit] = rating
	ExtractionView.setPip(segment.Hit, rating)
	playFeedback(current, rating, position)

	current.FrozenUntil = now + info.HitPause
	current.FrozenPos = position
	current.AwaitingReply = true
	current.LastTapAt = os.clock()
	local nextHit = segment.Hit + 1
	if nextHit <= info.Hits then
		current.Segment = {
			Hit = nextHit,
			StartAt = now + info.HitPause,
			StartPos = position,
			StartDir = direction,
			Speed = info.Speeds[nextHit],
		}
	else
		current.Segment = nil
		current.FinishedAt = os.clock()
	end
	Remotes.get("ExtractionTap"):FireServer(current.Id, now)
end

-- Server -> client. Arguments are checked before use.
local function onStarted(id: any, raw: any)
	if not isNumber(id) then
		return
	end
	local info = readInfo(raw)
	if info == nil then
		return
	end
	if active then
		close()
	end
	InventoryController.close()
	active = {
		Id = id,
		Info = info,
		Segment = {
			Hit = 1,
			StartAt = info.StartAt,
			StartPos = info.StartPos,
			StartDir = info.StartDir,
			Speed = info.Speeds[1],
		},
		Ratings = {},
		AwaitingReply = false,
		FrozenUntil = 0,
		FrozenPos = info.StartPos,
		Opened = false,
		LastTapAt = 0,
		Result = nil,
		ResultShownAt = 0,
		FinishedAt = 0,
	}
end

local function onTapResult(id: any, raw: any)
	local current = active
	if current == nil or id ~= current.Id or typeof(raw) ~= "table" then
		return
	end
	current.AwaitingReply = false
	local done = if isNumber(raw.Done) then raw.Done else #current.Ratings
	local nextSegment = readSegment(raw.Next)

	if raw.Ok == true then
		local hit, rating = raw.Hit, raw.Rating
		if isNumber(hit) and typeof(rating) == "string" and current.Ratings[hit] ~= rating then
			-- The server saw it differently: show the real result.
			current.Ratings[hit] = rating
			ExtractionView.setPip(hit, rating)
		end
		if isNumber(raw.Position) and serverNow() < current.FrozenUntil then
			current.FrozenPos = raw.Position
		end
	else
		-- Refused: forget the predicted hits the server has not counted.
		for index = #current.Ratings, done + 1, -1 do
			current.Ratings[index] = nil
			ExtractionView.setPip(index, nil)
		end
		current.FrozenUntil = 0
		if done < current.Info.Hits then
			current.FinishedAt = 0
		end
	end

	-- The server's segment is the truth for where the marker goes next.
	if done >= current.Info.Hits then
		current.Segment = nil
	elseif nextSegment then
		current.Segment = nextSegment
	end
end

local function onFinished(id: any, raw: any)
	local current = active
	if current == nil or id ~= current.Id or typeof(raw) ~= "table" then
		return
	end
	local ratings: { string } = {}
	if typeof(raw.Ratings) == "table" then
		for index, rating in raw.Ratings do
			if typeof(index) == "number" and typeof(rating) == "string" then
				ratings[index] = rating
			end
		end
	end
	local condition = raw.Condition
	current.Result = {
		FossilId = if typeof(raw.FossilId) == "string" then raw.FossilId else current.Info.FossilId,
		Rarity = if typeof(raw.Rarity) == "string" then raw.Rarity else current.Info.Rarity,
		Condition = if isNumber(condition) then math.clamp(math.round(condition), 1, 100) else 1,
		Ratings = ratings,
		TimedOut = raw.TimedOut == true,
	}
	current.Segment = nil
	current.AwaitingReply = false
	if current.FinishedAt == 0 then
		current.FinishedAt = os.clock()
	end
end

local function step(delta: number)
	ExtractionView.step(delta)
	local current = active
	if current == nil then
		return
	end
	local now = serverNow()
	local info = current.Info

	if not current.Opened then
		-- Let the reveal moment play first, but never past the marker's start.
		local due = now >= info.StartAt - feel.OpenLead
		if (due and not FossilController.isBusy()) or now >= info.StartAt or current.Result then
			open(current)
		else
			return
		end
	end

	-- The marker.
	local segment = current.Segment
	if now < current.FrozenUntil or segment == nil then
		ExtractionView.setMarker(current.FrozenPos)
	else
		local position = ExtractionMath.positionAt(segment, now)
		ExtractionView.setMarker(position)
		showZone(current, segment.Hit)
	end

	-- The ending.
	local result = current.Result
	local clock = os.clock()
	if result and current.ResultShownAt == 0 and now >= current.FrozenUntil then
		showResult(current, result)
		return
	end
	if current.ResultShownAt > 0 then
		if clock - current.ResultShownAt >= feel.ResultHoldTime then
			close()
		end
		return
	end

	-- An unanswered tap must not block the next one.
	if current.AwaitingReply and clock - current.LastTapAt > feel.MaxWaitForServer then
		current.AwaitingReply = false
	end
	-- Never leave the player stuck if the server stops answering.
	local waitedTooLong = current.FinishedAt > 0
		and clock - current.FinishedAt > feel.MaxWaitForServer
	if waitedTooLong or now > info.Deadline + feel.MaxWaitForServer then
		close()
	end
end

-- Public API ---------------------------------------------------------------

-- True while an extraction is running (or its result is on screen). Digging
-- is paused meanwhile.
function ExtractionController.isBusy(): boolean
	return active ~= nil
end

-- A read-only look at the running extraction, for debugging and tests.
function ExtractionController.getState(): { [string]: any }?
	local current = active
	if current == nil then
		return nil
	end
	return {
		Id = current.Id,
		Info = current.Info,
		Segment = current.Segment,
		Ratings = table.clone(current.Ratings),
		Opened = current.Opened,
		AwaitingReply = current.AwaitingReply,
		FrozenUntil = current.FrozenUntil,
		Result = current.Result,
		ResultShown = current.ResultShownAt > 0,
	}
end

function ExtractionController.Start()
	ExtractionView.build()
	for _, target in ExtractionView.getInputTargets() do
		target.InputBegan:Connect(function(input: InputObject)
			local kind = input.UserInputType
			if kind == Enum.UserInputType.MouseButton1 or kind == Enum.UserInputType.Touch then
				ExtractionController.tap()
			end
		end)
	end
	Remotes.get("ExtractionStarted").OnClientEvent:Connect(onStarted)
	Remotes.get("ExtractionTapResult").OnClientEvent:Connect(onTapResult)
	Remotes.get("ExtractionFinished").OnClientEvent:Connect(onFinished)
	RunService.RenderStepped:Connect(step)
end

return ExtractionController
