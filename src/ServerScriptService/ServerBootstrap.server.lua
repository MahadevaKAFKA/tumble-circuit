--[[
	ServerBootstrap — creates remotes once, then starts services in dependency order:
	TrainingTrack (build course) -> MarbleCharacter -> RacePhysics -> PracticeRun.
	Marble spawning starts LAST so every subscriber is connected before the first spawn.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- First, before anything can yield: this game has no Characters (see MarbleCharacterService).
Players.CharacterAutoLoads = false

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local Protocol = require(Shared:WaitForChild("Protocol"))

local Services = script.Parent:WaitForChild("Services")
local TrainingTrackService = require(Services:WaitForChild("TrainingTrackService"))
local MarbleCharacterService = require(Services:WaitForChild("MarbleCharacterService"))
local RacePhysicsService = require(Services:WaitForChild("RacePhysicsService"))
local PracticeRunService = require(Services:WaitForChild("PracticeRunService"))

-- Remotes: created by the server only, from Protocol.
local existing = ReplicatedStorage:FindFirstChild(Protocol.RemotesFolderName)
if existing then
	existing:Destroy()
end
local remotes = Instance.new("Folder")
remotes.Name = Protocol.RemotesFolderName
for _, remoteName in pairs(Protocol.Remotes) do
	local remote = Instance.new("RemoteEvent")
	remote.Name = remoteName
	remote.Parent = remotes
end
remotes.Parent = ReplicatedStorage

local track = TrainingTrackService.new()
track:ApplyEnvironment()
local built, buildError = pcall(function()
	track:Build()
end)
if not built then
	workspace:SetAttribute(Protocol.WorkspaceAttributes.CourseError, tostring(buildError))
	warn("[TumbleCircuit] course build FAILED, server not starting: " .. tostring(buildError))
	return
end

local marbles = MarbleCharacterService.new(track)
local physics = RacePhysicsService.new(track, marbles)
local runs = PracticeRunService.new(track, marbles, physics)

physics:Start()
runs:Start()
marbles:Start(remotes)

print(string.format("[TumbleCircuit] server ready (%s)", GameConfig.Version))
