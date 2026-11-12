--!strict
--[[
	TimeScale: the speed at which this player's effects run. 1 is normal.

	Used for the brief slow motion when a fossil is uncovered. It only slows
	local effects (crumble pieces, particles, cell reactions). The server, other
	players and the character itself keep running at normal speed.
]]

local TimeScale = {}

local current = 1
local slowScale = 1
local holdUntil = 0
local recoverTime = 0.2

function TimeScale.get(): number
	return current
end

-- Drop to `scale` at once, hold it for `hold` seconds, then ease back to 1.
function TimeScale.slow(scale: number, hold: number, recover: number)
	slowScale = math.clamp(scale, 0.01, 1)
	current = slowScale
	holdUntil = os.clock() + hold
	recoverTime = math.max(recover, 0.01)
end

-- Keep the current slow motion going for `extra` more seconds.
function TimeScale.extend(extra: number)
	if current >= 1 then
		return
	end
	holdUntil = math.max(holdUntil, os.clock()) + extra
	current = slowScale
end

-- The moment (os.clock) the slow motion stops holding and starts to recover.
function TimeScale.holdEndsAt(): number
	return holdUntil
end

function TimeScale.cancel()
	holdUntil = 0
	current = 1
end

-- Call once per frame with the real frame time. Returns the scaled frame time.
function TimeScale.step(realDelta: number): number
	if current < 1 and os.clock() >= holdUntil then
		current = math.min(1, current + (1 - slowScale) * realDelta / recoverTime)
	end
	return realDelta * current
end

return TimeScale
