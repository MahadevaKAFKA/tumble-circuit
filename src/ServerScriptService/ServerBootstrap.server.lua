--[[
	ServerBootstrap — creates the one Remotes folder from RoundProtocol (server only), builds the
	courses, then starts services in dependency order:
	  TrainingTrack -> MarbleCharacter -> RacePhysics -> Checkpoint/Progress -> Round
	Marble spawning starts LAST so every subscriber (and the spawn resolver) exists first.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

Players.CharacterAutoLoads = false -- this game has no Characters (see MarbleCharacterService)

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local RoundProtocol = require(Shared:WaitForChild("RoundProtocol"))

local Services = script.Parent:WaitForChild("Services")
local TrainingTrackService = require(Services:WaitForChild("TrainingTrackService"))
local MarbleCharacterService = require(Services:WaitForChild("MarbleCharacterService"))
local RacePhysicsService = require(Services:WaitForChild("RacePhysicsService"))
local CheckpointService = require(Services:WaitForChild("CheckpointService"))
local ProgressService = require(Services:WaitForChild("ProgressService"))
local RoundService = require(Services:WaitForChild("RoundService"))
local AbilityService = require(Services:WaitForChild("AbilityService"))
local MicroSkillService = require(Services:WaitForChild("MicroSkillService"))

local existing = ReplicatedStorage:FindFirstChild(RoundProtocol.FolderName)
if existing then
	existing:Destroy()
end
local remotes = Instance.new("Folder")
remotes.Name = RoundProtocol.FolderName
remotes:SetAttribute("ProtocolVersion", RoundProtocol.Version)
for remoteName in pairs(RoundProtocol.Remotes) do
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
local checkpoints = CheckpointService.new(track)
local progress = ProgressService.new(checkpoints, physics)
local round = RoundService.new({
	track = track,
	marbles = marbles,
	physics = physics,
	checkpoints = checkpoints,
	progress = progress,
	remotes = remotes,
})

local abilities = AbilityService.new({ marbles = marbles, physics = physics, round = round, remotes = remotes })
local micro = MicroSkillService.new({ track = track, marbles = marbles, physics = physics, round = round, abilities = abilities, remotes = remotes })

physics:Start()
round:Start()
abilities:Start()
micro:Start()
marbles:Start()

-- Studio integration tests can reach the live services through this table (never replicated).
_G.TumbleCircuitServer = { track = track, marbles = marbles, physics = physics, checkpoints = checkpoints, progress = progress, round = round, abilities = abilities, micro = micro, remotes = remotes }

print(string.format("[TumbleCircuit] server ready (%s, protocol v%d)", GameConfig.Version, RoundProtocol.Version))
