--[[
	Offline test entry point.   texlua tools/offline/run_tests.lua [projectRoot]
	1) Syntax-checks every .lua file in the project with the Lua 5.3 parser (the source is written
	   in the Lua 5.1 subset of Luau so this is meaningful; it is NOT a Luau type check).
	2) Runs src/Tests/A1PureSpecs.lua against the pure modules using the datatype shim.
]]

local root = arg[1] or "."

local failures = 0
local files = {}
local function walk(dir)
	for entry in lfs.dir(dir) do
		if entry ~= "." and entry ~= ".." then
			local path = dir .. "/" .. entry
			local mode = lfs.attributes(path, "mode")
			if mode == "directory" then
				walk(path)
			elseif entry:match("%.lua$") then
				files[#files + 1] = path
			end
		end
	end
end
walk(root .. "/src")
walk(root .. "/tools")
files[#files + 1] = root .. "/PLACEHOLDER_IDS.lua"
table.sort(files)

print("== Syntax (Lua 5.3 parser over Lua-5.1-subset Luau) ==")
for _, path in ipairs(files) do
	local chunk, err = loadfile(path)
	if chunk then
		print("ok    " .. path:sub(#root + 2))
	else
		failures = failures + 1
		print("FAIL  " .. tostring(err))
	end
end

print("\n== A1 pure specs ==")
local H = dofile(root .. "/tools/offline/harness.lua").new(root)
local modules = {
	GameConfig = H.module("ReplicatedStorage/Shared/GameConfig"),
	PhysicsConfig = H.module("ReplicatedStorage/Shared/PhysicsConfig"),
	Protocol = H.module("ReplicatedStorage/Shared/Protocol"),
	Utility = H.module("ReplicatedStorage/Shared/Utility"),
	RouteTracker = H.module("ReplicatedStorage/Shared/RouteTracker"),
	TrackDefinitions = H.module("ReplicatedStorage/Shared/TrackDefinitions"),
	PlaceholderIds = H.module("ReplicatedStorage/Shared/PlaceholderIds"),
	Builder = H.module("ServerStorage/ProceduralBuilders/TrainingTrackBuilder"),
	HubBuilder = H.module("ServerStorage/ProceduralBuilders/HubBuilder"),
	ThemedHubBuilder = H.module("ServerStorage/ProceduralBuilders/ThemedHubBuilder"),
	RaceConfig = H.module("ReplicatedStorage/Shared/RaceConfig"),
	MotionFeel = H.module("ReplicatedStorage/Shared/MotionFeel"),
	RoundProtocol = H.module("ReplicatedStorage/Shared/RoundProtocol"),
	RaceRules = H.module("ServerScriptService/Services/RaceRules"),
	CheckpointService = H.module("ServerScriptService/Services/CheckpointService"),
	AbilityConfig = H.module("ReplicatedStorage/Shared/AbilityConfig"),
	SkillRules = H.module("ServerScriptService/Services/SkillRules"),
	HazardSim = H.module("ReplicatedStorage/Shared/HazardSim"),
	TrackValidator = H.module("ServerScriptService/Services/TrackValidator"),
	BotBrain = H.module("ServerScriptService/Services/BotBrain"),
	ChaosGateService = H.module("ServerScriptService/Services/ChaosGateService"),
	ProgressionConfig = H.module("ReplicatedStorage/Shared/ProgressionConfig"),
	PlayerDataSchema = H.module("ReplicatedStorage/Shared/PlayerDataSchema"),
	ProfileStore = H.module("ServerScriptService/Services/ProfileStore"),
	RewardRules = H.module("ServerScriptService/Services/RewardRules"),
	UIController = H.module("StarterPlayer/StarterPlayerScripts/Controllers/UIController"),
	VoteRules = H.module("ServerScriptService/Services/VoteRules"),
	MapVoteRules = H.module("ServerScriptService/Services/MapVoteRules"),
	PartyRules = H.module("ServerScriptService/Services/PartyRules"),
	TimeTrialRules = H.module("ReplicatedStorage/Shared/TimeTrialRules"),
	AbilityRules = H.module("ServerScriptService/Services/AbilityRules"),
	SocialConfig = H.module("ReplicatedStorage/Shared/SocialConfig"),
	Catalog = H.module("ReplicatedStorage/Shared/Catalog"),
	MarbleLook = H.module("ReplicatedStorage/Shared/MarbleLook"),
	QuestConfig = H.module("ReplicatedStorage/Shared/QuestConfig"),
	CosmeticService = H.module("ServerScriptService/Services/CosmeticService"),
	CapsuleOdds = H.module("ReplicatedStorage/Shared/CapsuleOdds"),
	SeasonConfig = H.module("ReplicatedStorage/Shared/SeasonConfig"),
	CapsuleService = H.module("ServerScriptService/Services/CapsuleService"),
	SeasonService = H.module("ServerScriptService/Services/SeasonService"),
	ShopConfig = H.module("ReplicatedStorage/Shared/ShopConfig"),
	MapRegistry = H.module("ReplicatedStorage/Shared/MapRegistry"),
	VisualProfiles = H.module("ReplicatedStorage/Shared/VisualProfiles"),
	MapLoader = H.module("ServerScriptService/Services/MapLoader"),
	BallotRules = H.module("ServerScriptService/Services/BallotRules"),
	Dressing = H.module("ReplicatedStorage/Shared/Dressing"),
	EnvironmentProfiles = H.module("ReplicatedStorage/Shared/EnvironmentProfiles"),
	HubRules = H.module("ServerScriptService/Services/HubRules"),
}
-- A5 client modules: load-time references to client services are stubbed; only their pure
-- functions (Step / Choose / PbLine) are exercised.
H.stubServices = { Players = {}, TweenService = {}, UserInputService = {} }
modules.SettingsPure = H.module("StarterPlayer/StarterPlayerScripts/Controllers/SettingsController")
modules.LoadoutPure = H.module("StarterPlayer/StarterPlayerScripts/Controllers/StarterLoadoutController")
modules.ResultsPure = H.module("StarterPlayer/StarterPlayerScripts/Controllers/ResultsController")
modules.SocialPure = H.module("StarterPlayer/StarterPlayerScripts/Controllers/SocialController")
H.stubServices = { Players = {}, RunService = {}, DataStoreService = {}, UserService = {} }
modules.HubMenusPure = H.module("StarterPlayer/StarterPlayerScripts/Controllers/HubMenusController")
modules.LeaderboardService = H.module("ServerScriptService/Services/LeaderboardService")
H.stubServices = { Players = {}, RunService = {}, HttpService = {} }
modules.LabPure = H.module("StarterPlayer/StarterPlayerScripts/Controllers/LabController")
H.stubServices = { Players = {}, RunService = {}, HttpService = {}, MarketplaceService = {}, PolicyService = {} }
modules.ShopPure = H.module("StarterPlayer/StarterPlayerScripts/Controllers/ShopController")
modules.ProductService = H.module("ServerScriptService/Services/ProductService")
modules.AntiCheatService = H.module("ServerScriptService/Services/AntiCheatService")
H.stubServices = { RunService = {} }
modules.FeatureGates = H.module("ServerScriptService/Services/FeatureGates")
H.stubServices = { Players = {}, RunService = {}, TweenService = {}, UserInputService = {} }
modules.MapSelectPure = H.module("StarterPlayer/StarterPlayerScripts/Controllers/MapSelectController")
modules.UIKitPure = H.module("StarterPlayer/StarterPlayerScripts/Controllers/UIKit")
modules.TouchControlsPure = H.module("StarterPlayer/StarterPlayerScripts/Controllers/TouchControls")
modules.RaceIntroPure = H.module("StarterPlayer/StarterPlayerScripts/Controllers/RaceIntroController")
modules.SpeedFeelPure = H.module("StarterPlayer/StarterPlayerScripts/Controllers/SpeedFeelController")
modules.RevealPure = H.module("StarterPlayer/StarterPlayerScripts/Controllers/CapsuleRevealController")
modules.CameraPure = H.module("StarterPlayer/StarterPlayerScripts/Controllers/CameraController")
H.stubServices = {}

-- A5 UI text scan: every string literal in client code (comments stripped).
do
	local strings, marketplace = {}, false
	local function stripComments(text)
		text = text:gsub("%-%-%[(=*)%[.-%]%1%]", "")
		local out = {}
		for line in (text .. "\n"):gmatch("(.-)\n") do
			local inString, quote, cut = false, nil, nil
			local i = 1
			while i <= #line do
				local c = line:sub(i, i)
				if inString then
					if c == "\\" then
						i = i + 1
					elseif c == quote then
						inString = false
					end
				elseif c == '"' or c == "'" then
					inString, quote = true, c
				elseif line:sub(i, i + 1) == "--" then
					cut = i
					break
				end
				i = i + 1
			end
			out[#out + 1] = cut and line:sub(1, cut - 1) or line
		end
		return table.concat(out, "\n")
	end
	for _, path in ipairs(files) do
		local f = io.open(path, "r")
		local text = f and f:read("a") or ""
		if f then
			f:close()
		end
		local code = stripComments(text)
		-- D: MarketplaceService is allowed only in the optional shop (ProductService server-side,
		-- ShopController for prompts / localized prices); anywhere else fails the check
		local shopFile = path:find("ProductService.lua", 1, true) or path:find("ShopController.lua", 1, true)
		if path:find("/src/", 1, true) and not path:find("/src/Tests/", 1, true) and not shopFile and code:find("MarketplaceService", 1, true) then
			marketplace = true
		end
		if path:find("StarterPlayerScripts", 1, true) and not shopFile then
			for literal in code:gmatch('"([^"]*)"') do
				strings[#strings + 1] = literal
			end
		end
	end
	modules.ClientUiStrings = strings
	modules.UsesMarketplace = marketplace
end
-- HazardController.PhaseAt is pure; load the client module file directly for that one function.
do
	local env = setmetatable({ game = H.game, require = H.require, script = nil }, { __index = _G })
	local chunk = assert(loadfile(root .. "/src/StarterPlayer/StarterPlayerScripts/Controllers/HazardController.lua", "t", env))
	local controller = chunk()
	modules.HazardPhase = controller.PhaseAt
	modules.HazardControllerPure = controller -- SweeperArmCFrame / HammerHeadCFrame are pure
end

-- A4 free look: the real CameraController against a fake camera/workspace (offline only).
do
	local motorFile = assert(io.open(root .. "/src/ReplicatedStorage/Shared/MarbleMotorController.lua", "r"))
	modules.MotorSource = motorFile:read("a")
	motorFile:close()
	local function connection()
		return { Disconnect = function() end }
	end
	modules.CameraHarness = {
		new = function()
			local camera = { FieldOfView = 70 }
			local fakeWorkspace = {
				CurrentCamera = camera,
				GetPropertyChangedSignal = function()
					return { Connect = connection }
				end,
				Raycast = function()
					return nil
				end,
			}
			local env = setmetatable({
				game = H.game,
				require = H.require,
				workspace = fakeWorkspace,
				RaycastParams = { new = function() return {} end },
				Enum = {
					RaycastFilterType = { Exclude = "Exclude" },
					CameraType = { Scriptable = "Scriptable", Custom = "Custom" },
				},
				math = setmetatable({ atan2 = math.atan2 or math.atan }, { __index = math }),
			}, { __index = _G })
			local chunk = assert(loadfile(root .. "/src/StarterPlayer/StarterPlayerScripts/Controllers/CameraController.lua", "t", env))
			return chunk().new(), camera
		end,
	}
end

-- Hub free roam: the real shared MarbleMotorController with a fake ball / force (offline only).
do
	modules.MotorHarness = {
		new = function()
			local fakeWorkspace = {
				Gravity = 196.2,
				Spherecast = function()
					return { Normal = Vector3.new(0, 1, 0) } -- always on flat ground
				end,
				GetServerTimeNow = function()
					return os.clock()
				end,
			}
			local env = setmetatable({
				game = H.game,
				require = H.require,
				workspace = fakeWorkspace,
				RaycastParams = { new = function() return {} end },
				Enum = { RaycastFilterType = { Exclude = "Exclude" } },
			}, { __index = _G })
			local chunk = assert(loadfile(root .. "/src/ReplicatedStorage/Shared/MarbleMotorController.lua", "t", env))
			local Motor = chunk()
			local motor = Motor.new()
			local ball = { Position = Vector3.new(0, 0, 0), AssemblyLinearVelocity = Vector3.new(0, 0, 0), AssemblyMass = 1, Anchored = false, Parent = true }
			local force = { Force = Vector3.new(0, 0, 0), Parent = true }
			motor.ball, motor.force = ball, force
			return motor, ball, force, Motor
		end,
	}
end

modules.ListFiles = function(rel) -- every .lua file at / under rel (offline only)
	local out = {}
	local full = root .. "/" .. rel
	if lfs.attributes(full, "mode") == "file" then
		return { rel }
	end
	local function walkDir(dir, prefix)
		for entry in lfs.dir(dir) do
			if entry ~= "." and entry ~= ".." then
				local path = dir .. "/" .. entry
				if lfs.attributes(path, "mode") == "directory" then
					walkDir(path, prefix .. "/" .. entry)
				elseif entry:match("%.lua$") then
					out[#out + 1] = prefix .. "/" .. entry
				end
			end
		end
	end
	walkDir(full, rel)
	table.sort(out)
	return out
end
modules.ReadFile = function(rel) -- B3 specs read a source file (offline only)
	local f = assert(io.open(root .. "/" .. rel))
	local text = f:read("*a")
	f:close()
	return text
end

local suites = {
	{ "A1 pure specs", root .. "/src/Tests/Unit/A1PureSpecs.lua" },
	{ "A2 round specs", root .. "/src/Tests/Unit/RoundState.spec.lua" },
	{ "A3 ability specs", root .. "/src/Tests/Unit/Ability.spec.lua" },
	{ "A3 micro-skill specs", root .. "/src/Tests/Unit/MicroSkill.spec.lua" },
	{ "A3 ability security specs", root .. "/src/Tests/Unit/AbilitySecurity.spec.lua" },
	{ "A4 track validation specs", root .. "/src/Tests/Unit/TrackValidation.spec.lua" },
	{ "A4 hazard reset specs", root .. "/src/Tests/Unit/HazardReset.spec.lua" },
	{ "A4 bot navigation specs", root .. "/src/Tests/Unit/BotNavigation.spec.lua" },
	{ "A4 chaos gate specs", root .. "/src/Tests/Unit/ChaosGate.spec.lua" },
	{ "A4 ready vote specs", root .. "/src/Tests/Unit/ReadyVote.spec.lua" },
	{ "A4 free look specs (offline only)", root .. "/src/Tests/Unit/FreeLook.spec.lua" },
	{ "Hub free roam specs (offline only)", root .. "/src/Tests/Unit/HubFreeRoam.spec.lua" },
	{ "B1 world specs", root .. "/src/Tests/Unit/Worlds.spec.lua" },
	{ "B1 rules specs", root .. "/src/Tests/Unit/B1Rules.spec.lua" },
	{ "B2 ability specs", root .. "/src/Tests/Unit/B2Abilities.spec.lua" },
	{ "B3 progression specs", root .. "/src/Tests/Unit/B3Progression.spec.lua" },
	{ "C capsule / season specs", root .. "/src/Tests/Unit/CCapsules.spec.lua" },
	{ "D commerce / security specs", root .. "/src/Tests/Unit/DCommerce.spec.lua" },
	{ "Prompt 02 map registry specs", root .. "/src/Tests/Unit/MapRegistry.spec.lua" },
	{ "Prompt 03 map selection specs", root .. "/src/Tests/Unit/MapSelection.spec.lua" },
	{ "Prompts 04/07 hub lifecycle specs", root .. "/src/Tests/Unit/HubLifecycle.spec.lua" },
	{ "Prompts 05/06 dressing specs", root .. "/src/Tests/Unit/Dressing.spec.lua" },
	{ "Protocol key specs", root .. "/src/Tests/Unit/ProtocolKeys.spec.lua" },
	{ "UI overhaul specs", root .. "/src/Tests/Unit/UIOverhaul.spec.lua" },
	{ "Environment specs", root .. "/src/Tests/Unit/Environment.spec.lua" },
	{ "Motion specs (UI entrances, race entry)", root .. "/src/Tests/Unit/Motion.spec.lua" },
	{ "A5 persistence specs", root .. "/src/Tests/Unit/Persistence.spec.lua" },
	{ "A5 reward idempotence specs", root .. "/src/Tests/Unit/RewardIdempotence.spec.lua" },
	{ "A5 UI state specs", root .. "/src/Tests/Unit/UIState.spec.lua" },
	{ "A6 social specs", root .. "/src/Tests/Unit/Social.spec.lua" },
}
local passed, failed = 0, 0
-- Boot smoke (2026-11-26): both bootstrap main chunks run end to end against proxy Roblox APIs
do
	print("\n-- Boot smoke (main chunks, proxy Roblox APIs) --")
	BOOT_SMOKE_AS_MODULE = true
	local boot = dofile(root .. "/tools/offline/boot_smoke.lua")
	BOOT_SMOKE_AS_MODULE = nil
	local realPrint = print
	for _, target in ipairs({ "ServerScriptService/ServerBootstrap.server", "StarterPlayer/StarterPlayerScripts/ClientBootstrap.client" }) do
		local okRun, err = boot(root, target)
		if okRun then
			passed = passed + 1
			realPrint("PASS  " .. target .. " main chunk completes")
		else
			failed = failed + 1
			realPrint("FAIL  " .. target .. " main chunk  -- " .. tostring(err):match("[^\n]*"))
		end
	end
end
for _, suite in ipairs(suites) do
	local results = dofile(suite[2]).run(modules)
	print("\n-- " .. suite[1] .. " --")
	for _, line in ipairs(results.lines) do
		print(line)
	end
	for _, line in ipairs(results.info) do
		print("info  " .. line)
	end
	passed, failed = passed + results.passed, failed + results.failed
end
print(string.format("\n%d passed, %d failed (+ %d syntax failures)", passed, failed, failures))
os.exit((failed + failures) == 0 and 0 or 1)
