--[[
	CupConfig (challenges/cups/creator brief, 2026-11-26) — the Foundry Cup PILOT, in staging.

	Status "Staging": nothing in the live game reads this yet except the offline tests and the
	design doc (docs/FOUNDRY_CUP.md). It fixes the rules so the qualifier data that already
	exists (the Drop Shaft Weekly board) can feed a later final without a rule change.

	  Qualifier  the Drop Shaft Weekly Challenge board for the cup's week (best valid time per
	             player, server-timed). Top `FinalSize` qualify; ties by who set the time first.
	  Final      a 3-race series on the Neon Foundry circuit (3 laps each), Ranked ruleset (no
	             abilities, no bots, no comeback boosts). Points per race below; DNF scores 0.
	             Tiebreak: more wins, then the better best finish, then the qualifier time.
	  Prizes     none in the pilot. A cosmetic badge may be proposed later; no Robux, no paid
	             entry, nothing purchasable - any prize needs the owner's approval first.
	Pure; shared with clients.
]]

local CupConfig = {}

CupConfig.Cups = {
	{
		Id = "foundry_cup_pilot",
		Title = "Foundry Cup (pilot)",
		Status = "Staging",
		QualifierChallenge = "drop_shaft",
		FinalSize = 12,
		Map = "NeonFoundry_A4",
		Races = 3,
		Points = { 25, 18, 15, 12, 10, 8, 6, 4, 2, 1 },
		Ruleset = "Ranked",
		Prize = nil,
	},
}
CupConfig.ById = {}
for _, cup in ipairs(CupConfig.Cups) do
	CupConfig.ById[cup.Id] = cup
end

function CupConfig.Points(cup, place, finished)
	if not finished or type(place) ~= "number" then
		return 0
	end
	return cup.Points[place] or 0
end

-- rows: { {userId, seconds, setAt} } from the weekly board -> the qualified list (best first)
function CupConfig.Qualify(cup, rows)
	local list = {}
	for _, r in ipairs(rows or {}) do
		if type(r.userId) == "number" and type(r.seconds) == "number" and r.seconds > 0 then
			list[#list + 1] = r
		end
	end
	table.sort(list, function(a, b)
		if a.seconds ~= b.seconds then
			return a.seconds < b.seconds
		end
		if (a.setAt or 0) ~= (b.setAt or 0) then
			return (a.setAt or 0) < (b.setAt or 0)
		end
		return a.userId < b.userId
	end)
	local out = {}
	for i = 1, math.min(cup.FinalSize, #list) do
		out[i] = list[i]
	end
	return out
end

-- races: { { [userId] = { place, finished } }, ... }; qualifier: { [userId] = seconds }
-- -> standings { {userId, points, wins, bestPlace, qualifier} } best first
function CupConfig.Standings(cup, races, qualifier)
	local byUser = {}
	local function row(userId)
		local r = byUser[userId]
		if not r then
			r = { userId = userId, points = 0, wins = 0, bestPlace = math.huge, qualifier = qualifier and qualifier[userId] or math.huge }
			byUser[userId] = r
		end
		return r
	end
	for _, race in ipairs(races or {}) do
		for userId, res in pairs(race) do
			local r = row(userId)
			r.points = r.points + CupConfig.Points(cup, res.place, res.finished)
			if res.finished and res.place == 1 then
				r.wins = r.wins + 1
			end
			if res.finished and res.place < r.bestPlace then
				r.bestPlace = res.place
			end
		end
	end
	local out = {}
	for _, r in pairs(byUser) do
		out[#out + 1] = r
	end
	table.sort(out, function(a, b)
		if a.points ~= b.points then
			return a.points > b.points
		end
		if a.wins ~= b.wins then
			return a.wins > b.wins
		end
		if a.bestPlace ~= b.bestPlace then
			return a.bestPlace < b.bestPlace
		end
		if a.qualifier ~= b.qualifier then
			return a.qualifier < b.qualifier
		end
		return a.userId < b.userId
	end)
	return out
end

return CupConfig
