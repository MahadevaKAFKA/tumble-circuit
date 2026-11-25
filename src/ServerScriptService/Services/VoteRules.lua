--[[
	VoteRules (A6) — pure Chaos Vote logic (master section 6):
	  * eligible voters: humans who are NOT active racers (finished racers, late joiners, people
	    sitting out). Bots never vote (they have no client).
	  * a poll opens every IntervalSeconds of Racing when >= 1 eligible voter and >= 1 active
	    racer exist and enough race time is left; one vote per voter per poll; votes for a
	    closed / different poll are refused.
	  * tally: most votes wins; a tie alternates deterministically by poll id (odd -> option 1,
	    even -> option 2); zero votes -> nothing happens.
]]

local VoteRules = {}

function VoteRules.Eligible(voter)
	return voter.isHuman == true and voter.isActiveRacer ~= true
end

function VoteRules.ShouldOpen(ctx, cfg)
	if ctx.state ~= "Racing" or ctx.pollOpen then
		return false
	end
	if ctx.eligible < 1 or ctx.activeRacers < 1 then
		return false
	end
	if ctx.secondsLeft < cfg.WindowSeconds + cfg.LeadSeconds + cfg.DurationSeconds or ctx.secondsLeft < cfg.MinSecondsLeft then
		return false
	end
	local since = ctx.lastPollAt and (ctx.now - ctx.lastPollAt) or ctx.raceElapsed
	return since >= cfg.IntervalSeconds and ctx.modifierBusyUntil <= ctx.now
end

function VoteRules.NewPoll(id, now, cfg)
	return { id = id, opensAt = now, closesAt = now + cfg.WindowSeconds, votes = {}, counts = {}, open = true, optionCount = #cfg.Options }
end

-- Returns ok, reason.
function VoteRules.Cast(poll, voterKey, pollId, option, now)
	if not poll or not poll.open then
		return false, "no open poll"
	end
	if pollId ~= poll.id then
		return false, "stale poll"
	end
	if now >= poll.closesAt then
		return false, "closed"
	end
	if type(option) ~= "number" or option < 1 or option > poll.optionCount or option % 1 ~= 0 then
		return false, "bad option"
	end
	if poll.votes[voterKey] then
		return false, "already voted"
	end
	poll.votes[voterKey] = option
	poll.counts[option] = (poll.counts[option] or 0) + 1
	return true
end

-- Returns winning option index or nil (no votes).
function VoteRules.Tally(poll)
	local best, bestCount, tie = nil, 0, false
	for option = 1, poll.optionCount do
		local c = poll.counts[option] or 0
		if c > bestCount then
			best, bestCount, tie = option, c, false
		elseif c == bestCount and c > 0 then
			tie = true
		end
	end
	if not best then
		return nil
	end
	if tie then
		return (poll.id % 2 == 1) and 1 or 2
	end
	return best
end

return VoteRules
