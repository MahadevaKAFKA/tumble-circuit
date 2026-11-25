--[[
	CCapsules.spec — Phase C: capsule odds (one pure function for roll and display), pity
	boundaries, 100k base-draw simulation, the atomic free-capsule transaction, Shard Shop
	prices, the free season, profile v4. Earned-only: no Robux anywhere.
]]

local Spec = {}

local function lcg(seed)
	local state = seed
	return function()
		state = (state * 1103515245 + 12345) % 2147483648
		return state / 2147483648
	end
end

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
	local O, C, Schema, SC = m.CapsuleOdds, m.Catalog, m.PlayerDataSchema, m.SeasonConfig
	local pools = {}
	for _, tier in ipairs(O.Tiers) do
		pools[tier] = C.MarblesOfRarity(tier)
	end
	local function sum(t)
		local s = 0
		for _, tier in ipairs(O.Tiers) do
			s = s + (t[tier] or 0)
		end
		return s
	end
	check("base 55/30/11/3.5/0.5 sums to 100%", math.abs(sum(O.Base) - 1) < 1e-9 and O.Base.Common == 0.55 and O.Base.Mythic == 0.005)
	check("pity tables sum to 100% (85/13/2 and 95/5)", math.abs(sum(O.EpicPity) - 1) < 1e-9 and math.abs(sum(O.LegendaryPity) - 1) < 1e-9)
	local _, b13 = O.TierTable(13, 0)
	local _, b14 = O.TierTable(14, 0)
	local _, b58 = O.TierTable(0, 58)
	local _, b59 = O.TierTable(0, 59)
	local _, both = O.TierTable(14, 59)
	check("Epic+ pity exactly on the 15th open (13 misses: base, 14: pity)", b13 == "Base" and b14 == "EpicPity")
	check("Legendary+ pity exactly on the 60th open (58: base, 59: pity)", b58 == "Base" and b59 == "LegendaryPity")
	check("Legendary pity wins when both apply", both == "LegendaryPity")
	local e, l = O.After("Rare", 5, 20)
	local e2, l2 = O.After("Epic", 5, 20)
	local e3, l3 = O.After("Mythic", 14, 59)
	check("counters: Rare +1/+1, Epic resets Epic+ only, Mythic resets both", e == 6 and l == 21 and e2 == 0 and l2 == 21 and e3 == 0 and l3 == 0)
	local epicIn, legIn = O.Within(14, 59)
	check("'within N' text values (1 = next open)", epicIn == 1 and legIn == 1 and select(1, O.Within(0, 0)) == 15 and select(2, O.Within(0, 0)) == 60)
	for _, counters in ipairs({ { 0, 0 }, { 14, 0 }, { 0, 59 } }) do
		local total = 0
		for _, entry in ipairs(O.ItemOdds(pools, counters[1], counters[2])) do
			total = total + entry.p
		end
		check(string.format("item odds sum to 100%% (counters %d/%d)", counters[1], counters[2]), math.abs(total - 1) < 1e-9)
	end
	local mythicEach = O.ItemOdds(pools, 0, 0)
	local each
	for _, entry in ipairs(mythicEach) do
		if entry.tier == "Mythic" then
			each = entry.p
		end
	end
	check("Mythic item odds = 0.5% / 2 = 0.25%, shown with enough decimals", math.abs(each - 0.0025) < 1e-12 and O.Percent(each) == "0.250%" and O.Percent(0.00001) ~= "0%")

	-- 100,000 base draws (counters held at 0: base table only; the pity-mixed long run differs)
	local rng = lcg(20261125)
	local counts, perItem = {}, {}
	local N = 100000
	for _ = 1, N do
		local tier, id = O.RollWith(rng(), rng(), pools, 0, 0)
		counts[tier] = (counts[tier] or 0) + 1
		perItem[id] = (perItem[id] or 0) + 1
	end
	local tolerance = { Common = 0.006, Rare = 0.006, Epic = 0.004, Legendary = 0.0025, Mythic = 0.0012 }
	local within, report = true, {}
	for _, tier in ipairs(O.Tiers) do
		local f = (counts[tier] or 0) / N
		report[#report + 1] = string.format("%s %.3f%%", tier, f * 100)
		if math.abs(f - O.Base[tier]) > tolerance[tier] then
			within = false
		end
	end
	results.info[#results.info + 1] = "100k base draws observed: " .. table.concat(report, ", ")
	check("100k base draws match 55/30/11/3.5/0.5 within tolerance", within, table.concat(report, ", "))
	local commonMin, commonMax = math.huge, 0
	for _, id in ipairs(pools.Common) do
		commonMin = math.min(commonMin, perItem[id] or 0)
		commonMax = math.max(commonMax, perItem[id] or 0)
	end
	local expected = N * 0.55 / 12
	check("items inside a tier are uniform (each Common within 5% of expected)", commonMin > expected * 0.95 and commonMax < expected * 1.05, string.format("%d..%d vs %.0f", commonMin, commonMax, expected))
	-- pity branches on their own
	local pityOk = true
	local r2 = lcg(7)
	for _ = 1, 5000 do
		local t1 = O.RollWith(r2(), r2(), pools, 14, 0)
		local t2 = O.RollWith(r2(), r2(), pools, 0, 59)
		if O.Rank[t1] < O.Rank.Epic or O.Rank[t2] < O.Rank.Legendary then
			pityOk = false
		end
	end
	check("pity branches never give less than promised (5k draws each)", pityOk)
	-- sequential run with real counter updates
	local r3 = lcg(99)
	local em, lm, worstE, worstL = 0, 0, 0, 0
	for _ = 1, 20000 do
		local tier = O.RollWith(r3(), r3(), pools, em, lm)
		em, lm = O.After(tier, em, lm)
		worstE, worstL = math.max(worstE, em), math.max(worstL, lm)
	end
	check("20k sequential opens: never 15 in a row without Epic+, never 60 without Legendary+", worstE <= 14 and worstL <= 59, worstE .. "/" .. worstL)
	local a, b = lcg(5), lcg(5)
	local same = true
	for _ = 1, 50 do
		local x1 = select(2, O.RollWith(a(), a(), pools, 0, 0))
		local x2 = select(2, O.RollWith(b(), b(), pools, 0, 0))
		same = same and x1 == x2
	end
	check("reproducible on a fixed seed", same)

	------------------------------------------------------------------ atomic transaction
	local CS = m.CapsuleService
	local function profile(coins)
		local d = Schema.Defaults()
		d.coins = coins
		return d
	end
	local function snap(d)
		return { version = O.Version, epic = d.capsule.epicMisses, legendary = d.capsule.legendaryMisses }
	end
	local d = profile(1300)
	local r = CS.OpenOn(d, "req-0001", snap(d), pools, function()
		return 0.01
	end, 100)
	check("open: debits exactly 600, grants a Common, records history + pity", r and d.coins == 700 and r.tier == "Common" and #d.capsule.history == 1 and d.capsule.epicMisses == 1 and d.capsule.legendaryMisses == 1)
	local replay = CS.OpenOn(d, "req-0001", snap(d), pools, function()
		return 0.99
	end, 101)
	check("retry with the same request id: same result, no second charge", replay and replay.replay and replay.id == r.id and d.coins == 700 and #d.capsule.history == 1)
	local stale, why = CS.OpenOn(d, "req-0002", { version = O.Version, epic = 0, legendary = 0 }, pools, function()
		return 0.5
	end, 102)
	check("stale odds snapshot refused (nothing spent)", stale == nil and string.find(why, "odds") ~= nil and d.coins == 700)
	local poor = profile(599)
	local none, why2 = CS.OpenOn(poor, "req-0003", snap(poor), pools, function()
		return 0.5
	end, 103)
	check("not enough Coins: refused, wallet unchanged (never negative)", none == nil and poor.coins == 599 and string.find(why2, "600") ~= nil)
	local two = profile(1200)
	local o1 = CS.OpenOn(two, "req-a", snap(two), pools, function()
		return 0.5
	end, 1)
	local o2 = CS.OpenOn(two, "req-b", snap(two), pools, function()
		return 0.5
	end, 1)
	local o3 = CS.OpenOn(two, "req-c", snap(two), pools, function()
		return 0.5
	end, 1)
	check("two opens back to back: two debits, two results; a third with 0 Coins refused", o1 and o2 and not o3 and two.coins == 0 and #two.capsule.history == 2)
	local u = { Common = 0.01, Rare = 0.6, Epic = 0.9, Legendary = 0.97, Mythic = 0.999 }
	local dupOk = true
	for tier, uu in pairs(u) do
		local dd = profile(1200)
		dd.capsule.epicMisses, dd.capsule.legendaryMisses = 0, 0
		table.insert(dd.cosmetics.owned, pools[tier][1])
		local before = dd.shards
		local res = CS.OpenOn(dd, "dup-" .. tier, snap(dd), pools, (function()
			local seq, i = { uu, 0 }, 0
			return function()
				i = i + 1
				return seq[i]
			end
		end)(), 1)
		if not (res and res.dup and res.tier == tier and dd.shards - before == O.DuplicateShards[tier]) then
			dupOk = false
		end
	end
	check("duplicates give exactly 5/20/65/200/600 Shards per tier", dupOk)
	local hist = profile(600 * 25)
	for i = 1, 25 do
		CS.OpenOn(hist, "h-" .. i .. "-xxxx", snap(hist), pools, function()
			return 0.2
		end, i)
	end
	check("history keeps the last 20, newest first", #hist.capsule.history == 20 and hist.capsule.history[1].req == "h-25-xxxx" and #hist.capsule.requests == 20)
	-- shard shop
	local shopOk = true
	for _, tier in ipairs(O.Tiers) do
		local dd = profile(0)
		dd.shards = O.ShardPrice[tier] + 3
		local id = pools[tier][#pools[tier]]
		local price = CS.ShardBuyOn(dd, id)
		local again = CS.ShardBuyOn(dd, id)
		if not (price == O.ShardPrice[tier] and dd.shards == 3 and again == nil) then
			shopOk = false
		end
	end
	check("Shard Shop: exact 60/180/600/1900/6000, item granted, can't buy it twice", shopOk)
	local broke = profile(0)
	broke.shards = 59
	check("Shard Shop: not enough Shards refused, nothing changes", CS.ShardBuyOn(broke, pools.Common[2]) == nil and broke.shards == 59)

	------------------------------------------------------------------ season
	local s1 = SC.Seasons[1]
	check("season 1 is 28 days, 30 levels", s1.endsAt - s1.startsAt == 28 * 86400 and SC.Levels == 30)
	check("current season only inside its dates", SC.Current(s1.startsAt) == s1 and SC.Current(s1.endsAt) == nil and SC.Current(s1.startsAt - 1) == nil)
	local rec = SC.Default()
	SC.AddXp(rec, 650, s1.startsAt + 10)
	local okClaim = SC.Claim(rec, 2, s1.startsAt + 20)
	local twice = SC.Claim(rec, 2, s1.startsAt + 21)
	local tooHigh = SC.Claim(rec, 3, s1.startsAt + 22)
	check("season: 650 XP = level 2; claim once; level 3 locked", rec.id == "S1" and SC.LevelForXp(rec.xp) == 2 and okClaim and twice == nil and tooHigh == nil)
	SC.Refresh(rec, s1.endsAt + 10)
	check("rollover: season XP and claims reset (no season -> nothing claimable)", rec.xp == 0 and #rec.claimed == 0 and SC.Claim(rec, 1, s1.endsAt + 10) == nil)
	local SS = m.SeasonService
	local dd = profile(0)
	table.insert(dd.cosmetics.owned, "tangerine")
	local text = SS.ApplyReward(dd, { kind = "Item", id = "tangerine" })
	check("season item you already own -> its duplicate Shards (nothing removed)", dd.shards == O.DuplicateShards.Common and string.find(text, "already") ~= nil)
	local all = true
	for level = 1, SC.Levels do
		local reward = SC.Reward(level)
		all = all and (reward.kind ~= "Item" or C.Get(reward.id) ~= nil)
	end
	check("all 30 free rewards are real (items exist)", all)

	------------------------------------------------------------------ profile v4 / UI
	local migrated = Schema.Migrate({ schemaVersion = 3, coins = 70 })
	check("v3 -> v4: Coins kept, shards 0, capsule + season defaults", migrated.schemaVersion == Schema.Version and migrated.coins == 70 and migrated.shards == 0 and migrated.capsule.epicMisses == 0 and migrated.season.xp == 0)
	local hostile = Schema.Migrate({ schemaVersion = 4, shards = -5, capsule = { epicMisses = 99, legendaryMisses = -3, history = { { id = "nope" }, { id = "cobalt", tier = "Mythic", shards = 1e9 } } }, season = { id = "S1", xp = 1e9, claimed = { 1, 1, 99 } } })
	check("v4 sanitize: shards >= 0, pity counters clamped, history tier from the catalog", hostile.shards == 0 and hostile.capsule.epicMisses == O.EpicPityAfter and hostile.capsule.legendaryMisses == 0 and #hostile.capsule.history == 1 and hostile.capsule.history[1].tier == "Common")
	check("v4 sanitize: season XP capped, claims unique and in range", hostile.season.xp == SC.Levels * SC.XpPerLevel and #hostile.season.claimed == 1)
	local Lab = m.LabPure
	if Lab then
		local tiers, items, branch = Lab.OddsLines(0, 0)
		check("Capsule Lab shows 5 tier lines and all 35 item lines from the same odds", #tiers == 5 and #items == 35 and branch == "Base" and string.find(tiers[5], "0.500%%") ~= nil)
		local _, _, b2 = Lab.OddsLines(14, 0)
		check("Capsule Lab follows the server's counters (pity branch shown)", b2 == "EpicPity")
	end
	return results
end

return Spec
