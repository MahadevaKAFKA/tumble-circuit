--[[
	TimeTrialRules (B1) — pure rules for solo Time Trials and their PB ghosts. No Roblox APIs.
	- Who may start: not in the current round, not while the grid is filling (Preparing /
	  Countdown), not twice at once.
	- A run counts only from server-judged checkpoints in order and a finish crossing (the same
	  CheckpointService as races); times under MinSeconds are never a best.
	- Ghost: server-observed positions sampled every 1/GhostHz s of the run, rounded to 0.1
	  stud, capped at MaxSeconds × GhostHz points. Only a new PB replaces the stored ghost.
]]

local TimeTrialRules = {}

TimeTrialRules.CountdownSeconds = 3
TimeTrialRules.MaxSeconds = 180
TimeTrialRules.MinSeconds = 8
TimeTrialRules.GhostHz = 5
TimeTrialRules.ReturnDelaySeconds = 3
TimeTrialRules.Mode = "TimeTrial"

function TimeTrialRules.CanStart(ctx)
	if ctx.running then
		return false, "Already in a Time Trial"
	end
	if ctx.inRound then
		return false, "You're in this race - Time Trial after it"
	end
	if ctx.state == "Preparing" or ctx.state == "Countdown" then
		return false, "Racers are on the grid - try again in a moment"
	end
	return true, nil
end

function TimeTrialRules.IsBetter(seconds, previous)
	if type(seconds) ~= "number" or seconds ~= seconds or seconds < TimeTrialRules.MinSeconds then
		return false
	end
	return previous == nil or seconds < previous
end

local function round1(x)
	return math.floor(x * 10 + 0.5) / 10
end

-- recorder: { points = {x,y,z,...}, nextAt = 0 }; t = seconds since the run started
function TimeTrialRules.NewRecorder()
	return { points = {}, nextAt = 0, count = 0 }
end

function TimeTrialRules.Record(recorder, t, position)
	local cap = TimeTrialRules.MaxSeconds * TimeTrialRules.GhostHz + 1
	if t + 1e-9 < recorder.nextAt or recorder.count >= cap then
		return false
	end
	local p = recorder.points
	p[#p + 1] = round1(position.X)
	p[#p + 1] = round1(position.Y)
	p[#p + 1] = round1(position.Z)
	recorder.count = recorder.count + 1
	recorder.nextAt = recorder.count / TimeTrialRules.GhostHz
	return true
end

function TimeTrialRules.GhostPayload(recorder, seconds, key)
	return { v = 1, key = key, seconds = seconds, hz = TimeTrialRules.GhostHz, points = recorder.points }
end

-- a stored ghost is used only if it is well-formed and matches the key (layout + seed + mode)
function TimeTrialRules.ValidGhost(ghost, key)
	if type(ghost) ~= "table" or ghost.v ~= 1 or ghost.key ~= key or type(ghost.points) ~= "table" then
		return false
	end
	local n = #ghost.points
	return n >= 6 and n % 3 == 0 and n <= (TimeTrialRules.MaxSeconds * TimeTrialRules.GhostHz + 1) * 3 and type(ghost.seconds) == "number"
end

-- ghost position at time t (linear between samples); nil before/after
function TimeTrialRules.GhostAt(ghost, t)
	local p = ghost.points
	local count = #p / 3
	if t < 0 or count < 2 then
		return nil
	end
	local f = t * ghost.hz
	local i = math.floor(f)
	if i >= count - 1 then
		return nil
	end
	local a = f - i
	local function at(k, c)
		return p[k * 3 + c]
	end
	return at(i, 1) + (at(i + 1, 1) - at(i, 1)) * a, at(i, 2) + (at(i + 1, 2) - at(i, 2)) * a, at(i, 3) + (at(i + 1, 3) - at(i, 3)) * a
end

return TimeTrialRules
