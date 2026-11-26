--[[
	Circuits.spec (2026-11-26 three-lap brief) — the Neon Foundry three-lap circuit and the lap
	rules: closure, lap targets, ordered/directional crossings on race distance, tracker wrap
	and respawn hints, branch-equal progress, boost lanes, finisher deck, bots on a risk split,
	HUD lap state, nameplate declutter and the case-opening pose. Pure modules only.
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
	local TD, TV, RT = m.TrackDefinitions, m.TrackValidator, m.RouteTracker
	local radius = m.PhysicsConfig.Ball.Radius
	local def = TD.NeonFoundryCircuit
	local layout = TD.Generate(def, radius)
	local L = layout.LapLength

	------------------------------------------------------------------ the course
	check("standard races use the circuit (one flag back to the single run)", TD.CircuitRaces == true and TD.Worlds[1] == def and TD.LegacyWorlds[1] == TD.NeonFoundry)
	local errors = TD.Validate(def, layout)
	check("circuit passes the generator validator", #errors == 0, table.concat(errors, " | "))
	local tv = TV.Validate(def, layout)
	check("circuit passes TrackValidator (all hazard seeds)", #tv == 0, table.concat(tv, " | "))
	check("the lap closes on itself (< 0.05 studs before the snap)", layout.Loop and layout.ClosureError < 0.05, string.format("%.4f", layout.ClosureError))
	local first, last = layout.Sections[1], layout.Sections[#layout.Sections]
	check("start/finish seam: same point, same facing, same width", (first.Position - last.Position).Magnitude < 1e-6 and first.Forward:Dot(last.Forward) > 0.9999 and math.abs(first.Width - last.Width) < 1e-6)
	check("8-12 checkpoint sectors per lap", #layout.Checkpoints >= 8 and #layout.Checkpoints <= 12, #layout.Checkpoints)
	check("three laps, 2200-3600 stud lap", layout.Laps == 3 and L >= 2200 and L <= 3600, string.format("%.0f", L))
	local standing, flying, race = TD.EstimateLapSeconds(layout, m.PhysicsConfig.Movement, 196.2, 3)
	results.info[#results.info + 1] = string.format("Neon Foundry circuit: lap %.0f studs, model standing %.1f s / flying %.1f s / race %.0f s (MODEL, not a measurement)", L, standing, flying, race)
	check("lap MODEL inside the 55-80 s clean-lap target", flying >= 55 and flying <= 80, string.format("%.1f", flying))
	check("race MODEL 3-5 min before hazards and mistakes are added", race >= 160 and race <= 300, string.format("%.0f", race))
	check("race clock is the course's own (not the old 180 s)", def.MaxRaceSeconds and def.MaxRaceSeconds >= race * 2)
	local climb = 0
	for _, piece in ipairs(def.Pieces) do
		local p = piece.Pitch or { 0, 0 }
		climb = math.min(climb, p[1], p[2])
	end
	check("a real return leg: the lap climbs back (<= 9 degrees) to the grid level", climb < -3 and climb >= -9, climb)
	local boosted = 0
	for _, hz in ipairs(layout.Hazards) do
		if hz.Kind == "Boost" and hz.Definition.Piece:find("Ascent") then
			boosted = boosted + hz.Length
		end
	end
	check("the climb has a marked boost lane along it (assisted ascent)", boosted > 300, boosted)
	local gapsOk, worst = true, 0
	local prev = 0
	for _, cp in ipairs(layout.Checkpoints) do
		worst = math.max(worst, cp.S - prev)
		prev = cp.S
	end
	worst = math.max(worst, L - prev)
	gapsOk = worst <= 650
	check("no recovery costs more than 650 studs (checkpoint gaps around the lap)", gapsOk, string.format("%.0f", worst))
	local hub = TD.Hub
	local nearest = math.huge
	for _, sec in ipairs(layout.Sections) do
		local d = sec.Position - hub.Center
		nearest = math.min(nearest, math.sqrt(d.X * d.X + d.Z * d.Z))
	end
	check("the lap stays far from the Orbital Garage (no road over the hub)", nearest > hub.Radius + 150, string.format("%.0f", nearest))

	------------------------------------------------------------------ route choices
	local function laneBias(pieceName, offset)
		local piece = layout.PieceByName[pieceName]
		local worstBias = 0
		for at = 6, piece.Definition.Length - 6, 12 do
			local f = TD.SampleAtH(layout, piece.StartH + at)
			local a, b = RT.new(layout.Route, { hintS = f.S }), RT.new(layout.Route, { hintS = f.S })
			for k = 30, 1, -5 do
				local g = TD.SampleAtH(layout, piece.StartH + at - k)
				a:Update(g.Position + g.Right * offset + g.Up * radius)
				b:Update(g.Position - g.Right * offset + g.Up * radius)
			end
			local sa = a:Update(f.Position + f.Right * offset + f.Up * radius).s
			local sb = b:Update(f.Position - f.Right * offset + f.Up * radius).s
			worstBias = math.max(worstBias, math.abs(sa - sb))
		end
		return worstBias
	end
	check("split A: both lanes share one progress scale (+-2 studs)", laneBias("SplitACurve", 8.5) <= 2)
	check("split B: both lanes share one progress scale (+-2 studs)", laneBias("SplitBCurveB", 8.5) <= 2)
	local gap = layout.PieceByName.SplitBGap
	local kicker = nil
	for _, z in ipairs(layout.TrickZones) do
		if z.Offset > 0 and z.LipS < layout.Sections[gap.FirstSection].S + 1 and z.LipS > layout.Sections[gap.FirstSection].S - 10 then
			kicker = z
		end
	end
	check("split B risk line: right-lane gap with a kicker right before it, safe left lane walled", gap.Definition.HalfFloor == "Left" and gap.Definition.Divider ~= nil and kicker ~= nil)
	local cpS = {}
	for _, cp in ipairs(layout.Checkpoints) do
		cpS[cp.Name] = cp.S
	end
	local splitA = layout.PieceByName.SplitACurve
	local splitB = layout.PieceByName.SplitBGap
	check("both branches sit between equivalent gates (a gate before and after each split)", cpS["Split A"] < layout.Sections[splitA.FirstSection].S and cpS["Inspection Hall"] > layout.Sections[splitA.LastSection].S and cpS["Split B"] < layout.Sections[splitB.FirstSection].S and cpS["Hammer"] > layout.Sections[splitB.LastSection].S)

	------------------------------------------------------------------ targets
	local targets = layout.Targets
	local per = #layout.Checkpoints
	check("targets: every lap's gates, two lap lines, one finish", #targets == 3 * (per + 1) and targets[per + 1].Kind == "Lap" and targets[2 * (per + 1)].Kind == "Lap" and targets[#targets].Kind == "Finish" and math.abs(targets[#targets].S - 3 * L) < 1e-6)
	local ordered = true
	for i = 2, #targets do
		ordered = ordered and targets[i].S > targets[i - 1].S
	end
	check("targets strictly ascend in race distance", ordered)
	local lap, cp = TD.LapState(layout, 0, 3)
	local lap2, cp2 = TD.LapState(layout, per + 1 + 3, 3)
	local lap3 = TD.LapState(layout, 2 * (per + 1), 3)
	check("lap state: start = LAP 1 CP 0; after a lap line + 3 gates = LAP 2 CP 3; final lap = 3", lap == 1 and cp == 0 and lap2 == 2 and cp2 == 3 and lap3 == 3)

	------------------------------------------------------------------ crossings (CheckpointService)
	local CS = m.CheckpointService
	local track = { GetLayout = function()
		return layout
	end }
	local function newJudge()
		local judge = CS.new(track)
		judge:BeginRound({ P = -20 }, 0)
		return judge
	end
	-- a run that rolls the whole race in small steps (40 studs per 1 s sample)
	local function drive(judge, from, to, step, t0, frozen)
		local events = {}
		local s, t = from, t0 or 0
		while s < to do
			local nextS = math.min(to, s + (step or 40))
			for _, e in ipairs(judge:Process("P", { prevS = s, s = nextS, prevTime = t, time = t + 1, distance = 0, halfWidth = 13, frozen = frozen }) or {}) do
				events[#events + 1] = e
			end
			s, t = nextS, t + 1
		end
		return events, t
	end
	local judge = newJudge()
	local events = drive(judge, -20, 3 * L + 10)
	local kinds = { Checkpoint = 0, Lap = 0, Finish = 0, Rejected = 0 }
	for _, e in ipairs(events) do
		kinds[e.kind] = (kinds[e.kind] or 0) + 1
	end
	check("a clean three-lap run: every gate on every lap, two LAP events, one finish", kinds.Checkpoint == 3 * per and kinds.Lap == 2 and kinds.Finish == 1 and kinds.Rejected == 0, string.format("%d cp, %d lap, %d fin, %d rej", kinds.Checkpoint, kinds.Lap, kinds.Finish, kinds.Rejected))
	local laps = judge:GetLapTimes("P")
	check("three lap times recorded (lap 1 from GO, laps 2-3 line to line)", #laps == 3 and laps[1] > 0 and laps[3] > 0, #laps)
	local judge2 = newJudge()
	local early = drive(judge2, -20, 400, 40, 0, true)
	check("frozen on the grid: crossing the line / a gate early counts nothing", #early == 0 and judge2:GetConfirmed("P") == 0)
	local judge3 = newJudge()
	drive(judge3, -20, 40)
	local back = drive(judge3, -40, -5) -- rolled back over the line, then forward again
	check("a reversed line crossing never counts (no lap, no gate)", judge3:GetConfirmed("P") == 0 and #back == 0)
	local judge4 = newJudge()
	drive(judge4, -20, layout.Checkpoints[1].S + 10)
	local dup = drive(judge4, layout.Checkpoints[1].S - 5, layout.Checkpoints[1].S + 5, 2)
	check("duplicate contact with a gate counts once", judge4:GetConfirmed("P") == 1 and #dup == 0)
	local judge5 = newJudge()
	drive(judge5, -20, layout.Checkpoints[2].S - 10) -- first gate taken
	local skip = judge5:Process("P", { prevS = layout.Checkpoints[2].S - 10, s = layout.Checkpoints[4].S + 5, prevTime = 50, time = 50.1, distance = 0, halfWidth = 13 })
	check("a jump past gates is rejected and nothing after the last gate counts", judge5:GetConfirmed("P") == 1 and skip and skip[1].kind == "Rejected")
	local judge6 = newJudge()
	drive(judge6, -20, L + 10)
	local lap1Done = judge6:GetConfirmed("P")
	check("one lap only = lap 2 (not finished)", lap1Done == per + 1 and not judge6:IsFinished("P"))
	local judge7 = newJudge()
	local wide = judge7:Process("P", { prevS = layout.Checkpoints[1].S - 5, s = layout.Checkpoints[1].S + 5, prevTime = 9, time = 9.2, distance = 40, halfWidth = 13 })
	check("a gate crossed outside the corridor (a neighbouring road) does not count", judge7:GetConfirmed("P") == 0 and wide and wide[1].kind == "Rejected")
	local judge8 = CS.new(track, 1)
	judge8:BeginRound({ P = 6 }, 0)
	local ttEvents = drive(judge8, 6, L + 10)
	local ttFinish = ttEvents[#ttEvents]
	check("a one-lap Time Trial judge finishes at the line after one lap", ttFinish and ttFinish.kind == "Finish" and judge8:GetConfirmed("P") == per + 1)

	------------------------------------------------------------------ tracker wrap + hints
	local tr = RT.new(layout.Route, { hintS = -30 })
	local seq = {}
	for s = L - 30, L + 30, 6 do
		local p = RT.PointAtS(layout.Route, s)
		seq[#seq + 1] = tr:Update(p).s
	end
	local mono = true
	for i = 2, #seq do
		mono = mono and seq[i] > seq[i - 1]
	end
	check("tracker: race distance keeps growing across the start/finish line", mono and seq[1] < 0 and seq[#seq] > 0, string.format("%.1f .. %.1f", seq[1], seq[#seq]))
	local backward = {}
	for s = L + 20, L - 20, -5 do
		backward[#backward + 1] = tr:Update(RT.PointAtS(layout.Route, s)).s
	end
	check("tracker: rolling back over the line goes back below 0 (no phantom lap)", backward[#backward] < 0)
	local respawnS = L + layout.Checkpoints[5].S + 6
	local tr2 = RT.new(layout.Route, { hintS = respawnS })
	local got = tr2:Update(RT.PointAtS(layout.Route, respawnS)).s
	check("respawn hint: a lap-2 checkpoint respawn tracks as lap 2", math.abs(got - respawnS) < 1, string.format("%.1f vs %.1f", got, respawnS))

	------------------------------------------------------------------ boost lane, deck, bots
	local HS = m.HazardSim
	local lift
	for _, hz in ipairs(layout.Hazards) do
		if hz.Id == "Lift4" then
			lift = { Kind = hz.Kind, Frame = hz.Frame, FromFrame = hz.FromFrame, ToFrame = hz.ToFrame, Length = hz.Length, Params = HS.Params(hz.Definition, 0) }
		end
	end
	local mid = TD.SampleAtH(layout, (lift.FromFrame.H + lift.ToFrame.H) / 2)
	local inLane = HS.EnvironmentAccel(lift, 0, mid.Position + mid.Right * -6 + mid.Up * radius)
	local outLane = HS.EnvironmentAccel(lift, 0, mid.Position + mid.Right * 8 + mid.Up * radius)
	check("boost lane pushes along the road in its lane only", inLane ~= nil and inLane.Magnitude > 16 and inLane.Unit:Dot(mid.Forward) > 0.97 and outLane == nil)
	local deck = layout.FinisherDeck
	local deckClear = math.huge
	for _, sec in ipairs(layout.Sections) do
		local d = sec.Position - deck.Position
		deckClear = math.min(deckClear, math.sqrt(d.X * d.X + d.Z * d.Z))
	end
	check("finisher deck sits clear of the road (finishers leave the lap)", deck and deckClear > 30, string.format("%.0f", deckClear))
	local BB = m.BotBrain
	if BB then
		local state = {}
		local target = BB.ChooseTarget({ splitAhead = { inside = 1, forced = -1 }, halfWidth = 17, hazards = {}, s = 0, lateral = 0, rng = function()
			return 0
		end, skill = 1.2 }, state)
		check("bots always take the walled safe lane at a risk split", state.splitChoice == -1 and target < 0)
		local boostTarget = BB.ChooseTarget({ boostLane = -6, halfWidth = 14, hazards = {}, s = 0, lateral = 0, rng = function()
			return 0.5
		end, skill = 1 }, {})
		check("bots aim for a boost lane", math.abs(boostTarget + 6) < 1e-6)
	end

	------------------------------------------------------------------ Sky Carnival (milestone 3)
	local sky = TD.SkyCarnivalCircuit
	local skyLayout = TD.Generate(sky, radius)
	local skyErrors = TD.Validate(sky, skyLayout)
	local skyTv = TV.Validate(sky, skyLayout)
	check("Sky Carnival circuit validates (generator + TrackValidator)", #skyErrors == 0 and #skyTv == 0, table.concat(skyErrors, " | ") .. table.concat(skyTv, " | "))
	check("Sky Carnival is a race-ready circuit in the rotation", TD.Worlds[2] == sky and TD.RaceReady("SkyCarnival_B1"))
	local skyYaw, foundryYaw = 0, 0
	for _, piece in ipairs(sky.Pieces) do
		skyYaw = skyYaw + (piece.Yaw or 0)
	end
	for _, piece in ipairs(def.Pieces) do
		foundryYaw = foundryYaw + (piece.Yaw or 0)
	end
	check("different topology: Foundry turns right once, Sky Carnival turns left twice (a stacked helix)", foundryYaw == 360 and skyYaw == -720, string.format("%d / %d", foundryYaw, skyYaw))
	local helix = skyLayout.PieceByName.HelixB
	local minGap = math.huge
	for i = helix.FirstSection, helix.LastSection do
		for j = i + 1, helix.LastSection do
			local a, b = skyLayout.Sections[i], skyLayout.Sections[j]
			local d = a.Position - b.Position
			if b.S - a.S > 200 and math.sqrt(d.X * d.X + d.Z * d.Z) < 10 then
				minGap = math.min(minGap, math.abs(d.Y))
			end
		end
	end
	check("helix turns are stacked with real headroom (>= 30 studs between the turns)", minGap >= 30 and minGap < math.huge, string.format("%.0f", minGap))
	local trk = RT.new(skyLayout.Route, { hintS = skyLayout.Sections[helix.FirstSection].S })
	local jumped, prevS = false, nil
	for i = helix.FirstSection, helix.LastSection do
		local sec = skyLayout.Sections[i]
		local got = trk:Update(sec.Position + sec.Up * radius).s
		if prevS and (got < prevS - 1 or got > prevS + 60) then
			jumped = true
		end
		prevS = got
	end
	check("progress never jumps between the stacked helix turns", not jumped)
	local _, skyFlying, skyRace = TD.EstimateLapSeconds(skyLayout, m.PhysicsConfig.Movement, 196.2, 3)
	results.info[#results.info + 1] = string.format("Sky Carnival circuit: lap %.0f studs, model flying lap %.1f s, race %.0f s (MODEL)", skyLayout.LapLength, skyFlying, skyRace)
	check("Sky Carnival lap MODEL inside 55-80 s, race 3-5 min", skyFlying >= 55 and skyFlying <= 80 and skyRace >= 160 and skyRace <= 300, string.format("%.1f / %.0f", skyFlying, skyRace))
	local bounce, hops = false, 0
	for _, hz in ipairs(skyLayout.Hazards) do
		if hz.Id == "GapDrum" then
			bounce = hz.Offset < 0 and skyLayout.PieceByName.CloudGapA.Definition.HalfFloor == "Right"
		end
	end
	for _, piece in ipairs(sky.Pieces) do
		if piece.HalfFloor == "Left" then
			hops = hops + 1
		end
	end
	check("Sky Carnival choices: drum bounce over the cloud gap (or the bridge), two kicker hops (or the wide arc)", bounce and hops == 2 and #skyLayout.TrickZones >= 2)

	------------------------------------------------------------------ Volcano Vault (graphics brief C)
	local vv = TD.VolcanoVaultCircuit
	local vvLayout = TD.Generate(vv, radius)
	local vvErr, vvTv = TD.Validate(vv, vvLayout), TV.Validate(vv, vvLayout)
	check("Volcano Vault circuit validates and is back in rotation", #vvErr == 0 and #vvTv == 0 and TD.Worlds[3] == vv and TD.RaceReady("VolcanoVault_B1"), table.concat(vvErr, " | ") .. table.concat(vvTv, " | "))
	local _, vvFlying, vvRace = TD.EstimateLapSeconds(vvLayout, m.PhysicsConfig.Movement, 196.2, 3)
	results.info[#results.info + 1] = string.format("Volcano Vault circuit: lap %.0f studs, model flying lap %.1f s, race %.0f s (MODEL)", vvLayout.LapLength, vvFlying, vvRace)
	check("Volcano Vault lap MODEL inside 55-80 s, race 3-5 min", vvFlying >= 55 and vvFlying <= 80 and vvRace >= 160 and vvRace <= 300, string.format("%.1f / %.0f", vvFlying, vvRace))
	local road = vv.Theme.NavyFloor
	local lum = 0.2126 * road.R + 0.7152 * road.G + 0.0722 * road.B
	check("Volcano Vault road is a neutral-grey midtone against the lava", lum > 0.3 and lum < 0.5 and math.abs(road.R - road.B) < 0.05, string.format("%.2f", lum))
	local roofed, ventSplit = 0, layout and vvLayout.PieceByName.VentSplit
	for _, piece in ipairs(vv.Pieces) do
		if piece.Roof then
			roofed = roofed + 1
		end
	end
	check("Volcano Vault: a timed-vent split, a brake split and an uphill tunnel through the ridge", ventSplit and ventSplit.Definition.Divider and vvLayout.PieceByName.BrakeSplit.Definition.Divider and roofed >= 4)

	------------------------------------------------------------------ instrumentation (brief 3 A)
	local RS = m.RaceStats
	if RS then
		local stats = RS.new(layout)
		local plain = layout.Sections[layout.PieceByName.PassingA.FirstSection].S + 60 -- a passing straight: plain road
		stats:OnSample("P", { s = plain, height = 0.1 })
		stats:OnSample("P", { s = plain + 5, height = 3.2 }) -- airborne on plain road = seam suspect
		local kick = layout.TrickZones[1].LipS
		stats:OnSample("Q", { s = kick - 2, height = 0.1 })
		stats:OnSample("Q", { s = kick + 4, height = 3.5 }) -- the trick ramp: by design
		stats:OnRespawn("Q", "Fell")
		stats:OnRespawn("P", "Reset")
		stats:OnResult(true)
		stats:OnResult(false)
		local sum = stats:Summary()
		local launches, falls, resets = 0, 0, 0
		for _, row in ipairs(sum.sectors) do
			launches, falls, resets = launches + row.launches, falls + row.falls, resets + row.resets
		end
		check("race stats: a launch on plain road is flagged, a kicker jump is not; resets / falls counted per sector", launches == 1 and falls == 1 and resets == 1 and sum.line:find("finished 1, dnf 1", 1, true) ~= nil, sum.line)
		local lap2 = stats:SectorAt(L + layout.Checkpoints[3].S + 1)
		check("race stats: sectors are per lap (lap 2 gate 3 = sector 3)", lap2 == 3)
	end

	------------------------------------------------------------------ HUD / tags / reveal
	local NP = m.NameplatePure
	if NP then
		local c = {}
		for i = 1, 8 do
			c[i] = { id = "b" .. i, distance = 4 + i * 6, x = 400 + i * (i > 5 and 90 or 10), y = 300, onScreen = true }
		end
		local shown = NP.Decide(c, {})
		local n = 0
		for _ in pairs(shown) do
			n = n + 1
		end
		check("name tags: never the stacked row - none closer than 16 studs, overlaps hidden, at most 3", n <= 3 and not shown.b1 and n >= 1)
		check("name tags: none at all on the start grid", next(NP.Decide(c, { hideAll = true })) == nil)
	end
	local RV = m.RevealPure
	if RV and RV.ChestPose then
		local pop, shake, burst = RV.ChestPose(0.1), RV.ChestPose(0.8), RV.ChestPose(1.2)
		check("case opening: pops in, shakes harder, the lid flies off with a flash", pop.lid == 0 and math.abs(shake.rotation) >= 0 and shake.burst == 0 and burst.lid > 100 and burst.burst > 0.5)
		local reduced = RV.ChestPose(0.3, true)
		check("Reduced Motion: the case opens without any shake", reduced.rotation == 0 and reduced.lid > 0)
	end
	return results
end

return Spec
