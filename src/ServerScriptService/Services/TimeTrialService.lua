--[[
	TimeTrialService (B1) — solo Time Trials on the active world, with a server-recorded PB ghost.
	- RequestTimeTrial(true) starts (if TimeTrialRules.CanStart), RequestTimeTrial(false) quits.
	  Starting sits you out of the next race (JOIN RACE again any time; that ends the trial).
	- The marble is placed just past the start gate, frozen for 3 s, then released as a fresh
	  marble (same path as GO). It stays in the TC_Protected group for the whole run: it never
	  touches racers. Abilities and tricks are off (they need an active racer).
	- A private CheckpointService judges the run exactly like a race (ordered checkpoints,
	  plausible sweeps). Falls respawn at the last confirmed checkpoint.
	- Best time: profile.bestTimes[world|layout|seed|TimeTrial] (never mixed with races). No
	  Coins or XP (nothing to farm). On a new best, the server's own samples of the run become the
	  ghost, stored in DataStore TumbleGhosts_v1 (memory in Studio mock mode).
	- Aborted, with the reason, when the course changes, after 180 s, or when you leave.
]]

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlayerDataSchema = require(Shared:WaitForChild("PlayerDataSchema"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local RaceConfig = require(Shared:WaitForChild("RaceConfig"))
local RoundProtocol = require(Shared:WaitForChild("RoundProtocol"))
local TimeTrialRules = require(Shared:WaitForChild("TimeTrialRules"))
local Utility = require(Shared:WaitForChild("Utility"))
local CheckpointService = require(script.Parent:WaitForChild("CheckpointService"))

local TimeTrialService = {}
TimeTrialService.__index = TimeTrialService

local ZONES = Protocol.Zones
local REASONS = Protocol.SpawnReasons

function TimeTrialService.new(deps)
	local self = setmetatable({}, TimeTrialService)
	self.track = deps.track
	self.marbles = deps.marbles
	self.physics = deps.physics
	self.round = deps.round
	self.remotes = deps.remotes
	self.data = deps.data
	self.hazards = deps.hazards
	self.runs = {} -- [player] = run
	self.memoryGhosts = {} -- Studio mock / no DataStore
	self.maid = Utility.Maid.new()
	self.store = nil
	return self
end

function TimeTrialService:_ghostStore()
	if self.store == false then
		return nil
	end
	if self.store == nil then
		local live = self.data and self.data.GetMode and self.data:GetMode() == "Live"
		if not live then
			self.store = false
			return nil
		end
		local ok, store = pcall(function()
			return DataStoreService:GetDataStore("TumbleGhosts_v1")
		end)
		self.store = ok and store or false
	end
	return self.store or nil
end

function TimeTrialService:_send(player, payload)
	local remote = self.remotes:FindFirstChild("TimeTrialState")
	if remote and player.Parent then
		payload.serverTime = workspace:GetServerTimeNow()
		remote:FireClient(player, payload)
	end
end

function TimeTrialService:IsRunning(player)
	return self.runs[player] ~= nil
end

-- circuits: a Time Trial is RaceConfig.TimeTrialLaps laps (1 by default) - its record key
-- carries the lap count when it is not 1 lap, so 1-lap and full-race trials never mix
function TimeTrialService:_laps()
	local layout = self.track:GetLayout(ZONES.Race)
	return layout.Loop and (RaceConfig.TimeTrialLaps or 1) or nil
end

function TimeTrialService:_key()
	local def = self.track:GetLayout(ZONES.Race).Definition
	local seed = self.hazards and self.hazards:GetSeed() or 0
	local laps = self:_laps()
	local mode = TimeTrialRules.Mode .. ((laps and laps > 1) and (laps .. "L") or "")
	return PlayerDataSchema.BestTimeKey(def.Id, def.LayoutVersion, seed, mode), def
end

-- RoundService asks this first for a Time Trial marble's race S (circuits)
function TimeTrialService:ProgressHint(player)
	local run = self.runs[player]
	if not run then
		return nil
	end
	local target = run.phase == "Running" and run.judge:GetConfirmedTarget(player) or nil
	if target then
		return target.S + RaceConfig.Recovery.CheckpointRespawnAhead
	end
	return run.startS
end

function TimeTrialService:StartTrial(player)
	local ok, reason = TimeTrialRules.CanStart({
		running = self.runs[player] ~= nil,
		inRound = self.round.racerByPlayer[player] ~= nil,
		state = self.round:GetState(),
	})
	if not ok then
		self:_send(player, { phase = "Refused", reason = reason })
		return false
	end
	self.round:TryJoin(player, false) -- a Time Trial sits you out of the next race
	local key, def = self:_key()
	local cf, startS = self.track:GetTimeTrialStart()
	local profile = self.data and self.data:GetProfile(player)
	local run = {
		key = key,
		worldId = def.Id,
		worldName = def.DisplayName,
		startCFrame = cf,
		startS = startS,
		phase = "Countdown",
		goAt = workspace:GetServerTimeNow() + TimeTrialRules.CountdownSeconds,
		judge = CheckpointService.new(self.track, self:_laps()),
		recorder = TimeTrialRules.NewRecorder(),
		best = profile and profile.data.bestTimes[key] or nil,
	}
	self.runs[player] = run
	self.marbles:SpawnMarble(player, REASONS.TimeTrial)
	self:_send(player, { phase = "Countdown", goAt = run.goAt, world = run.worldName, best = run.best, total = #self.track:GetLayout(ZONES.Race).Checkpoints })
	task.spawn(function()
		self:_sendGhost(player, run)
	end)
	task.delay(TimeTrialRules.CountdownSeconds, function()
		if self.runs[player] == run and run.phase == "Countdown" then
			run.phase = "Running"
			run.startClock = os.clock()
			run.judge:BeginRound({ [player] = run.startS }, run.startClock)
			self.marbles:Release(player)
			self:_send(player, { phase = "Running", startedAt = workspace:GetServerTimeNow() })
		end
	end)
	return true
end

function TimeTrialService:_sendGhost(player, run)
	local ghost = self.memoryGhosts[tostring(player.UserId) .. "|" .. run.key]
	local store = self:_ghostStore()
	if not ghost and store then
		local ok, value = pcall(function()
			return store:GetAsync(tostring(player.UserId) .. "|" .. run.key)
		end)
		ghost = ok and value or nil
	end
	if self.runs[player] == run and TimeTrialRules.ValidGhost(ghost, run.key) then
		local remote = self.remotes:FindFirstChild("GhostPath")
		if remote and player.Parent then
			remote:FireClient(player, ghost)
		end
	end
end

function TimeTrialService:Stop(player, reason)
	local run = self.runs[player]
	if not run then
		return
	end
	self.runs[player] = nil
	run.judge:EndRound()
	self:_send(player, { phase = "Ended", reason = reason })
	if player.Parent and self.marbles:GetZone(player) == ZONES.Race then
		self.marbles:SpawnMarble(player, REASONS.ToHub)
	end
end

-- Spawn resolver hook (RoundService asks first): nil = not a Time Trial spawn.
function TimeTrialService:ResolveSpawn(player, reason)
	local run = self.runs[player]
	if not run or reason == REASONS.ToHub then
		return nil
	end
	if run.phase == "Countdown" then
		return { CFrame = run.startCFrame, Zone = ZONES.Race, Frozen = true, Ghost = true }
	end
	if run.phase == "Running" then
		local target = run.judge:GetConfirmedTarget(player)
		local cf = target and target.RespawnFrame and self.track:FrameCFrame(target.RespawnFrame) or run.startCFrame
		return { CFrame = cf, Zone = ZONES.Race, Frozen = false, Ghost = true }
	end
	return nil
end

function TimeTrialService:_onProgress(player, info)
	local run = self.runs[player]
	if not run or run.phase ~= "Running" or info.zone ~= ZONES.Race then
		return
	end
	local t = os.clock() - run.startClock
	if t > TimeTrialRules.MaxSeconds then
		self:Stop(player, "Time limit (180 s)")
		return
	end
	if info.position and not info.frozen then
		TimeTrialRules.Record(run.recorder, t, info.position)
	end
	for _, event in ipairs(run.judge:Process(player, info) or {}) do
		if event.kind == "Checkpoint" then
			self:_send(player, { phase = "Checkpoint", index = event.checkpoint or event.index, total = #self.track:GetLayout(ZONES.Race).Checkpoints })
		elseif event.kind == "Finish" then
			self:_finish(player, run, event.seconds)
			return
		end
	end
end

function TimeTrialService:_finish(player, run, seconds)
	run.phase = "Finished"
	local previous = run.best
	local isPb = TimeTrialRules.IsBetter(seconds, previous)
	if isPb and self.data then
		self.data:Update(player, function(data)
			local current = data.bestTimes[run.key]
			if TimeTrialRules.IsBetter(seconds, current) then
				data.bestTimes[run.key] = seconds
			end
		end)
		self.data:SaveSoon(player)
		local ghost = TimeTrialRules.GhostPayload(run.recorder, seconds, run.key)
		local id = tostring(player.UserId) .. "|" .. run.key
		self.memoryGhosts[id] = ghost
		local store = self:_ghostStore()
		if store then
			task.spawn(function()
				local ok, err = pcall(function()
					store:SetAsync(id, ghost, { player.UserId })
				end)
				if not ok then
					warn("[TimeTrial] ghost save failed: " .. tostring(err))
				end
			end)
		end
	end
	self:_send(player, { phase = "Finished", seconds = seconds, best = isPb and seconds or previous, previous = previous, pb = isPb, world = run.worldName })
	if self.round.ReportTimeTrial then
		self.round:ReportTimeTrial(player, seconds, isPb) -- B3 quests listen here
	end
	task.delay(TimeTrialRules.ReturnDelaySeconds, function()
		if self.runs[player] == run then
			self.runs[player] = nil
			if player.Parent then
				self.marbles:SpawnMarble(player, REASONS.ToHub)
			end
		end
	end)
end

function TimeTrialService:Start()
	local remote = self.remotes:WaitForChild("RequestTimeTrial", 10)
	if remote then
		local limiter = Utility.RateLimiter.new(RoundProtocol.Remotes.RequestTimeTrial.MinInterval)
		self.maid:Give(remote.OnServerEvent:Connect(function(player, ...)
			if not RoundProtocol.ValidateArgs("RequestTimeTrial", ...) or not limiter:Try(player) then
				return
			end
			local wants = ...
			if wants then
				self:StartTrial(player)
			else
				self:Stop(player, "You quit the Time Trial")
			end
		end))
	end
	self.maid:Give(self.physics.Progress:Connect(function(player, info)
		self:_onProgress(player, info)
	end))
	self.maid:Give(self.marbles.PlayerLeaving:Connect(function(player)
		local run = self.runs[player]
		if run then
			self.runs[player] = nil
			run.judge:EndRound()
		end
	end))
	self.maid:Give(self.track.WorldChanged:Connect(function()
		for player in pairs(self.runs) do
			self:Stop(player, "The course is changing for the next race")
		end
	end))
end

function TimeTrialService:Destroy()
	self.maid:Cleanup()
end

return TimeTrialService
