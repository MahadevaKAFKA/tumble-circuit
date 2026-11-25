--[[
	QuestConfig + rules (B3) — 3 daily and 4 weekly quests, UTC resets (daily at 00:00 UTC,
	weekly on Monday 00:00 UTC). Progress comes only from server events (race results, ability
	activations, judged tricks / gates, Time Trial finishes). No streaks, no punishment for
	missing a day. Claims are once per quest per period, inside one profile mutation.

	Bot practice: progress from races with only you + bots counts for your first BotQuestRaces
	bot races each UTC day (the same three that pay full Coins); later ones still pay but do not
	advance quests - the quest panel says so.
]]

local QuestConfig = {}

QuestConfig.BotQuestRaces = 3

-- event kinds: race (raced to the end, finished or active DNF), finish, podium, ability, trick,
-- gate, trial (Time Trial finish), world (distinct world raced this week), pb (race or trial PB)
QuestConfig.Daily = {
	{ id = "d_race3", text = "Race 3 times", event = "race", target = 3 },
	{ id = "d_finish2", text = "Finish 2 races", event = "finish", target = 2 },
	{ id = "d_ability5", text = "Use 5 abilities in races", event = "ability", target = 5 },
	{ id = "d_trick2", text = "Land 2 ramp tricks", event = "trick", target = 2 },
	{ id = "d_gate3", text = "Collect 3 Chaos Gates", event = "gate", target = 3 },
	{ id = "d_trial1", text = "Finish a Time Trial", event = "trial", target = 1 },
	{ id = "d_podium1", text = "Finish on the podium", event = "podium", target = 1 },
}
QuestConfig.Weekly = {
	{ id = "w_finish15", text = "Finish 15 races", event = "finish", target = 15 },
	{ id = "w_podium3", text = "Finish on the podium 3 times", event = "podium", target = 3 },
	{ id = "w_worlds2", text = "Race on 2 different worlds", event = "world", target = 2 },
	{ id = "w_pb1", text = "Beat a personal best", event = "pb", target = 1 },
}
QuestConfig.DailyCount = 3
QuestConfig.Rewards = {
	Daily = { coins = 60, xp = 100 },
	Weekly = { coins = 250, xp = 400 },
}

local DAY = 86400

function QuestConfig.UtcDay(epochSeconds)
	return math.floor(epochSeconds / DAY)
end

-- Monday-based UTC week (epoch day 0 was a Thursday)
function QuestConfig.UtcWeek(epochSeconds)
	return math.floor((math.floor(epochSeconds / DAY) + 3) / 7)
end

local function defById(scope, id)
	for _, def in ipairs(scope == "Daily" and QuestConfig.Daily or QuestConfig.Weekly) do
		if def.id == id then
			return def
		end
	end
	return nil
end
QuestConfig.Def = defById

-- The day's three daily quests: the same for everyone (deterministic from the UTC day)
function QuestConfig.DailyFor(day)
	local pool = {}
	for i, def in ipairs(QuestConfig.Daily) do
		pool[i] = def.id
	end
	local seed = (day * 1103515245 + 12345) % 2147483648
	local picked = {}
	for _ = 1, QuestConfig.DailyCount do
		seed = (seed * 1103515245 + 12345) % 2147483648
		local i = seed % #pool + 1
		picked[#picked + 1] = table.remove(pool, i)
	end
	return picked
end

local function fresh(ids)
	local out = {}
	for i, id in ipairs(ids) do
		out[i] = { id = id, progress = 0, claimed = false }
	end
	return out
end

function QuestConfig.Default()
	return { day = -1, daily = {}, week = -1, weekly = {}, worlds = {}, botDay = -1, botRaces = 0 }
end

-- Bring quest state up to date for `now` (new day / new week = new quests). Returns changed.
function QuestConfig.Refresh(q, now)
	local changed = false
	local day, week = QuestConfig.UtcDay(now), QuestConfig.UtcWeek(now)
	if q.day ~= day then
		q.day = day
		q.daily = fresh(QuestConfig.DailyFor(day))
		changed = true
	end
	if q.week ~= week then
		q.week = week
		local ids = {}
		for i, def in ipairs(QuestConfig.Weekly) do
			ids[i] = def.id
		end
		q.weekly = fresh(ids)
		q.worlds = {}
		changed = true
	end
	if q.botDay ~= day then
		q.botDay = day
		q.botRaces = 0
	end
	return changed
end

-- Apply one event (kind, amount, ctx = { worldId, botPractice }). Returns list of quests that
-- just completed (for a toast). Bot practice beyond the daily allowance gives no progress.
function QuestConfig.Apply(q, kind, amount, now, ctx)
	QuestConfig.Refresh(q, now)
	ctx = ctx or {}
	if ctx.botPractice and ctx.countsBotRace then
		q.botRaces = q.botRaces + 1
	end
	if ctx.botPractice and q.botRaces > QuestConfig.BotQuestRaces then
		return {}, "bot_limit"
	end
	if kind == "world" then
		if not ctx.worldId or q.worlds[ctx.worldId] then
			return {}
		end
		q.worlds[ctx.worldId] = true
		amount = 1
	end
	local done = {}
	for _, scope in ipairs({ "Daily", "Weekly" }) do
		for _, entry in ipairs(scope == "Daily" and q.daily or q.weekly) do
			local def = defById(scope, entry.id)
			if def and def.event == kind and entry.progress < def.target then
				entry.progress = math.min(def.target, entry.progress + (amount or 1))
				if entry.progress >= def.target then
					done[#done + 1] = def.text
				end
			end
		end
	end
	return done
end

-- Claim (scope, index): returns reward or nil, reason. Mutates `claimed` only when it pays.
function QuestConfig.Claim(q, scope, index, now)
	QuestConfig.Refresh(q, now)
	local list = scope == "Daily" and q.daily or scope == "Weekly" and q.weekly or nil
	local entry = list and list[index]
	if not entry then
		return nil, "No such quest"
	end
	local def = defById(scope, entry.id)
	if not def then
		return nil, "No such quest"
	end
	if entry.claimed then
		return nil, "Already claimed"
	end
	if entry.progress < def.target then
		return nil, "Not finished yet"
	end
	entry.claimed = true
	return QuestConfig.Rewards[scope]
end

-- Sanitize a stored quest table (profile migration)
function QuestConfig.Sanitize(raw)
	local q = QuestConfig.Default()
	if type(raw) ~= "table" then
		return q
	end
	local function int(v)
		return type(v) == "number" and v == v and math.floor(v) or nil
	end
	q.day = int(raw.day) or -1
	q.week = int(raw.week) or -1
	q.botDay = int(raw.botDay) or -1
	q.botRaces = math.max(0, int(raw.botRaces) or 0)
	for _, scope in ipairs({ "Daily", "Weekly" }) do
		local key = scope == "Daily" and "daily" or "weekly"
		for _, e in ipairs(type(raw[key]) == "table" and raw[key] or {}) do
			local def = type(e) == "table" and defById(scope, e.id)
			if def and #q[key] < (scope == "Daily" and QuestConfig.DailyCount or #QuestConfig.Weekly) then
				q[key][#q[key] + 1] = { id = e.id, progress = math.max(0, math.min(def.target, int(e.progress) or 0)), claimed = e.claimed == true }
			end
		end
	end
	if type(raw.worlds) == "table" then
		for id, v in pairs(raw.worlds) do
			if type(id) == "string" and #id <= 40 and v == true then
				q.worlds[id] = true
			end
		end
	end
	return q
end

return QuestConfig
