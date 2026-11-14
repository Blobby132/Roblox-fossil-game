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
	  ExtractionTap(id: number, tapTime: number)
	      "I tapped during extraction `id` at this moment" (server time, from
	      Workspace:GetServerTimeNow()). Never a rating: the server works out
	      where the marker was.
	  InventoryRequest()
	      "Send me my whole inventory." Sent once when the client starts.

	Server -> client:
	  SwingResult(seq: number, ok: boolean, code: string, value: number, defId: string?)
	      The server's ruling on one SwingRequest.
	      code:  Hit | Break | Clean | Reveal            (ok = true)
	             WrongTool | TooFar | Cooldown | NotExposed | NothingThere |
	             AlreadyRevealed | NoPlot | NoTool | NoCharacter |
	             Extracting                              (ok = false)
	      value: cell health left (Hit, Break) or cleaning strokes done (Clean, Reveal)
	      defId: the fossil's id, only on Reveal
	  DebugFossils(cellIndices: { number })
	      Developer shortcut: where the buried fossils are.
	  ExtractionStarted(id: number, info: table)
	      An uncovered fossil's extraction has begun. info holds everything
	      needed to draw it: FossilId, Rarity, CellIndex, Hits, StartAt,
	      Deadline, Speeds, StartPos, StartDir, Zones, PerfectWidth, GoodWidth,
	      HitPause (see ExtractionService).
	  ExtractionTapResult(id: number, result: table)
	      The ruling on one ExtractionTap: Ok, Code (Perfect | Good | Miss, or
	      Finished | NotStarted | TooFast | NotYours), Hit, Rating, Position,
	      RatedAt, Done (hits rated so far) and Next (the segment the marker
	      is on now, or nil once every hit is rated).
	  ExtractionFinished(id: number, result: table)
	      The fossil is extracted: EntryId, FossilId, Rarity, Condition,
	      Ratings, TimedOut.
	  InventorySync(entries: { Entry })
	      The whole inventory (see InventoryLogic.Entry).
	  InventoryAdded(entry: Entry)
	      One new inventory entry.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

export type RemoteName =
	"SwingRequest"
	| "SwingResult"
	| "EquipRequest"
	| "DebugRequest"
	| "DebugFossils"
	| "ExtractionStarted"
	| "ExtractionTap"
	| "ExtractionTapResult"
	| "ExtractionFinished"
	| "InventoryRequest"
	| "InventorySync"
	| "InventoryAdded"

local FOLDER_NAME = "Remotes"

local NAMES: { RemoteName } = {
	"SwingRequest",
	"SwingResult",
	"EquipRequest",
	"DebugRequest",
	"DebugFossils",
	"ExtractionStarted",
	"ExtractionTap",
	"ExtractionTapResult",
	"ExtractionFinished",
	"InventoryRequest",
	"InventorySync",
	"InventoryAdded",
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
