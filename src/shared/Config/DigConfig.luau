--!strict
--[[
	DigConfig: input options and the limits the server enforces on digging.

	The server re-checks every swing. These numbers decide how much slack it
	gives honest players for network lag before it rejects a swing.
]]

local DigConfig = {
	-- PC: holding the mouse button keeps swinging. Mobile is always one tap per swing.
	HoldToRepeat = true,

	-- How far the click / tap ray reaches, in studs.
	MaxRayDistance = 300,

	-- Extra reach (studs) the server allows on top of a tool's Range, because
	-- the server sees the character slightly behind where the player sees it.
	RangeTolerance = 3,

	-- How early (seconds) a swing may arrive and still be accepted. Over time a
	-- player can never swing faster than the tool's Cooldown; this only forgives
	-- swings that bunch up on the network.
	CooldownTolerance = 0.25,

	-- Flood protection: requests per second the server will even look at.
	MaxRequestsPerSecond = 12,
	RequestBurst = 8,

	-- The client forgets a swing the server never answered after this long.
	PendingTimeout = 3,
}

return DigConfig
