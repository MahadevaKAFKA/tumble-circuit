--[[
	RankService (graphics/gameplay/ranked brief, milestone E, 2026-11-26) — the opt-in Ranked
	Circuit TEST on top of the normal queue (no second always-open queue while traffic is low).

	* A player opts in (RequestRankedOptIn). A round is RANKED only when ranked is enabled, every
	  queued human opted in and there are >= RankRules.MinHumans of them; otherwise it is a normal
	  Casual race and the RankState says honestly why ("needs 4 ranked players - Casual for now").
	* Ranked rounds use one fixed shared ruleset: no bot fill, no Chaos Gate comeback boosts, no
	  abilities (loadout advantages); default trails / launch animations stay visual only.
	* At the seal (Preparing) the roster and every rating are snapshotted. At Results the deltas
	  come from that snapshot (RankRules.Deltas) and apply per player idempotently by match id;
	  a player who left keeps an unsettled result that applies if they rejoin this server.
	  A round with fewer than MinHumans at the seal, or without a finalized result, changes
	  nothing (aborted / faulted rounds are neutral).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local RankRules = require(Shared:WaitForChild("RankRules"))
local Utility = require(Shared:WaitForChild("Utility"))

local RankService = {}
RankService.__index = RankService

-- Feature flags. Enabled = the opt-in test is offered (private builds); PublicDiscovery stays off
-- until traffic and repeatable validation justify it (the owner flips it).
RankService.Config = { Enabled = true, PublicDiscovery = false }

function RankService.new(deps)
	local self = setmetatable({}, RankService)
	self.data = deps.data
	self.round = deps.round
	self.remotes = deps.remotes
	self.maid = Utility.Maid.new()
	self.optIn = {}
	self.sealed = nil -- { matchId, roster = { [userId] = { rating, placements } } }
	self.unsettled = {} -- [userId] = { matchId, delta, place, n }
	self.lastResult = {} -- [userId] = { delta, rating, tier, pending }
	return self
end

-- Pure: should this queue be a Ranked round? humans = list of { userId, optedIn }
function RankService.ShouldRank(enabled, humans)
	if not enabled then
		return false, "Ranked test is off"
	end
	local opted = 0
	for _, h in ipairs(humans) do
		if not h.optedIn then
			return false, "someone in this race is in Casual"
		end
		opted = opted + 1
	end
	if opted < RankRules.MinHumans then
		return false, string.format("needs %d ranked players (%d queued) - Casual races continue", RankRules.MinHumans, opted)
	end
	return true, nil
end

function RankService:Start()
	local remote = self.remotes:FindFirstChild("RequestRankedOptIn")
	if remote then
		self.maid:Give(remote.OnServerEvent:Connect(function(player, wants)
			if type(wants) ~= "boolean" then
				return
			end
			self.optIn[player] = wants and RankService.Config.Enabled or nil
			self:SendState(player)
		end))
	end
	self.maid:Give(Players.PlayerRemoving:Connect(function(player)
		self.optIn[player] = nil
	end))
	self.maid:Give(Players.PlayerAdded:Connect(function(player)
		task.delay(3, function()
			self:_settle(player)
			self:SendState(player)
		end)
	end))
end

function RankService:IsOptedIn(player)
	return self.optIn[player] == true
end

-- RoundService asks at Preparing, before bots fill: returns isRanked
function RankService:Seal(roundId, humanRacers)
	local humans = {}
	for _, racer in ipairs(humanRacers) do
		humans[#humans + 1] = { userId = racer.userId, optedIn = self.optIn[racer.player] == true }
	end
	local ranked, why = RankService.ShouldRank(RankService.Config.Enabled, humans)
	self.waitNote = why
	if not ranked then
		self.sealed = nil
		for _, racer in ipairs(humanRacers) do
			if self.optIn[racer.player] then
				self:SendState(racer.player)
			end
		end
		return false
	end
	local roster = {}
	for _, racer in ipairs(humanRacers) do
		local profile = self.data and self.data:GetProfile(racer.player)
		local rank = profile and profile.data.rank or RankRules.Default()
		roster[racer.userId] = { rating = rank.rating, placements = rank.placements } -- immutable snapshot
	end
	self.sealed = { matchId = string.format("%s:%s", tostring(game.JobId ~= "" and game.JobId or "studio"), tostring(roundId)), roster = roster }
	return true
end

function RankService:IsRankedRound()
	return self.sealed ~= nil
end

-- RoundService at Results: standings = sorted entries { userId, place, finished, isBot }
function RankService:Finalize(standings)
	local sealed = self.sealed
	self.sealed = nil
	if not sealed then
		return
	end
	local roster, humans = {}, {}
	for _, entry in ipairs(standings) do
		local snap = sealed.roster[entry.userId]
		if snap and not entry.isBot then
			roster[#roster + 1] = { userId = entry.userId, rating = snap.rating, placements = snap.placements, place = entry.place, finished = entry.finished == true }
			humans[#humans + 1] = { userId = entry.userId }
		end
	end
	-- a sealed player missing from the standings (left before results) is a DNF
	for userId, snap in pairs(sealed.roster) do
		local found = false
		for _, r in ipairs(roster) do
			found = found or r.userId == userId
		end
		if not found then
			roster[#roster + 1] = { userId = userId, rating = snap.rating, placements = snap.placements, finished = false }
			humans[#humans + 1] = { userId = userId }
		end
	end
	local ok = RankRules.Eligible(humans, true)
	if not ok then
		return -- neutral: not enough humans stayed to score this round
	end
	local deltas = RankRules.Deltas(roster)
	for _, r in ipairs(roster) do
		self.unsettled[r.userId] = { matchId = sealed.matchId, delta = deltas[r.userId] or 0, place = r.place, n = #roster }
		local player = Players:GetPlayerByUserId(r.userId)
		if player then
			self:_settle(player)
		end
	end
end

-- apply an unsettled result to a loaded profile (idempotent by match id)
function RankService:_settle(player)
	local pending = self.unsettled[player.UserId]
	if not pending then
		return
	end
	local applied, rating = false, nil
	local updated = self.data and self.data:Update(player, function(data)
		data.rank = data.rank or RankRules.Default()
		applied, rating = RankRules.Apply(data.rank, pending.matchId, pending.delta, pending.place, pending.n)
	end)
	if updated then
		self.unsettled[player.UserId] = nil
		if self.data.SaveSoon then
			self.data:SaveSoon(player)
		end
		local profile = self.data:GetProfile(player)
		local rank = profile and profile.data.rank
		self.lastResult[player.UserId] = { delta = applied and pending.delta or 0, rating = rating, pending = false }
		if rank then
			self:SendState(player)
		end
	else
		self.lastResult[player.UserId] = { delta = pending.delta, pending = true } -- shown as "pending", never invented
		self:SendState(player)
	end
end

function RankService:SendState(player)
	local remote = self.remotes:FindFirstChild("RankState")
	if not remote or not player.Parent then
		return
	end
	local profile = self.data and self.data:GetProfile(player)
	local rank = profile and profile.data.rank or RankRules.Default()
	local tier, placed = RankRules.Tier(rank.rating, rank.placements)
	remote:FireClient(player, {
		enabled = RankService.Config.Enabled,
		optIn = self.optIn[player] == true,
		rating = rank.rating,
		placements = rank.placements,
		placementRaces = RankRules.PlacementRaces,
		tier = tier,
		placed = placed,
		progress = RankRules.TierProgress(rank.rating),
		season = rank.season,
		minHumans = RankRules.MinHumans,
		waitNote = self.optIn[player] and self.waitNote or nil,
		last = self.lastResult[player.UserId],
		history = rank.history,
	})
end

function RankService:Destroy()
	self.maid:Cleanup()
end

return RankService
