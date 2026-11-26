--[[
	MapRegistry.spec — promo pack prompt 02: map + hub registry, load validation and fallback,
	visual profiles, feature gates. Pure modules only.
]]

local Spec = {}

function Spec.run(m)
	local results = { passed = 0, failed = 0, lines = {}, info = {} }
	local function check(name, ok, detail)
		if ok then
			results.passed = results.passed + 1
			table.insert(results.lines, "PASS  " .. name)
		else
			results.failed = results.failed + 1
			table.insert(results.lines, "FAIL  " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
		end
	end
	local R, TD, L = m.MapRegistry, m.TrackDefinitions, m.MapLoader
	if not (R and TD and L) then
		check("registry modules load", false, "MapRegistry / TrackDefinitions / MapLoader missing")
		return results
	end

	------------------------------------------------------------------ registry data
	local errors = R.ValidateStatic(TD)
	check("registry validates clean (ids, builders, hubs, default)", #errors == 0, table.concat(errors, "; "))
	local ids = {}
	for i, map in ipairs(R.Maps) do
		ids[i] = map.Id
	end
	check("map ids are the B1 ids, in the B1 rotation order (records stay compatible)", table.concat(ids, ",") == "NeonFoundry_A4,SkyCarnival_B1,VolcanoVault_B1", table.concat(ids, ","))
	local sameAsWorlds = #R.Maps == #TD.Worlds
	for i, def in ipairs(TD.Worlds) do
		sameAsWorlds = sameAsWorlds and R.Maps[i] and R.Maps[i].Track == def.Id
	end
	check("registry order = TrackDefinitions.Worlds order (map rotation unchanged)", sameAsWorlds)
	check("default map is Neon Foundry, default hub is Orbital Garage", R.DefaultMapId == "NeonFoundry_A4" and R.DefaultHubId == "OrbitalGarage")
	local garage = R.RawHub("OrbitalGarage")
	check("Orbital Garage keeps the A2 geometry and practice chute (same tables)", garage and garage.Geometry == TD.Hub and garage.Chute == TD.PracticeChute and garage.ModelName == m.Protocol.HubModelName)
	local metaOk, cardClean = true, true
	for _, map in ipairs(R.Maps) do
		local card = R.Card(map)
		metaOk = metaOk and card.name ~= "" and card.difficulty ~= "?" and card.blurb ~= "" and card.skill ~= ""
		cardClean = cardClean and card.Builder == nil and card.Track == nil and card.track == nil and card.builder == nil
		local def = TD.WorldsById[map.Track]
		metaOk = metaOk and def and def.DisplayName == map.Meta.DisplayName
	end
	check("every map has name / difficulty / skill / one-line blurb (matches the track name)", metaOk)
	check("client cards carry no builder names or geometry", cardClean)

	------------------------------------------------------------------ fallback lookups
	local map, fell = R.Map("NoSuchMap_X")
	check("unknown map id -> Neon Foundry (fellBack)", map and map.Id == "NeonFoundry_A4" and fell == true)
	local hub, hubFell = R.Hub(nil)
	check("missing hub id -> Orbital Garage (fellBack)", hub and hub.Id == "OrbitalGarage" and hubFell == true)
	local sky = R.Map("SkyCarnival_B1")
	check("a live map resolves to itself", sky and sky.Id == "SkyCarnival_B1")

	------------------------------------------------------------------ static validation catches mistakes
	local dup = { Id = "SkyCarnival_B1", Track = "SkyCarnival_B1", Hub = "OrbitalGarage", Builder = "SplineCourse", Status = "Off", Meta = { DisplayName = "x" } }
	table.insert(R.Maps, dup)
	local e1 = R.ValidateStatic(TD)
	table.remove(R.Maps)
	local bad = { Id = "Broken_X", Track = "Nope", Hub = "NoHub", Builder = "Missing", Status = "Gated", Gate = "Nope", Meta = {} }
	table.insert(R.Maps, bad)
	R.Reindex()
	local e2 = R.ValidateStatic(TD)
	local gatedOff = R.Map("Broken_X")
	local gatedOn = R.Map("Broken_X", { Nope = true })
	table.remove(R.Maps)
	R.Reindex()
	local joined2 = table.concat(e2, "; ")
	check("duplicate map id is reported", table.concat(e1, "; "):find("duplicate map id SkyCarnival_B1") ~= nil, table.concat(e1, "; "))
	check("unknown track, missing builder, unknown hub, no name, unknown gate are all reported",
		joined2:find("not a TrackDefinitions world") and joined2:find("missing builder") and joined2:find("hub NoHub") and joined2:find("no display name") and joined2:find("unknown gate") == nil and joined2:find("gated without a known gate") ~= nil, joined2)
	check("a gated map is unavailable without its gate (falls back) and available with it", gatedOff.Id == "NeonFoundry_A4" and gatedOn.Id == "Broken_X")
	check("registry restored after the negative cases", #R.ValidateStatic(TD) == 0 and R.RawMap("Broken_X") == nil)

	------------------------------------------------------------------ load validation (geometry)
	local radius = m.PhysicsConfig.Ball.Radius
	local depth = m.PhysicsConfig.Server.KillDepthBelowCourse
	local allClean = true
	for _, def in ipairs(TD.Worlds) do
		local layout = TD.Generate(def, radius)
		local errs = L.ValidateCourse(layout, layout.MinY - depth)
		if #errs > 0 then
			allClean = false
			results.info[#results.info + 1] = def.Id .. ": " .. table.concat(errs, "; ")
		end
	end
	check("every map loads clean: checkpoints reachable in order, finite spawn / grid / respawns", allClean)
	local foundry = TD.Generate(TD.NeonFoundry, radius)
	local saved = foundry.Checkpoints[3].S
	foundry.Checkpoints[3].S = foundry.Checkpoints[1].S - 1
	local e3 = L.ValidateCourse(foundry, foundry.MinY - depth)
	foundry.Checkpoints[3].S = saved
	check("an out-of-order checkpoint is reported as unreachable", #e3 > 0 and table.concat(e3, " "):find("checkpoint 3 unreachable") ~= nil, table.concat(e3, "; "))
	local nan = 0 / 0
	local savedFrame = foundry.SpawnFrame
	foundry.SpawnFrame = { Position = Vector3.new(nan, 0, 0) }
	local e4 = L.ValidateCourse(foundry, foundry.MinY - depth)
	foundry.SpawnFrame = savedFrame
	check("a NaN spawn transform is reported", table.concat(e4, " "):find("invalid spawn transform") ~= nil)
	local cp1 = foundry.Checkpoints[1].RespawnFrame
	foundry.Checkpoints[1].RespawnFrame = { Position = Vector3.new(0, foundry.MinY - depth - 5, 0) }
	local e5 = L.ValidateCourse(foundry, foundry.MinY - depth)
	foundry.Checkpoints[1].RespawnFrame = cp1
	check("a respawn below the kill height is reported", table.concat(e5, " "):find("below the kill height") ~= nil)

	local HB = m.HubBuilder
	if HB then
		local chute = TD.Generate(garage.Chute, radius)
		local spawns = HB.SpawnCFrames(garage.Geometry, radius, m.GameConfig.Spawn.SpawnLift)
		local killY = math.min(garage.Geometry.Center.Y, chute.MinY) - depth
		local e6 = L.ValidateHub(garage.Geometry, chute, spawns, killY)
		check("Orbital Garage loads clean: 16 spawns on the deck, practice entry and return", #e6 == 0 and #spawns == 16, table.concat(e6, "; "))
		local far = { CFrame.new(garage.Geometry.Center + Vector3.new(garage.Geometry.Radius + 5, 3, 0)) }
		check("a spawn off the deck is reported", #L.ValidateHub(garage.Geometry, chute, far, killY) > 0)
		check("a hub without a practice chute is reported", table.concat(L.ValidateHub(garage.Geometry, nil, spawns, killY), " "):find("no practice entry") ~= nil)
	end

	------------------------------------------------------------------ fallback decision
	local en, dropped, fatal = L.Decide({ { id = "A", ok = true, errors = {} }, { id = "B", ok = false, errors = { "boom" } }, { id = "C", ok = true, errors = { "bad cp" } } }, "A")
	check("failing non-default maps are dropped, the rest keep running", table.concat(en, ",") == "A" and dropped.B == "boom" and dropped.C == "bad cp" and fatal == nil)
	local en2, _, fatal2 = L.Decide({ { id = "A", ok = true, errors = { "note" } }, { id = "B", ok = true, errors = {} } }, "A")
	check("the default map stays even with validation notes", table.concat(en2, ",") == "A,B" and fatal2 == nil)
	local _, _, fatal3 = L.Decide({ { id = "A", ok = false, errors = { "throw" } } }, "A")
	check("the default map failing to build is fatal (nothing safer to fall back to)", fatal3 ~= nil and fatal3:find("throw") ~= nil)

	------------------------------------------------------------------ visual profiles
	local VP = m.VisualProfiles
	if VP then
		local function sameColor(a, b)
			return a and b and math.abs(a.R - b.R) < 1e-6 and math.abs(a.G - b.G) < 1e-6 and math.abs(a.B - b.B) < 1e-6
		end
		local p = VP.Get("ClassicNight")
		local same = p.ClockTime == 0 and p.Brightness == 2 and sameColor(p.Ambient, Color3.fromRGB(46, 56, 96)) and sameColor(p.OutdoorAmbient, Color3.fromRGB(70, 82, 130))
			and sameColor(p.FogColor, m.GameConfig.Palette.Navy) and p.FogStart == 300 and p.FogEnd == 1600 and p.EnvironmentDiffuseScale == 0.4 and p.EnvironmentSpecularScale == 1
			and p.Bloom.Intensity == 0.7 and p.Bloom.Size == 24 and p.Bloom.Threshold == 1.4 and p.Grade.Contrast == 0.08 and p.Grade.Saturation == 0.12
		check("ClassicNight (server start-up) = the exact pre-registry environment", same)
		local complete = true
		for _, profile in pairs(VP.Profiles) do
			for _, field in ipairs(VP.Fields) do
				if profile[field] == nil then
					complete = false
				end
			end
			complete = complete and profile.Bloom and profile.Grade and profile.Grade.TintColor ~= nil and profile.Grade.Brightness ~= nil and profile.Atmosphere ~= nil
		end
		check("every profile sets every field it owns (switching leaves nothing behind)", complete)
		local fakeLighting, bloom, grade, atmosphere = {}, {}, {}, {}
		local written = VP.Apply(fakeLighting, VP.Get("SkyCarnival"), { bloom = bloom, grade = grade, atmosphere = atmosphere })
		check("Apply writes all lighting fields + bloom + grade + atmosphere", #written == #VP.Fields + 3 and fakeLighting.ClockTime == 16.2 and bloom.Intensity == 0.3 and grade.TintColor ~= nil and atmosphere.Density == 0.26)
		local night = {}
		VP.Apply({}, VP.Get("ClassicNight"), { atmosphere = night })
		check("leaving a map profile for the night profile clears the atmosphere (density 0)", night.Density == 0 and night.Haze == 0)
		local unknown, fellBack = VP.Get("Nope")
		check("unknown profile -> ClassicNight", unknown == p and fellBack)
		local named = true
		for _, entry in ipairs(R.Maps) do
			named = named and VP.Profiles[entry.Profile] ~= nil
		end
		for _, entry in ipairs(R.Hubs) do
			named = named and VP.Profiles[entry.Profile] ~= nil
		end
		check("every registry map and hub names an existing profile", named)
	end

	------------------------------------------------------------------ feature gates
	local FG = m.FeatureGates
	if FG then
		local cfg = { OwnerSeesGated = true, GatedUserIds = { 77 } }
		check("Studio: every gate on", FG.Resolve(true, 1, 2, true, cfg).NewHubs == true)
		check("live: a stranger gets no gates", next(FG.Resolve(false, 5, 2, true, cfg)) == nil)
		check("live: the creator account (user-owned) gets the gates", FG.Resolve(false, 2, 2, true, cfg).NewHubs == true)
		check("live: group-owned experience -> creator id is a group, never a user match", next(FG.Resolve(false, 2, 2, false, cfg)) == nil)
		check("live: listed test accounts get the gates", FG.Resolve(false, 77, 2, false, cfg).NewHubs == true)
		check("live: OwnerSeesGated off -> creator gets none", next(FG.Resolve(false, 2, 2, true, { OwnerSeesGated = false })) == nil)
		check("gates encode for the client attribute", FG.Encode({ NewHubs = true }) == "NewHubs" and FG.Encode({}) == "")
	end
	return results
end

return Spec
