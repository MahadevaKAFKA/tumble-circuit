--[[
	ChallengeConfig (challenges/cups/creator brief, 2026-11-26) — the allowlist of challenges,
	their versions, medals, share codes, the weekly rotation and the map mastery goals.

	A challenge's records, ghosts and medals are scoped to Key() = id|revision|ruleset|scoring,
	so a course or rule change never compares against old times. Codes are a routing hint only:
	the server resolves them against this allowlist (never trusts a time, entry or ownership).
	Medal targets are PROVISIONAL (from the lap model + margins) until real attempts exist.
	Pure; shared with clients.
]]

local ChallengeConfig = {}

ChallengeConfig.ScoringVersion = 1
ChallengeConfig.Challenges = {
	{
		Id = "drop_shaft",
		Code = "DROP1",
		Revision = 1,
		Ruleset = "R1", -- solo, no abilities, no bots, no comeback boosts, fixed start
		Course = "DropShaftChallenge", -- TrackDefinitions key
		Map = "NeonFoundry_A4",
		MapName = "Neon Foundry",
		Title = "The Drop Shaft",
		Goal = "Brake before the lip, land wide, take the hairpin. Clean is fast.",
		FastLine = "Hit the right kicker at speed to land past the qualifying line, then the inside of the hairpin.",
		Medals = { Gold = 21.0, Silver = 24.0, Bronze = 28.0 }, -- provisional (model 17.1 s + margins)
		MaxSeconds = 90,
		Status = "Live",
	},
}
ChallengeConfig.ById = {}
ChallengeConfig.ByCode = {}
for _, c in ipairs(ChallengeConfig.Challenges) do
	ChallengeConfig.ById[c.Id] = c
	ChallengeConfig.ByCode[c.Code] = c
end

-- Weekly Challenge rotation (UTC weeks). Starts with the Drop Shaft; Sky Carnival landing and
-- Volcano Vault vent sectors join once they are authored and validated.
ChallengeConfig.WeeklyRotation = { "drop_shaft" }
ChallengeConfig.WeekEpoch = 1764547200 -- Monday 2025-12-01 00:00 UTC (week 0)

function ChallengeConfig.Key(c)
	return string.format("%s|r%d|%s|s%d", c.Id, c.Revision, c.Ruleset, ChallengeConfig.ScoringVersion)
end

function ChallengeConfig.Medal(c, seconds)
	if type(seconds) ~= "number" or seconds <= 0 then
		return nil
	end
	for _, name in ipairs({ "Gold", "Silver", "Bronze" }) do
		if seconds <= c.Medals[name] then
			return name
		end
	end
	return nil
end

-- the week window for a UTC time: index, startsAt, endsAt
function ChallengeConfig.Week(now)
	local week = math.floor((now - ChallengeConfig.WeekEpoch) / (7 * 86400))
	local starts = ChallengeConfig.WeekEpoch + week * 7 * 86400
	return week, starts, starts + 7 * 86400
end

function ChallengeConfig.Weekly(now)
	local week, starts, ends = ChallengeConfig.Week(now)
	local rotation = ChallengeConfig.WeeklyRotation
	local id = rotation[(week % #rotation) + 1]
	return ChallengeConfig.ById[id], week, starts, ends
end

-- A typed / shared code -> an allowlisted live challenge (case-insensitive), or nil
function ChallengeConfig.Resolve(code)
	if type(code) ~= "string" or #code > 12 then
		return nil
	end
	local c = ChallengeConfig.ByCode[string.upper((code:gsub("%s", "")))]
	if c and c.Status == "Live" then
		return c
	end
	return nil
end

-- "Drop Shaft · 24.81 s · Beat my time"
function ChallengeConfig.ResultLine(c, seconds)
	return string.format("%s · %.2f s · Beat my time  (code %s)", c.Title, seconds, c.Code)
end

-- Map mastery (Garage + map selector). Each goal names its evidence; rewards grant once.
ChallengeConfig.Mastery = {
	NeonFoundry_A4 = {
		Reward = "trail_foundry_exhaust",
		Goals = {
			{ Id = "nf_clean", Title = "Clean Circuit", Text = "Finish all three laps of a Neon Foundry race without a reset or a fall." },
			{ Id = "nf_fast", Title = "Fast Sector", Text = "Beat the Drop Shaft gold time." },
			{ Id = "nf_signature", Title = "Signature Line", Text = "Take the precision entry and land past the Drop Shaft's qualifying line, then finish." },
		},
	},
	SkyCarnival_B1 = {
		Reward = nil, -- a Sky Carnival marble pattern once its landing goals are validated
		Goals = {
			{ Id = "sc_clean", Title = "Clean Circuit", Text = "Finish all three laps of a Sky Carnival race without a reset or a fall." },
		},
	},
	VolcanoVault_B1 = {
		Reward = nil, -- a Volcano Vault profile emblem once its vent-timing goal is validated
		Goals = {
			{ Id = "vv_clean", Title = "Clean Circuit", Text = "Finish all three laps of a Volcano Vault race without a reset or a fall." },
		},
	},
}

-- goals done for a map given the profile's mastery table
function ChallengeConfig.MasteryProgress(mapId, mastery)
	local m = ChallengeConfig.Mastery[mapId]
	if not m then
		return 0, 0
	end
	local done = 0
	for _, g in ipairs(m.Goals) do
		if mastery and mastery[g.Id] then
			done = done + 1
		end
	end
	return done, #m.Goals
end

return ChallengeConfig
