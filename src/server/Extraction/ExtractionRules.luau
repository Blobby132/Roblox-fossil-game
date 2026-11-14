--!strict
--[[
	ExtractionRules: the authoritative state of one extraction, and what a tap
	does to it.

	Plain data and pure logic, like PlotRules: no players, no network, and
	times are passed in. ExtractionService turns the outcomes into messages.

	What the server decides, and the client never gets a say in:
	  * the marker's speed for every hit, where it starts and which way it goes
	  * where each hit's zone is, and how wide
	  * when the marker sets off
	The client only reports WHEN the player tapped. The server works out where
	the marker was at that moment and rates it.

	A tap's timestamp is trusted only within a small window around when it
	arrived (Server.LagAllowance behind, Server.ClockTolerance ahead). Outside
	that window it is moved to the nearest edge, so an old or future timestamp
	can never pick a better moment than an honest tap sent on time.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local ExtractionConfig = require(Shared.Config.ExtractionConfig)
local ExtractionMath = require(Shared.Extraction.ExtractionMath)

export type Setup = {
	Rarity: string,
	Hits: number,
	StartAt: number, -- server time the marker first sets off
	Deadline: number, -- server time the extraction finishes by itself
	Speeds: { number }, -- marker speed for each hit
	StartPos: number,
	StartDir: number,
	Zones: { number }, -- zone centre for each hit
	PerfectWidth: number,
	GoodWidth: number,
	HitPause: number,
}

export type State = {
	Setup: Setup,
	Segment: ExtractionMath.Segment?, -- the segment waiting for the next tap; nil once finished
	Ratings: { ExtractionMath.Rating },
	Points: { number },
	LastArrival: number, -- when the last accepted tap arrived
	Finished: boolean,
	TimedOut: boolean,
}

export type TapOutcome = {
	Ok: boolean,
	-- Ok:     Perfect | Good | Miss
	-- Not ok: Finished | NotStarted | TooFast
	Code: string,
	Hit: number?, -- which tap this was
	Rating: ExtractionMath.Rating?,
	Position: number?, -- where the marker stopped
	RatedAt: number?, -- the moment the server rated (the timestamp after any adjustment)
}

local ExtractionRules = {}

local function fail(code: string): TapOutcome
	return { Ok = false, Code = code }
end

-- A new extraction for a fossil of this rarity.
--   now         server time right now
--   nextNumber  random number from 0 (inclusive) to 1 (exclusive)
function ExtractionRules.new(rarity: string, now: number, nextNumber: () -> number): State
	local hits = math.max(1, ExtractionConfig.Hits)
	local perfectWidth, goodWidth = ExtractionMath.zoneWidthsFor(rarity)
	local speeds = ExtractionMath.speedsFor(rarity)
	local startPos = nextNumber()
	local startDir = if nextNumber() < 0.5 then 1 else -1

	local zones: { number } = {}
	local reference = startPos
	for hit = 1, hits do
		zones[hit] = ExtractionMath.pickZone(nextNumber, reference, goodWidth)
		reference = zones[hit]
	end

	local startAt = now + ExtractionConfig.StartDelay
	local setup: Setup = {
		Rarity = rarity,
		Hits = hits,
		StartAt = startAt,
		Deadline = startAt + ExtractionConfig.Server.MaxDuration,
		Speeds = speeds,
		StartPos = startPos,
		StartDir = startDir,
		Zones = zones,
		PerfectWidth = perfectWidth,
		GoodWidth = goodWidth,
		HitPause = ExtractionConfig.HitPause,
	}
	return {
		Setup = setup,
		Segment = {
			Hit = 1,
			StartAt = startAt,
			StartPos = startPos,
			StartDir = startDir,
			Speed = speeds[1],
		},
		Ratings = {},
		Points = {},
		LastArrival = -math.huge,
		Finished = false,
		TimedOut = false,
	}
end

-- Rates one tap.
--   claimed  the moment the player says they tapped (server time)
--   arrival  the server time the tap arrived
function ExtractionRules.tap(state: State, claimed: number, arrival: number): TapOutcome
	local segment = state.Segment
	if state.Finished or segment == nil then
		return fail("Finished")
	end
	local limits = ExtractionConfig.Server
	if arrival - state.LastArrival < limits.MinTapInterval then
		return fail("TooFast")
	end

	local ratedAt =
		math.clamp(claimed, arrival - limits.LagAllowance, arrival + limits.ClockTolerance)
	if ratedAt < segment.StartAt - limits.ClockTolerance then
		-- The marker was not moving yet: still waiting to start, or paused
		-- after the previous hit.
		return fail(if segment.Hit == 1 then "NotStarted" else "TooFast")
	end
	ratedAt = math.max(ratedAt, segment.StartAt)

	local setup = state.Setup
	local position, direction = ExtractionMath.positionAt(segment, ratedAt)
	local rating, points =
		ExtractionMath.rate(position, setup.Zones[segment.Hit], setup.PerfectWidth, setup.GoodWidth)
	table.insert(state.Ratings, rating)
	table.insert(state.Points, points)
	state.LastArrival = arrival

	local nextHit = segment.Hit + 1
	if nextHit > setup.Hits then
		state.Finished = true
		state.Segment = nil
	else
		state.Segment = {
			Hit = nextHit,
			StartAt = ratedAt + setup.HitPause,
			StartPos = position,
			StartDir = direction,
			Speed = setup.Speeds[nextHit],
		}
	end

	return {
		Ok = true,
		Code = rating,
		Hit = segment.Hit,
		Rating = rating,
		Position = position,
		RatedAt = ratedAt,
	}
end

-- Time ran out: every hit not taken counts as the worst possible miss.
-- The fossil is still extracted.
function ExtractionRules.expire(state: State)
	if state.Finished then
		return
	end
	local worst = ExtractionConfig.Condition.Miss.Min
	while #state.Ratings < state.Setup.Hits do
		table.insert(state.Ratings, "Miss")
		table.insert(state.Points, worst)
	end
	state.Finished = true
	state.TimedOut = true
	state.Segment = nil
end

-- The fossil's condition (1-100) from the hits so far.
function ExtractionRules.condition(state: State): number
	return ExtractionMath.condition(state.Points)
end

return ExtractionRules
