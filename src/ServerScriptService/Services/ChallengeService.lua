--[[
	ChallengeService (challenges/cups/creator brief, 2026-11-26) — solo challenge attempts on the
	authored challenge courses (first: The Drop Shaft), the Weekly Challenge board, share codes
	and map mastery. Reuses the race authority: CheckpointService judges ordered gates on the
	challenge course; the server's own clock times the run; RacePhysicsService observes it.

	Attempt: Try -> placed on the start, frozen (same spot, orientation and the same launch slope
	for everyone) -> 3 s countdown -> GO (released) -> gates -> finish. A fall, a reset or the time
	limit ends the attempt cleanly ("Failed") and the marble waits on the start for RETRY (one
	action, no hub trip). A best is saved only after a valid finish, scoped to the challenge key
	(id | revision | ruleset | scoring). Splits vs the player's own best at each gate. The PB
	ghost reuses the Time Trial ghost store. Codes / invite launch data are routing hints resolved
	against the allowlist. Mastery goals grant their map reward once.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChallengeConfig = require(Shared:WaitForChild("ChallengeConfig"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local RoundProtocol = require(Shared:WaitForChild("RoundProtocol"))
local TimeTrialRules = require(Shared:WaitForChild("TimeTrialRules"))
local Utility = require(Shared:WaitForChild("Utility"))
local CheckpointService = require(script.Parent:WaitForChild("CheckpointService"))

local ZONES = Protocol.Zones
local REASONS = Protocol.SpawnReasons

local ChallengeService = {}
ChallengeService.__index = ChallengeService

ChallengeService.CountdownSeconds = 3
ChallengeService.RetryCountdownSeconds = 2

-- Pure: split deltas against a best run's gate times (nil where there is no comparison)
function ChallengeService.SplitDelta(bestSplits, index, t)
	local best = type(bestSplits) == "table" and bestSplits[index]
	if type(best) ~= "number" then
		return nil
	end
	return t - best
end

-- Pure: the signature line - the FIRST landing after the lip lands past the qualifying line
function ChallengeService.SignatureLanded(landingS, qualifyingS)
	return type(landingS) == "number" and type(qualifyingS) == "number" and landingS >= qualifyingS
end

function ChallengeService.new(deps)
	local self = setmetatable({}, ChallengeService)
	self.track = deps.track
	self.marbles = deps.marbles
	self.physics = deps.physics
	self.round = deps.round
	self.remotes = deps.remotes
	self.data = deps.data
	self.cosmetics = deps.cosmetics
	self.timeTrial = deps.timeTrial
	self.telemetry = deps.telemetry
	self.maid = Utility.Maid.new()
	self.runs = {}
	self.memoryGhosts = {}
	return self
end

function ChallengeService:Start()
	local remote = self.remotes:WaitForChild("RequestChallenge", 10)
	if remote then
		local limiter = Utility.RateLimiter.new(RoundProtocol.Remotes.RequestChallenge.MinInterval)
		self.maid:Give(remote.OnServerEvent:Connect(function(player, ...)
			if not RoundProtocol.ValidateArgs("RequestChallenge", ...) or not limiter:Try(player) then
				return
			end
			local id, action = ...
			self:_request(player, id, action)
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
	self.maid:Give(Players.PlayerAdded:Connect(function(player)
		-- invite / shared link: launch data is a code; resolved against the allowlist, never trusted
		local ok, join = pcall(function()
			return player:GetJoinData()
		end)
		local code = ok and type(join) == "table" and join.LaunchData or nil
		local c = ChallengeConfig.Resolve(code)
		if c then
			task.delay(4, function()
				self:_send(player, { phase = "Card", id = c.Id, invited = true })
			end)
		end
	end))
	-- challenge start gates stay open: the marble itself is frozen until GO
	for _, c in ipairs(ChallengeConfig.Challenges) do
		if self.track.SetChallengeGateOpen then
			self.track:SetChallengeGateOpen(c.Id, true)
		end
	end
end

function ChallengeService:IsRunning(player)
	return self.runs[player] ~= nil
end

function ChallengeService:_send(player, payload)
	local remote = self.remotes:FindFirstChild("ChallengeState")
	if remote and player.Parent then
		remote:FireClient(player, payload)
	end
end

function ChallengeService:_profile(player)
	local profile = self.data and self.data:GetProfile(player)
	return profile and profile.data
end

function ChallengeService:_card(player, c)
	local data = self:_profile(player)
	local key = ChallengeConfig.Key(c)
	local challenges = data and data.challenges or {}
	local mastery = data and data.mastery or {}
	local done, total = ChallengeConfig.MasteryProgress(c.Map, mastery)
	local _, week, starts, ends = ChallengeConfig.Weekly(os.time())
	return {
		phase = "Card",
		id = c.Id,
		key = key,
		best = challenges.best and challenges.best[key] or nil,
		medal = challenges.medals and challenges.medals[key] or nil,
		mastery = { done = done, total = total },
		week = week,
		weekStarts = starts,
		weekEnds = ends,
		weekly = (ChallengeConfig.Weekly(os.time())).Id == c.Id,
	}
end

function ChallengeService:_request(player, id, action)
	if action == "code" then
		local c = ChallengeConfig.Resolve(id)
		if c then
			self:_send(player, self:_card(player, c))
		else
			self:_send(player, { phase = "Refused", reason = "Unknown or expired code - pick a challenge from the list" })
		end
		return
	end
	local c = ChallengeConfig.ById[id]
	if not c or c.Status ~= "Live" then
		self:_send(player, { phase = "Refused", reason = "That challenge is not available" })
		return
	end
	if action == "card" then
		self:_send(player, self:_card(player, c))
	elseif action == "start" or action == "retry" then
		self:_begin(player, c)
	elseif action == "quit" then
		self:Stop(player, "Quit")
	elseif action == "board" then
		task.spawn(function()
			self:_sendBoard(player, c)
		end)
	elseif action == "share" or action == "unshare" then
		self:_setShare(player, c, action == "share")
	end
end

function ChallengeService:_begin(player, c)
	local existing = self.runs[player]
	if not existing then
		local ok, reason = TimeTrialRules.CanStart({
			running = self.timeTrial and self.timeTrial:IsRunning(player) or false,
			inRound = self.round.racerByPlayer[player] ~= nil,
			state = self.round:GetState(),
		})
		if not ok then
			self:_send(player, { phase = "Refused", reason = reason })
			return
		end
		self.round:TryJoin(player, false) -- an attempt sits you out of the next race (queue stays open)
	end
	local course = self.track:GetChallenge(c.Id)
	if not course then
		self:_send(player, { phase = "Refused", reason = "The challenge course is not built on this server" })
		return
	end
	local layout = course.layout
	local slot = layout.GridSlots[2] or layout.GridSlots[1]
	local data = self:_profile(player)
	local key = ChallengeConfig.Key(c)
	local countdown = existing and ChallengeService.RetryCountdownSeconds or ChallengeService.CountdownSeconds
	local run = {
		c = c,
		key = key,
		layout = layout,
		startCFrame = self.track:FrameCFrame(slot.Frame, slot.Offset),
		startS = slot.Frame.S,
		phase = "Countdown",
		goAt = workspace:GetServerTimeNow() + countdown,
		judge = CheckpointService.new({ GetLayout = function()
			return layout
		end }),
		recorder = TimeTrialRules.NewRecorder(),
		best = data and data.challenges and data.challenges.best[key] or nil,
		bestSplits = data and data.challenges and data.challenges.splits[key] or nil,
		splits = {},
		attempt = (existing and existing.attempt or 0) + 1,
		qualifyingS = layout.Definition.QualifyingLine and layout.Resolve(layout.Definition.QualifyingLine).S or nil,
		lipS = layout.Checkpoints[1] and layout.Checkpoints[1].S or 0,
	}
	self.runs[player] = run
	self.marbles:SpawnMarble(player, REASONS.TimeTrial)
	self:_send(player, { phase = "Countdown", id = c.Id, goAt = run.goAt, best = run.best, medals = c.Medals, attempt = run.attempt, total = #layout.Checkpoints })
	task.spawn(function()
		self:_sendGhost(player, run)
	end)
	task.delay(countdown, function()
		if self.runs[player] == run and run.phase == "Countdown" then
			run.phase = "Running"
			run.startClock = os.clock()
			run.judge:BeginRound({ [player] = run.startS }, run.startClock)
			self.marbles:Release(player)
			self:_send(player, { phase = "Running", id = c.Id, startedAt = workspace:GetServerTimeNow() })
			if self.telemetry then
				self.telemetry:Event(player, "challenge_start", { id = c.Id, attempt = run.attempt })
			end
		end
	end)
end

function ChallengeService:Stop(player, reason)
	local run = self.runs[player]
	if not run then
		return
	end
	self.runs[player] = nil
	run.judge:EndRound()
	self:_send(player, { phase = "Ended", id = run.c.Id, reason = reason })
	if player.Parent and self.marbles:GetZone(player) == ZONES.Race then
		self.marbles:SpawnMarble(player, REASONS.ToHub)
	end
end

-- RoundService asks this (after the Time Trial) for every spawn: nil = not a challenge spawn
function ChallengeService:ResolveSpawn(player, reason)
	local run = self.runs[player]
	if not run or reason == REASONS.ToHub then
		return nil
	end
	if run.phase == "Running" and (reason == REASONS.Fell or reason == REASONS.Reset or reason == REASONS.Lost or reason == REASONS.Movement) then
		self:_fail(player, run, reason == REASONS.Reset and "Reset - try again" or "Fell - try again")
	end
	local frozen = run.phase ~= "Running"
	return { CFrame = run.startCFrame, Zone = ZONES.Race, Frozen = frozen, Ghost = true, Hub = run.c.Id }
end

-- the race S where a challenge marble's tracker starts (RoundService delegates)
function ChallengeService:ProgressHint(player)
	local run = self.runs[player]
	return run and run.startS or nil
end

function ChallengeService:_fail(player, run, reason)
	if run.phase ~= "Running" then
		return
	end
	run.phase = "Failed"
	run.judge:EndRound()
	self:_send(player, { phase = "Failed", id = run.c.Id, reason = reason, best = run.best })
end

function ChallengeService:_onProgress(player, info)
	local run = self.runs[player]
	if not run or run.phase ~= "Running" or info.zone ~= ZONES.Race or info.hubId ~= run.c.Id then
		return
	end
	local t = (info.time or os.clock()) - run.startClock -- the monitor's own os.clock sample time
	if t > (run.c.MaxSeconds or 90) then
		self:_fail(player, run, "Time limit")
		return
	end
	if info.position and not info.frozen then
		TimeTrialRules.Record(run.recorder, t, info.position)
	end
	-- landing after the lip (the Signature Line): first floor contact once airborne past it
	if info.s and info.height and info.s > run.lipS then
		if info.height > 1.6 then
			run.airborne = true
		elseif run.airborne and not run.landingS and info.height < 0.6 then
			run.landingS = info.s
		end
	end
	for _, event in ipairs(run.judge:Process(player, info) or {}) do
		if event.kind == "Checkpoint" then
			local split = event.time - run.startClock
			run.splits[event.checkpoint or event.index] = split
			self:_send(player, { phase = "Split", id = run.c.Id, index = event.checkpoint or event.index, total = #run.layout.Checkpoints, t = split, delta = ChallengeService.SplitDelta(run.bestSplits, event.checkpoint or event.index, split) })
		elseif event.kind == "Finish" then
			self:_finish(player, run, event.seconds)
			return
		elseif event.kind == "Rejected" then
			self:_fail(player, run, "Missed a gate - try again")
			return
		end
	end
end

function ChallengeService:_finish(player, run, seconds)
	run.phase = "Finished"
	run.judge:EndRound()
	local c, key = run.c, run.key
	local previous = run.best
	local isPb = seconds >= TimeTrialRules.MinSeconds and TimeTrialRules.IsBetter(seconds, previous)
	local medal = ChallengeConfig.Medal(c, seconds)
	local saved = true
	if isPb or medal then
		saved = self.data and self.data:Update(player, function(data)
			data.challenges = data.challenges or { best = {}, medals = {}, splits = {} }
			if isPb then
				data.challenges.best[key] = seconds
				data.challenges.splits[key] = run.splits
			end
			local had = data.challenges.medals[key]
			local rank = { Gold = 3, Silver = 2, Bronze = 1 }
			if medal and (not had or rank[medal] > rank[had]) then
				data.challenges.medals[key] = medal
			end
		end) or false
		if saved and self.data.SaveSoon then
			self.data:SaveSoon(player)
		end
	end
	-- mastery: Fast Sector (gold) and Signature Line (landed past the qualifying line + finished)
	local signature = ChallengeService.SignatureLanded(run.landingS, run.qualifyingS)
	if c.Id == "drop_shaft" then
		if medal == "Gold" then
			self:GrantMastery(player, "nf_fast")
		end
		if signature then
			self:GrantMastery(player, "nf_signature")
		end
	end
	if isPb then
		local ghost = TimeTrialRules.GhostPayload(run.recorder, seconds, key)
		local id = tostring(player.UserId) .. "|" .. key
		self.memoryGhosts[id] = ghost
		task.spawn(function()
			local store = self:_ghostStore()
			if store then
				pcall(function()
					store:SetAsync(id, ghost, { player.UserId })
				end)
			end
			self:_writeWeekly(player, c, seconds)
		end)
	end
	self:_send(player, {
		phase = "Finished",
		id = c.Id,
		seconds = seconds,
		best = isPb and seconds or previous,
		previous = previous,
		pb = isPb,
		medal = medal,
		signature = signature,
		saved = saved,
		line = ChallengeConfig.ResultLine(c, seconds),
		code = c.Code,
	})
	if self.telemetry then
		self.telemetry:Event(player, "challenge_finish", { id = c.Id, attempt = run.attempt, value = math.floor(seconds * 100) })
	end
end

function ChallengeService:_live()
	return self.data ~= nil and self.data.GetMode ~= nil and self.data:GetMode() == "Live"
end

function ChallengeService:_ghostStore()
	if self.store == nil then
		if not self:_live() then
			self.store = false
		else
			local ok, store = pcall(function()
				return DataStoreService:GetDataStore("TumbleGhosts_v1")
			end)
			self.store = ok and store or false
		end
	end
	return self.store or nil
end

function ChallengeService:_loadGhost(userId, key)
	local id = tostring(userId) .. "|" .. key
	local ghost = self.memoryGhosts[id]
	local store = self:_ghostStore()
	if not ghost and store then
		local ok, value = pcall(function()
			return store:GetAsync(id)
		end)
		ghost = ok and value or nil
		if TimeTrialRules.ValidGhost(ghost, key) then
			self.memoryGhosts[id] = ghost
		end
	end
	return TimeTrialRules.ValidGhost(ghost, key) and ghost or nil
end

-- Pure: the friend ghost to race - fastest valid, explicitly shared, same-key (same challenge
-- revision + ruleset) ghost among friends; nil when none
function ChallengeService.PickFriendGhost(candidates, key)
	local best = nil
	for _, c in ipairs(candidates or {}) do
		local g = c.ghost
		if c.isFriend and type(g) == "table" and g.shared == true and TimeTrialRules.ValidGhost(g, key) then
			if not best or g.seconds < best.ghost.seconds then
				best = c
			end
		end
	end
	return best
end

function ChallengeService:_friendGhost(player, key)
	local candidates = {}
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			local ok, isFriend = pcall(function()
				return player:IsFriendsWith(other.UserId)
			end)
			if ok and isFriend then
				candidates[#candidates + 1] = { isFriend = true, name = other.DisplayName, ghost = self:_loadGhost(other.UserId, key) }
			end
		end
	end
	return ChallengeService.PickFriendGhost(candidates, key)
end

function ChallengeService:_sendGhost(player, run)
	local ghost = self:_loadGhost(player.UserId, run.key)
	local friend = self:_friendGhost(player, run.key)
	if self.runs[player] ~= run then
		return
	end
	self:_send(player, {
		phase = "Ghost",
		id = run.c.Id,
		ghost = ghost,
		note = ghost == nil and "No ghost yet - finish once to race your own best" or nil,
		friend = friend and friend.ghost or nil,
		friendName = friend and friend.name or nil,
		friendNote = friend == nil and "No friend here has shared a ghost for this version - racing your own best" or nil,
	})
end

-- the Weekly Challenge board (OrderedDataStore per week window; ascending times in ms)
function ChallengeService.WeeklyStoreName(c, week)
	return string.format("TCChal_%s_r%d_W%d", c.Id, c.Revision, week)
end

function ChallengeService:_weeklyStore(c)
	if not self:_live() then
		return nil
	end
	local weekly, week = ChallengeConfig.Weekly(os.time())
	if not weekly or weekly.Id ~= c.Id then
		return nil
	end
	local ok, store = pcall(function()
		return DataStoreService:GetOrderedDataStore(ChallengeService.WeeklyStoreName(c, week))
	end)
	return ok and store or nil
end

function ChallengeService:_writeWeekly(player, c, seconds)
	local store = self:_weeklyStore(c)
	if not store then
		return
	end
	local ms = math.floor(seconds * 1000 + 0.5)
	pcall(function()
		store:UpdateAsync(tostring(player.UserId), function(old)
			if type(old) == "number" and old <= ms then
				return nil
			end
			return ms
		end)
	end)
end

function ChallengeService:_sendBoard(player, c)
	local store = self:_weeklyStore(c)
	local rows, err = {}, nil
	if store then
		local ok, pages = pcall(function()
			return store:GetSortedAsync(true, 10)
		end)
		if ok and pages then
			for i, item in ipairs(pages:GetCurrentPage()) do
				rows[i] = { rank = i, userId = tonumber(item.key), seconds = item.value / 1000 }
			end
		else
			err = "The weekly board is unavailable right now"
		end
	else
		err = self:_live() and "No weekly board for this challenge" or "Weekly boards are live-server only (Studio / mock data)"
	end
	local _, week, starts, ends = ChallengeConfig.Weekly(os.time())
	self:_send(player, { phase = "Board", id = c.Id, rows = rows, error = err, week = week, weekStarts = starts, weekEnds = ends })
end

function ChallengeService:_setShare(player, c, on)
	-- explicit owner sharing of the PB ghost (friends in the same server may race it); the flag
	-- lives on the stored ghost, so a new PB ghost starts unshared again
	local key = ChallengeConfig.Key(c)
	local id = tostring(player.UserId) .. "|" .. key
	local ghost = self:_loadGhost(player.UserId, key)
	if not ghost then
		self:_send(player, { phase = "Shared", id = c.Id, shared = false, note = "Finish once to have a ghost to share" })
		return
	end
	ghost.shared = on == true
	local store = self:_ghostStore()
	if store then
		pcall(function()
			store:UpdateAsync(id, function(old)
				if TimeTrialRules.ValidGhost(old, key) then
					old.shared = on == true
					return old
				end
				return nil
			end)
		end)
	end
	self:_send(player, { phase = "Shared", id = c.Id, shared = ghost.shared })
end

-- Pure: the "Clean Circuit" goal id for a map (nil when the map has none)
function ChallengeService.CleanCircuitGoal(mapId)
	local m = ChallengeConfig.Mastery[mapId or ""]
	for _, g in ipairs(m and m.Goals or {}) do
		if string.sub(g.Id, -6) == "_clean" then
			return g.Id
		end
	end
	return nil
end

-- RoundService: a human finished every lap of a circuit race on mapId without a reset or a fall
function ChallengeService:OnCleanCircuit(player, mapId)
	local goal = ChallengeService.CleanCircuitGoal(mapId)
	if goal then
		return self:GrantMastery(player, goal)
	end
	return false
end

-- Mastery: idempotent; the map reward grants once when all its goals are done
function ChallengeService:GrantMastery(player, goalId)
	local newly = false
	local updated = self.data and self.data:Update(player, function(data)
		data.mastery = data.mastery or {}
		if not data.mastery[goalId] then
			data.mastery[goalId] = true
			newly = true
		end
	end)
	if not updated or not newly then
		return false
	end
	if self.data.SaveSoon then
		self.data:SaveSoon(player)
	end
	for mapId, m in pairs(ChallengeConfig.Mastery) do
		for _, g in ipairs(m.Goals) do
			if g.Id == goalId then
				local data = self:_profile(player)
				local done, total = ChallengeConfig.MasteryProgress(mapId, data and data.mastery)
				self:_send(player, { phase = "Mastery", goal = goalId, title = g.Title, map = mapId, done = done, total = total })
				if done == total and m.Reward and self.cosmetics then
					self.cosmetics:Grant(player, m.Reward, "mastery")
				end
			end
		end
	end
	return true
end

function ChallengeService:Destroy()
	self.maid:Cleanup()
end

return ChallengeService
