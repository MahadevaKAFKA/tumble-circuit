--[[
	RacePhysicsService (server, A1 scope) — observes every marble at a fixed low rate:
	route progress (RouteTracker, ADR-09), measured speed, fall-off detection, and a speed-envelope
	anomaly LOG (never a punishment). It publishes Progress for PracticeRunService.

	In A1 the owning client applies the steering forces (client network ownership). The server
	does not apply forces; validating impulses and movement plausibility for competitive rounds is
	A2 work (see BUILD_STATUS "A2 security notes").

	One Heartbeat connection for all players. Elapsed time is accumulated, never discarded.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local PhysicsConfig = require(Shared:WaitForChild("PhysicsConfig"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local RouteTracker = require(Shared:WaitForChild("RouteTracker"))
local Utility = require(Shared:WaitForChild("Utility"))

local RacePhysicsService = {}
RacePhysicsService.__index = RacePhysicsService

function RacePhysicsService.new(trackService, marbleService)
	local self = setmetatable({}, RacePhysicsService)
	self.track = trackService
	self.marbles = marbleService
	self.entries = {}
	self.maid = Utility.Maid.new()
	self.Progress = Utility.Signal.new() -- (player, info) info = {s, distance, speed, position, ...}
	self.Fell = Utility.Signal.new() -- (player)
	return self
end

function RacePhysicsService:Start()
	local layout = self.track:GetLayout()
	self.maid:Give(self.marbles.MarbleSpawned:Connect(function(player, ball)
		self.entries[player] = {
			ball = ball,
			tracker = RouteTracker.new(layout.Route),
			overSpeedSeconds = 0,
			anomalyLogged = false,
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
		for player, entry in pairs(self.entries) do
			self:_observe(player, entry, elapsed)
		end
	end))
end

function RacePhysicsService:_observe(player, entry, elapsed)
	local ball = entry.ball
	if not ball.Parent then
		return
	end
	local position = ball.Position
	local velocity = ball.AssemblyLinearVelocity
	local info = entry.tracker:Update(position)
	info.speed = velocity.Magnitude
	info.position = position
	entry.lastInfo = info

	if position.Y < self.track:GetKillY() then
		self.entries[player] = nil -- stop observing until the next spawn
		self.Fell:Fire(player)
		self.marbles:ScheduleRespawn(player, Protocol.SpawnReasons.Fell, GameConfig.Spawn.FallRespawnDelaySeconds)
		return
	end

	local envelope = PhysicsConfig.Movement.TerminalSpeed * PhysicsConfig.Server.AnomalySpeedFactor
	if info.speed > envelope then
		entry.overSpeedSeconds = entry.overSpeedSeconds + elapsed
		if entry.overSpeedSeconds >= PhysicsConfig.Server.AnomalySustainSeconds and not entry.anomalyLogged then
			entry.anomalyLogged = true
			warn(string.format(
				"[RacePhysics] anomaly (logged only): %s held %.0f studs/s, envelope %.0f",
				player.Name,
				info.speed,
				envelope
			))
		end
	else
		entry.overSpeedSeconds = 0
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
