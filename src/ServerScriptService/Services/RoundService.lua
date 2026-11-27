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
local RaceStats = require(script.Parent:WaitForChild("RaceStats"))
local MapVoteRules = require(script.Parent:WaitForChild("MapVoteRules"))
local BallotRules = require(script.Parent:WaitForChild("BallotRules"))
local MapRegistry = require(Shared:WaitForChild("MapRegistry"))

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
	self.lastWorldIndex = 0 -- B1: world rotation (0 = nothing raced yet → first world next)
	self.nextWorldIndex = 1
	self.ballots = BallotRules.NewBox(1) -- prompt 03: ballots for the next round (epoch = its round id)
	self.lastResolution = nil -- { roundId, mapId, counts, counted, fellBack }
	self.hubs = deps.hubs -- prompt 03/04 (optional): per-player hub (HubService); set by the bootstrap
	self.party = deps.party -- B1 (optional): keeps Roblox party members on neighbouring slots
	self.telemetry = deps.telemetry -- brief 3 (optional): per-sector race health counts
	if self.physics then
		-- circuits: a new marble's tracker starts on the right lap (grid = just behind the line)
		self.physics.hintFor = function(entity, zone)
			return self:ProgressHint(entity, zone)
		end
	end
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
	self.TimeTrialFinished = Utility.Signal.new() -- B3: (player, seconds, isPb)
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
	self:_connectRemote("RequestBallot", function(player, mapIndex, epoch, seq)
		self:TryBallot(player, mapIndex, epoch, seq)
	end)
	self:_connectRemote("RequestDestination", function(player, hubIndex, modeIndex)
		if self.hubs then
			self.hubs:TryDestination(player, hubIndex, modeIndex)
		end
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
	-- B1 rotation candidate (prompt 03: ballots decide at Preparing; no ballots = rotation)
	local ids = self.track.GetWorldIds and self.track:GetWorldIds() or {}
	self.nextWorldIndex = MapVoteRules.NextInRotation(self.lastWorldIndex, #ids) or 1
end

-- prompt 03: who can vote / is counted. Connected humans; counted = also queued for the race.
function RoundService:_voterSets()
	local connected, counted = {}, {}
	for _, player in ipairs(Players:GetPlayers()) do
		connected[player.UserId] = true
		if self.queued[player] then
			counted[player.UserId] = true
		end
	end
	return connected, counted
end

function RoundService:_eligibleMaps()
	local ids = self.track.GetWorldIds and self.track:GetWorldIds() or {}
	local set = {}
	for _, id in ipairs(ids) do
		set[id] = true
	end
	return ids, set
end

-- prompt 03: Vote for Next Race. Any connected human, any time before the box resolves.
function RoundService:TryBallot(player, mapIndex, epoch, seq)
	local ids, eligible = self:_eligibleMaps()
	local ok, reason = BallotRules.Cast(self.ballots, player.UserId, ids[mapIndex], epoch, seq, eligible)
	if ok then
		if reason ~= "same" then
			self:Broadcast()
		end
	else
		self:SendSnapshot(player) -- stale / duplicate: the client re-reads the current box
	end
	return ok, reason
end

-- The map ballots would pick right now (or the rotation candidate).
function RoundService:_rotationIndex(count)
	return MapVoteRules.NextInRotation(self.lastWorldIndex, count) or 1
end

function RoundService:_leadingIndex()
	local ids = self:_eligibleMaps()
	local _, counted = self:_voterSets()
	local counts = BallotRules.Tally(self.ballots, counted, ids)
	return BallotRules.Winner(counts, self:_rotationIndex(#ids)) or 1, counts
end

-- Resolve the ballot box for the round about to start; a new box opens for the one after it.
function RoundService:_resolveBallots()
	local ids = self:_eligibleMaps()
	local _, counted = self:_voterSets()
	local winner, counts, total = BallotRules.Resolve(self.ballots, counted, ids, self:_rotationIndex(#ids))
	self.nextWorldIndex = winner or 1
	self.lastResolution = { roundId = self.roundId + 1, mapId = ids[self.nextWorldIndex], counts = counts, counted = total }
	if GameConfig.Debug.VerboseLogging then
		print(string.format("[Round] ballots: %s (%s, %d counted)", tostring(ids[self.nextWorldIndex]), table.concat(counts, "/"), total))
	end
	self.ballots = BallotRules.NewBox(self.roundId + 2)
end

function RoundService:ReportTimeTrial(player, seconds, isPb)
	self.TimeTrialFinished:Fire(player, seconds, isPb)
end

function RoundService:GetNextWorldId()
	local ids = self.track.GetWorldIds and self.track:GetWorldIds() or {}
	local index = self.nextWorldIndex -- Preparing / Countdown: the map being raced
	if self.state ~= S.Preparing and self.state ~= S.Countdown then
		index = self:_leadingIndex() -- prompt 03: the map ballots favour for the next race
	end
	return ids[index] or ids[1]
end

function RoundService:_enterPreparing()
	self:_resolveBallots()
	local worldId = (self:_eligibleMaps())[self.nextWorldIndex]
	if worldId and self.track.SetActiveWorld then
		-- B1: hazards / bots / gates rebind via WorldChanged. prompt 03: a map that cannot be
		-- activated falls back to the known-safe default map; the race still starts.
		if not self.track:SetActiveWorld(worldId) then
			local fallback = MapRegistry.DefaultMapId
			warn("[Round] could not load " .. tostring(worldId) .. "; racing " .. fallback)
			self.track:SetActiveWorld(fallback)
			local ids = self:_eligibleMaps()
			for i, id in ipairs(ids) do
				if id == fallback then
					self.nextWorldIndex = i
				end
			end
			if self.lastResolution then
				self.lastResolution.fellBack = true
			end
		end
		self.lastWorldIndex = self.nextWorldIndex
	end
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
	if self.party then
		order = self.party:GroupGridOrder(order) -- B1: party members on neighbouring slots
	end
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
			-- shop brief: the equipped cosmetics as validated at the start of this race; the
			-- marble, trail, launch, results plate and podium effect all come from this snapshot
			look = self.cosmetics and self.cosmetics:LookFor(player) or nil,
		}
		self.racers[#self.racers + 1] = racer
		self.racerByPlayer[player] = racer
	end
	-- brief 3 E: an opt-in Ranked round is sealed now (roster + ratings snapshot), before bots
	self.rankedRound = self.ranked ~= nil and #self.racers > 0 and self.ranked:Seal(self.roundId, self.racers) or false
	-- A4: bots fill the remaining slots (behind the humans) up to FillTo racers (never in Ranked).
	local cfg = RaceConfig.Bots
	if self.bots and cfg and cfg.Enabled and #self.racers > 0 and not self.rankedRound then
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

-- Race S of where an entity's marble appears (circuits; nil = no hint needed).
function RoundService:ProgressHint(entity, zone)
	if zone ~= ZONES.Race then
		return nil
	end
	if self.timeTrial and self.timeTrial.ProgressHint then
		local hint = self.timeTrial:ProgressHint(entity)
		if hint then
			return hint
		end
	end
	if self.challenges then
		local hint = self.challenges:ProgressHint(entity) -- challenges brief: solo challenge course
		if hint then
			return hint
		end
	end
	local racer = self.racerByPlayer[entity]
	local layout = self.track:GetLayout(ZONES.Race)
	if not racer or not layout.Loop then
		return nil
	end
	local target = self.state == S.Racing and self.checkpoints:GetConfirmedTarget(entity) or nil
	if target then
		return target.S + RaceConfig.Recovery.CheckpointRespawnAhead
	end
	local slot = layout.GridSlots[((racer.slot - 1) % #layout.GridSlots) + 1]
	return slot.Frame.S - layout.LapLength
end

function RoundService:_raceSeconds()
	local def = self.track:GetLayout(ZONES.Race).Definition
	return def.MaxRaceSeconds or T.MaxRaceSeconds
end

function RoundService:_enterRacing()
	self.graceStarted = false
	self.leaderGrace = false
	self.raceStartClock = os.clock()
	self.raceStartedAt = workspace:GetServerTimeNow()
	self.track:SetStartGateClosed(false)
	local layout = self.track:GetLayout(ZONES.Race)
	local starts = {}
	local behind = layout.Loop and layout.LapLength or 0 -- circuits: the grid is behind the line
	for _, racer in ipairs(self.racers) do
		starts[racer.player] = layout.GridSlots[((racer.slot - 1) % #layout.GridSlots) + 1].Frame.S - behind
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
	self:_setTimer(self:_raceSeconds())
	self.stats = RaceStats.new(layout) -- brief 3: per-sector resets / falls / seam launches
	self.gateLog = {} -- challenges brief: per-target crossing order (rival gap)
end

-- shop brief: the race-start cosmetic snapshot of a player in this round (nil = not racing);
-- MarbleCharacterService uses it for respawns so a race never changes look halfway
function RoundService:LookSnapshot(player)
	local racer = self.racerByPlayer[player]
	return racer and racer.look or nil
end

-- challenges brief: a one-line story for each human racer's results card (from the grid slot,
-- the server's gate log, recoveries and lap times)
function RoundService:_attachStories(standings)
	local gates = self.gateLog or {}
	for _, entry in ipairs(standings) do
		local racer = nil
		for _, r in ipairs(self.racers) do
			if r.userId == entry.userId then
				racer = r
				break
			end
		end
		if racer and not racer.isBot then
			local led, seen, bestGain, lastPlace = 0, 0, 0, nil
			local indices = {}
			for index in pairs(gates) do
				indices[#indices + 1] = index
			end
			table.sort(indices)
			for _, index in ipairs(indices) do
				for at, crossing in ipairs(gates[index]) do
					if crossing.player == racer.player then
						seen = seen + 1
						if at == 1 then
							led = led + 1
						end
						if lastPlace and lastPlace - at > bestGain then
							bestGain = lastPlace - at
						end
						lastPlace = at
						break
					end
				end
			end
			entry.story = RaceRules.StoryLine({ place = entry.place, field = #standings, grid = racer.slot, finished = entry.finished, recoveries = racer.recoveries or 0, laps = racer.lapTimes, ledGates = led, gates = seen, bestGain = bestGain })
		end
	end
end

function RoundService:_enterResults()
	for _, racer in ipairs(self.racers) do
		if not racer.finished then
			racer.dnf = true
		end
	end
	self.results = self.progress:Standings(self.racers)
	self:_attachStories(self.results)
	for _, entry in ipairs(self.results) do
		for _, r in ipairs(self.racers) do
			if r.userId == entry.userId and r.look then
				entry.plate, entry.podium = r.look.plate, r.look.podium
			end
		end
	end
	if self.rankedRound and self.ranked then
		self.ranked:Finalize(self.results) -- deltas from the seal snapshot, idempotent per match id
	end
	-- challenges brief: map mastery "Clean Circuit" - all laps of a circuit race, no reset, no fall
	local raceLayout = self.track:GetLayout(ZONES.Race)
	if self.challenges and raceLayout.Loop and self.track.GetActiveWorldId then
		local mapId = self.track:GetActiveWorldId()
		for _, racer in ipairs(self.racers) do
			if not racer.isBot and racer.finished and (racer.recoveries or 0) == 0 and racer.player and racer.player.Parent then
				self.challenges:OnCleanCircuit(racer.player, mapId)
			end
		end
	end
	if self.stats then
		for _, racer in ipairs(self.racers) do
			self.stats:OnResult(racer.finished == true)
		end
		local summary = self.stats:Summary()
		local def = self.track:GetLayout(ZONES.Race).Definition
		print(string.format("[RaceStats] %s v%d %s: %s", tostring(def.Id), def.LayoutVersion or 1, tostring(self.roundId), summary.line))
		self.lastRaceStats = summary
		local reporter = nil -- AnalyticsService events need a player in the server: any human racer
		for _, racer in ipairs(self.racers) do
			if not racer.isBot and racer.player and racer.player.Parent then
				reporter = racer.player
				break
			end
		end
		if self.telemetry and reporter then
			for _, row in ipairs(summary.sectors) do
				if row.resets + row.falls > 0 then
					self.telemetry:Event(reporter, "race_sector_recoveries", { map = def.Id, sector = row.index, value = row.resets + row.falls })
				end
				if row.launches > 0 then
					self.telemetry:Event(reporter, "race_sector_seam_launch", { map = def.Id, sector = row.index, value = row.launches })
				end
			end
		end
		self.stats = nil
	end
	self:_setTimer(T.ResultsSeconds)
	self.RaceFinished:Fire(self.roundId, self.results)
end

function RoundService:_enterCleanup()
	self.rankedRound = false
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
	if wants and self.timeTrial and self.timeTrial:IsRunning(player) then
		self.timeTrial:Stop(player, "You joined the next race") -- B1: JOIN RACE ends a Time Trial
	end
	if wants and self.challenges and self.challenges:IsRunning(player) then
		self.challenges:Stop(player, "You joined the next race")
	end
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
	if self.timeTrial and not isBot(player) then
		local spot = self.timeTrial:ResolveSpawn(player, reason) -- B1: solo Time Trial
		if spot then
			return spot
		end
	end
	if self.challenges and not isBot(player) then
		local spot = self.challenges:ResolveSpawn(player, reason) -- challenges brief
		if spot then
			return spot
		end
	end
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
				if self.stats then
					self.stats:OnRespawn(player, reason)
				end
				if reason == REASONS.Fell or reason == REASONS.Lost or reason == REASONS.Reset or reason == REASONS.Movement then
					racer.recoveries = (racer.recoveries or 0) + 1 -- challenges brief: Clean Circuit mastery
				end
				local target = self.checkpoints:GetConfirmedTarget(player)
				local cf = target and target.RespawnFrame and self.track:FrameCFrame(target.RespawnFrame) or self.track:GetGridCFrame(racer.slot)
				return { CFrame = cf, Zone = ZONES.Race, Frozen = false }
			end
		end
	end
	-- prompt 03/04: the player's own hub (Orbital Garage if theirs is missing); Practice starts
	-- at that hub's practice lane
	local hubId = self.hubs and self.hubs:HubFor(player) or nil
	if reason == REASONS.Practice and self.track.GetPracticeStartCFrame then
		return { CFrame = self.track:GetPracticeStartCFrame(hubId), Zone = ZONES.Hub, Frozen = false, Hub = hubId }
	end
	return { CFrame = self.track:NextHubSpawnCFrame(hubId), Zone = ZONES.Hub, Frozen = false, Hub = hubId }
end

-- prompt 03/04: on the grid or racing right now (destinations wait until after the race)
function RoundService:IsOnGridOrRacing(player)
	local racer = self.racerByPlayer[player]
	local state = self.state
	return racer ~= nil and not racer.finished and (state == S.Preparing or state == S.Countdown or state == S.Racing)
end

---------------------------------------------------------------------------------------------
-- Observation
---------------------------------------------------------------------------------------------
function RoundService:_onProgress(player, info)
	if info.zone == ZONES.Hub then
		local chute = self.track:GetLayout(ZONES.Hub, info.hubId)
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
	if self.stats then
		self.stats:OnSample(player, info)
	end
	local events = self.checkpoints:Process(player, info)
	if not events then
		return
	end
	local layout = self.track:GetLayout(ZONES.Race)
	for _, event in ipairs(events) do
		if event.kind == "Checkpoint" or event.kind == "Lap" then
			local remote = self.remotes:FindFirstChild("CheckpointFeedback")
			if event.kind == "Lap" then
				racer.lapTimes = racer.lapTimes or {}
				racer.lapTimes[#racer.lapTimes + 1] = event.lapSeconds
			end
			-- challenges brief: signed gap to the racer just ahead at this gate (and tell them)
			self.gateLog = self.gateLog or {}
			self.gateLog[event.index] = self.gateLog[event.index] or {}
			local place, ahead = RaceRules.GateCrossing(self.gateLog[event.index], { time = event.time, player = player, userId = racer.userId, name = racer.name, isBot = racer.isBot == true })
			if remote and ahead and not ahead.isBot and ahead.player and ahead.player.Parent then
				remote:FireClient(ahead.player, { roundId = self.roundId, kind = "GapBehind", index = 0, total = #layout.Checkpoints, behindName = racer.name, behindIsBot = racer.isBot == true, gap = event.time - ahead.time })
			end
			if remote and not racer.isBot then
				remote:FireClient(player, {
					gatePlace = place,
					aheadName = ahead and ahead.name or nil,
					aheadUserId = ahead and ahead.userId or nil,
					aheadIsBot = ahead and ahead.isBot or nil,
					aheadGap = ahead and (event.time - ahead.time) or nil,
					roundId = self.roundId,
					kind = event.kind,
					index = event.checkpoint or 0, -- checkpoint within the lap (0 on a lap line)
					total = #layout.Checkpoints,
					lap = event.kind == "Lap" and (event.lap + 1) or event.lap, -- the lap now being driven
					laps = layout.Loop and layout.Laps or 1,
					lapSeconds = event.lapSeconds,
					serverTime = workspace:GetServerTimeNow(),
				})
			end
		elseif event.kind == "Finish" then
			if event.laps and #event.laps > 0 then
				racer.lapTimes = event.laps
			end
			table.insert(self.pendingFinishes, { racer = racer, time = event.time, seconds = event.seconds, ordinal = racer.ordinal })
		elseif event.kind == "Rejected" then
			self:_warnOnce(player, "cp" .. event.reason, string.format("%s crossing (%s) by %s", self.roundId, event.reason, player.Name))
			if self.anticheat and not isBot(player) then
				self.anticheat:Flag(player, "Checkpoint", event.reason) -- D3 aggregation
			end
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
				notice:FireAllClients({ roundId = self.roundId, userId = racer.userId, name = racer.name, isBot = racer.isBot == true, place = self.finishCounter, seconds = item.seconds, laps = racer.lapTimes })
			end
			self:_clearFinisher(racer)
		end
	end
	self:_startLeaderGrace()
	self:_maybeBroadcastStandings(true)
	self:_checkRaceComplete()
end

-- Circuits: a finished marble would keep rolling into the next lap among racers still on it,
-- so after a short roll-out it moves to the finisher deck beside the line (spectating view).
function RoundService:_clearFinisher(racer)
	local layout = self.track:GetLayout(ZONES.Race)
	if not layout.Loop then
		return
	end
	local delay = RaceConfig.Timers.FinishRollOutSeconds or 1.2
	if racer.isBot then
		if self.bots and self.bots.ScheduleRespawn then
			self.bots:ScheduleRespawn(racer.player, REASONS.Finished, delay)
		end
	elseif racer.player and racer.player.Parent then
		self.marbles:ScheduleRespawn(racer.player, REASONS.Finished, delay)
	end
end

-- Circuits: once the leader finishes, everyone else gets a bounded grace (never more than the
-- race clock had left) - initial value from the lap model until slow-finisher data exists.
function RoundService:_startLeaderGrace()
	local layout = self.track:GetLayout(ZONES.Race)
	if self.leaderGrace or not layout.Loop or self.state ~= S.Racing or self.finishCounter < 1 then
		return
	end
	self.leaderGrace = true
	local grace = layout.Definition.FinishGraceSeconds or RaceConfig.Timers.FinishGraceSeconds or 90
	if self.deadline and self.deadline - os.clock() > grace then
		self:_setTimer(grace)
		self:Broadcast()
	end
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
	BallotRules.Remove(self.ballots, player.UserId) -- prompt 03: a leaver's ballot stops counting
	self.queued[player] = nil
	self.ready[player] = nil
	self.ordinals[player] = nil
	for _, limiter in pairs(self.limiters) do
		limiter:Forget(player) -- A6 cleanup: no per-player state survives a leave
	end
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
			story = entry.story, -- challenges brief: results only (nil during the race)
			plate = entry.plate, -- shop brief: results nameplate + podium effect (race snapshot)
			podium = entry.podium,
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
		checkpointTotal = #self.track:GetLayout(ZONES.Race).Checkpoints, -- per lap
		laps = self.track:GetLayout(ZONES.Race).Loop and self.track:GetLayout(ZONES.Race).Laps or 1,
		mode = self.rankedRound and "Ranked" or "Casual", -- brief 3 E
		finishGrace = self.leaderGrace == true, -- the clock is now the finish grace (show it)
		racers = racers,
		queued = queued,
		humanCount = #Players:GetPlayers(),
		queuedCount = vote.needed,
		raceCapacity = vote.capacity,
		readyOpen = self.state == S.Intermission and RaceConfig.Ready.Enabled and vote.open,
		readyCount = vote.ready,
		ready = ready,
		hazardSeed = self.hazards and self.hazards:GetSeed() or 0,
		chaosModifier = self.chaosModifier,
		hazardEpoch = self.hazards and self.hazards:GetEpoch() or 0,
		worldId = self.track.GetActiveWorldId and self.track:GetActiveWorldId() or nil, -- B1
		nextWorldId = self:GetNextWorldId(),
		ballot = self:_ballotSnapshot(),
		party = self.party and self.party:SnapshotFor() or nil,
	}
end

function RoundService:_ballotSnapshot()
	local ids = self:_eligibleMaps()
	local connected, counted = self:_voterSets()
	local counts, total = BallotRules.Tally(self.ballots, counted, ids)
	return {
		epoch = self.ballots.epoch,
		maps = ids,
		counts = counts,
		counted = total,
		choices = BallotRules.Choices(self.ballots, connected, ids),
		last = self.lastResolution,
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

-- A6: the voted Chaos modifier rides in the snapshot so late joiners apply it too.
function RoundService:SetChaosModifier(modifier)
	self.chaosModifier = modifier
	self:Broadcast()
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
