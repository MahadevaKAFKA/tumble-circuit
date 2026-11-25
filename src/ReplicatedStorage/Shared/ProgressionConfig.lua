--[[
	ProgressionConfig (A5) — every Coin / XP / level number in one pure, replicated module, so the
	results screen can explain exactly where each Coin came from. Hypotheses from the master
	reference (section "Race pay"), to be tuned from playtests. Coins are only ever EARNED.

	Coins (human racer, one award per raceId + player):
	  finished : 55 base + placement + 20 completion
	             placement 1st 125, 2nd 100, 3rd 80; 4th..last interpolate linearly 60 -> 35
	             (4th = 60, last = 35; with exactly 4 racers 4th = 60). Rounded to whole Coins.
	  DNF      : 25 consolation INSTEAD of base/placement/completion, only if the racer was
	             active (sent real input this race and reached checkpoint 1 or 15% of the route)
	  idle     : 0 (no input this race), finished or not
	XP: finished 100 + placement 60 / 45 / 30 / 10 (4th and below) + 30 for a verified personal
	    best on the same track configuration; active DNF 20; idle 0.
	Bot practice (one human + bots): the first 3 such races per account per UTC day pay normally;
	later ones pay 60% of the Coins (rounded), XP unchanged, always shown on the results screen.
	Levels 1..50: Lv2 at 400 XP total; every next level costs 80 XP more than the previous one.
]]

local ProgressionConfig = {}

ProgressionConfig.Coins = {
	FinishBase = 55,
	Podium = { 125, 100, 80 },
	RestHigh = 60, -- 4th place
	RestLow = 35, -- last place
	Completion = 20,
	DnfConsolation = 25,
	DnfActiveMinProgressFraction = 0.15,
}

ProgressionConfig.Xp = {
	Finish = 100,
	Placement = { 60, 45, 30 },
	PlacementRest = 10,
	PersonalBest = 30,
	DnfActive = 20,
}

ProgressionConfig.BotPractice = {
	FullRewardRacesPerDay = 3,
	CoinMultiplier = 0.6,
}

ProgressionConfig.Levels = {
	Max = 50,
	FirstCost = 400, -- XP from level 1 to level 2
	CostStep = 80, -- each further level costs this much more
}

-- XP needed to go from `level` to `level + 1` (nil at the cap).
function ProgressionConfig.LevelCost(level)
	local cfg = ProgressionConfig.Levels
	if level >= cfg.Max then
		return nil
	end
	return cfg.FirstCost + cfg.CostStep * (level - 1)
end

-- Total XP at which `level` is reached (level 1 = 0).
function ProgressionConfig.TotalXpForLevel(level)
	local total = 0
	for l = 1, math.min(level, ProgressionConfig.Levels.Max) - 1 do
		total = total + ProgressionConfig.LevelCost(l)
	end
	return total
end

-- level, xp into this level, xp needed for the next (0 at max). Safe for any number.
function ProgressionConfig.LevelForXp(xp)
	xp = tonumber(xp) or 0
	if xp ~= xp or xp < 0 then
		xp = 0
	end
	local level, remaining = 1, math.floor(math.min(xp, 2 ^ 52))
	while level < ProgressionConfig.Levels.Max do
		local cost = ProgressionConfig.LevelCost(level)
		if remaining < cost then
			return level, remaining, cost
		end
		remaining = remaining - cost
		level = level + 1
	end
	return level, 0, 0
end

-- Placement Coins for a finisher. place 1..count.
function ProgressionConfig.PlacementCoins(place, count)
	local c = ProgressionConfig.Coins
	if c.Podium[place] then
		return c.Podium[place]
	end
	if count <= 4 or place <= 4 then
		return c.RestHigh
	end
	local f = (place - 4) / (count - 4)
	return math.floor(c.RestHigh + (c.RestLow - c.RestHigh) * f + 0.5)
end

--[[ result = { finished, place, count, active, checkpoint, progressFraction, personalBest,
                botPractice, botRacesToday (before this one) }
	 Returns { coins, xp, lines = { {label, coins, xp} }, multiplierNote } ]]
function ProgressionConfig.RaceReward(result)
	local c, x = ProgressionConfig.Coins, ProgressionConfig.Xp
	local lines = {}
	local function line(label, coins, xp)
		lines[#lines + 1] = { label = label, coins = coins or 0, xp = xp or 0 }
	end
	if not result.active then
		line("No input detected this race - no reward", 0, 0)
	elseif result.finished then
		line("Finished", c.FinishBase, x.Finish)
		local placementXp = x.Placement[result.place] or x.PlacementRest
		line("Placement " .. tostring(result.place) .. " of " .. tostring(result.count), ProgressionConfig.PlacementCoins(result.place, result.count), placementXp)
		line("Completion bonus", c.Completion, 0)
		if result.personalBest then
			line("Personal best!", 0, x.PersonalBest)
		end
	else
		local progressed = (result.checkpoint or 0) >= 1 or (result.progressFraction or 0) >= c.DnfActiveMinProgressFraction
		if progressed then
			line("Did not finish - consolation", c.DnfConsolation, x.DnfActive)
		else
			line("Did not finish - reach checkpoint 1 for a consolation reward", 0, 0)
		end
	end
	local coins, xp = 0, 0
	for _, l in ipairs(lines) do
		coins = coins + l.coins
		xp = xp + l.xp
	end
	local note = nil
	if result.botPractice and coins > 0 then
		local free = ProgressionConfig.BotPractice.FullRewardRacesPerDay
		if (result.botRacesToday or 0) >= free then
			local reduced = math.floor(coins * ProgressionConfig.BotPractice.CoinMultiplier + 0.5)
			line(string.format("Bot practice race %d today: Coins x%.1f", (result.botRacesToday or 0) + 1, ProgressionConfig.BotPractice.CoinMultiplier), reduced - coins, 0)
			note = string.format("Racing only bots: the first %d races each day pay full Coins, later ones pay %d%%. XP is always full.", free, math.floor(ProgressionConfig.BotPractice.CoinMultiplier * 100 + 0.5))
			coins = reduced
		else
			note = string.format("Bot practice race %d of %d at full Coins today.", (result.botRacesToday or 0) + 1, free)
		end
	end
	return { coins = coins, xp = xp, lines = lines, multiplierNote = note }
end

return ProgressionConfig
