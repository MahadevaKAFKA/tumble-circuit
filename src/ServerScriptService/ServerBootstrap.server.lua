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
local TelemetryService = require(Services:WaitForChild("TelemetryService"))
local CosmeticService = require(Services:WaitForChild("CosmeticService"))
local QuestService = require(Services:WaitForChild("QuestService"))
local LeaderboardService = require(Services:WaitForChild("LeaderboardService"))
local CapsuleService = require(Services:WaitForChild("CapsuleService"))
local SeasonService = require(Services:WaitForChild("SeasonService"))
local ProductService = require(Services:WaitForChild("ProductService"))
local AntiCheatService = require(Services:WaitForChild("AntiCheatService"))
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

-- prompt 02/07: registry feature gates. Server-wide gates (race maps in rotation) are on only
-- in Studio; gated HUBS are per player (FeatureGates.ForPlayer) so the owner can try them on a
-- live private server without changing anyone else's race.
local FeatureGates = require(Services:WaitForChild("FeatureGates"))
local track = TrainingTrackService.new({ features = FeatureGates.ForServer() })
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
-- prompt 03/04: per-player hubs (Visit Hub / Practice); round asks it where hub spawns go
local HubService = require(Services:WaitForChild("HubService"))
local hubs = HubService.new({ track = track, marbles = marbles, remotes = remotes, round = round, timeTrial = timeTrial, featuresFor = FeatureGates.ForPlayer })
round.hubs = hubs
-- B3: telemetry, cosmetics, quests, leaderboards
local telemetry = TelemetryService.new()
local cosmetics = CosmeticService.new({ data = playerData, marbles = marbles, remotes = remotes, telemetry = telemetry })
marbles.lookResolver = function(player)
	return cosmetics:LookFor(player)
end
social.emoteResolver = function(player, slot)
	return cosmetics:EmoteFor(player, slot)
end
local quests = QuestService.new({ data = playerData, round = round, remotes = remotes, economy = economy, abilities = abilities, micro = micro, gates = chaos, track = track, telemetry = telemetry })
local leaderboards = LeaderboardService.new({ data = playerData, round = round, economy = economy, remotes = remotes, track = track, hazards = hazards })
-- C: free capsules (earned Coins), Shard Shop, free season
local capsules = CapsuleService.new({ data = playerData, remotes = remotes, cosmetics = cosmetics, telemetry = telemetry })
local seasons = SeasonService.new({ data = playerData, remotes = remotes, economy = economy, quests = quests, cosmetics = cosmetics })
-- D: anti-cheat aggregation + the optional shop (all products nil = nothing on sale)
local anticheat = AntiCheatService.new({ remotes = remotes, physics = physics })
round.anticheat = anticheat
capsules.anticheat = anticheat
local products = ProductService.new({ data = playerData, remotes = remotes, cosmetics = cosmetics, telemetry = telemetry, anticheat = anticheat })
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
hubs:Start() -- before players spawn: sets TC_Hub / TC_Features on everyone
round:Start()
timeTrial:Start()
cosmetics:Start()
quests:Start()
leaderboards:Start()
capsules:Start()
seasons:Start()
anticheat:Start()
products:Start()
-- B3 telemetry hooks (Roblox AnalyticsService via TelemetryService; failures never matter)
do
	local function human(entity)
		return typeof(entity) == "Instance" and entity:IsA("Player")
	end
	round.StateChanged:Connect(function(state)
		if state == RoundProtocol.States.Racing then
			local worldId = track:GetActiveWorldId()
			for _, entity in ipairs(round:GetActiveRacers()) do
				if human(entity) then
					telemetry:Onboarding(entity, "FirstRace")
					telemetry:Event(entity, "race_start", { world = worldId })
				end
			end
		end
	end)
	round.RaceFinished:Connect(function(_, results)
		for _, entry in ipairs(results) do
			local player = not entry.isBot and round:GetPlayerByUserId(entry.userId)
			if player then
				if entry.finished then
					telemetry:Onboarding(player, "FirstFinish")
				end
				telemetry:Event(player, entry.finished and "race_finish" or "race_dnf", { value = entry.place or 0, world = track:GetActiveWorldId() })
			end
		end
	end)
	abilities.Activated:Connect(function(entity, id)
		if human(entity) then
			telemetry:Event(entity, "ability_used", { ability = id })
		end
	end)
	playerData.ProfileLoaded:Connect(function(player)
		telemetry:Onboarding(player, "Title")
	end)
	game:GetService("Players").PlayerRemoving:Connect(function(player)
		telemetry:Forget(player)
	end)
end
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
_G.TumbleCircuitServer = { track = track, marbles = marbles, physics = physics, checkpoints = checkpoints, progress = progress, round = round, abilities = abilities, micro = micro, remotes = remotes, hazards = hazards, bots = bots, chaos = chaos, perf = perf, playerData = playerData, economy = economy, dev = dev, social = social, party = party, timeTrial = timeTrial, cosmetics = cosmetics, quests = quests, leaderboards = leaderboards, telemetry = telemetry, capsules = capsules, seasons = seasons, products = products, anticheat = anticheat, hubs = hubs }

print(string.format("[TumbleCircuit] server ready (%s, protocol v%d)", GameConfig.Version, RoundProtocol.Version))
