--[[
	Harness: runs the game's real Luau code outside Roblox, using Lune.

	How it works:
	  1. `rojo build` turns the project into a place file, exactly as Studio
	     would see it.
	  2. Lune loads that place file. Its Roblox library provides real Instance
	     objects that check property names, enum names and value types, so a
	     typo such as `part.CanQuerry = false` fails here just as it would in
	     Studio.
	  3. The parts of the engine Lune does not have (events, remotes, input,
	     the camera, time) are replaced by small fakes defined in this file.
	     Time is virtual: tests advance the clock themselves, so they are fast
	     and repeatable.

	The server and the client run in the same process and share one DataModel.
	Each side gets its own copy of every module, as in a real game.

	This proves the code runs and the rules hold. It cannot judge how the game
	feels; that still needs a playtest in Studio.
]]

local fs = require("@lune/fs")
local luau = require("@lune/luau")
local process = require("@lune/process")
local roblox = require("@lune/roblox")

local Harness = {}

-- Errors raised inside game code that ran from an event or a timer.
Harness.errors = {} :: { string }

-- Everything the fakes record, for tests to assert on.
Harness.stats = {
	soundsPlayed = 0,
	particlesEmitted = 0,
	swingAnimations = 0,
}

------------------------------------------------------------------------------
-- Virtual time and a tiny task scheduler
------------------------------------------------------------------------------

local now = 100 -- virtual seconds
local timers = {} :: { { at: number, order: number, run: () -> () } }
local deferred = {} :: { () -> () }
local timerOrder = 0

local function report(err: any, thread: thread?)
	local message = tostring(err)
	if thread then
		message ..= "\n" .. debug.traceback(thread)
	end
	table.insert(Harness.errors, message)
end

-- Runs a function or resumes a thread, recording any error.
local function resume(target: any, ...: any): thread?
	local thread = if type(target) == "thread" then target else coroutine.create(target)
	local ok, err = coroutine.resume(thread, ...)
	if not ok then
		report(err, thread)
	end
	return thread
end

local function addTimer(delay: number, run: () -> ())
	timerOrder += 1
	table.insert(timers, { at = now + math.max(delay, 0), order = timerOrder, run = run })
end

local fakeTask = {}

function fakeTask.spawn(target: any, ...: any): thread?
	return resume(target, ...)
end

function fakeTask.defer(target: any, ...: any)
	local args = table.pack(...)
	table.insert(deferred, function()
		resume(target, table.unpack(args, 1, args.n))
	end)
end

function fakeTask.delay(delay: number, target: any, ...: any)
	local args = table.pack(...)
	addTimer(delay, function()
		resume(target, table.unpack(args, 1, args.n))
	end)
end

function fakeTask.wait(delay: number?): number
	local thread = coroutine.running()
	local started = now
	-- A bare task.wait() still takes one frame.
	addTimer(math.max(delay or 0, 1 / 60), function()
		resume(thread)
	end)
	coroutine.yield()
	return now - started
end

local fakeOs = setmetatable({
	clock = function(): number
		return now
	end,
}, { __index = os })

local function runDeferred()
	while #deferred > 0 do
		local batch = deferred
		deferred = {}
		for _, run in batch do
			run()
		end
	end
end

-- Moves the virtual clock forward, running timers that come due.
function Harness.advance(seconds: number)
	local target = now + seconds
	while true do
		local nextIndex: number? = nil
		for index, timer in timers do
			if timer.at <= target then
				local best = if nextIndex then timers[nextIndex] else nil
				if
					best == nil
					or timer.at < best.at
					or (timer.at == best.at and timer.order < best.order)
				then
					nextIndex = index
				end
			end
		end
		if nextIndex == nil then
			break
		end
		local timer = table.remove(timers, nextIndex)
		now = math.max(now, timer.at)
		timer.run()
		runDeferred()
	end
	now = target
	runDeferred()
end

function Harness.now(): number
	return now
end

------------------------------------------------------------------------------
-- Fake signals (events)
------------------------------------------------------------------------------

local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ handlers = {}, waiting = {} }, Signal)
end

function Signal:Connect(handler)
	table.insert(self.handlers, handler)
	local handlers = self.handlers
	return {
		Disconnect = function()
			local index = table.find(handlers, handler)
			if index then
				table.remove(handlers, index)
			end
		end,
	}
end

function Signal:Wait()
	table.insert(self.waiting, coroutine.running())
	return coroutine.yield()
end

function Signal:Fire(...)
	for _, handler in table.clone(self.handlers) do
		resume(handler, ...)
	end
	local waiting = self.waiting
	self.waiting = {}
	for _, thread in waiting do
		resume(thread, ...)
	end
end

Harness.Signal = Signal

-- One fake signal per (instance, event name).
local signals = {} :: { [any]: { [string]: any } }

local function signalFor(instance: any, name: string)
	local byName = signals[instance]
	if byName == nil then
		byName = {}
		signals[instance] = byName
	end
	local signal = byName[name]
	if signal == nil then
		signal = Signal.new()
		byName[name] = signal
	end
	return signal
end

Harness.signalFor = signalFor

local function implementEvent(className: string, eventName: string)
	roblox.implementProperty(className, eventName, function(instance)
		return signalFor(instance, eventName)
	end)
end

------------------------------------------------------------------------------
-- Fake engine state
------------------------------------------------------------------------------

local game: any = nil
local side = "Server" -- which side's code is running right now
local localPlayer: any = nil
local players = {} :: { any }

-- Remote messages wait in a queue until the test delivers them, like a network.
local toServer = {} :: { { remote: any, player: any, args: any } }
local toClient = {} :: { { remote: any, args: any } }

-- What the next Workspace:Raycast call returns (set by the test).
Harness.raycastResult = nil :: any
Harness.mouseLocation = roblox.Vector2.new(400, 300)
Harness.lastInputType = roblox.Enum.UserInputType.MouseButton1
local renderSteps = {} :: { [string]: (number) -> () }

-- Lune's instances are plain data: nothing fills in the values the engine
-- would compute. Two things need help.
--   * A few properties have no starting value, so they are given one here.
--   * Position and CFrame are stored separately. syncPositions() copies
--     whichever one changed onto the other, as the engine would.
local trackedParts = {} :: { any }
local knownPlacement = {} :: { [any]: { cframe: any, position: any } }

local function newInstance(className: string, parent: any?): any
	local instance = roblox.Instance.new(className)
	if instance:IsA("BasePart") then
		instance.Position = roblox.Vector3.zero
		table.insert(trackedParts, instance)
	elseif className == "Sound" then
		instance.IsPlaying = false
	elseif className == "Humanoid" then
		instance.Health = 100
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

local function syncPositions()
	local zero = roblox.Vector3.zero
	for index = #trackedParts, 1, -1 do
		local part = trackedParts[index]
		if part.Parent == nil then
			-- Destroyed, or put away; stop tracking it.
			knownPlacement[part] = nil
			table.remove(trackedParts, index)
			continue
		end
		local cframe, position = part.CFrame, part.Position
		local known = knownPlacement[part]
		if known == nil then
			if position ~= cframe.Position then
				if cframe.Position == zero then
					part.CFrame = cframe.Rotation + position
				else
					part.Position = cframe.Position
				end
			end
		elseif cframe ~= known.cframe then
			part.Position = cframe.Position
		elseif position ~= known.position then
			part.CFrame = cframe.Rotation + position
		else
			continue
		end
		knownPlacement[part] = { cframe = part.CFrame, position = part.Position }
	end
end

-- Children and attributes seen at the last "replication", to detect changes.
local watchedChildren = {} :: { [any]: { [any]: boolean } }
local watchedAttributes = {} :: { [any]: { [string]: any } }

local function withSide(newSide: string, run: () -> ())
	local previous = side
	side = newSide
	run()
	side = previous
end

-- Which input devices the fake player has (as UserInputService reports them).
function Harness.setInputDevices(mouse: boolean, keyboard: boolean, touch: boolean)
	local UserInputService = game:GetService("UserInputService")
	UserInputService.MouseEnabled = mouse
	UserInputService.KeyboardEnabled = keyboard
	UserInputService.TouchEnabled = touch
end

local function installFakes()
	-- Events.
	implementEvent("Instance", "ChildAdded")
	implementEvent("Instance", "ChildRemoved")
	implementEvent("Players", "PlayerAdded")
	implementEvent("Players", "PlayerRemoving")
	implementEvent("Player", "CharacterAdded")
	implementEvent("RemoteEvent", "OnServerEvent")
	implementEvent("RemoteEvent", "OnClientEvent")
	implementEvent("RunService", "RenderStepped")
	implementEvent("RunService", "Heartbeat")
	implementEvent("UserInputService", "InputBegan")
	implementEvent("UserInputService", "InputEnded")
	implementEvent("UserInputService", "TouchTapInWorld")
	implementEvent("UserInputService", "WindowFocusReleased")
	implementEvent("GuiButton", "Activated")
	implementEvent("GuiObject", "InputBegan")

	-- Instance.
	roblox.implementMethod("Instance", "SimRemove", function(self)
		self.Parent = nil
	end)
	roblox.implementMethod("Instance", "SimClearChildren", function(self)
		for _, child in self:GetChildren() do
			child.Parent = nil
		end
	end)
	roblox.implementMethod("Instance", "WaitForChild", function(self, name, timeout)
		local child = self:FindFirstChild(name)
		if child == nil and timeout == nil then
			error(`WaitForChild("{name}") on {self:GetFullName()} would wait forever`, 2)
		end
		return child
	end)
	roblox.implementMethod("Instance", "GetAttributeChangedSignal", function(self, name)
		local seen = watchedAttributes[self]
		if seen == nil then
			seen = {}
			watchedAttributes[self] = seen
		end
		if seen[name] == nil then
			seen[name] = { value = self:GetAttribute(name) }
		end
		return signalFor(self, "Attribute:" .. name)
	end)

	roblox.implementMethod("Model", "PivotTo", function(self, cframe)
		local root = self:FindFirstChild("HumanoidRootPart")
		if root then
			root.CFrame = cframe
		end
	end)
	roblox.implementMethod("Model", "AddPersistentPlayer", function() end)
	roblox.implementMethod("Model", "RemovePersistentPlayer", function() end)
	roblox.implementMethod("Model", "GetPivot", function(self)
		local root = self:FindFirstChild("HumanoidRootPart")
		return if root then root.CFrame else roblox.CFrame.new()
	end)

	-- Players.
	roblox.implementMethod("Players", "GetPlayers", function()
		return table.clone(players)
	end)

	-- Characters.
	roblox.implementMethod("Humanoid", "EquipTool", function(self, tool)
		local character = self.Parent
		for _, child in character:GetChildren() do
			if child:IsA("Tool") and child ~= tool then
				child.Parent = nil
			end
		end
		tool.Parent = character
	end)

	-- Remotes.
	roblox.implementMethod("RemoteEvent", "FireServer", function(self, ...)
		table.insert(toServer, { remote = self, player = localPlayer, args = table.pack(...) })
	end)
	roblox.implementMethod("RemoteEvent", "FireClient", function(self, target, ...)
		-- Only the local player has a client in this simulation.
		if target == localPlayer then
			table.insert(toClient, { remote = self, args = table.pack(...) })
		end
	end)

	-- RunService.
	roblox.implementMethod("RunService", "IsServer", function()
		return side == "Server"
	end)
	roblox.implementMethod("RunService", "IsClient", function()
		return side == "Client"
	end)
	roblox.implementMethod("RunService", "IsStudio", function()
		return true
	end)
	roblox.implementMethod("RunService", "BindToRenderStep", function(_self, name, _priority, run)
		renderSteps[name] = run
	end)

	-- Workspace.
	roblox.implementMethod("Workspace", "GetServerTimeNow", function()
		return now + 1_000_000
	end)
	roblox.implementMethod("Workspace", "Raycast", function()
		return Harness.raycastResult
	end)

	-- Camera: the test decides what a click hits, so rays are placeholders.
	local function fakeRay()
		return roblox.Ray.new(roblox.Vector3.new(0, 100, 0), roblox.Vector3.new(0, -1, 0))
	end
	roblox.implementMethod("Camera", "ViewportPointToRay", fakeRay)
	roblox.implementMethod("Camera", "ScreenPointToRay", fakeRay)

	-- Input.
	roblox.implementMethod("UserInputService", "GetMouseLocation", function()
		return Harness.mouseLocation
	end)
	roblox.implementMethod("UserInputService", "GetLastInputType", function()
		return Harness.lastInputType
	end)
	Harness.setInputDevices(true, true, false)

	-- Sound, particles, tweens, misc.
	roblox.implementMethod("Sound", "Play", function()
		Harness.stats.soundsPlayed += 1
	end)
	roblox.implementMethod("Sound", "Stop", function() end)
	roblox.implementMethod("ParticleEmitter", "Emit", function(_self, count)
		Harness.stats.particlesEmitted += count or 1
	end)
	roblox.implementMethod("TweenService", "Create", function(_self, instance, _info, goals)
		return {
			Play = function()
				-- Jump straight to the goal. This still checks every property name.
				for property, value in goals do
					instance[property] = value
				end
			end,
		}
	end)
	roblox.implementMethod("ContentProvider", "PreloadAsync", function() end)
	roblox.implementMethod("StarterGui", "SetCoreGuiEnabled", function() end)

	-- ContextActionService: bound actions get first go at matching key presses.
	local function bind(name, handler, inputs)
		Harness.boundActions[name] = { handler = handler, inputs = inputs }
	end
	roblox.implementMethod(
		"ContextActionService",
		"BindAction",
		function(_self, name, handler, _button, ...)
			bind(name, handler, { ... })
		end
	)
	roblox.implementMethod(
		"ContextActionService",
		"BindActionAtPriority",
		function(_self, name, handler, _button, _priority, ...)
			bind(name, handler, { ... })
		end
	)
	roblox.implementMethod("ContextActionService", "UnbindAction", function(_self, name)
		Harness.boundActions[name] = nil
	end)
end

-- Actions bound through ContextActionService, by name.
Harness.boundActions = {} :: { [string]: { handler: any, inputs: { any } } }

------------------------------------------------------------------------------
-- Globals that game code expects but Lune does not provide
------------------------------------------------------------------------------

local fakeRandom = {}
fakeRandom.__index = fakeRandom

local FakeRandom = {
	new = function(seed: number?)
		if seed then
			math.randomseed(seed)
		end
		return setmetatable({}, fakeRandom)
	end,
}

function fakeRandom:NextNumber(min: number?, max: number?): number
	local low, high = min or 0, max or 1
	return low + math.random() * (high - low)
end

function fakeRandom:NextInteger(min: number, max: number): number
	return math.random(min, max)
end

function fakeRandom:NextUnitVector()
	local angle = math.random() * math.pi * 2
	local y = math.random() * 2 - 1
	local flat = math.sqrt(1 - y * y)
	return roblox.Vector3.new(math.cos(angle) * flat, y, math.sin(angle) * flat)
end

local function baseEnvironment()
	return {
		game = game,
		workspace = game:GetService("Workspace"),
		Instance = { new = newInstance },
		Enum = roblox.Enum,
		Vector2 = roblox.Vector2,
		Vector3 = roblox.Vector3,
		CFrame = roblox.CFrame,
		Color3 = roblox.Color3,
		UDim = roblox.UDim,
		UDim2 = roblox.UDim2,
		Ray = roblox.Ray,
		NumberRange = roblox.NumberRange,
		NumberSequence = roblox.NumberSequence,
		ColorSequence = roblox.ColorSequence,
		Random = FakeRandom,
		RaycastParams = {
			new = function()
				return {}
			end,
		},
		TweenInfo = {
			new = function(...)
				return { ... }
			end,
		},
		task = fakeTask,
		os = fakeOs,
		warn = function(...)
			print("[warn]", ...)
		end,
	}
end

------------------------------------------------------------------------------
-- Loading the project
------------------------------------------------------------------------------

-- In Roblox, a script can still read a part after it has been destroyed (a
-- client does exactly that when the server removes a part). Lune instead
-- makes a destroyed instance unusable at once, and its Destroy cannot be
-- replaced. So game code is loaded with Destroy swapped for "remove from the
-- parent", which is what the game relies on. Line numbers stay the same.
local function prepare(source: string): string
	local prepared = string.gsub(source, ":Destroy%(%)", ":SimRemove()")
	prepared = string.gsub(prepared, ":ClearAllChildren%(%)", ":SimClearChildren()")
	return prepared
end

-- Builds the project with Rojo and loads it. Call once per test file.
function Harness.build()
	fs.writeDir("build")
	local result =
		process.exec("rojo", { "build", "default.project.json", "-o", "build/test.rbxl" })
	if not result.ok then
		error("rojo build failed:\n" .. result.stderr .. result.stdout)
	end
	game = roblox.deserializePlace(fs.readFile("build/test.rbxl"))
	installFakes()
	return game
end

-- A `require` for one side (server or client), with its own module cache.
function Harness.newRequire(forSide: string)
	local cache = {} :: { [any]: any }
	local loading = {} :: { [any]: boolean }
	local base = baseEnvironment()

	local function requireModule(module: any)
		if typeof(module) ~= "Instance" then
			error("require() was given " .. typeof(module) .. ", not a ModuleScript", 2)
		end
		local cached = cache[module]
		if cached ~= nil then
			return cached.value
		end
		if loading[module] then
			error("circular require of " .. module:GetFullName(), 2)
		end
		loading[module] = true

		local environment = table.clone(base)
		environment.script = module
		environment.require = requireModule
		local chunk = luau.load(prepare(module.Source), {
			debugName = module:GetFullName(),
			environment = environment,
		})
		local value
		withSide(forSide, function()
			value = chunk()
		end)
		loading[module] = nil
		cache[module] = { value = value }
		return value
	end

	return requireModule
end

-- Runs a Script or LocalScript from the place (for example the Main scripts).
function Harness.runScript(script: any, forSide: string, requireModule: any)
	local environment = table.clone(baseEnvironment())
	environment.script = script
	environment.require = requireModule
	local chunk = luau.load(prepare(script.Source), {
		debugName = script:GetFullName(),
		environment = environment,
	})
	withSide(forSide, function()
		resume(chunk)
	end)
	runDeferred()
end

------------------------------------------------------------------------------
-- Driving the simulation
------------------------------------------------------------------------------

-- Adds a player to the game, as if they had just joined.
function Harness.addPlayer(name: string, userId: number)
	local Players = game:GetService("Players")
	local player = newInstance("Player")
	player.Name = name
	player.UserId = userId
	newInstance("Backpack", player)
	newInstance("PlayerGui", player)
	player.Parent = Players
	table.insert(players, player)
	if localPlayer == nil then
		localPlayer = player
		Players.LocalPlayer = player
	end
	withSide("Server", function()
		signalFor(Players, "PlayerAdded"):Fire(player)
	end)
	runDeferred()
	return player
end

-- Removes a player from the game, as if they had just left.
function Harness.removePlayer(player: any)
	local Players = game:GetService("Players")
	withSide("Server", function()
		signalFor(Players, "PlayerRemoving"):Fire(player)
	end)
	runDeferred()
	local index = table.find(players, player)
	if index then
		table.remove(players, index)
	end
	player.Parent = nil
end

-- Gives a player a character standing at `position`.
function Harness.spawnCharacter(player: any, position: any)
	local character = newInstance("Model")
	character.Name = player.Name
	newInstance("Humanoid", character)
	local root = newInstance("Part")
	root.Name = "HumanoidRootPart"
	root.CFrame = roblox.CFrame.new(position)
	root.Parent = character
	character.Parent = game:GetService("Workspace")
	player.Character = character
	syncPositions()
	withSide("Server", function()
		signalFor(player, "CharacterAdded"):Fire(character)
	end)
	runDeferred()
	return character
end

-- Delivers queued client -> server messages.
function Harness.deliverToServer()
	syncPositions()
	local batch = toServer
	toServer = {}
	withSide("Server", function()
		for _, message in batch do
			signalFor(message.remote, "OnServerEvent"):Fire(
				message.player,
				table.unpack(message.args, 1, message.args.n)
			)
		end
	end)
	runDeferred()
end

-- Delivers queued server -> client messages. Returns them, for assertions.
function Harness.deliverToClient()
	syncPositions()
	local batch = toClient
	toClient = {}
	withSide("Client", function()
		for _, message in batch do
			signalFor(message.remote, "OnClientEvent"):Fire(
				table.unpack(message.args, 1, message.args.n)
			)
		end
	end)
	runDeferred()
	return batch
end

-- Throws away every queued message in both directions (a lost connection).
function Harness.dropMessages()
	toServer = {}
	toClient = {}
end

-- Sends a raw message to the server as the local player (for exploit tests).
function Harness.fireServer(remoteName: string, ...: any)
	local remote = game:GetService("ReplicatedStorage").Remotes:FindFirstChild(remoteName)
	table.insert(toServer, { remote = remote, player = localPlayer, args = table.pack(...) })
end

-- Starts watching a folder's children, so ChildAdded / ChildRemoved can fire.
function Harness.watchChildren(instance: any)
	if watchedChildren[instance] == nil then
		local seen = {}
		for _, child in instance:GetChildren() do
			seen[child] = true
		end
		watchedChildren[instance] = seen
	end
end

-- "Replicates": fires the child and attribute events for everything that
-- changed since the last call.
function Harness.replicate()
	syncPositions()
	withSide("Client", function()
		for instance, seen in watchedChildren do
			local current = {}
			for _, child in instance:GetChildren() do
				current[child] = true
			end
			for child in seen do
				if not current[child] then
					seen[child] = nil
					signalFor(instance, "ChildRemoved"):Fire(child)
				end
			end
			for child in current do
				if not seen[child] then
					seen[child] = true
					signalFor(instance, "ChildAdded"):Fire(child)
				end
			end
		end
		for instance, seen in watchedAttributes do
			for name, entry in seen do
				local value = instance:GetAttribute(name)
				if value ~= entry.value then
					entry.value = value
					signalFor(instance, "Attribute:" .. name):Fire()
				end
			end
		end
	end)
	runDeferred()
end

-- One rendered frame on the client.
function Harness.frame(delta: number?)
	local step = delta or 1 / 60
	syncPositions()
	Harness.advance(step)
	withSide("Client", function()
		signalFor(game:GetService("RunService"), "RenderStepped"):Fire(step)
		for _, run in renderSteps do
			resume(run, step)
		end
	end)
	runDeferred()
end

-- A full network round trip plus a frame: requests reach the server, changes
-- and replies reach the client. `repliesFirst` swaps the order in which
-- replicated changes and remote replies arrive, because the real engine does
-- not promise either order.
function Harness.roundTrip(repliesFirst: boolean?)
	Harness.deliverToServer()
	local replies
	if repliesFirst then
		replies = Harness.deliverToClient()
		Harness.replicate()
	else
		Harness.replicate()
		replies = Harness.deliverToClient()
	end
	Harness.frame()
	return replies
end

-- Fires a fake input event on the client.
function Harness.input(eventName: string, ...: any)
	local UserInputService = game:GetService("UserInputService")
	local args = table.pack(...)
	syncPositions()
	withSide("Client", function()
		signalFor(UserInputService, eventName):Fire(table.unpack(args, 1, args.n))
	end)
	runDeferred()
end

-- A key press. As in the engine, an action bound to the key through
-- ContextActionService runs first; if it sinks the input, other scripts see
-- the press as already processed.
function Harness.keyPress(keyCode: any)
	local input = {
		UserInputType = roblox.Enum.UserInputType.Keyboard,
		UserInputState = roblox.Enum.UserInputState.Begin,
		KeyCode = keyCode,
	}
	local sunk = false
	syncPositions()
	withSide("Client", function()
		for name, action in table.clone(Harness.boundActions) do
			if table.find(action.inputs, keyCode) then
				local thread = coroutine.create(action.handler)
				local ok, result = coroutine.resume(thread, name, input.UserInputState, input)
				if not ok then
					report(result, thread)
				elseif result == roblox.Enum.ContextActionResult.Sink then
					sunk = true
				end
			end
		end
	end)
	runDeferred()
	Harness.input("InputBegan", input, sunk)
end

-- A click or tap that lands on a GuiObject (fires its InputBegan).
--   inputType  Enum.UserInputType.MouseButton1 (default) or Touch
function Harness.guiInput(guiObject: any, inputType: any?)
	syncPositions()
	withSide("Client", function()
		signalFor(guiObject, "InputBegan"):Fire({
			UserInputType = inputType or roblox.Enum.UserInputType.MouseButton1,
			UserInputState = roblox.Enum.UserInputState.Begin,
		})
	end)
	runDeferred()
end

-- A left click on whatever Harness.raycastResult currently points at.
function Harness.click()
	local click = {
		UserInputType = roblox.Enum.UserInputType.MouseButton1,
	}
	Harness.input("InputBegan", click, false)
	Harness.input("InputEnded", click, false)
end

-- A click or tap on a GuiButton.
function Harness.press(button: any)
	syncPositions()
	withSide("Client", function()
		signalFor(button, "Activated"):Fire()
	end)
	runDeferred()
end

-- A screen tap on whatever Harness.raycastResult currently points at.
function Harness.tap()
	Harness.input("TouchTapInWorld", roblox.Vector2.new(200, 150), false)
end

------------------------------------------------------------------------------
-- A very small test runner
------------------------------------------------------------------------------

local failures = 0
local passes = 0

function Harness.test(name: string, run: () -> ())
	local errorsBefore = #Harness.errors
	local ok, err = xpcall(run, function(message)
		return debug.traceback(tostring(message), 2)
	end)
	-- An error inside an event handler or timer does not stop the test by
	-- itself, so count it as a failure here.
	if #Harness.errors > errorsBefore then
		local raised = table.concat(Harness.errors, "\n", errorsBefore + 1)
		err = (if ok then "" else tostring(err) .. "\n") .. "game code raised an error:\n" .. raised
		ok = false
	end
	if ok then
		passes += 1
		print("  ok    " .. name)
	else
		failures += 1
		print("  FAIL  " .. name)
		print("        " .. string.gsub(tostring(err), "\n", "\n        "))
	end
end

function Harness.expect(condition: any, message: string)
	if not condition then
		error(message, 2)
	end
end

function Harness.expectEqual(actual: any, expected: any, message: string)
	if actual ~= expected then
		error(`{message}: expected {tostring(expected)}, got {tostring(actual)}`, 2)
	end
end

function Harness.finish()
	print(`\n{passes} passed, {failures} failed`)
	process.exit(if failures > 0 then 1 else 0)
end

return Harness
