--!strict
--[[
	Signal: a minimal event object for script-to-script messages on one side
	of the network (it does not cross between server and client).

	    local changed = Signal.new()
	    local connection = changed:Connect(function(value) print(value) end)
	    changed:Fire(42)
	    connection:Disconnect()
]]

local Signal = {}
Signal.__index = Signal

export type Callback = (...any) -> ()

export type Connection = {
	Disconnect: (self: Connection) -> (),
}

export type Signal = typeof(setmetatable({} :: { _callbacks: { Callback } }, Signal))

function Signal.new(): Signal
	return setmetatable({ _callbacks = {} }, Signal)
end

function Signal.Connect(self: Signal, callback: Callback): Connection
	table.insert(self._callbacks, callback)
	local callbacks = self._callbacks
	local connection: Connection = {
		Disconnect = function(_self: Connection)
			local index = table.find(callbacks, callback)
			if index then
				table.remove(callbacks, index)
			end
		end,
	}
	return connection
end

function Signal.Fire(self: Signal, ...: any)
	-- Copy first, so a callback that disconnects itself does not skip another.
	for _, callback in table.clone(self._callbacks) do
		task.spawn(callback, ...)
	end
end

return Signal
