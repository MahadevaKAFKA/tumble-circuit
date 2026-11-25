--[[
	ServerBootstrap — creates the one Remotes folder from RoundProtocol (server only), builds the
	courses, then starts services in dependency order:
	  TrainingTrack -> MarbleCharacter -> RacePhysics -> Checkpoint/Progress -> Hazard -> Bot
	  -> Round -> Ability -> MicroSkill -> ChaosGate -> Perf
	Marble spawning starts after every subscriber (and the spawn resolver) exists; bots and perf
	start right after it (they need the marbles folder and never subscribe to marble signals).
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
local HazardService = require(Services:WaitForChild("HazardService"))
local BotService = require(Services:WaitForChild("BotService"))
local ChaosGateService = require(Services:WaitForChild("ChaosGateService"))
local PerfService = require(Services:WaitForChild("PerfService"))
local PlayerDataService = require(Services:WaitForChild("PlayerDataService"))
local EconomyService = require(Services:WaitForChild("EconomyService"))
local DevService = require(Services:WaitForChild("DevService"))
local SocialService = require(Services:WaitForChild("SocialService"))
local PartyService = require(Services:WaitForChild("PartyService"))
local TimeTrialService = require(Services:WaitForChild("TimeTrialService"))
local HubBuilder = require(game:GetService("ServerStorage"):WaitForChild("ProceduralBuilders"):WaitForChild("HubBuilder"))

local existing = ReplicatedStorage:FindFirstChild(RoundProtocol.FolderName)
if existing then
	existing:Destroy()
end
local remotes = Instance.new("Folder")
remotes.Name = RoundProtocol.FolderName
remotes:SetAttribute("ProtocolVersion", RoundProtocol.Version)
for remoteName, spec in pairs(RoundProtocol.Remotes) do
	-- A5: Studio/authorized-only remotes do not exist at all on a normal live server
	if not spec.StudioOnly or DevService.Enabled() then
		local remote = Instance.new("RemoteEvent")
		remote.Name = remoteName
		remote.Parent = remotes
	end
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
local hazards = HazardService.new(track)
local abilities -- created below (bots need it; it needs round)
local bots = BotService.new({ track = track, physics = physics, hazards = hazards })
local round = RoundService.new({
	track = track,
	marbles = marbles,
	physics = physics,
	checkpoints = checkpoints,
	progress = progress,
	remotes = remotes,
	bots = bots,
	hazards = hazards,
})

abilities = AbilityService.new({ marbles = marbles, physics = physics, round = round, remotes = remotes })
bots.abilities = abilities
abilities.track = track -- B2: grapple anchors, decoy route
abilities.checkpoints = checkpoints -- B2: grapple never past the next checkpoint
local micro = MicroSkillService.new({ track = track, marbles = marbles, physics = physics, round = round, abilities = abilities, remotes = remotes, hazards = hazards })
local chaos = ChaosGateService.new({ track = track, physics = physics, round = round, progress = progress, abilities = abilities, remotes = remotes })
local perf = PerfService.new({ track = track, bots = bots })
local playerData = PlayerDataService.new({ remotes = remotes })
abilities.playerData = playerData -- B2: owned abilities, unlocks (level / earned Coins)
local economy = EconomyService.new({ round = round, playerData = playerData, track = track, hazards = hazards, remotes = remotes })
local dev = DevService.new({ round = round, bots = bots, playerData = playerData, remotes = remotes })
local social = SocialService.new({ round = round, hazards = hazards, remotes = remotes, hubBuilder = HubBuilder })
local party = PartyService.new({ marbles = marbles }) -- B1
round.party = party
local timeTrial = TimeTrialService.new({ track = track, marbles = marbles, physics = physics, round = round, remotes = remotes, data = playerData, hazards = hazards }) -- B1
round.timeTrial = timeTrial
playerData.ProfileLoaded:Connect(function(player, profile)
	abilities:SetLoadout(player, profile.data.equippedAbilityIds) -- saved starter loadout
end)
abilities.LoadoutChanged:Connect(function(player, loadout)
	playerData:SetLoadout(player, loadout)
end)
bots.BotSpawned:Connect(function(bot)
	micro:_reset(bot) -- a respawn is never a takeoff / never keeps a slipstream (same as humans)
end)

playerData:Start() -- loads profiles as players join (does not block the course)
physics:Start()
hazards:Start()
round:Start()
timeTrial:Start()
abilities:Start()
micro:Start()
chaos:Start()
economy:Start()
dev:Start()
social:Start()
marbles:Start() -- creates the marbles folder and spawns players already present
bots:Start() -- bots only spawn at Preparing, so they can start after the folder exists
perf:Start()

-- Studio integration tests can reach the live services through this table (never replicated).
_G.TumbleCircuitServer = { track = track, marbles = marbles, physics = physics, checkpoints = checkpoints, progress = progress, round = round, abilities = abilities, micro = micro, remotes = remotes, hazards = hazards, bots = bots, chaos = chaos, perf = perf, playerData = playerData, economy = economy, dev = dev, social = social, party = party, timeTrial = timeTrial }

print(string.format("[TumbleCircuit] server ready (%s, protocol v%d)", GameConfig.Version, RoundProtocol.Version))
