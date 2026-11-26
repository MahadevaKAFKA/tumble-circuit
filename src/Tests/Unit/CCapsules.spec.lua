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
	local d = profile(1350)
	local r = CS.OpenOn(d, "req-0001", snap(d), pools, function()
		return 0.01
	end, 100)
	check("open: debits exactly the Skin case's 650, grants a Common, records history + pity", r and d.coins == 700 and r.tier == "Common" and #d.capsule.history == 1 and d.capsule.epicMisses == 1 and d.capsule.legendaryMisses == 1)
	local replay = CS.OpenOn(d, "req-0001", snap(d), pools, function()
		return 0.99
	end, 101)
	check("retry with the same request id: same result, no second charge", replay and replay.replay and replay.id == r.id and d.coins == 700 and #d.capsule.history == 1)
	local stale, why = CS.OpenOn(d, "req-0002", { version = O.Version, epic = 0, legendary = 0 }, pools, function()
		return 0.5
	end, 102)
	check("stale odds snapshot refused (nothing spent)", stale == nil and string.find(why, "odds") ~= nil and d.coins == 700)
	local poor = profile(649)
	local none, why2 = CS.OpenOn(poor, "req-0003", snap(poor), pools, function()
		return 0.5
	end, 103)
	check("not enough Coins: refused, wallet unchanged (never negative)", none == nil and poor.coins == 649 and string.find(why2, "650") ~= nil)
	local two = profile(1300)
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
		local dd = profile(1300)
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
	local hist = profile(650 * 25)
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
	------------------------------------------------------------------ tiered cases (2026-11-26 economy)
	local function boxPools(box)
		return O.PoolsFor(box, C.ItemsOfRarity)
	end
	check("four cases: Starter (basic) / Skin / Trail (specialist) / Apex (high tier)", #O.Boxes == 4 and O.Box("Starter").Tier == "BASIC" and O.Box("Marble").Kind == "Marble" and O.Box("Apex").Mixed and O.Box("nope").Id == "Marble")
	check("prices rise with the tier: basic < specialist < high tier", O.Box("Starter").Cost < O.Box("Trail").Cost and O.Box("Trail").Cost <= O.Box("Marble").Cost and O.Box("Marble").Cost < O.Box("Apex").Cost)
	local boxesOk, boxDetail = true, nil
	for _, box in ipairs(O.Boxes) do
		local bp = boxPools(box)
		local kinds = {}
		for _, k in ipairs(box.Kinds) do
			kinds[k] = true
		end
		for _, counters in ipairs({ { 0, 0 }, { 14, 0 }, { 0, 59 } }) do
			local total, kindOk = 0, true
			for _, entry in ipairs(O.ItemOdds(bp, counters[1], counters[2])) do
				total = total + entry.p
				local item = C.Get(entry.id)
				kindOk = kindOk and kinds[item.Kind] and not item.Exclusive and (not box.Rarities or box.Rarities[item.Rarity])
			end
			if math.abs(total - 1) > 1e-9 or not kindOk then
				boxesOk, boxDetail = false, box.Id .. " " .. counters[1] .. "/" .. counters[2] .. " sum " .. total
			end
		end
	end
	check("every case's item odds sum to 100% and hold only its kinds and tiers (base and both guarantees)", boxesOk, boxDetail)
	local st = O.EffectiveTiers(boxPools(O.Box("Starter")), 0, 0)
	check("Starter case: Common + Rare only, rescaled (55/30 -> 64.7/35.3)", math.abs(st.Common - 0.55 / 0.85) < 1e-9 and (st.Epic or 0) == 0)
	local ap = O.EffectiveTiers(boxPools(O.Box("Apex")), 0, 0)
	check("Apex case: Epic or better on every open (Epic 73.3 / Legendary 23.3 / Mythic 3.3)", (ap.Common or 0) == 0 and (ap.Rare or 0) == 0 and math.abs(ap.Epic - 0.11 / 0.15) < 1e-9 and math.abs(ap.Mythic - 0.005 / 0.15) < 1e-9)
	local stl = O.EffectiveTiers(boxPools(O.Box("Starter")), 14, 0)
	check("a guarantee for a tier the case can't drop gives its best tier (Starter: Rare)", stl.Rare == 1)
	-- per-case counters: opening one case never moves another case's guarantee
	local pc = profile(5000)
	pc.capsule.epicMisses = 7
	local function snapFor(dd, boxId)
		local e, l = O.Counters(dd.capsule, boxId)
		return { version = O.Version, epic = e, legendary = l, cost = O.Box(boxId).Cost }
	end
	local tr = CS.OpenOn(pc, "box-trail", snapFor(pc, "Trail"), boxPools(O.Box("Trail")), function()
		return 0.3
	end, 5, O.Box("Trail"))
	local te, tl = O.Counters(pc.capsule, "Trail")
	check("Trail case: charges 550, grants a Trail, moves only its own counters", tr and pc.coins == 4450 and C.Get(tr.id).Kind == "Trail" and pc.capsule.history[1].box == "Trail" and te == 1 and tl == 1 and pc.capsule.epicMisses == 7)
	local stale2, whyStale = CS.OpenOn(pc, "box-skin", { version = O.Version, epic = 0, legendary = 0, cost = 650 }, boxPools(O.Box("Marble")), function()
		return 0.3
	end, 6, O.Box("Marble"))
	check("the Skin case keeps its own (old shared) counters: a snapshot with another case's counters is refused", stale2 == nil and string.find(whyStale, "odds") ~= nil and pc.coins == 4450)
	local wrongPrice, whyPrice = CS.OpenOn(pc, "box-price", { version = O.Version, epic = 7, legendary = 0, cost = 600 }, boxPools(O.Box("Marble")), function()
		return 0.3
	end, 7, O.Box("Marble"))
	check("price mismatch: the price you saw isn't the server's -> refused, nothing spent", wrongPrice == nil and string.find(whyPrice, "price") ~= nil and pc.coins == 4450)
	local poorS = profile(249)
	local ne, whyE = CS.OpenOn(poorS, "box-starter", snapFor(poorS, "Starter"), boxPools(O.Box("Starter")), function()
		return 0.3
	end, 8, O.Box("Starter"))
	check("Starter case: 250 Coins needed, refused at 249", ne == nil and string.find(whyE, "250") ~= nil and poorS.coins == 249)
	local migrated6 = Schema.Migrate({ schemaVersion = 5, coins = 777, capsule = { epicMisses = 9, legendaryMisses = 30, pity = { Apex = { e = 2, l = 70 }, Bogus = { e = 1, l = 1 } }, history = { { id = "tangerine", tier = "Common", box = "Emote" } } } })
	local ae, al = O.Counters(migrated6.capsule, "Apex")
	check("v5 -> v6+: Coins kept, the old shared counters become the Skin case's, bad entries clamped / dropped", migrated6.schemaVersion == m.PlayerDataSchema.Version and migrated6.coins == 777 and migrated6.capsule.epicMisses == 9 and ae == 2 and al == O.LegendaryPityAfter and migrated6.capsule.pity.Bogus == nil)
	check("old history lines from removed v2 cases keep their name", migrated6.capsule.history[1].box == "Emote" and O.BoxName("Emote") == "EMOTE CAPSULE")

	local Lab = m.LabPure
	local RV = m.RevealPure
	if Lab and RV then
		-- the racing-spool reveal (2026-11-26): pure choreography + masks
		local T = RV.Times
		check("reveal timeline: queue 0.35, chase cut 0.75, rail 1.15, cross 2.0, unmask 2.05, done 2.5", T.Queue == 0.35 and T.Rail == 1.15 and T.Unmask == 2.05 and T.Done == 2.5)
		local lineupOk, crossOk, smoothOk = true, true, true
		for seed = 1, 40 do
			local lineup = RV.Lineup("cobalt", function()
				return "tangerine"
			end, lcg(seed), 6)
			local ranks, winners = {}, 0
			for i, id in ipairs(lineup.ids) do
				ranks[lineup.rank[i]] = true
				if i == lineup.winnerIndex then
					winners = winners + (id == "cobalt" and 1 or 0)
				end
			end
			lineupOk = lineupOk and winners == 1 and #lineup.ids == 6 and ranks[0] and ranks[5]
			for i = 1, 6 do
				local s = RV.Progress(T.Cross, lineup.queuePos[i], lineup.rank[i])
				if i == lineup.winnerIndex then
					crossOk = crossOk and math.abs(s - 1) < 1e-9
				else
					crossOk = crossOk and s < 0.9
				end
				local prev = RV.Progress(0, lineup.queuePos[i], lineup.rank[i])
				for f = 1, 150 do
					local cur = RV.Progress(f / 60, lineup.queuePos[i], lineup.rank[i])
					smoothOk = smoothOk and math.abs(cur - prev) < 0.06
					prev = cur
				end
			end
		end
		check("reveal lineup: the confirmed winner appears exactly once, finishing order is a full ranking", lineupOk)
		check("the confirmed winner is exactly on the reveal line at 2.0 s and clearly first", crossOk)
		check("every entrant moves continuously (no jumps across camera cuts)", smoothOk)
		-- masks: same outline family = same silhouette at any rarity; names/colours never used
		local byPattern, sharedOk = {}, true
		for _, item in ipairs(C.ByKind.Marble) do
			local mask = RV.Mask(item)
			local pattern = item.Look and item.Look.pattern or "None"
			byPattern[pattern] = byPattern[pattern] or mask
			sharedOk = sharedOk and byPattern[pattern] == mask and not string.find(mask, item.Name, 1, true)
		end
		check("marble masks come from the outline family only (same shape -> same mask across rarities)", sharedOk)
		local t1, t2 = RV.Mask(C.Get("trail_ember")), RV.Mask(C.Get("trail_starlight"))
		check("trails with the same profile share one neutral trace (Ember = Starlight: Twin)", t1 == t2 and t1 == "Trail:Twin" and RV.Mask(C.Get("trail_dust")) ~= t1)
		check("each category has a distinct mask (marble / trail / burst / emote)", RV.Mask(C.Get("cobalt")) ~= RV.Mask(C.Get("trail_dust")) and RV.Mask(C.Get("burst_confetti")) == "Burst" and RV.Mask(C.Get("emote_gg")) == "Emote")
		-- fillers are independent draws from the shown odds, from the case's own pool
		local rng, counts, n = lcg(99), {}, 20000
		local poolOk = true
		for _ = 1, n do
			local id = Lab.Filler("Apex", 0, 0, rng)
			local item = C.Get(id)
			poolOk = poolOk and item and (item.Rarity == "Epic" or item.Rarity == "Legendary" or item.Rarity == "Mythic")
			counts[item.Rarity] = (counts[item.Rarity] or 0) + 1
		end
		check("reveal fillers: only the case's own pool, distributed like the shown odds", poolOk and math.abs(counts.Epic / n - 0.11 / 0.15) < 0.02)
		-- saved result recovery
		local seenData = profile(1300)
		CS.OpenOn(seenData, "seen-001", snap(seenData), pools, function()
			return 0.4
		end, 1)
		check("an open is saved as not yet seen until the reveal is shown", seenData.capsule.history[1].seen == false and Lab.Unseen(seenData.capsule.history).req == "seen-001")
		local first = CS.MarkSeen(seenData, "seen-001")
		local again = CS.MarkSeen(seenData, "seen-001")
		check("marking a reveal seen is idempotent and grants / charges nothing", first and not again and seenData.coins == 650 and Lab.Unseen(seenData.capsule.history) == nil)
		local migratedSeen = Schema.Migrate({ schemaVersion = 5, capsule = { history = { { id = "tangerine", tier = "Common", req = "abc12345", seen = false } } } })
		check("an unseen result survives a save + reload (returns after a disconnect)", migratedSeen.capsule.history[1].seen == false)
	end
	if Lab then
		local tiers, items, branch = Lab.OddsLines(0, 0)
		check("Capsule Lab shows 5 tier lines and all 35 item lines from the same odds", #tiers == 5 and #items == 35 and branch == "Base" and string.find(tiers[5], "0.500%%") ~= nil)
		local _, _, b2 = Lab.OddsLines(14, 0)
		check("Capsule Lab follows the server's counters (pity branch shown)", b2 == "EpicPity")
	end
	return results
end

return Spec
