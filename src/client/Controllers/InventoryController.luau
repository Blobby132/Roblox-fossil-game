--!strict
--[[
	InventoryController: this player's copy of their inventory, and the HUD
	button and panel that show it (InventoryView).

	The server owns the inventory. On start this client asks for the whole
	list (InventoryRequest); after that the server sends each new find
	(InventoryAdded). Every entry from the network is checked before use.

	The panel lists finds rarest first, then by condition, and shows how far
	along each fossil set is ("Triceratops 1/3"). Finds added since the panel
	was last opened are tagged NEW.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local InventoryLogic = require(Shared.Inventory.InventoryLogic)
local Remotes = require(Shared.Remotes)
local Signal = require(Shared.Util.Signal)

local Client = script.Parent.Parent
local InventoryView = require(Client.Ui.InventoryView)
local SoundPlayer = require(Client.Effects.SoundPlayer)

local InventoryController = {}

InventoryController.Changed = Signal.new() -- ()

local entries: { InventoryLogic.Entry } = {}
local newIds: { [number]: boolean } = {}

local function render()
	InventoryView.render(
		InventoryLogic.sorted(entries),
		newIds,
		InventoryLogic.allSetProgress(entries)
	)
end

local function refresh()
	InventoryView.setCount(#entries)
	if InventoryView.isOpen() then
		render()
	end
	InventoryController.Changed:Fire()
end

local function indexOf(id: number): number?
	for index, entry in entries do
		if entry.Id == id then
			return index
		end
	end
	return nil
end

-- Server -> client: the whole list.
local function onSync(raw: any)
	if typeof(raw) ~= "table" then
		return
	end
	local fresh: { InventoryLogic.Entry } = {}
	for _, value in raw do
		local entry = InventoryLogic.validate(value)
		if entry then
			table.insert(fresh, entry)
		end
	end
	entries = fresh
	refresh()
end

-- Server -> client: one new find.
local function onAdded(raw: any)
	local entry = InventoryLogic.validate(raw)
	if entry == nil or indexOf(entry.Id) then
		return
	end
	table.insert(entries, entry)
	newIds[entry.Id] = true
	refresh()
end

-- Public API ---------------------------------------------------------------

-- A sorted copy of every find (rarest, then best condition first).
function InventoryController.getEntries(): { InventoryLogic.Entry }
	return InventoryLogic.sorted(entries)
end

function InventoryController.isOpen(): boolean
	return InventoryView.isOpen()
end

function InventoryController.open()
	if InventoryView.isOpen() then
		return
	end
	render()
	InventoryView.open()
	SoundPlayer.play("InventoryOpen")
end

function InventoryController.close()
	if not InventoryView.isOpen() then
		return
	end
	InventoryView.close()
	-- The player has seen them now.
	table.clear(newIds)
end

function InventoryController.toggle()
	if InventoryView.isOpen() then
		InventoryController.close()
	else
		InventoryController.open()
	end
end

-- Bounces the HUD button (called at the "Extracted!" moment).
function InventoryController.pulse()
	InventoryView.pulse()
end

function InventoryController.Start()
	InventoryView.build(InventoryController.toggle, InventoryController.close)
	InventoryView.setCount(0)
	Remotes.get("InventorySync").OnClientEvent:Connect(onSync)
	Remotes.get("InventoryAdded").OnClientEvent:Connect(onAdded)
	Remotes.get("InventoryRequest"):FireServer()
end

return InventoryController
