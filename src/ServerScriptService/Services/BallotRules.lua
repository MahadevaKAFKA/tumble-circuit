--[[
	BallotRules (promo pack prompt 03) — "Vote for Next Race". Pure rules, no Roblox APIs.

	One ballot box per upcoming round; its epoch is that round's id. A ballot can be cast or
	changed any time before the box resolves (at the start of Preparing), from any hub, during
	another race, or on the results screen: the latest valid ballot per player is the one that
	counts. Requests carry (epoch, seq):
	  * epoch ~= box epoch       -> "stale"      (sent for a race that has already been decided)
	  * seq <= the player's last -> "duplicate"  (a repeated / out-of-order request)
	  * map not eligible         -> "bad_map"    (not built, failed validation, or gated)
	Resolution counts only ballots from voters that are still connected AND queued for this race
	(bots never vote), only for eligible maps. Winner = most ballots; a tie goes to the tied map
	that comes first in rotation order starting at the rotation candidate; no ballots = the
	rotation candidate. Same inputs -> same winner on every server.
]]

local BallotRules = {}

BallotRules.MaxMaps = 16

function BallotRules.NewBox(epoch)
	return { epoch = epoch, ballots = {}, resolved = false }
end

-- eligible = { [mapId] = true }
function BallotRules.Cast(box, voterId, mapId, epoch, seq, eligible)
	if not box or box.resolved then
		return false, "closed"
	end
	if epoch ~= box.epoch then
		return false, "stale"
	end
	if type(seq) ~= "number" or seq ~= math.floor(seq) or seq < 1 then
		return false, "bad_seq"
	end
	if type(mapId) ~= "string" or not (eligible and eligible[mapId]) then
		return false, "bad_map"
	end
	local previous = box.ballots[voterId]
	if previous and seq <= previous.seq then
		return false, "duplicate"
	end
	box.ballots[voterId] = { mapId = mapId, seq = seq }
	if previous and previous.mapId == mapId then
		return true, "same"
	end
	return true, previous and "changed" or "ok"
end

function BallotRules.Remove(box, voterId)
	if box then
		box.ballots[voterId] = nil
	end
end

-- counts[i] for mapIds[i]; voters = { [voterId] = true } (connected + queued humans)
function BallotRules.Tally(box, voters, mapIds)
	local counts, indexOf = {}, {}
	for i, id in ipairs(mapIds) do
		counts[i] = 0
		indexOf[id] = i
	end
	local counted = 0
	if box then
		for voterId, ballot in pairs(box.ballots) do
			local i = indexOf[ballot.mapId]
			if i and voters[voterId] then
				counts[i] = counts[i] + 1
				counted = counted + 1
			end
		end
	end
	return counts, counted
end

-- Winner index into mapIds. rotationIndex = the map the rotation would pick (1..#mapIds).
function BallotRules.Winner(counts, rotationIndex)
	local n = #counts
	if n == 0 then
		return nil
	end
	if not rotationIndex or rotationIndex < 1 or rotationIndex > n then
		rotationIndex = 1
	end
	local best, winner = 0, rotationIndex
	for step = 0, n - 1 do
		local i = (rotationIndex - 1 + step) % n + 1
		if counts[i] > best then
			best, winner = counts[i], i
		end
	end
	return winner
end

-- Close the box and pick the map. Returns winnerIndex, counts, counted.
function BallotRules.Resolve(box, voters, mapIds, rotationIndex)
	local counts, counted = BallotRules.Tally(box, voters, mapIds)
	if box then
		box.resolved = true
	end
	return BallotRules.Winner(counts, rotationIndex), counts, counted
end

-- The ballot map index each counted voter chose (for the snapshot): { [tostring(id)] = index }
function BallotRules.Choices(box, voters, mapIds)
	local indexOf, out = {}, {}
	for i, id in ipairs(mapIds) do
		indexOf[id] = i
	end
	if box then
		for voterId, ballot in pairs(box.ballots) do
			if voters[voterId] and indexOf[ballot.mapId] then
				out[tostring(voterId)] = indexOf[ballot.mapId]
			end
		end
	end
	return out
end

return BallotRules
