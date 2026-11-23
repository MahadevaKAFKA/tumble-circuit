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
		sound.Volume = GameConfig.Audio.MasterVolume
		sound.Parent = SoundService
		self.cache[name] = sound
	end
	sound:Play()
	return true
end

function SoundController:Destroy()
	for _, sound in pairs(self.cache) do
		sound:Destroy()
	end
	self.cache = {}
end

return SoundController
