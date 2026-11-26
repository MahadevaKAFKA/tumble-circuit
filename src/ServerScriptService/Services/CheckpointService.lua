--[[
	CheckpointService — server-observed, ordered checkpoints and finish (ADR-04).

	A crossing counts only when, inside ONE monitor sample, route progress sweeps continuously
	across the next target (no jump larger than the speed envelope allows), the marble is inside
	the corridor, and the route distance since the previous confirmed crossing was covered
	plausibly. Crossing time is interpolated inside the sample. Respawns never create crossings
	(the first sample after a spawn has no previous progress), and the next target is always the
	next unconfirmed checkpoint, so nothing can be skipped. The client sends nothing here.

	2026-11-26 three-lap circuits: the targets are the layout's ordered TARGET list in race S
	(TrackDefinitions.Targets): every lap's checkpoints, the start/finish line between laps
	("Lap" events with the lap time) and the finish after the last lap. Progress is the tracker's
	unwrapped race S, so the same swept-crossing rules judge laps: a backwards or early line
	crossing never matches the next target, and a lap cannot count without its gates.
	`laps` (optional) overrides the layout's lap count (Time Trial = 1 lap).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local PhysicsConfig = require(Shared:WaitForChild("PhysicsConfig"))
local RaceConfig = require(Shared:WaitForChild("RaceConfig"))
local RaceRules = require(script.Parent:WaitForChild("RaceRules"))
local TrackDefinitions = require(Shared:WaitForChild("TrackDefinitions"))

local CheckpointService = {}
CheckpointService.__index = CheckpointService

function CheckpointService.new(trackService, laps)
	local self = setmetatable({}, CheckpointService)
	self.track = trackService
	self.laps = laps
	self.racers = {}
	self.active = false
	return self
end

-- The ordered targets for the active layout (cached per layout + lap count)
function CheckpointService:Targets()
	local layout = self.track:GetLayout("Race")
	if not layout.Loop or not self.laps or self.laps == layout.Laps then
		return layout.Targets or {}, layout
	end
	if self._targetsFor ~= layout then
		self._targetsFor = layout
		self._targets = TrackDefinitions.Targets(layout, self.laps)
	end
	return self._targets, layout
end

-- starts: { [player] = startS } (the racer's grid slot progress)
function CheckpointService:BeginRound(starts, startClock)
	self.racers = {}
	self.active = true
	self.startClock = startClock
	for player, startS in pairs(starts) do
		self.racers[player] = { confirmed = 0, lastCrossS = startS, lastCrossTime = startClock, finished = false, rejections = 0, lapStart = startClock, laps = {} }
	end
end

function CheckpointService:EndRound()
	self.active = false
	self.racers = {}
end

function CheckpointService:RemoveRacer(player)
	self.racers[player] = nil
end

function CheckpointService:GetConfirmed(player)
	local racer = self.racers[player]
	return racer and racer.confirmed or 0
end

function CheckpointService:IsFinished(player)
	local racer = self.racers[player]
	return racer ~= nil and racer.finished
end

-- The last confirmed target (nil before the first) - respawns use its RespawnFrame / race S.
function CheckpointService:GetConfirmedTarget(player)
	local racer = self.racers[player]
	local targets = self:Targets()
	return racer and racer.confirmed > 0 and targets[racer.confirmed] or nil
end

-- Completed lap times (seconds, in order) for the HUD and results.
function CheckpointService:GetLapTimes(player)
	local racer = self.racers[player]
	return racer and racer.laps or {}
end

-- The progress value standings may use: never beyond the next unconfirmed target.
function CheckpointService:CapProgress(player, s)
	local racer = self.racers[player]
	if not racer then
		return 0
	end
	local targets = self:Targets()
	local nextTarget = targets[racer.confirmed + 1]
	local cap = nextTarget and nextTarget.S or (targets[#targets] and targets[#targets].S) or s
	return math.min(s, cap)
end

-- Returns a list of events: {kind="Checkpoint", index, time} | {kind="Finish", time, seconds}
-- | {kind="Rejected", reason}
function CheckpointService:Process(player, info)
	local racer = self.racers[player]
	if not self.active or not racer or racer.finished or info.prevS == nil or info.frozen then
		return nil
	end
	local targets = self:Targets()
	local terminal = PhysicsConfig.Movement.TerminalSpeed
	local factor = RaceConfig.Validation.PlausibleSpeedFactor
	local dt = info.time - info.prevTime
	-- swept-continuity: progress may not jump more than the envelope allows in one sample
	if info.s - info.prevS > terminal * factor * math.max(dt, 0) + 10 then
		return { { kind = "Rejected", reason = "progress jump" } }
	end
	local events = nil
	while true do
		local index = racer.confirmed + 1
		local goal = targets[index]
		if not goal then
			break
		end
		local target = goal.S
		local fraction = RaceRules.CrossingFraction(info.prevS, info.s, target)
		if not fraction then
			break
		end
		events = events or {}
		if not RaceRules.WithinCorridor(info.distance, info.halfWidth, RaceConfig.Validation.CorridorExtra) then
			table.insert(events, { kind = "Rejected", reason = "outside corridor" })
			break
		end
		local t = RaceRules.InterpolateTime(info.prevTime, info.time, fraction)
		if not RaceRules.IsPlausibleSegment(target - racer.lastCrossS, t - racer.lastCrossTime, terminal, factor) then
			racer.rejections = racer.rejections + 1
			table.insert(events, { kind = "Rejected", reason = "implausible split" })
			break
		end
		racer.lastCrossS = target
		racer.lastCrossTime = t
		racer.confirmed = index
		if goal.Kind == "Checkpoint" then
			table.insert(events, { kind = "Checkpoint", index = index, checkpoint = goal.Checkpoint, lap = goal.Lap, time = t })
		elseif goal.Kind == "Lap" then
			racer.laps[#racer.laps + 1] = t - racer.lapStart
			racer.lapStart = t
			table.insert(events, { kind = "Lap", index = index, lap = goal.Lap, time = t, lapSeconds = racer.laps[#racer.laps] })
		else
			if targets[index].Lap > 1 or #racer.laps > 0 then
				racer.laps[#racer.laps + 1] = t - racer.lapStart
			end
			racer.finished = true
			racer.finishSeconds = t - self.startClock
			table.insert(events, { kind = "Finish", time = t, seconds = racer.finishSeconds, laps = racer.laps })
			break
		end
	end
	return events
end

return CheckpointService
