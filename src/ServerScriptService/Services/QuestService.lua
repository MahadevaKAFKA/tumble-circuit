--[[
	QuestService (B3) — daily / weekly quests (QuestConfig). Progress only from server events:
	race results (RoundService.RaceFinished + EconomyService.Granted for PBs), ability activations
	in races (AbilityService.Activated), judged tricks (MicroSkillService.TrickLanded), Chaos Gates
	(ChaosGateService.GateCollected), Time Trial finishes (RoundService.TimeTrialFinished).
	Bot practice: counted for your first 3 bot races per UTC day (QuestConfig.BotQuestRaces).
	RequestQuestClaim(scope, index): the claim flag and the Coins/XP grant happen in ONE profile
	mutation, so a double tap or a retry can never pay twice.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Protocol = require(Shared:WaitForChild("Protocol"))
local QuestConfig = require(Shared:WaitForChild("QuestConfig"))
local RoundProtocol = require(Shared:WaitForChild("RoundProtocol"))
local Utility = require(Shared:WaitForChild("Utility"))

local QuestService = {}
QuestService.__index = QuestService

local S = RoundProtocol.States

function QuestService.new(deps)
	local self = setmetatable({}, QuestService)
	self.data = deps.data
	self.round = deps.round
	self.remotes = deps.remotes
	self.economy = deps.economy
	self.abilities = deps.abilities
	self.micro = deps.micro
	self.gates = deps.gates
	self.track = deps.track
	self.telemetry = deps.telemetry
	self.botRound = false -- the current race is bot practice (1 human + bots)
	self.clock = os.time -- injectable for specs
	self.maid = Utility.Maid.new()
	self.Claimed = Utility.Signal.new() -- C: (player, scope) for season XP
	return self
end

local function isHuman(entity)
	return typeof(entity) == "Instance" and entity:IsA("Player")
end

function QuestService:SendState(player)
	local profile = self.data:GetProfile(player)
	if not profile or not player.Parent then
		return
	end
	local q = profile.data.quests
	local now = self.clock()
	if QuestConfig.Refresh(q, now) then
		self.data:Update(player, function() end) -- persist the new day's quests
	end
	local day, week = QuestConfig.UtcDay(now), QuestConfig.UtcWeek(now)
	self.remotes.QuestState:FireClient(player, {
		daily = q.daily,
		weekly = q.weekly,
		resetsDailyIn = (day + 1) * 86400 - now,
		resetsWeeklyIn = (week * 7 + 4) * 86400 - now, -- next Monday 00:00 UTC
		botRaces = q.botRaces,
		botLimit = QuestConfig.BotQuestRaces,
		rewards = QuestConfig.Rewards,
	})
end

function QuestService:Event(player, kind, amount, ctx)
	if not isHuman(player) or not player.Parent then
		return
	end
	local done = {}
	local updated = self.data:Update(player, function(data)
		done = QuestConfig.Apply(data.quests, kind, amount or 1, self.clock(), ctx or {})
	end)
	if updated then
		for _, text in ipairs(done) do
			self.remotes.ProgressionNotice:FireClient(player, { kind = "QuestDone", text = "QUEST DONE: " .. text .. " - claim it in QUESTS" })
		end
		self:SendState(player)
	end
end

function QuestService:Claim(player, scope, index)
	local reward, reason = nil, "Your progress isn't loaded yet"
	local ok = self.data:Update(player, function(data)
		reward, reason = QuestConfig.Claim(data.quests, scope, index, self.clock())
		if reward then
			data.coins = data.coins + reward.coins
			data.xp = data.xp + reward.xp
		end
	end)
	if ok and reward then
		self.data:SaveSoon(player)
		self.Claimed:Fire(player, scope)
		self.remotes.ProgressionNotice:FireClient(player, { kind = "QuestClaimed", text = string.format("+%d COINS  +%d XP", reward.coins, reward.xp) })
		if self.telemetry then
			local profile = self.data:GetProfile(player)
			self.telemetry:Economy(player, "Source", "Coins", reward.coins, profile and profile.data.coins or 0, "Quest:" .. scope)
		end
	else
		self.remotes.ProgressionNotice:FireClient(player, { kind = "Denied", text = reason or "Can't claim that" })
	end
	self:SendState(player)
	return reward ~= nil
end

function QuestService:_ctx(extra)
	local ctx = { botPractice = self.botRound }
	for k, v in pairs(extra or {}) do
		ctx[k] = v
	end
	return ctx
end

function QuestService:_onRaceFinished(results)
	local worldId = self.track:GetLayout(Protocol.Zones.Race).Definition.Id
	for _, entry in ipairs(results) do
		if not entry.isBot then
			local player = self.round:GetPlayerByUserId(entry.userId)
			if player then
				local ctx = self:_ctx({ worldId = worldId })
				self:Event(player, "race", 1, ctx)
				self:Event(player, "world", 1, ctx)
				if entry.finished then
					self:Event(player, "finish", 1, ctx)
					if entry.place and entry.place <= 3 then
						self:Event(player, "podium", 1, ctx)
					end
				end
			end
		end
	end
end

function QuestService:Start()
	local remote = self.remotes:WaitForChild("RequestQuestClaim", 10)
	if remote then
		local limiter = Utility.RateLimiter.new(RoundProtocol.Remotes.RequestQuestClaim.MinInterval)
		self.maid:Give(remote.OnServerEvent:Connect(function(player, ...)
			if RoundProtocol.ValidateArgs("RequestQuestClaim", ...) and limiter:Try(player) then
				local scope, index = ...
				self:Claim(player, scope, index)
			end
		end))
	end
	self.maid:Give(self.round.StateChanged:Connect(function(state)
		if state == S.Racing then
			local humans, bots = 0, 0
			for _, entity in ipairs(self.round:GetActiveRacers()) do
				if isHuman(entity) then
					humans = humans + 1
				else
					bots = bots + 1
				end
			end
			self.botRound = humans == 1 and bots > 0
			if self.botRound then
				for _, entity in ipairs(self.round:GetActiveRacers()) do
					if isHuman(entity) then
						self:Event(entity, "botstart", 0, { botPractice = true, countsBotRace = true })
					end
				end
			end
		end
	end))
	self.maid:Give(self.round.RaceFinished:Connect(function(_, results)
		self:_onRaceFinished(results)
	end))
	if self.economy then
		self.maid:Give(self.economy.Granted:Connect(function(player, notice)
			if notice and notice.pb and notice.pb.isNew then
				self:Event(player, "pb", 1, self:_ctx())
			end
		end))
	end
	self.maid:Give(self.abilities.Activated:Connect(function(player)
		if isHuman(player) and self.round:IsActiveRacer(player) then
			self:Event(player, "ability", 1, self:_ctx())
		end
	end))
	if self.micro and self.micro.TrickLanded then
		self.maid:Give(self.micro.TrickLanded:Connect(function(player)
			self:Event(player, "trick", 1, self:_ctx())
		end))
	end
	if self.gates and self.gates.GateCollected then
		self.maid:Give(self.gates.GateCollected:Connect(function(player)
			self:Event(player, "gate", 1, self:_ctx())
		end))
	end
	self.maid:Give(self.round.TimeTrialFinished:Connect(function(player, _, isPb)
		self:Event(player, "trial", 1, { botPractice = false })
		if isPb then
			self:Event(player, "pb", 1, { botPractice = false })
		end
	end))
	self.maid:Give(self.data.ProfileLoaded:Connect(function(player)
		self:SendState(player)
	end))
end

function QuestService:Destroy()
	self.maid:Cleanup()
end

return QuestService
