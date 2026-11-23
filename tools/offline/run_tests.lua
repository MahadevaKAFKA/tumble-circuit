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
	RaceConfig = H.module("ReplicatedStorage/Shared/RaceConfig"),
	RoundProtocol = H.module("ReplicatedStorage/Shared/RoundProtocol"),
	RaceRules = H.module("ServerScriptService/Services/RaceRules"),
	CheckpointService = H.module("ServerScriptService/Services/CheckpointService"),
}
-- HazardController.PhaseAt is pure; load the client module file directly for that one function.
do
	local env = setmetatable({ game = H.game, require = H.require, script = nil }, { __index = _G })
	local chunk = assert(loadfile(root .. "/src/StarterPlayer/StarterPlayerScripts/Controllers/HazardController.lua", "t", env))
	modules.HazardPhase = chunk().PhaseAt
end

local suites = {
	{ "A1 pure specs", root .. "/src/Tests/Unit/A1PureSpecs.lua" },
	{ "A2 round specs", root .. "/src/Tests/Unit/RoundState.spec.lua" },
}
local passed, failed = 0, 0
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
