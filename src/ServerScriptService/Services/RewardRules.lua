--[[
	RewardRules (A5, ADR-12) — pure race-reward application. Exactly one award per raceId per
	profile: the raceId goes into the profile's bounded reward ledger in the SAME mutation that
	adds the Coins/XP, so a duplicate finish callback, a second Results pass, a rejoin or a
	replayed save can never pay twice. Bots have no wallet (callers never pass them here).

	Apply(data, raceId, result, ctx) -> notice | nil, reason
	  result = { finished, place, count, seconds, active, checkpoint, progressFraction, botPractice }
	  ctx    = { worldId, layoutVersion, seedClass, mode, utcDay, minPlausibleSeconds }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlayerDataSchema = require(Shared:WaitForChild("PlayerDataSchema"))
local ProgressionConfig = require(Shared:WaitForChild("ProgressionConfig"))

local RewardRules = {}

function RewardRules.RaceId(serverId, roundId)
	return string.format("%s:%d", tostring(serverId):sub(1, 60), roundId)
end

function RewardRules.UtcDay(epochSeconds)
	return math.floor(epochSeconds / 86400)
end

function RewardRules.Apply(data, raceId, result, ctx)
	if type(raceId) ~= "string" or raceId == "" then
		return nil, "no race id"
	end
	if PlayerDataSchema.LedgerHas(data, raceId) then
		return nil, "duplicate"
	end
	local key = PlayerDataSchema.BestTimeKey(ctx.worldId, ctx.layoutVersion, ctx.seedClass, ctx.mode)
	local previous = data.bestTimes[key]
	local validTime = result.finished and result.active and type(result.seconds) == "number" and result.seconds >= (ctx.minPlausibleSeconds or 8)
	local isPb = validTime and (previous == nil or result.seconds < previous)

	local botRacesToday = 0
	if result.botPractice and data.botPractice.day == ctx.utcDay then
		botRacesToday = data.botPractice.races
	end
	local reward = ProgressionConfig.RaceReward({
		finished = result.finished,
		place = result.place,
		count = result.count,
		active = result.active,
		checkpoint = result.checkpoint,
		progressFraction = result.progressFraction,
		personalBest = isPb,
		botPractice = result.botPractice,
		botRacesToday = botRacesToday,
	})

	local levelBefore = (ProgressionConfig.LevelForXp(data.xp))
	data.coins = data.coins + reward.coins
	data.xp = data.xp + reward.xp
	local levelAfter, into, nextCost = ProgressionConfig.LevelForXp(data.xp)
	data.level = levelAfter
	data.raceCount = data.raceCount + 1
	if result.finished and result.active then
		if result.place == 1 then
			data.winCount = data.winCount + 1
		end
		if result.place <= 3 then
			data.podiumCount = data.podiumCount + 1
		end
	end
	if isPb then
		data.bestTimes[key] = result.seconds
	end
	if result.botPractice then
		data.botPractice = { day = ctx.utcDay, races = botRacesToday + 1 }
	end
	PlayerDataSchema.LedgerAdd(data, raceId)

	return {
		raceId = raceId,
		coins = reward.coins,
		xp = reward.xp,
		lines = reward.lines,
		multiplierNote = reward.multiplierNote,
		totalCoins = data.coins,
		levelBefore = levelBefore,
		level = levelAfter,
		levelUp = levelAfter > levelBefore,
		xpIntoLevel = into,
		xpForNext = nextCost,
		finished = result.finished == true,
		place = result.place,
		count = result.count,
		seconds = result.seconds,
		pb = {
			key = key,
			isNew = isPb == true,
			previous = previous, -- nil = first valid time on this exact configuration
			seconds = validTime and result.seconds or nil,
			comparable = previous ~= nil and validTime == true,
		},
	}
end

return RewardRules
