--[[
	B1Rules.spec — map vote, Party Race grouping and Time Trial rules (pure modules).
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
	------------------------------------------------------------------ map vote
	local MV = m.MapVoteRules
	check("rotation: nothing raced -> world 1, then 2, 3, back to 1", MV.NextInRotation(0, 3) == 1 and MV.NextInRotation(1, 3) == 2 and MV.NextInRotation(3, 3) == 1)
	check("vote opens with >= 2 queued humans and > 1 world only", MV.ShouldOpen(2, 3) and not MV.ShouldOpen(1, 3) and not MV.ShouldOpen(5, 1))
	check("vote window is 8 s", MV.VoteSeconds == 8)
	local ids = { "A", "B", "C" }
	local v = MV.NewVote(ids, 2, 100)
	check("valid vote counts", MV.Cast(v, 1, 3, true, 101) and v.counts[3] == 1)
	local ok1, why1 = MV.Cast(v, 1, 1, true, 101)
	check("one vote per human (no changing)", not ok1 and why1 == "already_voted" and v.counts[1] == 0)
	local ok2, why2 = MV.Cast(v, 2, 1, false, 101)
	check("non-queued / bots cannot vote", not ok2 and why2 == "not_eligible")
	local ok3 = MV.Cast(v, 3, 4, true, 101)
	local ok4 = MV.Cast(v, 4, 1.5, true, 101)
	check("bad option refused (4, 1.5)", not ok3 and not ok4)
	local ok5, why5 = MV.Cast(v, 5, 1, true, 108.01)
	check("vote after the 8 s window refused", not ok5 and why5 == "closed")
	check("most votes wins", MV.Winner(v) == 3)
	local tie = MV.NewVote(ids, 2, 0)
	MV.Cast(tie, 1, 1, true, 1)
	MV.Cast(tie, 2, 3, true, 1)
	check("tie -> first tied world in rotation order from the candidate (B? no votes; C before A)", MV.Winner(tie) == 3)
	local none = MV.NewVote(ids, 2, 0)
	check("no votes -> rotation candidate", MV.Winner(none) == 2)
	MV.Remove(v, 1)
	check("a leaver's vote stops counting", v.counts[3] == 0 and MV.Winner(v) == 2)

	------------------------------------------------------------------ party
	local PR = m.PartyRules
	local members = { [1] = "p", [2] = "", [3] = "p", [4] = "q", [5] = "p", [6] = "p", [7] = "p", [8] = "solo" }
	local join = { 1, 2, 3, 4, 5, 6, 7, 8 }
	local groups = PR.Groups(members, join)
	check("party of 5 here is capped at 4 (join order)", groups.p and #groups.p == 4 and groups.p[4] == 6)
	check("a party with 1 member here is not a group", groups.q == nil and groups.solo == nil)
	local order = PR.GroupOrder({ 2, 5, 4, 1, 8, 3, 7, 6 }, members, join)
	local pos = {}
	for i, id in ipairs(order) do
		pos[id] = i
	end
	local same = #order == 8
	check("every racer still on the grid exactly once", same)
	check("party members on neighbouring slots, at the first member's place", pos[5] == 2 and pos[1] == 3 and pos[3] == 4 and pos[6] == 5)
	check("non-party racers keep their shuffled order", pos[2] == 1 and pos[4] < pos[8] and pos[8] < pos[7])

	------------------------------------------------------------------ time trial
	local TT = m.TimeTrialRules
	check("can start when idle in the hub", TT.CanStart({ running = false, inRound = false, state = "Intermission" }))
	check("not while in the race / on the grid / twice", not TT.CanStart({ inRound = true, state = "Racing" }) and not TT.CanStart({ state = "Countdown" }) and not TT.CanStart({ running = true, state = "Racing" }))
	check("best: faster only, never under 8 s or NaN", TT.IsBetter(40, 41) and not TT.IsBetter(42, 41) and TT.IsBetter(40, nil) and not TT.IsBetter(7.9, nil) and not TT.IsBetter(0 / 0, nil))
	local rec = TT.NewRecorder()
	for i = 0, 50 do
		TT.Record(rec, i * 0.05, Vector3.new(i * 1.04, 10, -i))
	end
	check("ghost sampled at 5 Hz (2.5 s -> 13 points)", rec.count == 13, rec.count)
	check("ghost positions rounded to 0.1 stud", rec.points[4] == 4.2)
	local ghost = TT.GhostPayload(rec, 2.5, "K")
	check("stored ghost must match the key", TT.ValidGhost(ghost, "K") and not TT.ValidGhost(ghost, "other") and not TT.ValidGhost({ v = 1, key = "K", points = { 1, 2 } }, "K"))
	local x, y = TT.GhostAt(ghost, 0.3)
	check("ghost playback interpolates between samples", math.abs(x - 6.25) < 0.01 and y == 10, x)
	check("ghost ends after its last sample", TT.GhostAt(ghost, 5) == nil and TT.GhostAt(ghost, -1) == nil)
	local big = TT.NewRecorder()
	for i = 0, 2000 do
		TT.Record(big, i * 0.2, Vector3.new(0, 0, 0))
	end
	check("ghost capped at 180 s worth of samples", big.count == TT.MaxSeconds * TT.GhostHz + 1, big.count)
	return results
end

return Spec
