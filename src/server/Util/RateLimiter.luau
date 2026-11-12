--!strict
--[[
	RateLimiter: flood protection for RemoteEvents (a token bucket per player).

	Each player holds up to `burst` tokens and earns `perSecond` tokens every
	second. Each request costs one token; with none left, the request is dropped.
]]

local RateLimiter = {}
RateLimiter.__index = RateLimiter

type Bucket = {
	Tokens: number,
	LastRefill: number,
}

export type RateLimiter = typeof(setmetatable(
	{} :: {
		_perSecond: number,
		_burst: number,
		_buckets: { [Player]: Bucket },
	},
	RateLimiter
))

function RateLimiter.new(perSecond: number, burst: number): RateLimiter
	return setmetatable({
		_perSecond = perSecond,
		_burst = burst,
		_buckets = {},
	}, RateLimiter)
end

-- True if this player's request may go ahead.
function RateLimiter.allow(self: RateLimiter, player: Player): boolean
	local now = os.clock()
	local bucket = self._buckets[player]
	if bucket == nil then
		bucket = { Tokens = self._burst, LastRefill = now }
		self._buckets[player] = bucket
	end
	local earned = (now - bucket.LastRefill) * self._perSecond
	bucket.Tokens = math.min(self._burst, bucket.Tokens + earned)
	bucket.LastRefill = now
	if bucket.Tokens < 1 then
		return false
	end
	bucket.Tokens -= 1
	return true
end

-- Call when a player leaves.
function RateLimiter.forget(self: RateLimiter, player: Player)
	self._buckets[player] = nil
end

return RateLimiter
