--[[
	RankRules (graphics/gameplay/ranked brief, milestone E, 2026-11-26) — the competitive rating
	model for the opt-in Ranked Circuit TEST. Pure, deterministic, shared (clients show tiers).

	Model (documented in docs/RANKED.md):
	  * Every eligible player compares their verified finishing order against every other
	    eligible HUMAN in the sealed roster: actual = 1 ahead, 0 behind, 0.5 tie (same place or
	    both DNF). Expected = logistic(rating difference / Scale) from ONE immutable snapshot of
	    the ratings taken when the roster was sealed.
	  * delta = K * sum(actual - expected) / (opponents), so a 2nd place means the same in a
	    4-player and a 12-player field. K = Provisional for the first PlacementRaces results,
	    then Established. Deltas round to whole points.
	  * Bots, purchases, Coins, cosmetics, races played and bot wins are never inputs.
	  * A round counts only with >= MinHumans eligible humans at the seal and a finalized result;
	    aborted rounds change nothing. A DNF (timeout or quitting mid-race) ranks behind every
	    finisher, tied with the other DNFs.
	  * Apply is idempotent per match id (a retry or a duplicate result never applies twice).
	Skill rank is separate from level/XP, mastery, event results and the Stunt Lab.
]]

local RankRules = {}

RankRules.Version = 1
RankRules.Season = "S1"
RankRules.StartRating = 1000
RankRules.Scale = 400
RankRules.KProvisional = 48
RankRules.KEstablished = 24
RankRules.PlacementRaces = 5
RankRules.MinHumans = 4 -- start of the test; tune with real traffic
RankRules.AppliedMemory = 20
RankRules.HistoryMemory = 10
RankRules.Tiers = {
	{ Name = "Bronze", Min = -math.huge },
	{ Name = "Silver", Min = 900 },
	{ Name = "Gold", Min = 1050 },
	{ Name = "Platinum", Min = 1200 },
	{ Name = "Diamond", Min = 1350 },
	{ Name = "Elite", Min = 1500 },
}

function RankRules.Default()
	return { season = RankRules.Season, rating = RankRules.StartRating, placements = 0, applied = {}, history = {} }
end

local function finite(x)
	return type(x) == "number" and x == x and x > -math.huge and x < math.huge
end

function RankRules.Sanitize(raw)
	local d = RankRules.Default()
	if type(raw) ~= "table" then
		return d
	end
	d.season = type(raw.season) == "string" and #raw.season <= 16 and raw.season or d.season
	d.rating = finite(raw.rating) and math.clamp(math.floor(raw.rating + 0.5), 0, 5000) or d.rating
	d.placements = finite(raw.placements) and math.clamp(math.floor(raw.placements), 0, 1000000) or 0
	if type(raw.applied) == "table" then
		for _, id in ipairs(raw.applied) do
			if type(id) == "string" and #id <= 80 and #d.applied < RankRules.AppliedMemory then
				d.applied[#d.applied + 1] = id
			end
		end
	end
	if type(raw.history) == "table" then
		for _, h in ipairs(raw.history) do
			if type(h) == "table" and type(h.m) == "string" and finite(h.d) and finite(h.r) and #d.history < RankRules.HistoryMemory then
				d.history[#d.history + 1] = { m = string.sub(h.m, 1, 80), d = h.d, r = h.r, p = finite(h.p) and h.p or nil, n = finite(h.n) and h.n or nil }
			end
		end
	end
	return d
end

function RankRules.Expected(ra, rb)
	return 1 / (1 + 10 ^ ((rb - ra) / RankRules.Scale))
end

function RankRules.Tier(rating, placements)
	if (placements or 0) < RankRules.PlacementRaces then
		return "Provisional", placements or 0
	end
	local name = "Bronze"
	for _, tier in ipairs(RankRules.Tiers) do
		if rating >= tier.Min then
			name = tier.Name
		end
	end
	return name, nil
end

-- Progress inside the current tier (0..1) for the UI bar
function RankRules.TierProgress(rating)
	for i, tier in ipairs(RankRules.Tiers) do
		local nextTier = RankRules.Tiers[i + 1]
		if not nextTier or rating < nextTier.Min then
			if not nextTier or tier.Min == -math.huge then
				return nextTier and math.clamp((rating - (nextTier.Min - 150)) / 150, 0, 1) or 1
			end
			return math.clamp((rating - tier.Min) / (nextTier.Min - tier.Min), 0, 1)
		end
	end
	return 1
end

-- Is this sealed roster rankable? humans = { {userId, eligible=bool} }
function RankRules.Eligible(humans, finalized)
	if not finalized then
		return false, "not finalized"
	end
	local n = 0
	for _, h in ipairs(humans) do
		if h.eligible ~= false then
			n = n + 1
		end
	end
	if n < RankRules.MinHumans then
		return false, string.format("needs %d ranked players (had %d)", RankRules.MinHumans, n)
	end
	return true, nil
end

-- roster = { { userId, rating, placements, place (number) or nil, finished (bool) } } - the
-- snapshot taken at the seal + the finalized standings. Returns { [userId] = delta } (integers).
function RankRules.Deltas(roster)
	local list = {}
	for _, p in ipairs(roster) do
		list[#list + 1] = p
	end
	table.sort(list, function(a, b)
		return a.userId < b.userId -- deterministic order
	end)
	local function order(p)
		if p.finished and p.place then
			return p.place
		end
		return math.huge -- DNF: behind every finisher, tied with the other DNFs
	end
	local out = {}
	local n = #list
	if n < 2 then
		return out
	end
	for i, a in ipairs(list) do
		local sum = 0
		for j, b in ipairs(list) do
			if i ~= j then
				local oa, ob = order(a), order(b)
				local actual = oa < ob and 1 or (oa > ob and 0 or 0.5)
				sum = sum + (actual - RankRules.Expected(a.rating, b.rating))
			end
		end
		local k = (a.placements or 0) < RankRules.PlacementRaces and RankRules.KProvisional or RankRules.KEstablished
		local raw = k * sum / (n - 1)
		out[a.userId] = raw >= 0 and math.floor(raw + 0.5) or -math.floor(-raw + 0.5)
	end
	return out
end

-- Apply one match to a profile's rank table (mutates). Returns applied(bool), newRating.
-- Idempotent: the same matchId never applies twice. A new season starts from a soft reset.
function RankRules.Apply(rank, matchId, delta, place, fieldSize)
	if rank.season ~= RankRules.Season then
		rank.season = RankRules.Season
		rank.rating = math.floor((rank.rating + RankRules.StartRating) / 2 + 0.5) -- disclosed soft reset
		rank.placements = 0
	end
	for _, id in ipairs(rank.applied) do
		if id == matchId then
			return false, rank.rating
		end
	end
	rank.rating = math.max(0, rank.rating + delta)
	rank.placements = rank.placements + 1
	table.insert(rank.applied, matchId)
	while #rank.applied > RankRules.AppliedMemory do
		table.remove(rank.applied, 1)
	end
	table.insert(rank.history, 1, { m = matchId, d = delta, r = rank.rating, p = place, n = fieldSize })
	while #rank.history > RankRules.HistoryMemory do
		table.remove(rank.history)
	end
	return true, rank.rating
end

return RankRules
