--!strict
--[[
	ExtractionMath: the pure maths of the extraction minigame.

	Shared by both sides: the server rates every tap with it, and the client
	uses the same functions to draw the marker and predict the rating, so
	feedback is instant and normally matches the server exactly.

	The marker moves in "segments". A segment says where the marker starts,
	which way it is heading, how fast it goes and when it sets off. After each
	tap the next segment starts from where the marker stopped. Given a segment
	and a moment in time, the marker's position is fully determined.
]]

local ExtractionConfig = require(script.Parent.Parent.Config.ExtractionConfig)

export type Rating = "Perfect" | "Good" | "Miss"

export type Segment = {
	Hit: number, -- which tap this segment is waiting for (1 = first)
	StartAt: number, -- server time the marker sets off
	StartPos: number, -- 0-1 along the bar
	StartDir: number, -- 1 = moving right, -1 = moving left
	Speed: number, -- bar lengths per second
}

local ExtractionMath = {}

local function lerp(from: number, to: number, alpha: number): number
	return from + (to - from) * math.clamp(alpha, 0, 1)
end

-- Where the marker is at `time`, and which way it is moving (1 or -1).
-- Before the segment starts, the marker waits at its start position.
-- The marker bounces off both ends of the bar.
function ExtractionMath.positionAt(segment: Segment, time: number): (number, number)
	local elapsed = math.max(0, time - segment.StartAt)
	-- Unfold the bounces: travel along a line of length 2 and fold it back.
	local start = if segment.StartDir >= 0 then segment.StartPos else 2 - segment.StartPos
	local unfolded = (start + segment.Speed * elapsed) % 2
	if unfolded <= 1 then
		return unfolded, 1
	end
	return 2 - unfolded, -1
end

-- Rates a stop at `position` against a zone centred on `center`.
-- Returns the rating and the condition points it is worth.
function ExtractionMath.rate(
	position: number,
	center: number,
	perfectWidth: number,
	goodWidth: number
): (Rating, number)
	local condition = ExtractionConfig.Condition
	local distance = math.abs(position - center)
	local perfectHalf = perfectWidth / 2
	local goodHalf = math.max(goodWidth / 2, perfectHalf)

	if distance <= perfectHalf then
		local alpha = if perfectHalf > 0 then distance / perfectHalf else 0
		return "Perfect", lerp(condition.Perfect.Max, condition.Perfect.Min, alpha)
	end
	if distance <= goodHalf then
		local alpha = (distance - perfectHalf) / (goodHalf - perfectHalf)
		return "Good", lerp(condition.Good.Max, condition.Good.Min, alpha)
	end
	local alpha = (distance - goodHalf) / math.max(condition.MissFalloff, 1e-6)
	return "Miss", lerp(condition.Miss.Max, condition.Miss.Min, alpha)
end

-- The fossil's condition (1-100) from the points of every hit.
function ExtractionMath.condition(points: { number }): number
	local total = ExtractionConfig.Condition.Base
	for _, value in points do
		total += value
	end
	return math.clamp(math.round(total), 1, 100)
end

-- The named grade for a condition ("Excellent").
function ExtractionMath.grade(condition: number): ExtractionConfig.Grade
	local grades = ExtractionConfig.Grades
	for _, grade in grades do
		if condition >= grade.Min then
			return grade
		end
	end
	return grades[#grades]
end

-- "Ammonite: Excellent, 87%"
function ExtractionMath.describe(displayName: string, condition: number): string
	return `{displayName}: {ExtractionMath.grade(condition).Name}, {condition}%`
end

function ExtractionMath.modifiersFor(rarity: string): ExtractionConfig.RarityModifier
	local byRarity = ExtractionConfig.ByRarity
	return byRarity[rarity] or byRarity.Common or { SpeedScale = 1, ZoneScale = 1 }
end

-- Perfect and Good zone widths for a fossil of this rarity.
function ExtractionMath.zoneWidthsFor(rarity: string): (number, number)
	local zone = ExtractionConfig.Zone
	local scale = ExtractionMath.modifiersFor(rarity).ZoneScale
	local good = math.clamp(zone.GoodWidth * scale, 0.01, 1)
	local perfect = math.clamp(zone.PerfectWidth * scale, 0, good)
	return perfect, good
end

-- Marker speed for each hit, for a fossil of this rarity.
function ExtractionMath.speedsFor(rarity: string): { number }
	local perHit = ExtractionConfig.SpeedPerHit
	local base = ExtractionConfig.BaseSpeed * ExtractionMath.modifiersFor(rarity).SpeedScale
	local speeds: { number } = {}
	for hit = 1, ExtractionConfig.Hits do
		local multiplier = perHit[math.min(hit, #perHit)] or 1
		speeds[hit] = math.max(base * multiplier, 0.05)
	end
	return speeds
end

-- Picks a zone centre that keeps the whole Good band on the bar and, where
-- possible, sits at least Zone.MinShift away from `reference`.
-- nextNumber returns a random number from 0 (inclusive) to 1 (exclusive).
function ExtractionMath.pickZone(
	nextNumber: () -> number,
	reference: number,
	goodWidth: number
): number
	local zone = ExtractionConfig.Zone
	local low = math.min(goodWidth / 2 + zone.EdgeMargin, 0.5)
	local high = math.max(1 - goodWidth / 2 - zone.EdgeMargin, 0.5)

	-- Two allowed stretches: left of the reference, and right of it.
	local leftEnd = math.min(high, reference - zone.MinShift)
	local rightStart = math.max(low, reference + zone.MinShift)
	local leftLength = math.max(0, leftEnd - low)
	local rightLength = math.max(0, high - rightStart)
	local total = leftLength + rightLength
	if total <= 0 then
		-- Nowhere is far enough away: use whichever end is furthest.
		return if math.abs(low - reference) >= math.abs(high - reference) then low else high
	end
	local roll = nextNumber() * total
	if roll < leftLength then
		return low + roll
	end
	return rightStart + (roll - leftLength)
end

return ExtractionMath
