--!strict
--[[
	ParticlePool: one-shot particle bursts from FeelConfig.Particles.

	Each kind of burst keeps a few emitters that are reused in turn, so
	nothing is created while the player is digging.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EffectsRoot = require(script.Parent.EffectsRoot)
local FeelConfig = require(ReplicatedStorage.Shared.Config.FeelConfig)

local EMITTERS_PER_KIND = 4

type Slot = {
	Attachment: Attachment,
	Emitter: ParticleEmitter,
}

type Pool = {
	Slots: { Slot },
	Next: number,
}

local ParticlePool = {}

local pools: { [string]: Pool } = {}
local emitters: { ParticleEmitter } = {}
local timeScale = 1

-- Creates an emitter that looks like FeelConfig.Particles[key]. It does not
-- emit by itself: call Emit() on it, or set its Rate.
function ParticlePool.newEmitter(key: string, parent: Instance): ParticleEmitter?
	local def = FeelConfig.Particles[key]
	if def == nil then
		return nil
	end
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = key
	emitter.Enabled = false
	emitter.Rate = 0
	emitter.Texture = def.Texture
	emitter.Color = ColorSequence.new(def.Color)
	emitter.Lifetime = def.Lifetime
	emitter.Speed = def.Speed
	emitter.Size = NumberSequence.new(def.SizeStart, def.SizeEnd)
	emitter.Transparency = NumberSequence.new(def.TransparencyStart, def.TransparencyEnd)
	emitter.SpreadAngle = Vector2.new(def.SpreadAngle, def.SpreadAngle)
	emitter.Acceleration = def.Acceleration
	emitter.Drag = def.Drag
	emitter.RotSpeed = def.RotSpeed
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.LightEmission = def.LightEmission
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.TimeScale = timeScale
	emitter.Parent = parent
	table.insert(emitters, emitter)
	return emitter
end

local function getPool(key: string): Pool?
	local pool = pools[key]
	if pool then
		return pool
	end
	local slots: { Slot } = {}
	for _ = 1, EMITTERS_PER_KIND do
		local attachment = Instance.new("Attachment")
		attachment.Name = key
		attachment.Parent = EffectsRoot.Anchor
		local emitter = ParticlePool.newEmitter(key, attachment)
		if emitter == nil then
			attachment:Destroy()
			return nil
		end
		table.insert(slots, { Attachment = attachment, Emitter = emitter })
	end
	local created: Pool = { Slots = slots, Next = 1 }
	pools[key] = created
	return created
end

-- A frame whose "up" points along the surface normal, so particles spray
-- away from whatever face was hit.
local function orient(position: Vector3, normal: Vector3?): CFrame
	if normal == nil or normal.Y > 0.99 then
		return CFrame.new(position)
	end
	if normal.Y < -0.99 then
		return CFrame.new(position) * CFrame.Angles(math.pi, 0, 0)
	end
	return CFrame.lookAt(position, position + normal) * CFrame.Angles(-math.pi / 2, 0, 0)
end

-- Bursts particles of this kind at a point in the world.
--   normal      spray direction (defaults to straight up)
--   countScale  multiplies the kind's particle count
--   color       replaces the kind's colour for this and later bursts
function ParticlePool.emit(
	key: string,
	position: Vector3,
	normal: Vector3?,
	countScale: number?,
	color: Color3?
)
	local def = FeelConfig.Particles[key]
	local pool = getPool(key)
	if def == nil or pool == nil then
		return
	end
	local slot = pool.Slots[pool.Next]
	pool.Next = pool.Next % #pool.Slots + 1

	slot.Attachment.WorldCFrame = orient(position, normal)
	if color then
		slot.Emitter.Color = ColorSequence.new(color)
	end
	slot.Emitter:Emit(math.max(1, math.round(def.Count * (countScale or 1))))
end

-- Speed of every particle made here; 1 is normal. Used for slow motion.
function ParticlePool.setTimeScale(scale: number)
	if scale == timeScale then
		return
	end
	timeScale = scale
	for index = #emitters, 1, -1 do
		local emitter = emitters[index]
		if emitter.Parent == nil then
			table.remove(emitters, index)
		else
			emitter.TimeScale = scale
		end
	end
end

return ParticlePool
