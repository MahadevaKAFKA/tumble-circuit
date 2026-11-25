--[[
	RoundService — the authoritative A2 round (master section 2).

	Boot -> Lobby -> Intermission(15s) -> Preparing(2s) -> Countdown(3s) -> Racing(<=180s)
	     -> Results(12s) -> Cleanup(1s) -> Intermission | Lobby
	Transitions are checked against RoundProtocol.Transitions and are idempotent. Timing uses
	os.clock() deadlines on the server and publishes workspace:GetServerTimeNow() timestamps so
	every client (including late joiners) shows the same countdown.

	* Everyone present is queued by default; RequestJoinRace(false) sits out, (true) = play again.
	* One human is enough to race. A4: bots fill the grid to RaceConfig.Bots.FillTo (bots never
	  start a round, never go to the hub, and never keep a human waiting: once every human has
	  finished, the remaining bots get HumansDoneGraceSeconds). Late joiners wait in the hub.
	* A4: Preparing sets the hazard seed class (roundId % 3) and epoch (the scheduled GO time),
	  published in the snapshot, so every hazard restarts identically each round.
	* Racers are respawned frozen on a shuffled grid; GO opens the gate and releases them.
	* Finish/checkpoints come only from CheckpointService (server-observed). Simultaneous finishes
	  within one sample are ordered by interpolated crossing time, then join ordinal.
	* Recovery returns to the last confirmed checkpoint; during Preparing/Countdown it is refused.
	* Snapshots go out on every transition, on request, and at <= StandingsHz while racing when the
	  standings actually changed.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local RaceConfig = require(Shared:WaitForChild("RaceConfig"))
local RoundProtocol = require(Shared:WaitForChild("RoundProtocol"))
local Utility = require(Shared:WaitForChild("Utility"))
local RaceRules = require(script.Parent:WaitForChild("RaceRules"))

local RoundService = {}
RoundService.__index = RoundService

local S = RoundProtocol.States
local ZONES = Protocol.Zones
local REASONS = Protocol.SpawnReasons
local T = RaceConfig.Timers

function RoundService.new(deps)
	local self = setmetatable({}, RoundService)
	self.track = deps.track
	self.marbles = deps.marbles
	self.physics = deps.physics
	self.checkpoints = deps.checkpoints
	self.progress = deps.progress
	self.remotes = deps.remotes
	self.bots = deps.bots -- A4 (optional)
	self.hazards = deps.hazards -- A4 (optional)
	self.maid = Utility.Maid.new()
	self.state = S.Boot
	self.stateSeq = 0
	self.roundId = 0
	self.deadline = nil
	self.racers = {} -- array of racer records (this round)
	self.racerByPlayer = {}
	self.queued = {} -- [player] = bool
	self.ready = {} -- [player] = true: READY vote for the current intermission (owner request)
	self.ordinals = {} -- [player] = stable join ordinal
	self.nextOrdinal = 0
	self.finishCounter = 0
	self.pendingFinishes = {}
	self.lastStandingsKey = nil
	self.standingsTimer = 0
	self.limiters = {}
	self.warned = {}
	self.StateChanged = Utility.Signal.new() -- (state, snapshot)
	self.RaceFinished = Utility.Signal.new() -- (roundId, results) for later milestones (rewards = A5)
	for name, spec in pairs(RoundProtocol.Remotes) do
		if spec.Direction == "ClientToServer" then
			self.limiters[name] = Utility.RateLimiter.new(spec.MinInterval)
		end
	end
	return self
end

---------------------------------------------------------------------------------------------
-- Lifecycle
---------------------------------------------------------------------------------------------
local function isBot(entity)
	return type(entity) == "table" and entity.isBot == true
end
RoundService.IsBot = isBot

function RoundService:Start()
	if self.bots then
		self.bots.round = self
	end
	self.marbles:SetSpawnResolver(function(player, reason)
		return self:ResolveSpawn(player, reason)
	end)
	self:_connectRemote("RequestSnapshot", function(player)
		self:SendSnapshot(player)
	end)
	self:_connectRemote("RequestRecover", function(player)
		self:HandleRecover(player)
	end)
	self:_connectRemote("RequestJoinRace", function(player, wants)
		self:TryJoin(player, wants)
	end)
	self:_connectRemote("RequestReady", function(player, wants)
		self:TryReady(player, wants)
	end)
	-- A5 AFK guard: real input during Racing marks the racer active (rewards need it).
	self:_connectRemote("ReportActive", function(player, roundId)
		if roundId == self.roundId then
			self:MarkActive(player)
		end
	end)
	for _, name in ipairs({ "RequestAbility", "RequestTrick" }) do
		local remote = self.remotes:FindFirstChild(name)
		if remote then
			self.maid:Give(remote.OnServerEvent:Connect(function(player)
				self:MarkActive(player)
			end))
		end
	end
	self.maid:Give(self.marbles.PlayerJoined:Connect(function(player)
		self.nextOrdinal = self.nextOrdinal + 1
		self.ordinals[player] = self.nextOrdinal
		self.queued[player] = true -- autoqueue; the next race is always the default
		if self.state == S.Lobby then
			self:_transition(S.Intermission)
		else
			self:Broadcast()
		end
	end))
	self.maid:Give(self.marbles.PlayerLeaving:Connect(function(player)
		self:_onPlayerLeaving(player)
	end))
	self.maid:Give(self.physics.Progress:Connect(function(player, info)
		self:_onProgress(player, info)
	end))
	self.maid:Give(self.physics.SampleComplete:Connect(function()
		self:_flushFinishes()
	end))
	self.maid:Give(self.physics.MovementRejected:Connect(function(entity)
		if isBot(entity) then
			if self.bots then
				self.bots:Spawn(entity, REASONS.Movement)
			end
		else
			self.marbles:SpawnMarble(entity, REASONS.Movement)
		end
	end))
	self.maid:Give(RunService.Heartbeat:Connect(function(dt)
		self:_tick(dt)
	end))
	game:BindToClose(function()
		self:Shutdown()
	end)

	self:_transition(S.Lobby)
	if #Players:GetPlayers() > 0 then
		self:_transition(S.Intermission)
	end
end

function RoundService:Shutdown()
	self.track:SetStartGateClosed(true)
	self.checkpoints:EndRound()
	self.maid:Cleanup()
end

function RoundService:_connectRemote(name, handler)
	local remote = self.remotes:WaitForChild(name)
	self.maid:Give(remote.OnServerEvent:Connect(function(player, ...)
		local ok, reason = RoundProtocol.ValidateArgs(name, ...)
		if not ok then
			self:_warnOnce(player, name, "malformed " .. name .. " from " .. player.Name .. ": " .. reason)
			return
		end
		if not self.limiters[name]:Try(player) then
			return -- rate limited (silently: button spam is normal)
		end
		handler(player, ...)
	end))
end

function RoundService:_warnOnce(player, key, message)
	local id = tostring(player.UserId) .. key
	local now = os.clock()
	if not self.warned[id] or now - self.warned[id] > 60 then
		self.warned[id] = now
		warn("[Round] rejected: " .. message)
	end
end

---------------------------------------------------------------------------------------------
-- Transitions
---------------------------------------------------------------------------------------------
function RoundService:_transition(to)
	if self.state == to then
		return false -- idempotent
	end
	if not RoundProtocol.CanTransition(self.state, to) then
		warn(string.format("[Round] illegal transition %s -> %s ignored", self.state, to))
		return false
	end
	local from = self.state
	self.state = to
	self.stateSeq = self.stateSeq + 1
	self.stateStartedAt = workspace:GetServerTimeNow()
	self.deadline = nil
	self.stateEndsAt = nil
	local enter = self["_enter" .. to]
	if enter then
		enter(self, from)
	end
	if GameConfig.Debug.VerboseLogging then
		print(string.format("[Round] %s -> %s (round %d)", from, to, self.roundId))
	end
	self:Broadcast()
	self.StateChanged:Fire(to, self:GetSnapshot())
	return true
end

function RoundService:_setTimer(seconds)
	self.deadline = os.clock() + seconds
	self.stateEndsAt = workspace:GetServerTimeNow() + seconds
end

function RoundService:_enterLobby()
	self.track:SetStartGateClosed(true)
end

function RoundService:_enterIntermission()
	self.ready = {} -- every intermission starts with no READY votes
	self.track:SetStartGateClosed(true)
	self:_setTimer(T.IntermissionSeconds)
end

function RoundService:_enterPreparing()
	self.roundId = self.roundId + 1
	self.racers, self.racerByPlayer = {}, {}
	self.finishCounter = 0
	self.pendingFinishes = {}
	self.lastStandingsKey = nil
	local ids, byId = {}, {}
	for player, wants in pairs(self.queued) do
		if wants and player.Parent then
			ids[#ids + 1] = player.UserId
			byId[player.UserId] = player
		end
	end
	local order = RaceRules.ShuffleGrid(ids, self.roundId)
	local slots = self.track:GetGridSlotCount()
	for i, userId in ipairs(order) do
		if i > slots then
			break -- more humans than grid slots: the rest race next time
		end
		local player = byId[userId]
		local racer = {
			player = player,
			userId = userId,
			name = player.DisplayName,
			ordinal = self.ordinals[player] or i,
			slot = i,
			finished = false,
			dnf = false,
		}
		self.racers[#self.racers + 1] = racer
		self.racerByPlayer[player] = racer
	end
	-- A4: bots fill the remaining slots (behind the humans) up to FillTo racers.
	local cfg = RaceConfig.Bots
	if self.bots and cfg and cfg.Enabled and #self.racers > 0 then
		local fill = RaceRules.BotFillCount(#self.racers, slots, cfg.FillTo, cfg.Enabled)
		if cfg.FixedCount and #self.racers > 0 then -- dev panel override (Studio)
			fill = math.max(0, math.min(cfg.FixedCount, slots - #self.racers))
		end
		for i, bot in ipairs(self.bots:CreateRoster(fill, self.roundId)) do
			local racer = {
				player = bot,
				userId = bot.UserId,
				name = bot.DisplayName, -- displays add the [BOT] tag from isBot
				ordinal = 100000 + i,
				slot = #self.racers + 1,
				finished = false,
				dnf = false,
				isBot = true,
			}
			self.racers[#self.racers + 1] = racer
			self.racerByPlayer[bot] = racer
		end
	end
	if self.hazards then
		self.hazards:SetRound(self.roundId, workspace:GetServerTimeNow() + T.PreparingSeconds + T.CountdownSeconds)
	end
	self.track:SetStartGateClosed(true)
	for _, racer in ipairs(self.racers) do
		if racer.isBot then
			self.bots:Spawn(racer.player, REASONS.Grid)
		else
			self.marbles:SpawnMarble(racer.player, REASONS.Grid)
		end
	end
	self:_setTimer(T.PreparingSeconds)
end

function RoundService:_enterCountdown()
	self:_setTimer(T.CountdownSeconds)
end

function RoundService:_enterRacing()
	self.graceStarted = false
	self.raceStartClock = os.clock()
	self.raceStartedAt = workspace:GetServerTimeNow()
	self.track:SetStartGateClosed(false)
	local layout = self.track:GetLayout(ZONES.Race)
	local starts = {}
	for _, racer in ipairs(self.racers) do
		starts[racer.player] = layout.GridSlots[((racer.slot - 1) % #layout.GridSlots) + 1].Frame.S
	end
	-- Checkpoint records first: Release respawns each human racer (fresh free marble, owner
	-- playtest 2026-11-23), and the spawn resolver reads them. Bots keep A4's own release.
	self.checkpoints:BeginRound(starts, self.raceStartClock)
	for _, racer in ipairs(self.racers) do
		if racer.isBot then
			self.bots:Release(racer.player)
		else
			self.marbles:Release(racer.player)
		end
	end
	self:_setTimer(T.MaxRaceSeconds)
end

function RoundService:_enterResults()
	for _, racer in ipairs(self.racers) do
		if not racer.finished then
			racer.dnf = true
		end
	end
	self.results = self.progress:Standings(self.racers)
	self:_setTimer(T.ResultsSeconds)
	self.RaceFinished:Fire(self.roundId, self.results)
end

function RoundService:_enterCleanup()
	self.track:SetStartGateClosed(true)
	self.checkpoints:EndRound()
	local racers = self.racers
	self.racers, self.racerByPlayer = {}, {}
	if self.bots then
		self.bots:DespawnAll() -- A4: bots never outlive their round
	end
	for _, racer in ipairs(racers) do
		if not racer.isBot and racer.player and racer.player.Parent then
			self.marbles:SpawnMarble(racer.player, REASONS.ToHub)
		end
	end
	self.raceStartedAt = nil
	self:_setTimer(T.CleanupSeconds)
end

local function anyHumans()
	return #Players:GetPlayers() > 0
end

-- READY vote state for the current intermission (RaceRules.ReadyVote shape).
function RoundService:GetReadyVote()
	local queued, ready = 0, 0
	for player, wants in pairs(self.queued) do
		if wants and player.Parent then
			queued = queued + 1
			if self.ready[player] then
				ready = ready + 1
			end
		end
	end
	local capacity = RaceRules.RaceCapacity(self.track:GetGridSlotCount(), Players.MaxPlayers, RaceConfig.Ready.CapacityOverride)
	return RaceRules.ReadyVote(queued, ready, capacity)
end

-- A queued player votes READY (true) or takes it back (false). Only counted during Intermission
-- while the race is full; once every queued player is READY the race starts without waiting.
function RoundService:TryReady(player, wants)
	if not RaceConfig.Ready.Enabled or self.state ~= S.Intermission or not self.queued[player] then
		self:SendSnapshot(player)
		return false
	end
	if not self:GetReadyVote().open then
		self.ready[player] = nil
		self:SendSnapshot(player)
		return false
	end
	self.ready[player] = wants == true or nil
	local vote = self:GetReadyVote()
	if vote.allReady then
		if GameConfig.Debug.VerboseLogging then
			print(string.format("[Round] all %d racers READY: starting without the timer", vote.needed))
		end
		return self:_transition(S.Preparing)
	end
	self:Broadcast()
	return true
end

function RoundService:_queuedCount()
	local n = 0
	for player, wants in pairs(self.queued) do
		if wants and player.Parent then
			n = n + 1
		end
	end
	return n
end

function RoundService:_tick(dt)
	local state = self.state
	if state == S.Racing then
		self.standingsTimer = self.standingsTimer + dt
		if self.standingsTimer >= 1 / RaceConfig.Snapshot.StandingsHz then
			self.standingsTimer = 0
			self:_maybeBroadcastStandings()
		end
	end
	if not self.deadline or os.clock() < self.deadline then
		return
	end
	if state == S.Intermission then
		if not anyHumans() then
			self:_transition(S.Lobby)
		elseif self:_queuedCount() > 0 then
			self:_transition(S.Preparing)
		else
			self:_setTimer(T.IntermissionSeconds) -- everyone sitting out: wait another lap
			self:Broadcast()
		end
	elseif state == S.Preparing then
		self:_transition(#self.racers > 0 and S.Countdown or S.Cleanup)
	elseif state == S.Countdown then
		self:_transition(#self.racers > 0 and S.Racing or S.Cleanup)
	elseif state == S.Racing then
		self:EndRound("timeout")
	elseif state == S.Results then
		self:_transition(S.Cleanup)
	elseif state == S.Cleanup then
		self:_transition(anyHumans() and S.Intermission or S.Lobby)
	end
end

function RoundService:EndRound(reason)
	if self.state ~= S.Racing then
		return false
	end
	if #self.racers == 0 then
		return self:_transition(S.Cleanup)
	end
	if GameConfig.Debug.VerboseLogging then
		print("[Round] race ended: " .. tostring(reason))
	end
	return self:_transition(S.Results)
end

---------------------------------------------------------------------------------------------
-- Requests
---------------------------------------------------------------------------------------------
function RoundService:TryJoin(player, wants)
	self.queued[player] = wants == true
	if not wants then
		self.ready[player] = nil
	end
	if wants and self.state == S.Lobby then
		self:_transition(S.Intermission)
	else
		self:Broadcast()
	end
	return true
end

function RoundService:HandleRecover(player)
	local ball = self.marbles:GetBall(player)
	if not ball or self.marbles:IsRespawnPending(player) then
		return false
	end
	local zone = self.marbles:GetZone(player)
	if zone == ZONES.Race then
		local racer = self.racerByPlayer[player]
		if racer and (self.state == S.Preparing or self.state == S.Countdown) then
			return false -- a reset can never start or skip a race
		end
	end
	if not self.limiters.RecoverCooldown then
		self.limiters.RecoverCooldown = Utility.RateLimiter.new(RaceConfig.Recovery.ServerRecoverCooldownSeconds)
	end
	if not self.limiters.RecoverCooldown:Try(player) then
		return false
	end
	self:MarkActive(player)
	self.marbles:SpawnMarble(player, REASONS.Reset)
	return true
end

-- Where a player's next marble appears (called by MarbleCharacterService for every spawn).
function RoundService:ResolveSpawn(player, reason)
	local racer = self.racerByPlayer[player]
	local state = self.state
	if isBot(player) and (not racer or reason == REASONS.ToHub) then
		return nil -- bots never go to the hub
	end
	if racer and reason ~= REASONS.ToHub then
		if state == S.Preparing or state == S.Countdown then
			return { CFrame = self.track:GetGridCFrame(racer.slot), Zone = ZONES.Race, Frozen = true }
		elseif state == S.Racing or state == S.Results then
			if racer.finished then
				return { CFrame = self.track:GetFinishRespawnCFrame(), Zone = ZONES.Race, Frozen = false }
			end
			if state == S.Racing then
				local index = self.checkpoints:GetConfirmed(player)
				local cf = index > 0 and self.track:GetCheckpointRespawnCFrame(index) or self.track:GetGridCFrame(racer.slot)
				return { CFrame = cf, Zone = ZONES.Race, Frozen = false }
			end
		end
	end
	return { CFrame = self.track:NextHubSpawnCFrame(), Zone = ZONES.Hub, Frozen = false }
end

---------------------------------------------------------------------------------------------
-- Observation
---------------------------------------------------------------------------------------------
function RoundService:_onProgress(player, info)
	if info.zone == ZONES.Hub then
		local chute = self.track:GetLayout(ZONES.Hub)
		if info.s >= chute.FinishLineS and info.distance < 15 then
			self.marbles:ScheduleRespawn(player, REASONS.ToHub, 0.6) -- practice loop
		end
		return
	end
	if self.state ~= S.Racing then
		return
	end
	local racer = self.racerByPlayer[player]
	if not racer then
		return
	end
	local events = self.checkpoints:Process(player, info)
	if not events then
		return
	end
	for _, event in ipairs(events) do
		if event.kind == "Checkpoint" then
			local remote = self.remotes:FindFirstChild("CheckpointFeedback")
			if remote and not racer.isBot then
				remote:FireClient(player, {
					roundId = self.roundId,
					index = event.index,
					total = #self.track:GetLayout(ZONES.Race).Checkpoints,
					serverTime = workspace:GetServerTimeNow(),
				})
			end
		elseif event.kind == "Finish" then
			table.insert(self.pendingFinishes, { racer = racer, time = event.time, seconds = event.seconds, ordinal = racer.ordinal })
		elseif event.kind == "Rejected" then
			self:_warnOnce(player, "cp" .. event.reason, string.format("%s crossing (%s) by %s", self.roundId, event.reason, player.Name))
		end
	end
end

function RoundService:_flushFinishes()
	if #self.pendingFinishes == 0 then
		return
	end
	local batch = RaceRules.OrderFinishes(self.pendingFinishes)
	self.pendingFinishes = {}
	local notice = self.remotes:FindFirstChild("FinishNotice")
	for _, item in ipairs(batch) do
		local racer = item.racer
		if not racer.finished then
			self.finishCounter = self.finishCounter + 1
			racer.finished = true
			racer.finishOrdinal = self.finishCounter
			racer.seconds = item.seconds
			if notice then
				notice:FireAllClients({ roundId = self.roundId, userId = racer.userId, name = racer.name, isBot = racer.isBot == true, place = self.finishCounter, seconds = item.seconds })
			end
		end
	end
	self:_maybeBroadcastStandings(true)
	self:_checkRaceComplete()
end

-- Everyone finished -> results. Every human finished but bots still rolling -> short grace.
function RoundService:_checkRaceComplete()
	if self.state ~= S.Racing then
		return
	end
	local allDone, humansDone, humans = true, true, 0
	for _, racer in ipairs(self.racers) do
		if not racer.isBot then
			humans = humans + 1
		end
		if not racer.finished then
			allDone = false
			if not racer.isBot then
				humansDone = false
			end
		end
	end
	if allDone then
		self:EndRound("all finished")
	elseif humans > 0 and humansDone and not self.graceStarted then
		self.graceStarted = true
		local grace = (RaceConfig.Bots and RaceConfig.Bots.HumansDoneGraceSeconds) or 10
		if self.deadline and self.deadline - os.clock() > grace then
			self:_setTimer(grace)
			self:Broadcast()
		end
	end
end

function RoundService:_onPlayerLeaving(player)
	self.queued[player] = nil
	self.ready[player] = nil
	self.ordinals[player] = nil
	local racer = self.racerByPlayer[player]
	if racer then
		self.racerByPlayer[player] = nil
		for i = #self.racers, 1, -1 do
			if self.racers[i] == racer then
				table.remove(self.racers, i)
			end
		end
		self.checkpoints:RemoveRacer(player)
		local humans = 0
		for _, other in ipairs(self.racers) do
			if not other.isBot then
				humans = humans + 1
			end
		end
		if (self.state == S.Racing or self.state == S.Countdown or self.state == S.Preparing) and humans == 0 then
			self:_transition(S.Cleanup) -- bots never race on their own
			return
		end
		if self.state == S.Racing then
			self:_checkRaceComplete()
			if self.state ~= S.Racing then
				return
			end
		end
	end
	self:Broadcast()
end

---------------------------------------------------------------------------------------------
-- Snapshots
---------------------------------------------------------------------------------------------
function RoundService:GetStandings()
	if self.state == S.Results and self.results then
		return self.results
	end
	return self.progress:Standings(self.racers)
end

function RoundService:GetSnapshot()
	local standings = self:GetStandings()
	local racers = {}
	for i, entry in ipairs(standings) do
		racers[i] = {
			userId = entry.userId,
			name = entry.name,
			place = entry.place,
			checkpoint = entry.checkpoint,
			finished = entry.finished,
			seconds = entry.seconds,
			dnf = entry.dnf,
			isBot = entry.isBot,
		}
	end
	local queued = {}
	for player, wants in pairs(self.queued) do
		if wants and player.Parent then
			queued[tostring(player.UserId)] = true
		end
	end
	local vote = self:GetReadyVote()
	local ready = {}
	for player in pairs(self.ready) do
		if player.Parent and self.queued[player] then
			ready[tostring(player.UserId)] = true
		end
	end
	return {
		v = RoundProtocol.Version,
		roundId = self.roundId,
		state = self.state,
		stateSeq = self.stateSeq,
		stateStartedAt = self.stateStartedAt,
		stateEndsAt = self.stateEndsAt,
		raceStartedAt = self.raceStartedAt,
		trackId = self.track:GetLayout(ZONES.Race).Definition.Id,
		checkpointTotal = #self.track:GetLayout(ZONES.Race).Checkpoints,
		racers = racers,
		queued = queued,
		humanCount = #Players:GetPlayers(),
		queuedCount = vote.needed,
		raceCapacity = vote.capacity,
		readyOpen = self.state == S.Intermission and RaceConfig.Ready.Enabled and vote.open,
		readyCount = vote.ready,
		ready = ready,
		hazardSeed = self.hazards and self.hazards:GetSeed() or 0,
		hazardEpoch = self.hazards and self.hazards:GetEpoch() or 0,
	}
end

function RoundService:Broadcast()
	local remote = self.remotes:FindFirstChild("RoundSnapshot")
	if remote then
		remote:FireAllClients(self:GetSnapshot())
	end
end

function RoundService:SendSnapshot(player)
	local remote = self.remotes:FindFirstChild("RoundSnapshot")
	if remote then
		remote:FireClient(player, self:GetSnapshot())
	end
end

function RoundService:_maybeBroadcastStandings(force)
	local standings = self.progress:Standings(self.racers)
	local parts = {}
	for _, entry in ipairs(standings) do
		parts[#parts + 1] = entry.userId .. ":" .. entry.checkpoint .. ":" .. tostring(entry.finished)
	end
	local key = table.concat(parts, "|")
	if force or key ~= self.lastStandingsKey then
		self.lastStandingsKey = key
		self:Broadcast()
	end
end

-- A3: abilities and micro-skills only count for a live, unfinished racer during Racing.
function RoundService:IsActiveRacer(player)
	local racer = self.racerByPlayer[player]
	return self.state == S.Racing and racer ~= nil and not racer.finished
end

function RoundService:GetActiveRacers()
	local out = {}
	if self.state ~= S.Racing then
		return out
	end
	for _, racer in ipairs(self.racers) do
		if not racer.finished and racer.player and racer.player.Parent then
			out[#out + 1] = racer.player
		end
	end
	return out
end

function RoundService:MarkActive(player)
	local racer = self.racerByPlayer[player]
	if racer and self.state == S.Racing then
		racer.active = true
	end
end

function RoundService:GetPlayerByUserId(userId)
	return Players:GetPlayerByUserId(userId)
end

function RoundService:IsFinishedRacer(entity)
	local racer = self.racerByPlayer[entity]
	return racer ~= nil and racer.finished == true
end

-- The marble of a human or a bot racer.
function RoundService:GetBallFor(entity)
	if isBot(entity) then
		return self.bots and self.bots:GetBall(entity)
	end
	return self.marbles:GetBall(entity)
end

function RoundService:GetState()
	return self.state
end

function RoundService:GetRoundId()
	return self.roundId
end

return RoundService
