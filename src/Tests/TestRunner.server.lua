--[[
	TestRunner — runs automatically when you press Play in Studio (GameConfig.Debug.RunTestsInStudio).
	Prints to the Output window:
	  1) A1PureSpecs (same assertions the offline harness runs)
	  2) Studio integration checks that need the real engine: built course, spawn clearance,
	     remotes, no Characters/Humanoids, marble body (single collider, mass, ownership-ready).
	It never changes gameplay state. Disabled automatically outside Studio.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
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

local modules = {
	GameConfig = GameConfig,
	PhysicsConfig = PhysicsConfig,
	Protocol = Protocol,
	Utility = require(Shared:WaitForChild("Utility")),
	RouteTracker = require(Shared:WaitForChild("RouteTracker")),
	TrackDefinitions = require(Shared:WaitForChild("TrackDefinitions")),
	PlaceholderIds = require(Shared:WaitForChild("PlaceholderIds")),
	Builder = require(ServerStorage:WaitForChild("ProceduralBuilders"):WaitForChild("TrainingTrackBuilder")),
}
local okHazard, hazardModule = pcall(function()
	return require(StarterPlayer:WaitForChild("StarterPlayerScripts"):WaitForChild("Controllers"):WaitForChild("HazardController"))
end)
if okHazard then
	modules.HazardPhase = hazardModule.PhaseAt
end

local Specs = require(script.Parent:WaitForChild("A1PureSpecs"))

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

local pure = Specs.run(modules)
report("A1 pure specs", pure)

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
local course = workspace:FindFirstChild(Protocol.CourseModelName)
check("course built and CourseReady published", course ~= nil and workspace:GetAttribute(Protocol.WorkspaceAttributes.CourseReady) == true)
check("no course validation errors", workspace:GetAttribute(Protocol.WorkspaceAttributes.CourseError) == nil, workspace:GetAttribute(Protocol.WorkspaceAttributes.CourseError))

if course then
	local layout = modules.TrackDefinitions.Generate(modules.TrackDefinitions.Training, PhysicsConfig.Ball.Radius)
	local expected = modules.Builder.ComputeSpecs(layout)
	local built = 0
	for _, d in ipairs(course:GetDescendants()) do
		if d:IsA("BasePart") then
			built = built + 1
		end
	end
	check("every computed part exists in Workspace", built == #expected, string.format("%d built vs %d specs", built, #expected))
	check("course has floor, rails, decor, hazards", course:FindFirstChild("Floor") and course:FindFirstChild("Rails") and course:FindFirstChild("Decor") and course:FindFirstChild("Hazards") and true or false)

	local spawn = layout.SpawnFrame
	local spawnPos = spawn.Position + spawn.Up * (PhysicsConfig.Ball.Radius + GameConfig.Spawn.SpawnLift)
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Include
	overlap.FilterDescendantsInstances = { course }
	local blocking = workspace:GetPartBoundsInRadius(spawnPos, PhysicsConfig.Ball.Radius * 0.95, overlap)
	check("spawn point is clear of course geometry", #blocking == 0, #blocking .. " parts overlap")
	local below = workspace:Raycast(spawnPos, Vector3.new(0, -10, 0), (function()
		local p = RaycastParams.new()
		p.FilterType = Enum.RaycastFilterType.Include
		p.FilterDescendantsInstances = { course:FindFirstChild("Floor") }
		return p
	end)())
	check("spawn point has floor beneath it", below ~= nil)
	local floorHits, probes = 0, 0
	local probeParams = RaycastParams.new()
	probeParams.FilterType = Enum.RaycastFilterType.Include
	probeParams.FilterDescendantsInstances = { course:FindFirstChild("Floor") }
	for i = 1, #layout.Route.points - 1, 2 do
		local p = (layout.Route.points[i] + layout.Route.points[i + 1]) / 2
		probes = probes + 1
		if workspace:Raycast(p, Vector3.new(0, -8, 0), probeParams) then
			floorHits = floorHits + 1
		end
	end
	check("floor exists under the whole route centreline", floorHits == probes, floorHits .. "/" .. probes)
end

local remotes = ReplicatedStorage:FindFirstChild(Protocol.RemotesFolderName)
local remoteNames = {}
if remotes then
	for _, child in ipairs(remotes:GetChildren()) do
		table.insert(remoteNames, child.ClassName .. ":" .. child.Name)
	end
end
check("server created exactly the RequestReset RemoteEvent", #remoteNames == 1 and remoteNames[1] == "RemoteEvent:RequestReset", table.concat(remoteNames, ","))
check("CharacterAutoLoads is off (marble avatar only)", Players.CharacterAutoLoads == false)

task.wait(3) -- let Play Solo's player spawn
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
		local colliders = 0
		for _, part in ipairs(ball:GetDescendants()) do
			if part:IsA("BasePart") and part.CanCollide then
				colliders = colliders + 1
			end
		end
		if ball.CanCollide then
			colliders = colliders + 1
		end
		check(player.Name .. ": exactly one collider (BallRoot)", colliders == 1, colliders)
		check(player.Name .. ": BallRoot is a 4-stud ball", ball.Shape == Enum.PartType.Ball and math.abs(ball.Size.X - 4) < 1e-3)
		local expectedMass = PhysicsConfig.Ball.Density * (4 / 3) * math.pi * PhysicsConfig.Ball.Radius ^ 3
		check(player.Name .. ": assembly mass = ball only (stripes massless)", math.abs(ball.AssemblyMass - expectedMass) / expectedMass < 0.05, string.format("%.2f vs %.2f", ball.AssemblyMass, expectedMass))
		check(player.Name .. ": not anchored", not ball.Anchored)
		check(player.Name .. ": no Character", player.Character == nil)
	end
end

report("A1 Studio integration", integration)
