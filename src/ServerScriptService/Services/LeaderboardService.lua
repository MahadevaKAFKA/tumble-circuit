--[[
	LeaderboardService (B3) — human-only boards on Roblox OrderedDataStores, budget-aware.
	- Best race time per world | layout | variation (seed class): written only on a server-
	  verified PB (EconomyService.Granted, notice.pb.isNew), stored as whole milliseconds,
	  ascending; UpdateAsync keeps the faster value. Bots never write.
	- Weekly wins (UTC week): +1 for a human win in a race with at least MinHumansForWin humans
	  (a win over bots alone doesn't count).
	- Reads are cached per board for CacheSeconds; names via UserService display names.
	- "Friends here": your friends in this server and their best on that board (their profiles).
	- Writes check the request budget first and are dropped (logged) when it is low: boards are
	  best-effort, profiles stay the source of truth. Studio mock mode: boards say they need the
	  live game.
]]

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserService = game:GetService("UserService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlayerDataSchema = require(Shared:WaitForChild("PlayerDataSchema"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local QuestConfig = require(Shared:WaitForChild("QuestConfig"))
local RoundProtocol = require(Shared:WaitForChild("RoundProtocol"))
local TrackDefinitions = require(Shared:WaitForChild("TrackDefinitions"))
local Utility = require(Shared:WaitForChild("Utility"))

local LeaderboardService = {}
LeaderboardService.__index = LeaderboardService

LeaderboardService.CacheSeconds = 60
LeaderboardService.TopCount = 10
LeaderboardService.MinHumansForWin = 2
LeaderboardService.MinBudget = 5

function LeaderboardService.new(deps)
	local self = setmetatable({}, LeaderboardService)
	self.data = deps.data
	self.round = deps.round
	self.economy = deps.economy
	self.remotes = deps.remotes
	self.track = deps.track
	self.hazards = deps.hazards
	self.cache = {} -- [storeName] = { at, rows }
	self.names = {} -- [userId] = display name
	self.maid = Utility.Maid.new()
	return self
end

-- Pure: store names (<= 50 chars, stable)
function LeaderboardService.BestStoreName(worldId, layoutVersion, seedClass)
	return string.format("TCBest_%s_L%d_S%d", worldId, layoutVersion or 1, seedClass or 0)
end

function LeaderboardService.WinsStoreName(week)
	return string.format("TCWins_W%d", week)
end

-- Pure: seconds -> stored ms (whole, positive) and back
function LeaderboardService.ToMs(seconds)
	return math.max(1, math.floor(seconds * 1000 + 0.5))
end

function LeaderboardService:_live()
	return self.data.GetMode and self.data:GetMode() == "Live"
end

function LeaderboardService:_budgetOk()
	local ok, budget = pcall(function()
		return DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.SetIncrementSortedAsync)
	end)
	return ok and budget >= LeaderboardService.MinBudget
end

function LeaderboardService:_store(name)
	local ok, store = pcall(function()
		return DataStoreService:GetOrderedDataStore(name)
	end)
	return ok and store or nil
end

function LeaderboardService:WriteBest(player, worldId, layoutVersion, seedClass, seconds)
	if not self:_live() or not self:_budgetOk() then
		return false
	end
	local store = self:_store(LeaderboardService.BestStoreName(worldId, layoutVersion, seedClass))
	if not store then
		return false
	end
	local ms = LeaderboardService.ToMs(seconds)
	task.spawn(function()
		local ok, err = pcall(function()
			store:UpdateAsync(tostring(player.UserId), function(old)
				if type(old) == "number" and old <= ms then
					return nil -- keep the faster stored time
				end
				return ms
			end)
		end)
		if not ok then
			warn("[Leaderboard] best write failed: " .. tostring(err))
		end
	end)
	return true
end

function LeaderboardService:AddWin(player)
	if not self:_live() or not self:_budgetOk() then
		return false
	end
	local store = self:_store(LeaderboardService.WinsStoreName(QuestConfig.UtcWeek(os.time())))
	if not store then
		return false
	end
	task.spawn(function()
		local ok, err = pcall(function()
			store:IncrementAsync(tostring(player.UserId), 1)
		end)
		if not ok then
			warn("[Leaderboard] win write failed: " .. tostring(err))
		end
	end)
	return true
end

function LeaderboardService:_namesFor(ids)
	local missing = {}
	for _, id in ipairs(ids) do
		if not self.names[id] then
			missing[#missing + 1] = id
		end
	end
	if #missing > 0 then
		local ok, infos = pcall(function()
			return UserService:GetUserInfosByUserIdsAsync(missing)
		end)
		if ok and type(infos) == "table" then
			for _, info in ipairs(infos) do
				self.names[info.Id] = info.DisplayName
			end
		end
	end
end

function LeaderboardService:_top(name, ascending)
	local cached = self.cache[name]
	if cached and os.clock() - cached.at < LeaderboardService.CacheSeconds then
		return cached.rows, cached.error
	end
	local rows, errorText = {}, nil
	local store = self:_store(name)
	local ok, err = pcall(function()
		local page = store:GetSortedAsync(ascending, LeaderboardService.TopCount):GetCurrentPage()
		for i, item in ipairs(page) do
			rows[i] = { rank = i, userId = tonumber(item.key), value = item.value }
		end
	end)
	if not ok then
		errorText = "Leaderboard unavailable right now"
		warn("[Leaderboard] read failed: " .. tostring(err))
	end
	local ids = {}
	for _, row in ipairs(rows) do
		ids[#ids + 1] = row.userId
	end
	self:_namesFor(ids)
	for _, row in ipairs(rows) do
		row.name = self.names[row.userId] or "Racer"
	end
	self.cache[name] = { at = os.clock(), rows = rows, error = errorText }
	return rows, errorText
end

function LeaderboardService:Send(player, kind, worldId, seedClass)
	local def = TrackDefinitions.WorldsById[worldId] or TrackDefinitions.Worlds[1]
	local payload = { kind = kind, worldId = def.Id, seedClass = seedClass, rows = {}, friends = {} }
	local key = PlayerDataSchema.BestTimeKey(def.Id, def.LayoutVersion, seedClass, "Race")
	local profile = self.data:GetProfile(player)
	payload.mine = profile and profile.data.bestTimes[key] or nil
	-- friends in this server (their own verified profile PBs)
	for _, other in ipairs(Players:GetPlayers()) do
		if other ~= player then
			local okFriend, isFriend = pcall(function()
				return player:IsFriendsWith(other.UserId)
			end)
			local otherProfile = okFriend and isFriend and self.data:GetProfile(other)
			if otherProfile then
				payload.friends[#payload.friends + 1] = { name = other.DisplayName, seconds = otherProfile.data.bestTimes[key] }
			end
		end
	end
	if not self:_live() then
		payload.error = "Global leaderboards need the live game (Studio uses test data)"
	elseif kind == "Wins" then
		payload.rows, payload.error = self:_top(LeaderboardService.WinsStoreName(QuestConfig.UtcWeek(os.time())), false)
	else
		payload.rows, payload.error = self:_top(LeaderboardService.BestStoreName(def.Id, def.LayoutVersion, seedClass), true)
		for _, row in ipairs(payload.rows) do
			row.seconds = type(row.value) == "number" and row.value / 1000 or nil
		end
	end
	self.remotes.LeaderboardData:FireClient(player, payload)
end

function LeaderboardService:Start()
	local remote = self.remotes:WaitForChild("RequestLeaderboard", 10)
	if remote then
		local limiter = Utility.RateLimiter.new(RoundProtocol.Remotes.RequestLeaderboard.MinInterval)
		self.maid:Give(remote.OnServerEvent:Connect(function(player, ...)
			if RoundProtocol.ValidateArgs("RequestLeaderboard", ...) and limiter:Try(player) then
				local kind, worldId, seedClass = ...
				task.spawn(function()
					self:Send(player, kind == "Wins" and "Wins" or "Best", worldId, seedClass)
				end)
			end
		end))
	end
	if self.economy then
		self.maid:Give(self.economy.Granted:Connect(function(player, notice)
			if notice and notice.pb and notice.pb.isNew and type(notice.pb.seconds) == "number" then
				local def = self.track:GetLayout(Protocol.Zones.Race).Definition
				self:WriteBest(player, def.Id, def.LayoutVersion, self.hazards and self.hazards:GetSeed() or 0, notice.pb.seconds)
			end
		end))
	end
	self.maid:Give(self.round.RaceFinished:Connect(function(_, results)
		local humans, winner = 0, nil
		for _, entry in ipairs(results) do
			if not entry.isBot then
				humans = humans + 1
				if entry.place == 1 and entry.finished then
					winner = entry
				end
			end
		end
		if winner and humans >= LeaderboardService.MinHumansForWin then
			local player = self.round:GetPlayerByUserId(winner.userId)
			if player then
				self:AddWin(player)
			end
		end
	end))
end

function LeaderboardService:Destroy()
	self.maid:Cleanup()
end

return LeaderboardService
