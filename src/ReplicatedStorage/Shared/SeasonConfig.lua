--[[
	SeasonConfig (C3) — free 28-day seasons, 30 levels, a free reward track. Pure + data.
	- Seasons are configured HERE by the owner (id, name, start/end in UTC). The game only shows
	  a date that is configured; with no season running it says so (no invented deadlines).
	- Season XP: the XP a race actually paid (so the existing bot-practice rules apply) and quest
	  claims (daily +60, weekly +200). 300 season XP per level.
	- Claims are recorded per season id; a new season resets season XP and claims only. Owned
	  items, Coins, Shards and your account level are never touched.
	- No premium lane: nothing on the track costs anything.
]]

local SeasonConfig = {}

SeasonConfig.Levels = 30
SeasonConfig.XpPerLevel = 300
SeasonConfig.QuestXp = { Daily = 60, Weekly = 200 }

-- Owner-editable schedule (UTC epoch seconds). Season 1: Mon 23 Nov 2026 - Mon 21 Dec 2026.
SeasonConfig.Seasons = {
	{ id = "S1", name = "Season 1: Launch Lap", startsAt = 1795392000, endsAt = 1797811200 },
}

-- Free track: cosmetics every 5 levels, Coins on odd levels, Shards on the other even levels
SeasonConfig.CosmeticRewards = {
	[5] = "tangerine",
	[10] = "trail_bubble",
	[15] = "emote_so_close",
	[20] = "honeycomb",
	[25] = "burst_sparks",
	[30] = "storm_cloud",
}

function SeasonConfig.Reward(level)
	local item = SeasonConfig.CosmeticRewards[level]
	if item then
		return { kind = "Item", id = item }
	elseif level % 2 == 1 then
		return { kind = "Coins", amount = 60 }
	end
	return { kind = "Shards", amount = 20 }
end

function SeasonConfig.Current(now)
	for _, season in ipairs(SeasonConfig.Seasons) do
		if now >= season.startsAt and now < season.endsAt then
			return season
		end
	end
	return nil
end

function SeasonConfig.LevelForXp(xp)
	return math.min(SeasonConfig.Levels, math.floor((xp or 0) / SeasonConfig.XpPerLevel))
end

-- Bring a stored season record to the current season (rollover = fresh xp/claims)
function SeasonConfig.Refresh(record, now)
	local season = SeasonConfig.Current(now)
	local id = season and season.id or nil
	if record.id ~= id then
		record.id = id
		record.xp = 0
		record.claimed = {}
		return true
	end
	return false
end

function SeasonConfig.AddXp(record, amount, now)
	SeasonConfig.Refresh(record, now)
	if not record.id or type(amount) ~= "number" or amount <= 0 then
		return false
	end
	record.xp = math.min(record.xp + math.floor(amount), SeasonConfig.Levels * SeasonConfig.XpPerLevel)
	return true
end

-- Claim level `level`: returns reward or nil, reason. Marks the claim only when it pays.
function SeasonConfig.Claim(record, level, now)
	SeasonConfig.Refresh(record, now)
	if not record.id then
		return nil, "No season running"
	end
	if type(level) ~= "number" or level < 1 or level > SeasonConfig.Levels or level ~= math.floor(level) then
		return nil, "No such level"
	end
	for _, l in ipairs(record.claimed) do
		if l == level then
			return nil, "Already claimed"
		end
	end
	if SeasonConfig.LevelForXp(record.xp) < level then
		return nil, "Reach that season level first"
	end
	table.insert(record.claimed, level)
	return SeasonConfig.Reward(level)
end

function SeasonConfig.Default()
	return { id = nil, xp = 0, claimed = {} }
end

function SeasonConfig.Sanitize(raw)
	local r = SeasonConfig.Default()
	if type(raw) ~= "table" then
		return r
	end
	if type(raw.id) == "string" and #raw.id <= 16 then
		r.id = raw.id
	end
	if type(raw.xp) == "number" and raw.xp == raw.xp then
		r.xp = math.max(0, math.min(math.floor(raw.xp), SeasonConfig.Levels * SeasonConfig.XpPerLevel))
	end
	local seen = {}
	for _, l in ipairs(type(raw.claimed) == "table" and raw.claimed or {}) do
		if type(l) == "number" and l >= 1 and l <= SeasonConfig.Levels and l == math.floor(l) and not seen[l] then
			seen[l] = true
			r.claimed[#r.claimed + 1] = l
		end
	end
	return r
end

return SeasonConfig
