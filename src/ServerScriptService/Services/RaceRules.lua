--[[
	RaceRules — pure race-judging rules (no services), shared by CheckpointService, ProgressService
	and RoundService, and executed by the offline tests.

	Placement (ADR-09/ADR-11 ready): finishers first by finish ordinal; then racers by confirmed
	checkpoint index, then route distance; DNF last; ties always broken by a stable join ordinal.
	Never by height.
]]

local RaceRules = {}

-- Fraction (0..1] along a sample where progress crossed `target` going forward, or nil.
function RaceRules.CrossingFraction(sPrev, sNow, target)
	if sPrev == nil or sNow == nil or sNow <= sPrev then
		return nil
	end
	if sPrev < target and sNow >= target then
		return (target - sPrev) / (sNow - sPrev)
	end
	return nil
end

function RaceRules.InterpolateTime(tPrev, tNow, fraction)
	return tPrev + (tNow - tPrev) * fraction
end

-- Was route distance deltaS covered in deltaT plausibly (<= terminal * factor, small slack)?
function RaceRules.IsPlausibleSegment(deltaS, deltaT, terminalSpeed, factor)
	if deltaT <= 0 then
		return deltaS <= 10
	end
	return deltaS <= terminalSpeed * factor * deltaT + 10
end

-- Teleport audit over a sliding window.
function RaceRules.ExceedsEnvelope(distance, seconds, terminalSpeed, factor, slack)
	return distance > terminalSpeed * factor * math.max(seconds, 0) + slack
end

function RaceRules.WithinCorridor(distanceFromCentre, halfWidth, extra)
	return distanceFromCentre <= halfWidth + extra
end

-- Strict weak ordering for standings entries:
-- { finished, finishOrdinal, dnf, checkpoint, progressS, ordinal }
function RaceRules.CompareStandings(a, b)
	if a.finished ~= b.finished then
		return a.finished == true
	end
	if a.finished then
		if a.finishOrdinal ~= b.finishOrdinal then
			return a.finishOrdinal < b.finishOrdinal
		end
		return a.ordinal < b.ordinal
	end
	if (a.dnf == true) ~= (b.dnf == true) then
		return b.dnf == true
	end
	if a.checkpoint ~= b.checkpoint then
		return a.checkpoint > b.checkpoint
	end
	if a.progressS ~= b.progressS then
		return a.progressS > b.progressS
	end
	return a.ordinal < b.ordinal
end

function RaceRules.SortStandings(entries)
	table.sort(entries, RaceRules.CompareStandings)
	for i, entry in ipairs(entries) do
		entry.place = i
	end
	return entries
end

-- Order simultaneous finishes inside one server sample: earlier interpolated crossing time wins,
-- then the stable ordinal. Returns the list sorted in place.
function RaceRules.OrderFinishes(events)
	table.sort(events, function(a, b)
		if a.time ~= b.time then
			return a.time < b.time
		end
		return a.ordinal < b.ordinal
	end)
	return events
end

-- Deterministic grid shuffle (Park-Miller LCG seeded by roundId) so slot order is fair and
-- reproducible in tests. `ids` is an array of numbers; returns a new array.
function RaceRules.ShuffleGrid(ids, seed)
	local out = {}
	for i, id in ipairs(ids) do
		out[i] = id
	end
	table.sort(out)
	local state = (math.floor(seed) % 2147483646) + 1
	for i = #out, 2, -1 do
		state = (state * 48271) % 2147483647
		local j = (state % i) + 1
		out[i], out[j] = out[j], out[i]
	end
	return out
end

-- A4 (ADR-08): how many bots join a round. Bots only ever fill a round that has humans, up to
-- fillTo racers and never past the grid's slot count.
function RaceRules.BotFillCount(humans, slots, fillTo, enabled)
	if not enabled or humans <= 0 then
		return 0
	end
	return math.max(0, math.min(fillTo, slots) - humans)
end

return RaceRules
