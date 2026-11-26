--[[
	MapSelection.spec — promo pack prompt 03: ballots for the next race, personal destinations
	(Visit Hub / Practice) and the Map Selection card states. Pure modules only.
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
	local B, H = m.BallotRules, m.HubRules
	if not (B and H) then
		check("prompt 03 modules load", false)
		return results
	end
	local maps = { "NeonFoundry_A4", "SkyCarnival_B1", "VolcanoVault_B1" }
	local eligible = { NeonFoundry_A4 = true, SkyCarnival_B1 = true, VolcanoVault_B1 = true }

	------------------------------------------------------------------ solo
	local box = B.NewBox(1)
	check("solo: a queued player's ballot is accepted", B.Cast(box, 10, "VolcanoVault_B1", 1, 1, eligible))
	local winner = B.Resolve(box, { [10] = true }, maps, 1)
	check("solo: a single ballot picks the course (no 2-player minimum)", maps[winner] == "VolcanoVault_B1")
	check("a resolved box refuses late ballots", select(2, B.Cast(box, 10, "SkyCarnival_B1", 1, 2, eligible)) == "closed")

	------------------------------------------------------------------ two clients, simultaneous, different choices
	box = B.NewBox(2)
	B.Cast(box, 1, "SkyCarnival_B1", 2, 1, eligible)
	B.Cast(box, 2, "VolcanoVault_B1", 2, 1, eligible)
	local voters = { [1] = true, [2] = true }
	local counts = B.Tally(box, voters, maps)
	check("two clients: both ballots count once each", counts[1] == 0 and counts[2] == 1 and counts[3] == 1)
	check("tie -> first tied map in rotation order from the candidate (candidate 1 -> Sky)", maps[B.Winner(counts, 1)] == "SkyCarnival_B1")
	check("tie -> candidate 3 -> Volcano (deterministic, every server agrees)", maps[B.Winner(counts, 3)] == "VolcanoVault_B1")
	check("no ballots -> the rotation candidate", B.Winner({ 0, 0, 0 }, 2) == 2)

	------------------------------------------------------------------ duplicate / stale / changed
	local ok1, why1 = B.Cast(box, 1, "VolcanoVault_B1", 2, 2, eligible)
	check("a newer ballot replaces the old one (one ballot per player)", ok1 and why1 == "changed" and B.Tally(box, voters, maps)[3] == 2)
	check("the same request again is ignored (duplicate seq)", select(2, B.Cast(box, 1, "SkyCarnival_B1", 2, 2, eligible)) == "duplicate")
	check("an older request arriving late is ignored (out of order)", select(2, B.Cast(box, 1, "SkyCarnival_B1", 2, 1, eligible)) == "duplicate" and B.Tally(box, voters, maps)[3] == 2)
	check("a ballot for an already-decided race is stale", select(2, B.Cast(box, 1, "SkyCarnival_B1", 1, 9, eligible)) == "stale")
	check("a ballot for a map that is not eligible here is refused", select(2, B.Cast(box, 1, "Tideworks_X", 2, 9, eligible)) == "bad_map")
	check("non-integer / missing seq is refused", select(2, B.Cast(box, 1, "SkyCarnival_B1", 2, 1.5, eligible)) == "bad_seq")

	------------------------------------------------------------------ eligibility at resolution
	box = B.NewBox(3)
	B.Cast(box, 1, "SkyCarnival_B1", 3, 1, eligible)
	B.Cast(box, 2, "VolcanoVault_B1", 3, 1, eligible)
	B.Cast(box, 3, "VolcanoVault_B1", 3, 1, eligible)
	local _, c1 = B.Tally(box, { [1] = true }, maps)
	check("only queued, connected voters are counted (player 2 / 3 not queued yet)", c1 == 1)
	local w2, _, c2 = B.Resolve(box, { [1] = true, [3] = true }, maps, 1)
	check("a party member who queued later is counted at resolution", c2 == 2 and maps[w2] == "SkyCarnival_B1")
	box = B.NewBox(4)
	B.Cast(box, 1, "SkyCarnival_B1", 4, 1, eligible)
	B.Cast(box, 2, "VolcanoVault_B1", 4, 1, eligible)
	B.Remove(box, 2)
	check("leaving mid-vote removes the ballot", B.Tally(box, { [1] = true, [2] = true }, maps)[3] == 0)
	check("reconnect: a fresh client (seq 1) can vote again", B.Cast(box, 2, "NeonFoundry_A4", 4, 1, eligible))
	local shrunk = B.Tally(box, { [1] = true, [2] = true }, { "NeonFoundry_A4", "VolcanoVault_B1" })
	check("a ballot for a map dropped before resolution counts for nothing", shrunk[1] == 1 and shrunk[2] == 0)
	local choices = B.Choices(box, { [1] = true, [2] = true }, maps)
	check("snapshot choices show each connected voter's pick", choices["1"] == 2 and choices["2"] == 1)
	local a = B.NewBox(5)
	local b = B.NewBox(5)
	for _, bx in ipairs({ a, b }) do
		B.Cast(bx, 7, "SkyCarnival_B1", 5, 1, eligible)
		B.Cast(bx, 8, "NeonFoundry_A4", 5, 1, eligible)
	end
	check("same ballots -> same winner (deterministic)", B.Resolve(a, { [7] = true, [8] = true }, maps, 2) == B.Resolve(b, { [7] = true, [8] = true }, maps, 2))

	------------------------------------------------------------------ destinations (Visit Hub / Practice)
	local built = { OrbitalGarage = true, BalloonTerminal = true }
	local allowed = { OrbitalGarage = true }
	local function decide(hubId, mode, extra)
		local ctx = { built = built, allowed = allowed, current = "OrbitalGarage", lastAt = nil, racing = false, inTrial = false }
		for k, v in pairs(extra or {}) do
			ctx[k] = v
		end
		return H.Decide({ hubId = hubId, mode = mode, now = 100 }, ctx)
	end
	check("Visit a built, allowed hub -> accepted and moves you", decide("OrbitalGarage", "Visit").ok and decide("OrbitalGarage", "Visit").move)
	check("Practice -> accepted with the practice mode", decide("OrbitalGarage", "Practice").mode == "Practice")
	check("a hub that failed to load -> unavailable", decide("DryDock", "Visit").reason == "unavailable")
	check("a gated hub for an ordinary player -> gated", decide("BalloonTerminal", "Visit").reason == "gated")
	check("rapid destination changes are throttled", decide("OrbitalGarage", "Visit", { lastAt = 99.5 }).reason == "too_fast" and decide("OrbitalGarage", "Visit", { lastAt = 98 }).ok)
	local racing = decide("OrbitalGarage", "Visit", { racing = true })
	check("while racing: the hub becomes your return hub, no move (race undisturbed)", racing.ok and racing.reason == "after_race" and racing.move == false)
	check("from a Time Trial: accepted, the trial ends", decide("OrbitalGarage", "Practice", { inTrial = true }).reason == "left_trial")
	check("a bad mode is refused", decide("OrbitalGarage", "Teleport").ok == false)
	local back, fell = H.ReturnHub("BalloonTerminal", { OrbitalGarage = true }, "OrbitalGarage")
	check("after results: a missing chosen hub -> Orbital Garage (fellBack)", back == "OrbitalGarage" and fell == true)
	check("after results: your chosen hub when it exists", H.ReturnHub("BalloonTerminal", built, "OrbitalGarage") == "BalloonTerminal")

	------------------------------------------------------------------ card states
	local MS, R = m.MapSelectPure, m.MapRegistry
	if MS and R then
		local snap = { ballot = { epoch = 1, maps = maps, counts = { 0, 2, 1 }, choices = { ["5"] = 2 } } }
		local sky = MS.CardState(R.RawMap("SkyCarnival_B1"), { snap = snap, myUserId = 5, myHub = "None", features = {}, racing = false })
		check("card: name, difficulty, one-line description from the registry", sky.card.name == "Sky Carnival" and sky.card.difficulty ~= "" and sky.card.blurb ~= "")
		check("card: your ballot and the vote count", sky.voted and sky.votes == 2 and sky.voteEnabled)
		local here = MS.CardState(R.RawMap("NeonFoundry_A4"), { snap = snap, myUserId = 5, myHub = "OrbitalGarage", features = {}, racing = false })
		check("card: Visit is disabled with a reason when you're already there", not here.visitEnabled and here.visitText == "YOU'RE HERE")
		local race = MS.CardState(R.RawMap("NeonFoundry_A4"), { snap = snap, myUserId = 5, myHub = "None", features = {}, racing = true })
		check("card: while racing Visit says AFTER RACE and Practice is disabled", race.visitText == "AFTER RACE" and not race.practiceEnabled)
		local missing = MS.CardState(R.RawMap("VolcanoVault_B1"), { snap = { ballot = { epoch = 1, maps = { "NeonFoundry_A4" }, counts = { 0 }, choices = {} } }, myUserId = 5, myHub = "x", features = {}, racing = false })
		check("card: a map the server dropped cannot be voted for (and says why)", not missing.voteEnabled and missing.note ~= nil)
	end
	return results
end

return Spec
