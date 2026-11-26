--[[
	TestRunner — runs automatically when you press Play in Studio (GameConfig.Debug.RunTestsInStudio).
	Output window:
	  1) Unit/A1PureSpecs        movement/course/geometry (same as offline)
	  2) Unit/RoundState.spec    A2 round graph, payloads, standings, checkpoint judging, hub
	     Unit/*.spec (A3, A4)   abilities, micro-skills, security, track validation, hazard
	                             reset, bot navigation (kinematic model), chaos gates
	  3) Studio integration      real engine: built world, spawn clearance, floor coverage,
	                             no Humanoids, marble body; Integration/MultiplayerRound.spec
	  4) a 120 s round timeline  ([TumbleTests] timeline ...) to compare with TEST_PLAN.md
	It never changes gameplay state. Disabled automatically outside Studio.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local StarterPlayer = game:GetService("StarterPlayer")

if not RunService:IsStudio() then
	return
end

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
if not GameConfig.Debug.RunTestsInStudio then
	return
end

local PhysicsConfig = require(Shared:WaitForChild("PhysicsConfig"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local Services = ServerScriptService:WaitForChild("Services")
local Builders = ServerStorage:WaitForChild("ProceduralBuilders")

local modules = {
	GameConfig = GameConfig,
	PhysicsConfig = PhysicsConfig,
	Protocol = Protocol,
	RaceConfig = require(Shared:WaitForChild("RaceConfig")),
	RoundProtocol = require(Shared:WaitForChild("RoundProtocol")),
	Utility = require(Shared:WaitForChild("Utility")),
	RouteTracker = require(Shared:WaitForChild("RouteTracker")),
	TrackDefinitions = require(Shared:WaitForChild("TrackDefinitions")),
	PlaceholderIds = require(Shared:WaitForChild("PlaceholderIds")),
	Builder = require(Builders:WaitForChild("TrainingTrackBuilder")),
	HubBuilder = require(Builders:WaitForChild("HubBuilder")),
	ThemedHubBuilder = require(Builders:WaitForChild("ThemedHubBuilder")),
	RaceRules = require(Services:WaitForChild("RaceRules")),
	CheckpointService = require(Services:WaitForChild("CheckpointService")),
	AbilityConfig = require(Shared:WaitForChild("AbilityConfig")),
	SkillRules = require(Services:WaitForChild("SkillRules")),
	HazardSim = require(Shared:WaitForChild("HazardSim")),
	TrackValidator = require(Services:WaitForChild("TrackValidator")),
	BotBrain = require(Services:WaitForChild("BotBrain")),
	ChaosGateService = require(Services:WaitForChild("ChaosGateService")),
	ProgressionConfig = require(Shared:WaitForChild("ProgressionConfig")),
	PlayerDataSchema = require(Shared:WaitForChild("PlayerDataSchema")),
	ProfileStore = require(Services:WaitForChild("ProfileStore")),
	RewardRules = require(Services:WaitForChild("RewardRules")),
	VoteRules = require(Services:WaitForChild("VoteRules")),
	MapVoteRules = require(Services:WaitForChild("MapVoteRules")),
	PartyRules = require(Services:WaitForChild("PartyRules")),
	TimeTrialRules = require(Shared:WaitForChild("TimeTrialRules")),
	AbilityRules = require(Services:WaitForChild("AbilityRules")),
	Catalog = require(Shared:WaitForChild("Catalog")),
	MarbleLook = require(Shared:WaitForChild("MarbleLook")),
	QuestConfig = require(Shared:WaitForChild("QuestConfig")),
	CosmeticService = require(Services:WaitForChild("CosmeticService")),
	LeaderboardService = require(Services:WaitForChild("LeaderboardService")),
	CapsuleOdds = require(Shared:WaitForChild("CapsuleOdds")),
	SeasonConfig = require(Shared:WaitForChild("SeasonConfig")),
	CapsuleService = require(Services:WaitForChild("CapsuleService")),
	SeasonService = require(Services:WaitForChild("SeasonService")),
	ShopConfig = require(Shared:WaitForChild("ShopConfig")),
	ProductService = require(Services:WaitForChild("ProductService")),
	AntiCheatService = require(Services:WaitForChild("AntiCheatService")),
	SocialConfig = require(Shared:WaitForChild("SocialConfig")),
	MapRegistry = require(Shared:WaitForChild("MapRegistry")),
	VisualProfiles = require(Shared:WaitForChild("VisualProfiles")),
	MapLoader = require(Services:WaitForChild("MapLoader")),
	FeatureGates = require(Services:WaitForChild("FeatureGates")),
	BallotRules = require(Services:WaitForChild("BallotRules")),
	Dressing = require(Shared:WaitForChild("Dressing")),
	EnvironmentProfiles = require(Shared:WaitForChild("EnvironmentProfiles")),
	HubRules = require(Services:WaitForChild("HubRules")),
}
do
	local ControllersFolder = StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("Controllers")
	for key, name in pairs({ UIController = "UIController", SettingsPure = "SettingsController", LoadoutPure = "StarterLoadoutController", ResultsPure = "ResultsController", SocialPure = "SocialController", MapSelectPure = "MapSelectController" }) do
		local ok, mod = pcall(function()
			return require(ControllersFolder:WaitForChild(name))
		end)
		if ok then
			modules[key] = mod
		else
			warn("[TumbleTests] could not load " .. name .. " for pure UI specs: " .. tostring(mod))
		end
	end
end
local okHazard, hazardModule = pcall(function()
	return require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("Controllers"):WaitForChild("HazardController"))
end)
if okHazard then
	modules.HazardPhase = hazardModule.PhaseAt
	modules.HazardControllerPure = hazardModule
end

local Unit = script.Parent:WaitForChild("Unit")
local Integration = script.Parent:WaitForChild("Integration")

local function report(title, results)
	print(string.format("[TumbleTests] ===== %s: %d passed, %d failed =====", title, results.passed, results.failed))
	for _, line in ipairs(results.lines) do
		if string.sub(line, 1, 4) == "FAIL" then
			warn("[TumbleTests] " .. line)
		elseif GameConfig.Debug.VerboseLogging then
			print("[TumbleTests] " .. line)
		end
	end
	for _, line in ipairs(results.info or {}) do
		print("[TumbleTests] info: " .. line)
	end
end

report("A1 pure specs", require(Unit:WaitForChild("A1PureSpecs")).run(modules))
report("A2 round specs", require(Unit:WaitForChild("RoundState.spec")).run(modules))
report("A3 ability specs", require(Unit:WaitForChild("Ability.spec")).run(modules))
report("A3 micro-skill specs", require(Unit:WaitForChild("MicroSkill.spec")).run(modules))
report("A3 ability security specs", require(Unit:WaitForChild("AbilitySecurity.spec")).run(modules))
report("A4 track validation specs", require(Unit:WaitForChild("TrackValidation.spec")).run(modules))
report("A4 hazard reset specs", require(Unit:WaitForChild("HazardReset.spec")).run(modules))
report("A4 bot navigation specs", require(Unit:WaitForChild("BotNavigation.spec")).run(modules))
report("A4 chaos gate specs", require(Unit:WaitForChild("ChaosGate.spec")).run(modules))
report("A4 ready vote specs", require(Unit:WaitForChild("ReadyVote.spec")).run(modules))
report("A5 persistence specs", require(Unit:WaitForChild("Persistence.spec")).run(modules))
report("A5 reward idempotence specs", require(Unit:WaitForChild("RewardIdempotence.spec")).run(modules))
if modules.UIController then
	report("A5 UI state specs", require(Unit:WaitForChild("UIState.spec")).run(modules))
end
report("A6 social specs", require(Unit:WaitForChild("Social.spec")).run(modules))
report("B1 world specs", require(Unit:WaitForChild("Worlds.spec")).run(modules))
report("B1 rules specs", require(Unit:WaitForChild("B1Rules.spec")).run(modules))
report("B2 ability specs", require(Unit:WaitForChild("B2Abilities.spec")).run(modules))
report("B3 progression specs", require(Unit:WaitForChild("B3Progression.spec")).run(modules))
report("C capsule / season specs", require(Unit:WaitForChild("CCapsules.spec")).run(modules))
report("D commerce / security specs", require(Unit:WaitForChild("DCommerce.spec")).run(modules))
report("Prompt 02 map registry specs", require(Unit:WaitForChild("MapRegistry.spec")).run(modules))
report("Prompt 03 map selection specs", require(Unit:WaitForChild("MapSelection.spec")).run(modules))
report("Prompts 04/07 hub lifecycle specs", require(Unit:WaitForChild("HubLifecycle.spec")).run(modules))
report("Prompts 05/06 dressing specs", require(Unit:WaitForChild("Dressing.spec")).run(modules))
report("Protocol key specs", require(Unit:WaitForChild("ProtocolKeys.spec")).run(modules))
report("UI overhaul specs", require(Unit:WaitForChild("UIOverhaul.spec")).run(modules))
report("Environment specs", require(Unit:WaitForChild("Environment.spec")).run(modules))

------------------------------------------------------------------ integration (real engine)
local integration = { passed = 0, failed = 0, lines = {}, info = {} }
local function check(name, ok, detail)
	if ok then
		integration.passed = integration.passed + 1
		table.insert(integration.lines, "PASS  " .. name)
	else
		integration.failed = integration.failed + 1
		table.insert(integration.lines, "FAIL  " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
	end
end

local deadline = os.clock() + 20
while not workspace:GetAttribute(Protocol.WorkspaceAttributes.CourseReady) and os.clock() < deadline do
	task.wait(0.2)
end
local courseFolder = workspace:FindFirstChild(Protocol.CourseModelName)
-- B1: every world is built under TrainingCourse/<worldId>; check the active one here
local course = courseFolder and courseFolder:FindFirstChild(workspace:GetAttribute(Protocol.WorkspaceAttributes.ActiveWorld) or "")
check("world built and CourseReady published", course ~= nil and workspace:GetAttribute(Protocol.WorkspaceAttributes.CourseReady) == true)
check("no course validation errors", workspace:GetAttribute(Protocol.WorkspaceAttributes.CourseError) == nil, workspace:GetAttribute(Protocol.WorkspaceAttributes.CourseError))

if course then
	local layout = modules.TrackDefinitions.Generate(modules.TrackDefinitions.Race, PhysicsConfig.Ball.Radius)
	local expected = modules.Builder.ComputeSpecs(layout)
	local built = 0
	for _, d in ipairs(course:GetDescendants()) do
		if d:IsA("BasePart") then
			built = built + 1
		end
	end
	check("every computed race-track part exists", built == #expected, string.format("%d built vs %d specs", built, #expected))

	local floorParams = RaycastParams.new()
	floorParams.FilterType = Enum.RaycastFilterType.Include
	floorParams.FilterDescendantsInstances = { course:FindFirstChild("Floor") }
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Include
	overlap.FilterDescendantsInstances = { course }
	local blocked, unsupported = 0, 0
	for _, slot in ipairs(layout.GridSlots) do
		local p = slot.Frame.Position + slot.Frame.Right * slot.Offset + slot.Frame.Up * (PhysicsConfig.Ball.Radius + GameConfig.Spawn.SpawnLift)
		blocked = blocked + #workspace:GetPartBoundsInRadius(p, PhysicsConfig.Ball.Radius * 0.95, overlap)
		if not workspace:Raycast(p, Vector3.new(0, -10, 0), floorParams) then
			unsupported = unsupported + 1
		end
	end
	check("all 16 grid slots clear of geometry", blocked == 0, blocked .. " overlaps")
	check("all 16 grid slots have floor beneath", unsupported == 0, unsupported .. " unsupported")
	local floorHits, probes = 0, 0
	for i = 1, #layout.Route.points - 1, 2 do
		local p = (layout.Route.points[i] + layout.Route.points[i + 1]) / 2
		probes = probes + 1
		if workspace:Raycast(p, Vector3.new(0, -8, 0), floorParams) then
			floorHits = floorHits + 1
		end
	end
	check("floor exists under the whole race route", floorHits >= probes - 2, floorHits .. "/" .. probes .. " (falling tiles may be mid-drop)")
	-- A4 hazard instances the clients animate / the server toggles
	local hazardsFolder = course:FindFirstChild("Hazards")
	local roles = {}
	for _, d in ipairs(hazardsFolder and hazardsFolder:GetDescendants() or {}) do
		local role = d:IsA("BasePart") and d:GetAttribute("Role")
		if role then
			roles[role] = (roles[role] or 0) + 1
			if role == "Arm" or role == "Head" or role == "Arrow" or role == "FanDisc" then
				if d.CanCollide or d.CanQuery then
					check("moving hazard visual " .. d:GetFullName() .. " is non-colliding and unqueryable", false)
				end
			end
		end
	end
	check("hazard visuals tagged (sweeper arm, hammer head, 32 tiles, push arrows, trampoline pad)", (roles.Arm or 0) >= 1 and (roles.Head or 0) >= 1 and (roles.Tile or 0) == 32 and (roles.Arrow or 0) > 0 and (roles.Pad or 0) >= 1, string.format("arm %s head %s tile %s arrow %s pad %s", tostring(roles.Arm), tostring(roles.Head), tostring(roles.Tile), tostring(roles.Arrow), tostring(roles.Pad)))
	for _, cp in ipairs(layout.Checkpoints) do
		local p = cp.RespawnFrame.Position + cp.RespawnFrame.Up * (PhysicsConfig.Ball.Radius + GameConfig.Spawn.SpawnLift)
		check("checkpoint " .. cp.Index .. " respawn point clear with floor", #workspace:GetPartBoundsInRadius(p, 1.9, overlap) == 0 and workspace:Raycast(p, Vector3.new(0, -10, 0), floorParams) ~= nil)
	end
end

local hub = workspace:FindFirstChild(Protocol.HubModelName)
if hub then
	local hubParams = RaycastParams.new()
	hubParams.FilterType = Enum.RaycastFilterType.Include
	hubParams.FilterDescendantsInstances = { hub }
	local spawns = modules.HubBuilder.SpawnCFrames(modules.TrackDefinitions.Hub, PhysicsConfig.Ball.Radius, GameConfig.Spawn.SpawnLift)
	local supported = 0
	for _, cf in ipairs(spawns) do
		if workspace:Raycast(cf.Position, Vector3.new(0, -10, 0), hubParams) then
			supported = supported + 1
		end
	end
	check("all hub spawn spots have floor beneath", supported == #spawns, supported .. "/" .. #spawns)
end

check("CharacterAutoLoads is off (marble avatar only)", Players.CharacterAutoLoads == false)
task.wait(3)
local humanoids = 0
for _, d in ipairs(workspace:GetDescendants()) do
	if d:IsA("Humanoid") then
		humanoids = humanoids + 1
	end
end
check("no Humanoid anywhere in Workspace", humanoids == 0, humanoids)
local marbles = workspace:FindFirstChild(Protocol.MarblesFolderName)
for _, player in ipairs(Players:GetPlayers()) do
	local ball = marbles and marbles:FindFirstChild(Protocol.MarbleName(player.UserId))
	check(player.Name .. ": marble exists", ball ~= nil)
	if ball then
		local colliders = ball.CanCollide and 1 or 0
		for _, part in ipairs(ball:GetDescendants()) do
			if part:IsA("BasePart") and part.CanCollide then
				colliders = colliders + 1
			end
		end
		check(player.Name .. ": exactly one collider (BallRoot)", colliders == 1, colliders)
		check(player.Name .. ": BallRoot is a 4-stud ball", ball.Shape == Enum.PartType.Ball and math.abs(ball.Size.X - 4) < 1e-3)
		if not ball.Anchored then
			local expectedMass = PhysicsConfig.Ball.Density * (4 / 3) * math.pi * PhysicsConfig.Ball.Radius ^ 3
			check(player.Name .. ": assembly mass = ball only", math.abs(ball.AssemblyMass - expectedMass) / expectedMass < 0.05, string.format("%.2f vs %.2f", ball.AssemblyMass, expectedMass))
		end
		check(player.Name .. ": no Character", player.Character == nil)
	end
end
report("Studio integration (engine)", integration)

local roundSpec = require(Integration:WaitForChild("MultiplayerRound.spec"))
report("Studio integration (round)", roundSpec.run(modules))
-- A6 soak: GameConfig.Debug.SoakMinutes = 15 observes that long (one timeline line per transition
-- with bots, bot marbles, hazard seed and instance count) - compare Intermission lines for leaks.
local observeSeconds = math.max(120, (GameConfig.Debug.SoakMinutes or 0) * 60)
print("[TumbleTests] observing the round for " .. observeSeconds .. " s (timeline prints afterwards)...")
roundSpec.observe(modules, observeSeconds, function(timeline)
	print("[TumbleTests] timeline (" .. #timeline .. " transitions):")
	for _, line in ipairs(timeline) do
		print("[TumbleTests]   " .. line)
	end
end)
