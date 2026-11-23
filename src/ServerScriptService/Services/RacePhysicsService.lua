--[[
	RacePhysicsService (server) — observes every marble at PhysicsConfig.Server.MonitorHz:
	  * route progress on the marble's zone (RouteTracker, ADR-09), measured speed
	  * falls: below the zone's kill height, or (race zone) far off the route for a while
	  * movement audit: distance moved over a sliding window vs the plausibility envelope
	    (catches teleports without flagging replication hiccups); logged, and reported so the
	    round can put the marble back at its last confirmed checkpoint. Never a ban.
	Publishes Progress (consumed by checkpoints/standings), Fell and MovementRejected.

	Client network ownership means forces are applied by the owning client; this service is the
	server's audit of the result. Exposes the envelope and impulse caps for later milestones.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PhysicsConfig = require(Shared:WaitForChild("PhysicsConfig"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local RaceConfig = require(Shared:WaitForChild("RaceConfig"))
local RouteTracker = require(Shared:WaitForChild("RouteTracker"))
local Utility = require(Shared:WaitForChild("Utility"))
local RaceRules = require(script.Parent:WaitForChild("RaceRules"))

local RacePhysicsService = {}
RacePhysicsService.__index = RacePhysicsService

-- Largest velocity change any server-approved impulse may impose (studs/s). A3 abilities use it.
RacePhysicsService.ImpulseCaps = {
	BumperKick = PhysicsConfig.Hazards.PulseBumper.KickSpeed,
	MarbleBump = RaceConfig.Collisions.MaxBumpDeltaV,
}

function RacePhysicsService.new(trackService, marbleService)
	local self = setmetatable({}, RacePhysicsService)
	self.track = trackService
	self.marbles = marbleService
	self.entries = {}
	self.maid = Utility.Maid.new()
	self.Progress = Utility.Signal.new() -- (player, info)
	self.Fell = Utility.Signal.new() -- (player, zone)
	self.MovementRejected = Utility.Signal.new() -- (player, info)
	self.SampleComplete = Utility.Signal.new() -- () after every player was observed this sample
	return self
end

function RacePhysicsService:GetEnvelope()
	local v = RaceConfig.Validation
	return {
		terminalSpeed = PhysicsConfig.Movement.TerminalSpeed,
		factor = v.PlausibleSpeedFactor,
		windowSeconds = v.WindowSeconds,
		slackStuds = v.SlackStuds,
	}
end

function RacePhysicsService:Start()
	self.maid:Give(self.marbles.MarbleSpawned:Connect(function(player, ball, _, zone)
		local layout = self.track:GetLayout(zone)
		self.entries[player] = {
			ball = ball,
			zone = zone,
			layout = layout,
			tracker = RouteTracker.new(layout.Route),
			history = {},
			offRouteSeconds = 0,
			lastS = nil,
			lastTime = nil,
			lastInfo = nil,
		}
	end))
	self.maid:Give(self.marbles.MarbleRemoved:Connect(function(player)
		self.entries[player] = nil
	end))
	self.maid:Give(Players.PlayerRemoving:Connect(function(player)
		self.entries[player] = nil
	end))

	local interval = 1 / PhysicsConfig.Server.MonitorHz
	local accumulated = 0
	self.maid:Give(RunService.Heartbeat:Connect(function(dt)
		accumulated = accumulated + dt
		if accumulated < interval then
			return
		end
		local elapsed = accumulated
		accumulated = 0
		local now = os.clock()
		for player, entry in pairs(self.entries) do
			self:_observe(player, entry, elapsed, now)
		end
		self.SampleComplete:Fire()
	end))
end

function RacePhysicsService:_observe(player, entry, elapsed, now)
	local ball = entry.ball
	if not ball.Parent then
		return
	end
	local position = ball.Position
	local info = entry.tracker:Update(position)
	info.speed = ball.AssemblyLinearVelocity.Magnitude
	info.position = position
	info.zone = entry.zone
	info.time = now
	info.prevS = entry.lastS
	info.prevTime = entry.lastTime
	info.halfWidth = entry.layout.Sections[math.min(info.index, #entry.layout.Sections)].Width / 2
	info.frozen = ball.Anchored
	entry.lastS = info.s
	entry.lastTime = now
	entry.lastInfo = info

	-- Falls
	local fell = position.Y < self.track:GetKillY(entry.zone)
	if not fell and entry.zone == Protocol.Zones.Race and not ball.Anchored then
		if info.distance > RaceConfig.Recovery.OffRouteDistance then
			entry.offRouteSeconds = entry.offRouteSeconds + elapsed
			fell = entry.offRouteSeconds >= RaceConfig.Recovery.OffRouteSeconds
		else
			entry.offRouteSeconds = 0
		end
	end
	if fell then
		self.entries[player] = nil -- stop observing until the next spawn
		self.Fell:Fire(player, entry.zone)
		self.marbles:ScheduleRespawn(player, Protocol.SpawnReasons.Fell, RaceConfig.Recovery.FallRespawnDelaySeconds)
		return
	end

	-- Movement audit over a sliding window (spawns reset the history).
	local history = entry.history
	history[#history + 1] = { t = now, p = position }
	local window = RaceConfig.Validation.WindowSeconds
	while #history > 2 and history[2].t <= now - window do
		table.remove(history, 1)
	end
	local oldest = history[1]
	local span = now - oldest.t
	if span >= window * 0.9 then
		local env = self:GetEnvelope()
		local moved = (position - oldest.p).Magnitude
		if RaceRules.ExceedsEnvelope(moved, span, env.terminalSpeed, env.factor, env.slackStuds) then
			warn(string.format("[RacePhysics] movement rejected (logged): %s moved %.0f studs in %.2fs (zone %s)", player.Name, moved, span, entry.zone))
			info.rejected = true
			entry.history = { { t = now, p = position } }
			self.MovementRejected:Fire(player, info)
			return
		end
	end

	self.Progress:Fire(player, info)
end

function RacePhysicsService:GetLastInfo(player)
	local entry = self.entries[player]
	return entry and entry.lastInfo
end

function RacePhysicsService:Destroy()
	self.maid:Cleanup()
	self.entries = {}
end

return RacePhysicsService
