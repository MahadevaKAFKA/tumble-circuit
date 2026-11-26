--[[
	RewardIdempotence.spec (A5, ADR-12) — level curve, Coin/XP payouts for places 1, 2, 3, 4, 8
	and DNF, AFK guard, personal bests only within the same configuration, the transparent bot-
	practice multiplier, and one award per raceId even across a save -> leave -> rejoin cycle.
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
	local PC, RR, Schema, PS = m.ProgressionConfig, m.RewardRules, m.PlayerDataSchema, m.ProfileStore

	-------------------------------------------------------------------- levels
	check("Lv2 costs 400 XP, each next level +80", PC.LevelCost(1) == 400 and PC.LevelCost(2) == 480 and PC.LevelCost(3) == 560 and PC.LevelCost(49) == 400 + 80 * 48 and PC.LevelCost(50) == nil)
	local l399 = PC.LevelForXp(399)
	local l400, into400, next400 = PC.LevelForXp(400)
	local l880 = PC.LevelForXp(880)
	check("level boundaries: 399 -> 1, 400 -> 2 (0/480), 880 -> 3", l399 == 1 and l400 == 2 and into400 == 0 and next400 == 480 and l880 == 3)
	local lmax, _, nmax = PC.LevelForXp(1e15)
	check("level capped at 50 with no next cost; huge XP does not overflow", lmax == 50 and nmax == 0)
	check("NaN / negative XP -> level 1", PC.LevelForXp(0 / 0) == 1 and PC.LevelForXp(-50) == 1)
	check("TotalXpForLevel matches LevelForXp", PC.LevelForXp(PC.TotalXpForLevel(17)) == 17 and PC.LevelForXp(PC.TotalXpForLevel(17) - 1) == 16)

	-------------------------------------------------------------------- shipped economy (2026-11-26)
	local shipped = PC.RaceCoins
	check("economy: races pay no Coins (Coins come only from quests)", shipped == false)
	local function rr(place, count, opts)
		opts = opts or {}
		return PC.RaceReward({ finished = opts.finished ~= false, place = place, count = count, active = opts.active ~= false, checkpoint = opts.checkpoint, progressFraction = opts.progress, personalBest = opts.pb, botPractice = opts.bot, botRacesToday = opts.today })
	end
	local zero = true
	for _, r in ipairs({ rr(1, 8), rr(8, 8), rr(5, 8, { finished = false, checkpoint = 2 }), rr(1, 8, { bot = true, today = 5 }) }) do
		zero = zero and r.coins == 0
		for _, l in ipairs(r.lines) do
			zero = zero and l.coins == 0
		end
	end
	check("1st, last, DNF and bot races: 0 Coins on every line; XP unchanged (1st = 160)", zero and rr(1, 8).xp == 160 and rr(5, 8, { finished = false, checkpoint = 2 }).xp == 20)
	local econ = Schema.Defaults()
	econ.coins = 1234 -- an existing balance
	RR.Apply(econ, "E:1", { finished = true, place = 1, count = 8, seconds = 90, active = true, checkpoint = 8 }, { worldId = "NeonFoundry_A4", layoutVersion = 2, seedClass = 1, mode = "Race", utcDay = 1, minPlausibleSeconds = 8 })
	check("a race keeps the existing Coin balance exactly and still pays XP / records", econ.coins == 1234 and econ.xp == 190 and econ.winCount == 1)
	-- the documented race-Coin model below is checked with the flag on (if ever re-enabled)
	PC.RaceCoins = true

	-------------------------------------------------------------------- payouts
	local function reward(place, count, opts)
		opts = opts or {}
		return PC.RaceReward({ finished = opts.finished ~= false, place = place, count = count, active = opts.active ~= false, checkpoint = opts.checkpoint, progressFraction = opts.progress, personalBest = opts.pb, botPractice = opts.bot, botRacesToday = opts.today })
	end
	local coins = {}
	for _, place in ipairs({ 1, 2, 3, 4, 8 }) do
		coins[place] = reward(place, 8).coins
	end
	check("Coins 1st/2nd/3rd = 55+125/100/80+20", coins[1] == 200 and coins[2] == 175 and coins[3] == 155, string.format("%d %d %d", coins[1], coins[2], coins[3]))
	check("Coins 4th = 55+60+20, 8th of 8 = 55+35+20", coins[4] == 135 and coins[8] == 110, coins[4] .. " " .. coins[8])
	check("rest interpolates linearly 60 -> 35 (6th of 8 = 48 placement)", PC.PlacementCoins(6, 8) == 48 and PC.PlacementCoins(4, 4) == 60 and PC.PlacementCoins(5, 5) == 35)
	local dnf = reward(5, 8, { finished = false, checkpoint = 2 })
	check("active DNF: 25 consolation INSTEAD of base/placement (+20 XP)", dnf.coins == 25 and dnf.xp == 20 and #dnf.lines == 1)
	local dnfNothing = reward(5, 8, { finished = false, checkpoint = 0, progress = 0.05 })
	check("DNF without reaching checkpoint 1 / 15%: no consolation, told why", dnfNothing.coins == 0 and dnfNothing.lines[1].label:find("checkpoint 1") ~= nil)
	local idle = reward(1, 8, { active = false })
	check("no input this race (AFK): 0 Coins / 0 XP even if the marble rolled to the finish", idle.coins == 0 and idle.xp == 0)
	check("XP: 1st 160, 4th 110, +30 for a personal best", reward(1, 8).xp == 160 and reward(4, 8).xp == 110 and reward(4, 8, { pb = true }).xp == 140)
	local sum = 0
	for _, l in ipairs(reward(2, 8, { pb = true }).lines) do
		sum = sum + l.coins
	end
	check("breakdown lines add up to the total (results screen shows every source)", sum == reward(2, 8, { pb = true }).coins)

	-------------------------------------------------------------------- bot practice
	local fullBot = reward(1, 8, { bot = true, today = 2 })
	local reducedBot = reward(1, 8, { bot = true, today = 3 })
	check("bot practice: races 1-3 of the day pay full Coins, with a visible note", fullBot.coins == 200 and fullBot.multiplierNote ~= nil)
	check("bot practice: race 4+ pays 60% Coins (rounded), XP full, shown as its own line", reducedBot.coins == 120 and reducedBot.xp == 160 and reducedBot.lines[#reducedBot.lines].coins == -80 and reducedBot.multiplierNote:find("60%%") ~= nil)

	-------------------------------------------------------------------- Apply / idempotence
	local ctx = { worldId = "NeonFoundry_A4", layoutVersion = 2, seedClass = 1, mode = "Race", utcDay = 20000, minPlausibleSeconds = 8 }
	local data = Schema.Defaults()
	local finish = { finished = true, place = 1, count = 8, seconds = 95.2, active = true, checkpoint = 8 }
	local n1 = RR.Apply(data, "srvA:1", finish, ctx)
	check("first award applies Coins/XP/records", n1 and data.coins == 200 and data.xp == 190 and data.raceCount == 1 and data.winCount == 1 and data.podiumCount == 1)
	local n1b, why = RR.Apply(data, "srvA:1", finish, ctx)
	check("duplicate finish callback for the same raceId pays nothing", n1b == nil and why == "duplicate" and data.coins == 200 and data.raceCount == 1)
	check("first valid time on a variation is a PB without a fake comparison", n1.pb.isNew and n1.pb.previous == nil and n1.pb.comparable == false)
	local n2 = RR.Apply(data, "srvA:2", { finished = true, place = 3, count = 8, seconds = 93.0, active = true }, ctx)
	check("faster time on the same configuration: PB with delta", n2.pb.isNew and math.abs(n2.pb.previous - 95.2) < 1e-9)
	local n3 = RR.Apply(data, "srvA:3", { finished = true, place = 2, count = 8, seconds = 99.0, active = true }, ctx)
	check("slower time: no PB, compared against the stored best", n3.pb.isNew == false and n3.pb.comparable == true)
	local otherSeed = {}
	for k, v in pairs(ctx) do
		otherSeed[k] = v
	end
	otherSeed.seedClass = 2
	local n4 = RR.Apply(data, "srvA:4", { finished = true, place = 2, count = 8, seconds = 120, active = true }, otherSeed)
	check("a different hazard variation never compares with another's PB", n4.pb.isNew and n4.pb.previous == nil)
	local n5 = RR.Apply(data, "srvA:5", { finished = true, place = 1, count = 8, seconds = 4, active = true }, ctx)
	check("implausibly fast times are never recorded as a best", n5.pb.isNew == false and n5.pb.seconds == nil)

	local levelData = Schema.Defaults()
	levelData.xp = 300
	local up = RR.Apply(levelData, "L:1", finish, ctx)
	check("level-up reported once", up.levelUp == true and up.level == 2 and levelData.level == 2)
	check("duplicate cannot re-trigger a level-up", RR.Apply(levelData, "L:1", finish, ctx) == nil and levelData.xp == 490)

	-- daily bot practice counter
	local botData = Schema.Defaults()
	local botFinish = { finished = true, place = 1, count = 8, seconds = 100, active = true, botPractice = true }
	local paid = {}
	for i = 1, 5 do
		paid[i] = RR.Apply(botData, "B:" .. i, botFinish, ctx).coins
	end
	check("bot races per UTC day: 3 full, then 60%", paid[1] == 200 and paid[3] == 200 and paid[4] == 120 and paid[5] == 120)
	local nextDay = {}
	for k, v in pairs(ctx) do
		nextDay[k] = v
	end
	nextDay.utcDay = ctx.utcDay + 1
	check("the counter resets the next UTC day", RR.Apply(botData, "B:6", botFinish, nextDay).coins == 200)

	-- ledger bounded and still protects recent races
	local bounded = Schema.Defaults()
	for i = 1, 40 do
		RR.Apply(bounded, "R:" .. i, finish, ctx)
	end
	check("reward ledger stays bounded (25) and recent races stay protected", #bounded.rewardLedger == 25 and RR.Apply(bounded, "R:40", finish, ctx) == nil and RR.Apply(bounded, "R:16", finish, ctx) == nil)

	-- disconnect at results -> rejoin: the award persisted with its ledger entry
	local backend = PS.MemoryBackend()
	local now = 5000
	local serverA = PS.new({ backend = backend, jobId = "A", clock = function()
		return now
	end })
	local profile = serverA:Load("u_42")
	RR.Apply(profile.data, "A:7", finish, ctx)
	PS.MarkDirty(profile)
	serverA:Save(profile, true) -- player left during Results
	local serverB = PS.new({ backend = backend, jobId = "B", clock = function()
		return now
	end })
	local back = serverB:Load("u_42")
	check("rejoin after leaving at results: Coins kept, the same race can't pay again", back.data.coins == 200 and RR.Apply(back.data, "A:7", finish, ctx) == nil and back.data.coins == 200)
	check("raceIds include the server id (unique across servers)", RR.RaceId("job-1", 3) ~= RR.RaceId("job-2", 3) and RR.RaceId("job-1", 3) ~= RR.RaceId("job-1", 4))
	PC.RaceCoins = shipped
	return results
end

return Spec
