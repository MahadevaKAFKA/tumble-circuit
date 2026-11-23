--[[
	RoundState.spec — A2 pure assertions: round transition graph, remote payload validation,
	standings order and ties, grid shuffle, checkpoint/finish judging with simulated server
	samples (ordered crossings, skip/jump rejection, corridor, impossible splits, respawn),
	and the hub layout. Runs in Studio (TestRunner) and offline (tools/offline/run_tests.lua).
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
	local RP, RR = m.RoundProtocol, m.RaceRules
	local S = RP.States

	-------------------------------------------------------------------- transition graph
	local reachable, queue = { [S.Boot] = true }, { S.Boot }
	while #queue > 0 do
		local state = table.remove(queue, 1)
		for to in pairs(RP.Transitions[state] or {}) do
			if not reachable[to] then
				reachable[to] = true
				table.insert(queue, to)
			end
		end
	end
	local allReachable = true
	for _, state in pairs(S) do
		if not reachable[state] then
			allReachable = false
		end
	end
	check("every round state is reachable from Boot", allReachable)
	local noDeadEnds = true
	for _, state in pairs(S) do
		local exits = 0
		for _ in pairs(RP.Transitions[state] or {}) do
			exits = exits + 1
		end
		if exits == 0 then
			noDeadEnds = false
		end
	end
	check("no round state is a dead end", noDeadEnds)
	local cycle = { S.Intermission, S.Preparing, S.Countdown, S.Racing, S.Results, S.Cleanup, S.Intermission }
	local cycleOk = true
	for i = 1, #cycle - 1 do
		if not RP.CanTransition(cycle[i], cycle[i + 1]) then
			cycleOk = false
		end
	end
	check("full race cycle Intermission -> ... -> Intermission is legal", cycleOk)
	check("cannot jump Lobby -> Racing or Intermission -> Racing", not RP.CanTransition(S.Lobby, S.Racing) and not RP.CanTransition(S.Intermission, S.Racing))
	check("self-transitions are not in the graph (idempotence is RoundService's job)", not RP.CanTransition(S.Racing, S.Racing))
	check("aborts always possible once racers are placed", RP.CanTransition(S.Preparing, S.Cleanup) and RP.CanTransition(S.Countdown, S.Cleanup) and RP.CanTransition(S.Racing, S.Cleanup))

	-------------------------------------------------------------------- payload validation
	local cases = {
		{ "RequestJoinRace", { true }, true },
		{ "RequestJoinRace", {}, false },
		{ "RequestJoinRace", { "yes" }, false },
		{ "RequestJoinRace", { true, 5 }, false },
		{ "RequestRecover", {}, true },
		{ "RequestRecover", { {} }, false },
		{ "RequestSnapshot", {}, true },
		{ "RoundSnapshot", {}, false },
		{ "SetFinishTime", { 1 }, false },
	}
	local validationOk, bad = true, nil
	for _, case in ipairs(cases) do
		local ok = RP.ValidateArgs(case[1], table.unpack(case[2]))
		if ok ~= case[3] then
			validationOk, bad = false, case[1] .. " #" .. #case[2]
		end
	end
	check("remote payload validation accepts only exact schemas", validationOk, bad)
	local limitsOk = true
	for name, spec in pairs(RP.Remotes) do
		if spec.Direction == "ClientToServer" and not (spec.MinInterval and spec.MinInterval > 0) then
			limitsOk = false
		end
		if string.find(name, "Set") == 1 then
			limitsOk = false
		end
	end
	check("every client remote is rate limited; no Set* remotes exist", limitsOk)

	-------------------------------------------------------------------- standings
	local function entry(t)
		t.finishOrdinal = t.finishOrdinal or math.huge
		t.checkpoint = t.checkpoint or 0
		t.progressS = t.progressS or 0
		return t
	end
	local list = RR.SortStandings({
		entry({ userId = 1, ordinal = 1, finished = false, checkpoint = 2, progressS = 700 }),
		entry({ userId = 2, ordinal = 2, finished = true, finishOrdinal = 2 }),
		entry({ userId = 3, ordinal = 3, finished = false, checkpoint = 3, progressS = 650 }),
		entry({ userId = 4, ordinal = 4, finished = true, finishOrdinal = 1 }),
		entry({ userId = 5, ordinal = 5, finished = false, dnf = true, checkpoint = 3, progressS = 900 }),
		entry({ userId = 6, ordinal = 6, finished = false, checkpoint = 2, progressS = 700 }),
	})
	local order = {}
	for i, e in ipairs(list) do
		order[i] = e.userId
	end
	check("standings: finishers by order, then checkpoint, then distance, ties by ordinal, DNF last", table.concat(order, ",") == "4,2,3,1,6,5", table.concat(order, ","))
	local ties = RR.OrderFinishes({ { time = 10.0, ordinal = 2 }, { time = 9.98, ordinal = 3 }, { time = 10.0, ordinal = 1 } })
	check("near-simultaneous finishes ordered by interpolated time then ordinal", ties[1].ordinal == 3 and ties[2].ordinal == 1 and ties[3].ordinal == 2)
	local frac = RR.CrossingFraction(90, 110, 100)
	check("crossing fraction interpolates inside a sample", frac and math.abs(frac - 0.5) < 1e-9 and RR.CrossingFraction(110, 90, 100) == nil)

	local ids = { 50, 10, 40, 20, 30 }
	local a1, a2, b = RR.ShuffleGrid(ids, 7), RR.ShuffleGrid(ids, 7), RR.ShuffleGrid(ids, 8)
	local same, perm, seen = true, true, {}
	for i = 1, #ids do
		if a1[i] ~= a2[i] then
			same = false
		end
		seen[a1[i]] = (seen[a1[i]] or 0) + 1
	end
	for _, id in ipairs(ids) do
		if seen[id] ~= 1 then
			perm = false
		end
	end
	check("grid shuffle is a deterministic permutation", same and perm and #a1 == #ids)
	check("grid shuffle varies between rounds", table.concat(a1, ",") ~= table.concat(b, ","))

	-------------------------------------------------------------------- checkpoint judging
	local layout = m.TrackDefinitions.Generate(m.TrackDefinitions.Training, m.PhysicsConfig.Ball.Radius)
	local fakeTrack = { GetLayout = function()
		return layout
	end }
	local CP = m.CheckpointService.new(fakeTrack)
	local p1, p2, p3, p4 = { Name = "p1" }, { Name = "p2" }, { Name = "p3" }, { Name = "p4" }
	local gridS = layout.GridSlots[1].Frame.S
	CP:BeginRound({ [p1] = gridS, [p2] = gridS, [p3] = gridS, [p4] = gridS }, 0)

	local function run(player, speed, dt, untilS, opts)
		opts = opts or {}
		local s, t, events = gridS, 0, {}
		local prevS, prevT = nil, nil
		while s < untilS do
			prevS, prevT = s, t
			s = s + speed * dt
			t = t + dt
			local ev = CP:Process(player, { prevS = prevS, s = s, prevTime = prevT, time = t, distance = opts.distance or 0, halfWidth = 11, frozen = false })
			for _, e in ipairs(ev or {}) do
				table.insert(events, e)
			end
		end
		return events
	end
	local events = run(p1, 40, 0.05, layout.FinishLineS + 5)
	local kinds = {}
	for _, e in ipairs(events) do
		kinds[#kinds + 1] = e.kind .. (e.index and e.index or "")
	end
	check("checkpoints confirmed in order, then finish", table.concat(kinds, ",") == "Checkpoint1,Checkpoint2,Checkpoint3,Finish", table.concat(kinds, ","))
	local finish = events[#events]
	local expected = (layout.FinishLineS - gridS) / 40
	check("finish time interpolated within one sample", finish and finish.seconds and math.abs(finish.seconds - expected) < 1e-6, finish and finish.seconds)
	check("finished racer produces no further events", CP:Process(p1, { prevS = 100, s = 2000, prevTime = 1, time = 1.05, distance = 0, halfWidth = 11 }) == nil)

	local jump = CP:Process(p2, { prevS = gridS, s = gridS + 500, prevTime = 1, time = 1.05, distance = 0, halfWidth = 11 })
	check("teleport-sized progress jump is rejected (no checkpoint)", jump and jump[1].kind == "Rejected" and CP:GetConfirmed(p2) == 0)
	local wide = run(p3, 40, 0.05, layout.Checkpoints[1].S + 2, { distance = 30 })
	check("crossing outside the corridor is rejected", wide[1] and wide[1].kind == "Rejected" and CP:GetConfirmed(p3) == 0)
	local fast = run(p4, 120, 0.05, layout.Checkpoints[1].S + 2)
	check("impossibly fast split (120 studs/s average) is rejected", fast[1] and fast[1].kind == "Rejected" and CP:GetConfirmed(p4) == 0)
	check("respawn sample (no previous progress) never crosses", CP:Process(p2, { prevS = nil, s = layout.Checkpoints[1].S + 6, prevTime = nil, time = 5, distance = 0, halfWidth = 11 }) == nil)
	check("progress capped at the next unconfirmed checkpoint", CP:CapProgress(p2, 900) == layout.Checkpoints[1].S)

	-------------------------------------------------------------------- hub
	local hub = m.TrackDefinitions.Hub
	local spawns = m.HubBuilder.SpawnCFrames(hub, 2, 0.25)
	local spacingOk, insideOk = true, true
	for i = 1, #spawns do
		local p = spawns[i].Position
		local flat = Vector3.new(p.X - hub.Center.X, 0, p.Z - hub.Center.Z).Magnitude
		if flat + 2 > hub.Radius - 4 then
			insideOk = false
		end
		for j = i + 1, #spawns do
			if (spawns[j].Position - p).Magnitude < 6 then
				spacingOk = false
			end
		end
	end
	check("hub has 16 spawn spots, spaced >= 1.5 marble widths", #spawns == 16 and spacingOk)
	check("hub spawns sit well inside the rim", insideOk)
	local chuteDef = m.TrackDefinitions.PracticeChute
	local edge = Vector3.new(chuteDef.Origin.X - hub.Center.X, 0, chuteDef.Origin.Z - hub.Center.Z).Magnitude
	check("practice chute starts flush with the hub floor edge", math.abs(chuteDef.Origin.Y - hub.Center.Y) < 1e-6 and edge < hub.Radius and edge > hub.Radius - 4)
	local chuteHalf = chuteDef.Pieces[1].Width[1] / 2
	local gapOk = true
	for _, spec in ipairs(m.HubBuilder.ComputeSpecs(hub, chuteDef.Pieces[1].Width[1])) do
		if spec.Name == "Rim" then
			local rel = spec.CFrame.Position - hub.Center
			if rel.X > 0 and math.abs(rel.Z) < chuteHalf + 1.2 then
				gapOk = false
			end
		end
	end
	check("hub rim leaves the chute entrance open", gapOk)
	local chuteLayout = m.TrackDefinitions.Generate(chuteDef, 2)
	check("practice chute validates", #m.TrackDefinitions.Validate(chuteDef, chuteLayout) == 0, table.concat(m.TrackDefinitions.Validate(chuteDef, chuteLayout), "; "))
	check("race track has >= 3 checkpoints and 16 grid slots", #layout.Checkpoints >= 3 and #layout.GridSlots == 16)

	return results
end

return Spec
