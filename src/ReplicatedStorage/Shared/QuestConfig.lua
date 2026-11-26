--[[
	QuestConfig + rules (B3) — 3 daily and 4 weekly quests, UTC resets (daily at 00:00 UTC,
	weekly on Monday 00:00 UTC). Progress comes only from server events (race results, ability
	activations, judged tricks / gates, Time Trial finishes). No streaks, no punishment for
	missing a day. Claims are once per quest per period, inside one profile mutation.

	Bot practice: progress from races with only you + bots counts for your first BotQuestRaces
	bot races each UTC day; later ones still give XP but do not advance quests - the quest
	panel says so.

	Economy (owner brief 2026-11-26): completed quests are the ONLY source of new Coins.
	  Daily 3 x 100 Coins (+100 XP) · Weekly 4 x 400 Coins (+400 XP) · Milestones (one time,
	  placement-independent goals + skill goals for experienced players).
	  Claims are durable and idempotent: the claimed flag and the Coins are written in ONE
	  profile mutation (a retry or a second server finds it claimed). At a reset boundary a
	  completed quest you didn't claim is paid automatically before the new quests arrive
	  (Refresh returns those rewards and the caller adds them in the same mutation), so a reset
	  never eats a reward.
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
-- one-time milestones: progress never resets; each pays its own Coins once
QuestConfig.Milestones = {
	{ id = "m_finish1", text = "Finish your first race", event = "finish", target = 1, coins = 150, xp = 100 },
	{ id = "m_finish10", text = "Finish 10 races", event = "finish", target = 10, coins = 300, xp = 200 },
	{ id = "m_trick10", text = "Land 10 ramp tricks", event = "trick", target = 10, coins = 300, xp = 200 },
	{ id = "m_gate25", text = "Collect 25 Chaos Gates", event = "gate", target = 25, coins = 400, xp = 200 },
	{ id = "m_finish50", text = "Finish 50 races", event = "finish", target = 50, coins = 800, xp = 400 },
	-- skill goals
	{ id = "m_podium5", text = "Finish on the podium 5 times", event = "podium", target = 5, coins = 400, xp = 250, skill = true },
	{ id = "m_win1", text = "Win a race", event = "win", target = 1, coins = 300, xp = 200, skill = true },
	{ id = "m_pb5", text = "Beat a personal best 5 times", event = "pb", target = 5, coins = 400, xp = 250, skill = true },
	{ id = "m_win10", text = "Win 10 races", event = "win", target = 10, coins = 1000, xp = 500, skill = true },
}
QuestConfig.DailyCount = 3
QuestConfig.Rewards = {
	Daily = { coins = 100, xp = 100 },
	Weekly = { coins = 400, xp = 400 },
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
	local list = scope == "Daily" and QuestConfig.Daily or scope == "Milestone" and QuestConfig.Milestones or QuestConfig.Weekly
	for _, def in ipairs(list) do
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

local function freshMilestones()
	return fresh((function()
		local ids = {}
		for i, def in ipairs(QuestConfig.Milestones) do
			ids[i] = def.id
		end
		return ids
	end)())
end

function QuestConfig.Default()
	return { day = -1, daily = {}, week = -1, weekly = {}, worlds = {}, botDay = -1, botRaces = 0, milestones = freshMilestones() }
end

-- Reward of one completed entry (Daily / Weekly: the scope's reward; Milestone: its own)
function QuestConfig.RewardFor(scope, def)
	if scope == "Milestone" then
		return { coins = def.coins, xp = def.xp }
	end
	return QuestConfig.Rewards[scope]
end

-- completed but unclaimed entries of a period that is ending: claim them now (paid by caller)
local function settle(list, scope, out)
	for _, entry in ipairs(list or {}) do
		local def = defById(scope, entry.id)
		if def and not entry.claimed and entry.progress >= def.target then
			entry.claimed = true
			out[#out + 1] = { scope = scope, text = def.text, reward = QuestConfig.RewardFor(scope, def) }
		end
	end
end

-- Bring quest state up to date for `now` (new day / new week = new quests). Returns changed,
-- autoPaid (list of { scope, text, reward }: completed quests from the ended period, claimed
-- here; the CALLER adds their Coins / XP in the same mutation).
function QuestConfig.Refresh(q, now)
	local changed = false
	local paid = {}
	local day, week = QuestConfig.UtcDay(now), QuestConfig.UtcWeek(now)
	if type(q.milestones) ~= "table" or #q.milestones == 0 then
		q.milestones = freshMilestones()
		changed = true
	end
	if q.day ~= day then
		if q.day ~= -1 then
			settle(q.daily, "Daily", paid)
		end
		q.day = day
		q.daily = fresh(QuestConfig.DailyFor(day))
		changed = true
	end
	if q.week ~= week then
		if q.week ~= -1 then
			settle(q.weekly, "Weekly", paid)
		end
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
	return changed, paid
end

-- Apply one event (kind, amount, ctx = { worldId, botPractice }). Returns list of quests that
-- just completed (for a toast), reason, autoPaid (see Refresh). Bot practice beyond the daily
-- allowance gives no progress.
function QuestConfig.Apply(q, kind, amount, now, ctx)
	local _, paid = QuestConfig.Refresh(q, now)
	ctx = ctx or {}
	if ctx.botPractice and ctx.countsBotRace then
		q.botRaces = q.botRaces + 1
	end
	if ctx.botPractice and q.botRaces > QuestConfig.BotQuestRaces then
		return {}, "bot_limit", paid
	end
	if kind == "world" then
		if not ctx.worldId or q.worlds[ctx.worldId] then
			return {}, nil, paid
		end
		q.worlds[ctx.worldId] = true
		amount = 1
	end
	local done = {}
	for _, scope in ipairs({ "Daily", "Weekly", "Milestone" }) do
		for _, entry in ipairs(scope == "Daily" and q.daily or scope == "Weekly" and q.weekly or q.milestones) do
			local def = defById(scope, entry.id)
			if def and def.event == kind and entry.progress < def.target then
				entry.progress = math.min(def.target, entry.progress + (amount or 1))
				if entry.progress >= def.target then
					done[#done + 1] = def.text
				end
			end
		end
	end
	return done, nil, paid
end

-- Claim (scope, index): returns reward or nil, reason, autoPaid (see Refresh). Mutates
-- `claimed` only when it pays.
function QuestConfig.Claim(q, scope, index, now)
	local _, paid = QuestConfig.Refresh(q, now)
	local list = scope == "Daily" and q.daily or scope == "Weekly" and q.weekly or scope == "Milestone" and q.milestones or nil
	local entry = list and list[index]
	if not entry then
		return nil, "No such quest", paid
	end
	local def = defById(scope, entry.id)
	if not def then
		return nil, "No such quest", paid
	end
	if entry.claimed then
		return nil, "Already claimed", paid
	end
	if entry.progress < def.target then
		return nil, "Not finished yet", paid
	end
	entry.claimed = true
	return QuestConfig.RewardFor(scope, def), nil, paid
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
	local stored = {}
	for _, e in ipairs(type(raw.milestones) == "table" and raw.milestones or {}) do
		if type(e) == "table" and type(e.id) == "string" then
			stored[e.id] = e
		end
	end
	for i, def in ipairs(QuestConfig.Milestones) do
		local e = stored[def.id]
		q.milestones[i] = { id = def.id, progress = e and math.max(0, math.min(def.target, int(e.progress) or 0)) or 0, claimed = e ~= nil and e.claimed == true }
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
