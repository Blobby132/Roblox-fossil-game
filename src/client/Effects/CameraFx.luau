--!strict
--[[
	CameraFx: camera shake and field-of-view kicks.

	Both are applied after Roblox's own camera has updated for the frame, on
	top of wherever it put the camera, so they never fight the player's camera
	control and never build up over time.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local FeelConfig = require(ReplicatedStorage.Shared.Config.FeelConfig)

local CameraFx = {}

-- Shake strength, 0-1. It fades by itself.
local trauma = 0

-- Field of view: a temporary offset added to the camera's own value.
local fovBase: number? = nil
local fovOffset = 0
local fovFrom = 0
local fovTo = 0
local fovStart = 0
local fovDuration = 0.1

-- Adds camera shake. 0.2 is a light tap, 0.6 is a heavy thud. Capped at 1.
function CameraFx.shake(amount: number)
	if FeelConfig.CameraShake.Enabled and amount > 0 then
		trauma = math.min(1, trauma + amount)
	end
end

-- Moves the field-of-view offset to `target` degrees over `duration` seconds.
-- Negative zooms in. Go back to 0 to release the camera.
function CameraFx.setFovOffset(target: number, duration: number)
	fovFrom = fovOffset
	fovTo = target
	fovStart = os.clock()
	fovDuration = math.max(duration, 0.01)
end

local function step(delta: number)
	local camera = Workspace.CurrentCamera
	if camera == nil then
		return
	end

	if fovOffset ~= 0 or fovTo ~= 0 then
		local base = fovBase or camera.FieldOfView
		fovBase = base
		local alpha = math.clamp((os.clock() - fovStart) / fovDuration, 0, 1)
		local eased = 1 - (1 - alpha) * (1 - alpha)
		fovOffset = fovFrom + (fovTo - fovFrom) * eased
		camera.FieldOfView = base + fovOffset
		if alpha >= 1 and fovTo == 0 then
			fovOffset = 0
			fovBase = nil
		end
	end

	if trauma > 0 then
		local settings = FeelConfig.CameraShake
		local strength = trauma * trauma
		local time = os.clock() * settings.Frequency
		-- math.noise gives smooth values around -0.5..0.5; doubled to about -1..1.
		local offsetX = math.noise(time, 0.5) * 2 * settings.MaxOffset * strength
		local offsetY = math.noise(time, 17.5) * 2 * settings.MaxOffset * strength
		local roll = math.rad(math.noise(time, 43.5) * 2 * settings.MaxRoll * strength)
		camera.CFrame = camera.CFrame * CFrame.new(offsetX, offsetY, 0) * CFrame.Angles(0, 0, roll)
		trauma = math.max(0, trauma - settings.Decay * delta)
	end
end

function CameraFx.start()
	RunService:BindToRenderStep("DigCameraFx", Enum.RenderPriority.Camera.Value + 1, step)
end

return CameraFx
