--[[
	Ranked.spec (brief 3 E, 2026-11-26) — the rating model and its simulations: equal fields,
	mixed skill, ties, small vs large fields, placement stability, repeated races, idempotent
	apply by match id, eligibility (bots never count, minimum humans), DNF rule, season reset,
	the opt-in decision and the card text. Pure modules only.
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
	local R = m.RankRules
	if not R then
		check("RankRules loads", false)
		return results
	end
	local function field(n, rating, placements)
		local list = {}
		for i = 1, n do
			list[i] = { userId = i, rating = rating or 1000, placements = placements or 10, place = i, finished = true }
		end
		return list
	end
	-- equal field: zero-sum, winner up, last down, symmetric
	local d4 = R.Deltas(field(4))
	local sum = 0
	for _, v in pairs(d4) do
		sum = sum + v
	end
	check("equal 4-player field: winner gains, last loses, the field is ~zero-sum", d4[1] > 0 and d4[4] < 0 and d4[1] == -d4[4] and math.abs(sum) <= 2, string.format("%d %d %d %d", d4[1], d4[2], d4[3], d4[4]))
	-- second place in small vs large fields means the same relative result (normalized)
	local d12 = R.Deltas(field(12))
	local second4 = d4[2]
	local relative12 = d12[math.floor(12 * 2 / 4 + 0.5) - 1] -- the same relative position
	check("normalized by opponents: the winner of 4 and the winner of 12 gain the same", d4[1] == d12[1], string.format("%d vs %d", d4[1], d12[1]))
	check("2nd of 4 is a small gain; ~2nd-of-4 position in 12 is close to it", second4 > 0 and math.abs(second4 - relative12) <= 4, string.format("%d vs %d", second4, relative12))
	-- mixed skill: a favourite who wins gains little, an underdog who wins gains a lot
	local mixed = field(4)
	mixed[1].rating, mixed[2].rating = 1400, 900
	local fav = R.Deltas(mixed)[1]
	mixed[1].place, mixed[2].place = 2, 1
	local dog = R.Deltas(mixed)[2]
	check("mixed skill: an expected win gains less than an upset", fav < dog and fav > 0, string.format("fav +%d, underdog +%d", fav, dog))
	-- ties (same place / both DNF) are 0.5
	local tie = field(4)
	tie[3].finished, tie[4].finished = false, false
	local dt = R.Deltas(tie)
	check("two DNFs tie with each other and rank behind every finisher", dt[3] == dt[4] and dt[3] < 0 and dt[2] > dt[3])
	-- deterministic regardless of roster order
	local shuffled = field(6)
	local a = R.Deltas(shuffled)
	local reversed = {}
	for i = #shuffled, 1, -1 do
		reversed[#reversed + 1] = shuffled[i]
	end
	local b = R.Deltas(reversed)
	local same = true
	for k, v in pairs(a) do
		same = same and b[k] == v
	end
	check("deterministic: the roster order never changes a delta", same)
	-- provisional K moves faster than established
	local prov = R.Deltas(field(4, 1000, 0))
	check("placement races move faster than established ones", prov[1] > d4[1])
	-- repeated races: a consistently better player separates, ratings stay bounded
	local players = {}
	for i = 1, 6 do
		players[i] = { userId = i, rank = R.Default(), skill = i }
	end
	local seed = 12345
	local function rnd()
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	for race = 1, 200 do
		local roster = {}
		for _, p in ipairs(players) do
			roster[#roster + 1] = { p = p, score = p.skill + rnd() * 4 }
		end
		table.sort(roster, function(x, y)
			return x.score > y.score
		end)
		local snap = {}
		for place, r in ipairs(roster) do
			snap[#snap + 1] = { userId = r.p.userId, rating = r.p.rank.rating, placements = r.p.rank.placements, place = place, finished = true }
		end
		local deltas = R.Deltas(snap)
		for _, r in ipairs(roster) do
			R.Apply(r.p.rank, "m" .. race, deltas[r.p.userId], nil, #roster)
		end
	end
	local best, worst = players[6].rank.rating, players[1].rank.rating
	results.info[#results.info + 1] = string.format("200 simulated 6-player races: ratings %d (best) ... %d (weakest)", best, worst)
	check("repeated races: the stronger player ends higher, and nobody runs away (bounded)", best > worst + 150 and best < 1600 and worst > 400, string.format("%d / %d", best, worst))
	local rTier = R.Tier(best, 200)
	check("tiers: a rated player has a named tier; fewer than 5 results = Provisional", rTier ~= "Provisional" and R.Tier(1000, 4) == "Provisional")
	-- idempotent apply
	local rank = R.Default()
	local ok1 = R.Apply(rank, "server:7", 12)
	local ok2 = R.Apply(rank, "server:7", 12)
	check("a duplicate match result never applies twice", ok1 and not ok2 and rank.rating == 1012 and rank.placements == 1)
	-- eligibility: bots are never in the roster; fewer than MinHumans = neutral
	local okE = R.Eligible({ { userId = 1 }, { userId = 2 }, { userId = 3 } }, true)
	local okF = R.Eligible({ { userId = 1 }, { userId = 2 }, { userId = 3 }, { userId = 4 } }, false)
	local okG = R.Eligible({ { userId = 1 }, { userId = 2 }, { userId = 3 }, { userId = 4 } }, true)
	check("3 humans or an unfinalized result = no rating change; 4 finalized humans = rated", not okE and not okF and okG)
	-- season rollover: disclosed soft reset, placements restart, history kept
	local old = R.Default()
	old.rating, old.placements, old.season = 1400, 30, "S0"
	R.Apply(old, "s1:first", 0)
	check("season rollover: halfway back to the start rating, placements restart", old.season == R.Season and old.rating == 1200 and old.placements == 1)
	-- sanitize
	local clean = R.Sanitize({ rating = 1 / 0, placements = -3, applied = { 5, "x" }, history = { { m = "a", d = 3, r = 1003 } } })
	check("sanitize drops garbage (infinite rating, negative counts, bad ids)", clean.rating == R.StartRating and clean.placements == 0 and #clean.applied == 1 and #clean.history == 1)
	-- the opt-in decision
	local RS = m.RankService
	if RS then
		local yes = RS.ShouldRank(true, { { optedIn = true }, { optedIn = true }, { optedIn = true }, { optedIn = true } })
		local no, why = RS.ShouldRank(true, { { optedIn = true }, { optedIn = true } })
		local mixedQ = RS.ShouldRank(true, { { optedIn = true }, { optedIn = true }, { optedIn = true }, { optedIn = false } })
		check("a round is ranked only with 4+ humans who ALL opted in; otherwise Casual with an honest note", yes and not no and not mixedQ and why:find("Casual", 1, true) ~= nil, why)
	end
	local RC = m.RankPure
	if RC then
		local lines = RC.Lines({ enabled = true, optIn = true, tier = "Provisional", placements = 2, placementRaces = 5, minHumans = 4, waitNote = "needs 4 ranked players (1 queued) - Casual races continue", last = { pending = true } })
		check("rank card: placement progress, the wait note and a pending (never invented) result", lines.title:find("2 / 5", 1, true) and lines.status:find("Casual", 1, true) and lines.last:find("pending", 1, true))
	end
	return results
end

return Spec
