--!strict
--[[
	DigController: turns clicks and taps into swings.

	What the client does:
	  1. Finds what the click or tap hit in the player's own plot.
	  2. PREDICTS the result with the same rules the server uses (DigRules),
	     and plays the feedback immediately, so digging never waits on the
	     network.
	  3. Sends the server one small message: "I swung at cell N".

	What the client does NOT do: decide anything. The server re-checks the
	swing and answers with SwingResult. If it disagrees (rare: lag, or a
	tampered client), the prediction is undone here.

	Controls: left click (hold to keep swinging) on PC, tap on mobile.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local DigConfig = require(Shared.Config.DigConfig)
local DigRules = require(Shared.Dig.DigRules)
local FeelConfig = require(Shared.Config.FeelConfig)
local MaterialConfig = require(Shared.Config.MaterialConfig)
local Remotes = require(Shared.Remotes)
local ToolConfig = require(Shared.Config.ToolConfig)

local Client = script.Parent.Parent
local CellVisuals = require(Client.Effects.CellVisuals)
local EffectsController = require(script.Parent.EffectsController)
local FossilController = require(script.Parent.FossilController)
local PlotController = require(script.Parent.PlotController)
local ToolController = require(script.Parent.ToolController)

-- A swing we have sent and predicted, waiting for the server's ruling.
type PendingSwing = {
	Kind: "Cell" | "Fossil",
	Index: number,
	Part: BasePart,
	Amount: number, -- predicted damage (cell) or cleaning strokes (fossil)
	PredictedBreak: boolean,
	PredictedReveal: boolean,
	SentAt: number,
}

local DigController = {}

local player = Players.LocalPlayer

local sequence = 0
local pending: { [number]: PendingSwing } = {}
-- Per part: the last value the server confirmed (cell health, or strokes done
-- on a crust), and the predicted change it has not confirmed yet.
local confirmed: { [BasePart]: number } = {}
local unconfirmed: { [BasePart]: number } = {}

local nextSwingAt = 0
local mouseHeld = false
local lastPendingSweep = 0

local function getRootPosition(): Vector3?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position
	end
	return nil
end

local function numberAttribute(part: BasePart, name: string): number
	local value = part:GetAttribute(name)
	return if typeof(value) == "number" then value else 0
end

-- The server-confirmed value for a part, read from its attribute the first time.
local function confirmedValue(target: PlotController.Target): number
	local known = confirmed[target.Part]
	if known == nil then
		known = numberAttribute(target.Part, if target.Kind == "Cell" then "Health" else "Clean")
		confirmed[target.Part] = known
	end
	return known
end

local function cellDamageFraction(part: BasePart, health: number): number
	local materialId = part:GetAttribute("Mat")
	local material = if typeof(materialId) == "string"
		then MaterialConfig.Materials[materialId]
		else nil
	if material == nil or material.Health <= 0 then
		return 0
	end
	return 1 - health / material.Health
end

local function send(
	target: PlotController.Target,
	amount: number,
	willBreak: boolean,
	willReveal: boolean
)
	sequence += 1
	pending[sequence] = {
		Kind = target.Kind,
		Index = target.Index,
		Part = target.Part,
		Amount = amount,
		PredictedBreak = willBreak,
		PredictedReveal = willReveal,
		SentAt = os.clock(),
	}
	unconfirmed[target.Part] = (unconfirmed[target.Part] or 0) + amount
	Remotes.get("SwingRequest"):FireServer(sequence, target.Index)
end

-- The wrong tool was used: play the cue and point at a tool that would work.
local function wrongTool(target: PlotController.Target)
	EffectsController.wrongTool(target.Part)
	local materialId = target.Part:GetAttribute("Mat")
	for otherId in ToolConfig.Tools do
		local works: boolean
		if target.Kind == "Cell" then
			works = typeof(materialId) == "string" and DigRules.getDamage(otherId, materialId) > 0
		else
			works = DigRules.getCleanPower(otherId) > 0
		end
		if works then
			ToolController.nudge(otherId)
			return
		end
	end
end

local function swingAtCell(target: PlotController.Target, toolId: string)
	local materialId = target.Part:GetAttribute("Mat")
	if typeof(materialId) ~= "string" then
		return
	end
	local damage = DigRules.getDamage(toolId, materialId)
	if damage <= 0 then
		wrongTool(target)
		return
	end

	local health = confirmedValue(target) - (unconfirmed[target.Part] or 0) - damage
	local willBreak = health <= 0
	send(target, damage, willBreak, false)

	if willBreak then
		PlotController.setLocallyBroken(target.Index, true)
		FossilController.noteBreak(target.Index)
		EffectsController.cellBreak(target.Part, materialId)
	else
		EffectsController.cellHit(
			target.Part,
			materialId,
			target.Position,
			target.Normal,
			cellDamageFraction(target.Part, health)
		)
	end
end

local function swingAtFossil(target: PlotController.Target, toolId: string)
	local power = DigRules.getCleanPower(toolId)
	if power <= 0 then
		wrongTool(target)
		return
	end

	local needed = math.max(numberAttribute(target.Part, "CleanNeeded"), 1)
	local done = confirmedValue(target) + (unconfirmed[target.Part] or 0) + power
	local willReveal = done >= needed
	send(target, power, false, willReveal)

	EffectsController.crustBrush(target.Part, target.Position, target.Normal, done / needed)
	if willReveal then
		FossilController.beginReveal(target.Index, target.Part)
	end
end

-- One swing attempt along a ray from the camera.
local function trySwing(origin: Vector3, direction: Vector3)
	local now = os.clock()
	if now < nextSwingAt or FossilController.isBusy() then
		return
	end

	local target = PlotController.raycast(origin, direction * DigConfig.MaxRayDistance)
	if target == nil then
		return
	end
	if target.Kind == "Cell" and not PlotController.isExposed(target.Index) then
		return
	end
	if target.Kind == "Fossil" and target.Part:GetAttribute("Stage") ~= "Encased" then
		return
	end

	local toolId = ToolController.getEquipped()
	local tool = ToolConfig.Tools[toolId]
	local rootPosition = getRootPosition()
	local cellCenter = PlotController.getCellCenter(target.Index)
	if tool == nil or rootPosition == nil or cellCenter == nil then
		return
	end

	if DigRules.distanceToCell(rootPosition, cellCenter) > tool.Range then
		nextSwingAt = now + FeelConfig.TooFar.RetryDelay
		EffectsController.tooFar(target.Part)
		return
	end

	nextSwingAt = now + tool.Cooldown
	ToolController.playSwing()
	if target.Kind == "Cell" then
		swingAtCell(target, toolId)
	else
		swingAtFossil(target, toolId)
	end
end

local function swingAtMouse()
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end
	local location = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(location.X, location.Y)
	trySwing(ray.Origin, ray.Direction)
end

-- Puts a cell back the way the server says it is, after a wrong prediction.
local function restoreCell(entry: PendingSwing)
	local part = entry.Part
	if part.Parent == nil then
		return
	end
	if entry.PredictedBreak then
		PlotController.setLocallyBroken(entry.Index, false)
		CellVisuals.show(part)
	end
	local health = (confirmed[part] or 0) - (unconfirmed[part] or 0)
	CellVisuals.setCellDamage(part, cellDamageFraction(part, health))
end

local function restoreCrust(entry: PendingSwing)
	local part = entry.Part
	if entry.PredictedReveal then
		FossilController.cancelReveal(entry.Index)
	end
	if part.Parent == nil then
		return
	end
	local needed = math.max(numberAttribute(part, "CleanNeeded"), 1)
	local done = (confirmed[part] or 0) + (unconfirmed[part] or 0)
	CellVisuals.setCrustClean(part, done / needed)
end

-- Applies the server's ruling on one swing.
local function settle(entry: PendingSwing, ok: boolean, code: string, value: number, defId: string?)
	local part = entry.Part
	local remaining = (unconfirmed[part] or 0) - entry.Amount
	unconfirmed[part] = if remaining > 0 then remaining else nil
	if ok then
		confirmed[part] = value
	end

	if entry.Kind == "Cell" then
		if ok and code == "Break" then
			if not entry.PredictedBreak and part.Parent ~= nil then
				-- The server broke a cell we expected to survive. Catch up.
				local materialId = part:GetAttribute("Mat")
				PlotController.setLocallyBroken(entry.Index, true)
				FossilController.noteBreak(entry.Index)
				if typeof(materialId) == "string" then
					EffectsController.cellBreak(part, materialId)
				end
			end
		elseif not ok or entry.PredictedBreak then
			restoreCell(entry)
		end
	else
		if ok and code == "Reveal" and defId then
			FossilController.confirmReveal(entry.Index, defId)
		elseif not ok or entry.PredictedReveal then
			restoreCrust(entry)
		end
	end
end

-- Server -> client. Arguments are checked before use.
local function onSwingResult(seq: any, ok: any, code: any, value: any, defId: any)
	if typeof(seq) ~= "number" then
		return
	end
	local entry = pending[seq]
	if entry == nil then
		return
	end
	pending[seq] = nil
	settle(
		entry,
		ok == true,
		if typeof(code) == "string" then code else "",
		if typeof(value) == "number" then value else 0,
		if typeof(defId) == "string" then defId else nil
	)
end

-- A swing the server never answered is treated as rejected.
local function sweepPending(now: number)
	for seq, entry in pending do
		if now - entry.SentAt > DigConfig.PendingTimeout then
			pending[seq] = nil
			settle(entry, false, "Timeout", 0, nil)
		end
	end
end

local function updateHover()
	if not FeelConfig.Hover.Enabled then
		return
	end
	local camera = Workspace.CurrentCamera
	if
		camera == nil
		or not UserInputService.MouseEnabled
		or UserInputService:GetLastInputType() == Enum.UserInputType.Touch
	then
		EffectsController.setHover(nil, nil)
		return
	end

	local location = UserInputService:GetMouseLocation()
	local ray = camera:ViewportPointToRay(location.X, location.Y)
	local target = PlotController.raycast(ray.Origin, ray.Direction * DigConfig.MaxRayDistance)
	if target == nil then
		EffectsController.setHover(nil, nil)
		return
	end
	if target.Kind == "Cell" and not PlotController.isExposed(target.Index) then
		EffectsController.setHover(nil, nil)
		return
	end
	if target.Kind == "Fossil" and target.Part:GetAttribute("Stage") ~= "Encased" then
		EffectsController.setHover(nil, nil)
		return
	end

	local toolId = ToolController.getEquipped()
	local tool = ToolConfig.Tools[toolId]
	local rootPosition = getRootPosition()
	local cellCenter = PlotController.getCellCenter(target.Index)
	if tool == nil or rootPosition == nil or cellCenter == nil then
		EffectsController.setHover(nil, nil)
		return
	end

	local works: boolean
	if target.Kind == "Cell" then
		local materialId = target.Part:GetAttribute("Mat")
		works = typeof(materialId) == "string" and DigRules.getDamage(toolId, materialId) > 0
	else
		works = DigRules.getCleanPower(toolId) > 0
	end

	if DigRules.distanceToCell(rootPosition, cellCenter) > tool.Range then
		EffectsController.setHover(target.Part, "TooFar")
	elseif works then
		EffectsController.setHover(target.Part, "Valid")
	else
		EffectsController.setHover(target.Part, "WrongTool")
	end
end

local function forgetPart(_index: number, part: BasePart)
	confirmed[part] = nil
	unconfirmed[part] = nil
	CellVisuals.forget(part)
end

function DigController.Start()
	Remotes.get("SwingResult").OnClientEvent:Connect(onSwingResult)

	PlotController.CellRemoved:Connect(forgetPart)
	PlotController.FossilRemoved:Connect(forgetPart)

	-- PC: click, or hold to keep swinging.
	UserInputService.InputBegan:Connect(function(input: InputObject, processedByUi: boolean)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and not processedByUi then
			mouseHeld = true
			swingAtMouse()
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			mouseHeld = false
		end
	end)
	UserInputService.WindowFocusReleased:Connect(function()
		mouseHeld = false
	end)

	-- Mobile: one tap, one swing. Taps on buttons arrive as processedByUi.
	UserInputService.TouchTapInWorld:Connect(function(position: Vector2, processedByUi: boolean)
		local camera = Workspace.CurrentCamera
		if processedByUi or camera == nil then
			return
		end
		local ray = camera:ScreenPointToRay(position.X, position.Y)
		trySwing(ray.Origin, ray.Direction)
	end)

	RunService.RenderStepped:Connect(function()
		local now = os.clock()
		if mouseHeld and DigConfig.HoldToRepeat then
			swingAtMouse()
		end
		updateHover()
		if now - lastPendingSweep > 0.5 then
			lastPendingSweep = now
			sweepPending(now)
		end
	end)
end

return DigController
