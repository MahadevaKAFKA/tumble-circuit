--[[
	TrainingTrackService — builds and owns every course (A2, A4, B1), now through MapRegistry
	(promo pack prompt 02):
	  zone "Race": the ACTIVE map, one of the registry's enabled maps (Neon Foundry, Sky Carnival,
	               Volcano Vault). All are built once at boot under workspace.TrainingCourse
	               /<mapId> (pooled, never rebuilt); SetActiveWorld switches which one the Race
	               zone means and fires WorldChanged. Each is validated (TrackValidator +
	               MapLoader); a failing non-default map is dropped from rotation, Neon Foundry is
	               the known-safe fallback.
	  zone "Hub" : a registry hub (deck + its Practice Chute). Orbital Garage is the default and
	               the only one a caller gets without naming a hub id.
	Reused every round (only the start gates toggle).
	Exposes layouts, spawn CFrames, kill heights and the gate to the other services.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local MapRegistry = require(Shared:WaitForChild("MapRegistry"))
local PhysicsConfig = require(Shared:WaitForChild("PhysicsConfig"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local TrackDefinitions = require(Shared:WaitForChild("TrackDefinitions"))
local VisualProfiles = require(Shared:WaitForChild("VisualProfiles"))
local Builders = ServerStorage:WaitForChild("ProceduralBuilders")
local Builder = require(Builders:WaitForChild("TrainingTrackBuilder"))
local HubBuilder = require(Builders:WaitForChild("HubBuilder"))
local ThemedHubBuilder = require(Builders:WaitForChild("ThemedHubBuilder"))
local MapLoader = require(script.Parent:WaitForChild("MapLoader"))
local TrackValidator = require(script.Parent:WaitForChild("TrackValidator"))
local Utility = require(Shared:WaitForChild("Utility"))

-- Registry builder names -> builder functions (server only; MapRegistry only names them).
local TRACK_BUILDERS = {
	SplineCourse = function(layout, parent, name)
		return Builder.Build(layout, parent, name)
	end,
}
local HUB_BUILDERS = {
	RingDeck = function(entry, parent, chuteWidth)
		return HubBuilder.Build(entry.Geometry, parent, entry.ModelName, chuteWidth, Builder.MakePart, entry.Meta and entry.Meta.BoardTitle)
	end,
	ThemedDeck = function(entry, parent, chuteWidth, chuteLayout) -- prompt 04: map hubs
		return ThemedHubBuilder.Build(entry.Geometry, parent, entry.ModelName, chuteWidth, Builder.MakePart, entry.Meta and entry.Meta.BoardTitle, chuteLayout)
	end,
}

local TrainingTrackService = {}
TrainingTrackService.__index = TrainingTrackService

local ZONES = Protocol.Zones

function TrainingTrackService.new(options)
	local self = setmetatable({}, TrainingTrackService)
	self.layouts = {}
	self.killY = {}
	self.validationErrors = {}
	self.worlds = {} -- [worldId] = { def, layout, root, killY, startGate }
	self.worldOrder = {} -- enabled map ids in registry order (rotation order)
	self.hubs = {} -- [hubId] = { entry, layout, root, spawns, cursor, killY }
	self.hubOrder = {}
	self.droppedMaps = {} -- [mapId] = reason
	self.serverFeatures = (options and options.features) or {} -- gates enabled server-wide
	self.activeWorldId = nil
	self.WorldChanged = Utility.Signal.new() -- (worldId, layout)
	return self
end

function TrainingTrackService:ApplyEnvironment()
	if PhysicsConfig.GravityMultiplier ~= 1 then
		workspace.Gravity = 196.2 * PhysicsConfig.GravityMultiplier
	end
	local bloom = Lighting:FindFirstChild("TC_Bloom") or Instance.new("BloomEffect")
	bloom.Name = "TC_Bloom"
	bloom.Parent = Lighting
	local grade = Lighting:FindFirstChild("TC_Grade") or Instance.new("ColorCorrectionEffect")
	grade.Name = "TC_Grade"
	grade.Parent = Lighting
	-- prompt 02: the same night environment as before, now read from the default profile;
	-- clients switch profiles locally per zone (prompt 04), the server never does.
	VisualProfiles.Apply(Lighting, VisualProfiles.Get(VisualProfiles.Default), { bloom = bloom, grade = grade })
end

local function note(self, id, message)
	table.insert(self.validationErrors, id .. ": " .. message)
	warn("[Track] " .. id .. ": " .. message)
end

local function trackErrors(def, layout, full)
	return full and TrackValidator.Validate(def, layout) or TrackDefinitions.Validate(def, layout)
end

local function buildMap(self, map, courseFolder, radius)
	local def = TrackDefinitions.WorldsById[map.Track]
	assert(def, "track " .. tostring(map.Track) .. " is not defined")
	local build = TRACK_BUILDERS[map.Builder]
	assert(build, "missing builder " .. tostring(map.Builder))
	local layout = TrackDefinitions.Generate(def, radius)
	local killY = layout.MinY - PhysicsConfig.Server.KillDepthBelowCourse
	local errors = trackErrors(def, layout, true)
	for _, message in ipairs(MapLoader.ValidateCourse(layout, killY)) do
		errors[#errors + 1] = message
	end
	local root, count = build(layout, courseFolder, map.Id)
	return {
		def = def,
		layout = layout,
		root = root,
		count = count,
		killY = killY,
		startGate = root:FindFirstChild("Gates") and root.Gates:FindFirstChild("StartGate"),
	}, errors
end

local function buildHub(self, entry, radius)
	local build = HUB_BUILDERS[entry.Builder]
	assert(build, "missing hub builder " .. tostring(entry.Builder))
	local chute = TrackDefinitions.Generate(entry.Chute, radius)
	local errors = trackErrors(entry.Chute, chute, false)
	local geometry = entry.Geometry
	local killY = math.min(geometry.Center.Y, chute.MinY) - PhysicsConfig.Server.KillDepthBelowCourse
	local spawns = HubBuilder.SpawnCFrames(geometry, radius, GameConfig.Spawn.SpawnLift)
	for _, message in ipairs(MapLoader.ValidateHub(geometry, chute, spawns, killY)) do
		errors[#errors + 1] = message
	end
	local root, hubCount = build(entry, workspace, entry.Chute.Pieces[1].Width[1], chute)
	local _, chuteCount = Builder.Build(chute, root, "PracticeChute")
	root:SetAttribute("HubId", entry.Id)
	return { entry = entry, layout = chute, root = root, spawns = spawns, cursor = 0, killY = killY, count = hubCount + chuteCount }, errors
end

function TrainingTrackService:Build()
	local radius = PhysicsConfig.Ball.Radius
	local started = os.clock()
	local names = { Protocol.CourseModelName, Protocol.HubModelName }
	for _, entry in ipairs(MapRegistry.Hubs) do
		names[#names + 1] = entry.ModelName
	end
	for _, name in ipairs(names) do
		local existing = workspace:FindFirstChild(name)
		if existing then
			existing:Destroy()
		end
	end
	for _, message in ipairs(MapRegistry.ValidateStatic(TrackDefinitions)) do
		note(self, "registry", message)
	end

	-- Race maps: each enabled registry map built once; a failing non-default map is dropped
	local courseFolder = Instance.new("Folder")
	courseFolder.Name = Protocol.CourseModelName
	local raceCount = 0
	local results, built = {}, {}
	for _, map in ipairs(MapRegistry.EnabledMaps(self.serverFeatures)) do
		local ok, world, errors = pcall(buildMap, self, map, courseFolder, radius)
		if not ok then
			errors = { tostring(world) }
			world = nil
			local partial = courseFolder:FindFirstChild(map.Id)
			if partial then
				partial:Destroy()
			end
		end
		for _, message in ipairs(errors) do
			note(self, map.Id, message)
		end
		results[#results + 1] = { id = map.Id, ok = ok, errors = errors }
		built[map.Id] = world
	end
	local enabled, dropped, fatal = MapLoader.Decide(results, MapRegistry.DefaultMapId)
	if fatal then
		error("[Track] " .. fatal) -- nothing safer to fall back to: fail loudly, as before
	end
	for _, id in ipairs(enabled) do
		local world = built[id]
		self.worlds[id] = world
		self.worldOrder[#self.worldOrder + 1] = id
		raceCount = raceCount + world.count
	end
	for id, reason in pairs(dropped) do
		self.droppedMaps[id] = reason
		local world = built[id]
		if world and world.root then
			world.root:Destroy()
		end
	end
	self:_buildChallenges(courseFolder, radius)
	courseFolder.Parent = workspace
	local firstId = self.worlds[MapRegistry.DefaultMapId] and MapRegistry.DefaultMapId or self.worldOrder[1]
	self:SetActiveWorld(firstId)
	local race = self.layouts[ZONES.Race]

	-- Hubs: every Live/Gated registry hub (gated hubs are chosen per player, so they exist)
	local hubCount = 0
	for _, entry in ipairs(MapRegistry.Hubs) do
		if entry.Status == "Live" or entry.Status == "Gated" then
			local ok, hub, errors = pcall(buildHub, self, entry, radius)
			if not ok then
				errors = { tostring(hub) }
				hub = nil
			end
			for _, message in ipairs(errors) do
				note(self, entry.Id, message)
			end
			if entry.Id == MapRegistry.DefaultHubId then
				if not hub then
					error("[Track] default hub failed to build: " .. tostring(errors[1]))
				end
			elseif #errors > 0 then
				if hub and hub.root then
					hub.root:Destroy()
				end
				hub = nil
			end
			if hub then
				self.hubs[entry.Id] = hub
				self.hubOrder[#self.hubOrder + 1] = entry.Id
				hubCount = hubCount + hub.count
			else
				local leftover = workspace:FindFirstChild(entry.ModelName)
				if leftover and entry.Id ~= MapRegistry.DefaultHubId then
					leftover:Destroy()
				end
			end
		end
	end
	local defaultHub = self.hubs[MapRegistry.DefaultHubId]
	self.layouts[ZONES.Hub] = defaultHub.layout
	self.hubRoot = defaultHub.root
	self.hubSpawns = defaultHub.spawns
	self.killY[ZONES.Hub] = defaultHub.killY

	workspace:SetAttribute(Protocol.WorkspaceAttributes.MapsEnabled, table.concat(self.worldOrder, ","))
	workspace:SetAttribute(Protocol.WorkspaceAttributes.HubsEnabled, table.concat(self.hubOrder, ","))
	if #self.validationErrors > 0 then
		workspace:SetAttribute(Protocol.WorkspaceAttributes.CourseError, table.concat(self.validationErrors, "; "))
	end
	workspace:SetAttribute(Protocol.WorkspaceAttributes.CourseReady, true)
	print(string.format(
		"[Track] built %d maps (%d parts; active %s, %.0f studs, %d checkpoints) + %d hubs (%d parts) in %.1f ms",
		#self.worldOrder, raceCount, tostring(firstId), race.Route.total, #race.Checkpoints, #self.hubOrder, hubCount, (os.clock() - started) * 1000
	))
end

-- B1: switch the world the Race zone means. Only RoundService calls this, between races
-- (Preparing). Every start gate except the active one stays closed.
function TrainingTrackService:SetActiveWorld(worldId)
	local world = self.worlds[worldId]
	if not world then
		warn("[Track] unknown world " .. tostring(worldId))
		return false
	end
	if self.activeWorldId == worldId then
		return true
	end
	self.activeWorldId = worldId
	self.layouts[ZONES.Race] = world.layout
	self.raceRoot = world.root
	self.killY[ZONES.Race] = world.killY
	self.startGate = world.startGate
	for _, other in pairs(self.worlds) do
		if other ~= world and other.startGate then
			other.startGate.CanCollide = true
			other.startGate.CanQuery = true
			other.startGate.Transparency = 0.35
		end
	end
	workspace:SetAttribute(Protocol.WorkspaceAttributes.ActiveWorld, worldId)
	self.WorldChanged:Fire(worldId, world.layout)
	return true
end

function TrainingTrackService:GetActiveWorldId()
	return self.activeWorldId
end

function TrainingTrackService:GetWorldIds()
	local ids = {}
	for i, id in ipairs(self.worldOrder) do
		ids[i] = id
	end
	return ids
end

-- prompt 02: hubs by id. Unknown / failed ids resolve to the default hub (Orbital Garage).
function TrainingTrackService:GetHub(hubId)
	return self.hubs[hubId or ""] or self.hubs[MapRegistry.DefaultHubId]
end

function TrainingTrackService:GetHubIds()
	local ids = {}
	for i, id in ipairs(self.hubOrder) do
		ids[i] = id
	end
	return ids
end

function TrainingTrackService:HasHub(hubId)
	return self.hubs[hubId or ""] ~= nil
end

function TrainingTrackService:GetLayout(zone, hubId)
	if zone == ZONES.Hub then
		local hub = self:GetHub(hubId)
		return hub and hub.layout or self.layouts[ZONES.Hub]
	end
	-- challenges brief: a race-zone marble tagged with a challenge id rides that challenge course
	local challenge = hubId and self.challenges and self.challenges[hubId]
	if challenge and (zone or ZONES.Race) == ZONES.Race then
		return challenge.layout
	end
	return self.layouts[zone or ZONES.Race]
end

function TrainingTrackService:GetKillY(zone, hubId)
	if zone == ZONES.Hub then
		local hub = self:GetHub(hubId)
		return hub and hub.killY or self.killY[ZONES.Hub]
	end
	local challenge = hubId and self.challenges and self.challenges[hubId]
	if challenge then
		return challenge.killY
	end
	return self.killY[zone or ZONES.Race]
end

-- challenges brief: the authored challenge courses (built once, like the maps)
function TrainingTrackService:GetChallenge(id)
	return self.challenges and self.challenges[id]
end

function TrainingTrackService:_buildChallenges(courseFolder, radius)
	self.challenges = {}
	local ok, ChallengeConfig = pcall(function()
		return require(Shared:WaitForChild("ChallengeConfig"))
	end)
	if not ok then
		return
	end
	for _, c in ipairs(ChallengeConfig.Challenges) do
		local def = TrackDefinitions[c.Course]
		if def and c.Status == "Live" then
			local built, err = pcall(function()
				local layout = TrackDefinitions.Generate(def, radius)
				local errors = TrackDefinitions.Validate(def, layout)
				if #errors > 0 then
					error(table.concat(errors, "; "))
				end
				local root = Builder.Build(layout, courseFolder, "Challenge_" .. c.Id)
				local gate = root:FindFirstChild("Gates") and root.Gates:FindFirstChild("StartGate")
				self.challenges[c.Id] = { config = c, def = def, layout = layout, root = root, killY = layout.MinY - PhysicsConfig.Server.KillDepthBelowCourse, startGate = gate }
				print(string.format("[Track] challenge %s built (%.0f studs, %d gates)", c.Id, layout.FinishLineS - (layout.StartLineS or 0), #layout.Checkpoints))
			end)
			if not built then
				note(self, c.Id, "challenge course failed: " .. tostring(err))
			end
		end
	end
end

-- open / close one challenge start gate (each attempt opens it at GO, closes it on reset)
function TrainingTrackService:SetChallengeGateOpen(id, open)
	local c = self.challenges and self.challenges[id]
	local gate = c and c.startGate
	if gate then
		gate.CanCollide = not open
		gate.CanQuery = not open
		gate.Transparency = open and 1 or 0.35
	end
end

function TrainingTrackService:GetRaceRoot()
	return self.raceRoot
end

local function frameToCFrame(frame, lateral)
	local radius = PhysicsConfig.Ball.Radius
	local position = frame.Position + frame.Right * (lateral or 0) + frame.Up * (radius + GameConfig.Spawn.SpawnLift)
	return CFrame.fromMatrix(position, frame.Right, frame.Up)
end

-- Hub spawns rotate through the ring so simultaneous arrivals do not stack.
function TrainingTrackService:NextHubSpawnCFrame(hubId)
	local hub = self:GetHub(hubId)
	hub.cursor = hub.cursor % #hub.spawns + 1
	return hub.spawns[hub.cursor]
end

-- prompt 03: Practice from Map Selection starts on the hub's practice lane (its Spawn point)
function TrainingTrackService:GetPracticeStartCFrame(hubId)
	local hub = self:GetHub(hubId)
	return frameToCFrame(hub.layout.SpawnFrame, 0)
end

function TrainingTrackService:GetGridSlotCount()
	return #self.layouts[ZONES.Race].GridSlots
end

function TrainingTrackService:GetGridCFrame(slotIndex)
	local slots = self.layouts[ZONES.Race].GridSlots
	local slot = slots[((slotIndex - 1) % #slots) + 1]
	return frameToCFrame(slot.Frame, slot.Offset)
end

function TrainingTrackService:GetCheckpointRespawnCFrame(index)
	local cp = self.layouts[ZONES.Race].Checkpoints[index]
	return cp and frameToCFrame(cp.RespawnFrame, 0)
end

function TrainingTrackService:GetFinishRespawnCFrame()
	local layout = self.layouts[ZONES.Race]
	if layout.FinisherDeck then
		-- circuits: the finisher deck beside the line (finished marbles leave the road)
		local deck = layout.FinisherDeck
		return CFrame.lookAt(deck.Position + deck.Up * (PhysicsConfig.Ball.Radius + GameConfig.Spawn.SpawnLift), deck.Position + deck.Up * (PhysicsConfig.Ball.Radius + GameConfig.Spawn.SpawnLift) + deck.Forward)
	end
	local frame = TrackDefinitions.SampleAtH(layout, layout.FinishLineFrame.H + 10)
	return frameToCFrame(frame, 0)
end

-- A layout frame -> a spawn CFrame (respawn at a confirmed lap target)
function TrainingTrackService:FrameCFrame(frame, lateral)
	return frameToCFrame(frame, lateral or 0)
end

-- B1 Time Trial: a solo start just past the start gate (the gate stays closed between races)
function TrainingTrackService:GetTimeTrialStart()
	local layout = self.layouts[ZONES.Race]
	local frame = TrackDefinitions.SampleAtH(layout, layout.StartLineFrame.H + 6)
	return frameToCFrame(frame, 0), frame.S
end

function TrainingTrackService:SetStartGateClosed(closed)
	local gate = self.startGate
	if not gate then
		return
	end
	gate.CanCollide = closed
	gate.CanQuery = closed
	gate.Transparency = closed and 0.35 or 1
end

function TrainingTrackService:GetValidationErrors()
	return self.validationErrors
end

return TrainingTrackService
