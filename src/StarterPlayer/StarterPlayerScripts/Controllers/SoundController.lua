--[[
	SoundController — routes named cues to sounds. Silent by default: a cue with no id in
	PLACEHOLDER_IDS (all of them in A1) does nothing. No external audio is required to play.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))

local SoundController = {}
SoundController.__index = SoundController

function SoundController.new(placeholderIds)
	local self = setmetatable({}, SoundController)
	self.ids = (placeholderIds and placeholderIds.Sounds) or {}
	self.cache = {}
	return self
end

-- A5 settings: music / sfx levels 0-1 (stored now; the build ships without audio files).
function SoundController:SetVolumes(music, sfx)
	self.music = tonumber(music) or 0.6
	self.sfx = tonumber(sfx) or 0.8
	for _, sound in pairs(self.cache) do
		sound.Volume = GameConfig.Audio.MasterVolume * self.sfx
	end
end

function SoundController:Play(name)
	local id = self.ids[name]
	if type(id) ~= "string" or not string.match(id, "^rbxassetid://%d+$") then
		return false -- no licensed id configured: stay silent
	end
	local sound = self.cache[name]
	if not sound then
		sound = Instance.new("Sound")
		sound.Name = "TC_" .. name
		sound.SoundId = id
		sound.Volume = GameConfig.Audio.MasterVolume * (self.sfx or 0.8)
		sound.Parent = SoundService
		self.cache[name] = sound
	end
	if (self.sfx or 0.8) <= 0 then
		return false
	end
	sound:Play()
	return true
end

-- 2026-11-26 speed feel: a looped roll whose pitch and volume follow speed (0..1 of the cap),
-- silent in the air and when no "Roll" id is configured. surface = "Track" / "Air".
function SoundController:SetRoll(fraction, grounded)
	local id = self.ids.Roll
	if type(id) ~= "string" or not string.match(id, "^rbxassetid://%d+$") then
		return false
	end
	local roll = self.roll
	if not roll then
		roll = Instance.new("Sound")
		roll.Name = "TC_Roll"
		roll.SoundId = id
		roll.Looped = true
		roll.Volume = 0
		roll.Parent = SoundService
		self.roll = roll
	end
	local f = math.clamp(fraction or 0, 0, 1.2)
	local target = (grounded and f > 0.05) and (0.15 + 0.45 * f) * GameConfig.Audio.MasterVolume * (self.sfx or 0.8) or 0
	roll.Volume = roll.Volume + (target - roll.Volume) * 0.15
	roll.PlaybackSpeed = 0.8 + 0.55 * f
	if roll.Volume > 0.01 and not roll.IsPlaying then
		roll:Play()
	elseif roll.Volume <= 0.01 and roll.IsPlaying then
		roll:Stop()
	end
	return true
end

function SoundController:Destroy()
	for _, sound in pairs(self.cache) do
		sound:Destroy()
	end
	self.cache = {}
	if self.roll then
		self.roll:Destroy()
		self.roll = nil
	end
end

return SoundController
