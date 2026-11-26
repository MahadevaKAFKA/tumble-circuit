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

-- READY vote (owner request 2026-11-25) --------------------------------------------------------
-- How many queued players make the race "full": every grid slot taken, or every server slot taken
-- if the server is smaller than the grid (then nobody else can join). override > 0 replaces it.
function RaceRules.RaceCapacity(gridSlots, maxPlayers, override)
	if override and override > 0 then
		return math.floor(override)
	end
	local capacity = gridSlots
	if maxPlayers and maxPlayers > 0 then
		capacity = math.min(capacity, maxPlayers)
	end
	return math.max(1, capacity)
end

-- open: the vote is offered (race full). allReady: every queued player voted, so start now.
function RaceRules.ReadyVote(queuedCount, readyCount, capacity)
	local open = queuedCount > 0 and queuedCount >= capacity
	return {
		open = open,
		allReady = open and readyCount >= queuedCount,
		ready = open and math.min(readyCount, queuedCount) or 0,
		needed = queuedCount,
		capacity = capacity,
	}
end

-- challenges brief (rival gap): insert a crossing { time, ... } into one gate's time-ordered
-- list (monitor samples can arrive slightly out of order). Returns the place at that gate, the
-- crossing just ahead (nil when first) and the one just behind (nil when last so far).
function RaceRules.GateCrossing(list, entry)
	local i = #list + 1
	while i > 1 and list[i - 1].time > entry.time do
		i = i - 1
	end
	table.insert(list, i, entry)
	return i, list[i - 1], list[i + 1]
end

-- challenges brief: the one-line post-race story (pure). info = { place, field, grid,
-- finished, recoveries, laps = {lap seconds}, ledGates, gates, bestGain }. Says what happened,
-- never invents: every clause comes from server-judged data.
local function lapTime(seconds)
	local m = math.floor(seconds / 60)
	return string.format("%d:%04.1f", m, seconds - m * 60)
end
RaceRules.StoryLapTime = lapTime

function RaceRules.StoryLine(info)
	if type(info) ~= "table" or type(info.place) ~= "number" then
		return nil
	end
	local place, grid = info.place, info.grid
	local recoveries = info.recoveries or 0
	local parts = {}
	if not info.finished then
		parts[1] = recoveries > 0 and string.format("Out of time after %d recover%s", recoveries, recoveries == 1 and "y" or "ies") or "Out of time - the clock beat you this one"
	elseif place == 1 and info.gates and info.gates > 0 and info.ledGates == info.gates then
		parts[1] = "Led every gate, start to finish"
	elseif place == 1 and grid and grid > 1 then
		parts[1] = string.format("From P%d on the grid to the win", grid)
	elseif place == 1 then
		parts[1] = "Took the win"
	elseif grid and grid - place >= 2 then
		parts[1] = string.format("Climbed from P%d to P%d", grid, place)
	elseif grid and place - grid >= 2 then
		parts[1] = string.format("Started P%d, finished P%d%s", grid, place, recoveries > 0 and string.format(" - %d recover%s cost you", recoveries, recoveries == 1 and "y" or "ies") or "")
	else
		parts[1] = string.format("Finished P%d of %d", place, info.field or place)
	end
	if info.finished and recoveries == 0 then
		parts[#parts + 1] = "clean race"
	elseif info.finished and (info.bestGain or 0) >= 2 then
		parts[#parts + 1] = string.format("+%d places at one gate", info.bestGain)
	end
	local laps = info.laps
	if type(laps) == "table" and #laps >= 2 then
		local best, at = math.huge, 1
		for i, t in ipairs(laps) do
			if type(t) == "number" and t < best then
				best, at = t, i
			end
		end
		if best < math.huge then
			parts[#parts + 1] = string.format("best lap %s (lap %d)", lapTime(best), at)
		end
	end
	return table.concat(parts, "  ·  ")
end

return RaceRules
