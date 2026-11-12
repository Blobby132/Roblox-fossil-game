--!strict
--[[
	EffectsRoot: a folder in Workspace that exists only on this client.

	Anything a LocalScript creates in Workspace is seen by this player alone,
	so crumble pieces, particle anchors and outlines all live here.
]]

local Workspace = game:GetService("Workspace")

local folder = Instance.new("Folder")
folder.Name = "LocalEffects"
folder.Parent = Workspace

-- Particles need a part to live on. This one is invisible and never moves;
-- each burst uses an Attachment placed wherever the effect should appear.
local anchor = Instance.new("Part")
anchor.Name = "Anchor"
anchor.Anchored = true
anchor.CanCollide = false
anchor.CanQuery = false
anchor.CanTouch = false
anchor.Transparency = 1
anchor.Size = Vector3.new(1, 1, 1)
anchor.CFrame = CFrame.new()
anchor.Parent = folder

return {
	Folder = folder,
	Anchor = anchor,
}
