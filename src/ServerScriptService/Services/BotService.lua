--[[
	BotService (A4, ADR-08) — server-owned bot racers that fill the grid to RaceConfig.Bots.FillTo.
	* Same body (BotFactory), same MarbleMotorController code humans run, same caps, same hazard
	  contact model (HazardSim + pulse bumper timing), same checkpoint judging and recovery.
	* Brain: BotBrain (skill = consistency of decisions, never speed). Labelled [BOT] everywhere.
	* Spawned for a round on the grid (frozen), released at GO, despawned at Cleanup. Never in
	  the hub/practice chute, never persisted, never counted for human records (A5 rewards skip).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local HazardTiming = require(Shared:WaitForChild("HazardTiming"))
local HazardSim = require(Shared:WaitForChild("HazardSim"))
local PhysicsConfig = require(Shared:WaitForChild("PhysicsConfig"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local RaceConfig = require(Shared:WaitForChild("RaceConfig"))
local RouteTracker = require(Shared:WaitForChild("RouteTracker"))
local Utility = require(Shared:WaitForChild("Utility"))
local BotBrain = require(script.Parent:WaitForChild("BotBrain"))
local BotFactory = require(ServerStorage:WaitForChild("ProceduralBuilders"):WaitForChild("BotFactory"))
local MarbleMotorController = require(Shared:WaitForChild("MarbleMotorController")) -- the human motor

local BotService = {}
BotService.__index = BotService

function BotService.new(deps)
	local self = setmetatable({}, BotService)
	self.track = deps.track
	self.physics = deps.physics
	self.hazards = deps.hazards
	self.abilities = deps.abilities
	self.round = nil -- set by RoundService:AttachBots
	self.bots = {}
	self.maid = Utility.Maid.new()
	self.BotSpawned = Utility.Signal.new() -- (bot, ball, reason) like MarbleCharacterService.MarbleSpawned
	-- Playtest diagnostics (owner report 2026-11-25: bots vanished at GO and all showed DNF).
	-- Published every second as workspace attribute Bots_Status, shown in the stats box.
	self.diag = { respawns = {}, errors = 0, lastError = nil, lastWarn = 0 }
	self.statusTimer = 0
	return self
end

function BotService:_bindWorld()
	local layout = self.track:GetLayout(Protocol.Zones.Race)
	self.layout = layout
	self.bumpers = {}
	for _, hz in ipairs(self.hazards:GetResolved()) do
		if hz.Kind == "PulseBumper" and hz.Frame then
			table.insert(self.bumpers, { hazard = hz, floorPoint = hz.Frame.Position + hz.Frame.Right * (hz.Offset or 0), axis = hz.Frame.Up, contact = hz.Definition.Radius + PhysicsConfig.Ball.Radius + PhysicsConfig.Hazards.PulseBumper.ContactPadding, height = hz.Definition.Height })
		end
	end
	self.splitRanges, self.dropRanges = {}, {}
	local segmentKind = {} -- B1: module kind by segment (new worlds name their segments differently)
	for _, piece in ipairs(layout.Pieces) do
		segmentKind[piece.Segment] = segmentKind[piece.Segment] or piece.Definition.Kind
	end
	for _, piece in ipairs(layout.Pieces) do
		local a, b = layout.Sections[piece.FirstSection].S, layout.Sections[piece.LastSection].S
		if piece.Definition.Divider then
			table.insert(self.splitRanges, { a - 30, b })
		end
		if segmentKind[piece.Segment] == "DropShaft" then
			table.insert(self.dropRanges, { a - 30, b })
		end
	end
end

function BotService:Start()
	-- MarbleCharacterService.new creates this folder before any service starts; never wait for it
	-- (an unbounded wait here could stall server start-up, see BUILD_STATUS 2026-11-25).
	self.folder = workspace:FindFirstChild(Protocol.MarblesFolderName)
	assert(self.folder, "[Bots] marbles folder missing: MarbleCharacterService.new must run first")
	self:_bindWorld()
	if self.hazards.WorldBound then
		self.maid:Give(self.hazards.WorldBound:Connect(function()
			self:_bindWorld()
		end))
	end
	self.abilities:SetBotHooks({
		applyEffects = function(bot, effects)
			local entry = self.bots[bot]
			if entry and entry.motor then
				entry.motor:SetEffects(effects)
			end
		end,
		applyImpulse = function(bot, direction, deltaV, cap)
			local entry = self.bots[bot]
			if entry and entry.motor then
				entry.motor:ApplyExternalImpulse(direction, deltaV, math.min(cap or 18, 24))
			end
		end,
	})
	self.maid:Give(RunService.Heartbeat:Connect(function(dt)
		self:_step(dt)
	end))
end

-- A fresh roster for one round (deterministic names/skills per round).
function BotService:CreateRoster(count, roundId)
	self.diag.respawns, self.diag.errors, self.diag.lastError = {}, 0, nil -- per-round diagnostics
	local roster = {}
	local rng = BotBrain.Rng(roundId * 7919 + 13)
	for i = 1, count do
		local name = BotBrain.Names[((roundId + i - 2) % #BotBrain.Names) + 1]
		local skill = BotBrain.Skills[((i - 1) % #BotBrain.Skills) + 1]
		roster[i] = { isBot = true, UserId = -i, DisplayName = name, Name = "[BOT] " .. name, Parent = true, skill = skill, seed = math.floor(rng() * 1e6) }
	end
	return roster
end

function BotService:GetBall(bot)
	local entry = self.bots[bot]
	return entry and entry.ball
end

function BotService:IsBot(entity)
	return type(entity) == "table" and entity.isBot == true
end

function BotService:Spawn(bot, reason)
	local entry = self.bots[bot] or { generation = 0, rng = BotBrain.Rng(bot.seed), brain = {} }
	self.bots[bot] = entry
	entry.generation = entry.generation + 1
	entry.pending = false
	self.diag.respawns[reason] = (self.diag.respawns[reason] or 0) + 1
	self:_destroyBall(bot, entry)
	local spot = self.round:ResolveSpawn(bot, reason)
	if not spot or spot.Zone ~= Protocol.Zones.Race then
		return nil -- bots never go to the hub
	end
	local ball = BotFactory.CreateBall(bot, spot.CFrame, spot.Frozen == true)
	ball.Parent = self.folder
	if not ball.Anchored then
		pcall(function()
			ball:SetNetworkOwner(nil)
		end)
		self:_endProtectionLater(bot, ball)
	end
	entry.ball = ball
	entry.tracker = RouteTracker.new(self.layout.Route)
	entry.forward = Vector3.new(0, 0, -1)
	entry.lastProgressS, entry.lastProgressAt = nil, os.clock()
	entry.kickCooldown = {}
	entry.motor = MarbleMotorController.new()
	entry.motor:Bind(ball, { self.folder })
	entry.motor:SetMarblesFolder(self.folder)
	entry.motor:SetEnvironmentAccel(function(position)
		return self.hazards:EnvironmentAccelFor(position)
	end)
	self.abilities:CancelEffects(bot)
	self.physics:Track(bot, ball, Protocol.Zones.Race, function()
		self:ScheduleRespawn(bot, Protocol.SpawnReasons.Fell, RaceConfig.Recovery.FallRespawnDelaySeconds)
	end)
	self.BotSpawned:Fire(bot, ball, reason)
	return ball
end

function BotService:_endProtectionLater(bot, ball)
	task.delay(RaceConfig.Recovery.ProtectionSeconds, function()
		local entry = self.bots[bot]
		if entry and entry.ball == ball and ball.Parent then
			ball.CollisionGroup = RaceConfig.Collisions.MarbleGroup
			ball.Transparency = 0
			ball:SetAttribute(Protocol.BallAttributes.Protected, false)
		end
	end)
end

-- GO: replace the frozen grid ball with a fresh free one on the same slot (the spawn resolver
-- returns the grid slot, unfrozen, once Racing). Unanchoring the grid ball in place is what left
-- human marbles unable to move at GO (owner playtest 2026-11-23); bots used that path until the
-- owner saw them stay at the start and vanish (2026-11-25). Same fix for both now.
function BotService:Release(bot)
	local entry = self.bots[bot]
	local ball = entry and entry.ball
	if ball and ball.Parent and ball.Anchored then
		return self:Spawn(bot, Protocol.SpawnReasons.Go) ~= nil
	end
	return false
end

function BotService:ScheduleRespawn(bot, reason, delaySeconds)
	local entry = self.bots[bot]
	if not entry or entry.pending then
		return
	end
	entry.pending = true
	local generation = entry.generation
	task.delay(delaySeconds, function()
		local current = self.bots[bot]
		if current == entry and entry.generation == generation then
			self:Spawn(bot, reason)
		end
	end)
end

function BotService:_destroyBall(bot, entry)
	if entry.motor then
		entry.motor:Unbind()
		entry.motor = nil
	end
	if entry.ball then
		entry.ball:Destroy()
		entry.ball = nil
	end
	self.physics:Untrack(bot)
end

function BotService:DespawnAll()
	for bot, entry in pairs(self.bots) do
		entry.generation = entry.generation + 1
		self:_destroyBall(bot, entry)
		self.abilities:Forget(bot)
	end
	self.bots = {}
end

function BotService:Count()
	local n = 0
	for _ in pairs(self.bots) do
		n = n + 1
	end
	return n
end

local function inRanges(ranges, s)
	for _, r in ipairs(ranges) do
		if s >= r[1] and s <= r[2] then
			return true
		end
	end
	return false
end

function BotService:_hazardContext(s, speed)
	return BotBrain.HazardContext(self.hazards:GetResolved(), self.layout.Sections, s, speed, self.hazards:Time())
end

function BotService:_nearbyRacers(bot, position, radius)
	local n = 0
	for _, other in ipairs(self.round:GetActiveRacers()) do
		if other ~= bot then
			local ball = self.round:GetBallFor(other)
			if ball and ball.Parent and (ball.Position - position).Magnitude <= radius then
				n = n + 1
			end
		end
	end
	return n
end

-- Same AbilityService path (and cooldowns) humans use; BotBrain only picks when.
function BotService:_maybeUseAbility(bot, entry, info, speed, hazards, now)
	if now < (entry.nextAbilityCheck or 0) then
		return
	end
	entry.nextAbilityCheck = now + 0.5
	local ready = {}
	for _, item in ipairs(self.abilities:ReadySlots(bot)) do
		ready[item.id] = item.slot
	end
	if next(ready) == nil then
		return
	end
	local hazardAhead = math.huge
	for _, hz in ipairs(hazards) do
		local ahead = hz.s - info.s
		if ahead > 0 and ahead < hazardAhead and (hz.kind == "PulseBumper" or hz.kind == "Sweeper" or hz.kind == "Hammer") then
			hazardAhead = ahead
		end
	end
	local id = BotBrain.ChooseAbility({
		ready = ready,
		hazardAhead = hazardAhead,
		nearby = self:_nearbyRacers(bot, entry.ball.Position, 10),
		speed = speed,
		skill = bot.skill,
		rng = entry.rng,
	})
	if id and ready[id] then
		self.abilities:Activate(bot, ready[id])
	end
end

function BotService:_hit(bot, entry, apply)
	if self.abilities:IsShielded(bot) then
		self.abilities:ConsumeShield(bot, "Hazard")
		return
	end
	apply()
end

function BotService:_step(dt)
	local now = os.clock()
	local hazardTime = self.hazards:Time()
	local cfgBumper = PhysicsConfig.Hazards.PulseBumper
	for bot, entry in pairs(self.bots) do
		-- one failing bot must not stop the others (an error used to abort the whole loop every
		-- frame); the error is counted, shown in the stats box and warned at most every 10 s
		local ok, err = pcall(self._stepBot, self, bot, entry, dt, now, hazardTime, cfgBumper)
		if not ok then
			self.diag.errors = self.diag.errors + 1
			self.diag.lastError = tostring(err)
			if now - self.diag.lastWarn > 10 then
				self.diag.lastWarn = now
				warn("[Bots] step error (" .. bot.Name .. "): " .. tostring(err))
			end
		end
	end
	self.statusTimer = self.statusTimer + dt
	if self.statusTimer >= 1 then
		self.statusTimer = 0
		self:_publishStatus()
	end
end

-- One line for the stats box: how many bots race, how many actually move, how far the best got,
-- and why they respawned. Tells a phone playtest where bots go wrong.
function BotService:_publishStatus()
	if next(self.bots) == nil then
		workspace:SetAttribute("Bots_Status", "") -- no bots (hub / between rounds): no stats line
		return
	end
	local racing, moving, bestCp = 0, 0, 0
	for bot, entry in pairs(self.bots) do
		local ball = entry.ball
		if self.round and self.round:IsActiveRacer(bot) then
			racing = racing + 1
			if ball and ball.Parent and not ball.Anchored and ball.AssemblyLinearVelocity.Magnitude > 5 then
				moving = moving + 1
			end
		end
		if self.round and self.round.checkpoints then
			bestCp = math.max(bestCp, self.round.checkpoints:GetConfirmed(bot))
		end
	end
	local r = self.diag.respawns
	local status = string.format(
		"%d racing, %d moving, best CP %d/%d | fell %d stuck %d audit %d | errors %d",
		racing,
		moving,
		bestCp,
		#self.layout.Checkpoints,
		r.Fell or 0,
		r.Reset or 0,
		r.Movement or 0,
		self.diag.errors
	)
	workspace:SetAttribute("Bots_Status", status)
	workspace:SetAttribute("Bots_LastError", self.diag.lastError and string.sub(self.diag.lastError, 1, 120) or "")
end

function BotService:_stepBot(bot, entry, dt, now, hazardTime, cfgBumper)
	do
		local ball = entry.ball
		if ball and ball.Parent and entry.motor then
			local info = entry.tracker:Update(ball.Position)
			local section = self.layout.Sections[math.min(info.index, #self.layout.Sections)]
			local target = RouteTracker.HorizontalTangentAtS(self.layout.Route, info.s + 4)
			if target then
				entry.forward = Utility.safeUnit(Vector3.new(target.X, 0, target.Z), entry.forward)
			end
			local v = ball.AssemblyLinearVelocity
			local rel = ball.Position - info.closest
			local racing = not ball.Anchored and self.round:IsActiveRacer(bot)
			local mode = MarbleMotorController.Modes.Idle
			local steer, throttle, brake = 0, 0, false
			if racing then
				mode = MarbleMotorController.Modes.Play
				local hazards = self:_hazardContext(info.s, v.Magnitude)
				self:_maybeUseAbility(bot, entry, info, v.Magnitude, hazards, now)
				steer, throttle, brake = BotBrain.Decide(entry.brain, {
					lateral = rel:Dot(section.Right),
					lateralVelocity = v:Dot(section.Right),
					speed = v.Magnitude,
					s = info.s,
					halfWidth = section.Width / 2,
					hazards = hazards,
					splitAhead = inRanges(self.splitRanges, info.s),
					dropAhead = inRanges(self.dropRanges, info.s),
					skill = bot.skill,
					rng = entry.rng,
					now = now,
				})
			elseif self.round:IsFinishedRacer(bot) then
				mode = MarbleMotorController.Modes.Finished
			end
			entry.motor:Step(dt, { mode = mode, steer = Vector2.new(steer, throttle), brake = brake, brakePressed = brake and not entry.braking, forwardH = entry.forward })
			entry.braking = brake

			if not ball.Anchored then
				-- same hazard contact model the human clients apply to their own marbles
				local kick, id, kind = self.hazards:ContactFor(ball.Position, PhysicsConfig.Ball.Radius)
				local phased = entry.motor:HasStatus("Phase") -- B2: same rule as human clients
				if kick and kind ~= "Trampoline" and phased then
					kick = nil
				end
				if kick and (entry.kickCooldown[id] or 0) <= now then
					entry.kickCooldown[id] = now + 0.5
					local function apply()
						entry.motor:ApplyExternalImpulse(kick, math.min(kick.Magnitude, HazardSim.KickCap + 15), HazardSim.KickCap + 15)
					end
					if kind == "Trampoline" then
						apply() -- a feature, not a hit: shields never block the pad
					else
						self:_hit(bot, entry, apply)
					end
				end
				for i, bumper in ipairs(self.bumpers) do
					local offset = (bumper.hazard.Params and bumper.hazard.Params.PhaseOffset) or 0
					local phase = HazardTiming.PhaseAt(hazardTime + offset, cfgBumper)
					if phase == "Active" and not phased and (entry.kickCooldown["b" .. i] or 0) <= now then
						local d, along, radial = HazardTiming.AxisDistance(ball.Position, bumper.floorPoint, bumper.axis)
						if along > -1 and along < bumper.height + 1 and d > 1e-3 and d <= bumper.contact then
							entry.kickCooldown["b" .. i] = now + cfgBumper.CooldownSeconds
							self:_hit(bot, entry, function()
								entry.motor:ApplyKick(radial / d, cfgBumper.KickSpeed * self.hazards:BumperKickMultiplier())
							end)
						end
					end
				end
				-- stuck: no route progress (slow for 4 s, or rocking in place for 8 s) -> back to the
				-- last checkpoint, exactly like a human's hold-to-recover. Repeats are logged once.
				if racing then
					if not entry.lastProgressS or info.s > entry.lastProgressS + 2 then
						entry.lastProgressS, entry.lastProgressAt = info.s, now
						if entry.stuckAtS and info.s > entry.stuckAtS + 30 then
							entry.stuckResets, entry.stuckAtS = 0, nil -- got past the problem spot
						end
					elseif (now - entry.lastProgressAt > 4 and v.Magnitude < 2) or now - entry.lastProgressAt > 8 then
						entry.lastProgressAt = now
						entry.stuckResets = (entry.stuckResets or 0) + 1
						entry.stuckAtS = info.s
						if entry.stuckResets == 3 then
							warn(string.format("[Bots] %s stuck 3x near route distance %.0f - check this spot in a playtest", bot.Name, info.s))
						end
						self:ScheduleRespawn(bot, Protocol.SpawnReasons.Reset, 0.2)
					end
				end
			end
		end
	end
end

function BotService:Destroy()
	self:DespawnAll()
	self.maid:Cleanup()
end

return BotService
