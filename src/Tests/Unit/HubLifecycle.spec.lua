--[[
	HubLifecycle.spec — promo pack prompts 04 / 07: distinct hubs per map (Balloon Terminal,
	Basalt Inspection Deck) behind the NewHubs gate, their practice lanes, placement, and the
	two-player lifecycle (different hubs, one race, each back to their own hub). Pure modules.
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
	local R, TD, L, HB, TH = m.MapRegistry, m.TrackDefinitions, m.MapLoader, m.HubBuilder, m.ThemedHubBuilder
	if not (R and TD and L and HB and TH) then
		check("hub modules load", false)
		return results
	end
	local radius = m.PhysicsConfig.Ball.Radius
	local depth = m.PhysicsConfig.Server.KillDepthBelowCourse

	------------------------------------------------------------------ every hub loads
	local hubLayouts = {}
	for _, entry in ipairs(R.Hubs) do
		local chute = TD.Generate(entry.Chute, radius)
		hubLayouts[entry.Id] = chute
		local errs = TD.Validate(entry.Chute, chute)
		local spawns = HB.SpawnCFrames(entry.Geometry, radius, m.GameConfig.Spawn.SpawnLift)
		local killY = math.min(entry.Geometry.Center.Y, chute.MinY) - depth
		for _, e in ipairs(L.ValidateHub(entry.Geometry, chute, spawns, killY)) do
			errs[#errs + 1] = e
		end
		check(entry.Id .. ": practice lane + deck validate (spawns, entry, return)", #errs == 0, table.concat(errs, "; "))
		local len = chute.Route.total
		check(entry.Id .. ": short practice lane (100-400 studs)", len >= 100 and len <= 400, string.format("%.0f", len))
	end

	------------------------------------------------------------------ placement
	local worlds = {}
	for i, def in ipairs(TD.Worlds) do
		worlds[i] = TD.Generate(def, radius)
	end
	local minWorld, minHub = math.huge, math.huge
	for i, a in ipairs(R.Hubs) do
		local pts = { a.Geometry.Center }
		for _, sec in ipairs(hubLayouts[a.Id].Sections) do
			pts[#pts + 1] = sec.Position
		end
		for _, w in ipairs(worlds) do
			for _, sec in ipairs(w.Sections) do
				for _, p in ipairs(pts) do
					minWorld = math.min(minWorld, (sec.Position - p).Magnitude)
				end
			end
		end
		for j = i + 1, #R.Hubs do
			minHub = math.min(minHub, (a.Geometry.Center - R.Hubs[j].Geometry.Center).Magnitude)
		end
	end
	check("no hub or practice lane comes within 150 studs of any race course", minWorld >= 150, string.format("%.0f", minWorld))
	check("hubs are far apart (one hub's look never reaches another's)", minHub >= 1000, string.format("%.0f", minHub))
	local sky = TD.SkyCarnival.Origin
	local bt = TD.BalloonTerminal.Center
	check("Balloon Terminal sits below and behind the Sky Carnival start (view toward its map)", bt.Y < sky.Y and math.abs(bt.X - sky.X) < 1 and bt.Z > sky.Z)

	------------------------------------------------------------------ distinct builds
	local function specsFor(entry)
		if entry.Builder == "ThemedDeck" then
			return TH.ComputeSpecs(entry.Geometry, entry.Chute.Pieces[1].Width[1], hubLayouts[entry.Id])
		end
		return HB.ComputeSpecs(entry.Geometry, entry.Chute.Pieces[1].Width[1])
	end
	local names = {}
	for _, entry in ipairs(R.Hubs) do
		local specs = specsFor(entry)
		local sane, board, pad, set = true, false, false, {}
		for _, spec in ipairs(specs) do
			local sz = spec.Size
			if not (sz and sz.X > 0 and sz.Y > 0 and sz.Z > 0 and sz.X <= 2048 and sz.Y <= 2048 and sz.Z <= 2048) then
				sane = false
			end
			board = board or (spec.Name == "NextRaceBoard" and spec.Gui and spec.Gui.Kind == "Board")
			pad = pad or (spec.Attributes and spec.Attributes.TC_Selector == true)
			set[spec.Name] = true
		end
		names[entry.Id] = set
		check(entry.Id .. ": builds (all part sizes valid), " .. #specs .. " parts", sane and #specs < 400)
		check(entry.Id .. ": has the shared next-race board", board)
		if entry.Builder == "ThemedDeck" then
			check(entry.Id .. ": MAPS kiosk with a selector pad near spawn", pad and set.KioskSign and set.DeparturesSign and set.PracticeArch)
			local look = HB.HeadingVectors(entry.Geometry.ChuteHeadingDeg)
			local sides = TH.Styles[entry.Geometry.Style].Sides
			local open = true
			for _, spec in ipairs(specs) do
				if spec.Name == "Rim" then
					local d = spec.CFrame.Position - entry.Geometry.Center
					local flat = Vector3.new(d.X, 0, d.Z).Unit
					if flat:Dot(look) > math.cos(math.pi / sides) then
						open = false
					end
				end
			end
			check(entry.Id .. ": rim is open toward the practice lane", open)
			local kiosk, padPos = TH.KioskPosition(entry.Geometry)
			local padDist = Vector3.new(padPos.X - entry.Geometry.Center.X, 0, padPos.Z - entry.Geometry.Center.Z).Magnitude
			check(entry.Id .. ": selector pad is a short roll from the spawn ring, on the deck", padDist > entry.Geometry.SpawnRingRadius + 3 and padDist < entry.Geometry.Radius - 4 and kiosk ~= nil)
		end
	end
	check("three silhouettes: round Garage, octagon Terminal, hexagon Basalt", TH.Styles.Terminal.Sides == 8 and TH.Styles.Basalt.Sides == 6 and R.RawHub("OrbitalGarage").Builder == "RingDeck")
	check("each map hub has its own landmark", names.BalloonTerminal.TetheredBalloon and names.BalloonTerminal.Awning and names.BasaltDeck.FurnaceWindow and not names.BasaltDeck.TetheredBalloon and not names.OrbitalGarage.TetheredBalloon)
	check("Balloon Terminal paints a landing target on its practice lane", names.BalloonTerminal.LandingTarget == true)

	------------------------------------------------------------------ practice obstacles teach the map's skill
	local function hazardsOf(id)
		local kinds = {}
		for _, hz in ipairs(hubLayouts[id].Hazards or {}) do
			kinds[#kinds + 1] = hz
		end
		return kinds
	end
	local bh = hazardsOf("BalloonTerminal")
	check("Balloon Terminal lane: one wide drum (bounce control and landing)", #bh == 1 and bh[1].Kind == "Trampoline" and bh[1].Definition.Width >= 12)
	local vh = hazardsOf("BasaltDeck")
	check("Basalt lane: one slow demonstration piston (burst timing), slower than the course's", #vh == 1 and vh[1].Kind == "Hammer" and vh[1].Definition.Period > 3.2)
	check("Orbital Garage lane unchanged (no hazards)", #hazardsOf("OrbitalGarage") == 0)
	local brake = false
	for _, sign in ipairs(TD.BasaltPractice.Signs) do
		brake = brake or sign.Text:find("BRAKE") ~= nil
	end
	check("Basalt lane teaches braking before its drop", brake)

	------------------------------------------------------------------ gate
	check("new hubs are gated behind NewHubs", R.RawHub("BalloonTerminal").Status == "Gated" and R.RawHub("BalloonTerminal").Gate == "NewHubs" and R.RawHub("BasaltDeck").Gate == "NewHubs")
	check("without the gate: Sky Carnival's hub resolves to Orbital Garage", R.HubForMap("SkyCarnival_B1", {}).Id == "OrbitalGarage")
	check("with the gate: Sky Carnival -> Balloon Terminal, Volcano -> Basalt Deck", R.HubForMap("SkyCarnival_B1", { NewHubs = true }).Id == "BalloonTerminal" and R.HubForMap("VolcanoVault_B1", { NewHubs = true }).Id == "BasaltDeck")
	check("the race maps stay Live (gating a hub never removes a race)", R.RawMap("SkyCarnival_B1").Status == "Live")
	local MS = m.MapSelectPure
	if MS then
		local card = MS.CardState(R.RawMap("SkyCarnival_B1"), { snap = { ballot = { epoch = 1, maps = { "NeonFoundry_A4", "SkyCarnival_B1" }, counts = { 0, 0 }, choices = {} } }, myUserId = 1, myHub = "OrbitalGarage", features = {}, racing = false })
		check("card without the gate explains the hub is in testing", card.note and card.note:find("still in testing") ~= nil and card.hubId == "OrbitalGarage")
		local gated = MS.CardState(R.RawMap("SkyCarnival_B1"), { snap = { ballot = { epoch = 1, maps = { "SkyCarnival_B1" }, counts = { 0 }, choices = {} } }, myUserId = 1, myHub = "OrbitalGarage", features = { NewHubs = true }, racing = false })
		check("card with the gate visits Balloon Terminal", gated.hubId == "BalloonTerminal" and gated.visitEnabled)
	end

	------------------------------------------------------------------ two-player lifecycle (07)
	local H, B = m.HubRules, m.BallotRules
	if H and B then
		local built = { OrbitalGarage = true, BalloonTerminal = true, BasaltDeck = true }
		local chosen = { A = "OrbitalGarage", F = "OrbitalGarage" }
		local d = H.Decide({ hubId = "BalloonTerminal", mode = "Visit", now = 10 }, { built = built, allowed = { OrbitalGarage = true, BalloonTerminal = true }, current = "OrbitalGarage", racing = false, inTrial = false })
		if d.ok then
			chosen.A = d.hubId
		end
		check("player A visits Balloon Terminal; friend F stays in Orbital Garage", chosen.A == "BalloonTerminal" and chosen.F == "OrbitalGarage")
		local box = B.NewBox(7)
		B.Cast(box, 1, "SkyCarnival_B1", 7, 1, { SkyCarnival_B1 = true, NeonFoundry_A4 = true })
		B.Cast(box, 2, "SkyCarnival_B1", 7, 1, { SkyCarnival_B1 = true, NeonFoundry_A4 = true })
		local winner = B.Resolve(box, { [1] = true, [2] = true }, { "NeonFoundry_A4", "SkyCarnival_B1" }, 1)
		check("both queue from different hubs and enter the same next race", winner == 2)
		check("after results each returns to the hub they chose", H.ReturnHub(chosen.A, built, "OrbitalGarage") == "BalloonTerminal" and H.ReturnHub(chosen.F, built, "OrbitalGarage") == "OrbitalGarage")
		local lost, fell = H.ReturnHub(chosen.A, { OrbitalGarage = true }, "OrbitalGarage")
		check("if Balloon Terminal failed to load, A lands in Orbital Garage", lost == "OrbitalGarage" and fell)
		local box2 = B.NewBox(8)
		B.Cast(box2, 1, "SkyCarnival_B1", 8, 1, { SkyCarnival_B1 = true })
		B.Cast(box2, 2, "SkyCarnival_B1", 8, 1, { SkyCarnival_B1 = true })
		B.Remove(box2, 2)
		local _, counted = B.Tally(box2, { [1] = true }, { "SkyCarnival_B1" })
		check("queue continuity: one client leaves, the other's ballot and place stay", counted == 1)
		local balloon = R.RawHub("BalloonTerminal")
		local broken = TD.Generate(balloon.Chute, radius)
		broken.SpawnFrame = nil
		local errs = L.ValidateHub(balloon.Geometry, broken, HB.SpawnCFrames(balloon.Geometry, radius, 0.5), -1e5)
		check("a hub with a missing practice spawn is rejected at load (then not offered)", table.concat(errs, " "):find("no practice entry") ~= nil)
	end
	local VP = m.VisualProfiles
	if VP then
		local ok = true
		for _, entry in ipairs(R.Hubs) do
			local _, fellBack = VP.Get(entry.Profile)
			ok = ok and not fellBack
		end
		check("every hub's visual profile exists (a missing one falls back to the night profile)", ok and select(2, VP.Get("Broken")) == true)
	end
	return results
end

return Spec
