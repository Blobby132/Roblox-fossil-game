--!strict
--[[
	Remotes: every RemoteEvent in the game, created in code.

	The server calls Remotes.createAll() once at startup. After that, both
	sides call Remotes.get("Name"). Nothing is made by hand in Studio.

	Client -> server (the client only states intent; the server decides):
	  SwingRequest(seq: number, cellIndex: number)
	      "I swung at this cell of my plot."
	  EquipRequest(toolId: string)
	      "I want to hold this tool."
	  DebugRequest(action: string)
	      Developer shortcuts. Ignored unless DebugService allows the player.

	Server -> client:
	  SwingResult(seq: number, ok: boolean, code: string, value: number, defId: string?)
	      The server's ruling on one SwingRequest.
	      code:  Hit | Break | Clean | Reveal            (ok = true)
	             WrongTool | TooFar | Cooldown | NotExposed | NothingThere |
	             AlreadyRevealed | NoPlot | NoTool | NoCharacter   (ok = false)
	      value: cell health left (Hit, Break) or cleaning strokes done (Clean, Reveal)
	      defId: the fossil's id, only on Reveal
	  DebugFossils(cellIndices: { number })
	      Developer shortcut: where the buried fossils are.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

export type RemoteName =
	"SwingRequest"
	| "SwingResult"
	| "EquipRequest"
	| "DebugRequest"
	| "DebugFossils"

local FOLDER_NAME = "Remotes"

local NAMES: { RemoteName } = {
	"SwingRequest",
	"SwingResult",
	"EquipRequest",
	"DebugRequest",
	"DebugFossils",
}

local Remotes = {}

local cache: { [string]: RemoteEvent } = {}

-- Server only. Creates the folder and every RemoteEvent.
function Remotes.createAll()
	assert(RunService:IsServer(), "Remotes.createAll must run on the server")
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	for _, name in NAMES do
		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = folder
		cache[name] = remote
	end
	folder.Parent = ReplicatedStorage
end

function Remotes.get(name: RemoteName): RemoteEvent
	local cached = cache[name]
	if cached then
		return cached
	end
	assert(not RunService:IsServer(), "Remotes.createAll has not been called yet")
	local folder = ReplicatedStorage:WaitForChild(FOLDER_NAME)
	local remote = folder:WaitForChild(name) :: RemoteEvent
	cache[name] = remote
	return remote
end

return Remotes
