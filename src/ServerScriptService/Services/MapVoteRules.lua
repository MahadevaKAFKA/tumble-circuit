--[[
	MapVoteRules (B1) — pure rules for picking the next race world. No Roblox APIs.
	- Rotation: worlds in order; the next is the one after the last raced (wraps).
	- A vote runs in the first VoteSeconds of Intermission only when >= MinHumans queued humans
	  and > 1 world exist. Only queued humans vote, one vote each (no changing), option index
	  1..#options. Bots never vote.
	- Winner: most votes. Tie → the tied world that comes first in rotation order starting at
	  the rotation candidate (deterministic, everyone sees the same result). No votes → the
	  rotation candidate.
]]

local MapVoteRules = {}

MapVoteRules.VoteSeconds = 8
MapVoteRules.MinHumans = 2

-- index of the world after `lastIndex` in a list of `count` worlds
function MapVoteRules.NextInRotation(lastIndex, count)
	if count <= 0 then
		return nil
	end
	if not lastIndex or lastIndex < 1 or lastIndex > count then
		return 1
	end
	return lastIndex % count + 1
end

function MapVoteRules.ShouldOpen(queuedHumans, worldCount)
	return queuedHumans >= MapVoteRules.MinHumans and worldCount > 1
end

function MapVoteRules.NewVote(options, rotationIndex, now)
	local counts = {}
	for i = 1, #options do
		counts[i] = 0
	end
	return { open = true, options = options, rotationIndex = rotationIndex, endsAt = now + MapVoteRules.VoteSeconds, votes = {}, counts = counts }
end

-- returns accepted:boolean, reason:string
function MapVoteRules.Cast(vote, voterId, optionIndex, isQueuedHuman, now)
	if not vote or not vote.open then
		return false, "closed"
	end
	if now >= vote.endsAt then
		return false, "closed"
	end
	if not isQueuedHuman then
		return false, "not_eligible"
	end
	if type(optionIndex) ~= "number" or optionIndex ~= math.floor(optionIndex) or optionIndex < 1 or optionIndex > #vote.options then
		return false, "bad_option"
	end
	if vote.votes[voterId] then
		return false, "already_voted"
	end
	vote.votes[voterId] = optionIndex
	vote.counts[optionIndex] = vote.counts[optionIndex] + 1
	return true, "ok"
end

-- a voter left: their vote no longer counts
function MapVoteRules.Remove(vote, voterId)
	local option = vote and vote.votes[voterId]
	if option then
		vote.votes[voterId] = nil
		vote.counts[option] = math.max(0, vote.counts[option] - 1)
	end
end

function MapVoteRules.Winner(vote)
	local n = #vote.options
	local best, bestIndex = 0, vote.rotationIndex
	for step = 0, n - 1 do
		local i = (vote.rotationIndex - 1 + step) % n + 1
		local c = vote.counts[i] or 0
		if c > best then
			best, bestIndex = c, i
		end
	end
	return bestIndex, best
end

return MapVoteRules
