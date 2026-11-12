--!strict
--[[
	EffectsController: turns "a swing did X" into sound, particles, camera
	shake and movement. This is where the feel of digging is assembled; the
	numbers all come from FeelConfig and SoundConfig.

	It only plays effects. It never decides what a swing does (DigController
	predicts that, and the server has the final say).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage.Shared
local FeelConfig = require(Shared.Config.FeelConfig)

local Client = script.Parent.Parent
local CameraFx = require(Client.Effects.CameraFx)
local CellVisuals = require(Client.Effects.CellVisuals)
local DebrisField = require(Client.Effects.DebrisField)
local EffectsRoot = require(Client.Effects.EffectsRoot)
local ParticlePool = require(Client.Effects.ParticlePool)
local SoundPlayer = require(Client.Effects.SoundPlayer)
local TimeScale = require(Client.Effects.TimeScale)

export type HoverState = "Valid" | "WrongTool" | "TooFar"

local EffectsController = {}

local random = Random.new()
local comboCount = 0
local lastHitAt = 0

local hoverBox: SelectionBox? = nil
local flashBox: SelectionBox? = nil
local flashToken = 0

-- Pitch for the next hit sound: rises while hits keep landing, resets after a pause.
local function nextComboPitch(): number
	local combo = FeelConfig.Combo
	local now = os.clock()
	if now - lastHitAt > combo.Window then
		comboCount = 0
	else
		comboCount = math.min(comboCount + 1, combo.MaxSteps)
	end
	lastHitAt = now
	local jitter = random:NextNumber(-combo.PitchJitter, combo.PitchJitter)
	return 1 + comboCount * combo.PitchStep + jitter
end

local function newSelectionBox(name: string): SelectionBox
	local box = Instance.new("SelectionBox")
	box.Name = name
	box.LineThickness = FeelConfig.Hover.LineThickness
	box.SurfaceTransparency = 1
	box.Parent = EffectsRoot.Folder
	return box
end

-- A hit landed on a cell and it is still standing.
--   damageFraction  0 = untouched, 1 = about to break
function EffectsController.cellHit(
	part: BasePart,
	materialId: string,
	position: Vector3,
	normal: Vector3,
	damageFraction: number
)
	local feel = FeelConfig.Materials[materialId]
	if feel == nil then
		return
	end
	SoundPlayer.play(feel.HitSound, nextComboPitch())
	ParticlePool.emit(feel.HitParticles, position, normal)
	CellVisuals.setCellDamage(part, damageFraction)
	CellVisuals.punch(part)
	CameraFx.shake(feel.HitShake)
end

-- A cell broke: crumble it and hide it.
function EffectsController.cellBreak(part: BasePart, materialId: string)
	local feel = FeelConfig.Materials[materialId]
	if feel == nil then
		return
	end
	SoundPlayer.play(feel.BreakSound, nextComboPitch())
	ParticlePool.emit(feel.BreakParticles, part.Position)
	DebrisField.burst(part.Position, part.Size, part.Color, part.Material, feel.DebrisCount)
	CellVisuals.hide(part)
	CameraFx.shake(feel.BreakShake)
end

-- A brush stroke landed on a fossil's crust.
--   cleanFraction  0 = just exposed, 1 = fully brushed
function EffectsController.crustBrush(
	part: BasePart,
	position: Vector3,
	normal: Vector3,
	cleanFraction: number
)
	local crust = FeelConfig.Crust
	SoundPlayer.play(crust.BrushSound, nextComboPitch())
	ParticlePool.emit(crust.BrushParticles, position, normal)
	CellVisuals.setCrustClean(part, cleanFraction)
	CellVisuals.wiggle(part, crust.Wobble, crust.WobbleTime)
end

-- A crusted fossil appeared where a cell just broke.
function EffectsController.fossilFound(part: BasePart)
	local crust = FeelConfig.Crust
	SoundPlayer.play(crust.FoundSound)
	ParticlePool.emit(crust.FoundParticles, part.Position)
	CellVisuals.wiggle(part, crust.Wobble, crust.WobbleTime * 2)
end

-- The tool in hand cannot affect what was hit.
function EffectsController.wrongTool(part: BasePart)
	local feel = FeelConfig.WrongTool
	comboCount = 0
	SoundPlayer.play(feel.Sound)
	CellVisuals.wiggle(part, feel.Wiggle, feel.WiggleTime)
end

-- The target is out of reach: flash its outline.
function EffectsController.tooFar(part: BasePart)
	local feel = FeelConfig.TooFar
	SoundPlayer.play(feel.Sound)

	local box = flashBox or newSelectionBox("TooFarFlash")
	flashBox = box
	box.Color3 = feel.Color
	box.Adornee = part
	box.Visible = true
	flashToken += 1
	local token = flashToken
	task.delay(feel.FlashTime, function()
		if flashToken == token then
			box.Visible = false
		end
	end)
end

-- PC only: outline whatever is under the cursor. Pass nil to clear it.
function EffectsController.setHover(part: BasePart?, state: HoverState?)
	local hover = FeelConfig.Hover
	if not hover.Enabled then
		return
	end
	if part == nil then
		-- Nothing to outline. On a phone the box is never even created.
		if hoverBox then
			hoverBox.Visible = false
		end
		return
	end
	local box = hoverBox or newSelectionBox("Hover")
	hoverBox = box
	box.Visible = true
	box.Adornee = part
	if state == "WrongTool" then
		box.Color3 = hover.WrongToolColor
	elseif state == "TooFar" then
		box.Color3 = hover.TooFarColor
	else
		box.Color3 = hover.ValidColor
	end
end

-- The plot was refilled with fresh ground.
function EffectsController.plotRefilled(center: Vector3)
	local refill = FeelConfig.Refill
	SoundPlayer.play(refill.Sound)
	ParticlePool.emit(refill.Particles, center)
	comboCount = 0
end

function EffectsController.Start()
	SoundPlayer.preload()
	CameraFx.start()

	RunService.RenderStepped:Connect(function(realDelta: number)
		local delta = TimeScale.step(realDelta)
		local scale = TimeScale.get()

		-- Slow motion also slows particles and pitches new sounds down.
		ParticlePool.setTimeScale(scale)
		local slowPitch = FeelConfig.Reveal.SlowPitch
		SoundPlayer.setGlobalPitch(if scale < 1 then slowPitch + (1 - slowPitch) * scale else 1)

		CellVisuals.step(delta)
		DebrisField.step(delta)
	end)
end

return EffectsController
