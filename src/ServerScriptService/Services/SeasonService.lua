--[[
	SeasonService (C3) — the free season track (SeasonConfig). Season XP = the XP a race paid
	(EconomyService.Granted) + quest claims (QuestService.Claimed). RequestSeasonClaim(level):
	claim mark + reward in one profile mutation; an item you already own becomes its duplicate
	Shards (nothing is ever removed). Rollover resets season XP/claims only.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CapsuleOdds = require(Shared:WaitForChild("CapsuleOdds"))
local Catalog = require(Shared:WaitForChild("Catalog"))
local RoundProtocol = require(Shared:WaitForChild("RoundProtocol"))
local SeasonConfig = require(Shared:WaitForChild("SeasonConfig"))
local Utility = require(Shared:WaitForChild("Utility"))

local SeasonService = {}
SeasonService.__index = SeasonService

function SeasonService.new(deps)
	local self = setmetatable({}, SeasonService)
	self.data = deps.data
	self.remotes = deps.remotes
	self.economy = deps.economy
	self.quests = deps.quests
	self.cosmetics = deps.cosmetics
	self.clock = os.time
	self.maid = Utility.Maid.new()
	return self
end

-- Pure: apply a claimed reward to profile data. Returns a short text.
function SeasonService.ApplyReward(data, reward)
	if reward.kind == "Coins" then
		data.coins = data.coins + reward.amount
		return string.format("+%d COINS", reward.amount)
	elseif reward.kind == "Shards" then
		data.shards = data.shards + reward.amount
		return string.format("+%d SHARDS", reward.amount)
	end
	local item = Catalog.Get(reward.id)
	for _, id in ipairs(data.cosmetics.owned) do
		if id == reward.id then
			local shards = CapsuleOdds.DuplicateShards[item.Rarity]
			data.shards = data.shards + shards
			return string.format("%s (already owned: +%d SHARDS)", item.Name, shards)
		end
	end
	table.insert(data.cosmetics.owned, reward.id)
	return item.Name .. " " .. string.upper(item.Kind)
end

function SeasonService:SendState(player)
	local profile = self.data:GetProfile(player)
	if not profile or not player.Parent then
		return
	end
	local now = self.clock()
	local record = profile.data.season
	if SeasonConfig.Refresh(record, now) then
		self.data:Update(player, function() end)
	end
	local season = SeasonConfig.Current(now)
	self.remotes.SeasonState:FireClient(player, {
		season = season and { id = season.id, name = season.name, startsAt = season.startsAt, endsAt = season.endsAt } or nil,
		xp = record.xp,
		claimed = record.claimed,
		serverNow = now,
	})
end

function SeasonService:AddXp(player, amount)
	if type(amount) ~= "number" or amount <= 0 then
		return
	end
	local updated = self.data:Update(player, function(data)
		SeasonConfig.AddXp(data.season, amount, self.clock())
	end)
	if updated then
		self:SendState(player)
	end
end

function SeasonService:Claim(player, level)
	local text, reason = nil, "Your progress isn't loaded yet"
	self.data:Update(player, function(data)
		local reward
		reward, reason = SeasonConfig.Claim(data.season, level, self.clock())
		if reward then
			text = SeasonService.ApplyReward(data, reward)
		end
	end)
	if text then
		self.data:SaveSoon(player)
		self.remotes.ProgressionNotice:FireClient(player, { kind = "SeasonClaim", text = string.format("SEASON LEVEL %d: %s", level, text) })
		if self.cosmetics then
			self.cosmetics:SendState(player)
		end
	else
		self.remotes.ProgressionNotice:FireClient(player, { kind = "Denied", text = reason or "Can't claim that" })
	end
	self:SendState(player)
	return text ~= nil
end

function SeasonService:Start()
	local remote = self.remotes:WaitForChild("RequestSeasonClaim", 10)
	if remote then
		local limiter = Utility.RateLimiter.new(RoundProtocol.Remotes.RequestSeasonClaim.MinInterval)
		self.maid:Give(remote.OnServerEvent:Connect(function(player, ...)
			if RoundProtocol.ValidateArgs("RequestSeasonClaim", ...) and limiter:Try(player) then
				self:Claim(player, (...))
			end
		end))
	end
	if self.economy then
		self.maid:Give(self.economy.Granted:Connect(function(player, notice)
			if notice and type(notice.xp) == "number" then
				self:AddXp(player, notice.xp)
			end
		end))
	end
	if self.quests and self.quests.Claimed then
		self.maid:Give(self.quests.Claimed:Connect(function(player, scope)
			self:AddXp(player, SeasonConfig.QuestXp[scope] or 0)
		end))
	end
	self.maid:Give(self.data.ProfileLoaded:Connect(function(player)
		self:SendState(player)
	end))
end

function SeasonService:Destroy()
	self.maid:Cleanup()
end

return SeasonService
