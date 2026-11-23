--[[
	CheckpointService — server-observed, ordered checkpoints and finish (ADR-04).

	A crossing counts only when, inside ONE monitor sample, route progress sweeps continuously
	across the next target (no jump larger than the speed envelope allows), the marble is inside
	the corridor, and the route distance since the previous confirmed crossing was covered
	plausibly. Crossing time is interpolated inside the sample. Respawns never create crossings
	(the first sample after a spawn has no previous progress), and the next target is always the
	next unconfirmed checkpoint, so nothing can be skipped. The client sends nothing here.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local PhysicsConfig = require(Shared:WaitForChild("PhysicsConfig"))
local RaceConfig = require(Shared:WaitForChild("RaceConfig"))
local RaceRules = require(script.Parent:WaitForChild("RaceRules"))

local CheckpointService = {}
CheckpointService.__index = CheckpointService

function CheckpointService.new(trackService)
	local self = setmetatable({}, CheckpointService)
	self.track = trackService
	self.racers = {}
	self.active = false
	return self
end

-- starts: { [player] = startS } (the racer's grid slot progress)
function CheckpointService:BeginRound(starts, startClock)
	self.racers = {}
	self.active = true
	self.startClock = startClock
	for player, startS in pairs(starts) do
		self.racers[player] = { confirmed = 0, lastCrossS = startS, lastCrossTime = startClock, finished = false, rejections = 0 }
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

-- The progress value standings may use: never beyond the next unconfirmed target.
function CheckpointService:CapProgress(player, s)
	local racer = self.racers[player]
	local layout = self.track:GetLayout("Race")
	if not racer then
		return 0
	end
	local nextCp = layout.Checkpoints[racer.confirmed + 1]
	local cap = nextCp and nextCp.S or layout.FinishLineS
	return math.min(s, cap)
end

-- Returns a list of events: {kind="Checkpoint", index, time} | {kind="Finish", time, seconds}
-- | {kind="Rejected", reason}
function CheckpointService:Process(player, info)
	local racer = self.racers[player]
	if not self.active or not racer or racer.finished or info.prevS == nil or info.frozen then
		return nil
	end
	local layout = self.track:GetLayout("Race")
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
		local cp = layout.Checkpoints[index]
		local target = cp and cp.S or layout.FinishLineS
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
		if cp then
			racer.confirmed = index
			table.insert(events, { kind = "Checkpoint", index = index, time = t })
		else
			racer.finished = true
			racer.finishSeconds = t - self.startClock
			table.insert(events, { kind = "Finish", time = t, seconds = racer.finishSeconds })
			break
		end
	end
	return events
end

return CheckpointService
