--!strict
--[[
	CellVisuals: how grid cells and fossil crusts LOOK on this client.

	The server owns the parts; this module only changes how they appear to
	this player, to give instant feedback:
	  * a cell shrinks, darkens and tilts as it takes damage
	  * a cell or crust is knocked back for an instant when hit ("punch")
	  * a cell shakes sideways when the wrong tool hits it ("wiggle")
	  * a cell is hidden the moment we predict it breaks

	None of this is sent to the server, and all of it is undone if the server
	disagrees with the prediction.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local FeelConfig = require(Shared.Config.FeelConfig)
local FossilConfig = require(Shared.Config.FossilConfig)

type ChildRecord = {
	Part: BasePart,
	Relative: CFrame, -- the child's position relative to its cell (cracks ride along)
	Transparency: number,
}

type Record = {
	Part: BasePart,
	BaseCFrame: CFrame,
	BaseSize: Vector3,
	BaseColor: Color3,
	BaseTransparency: number,
	BaseCanCollide: boolean,
	Children: { ChildRecord },
	-- Resting look.
	Tilt: CFrame,
	Scale: number,
	ScaleHeight: boolean, -- crusts shrink in every direction; cells keep their height
	-- A reaction that is fading out. ReactTime 0 means none.
	ReactAge: number,
	ReactTime: number,
	ReactSquash: number,
	ReactDrop: number,
	ReactWiggle: number,
	Hidden: boolean,
}

local WIGGLE_SPEED = 60 -- radians per second

local CellVisuals = {}

local records: { [BasePart]: Record } = {}
local reacting: { [BasePart]: Record } = {}
local random = Random.new()

local function getRecord(part: BasePart): Record
	local existing = records[part]
	if existing then
		return existing
	end
	local children: { ChildRecord } = {}
	for _, child in part:GetChildren() do
		if child:IsA("BasePart") then
			table.insert(children, {
				Part = child,
				Relative = part.CFrame:ToObjectSpace(child.CFrame),
				Transparency = child.Transparency,
			})
		end
	end
	local record: Record = {
		Part = part,
		BaseCFrame = part.CFrame,
		BaseSize = part.Size,
		BaseColor = part.Color,
		BaseTransparency = part.Transparency,
		BaseCanCollide = part.CanCollide,
		Children = children,
		Tilt = CFrame.new(),
		Scale = 1,
		ScaleHeight = false,
		ReactAge = 0,
		ReactTime = 0,
		ReactSquash = 0,
		ReactDrop = 0,
		ReactWiggle = 0,
		Hidden = false,
	}
	records[part] = record
	return record
end

-- Places the part for its resting look plus whatever is left of a reaction.
local function apply(record: Record)
	local strength = 0 -- 1 at the instant of a hit, fading to 0
	if record.ReactTime > 0 then
		local progress = math.clamp(record.ReactAge / record.ReactTime, 0, 1)
		strength = (1 - progress) * (1 - progress)
	end

	local scale = record.Scale * (1 - record.ReactSquash * strength)
	local base = record.BaseSize
	local height = if record.ScaleHeight then base.Y * scale else base.Y
	local offset = Vector3.new(
		math.sin(record.ReactAge * WIGGLE_SPEED) * record.ReactWiggle * strength,
		-record.ReactDrop * strength,
		0
	)
	local cframe = record.BaseCFrame * record.Tilt + offset

	local part = record.Part
	part.Size = Vector3.new(base.X * scale, height, base.Z * scale)
	part.CFrame = cframe
	for _, child in record.Children do
		child.Part.CFrame = cframe * child.Relative
	end
end

local function react(part: BasePart, squash: number, drop: number, wiggle: number, time: number)
	local record = getRecord(part)
	record.ReactAge = 0
	record.ReactTime = math.max(time, 0.01)
	record.ReactSquash = squash
	record.ReactDrop = drop
	record.ReactWiggle = wiggle
	reacting[part] = record
	apply(record)
end

-- Shows how damaged a cell is. 0 = untouched, 1 = about to break.
function CellVisuals.setCellDamage(part: BasePart, fraction: number)
	local hit = FeelConfig.CellHit
	local amount = math.clamp(fraction, 0, 1)
	local record = getRecord(part)
	local maxTilt = math.rad(hit.DamageTilt) * amount
	record.Scale = 1 - hit.DamageShrink * amount
	record.Tilt =
		CFrame.Angles(random:NextNumber(-maxTilt, maxTilt), 0, random:NextNumber(-maxTilt, maxTilt))
	part.Color = record.BaseColor:Lerp(Color3.new(0, 0, 0), hit.DamageDarken * amount)
	apply(record)
end

-- Shows how clean a fossil's crust is. 0 = just exposed, 1 = fully brushed.
function CellVisuals.setCrustClean(part: BasePart, fraction: number)
	local crust = FossilConfig.Crust
	local amount = math.clamp(fraction, 0, 1)
	local record = getRecord(part)
	record.ScaleHeight = true
	record.Scale = 1 - FeelConfig.Crust.ShrinkWhenClean * amount
	part.Color = crust.DirtyColor:Lerp(crust.CleanColor, amount)
	apply(record)
end

-- A hit landed: knock the part back for an instant.
function CellVisuals.punch(part: BasePart)
	local hit = FeelConfig.CellHit
	react(part, hit.PunchSquash, hit.PunchDrop, 0, hit.PunchTime)
end

-- Shake the part sideways (wrong tool, brush strokes).
function CellVisuals.wiggle(part: BasePart, amount: number, time: number)
	react(part, 0, 0, amount, time)
end

-- Hide a cell we predict has broken. It stays in place until the server
-- removes it, but can no longer be seen, stood on or clicked.
function CellVisuals.hide(part: BasePart)
	local record = getRecord(part)
	if record.Hidden then
		return
	end
	record.Hidden = true
	part.Transparency = 1
	part.CanCollide = false
	part.CanQuery = false
	for _, child in record.Children do
		child.Part.Transparency = 1
	end
end

-- Undo hide(): the server said the cell is still there.
function CellVisuals.show(part: BasePart)
	local record = records[part]
	if record == nil or not record.Hidden then
		return
	end
	record.Hidden = false
	part.Transparency = record.BaseTransparency
	part.CanCollide = record.BaseCanCollide
	part.CanQuery = true
	for _, child in record.Children do
		child.Part.Transparency = child.Transparency
	end
end

-- End any punch or wiggle now and leave the part at rest. After this,
-- nothing here writes to the part again until the next hit.
function CellVisuals.stopReaction(part: BasePart)
	local record = reacting[part]
	if record then
		reacting[part] = nil
		record.ReactTime = 0
		apply(record)
	end
end

-- Stop tracking a part (it was removed, or something else now animates it).
function CellVisuals.forget(part: BasePart)
	records[part] = nil
	reacting[part] = nil
end

-- Call once per frame with the (time-scaled) frame time.
function CellVisuals.step(delta: number)
	for part, record in reacting do
		record.ReactAge += delta
		if record.ReactAge >= record.ReactTime then
			record.ReactTime = 0
			reacting[part] = nil
		end
		apply(record)
	end
end

return CellVisuals
