--[[
	MapRegistry (promo pack prompt 02) — the one list of race maps and hubs.

	Each entry has two parts:
	  Meta  : client-visible card data (display name, difficulty, one-line description, skill,
	          preview, palette). Safe to show anywhere.
	  refs  : ids of the geometry and builders that own the real data. Track = a
	          TrackDefinitions.Worlds id; Hub = a hub id here; Builder / HubBuilder = names the
	          SERVER resolves to builder modules (clients never build).
	Server-owned state (active map, votes, who is in which hub) lives in the services, not here.

	Ids are stable: best times, ghosts and leaderboards are keyed by map ids, so the three race
	ids stay exactly the B1 ids. Status "Live" = in rotation and on the map cards; "Gated" = only
	when the named feature gate is on (Studio / development builds); anything else = off.
	Pure module: no services, so the offline harness runs it.
]]

local TrackDefinitions = require(script.Parent:WaitForChild("TrackDefinitions"))

local MapRegistry = {}

MapRegistry.Version = 1
MapRegistry.DefaultMapId = "NeonFoundry_A4" -- the known-safe playable map
MapRegistry.DefaultHubId = "OrbitalGarage" -- the spawn hub, always available

-- Builder names the server knows how to run (TrainingTrackService resolves them).
MapRegistry.TrackBuilders = { SplineCourse = true }
MapRegistry.HubBuilders = { RingDeck = true, ThemedDeck = true }

-- Development feature gates. Off on live servers unless listed in GameConfig; on in Studio.
MapRegistry.Gates = { NewHubs = "NewHubs" }

MapRegistry.Maps = {
	{
		Id = "NeonFoundry_A4",
		Track = "NeonFoundry_A4",
		Hub = "OrbitalGarage",
		Builder = "SplineCourse",
		Profile = "NeonFoundry",
		Status = "Live",
		Meta = {
			DisplayName = "Neon Foundry",
			Difficulty = "Medium",
			Skill = "Banking and sweeper timing",
			Blurb = "Banked drops, sweeper arms and a split lane through a night factory.",
			Preview = nil, -- a verified Roblox image id once a real capture exists (prompt 24)
			Swatch = { 0x10172D, 0x27D7F5, 0xA078FF, 0xFFD45A },
		},
	},
	{
		Id = "SkyCarnival_B1",
		Track = "SkyCarnival_B1",
		Hub = "BalloonTerminal", -- gated (04/07): players without the gate use Orbital Garage
		Builder = "SplineCourse",
		Profile = "SkyCarnival",
		Status = "Live",
		Meta = {
			DisplayName = "Sky Carnival",
			Difficulty = "Easy",
			Skill = "Bounce control and landing",
			Blurb = "Balloon bumpers, a bouncy drum and gusty wind lanes above the clouds.",
			Preview = nil,
			Swatch = { 0x28468D, 0xFFF2CB, 0xA0E9CE, 0xF08BAE },
		},
	},
	{
		Id = "VolcanoVault_B1",
		Track = "VolcanoVault_B1",
		Hub = "BasaltDeck", -- gated (04/09)
		Builder = "SplineCourse",
		Profile = "VolcanoVault",
		Status = "Live",
		Meta = {
			DisplayName = "Volcano Vault",
			Difficulty = "Hard",
			Skill = "Burst timing and braking",
			Blurb = "Pistons, geyser vents and falling rocks over lava. Brake before the drop.",
			Preview = nil,
			Swatch = { 0x292329, 0xFF7047, 0xFFBD5D, 0xDDE8F1 },
		},
	},
}

MapRegistry.Hubs = {
	{
		Id = "OrbitalGarage",
		ModelName = "OrbitalGarage", -- = Protocol.HubModelName (clients look it up by this name)
		Builder = "RingDeck",
		Map = "NeonFoundry_A4",
		Profile = "OrbitalGarage",
		Status = "Live",
		Geometry = TrackDefinitions.Hub,
		Chute = TrackDefinitions.PracticeChute,
		Meta = {
			DisplayName = "Orbital Garage",
			Blurb = "The spawn hub above the Neon Foundry.",
			BoardTitle = "ORBITAL GARAGE",
			PracticeObjective = "Steer through the bends and brake into the basin.",
		},
	},
	{
		Id = "BalloonTerminal",
		ModelName = "BalloonTerminal",
		Builder = "ThemedDeck",
		Map = "SkyCarnival_B1",
		Profile = "BalloonTerminal",
		Status = "Gated",
		Gate = "NewHubs",
		Geometry = TrackDefinitions.BalloonTerminal,
		Chute = TrackDefinitions.BalloonPractice,
		Meta = {
			DisplayName = "Balloon Terminal",
			Blurb = "A canvas boarding deck in the clouds below the Sky Carnival.",
			BoardTitle = "BALLOON TERMINAL",
			PracticeObjective = "Bounce on the drum and land on the target rings.",
		},
	},
	{
		Id = "BasaltDeck",
		ModelName = "BasaltInspectionDeck",
		Builder = "ThemedDeck",
		Map = "VolcanoVault_B1",
		Profile = "BasaltDeck",
		Status = "Gated",
		Gate = "NewHubs",
		Geometry = TrackDefinitions.BasaltDeck,
		Chute = TrackDefinitions.BasaltPractice,
		Meta = {
			DisplayName = "Basalt Inspection Deck",
			Blurb = "A furnace-lit inspection deck above the Volcano Vault.",
			BoardTitle = "BASALT INSPECTION DECK",
			PracticeObjective = "Time the slow piston, then brake before the drop.",
		},
	},
}

local mapsById, hubsById = {}, {}
local function index()
	mapsById, hubsById = {}, {}
	for i, map in ipairs(MapRegistry.Maps) do
		map.Order = i
		if mapsById[map.Id] == nil then
			mapsById[map.Id] = map
		end
	end
	for _, hub in ipairs(MapRegistry.Hubs) do
		if hubsById[hub.Id] == nil then
			hubsById[hub.Id] = hub
		end
	end
end
index()
MapRegistry.Reindex = index -- specs and later prompts append entries, then reindex

-- Is this entry usable on this server? features = { [gateName] = true }
function MapRegistry.IsEnabled(entry, features)
	if not entry then
		return false
	end
	if entry.Status == "Live" then
		return true
	end
	if entry.Status == "Gated" then
		return entry.Gate ~= nil and type(features) == "table" and features[entry.Gate] == true
	end
	return false
end

-- Map entry by id; unknown or disabled ids fall back to the default map. Returns entry, fellBack.
function MapRegistry.Map(id, features)
	local map = mapsById[id]
	if map and MapRegistry.IsEnabled(map, features) then
		return map, false
	end
	return mapsById[MapRegistry.DefaultMapId], true
end

function MapRegistry.Hub(id, features)
	local hub = hubsById[id]
	if hub and MapRegistry.IsEnabled(hub, features) then
		return hub, false
	end
	return hubsById[MapRegistry.DefaultHubId], true
end

function MapRegistry.RawMap(id)
	return mapsById[id]
end

function MapRegistry.RawHub(id)
	return hubsById[id]
end

-- The hub a map belongs to (its own when enabled, otherwise the default hub).
function MapRegistry.HubForMap(mapId, features)
	local map = mapsById[mapId]
	return MapRegistry.Hub(map and map.Hub, features)
end

-- Enabled maps / hubs in registry order.
function MapRegistry.EnabledMaps(features)
	local out = {}
	for _, map in ipairs(MapRegistry.Maps) do
		if MapRegistry.IsEnabled(map, features) and mapsById[map.Id] == map then
			out[#out + 1] = map
		end
	end
	return out
end

function MapRegistry.EnabledHubs(features)
	local out = {}
	for _, hub in ipairs(MapRegistry.Hubs) do
		if MapRegistry.IsEnabled(hub, features) and hubsById[hub.Id] == hub then
			out[#out + 1] = hub
		end
	end
	return out
end

-- Client card data only (never builder names or geometry).
function MapRegistry.Card(map)
	if not map then
		return nil
	end
	local meta = map.Meta or {}
	return {
		id = map.Id,
		name = meta.DisplayName or map.Id,
		difficulty = meta.Difficulty or "?",
		skill = meta.Skill or "",
		blurb = meta.Blurb or "",
		preview = meta.Preview,
		swatch = meta.Swatch,
		hubId = map.Hub,
	}
end

local function finiteVector(v)
	return v ~= nil and type(v.X) == "number" and v.X == v.X and v.Y == v.Y and v.Z == v.Z
		and math.abs(v.X) < 1e6 and math.abs(v.Y) < 1e6 and math.abs(v.Z) < 1e6
end
MapRegistry.FiniteVector = finiteVector

-- Static checks on the data (no geometry generation): duplicate ids, missing references and
-- builders, a usable default. Returns a list of error strings (empty = valid).
function MapRegistry.ValidateStatic(trackDefs)
	trackDefs = trackDefs or TrackDefinitions
	local errors = {}
	local function err(fmt, ...)
		errors[#errors + 1] = string.format(fmt, ...)
	end
	local seen = {}
	for _, map in ipairs(MapRegistry.Maps) do
		if type(map.Id) ~= "string" or map.Id == "" then
			err("a map has no id")
		elseif seen[map.Id] then
			err("duplicate map id %s", map.Id)
		end
		seen[map.Id or ""] = true
		if not (trackDefs.WorldsById and trackDefs.WorldsById[map.Track]) then
			err("%s: track %s is not a TrackDefinitions world", tostring(map.Id), tostring(map.Track))
		end
		if not MapRegistry.TrackBuilders[map.Builder or ""] then
			err("%s: missing builder %s", tostring(map.Id), tostring(map.Builder))
		end
		if not hubsById[map.Hub or ""] then
			err("%s: hub %s is not registered", tostring(map.Id), tostring(map.Hub))
		end
		if not (map.Meta and type(map.Meta.DisplayName) == "string" and map.Meta.DisplayName ~= "") then
			err("%s: no display name", tostring(map.Id))
		end
		if map.Status == "Gated" and not MapRegistry.Gates[map.Gate or ""] then
			err("%s: gated without a known gate", tostring(map.Id))
		end
	end
	local seenHub = {}
	for _, hub in ipairs(MapRegistry.Hubs) do
		if type(hub.Id) ~= "string" or hub.Id == "" then
			err("a hub has no id")
		elseif seenHub[hub.Id] then
			err("duplicate hub id %s", hub.Id)
		end
		seenHub[hub.Id or ""] = true
		if not MapRegistry.HubBuilders[hub.Builder or ""] then
			err("%s: missing hub builder %s", tostring(hub.Id), tostring(hub.Builder))
		end
		local g = hub.Geometry
		if not (g and finiteVector(g.Center) and type(g.Radius) == "number" and g.Radius > 10 and (g.SpawnSlots or 0) >= 1) then
			err("%s: invalid hub geometry", tostring(hub.Id))
		end
		if not (hub.Chute and hub.Chute.Pieces and hub.Chute.Spawn and hub.Chute.FinishLine) then
			err("%s: no practice chute (entry / return points)", tostring(hub.Id))
		end
		if not mapsById[hub.Map or ""] then
			err("%s: map %s is not registered", tostring(hub.Id), tostring(hub.Map))
		end
		if hub.Status == "Gated" and not MapRegistry.Gates[hub.Gate or ""] then
			err("%s: gated without a known gate", tostring(hub.Id))
		end
	end
	local default = mapsById[MapRegistry.DefaultMapId]
	if not (default and default.Status == "Live") then
		err("default map %s must exist and be Live", MapRegistry.DefaultMapId)
	end
	local defaultHub = hubsById[MapRegistry.DefaultHubId]
	if not (defaultHub and defaultHub.Status == "Live") then
		err("default hub %s must exist and be Live", MapRegistry.DefaultHubId)
	end
	return errors
end

return MapRegistry
