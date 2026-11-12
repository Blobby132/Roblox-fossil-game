--!strict
--[[
	Ui: small helpers for building interface in code.

	House rules for every piece of UI in this game (they keep it usable on
	phones, where most Roblox play happens):
	  * size and position with Scale, never fixed pixel Offsets
	  * lock shapes with UIAspectRatioConstraint
	  * cap how big things grow on large screens with UISizeConstraint
	  * keep the bottom corners clear: the thumbstick and jump button live there
]]

local Players = game:GetService("Players")

local Ui = {}

local hud: ScreenGui? = nil

-- Creates an instance, sets its properties and parents the given children to it.
-- Returns `any` so callers can cast to the class they asked for.
function Ui.create(className: string, properties: { [string]: any }, children: { Instance }?): any
	local instance = Instance.new(className) :: any
	for key, value in properties do
		instance[key] = value
	end
	if children then
		for _, child in children do
			child.Parent = instance
		end
	end
	return instance
end

-- The one ScreenGui every controller adds its interface to.
function Ui.getHud(): ScreenGui
	local existing = hud
	if existing then
		return existing
	end
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local created = Ui.create("ScreenGui", {
		Name = "DigHud",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 5,
	}) :: ScreenGui
	created.Parent = playerGui
	hud = created
	return created
end

return Ui
