--!strict
--[[
	SoundPlayer: plays the layered sound effects defined in SoundConfig.

	Sounds are not positional: they are this player's own feedback, so they
	play at full clarity. A few Sound objects ("voices") are kept per asset and
	reused, so quick repeated hits can overlap without creating new instances.
]]

local ContentProvider = game:GetService("ContentProvider")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local SoundConfig = require(ReplicatedStorage.Shared.Config.SoundConfig)

local MAX_VOICES_PER_ASSET = 6

local SoundPlayer = {}

local folder: Folder? = nil
local voices: { [string]: { Sound } } = {}
-- Counts plays per voice, so a scheduled cut-off never stops a newer play.
local playCount: { [Sound]: number } = {}
local globalPitch = 1

local function getFolder(): Folder
	local existing = folder
	if existing then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = "DigSounds"
	created.Parent = SoundService
	folder = created
	return created
end

local function acquire(assetId: string): Sound
	local list = voices[assetId]
	if list == nil then
		list = {}
		voices[assetId] = list
	end
	for _, sound in list do
		if not sound.IsPlaying then
			return sound
		end
	end
	if #list < MAX_VOICES_PER_ASSET then
		local sound = Instance.new("Sound")
		sound.SoundId = assetId
		sound.Parent = getFolder()
		table.insert(list, sound)
		return sound
	end
	-- Every voice is busy: reuse the oldest.
	local oldest = table.remove(list, 1) :: Sound
	table.insert(list, oldest)
	return oldest
end

local function playLayer(layer: SoundConfig.SoundLayer, pitch: number, volume: number)
	local sound = acquire(layer.Id)
	local count = (playCount[sound] or 0) + 1
	playCount[sound] = count

	sound.Volume = math.clamp(layer.Volume * volume * SoundConfig.MasterVolume, 0, 10)
	sound.PlaybackSpeed = math.clamp(layer.Pitch * pitch * globalPitch, 0.05, 10)
	sound.TimePosition = 0
	sound:Play()

	local length = layer.Length
	if length then
		task.delay(length, function()
			if playCount[sound] == count then
				sound:Stop()
			end
		end)
	end
end

-- Plays a sound from SoundConfig.Sounds. pitch and volume scale every layer.
function SoundPlayer.play(key: string, pitch: number?, volume: number?)
	local layers = SoundConfig.Sounds[key]
	if layers == nil then
		return
	end
	for _, layer in layers do
		local delay = layer.Delay
		if delay and delay > 0 then
			task.delay(delay, playLayer, layer, pitch or 1, volume or 1)
		else
			playLayer(layer, pitch or 1, volume or 1)
		end
	end
end

-- Pitch applied to every sound that starts from now on (used for slow motion).
function SoundPlayer.setGlobalPitch(pitch: number)
	globalPitch = pitch
end

-- Loads every sound up front, so the first hit is not silent.
function SoundPlayer.preload()
	local toLoad: { Instance } = {}
	for _, layers in SoundConfig.Sounds do
		for _, layer in layers do
			if voices[layer.Id] == nil then
				table.insert(toLoad, acquire(layer.Id))
			end
		end
	end
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync(toLoad)
		end)
	end)
end

return SoundPlayer
