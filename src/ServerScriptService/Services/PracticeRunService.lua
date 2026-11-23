--[[
	PracticeRunService — server-timed practice runs (A1 only; no rounds, no rewards).

	Ready    : marble spawned on the pad. Timer at 0.
	Running  : route progress passed the start line. Server records os.clock() for the duration and
	           publishes workspace:GetServerTimeNow() so clients can draw a live timer.
	Finished : progress passed the finish line AND the ordered course marks were reached in order.
	           Runs shorter than GameConfig.Run.MinPlausibleSeconds are logged and not recorded as best.

	A respawn for any reason (reset, fall, Try Again) starts a fresh Ready run.
	State is published as Player attributes (see Protocol).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local Utility = require(Shared:WaitForChild("Utility"))

local PracticeRunService = {}
PracticeRunService.__index = PracticeRunService

local ATTR = Protocol.PlayerAttributes
local STATES = Protocol.RunStates
local OFF_ROUTE_DISTANCE = 25 -- farther than this from the centreline counts as "not on course"

function PracticeRunService.new(trackService, marbleService, physicsService)
	local self = setmetatable({}, PracticeRunService)
	self.track = trackService
	self.marbles = marbleService
	self.physics = physicsService
	self.runs = {}
	self.maid = Utility.Maid.new()
	self.RunFinished = Utility.Signal.new() -- (player, seconds, isBest, plausible)
	return self
end

function PracticeRunService:Start()
	self.maid:Give(self.marbles.MarbleSpawned:Connect(function(player)
		self:_setReady(player)
	end))
	self.maid:Give(self.physics.Progress:Connect(function(player, info)
		self:_onProgress(player, info)
	end))
	self.maid:Give(Players.PlayerRemoving:Connect(function(player)
		self.runs[player] = nil
	end))
end

function PracticeRunService:_setReady(player)
	local run = self.runs[player] or { best = nil }
	run.state = STATES.Ready
	run.startClock = nil
	run.marks = {}
	self.runs[player] = run
	player:SetAttribute(ATTR.RunStartServerTime, 0)
	player:SetAttribute(ATTR.LastRunWasBest, false)
	player:SetAttribute(ATTR.RunState, STATES.Ready)
end

function PracticeRunService:_onProgress(player, info)
	local run = self.runs[player]
	if not run or info.distance > OFF_ROUTE_DISTANCE then
		return
	end
	local layout = self.track:GetLayout()

	if run.state == STATES.Ready then
		if info.s > layout.StartLineS + 0.5 then
			run.state = STATES.Running
			run.startClock = os.clock()
			run.marks = {}
			player:SetAttribute(ATTR.RunStartServerTime, workspace:GetServerTimeNow())
			player:SetAttribute(ATTR.RunState, STATES.Running)
		end
	elseif run.state == STATES.Running then
		for i, mark in ipairs(layout.Marks) do
			if not run.marks[i] and info.s >= mark.S and (i == 1 or run.marks[i - 1]) then
				run.marks[i] = true
			end
		end
		if info.s >= layout.FinishLineS then
			for i = 1, #layout.Marks do
				if not run.marks[i] then
					return -- reached the finish without the ordered marks: not a valid finish
				end
			end
			self:_finish(player, run)
		end
	end
end

function PracticeRunService:_finish(player, run)
	local seconds = os.clock() - run.startClock
	run.state = STATES.Finished
	local plausible = seconds >= GameConfig.Run.MinPlausibleSeconds
	if not plausible then
		warn(string.format("[PracticeRun] implausible %.2fs finish by %s (logged, not recorded)", seconds, player.Name))
	end
	local isBest = plausible and (run.best == nil or seconds < run.best)
	if isBest then
		run.best = seconds
	end
	player:SetAttribute(ATTR.LastRunSeconds, seconds)
	player:SetAttribute(ATTR.BestSeconds, run.best)
	player:SetAttribute(ATTR.LastRunWasBest, isBest)
	player:SetAttribute(ATTR.RunState, STATES.Finished) -- set last: clients render on this change
	self.RunFinished:Fire(player, seconds, isBest, plausible)
end

function PracticeRunService:Destroy()
	self.maid:Cleanup()
	self.runs = {}
end

return PracticeRunService
