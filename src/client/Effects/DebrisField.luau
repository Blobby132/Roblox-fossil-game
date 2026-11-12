--!strict
--[[
	DebrisField: the crumble. Small greybox pieces that fly out of a
	breaking cell, tumble, shrink and vanish.

	The pieces are moved by this script, not by physics: that keeps them
	cheap, lets them be pooled, and lets slow motion affect them.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EffectsRoot = require(script.Parent.EffectsRoot)
local FeelConfig = require(ReplicatedStorage.Shared.Config.FeelConfig)

type Piece = {
	Part: Part,
	Active: boolean,
	Position: Vector3,
	Velocity: Vector3,
	Axis: Vector3,
	Angle: number,
	Spin: number,
	Size: number,
	Age: number,
	Lifetime: number,
}

local DebrisField = {}

local pieces: { Piece } = {}
local nextReuse = 1
local random = Random.new()

local function newPiece(): Piece
	local part = Instance.new("Part")
	part.Name = "Debris"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Transparency = 1
	part.Parent = EffectsRoot.Folder
	return {
		Part = part,
		Active = false,
		Position = Vector3.zero,
		Velocity = Vector3.zero,
		Axis = Vector3.yAxis,
		Angle = 0,
		Spin = 0,
		Size = 1,
		Age = 0,
		Lifetime = 1,
	}
end

local function takePiece(): Piece
	for _, piece in pieces do
		if not piece.Active then
			return piece
		end
	end
	if #pieces < FeelConfig.Crumble.MaxPieces then
		local piece = newPiece()
		table.insert(pieces, piece)
		return piece
	end
	-- Everything is in the air: reuse the next one in line.
	local piece = pieces[nextReuse]
	nextReuse = nextReuse % #pieces + 1
	return piece
end

-- Throws `count` pieces out of a box centred on `center`.
function DebrisField.burst(
	center: Vector3,
	boxSize: Vector3,
	color: Color3,
	material: Enum.Material,
	count: number
)
	local crumble = FeelConfig.Crumble
	for _ = 1, count do
		local piece = takePiece()
		local angle = random:NextNumber(0, math.pi * 2)
		local speed = random:NextNumber(crumble.SpeedMin, crumble.SpeedMax)

		piece.Active = true
		piece.Age = 0
		piece.Lifetime = crumble.Lifetime * random:NextNumber(0.7, 1.1)
		piece.Size = random:NextNumber(crumble.SizeMin, crumble.SizeMax)
		piece.Position = center
			+ Vector3.new(
				random:NextNumber(-0.4, 0.4) * boxSize.X,
				random:NextNumber(-0.4, 0.4) * boxSize.Y,
				random:NextNumber(-0.4, 0.4) * boxSize.Z
			)
		piece.Velocity = Vector3.new(
			math.cos(angle) * speed,
			crumble.Upward * random:NextNumber(0.5, 1.2),
			math.sin(angle) * speed
		)
		piece.Axis = random:NextUnitVector()
		piece.Angle = random:NextNumber(0, math.pi * 2)
		piece.Spin = crumble.Spin * random:NextNumber(0.5, 1.5)

		piece.Part.Color = color
		piece.Part.Material = material
		piece.Part.Transparency = 0
	end
end

-- Call once per frame with the (time-scaled) frame time.
function DebrisField.step(delta: number)
	local gravity = Vector3.new(0, -FeelConfig.Crumble.Gravity, 0)
	for _, piece in pieces do
		if piece.Active then
			piece.Age += delta
			if piece.Age >= piece.Lifetime then
				piece.Active = false
				piece.Part.Transparency = 1
			else
				piece.Velocity += gravity * delta
				piece.Position += piece.Velocity * delta
				piece.Angle += piece.Spin * delta
				-- Shrink slowly at first, then quickly at the end.
				local life = piece.Age / piece.Lifetime
				local size = math.max(piece.Size * (1 - life * life), 0.05)
				piece.Part.Size = Vector3.new(size, size, size)
				piece.Part.CFrame = CFrame.new(piece.Position)
					* CFrame.fromAxisAngle(piece.Axis, piece.Angle)
			end
		end
	end
end

return DebrisField
