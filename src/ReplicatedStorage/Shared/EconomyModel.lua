--[[
	EconomyModel (owner brief 2026-11-26, economy) — a pure planning model, read by specs and
	docs only (no gameplay code uses it). It turns the live config (QuestConfig rewards,
	CapsuleOdds case prices, ProgressionConfig race pay) into Coins over 1 / 7 / 30 days and the
	number of cases a player could open of each tier. The play patterns are ASSUMPTIONS to be
	replaced with playtest telemetry (TelemetryService Economy events).

	  Active  every daily quest (3/day), every weekly (4/week), milestones early
	  Casual  2 of 3 dailies, 2 of 4 weeklies, milestones slower
	  Before  the v31 economy for comparison: 5 races/day at ~155 Coins + 3 x 60 daily + 4 x 250
	          weekly (race Coins on, 600-Coin Marble capsule)
]]

local CapsuleOdds = require(script.Parent:WaitForChild("CapsuleOdds"))
local QuestConfig = require(script.Parent:WaitForChild("QuestConfig"))

local EconomyModel = {}

local function milestoneCoins(ids)
	local total = 0
	for _, def in ipairs(QuestConfig.Milestones) do
		if ids[def.id] then
			total = total + def.coins
		end
	end
	return total
end

-- milestones reached by day N (assumed)
EconomyModel.Patterns = {
	Active = {
		dailies = 3,
		weeklies = 4,
		milestones = {
			[1] = { m_finish1 = true },
			[7] = { m_finish1 = true, m_finish10 = true, m_win1 = true, m_podium5 = true, m_trick10 = true },
			[30] = "all",
		},
	},
	Casual = {
		dailies = 2,
		weeklies = 2,
		milestones = {
			[1] = { m_finish1 = true },
			[7] = { m_finish1 = true, m_finish10 = true },
			[30] = { m_finish1 = true, m_finish10 = true, m_trick10 = true, m_win1 = true, m_podium5 = true, m_gate25 = true },
		},
	},
}

-- Coins earned by `day` (1, 7 or 30) for a pattern name
function EconomyModel.CoinsBy(patternName, day)
	local p = EconomyModel.Patterns[patternName]
	local daily = QuestConfig.Rewards.Daily.coins * p.dailies * day
	local weekly = QuestConfig.Rewards.Weekly.coins * p.weeklies * math.floor(day / 7)
	local reached = p.milestones[day]
	local ms
	if reached == "all" then
		ms = 0
		for _, def in ipairs(QuestConfig.Milestones) do
			ms = ms + def.coins
		end
	else
		ms = milestoneCoins(reached or {})
	end
	return daily + weekly + ms
end

-- the v31 economy (race Coins on), same day counts
function EconomyModel.CoinsBefore(day)
	return day * (5 * 155 + 3 * 60) + math.floor(day / 7) * 4 * 250
end

-- How many cases of each tier those Coins buy (all spent on that one case)
function EconomyModel.Cases(coins)
	local out = {}
	for _, box in ipairs(CapsuleOdds.Boxes) do
		out[box.Id] = math.floor(coins / box.Cost)
	end
	return out
end

-- The full table: { [pattern] = { [day] = { coins, cases } } }
function EconomyModel.Table()
	local out = {}
	for _, name in ipairs({ "Active", "Casual" }) do
		out[name] = {}
		for _, day in ipairs({ 1, 7, 30 }) do
			local coins = EconomyModel.CoinsBy(name, day)
			out[name][day] = { coins = coins, cases = EconomyModel.Cases(coins) }
		end
	end
	return out
end

return EconomyModel
