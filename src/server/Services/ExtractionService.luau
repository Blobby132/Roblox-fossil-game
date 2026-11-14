--!strict
--[[
	ExtractionService: runs the extraction minigame for each player.

	Uncovering a fossil (the final brush stroke) calls Begin. The server then:
	  1. sets up the extraction (ExtractionRules.new): marker speeds, start
	     position, zones and start time are all chosen here
	  2. tells the player with ExtractionStarted
	  3. rates each ExtractionTap (the client only sends WHEN it tapped)
	  4. once every hit is rated, or time runs out, works out the condition,
	     adds the fossil to the inventory and sends ExtractionFinished

	A player has at most one extraction at a time, and a fossil can only ever
	be extracted once. While a player is extracting, DigService refuses their
	swings, and their plot's refill waits (PlotService.SetRefillHeld).

	Every ExtractionTap is checked, in order:
	  1. well formed: a whole-number id and a finite timestamp
	  2. not flooding (rate limit, as in DigService)
	  3. the id is this player's own running extraction
	  4. the rules (ExtractionRules.tap): not finished (extra taps), not too
	     fast, the marker is moving
	and always answered with ExtractionTapResult, so the client can correct
	its prediction.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local ExtractionConfig = require(Shared.Config.ExtractionConfig)
local ExtractionMath = require(Shared.Extraction.ExtractionMath)
local FossilConfig = require(Shared.Config.FossilConfig)
local Remotes = require(Shared.Remotes)

local Server = script.Parent.Parent
local AnalyticsService = require(script.Parent.AnalyticsService)
local ExtractionRules = require(Server.Extraction.ExtractionRules)
local FossilService = require(script.Parent.FossilService)
local InventoryService = require(script.Parent.InventoryService)
local PlotService = require(script.Parent.PlotService)
local RateLimiter = require(Server.Util.RateLimiter)

export type Extraction = {
	Id: number,
	Player: Player,
	Plot: PlotService.Plot,
	FossilIndex: number,
	CellIndex: number,
	Generation: number, -- the plot's generation when the fossil was uncovered
	FossilId: string,
	FoundAt: number, -- os.time()
	State: ExtractionRules.State,
}

local ExtractionService = {}

local limits = ExtractionConfig.Server
local limiter = RateLimiter.new(limits.MaxRequestsPerSecond, limits.RequestBurst)
local random = Random.new()

local byPlayer: { [Player]: Extraction } = {}
local byId: { [number]: Extraction } = {}
local lastId = 0

local function segmentPayload(segment: ExtractionMath.Segment?): { [string]: number }?
	if segment == nil then
		return nil
	end
	return {
		Hit = segment.Hit,
		StartAt = segment.StartAt,
		StartPos = segment.StartPos,
		StartDir = segment.StartDir,
		Speed = segment.Speed,
	}
end

-- What the client needs to draw and predict the minigame.
local function startPayload(extraction: Extraction): { [string]: any }
	local setup = extraction.State.Setup
	return {
		FossilId = extraction.FossilId,
		Rarity = setup.Rarity,
		CellIndex = extraction.CellIndex,
		Hits = setup.Hits,
		StartAt = setup.StartAt,
		Deadline = setup.Deadline,
		Speeds = table.clone(setup.Speeds),
		StartPos = setup.StartPos,
		StartDir = setup.StartDir,
		Zones = table.clone(setup.Zones),
		PerfectWidth = setup.PerfectWidth,
		GoodWidth = setup.GoodWidth,
		HitPause = setup.HitPause,
	}
end

local function forget(extraction: Extraction)
	if byPlayer[extraction.Player] == extraction then
		byPlayer[extraction.Player] = nil
	end
	byId[extraction.Id] = nil
	PlotService.SetRefillHeld(extraction.Plot, false)
end

-- Every hit is rated (or time ran out): the fossil goes into the inventory.
local function finish(extraction: Extraction)
	if byId[extraction.Id] ~= extraction then
		return
	end
	local player = extraction.Player
	local state = extraction.State
	local condition = ExtractionRules.condition(state)
	forget(extraction)

	local entry = InventoryService.Add(player, extraction.FossilId, condition, extraction.FoundAt)
	FossilService.MarkExtracted(
		extraction.Plot,
		extraction.FossilIndex,
		extraction.Generation,
		limits.RemovePartDelay
	)
	AnalyticsService.LogOnboardingStep(player, "FirstExtraction")

	Remotes.get("ExtractionFinished"):FireClient(player, extraction.Id, {
		EntryId = if entry then entry.Id else 0,
		FossilId = extraction.FossilId,
		Rarity = state.Setup.Rarity,
		Condition = condition,
		Ratings = table.clone(state.Ratings),
		TimedOut = state.TimedOut,
	})
end

-- Starts extracting a fossil the player has just uncovered. Returns false if
-- it cannot start (the player is already extracting, the fossil is not
-- uncovered, or it has been extracted before).
function ExtractionService.Begin(
	player: Player,
	plot: PlotService.Plot,
	fossilIndex: number
): boolean
	local state = plot.State
	local fossil = state and state.Fossils[fossilIndex]
	if byPlayer[player] or plot.Owner ~= player or fossil == nil then
		return false
	end
	if fossil.Stage ~= "Revealed" or fossil.ExtractionStarted then
		return false
	end
	local def = FossilConfig.ById[fossil.DefId]
	if def == nil then
		return false
	end
	fossil.ExtractionStarted = true

	lastId += 1
	local now = Workspace:GetServerTimeNow()
	local extraction: Extraction = {
		Id = lastId,
		Player = player,
		Plot = plot,
		FossilIndex = fossilIndex,
		CellIndex = fossil.CellIndex,
		Generation = plot.Generation,
		FossilId = def.Id,
		FoundAt = os.time(),
		State = ExtractionRules.new(def.Rarity, now, function(): number
			return random:NextNumber()
		end),
	}
	byPlayer[player] = extraction
	byId[extraction.Id] = extraction
	PlotService.SetRefillHeld(plot, true)

	Remotes.get("ExtractionStarted"):FireClient(player, extraction.Id, startPayload(extraction))

	-- A player who walks away still gets the fossil once time runs out.
	task.delay(extraction.State.Setup.Deadline - now, function()
		if byId[extraction.Id] == extraction then
			ExtractionRules.expire(extraction.State)
			finish(extraction)
		end
	end)
	return true
end

-- True while the player has an extraction running.
function ExtractionService.IsActive(player: Player): boolean
	return byPlayer[player] ~= nil
end

-- The player's running extraction, or nil (for debugging and tests).
function ExtractionService.GetActive(player: Player): Extraction?
	return byPlayer[player]
end

local function reply(player: Player, id: number, result: { [string]: any })
	Remotes.get("ExtractionTapResult"):FireClient(player, id, result)
end

-- Client -> server. Every argument is untrusted.
local function onExtractionTap(player: Player, id: any, claimed: any)
	if typeof(id) ~= "number" or typeof(claimed) ~= "number" then
		return
	end
	if id ~= id or id % 1 ~= 0 or claimed ~= claimed or math.abs(claimed) == math.huge then
		return
	end
	if not limiter:allow(player) then
		return
	end

	local extraction = byId[id]
	if extraction == nil or extraction.Player ~= player then
		-- Not this player's (or long finished). Say nothing about it.
		reply(player, id, { Ok = false, Code = "NotYours" })
		return
	end

	local state = extraction.State
	local outcome = ExtractionRules.tap(state, claimed, Workspace:GetServerTimeNow())
	reply(player, id, {
		Ok = outcome.Ok,
		Code = outcome.Code,
		Hit = outcome.Hit,
		Rating = outcome.Rating,
		Position = outcome.Position,
		RatedAt = outcome.RatedAt,
		Done = #state.Ratings,
		Next = segmentPayload(state.Segment),
	})
	if state.Finished then
		finish(extraction)
	end
end

function ExtractionService.Start()
	Remotes.get("ExtractionTap").OnServerEvent:Connect(onExtractionTap)
	Players.PlayerRemoving:Connect(function(player: Player)
		local extraction = byPlayer[player]
		if extraction then
			-- No saving yet, so an unfinished extraction is simply dropped.
			forget(extraction)
		end
		limiter:forget(player)
	end)
end

return ExtractionService
