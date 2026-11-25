--[[
	PlayerDataService (A5) — one profile per player (PlayerDataSchema v1) through ProfileStore.
	* Live server: DataStoreService (UpdateAsync only, request budget respected, bounded retries).
	* Studio: in-memory MOCK unless GameConfig.Persistence.StudioMode = "Live" (explicit opt-in for
	  a throwaway test universe). The mock survives leave/rejoin inside one Studio server session.
	* Session lock + takeover refusal (see ProfileStore). Autosave every AutosaveSeconds when dirty,
	  lock refresh every LockRefreshSeconds, save + release on leave, BindToClose flush.
	* Rejoining the SAME server while the leave-save is still running waits for it first.
	* Honest status to the client (ProfileState.status): Loading | Ready | Mock | Unsaved |
	  Unavailable | ReadOnly | TakenOver, plus savedAt so the UI only says "saved" after a save.
	* Settings: RequestSettings(key, value) -> sanitized, coalesced into the next autosave.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local PlayerDataSchema = require(Shared:WaitForChild("PlayerDataSchema"))
local ProgressionConfig = require(Shared:WaitForChild("ProgressionConfig"))
local RoundProtocol = require(Shared:WaitForChild("RoundProtocol"))
local Utility = require(Shared:WaitForChild("Utility"))
local ProfileStore = require(script.Parent:WaitForChild("ProfileStore"))

local PlayerDataService = {}
PlayerDataService.__index = PlayerDataService

local sharedMockBackend = nil -- one per server session so Studio leave/rejoin keeps the mock

local STATUS_TEXT = {
	Loading = "Loading your progress...",
	Ready = "Progress saved to your account",
	Mock = "Studio test profile - not saved to Roblox",
	Unsaved = "Couldn't save yet - retrying. Your progress is kept while you play.",
	Unavailable = "Saved progress couldn't load - this session won't be saved.",
	ReadOnly = "Your profile is from a newer game version - this session won't be saved.",
	TakenOver = "You joined another server - this one stopped saving.",
}
PlayerDataService.StatusText = STATUS_TEXT

-- DataStore adapter: same UpdateAsync contract as ProfileStore.MemoryBackend.
local DataStoreBackend = {}
DataStoreBackend.__index = DataStoreBackend

function DataStoreBackend.new(name)
	local store = DataStoreService:GetDataStore(name)
	return setmetatable({ store = store }, DataStoreBackend)
end

function DataStoreBackend:UpdateAsync(key, transform)
	local waited = 0
	while waited < 10 do
		local ok, budget = pcall(function()
			return DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync)
		end)
		if not ok or budget >= 1 then
			break
		end
		task.wait(0.5)
		waited = waited + 0.5
	end
	return (self.store:UpdateAsync(key, transform))
end

function PlayerDataService.new(deps)
	local self = setmetatable({}, PlayerDataService)
	self.remotes = deps.remotes
	self.profiles = {} -- [player] = profile
	self.releasing = {} -- [userId] = true while a leave-save runs
	self.maid = Utility.Maid.new()
	self.ProfileLoaded = Utility.Signal.new() -- (player, profile)
	self.limiter = Utility.RateLimiter.new(RoundProtocol.Remotes.RequestSettings.MinInterval)
	return self
end

function PlayerDataService:_makeStore()
	local cfg = GameConfig.Persistence
	local studio = RunService:IsStudio()
	local jobId = game.JobId ~= "" and game.JobId or ("studio-" .. HttpService:GenerateGUID(false))
	local useMock = studio and cfg.StudioMode ~= "Live"
	local backend
	if not useMock then
		local ok, result = pcall(DataStoreBackend.new, cfg.StoreName)
		if ok then
			backend = result
		else
			warn("[Profiles] DataStoreService unavailable (" .. tostring(result) .. "). Progress will not be saved this session.")
			self.unavailable = true
		end
	end
	if useMock then
		sharedMockBackend = sharedMockBackend or ProfileStore.MemoryBackend()
		backend = sharedMockBackend
		print("[Profiles] Studio MOCK mode: profiles live in memory only (GameConfig.Persistence.StudioMode)")
	end
	self.mode = useMock and "Mock" or (self.unavailable and "Unavailable" or "Live")
	self.store = backend and ProfileStore.new({
		backend = backend,
		jobId = jobId,
		mock = useMock,
		clock = os.time,
		wait = task.wait,
		log = warn,
	})
end

function PlayerDataService:Start()
	self:_makeStore()
	local remote = self.remotes:WaitForChild("RequestSettings")
	self.maid:Give(remote.OnServerEvent:Connect(function(player, ...)
		if RoundProtocol.ValidateArgs("RequestSettings", ...) and self.limiter:Try(player) then
			self:SetSetting(player, ...)
		end
	end))
	-- the client asks for a snapshot once its listeners exist: resend the profile with it
	local snapshotLimiter = Utility.RateLimiter.new(RoundProtocol.Remotes.RequestSnapshot.MinInterval)
	self.maid:Give(self.remotes:WaitForChild("RequestSnapshot").OnServerEvent:Connect(function(player)
		if snapshotLimiter:Try(player) then
			self:SendState(player)
		end
	end))
	self.maid:Give(Players.PlayerAdded:Connect(function(player)
		self:_onJoin(player)
	end))
	self.maid:Give(Players.PlayerRemoving:Connect(function(player)
		self:_onLeave(player)
	end))
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(function()
			self:_onJoin(player)
		end)
	end
	task.spawn(function()
		while true do
			task.wait(GameConfig.Persistence.AutosaveSeconds)
			self:_autosave()
		end
	end)
	game:BindToClose(function()
		self:_flushAll()
	end)
end

local function key(userId)
	return "u_" .. tostring(userId)
end

function PlayerDataService:_onJoin(player)
	if self.profiles[player] then
		return
	end
	local placeholder = { key = key(player.UserId), data = PlayerDataSchema.Defaults(), status = "Loading", notes = {} }
	self.profiles[player] = placeholder
	self:SendState(player)
	local waited = 0
	while self.releasing[player.UserId] and waited < 30 do -- rejoined this server mid leave-save
		task.wait(0.25)
		waited = waited + 0.25
	end
	local profile
	if self.store then
		profile = self.store:Load(key(player.UserId))
	else
		profile = { key = key(player.UserId), data = PlayerDataSchema.Defaults(), status = "Unavailable", notes = { "DataStoreService unavailable" } }
	end
	if not player.Parent then
		-- left while loading: release the lock we just took, change nothing else
		if self.store and ProfileStore.CanSave(profile) then
			self.store:Save(profile, true)
		end
		return
	end
	self.profiles[player] = profile
	for _, note in ipairs(profile.notes) do
		print("[Profiles] " .. player.Name .. ": " .. note)
	end
	self.ProfileLoaded:Fire(player, profile)
	self:SendState(player)
end

function PlayerDataService:_onLeave(player)
	local profile = self.profiles[player]
	self.profiles[player] = nil
	if not profile or not self.store or not ProfileStore.CanSave(profile) then
		return
	end
	local userId = player.UserId
	self.releasing[userId] = true
	task.spawn(function()
		self.store:Save(profile, true)
		self.releasing[userId] = nil
	end)
end

function PlayerDataService:_autosave()
	if not self.store then
		return
	end
	local now = os.time()
	for player, profile in pairs(self.profiles) do
		local stale = now - (profile.lastSavedAt or profile.loadedAt or now) >= GameConfig.Persistence.LockRefreshSeconds
		if ProfileStore.CanSave(profile) and (profile.dirty or stale) then
			task.spawn(function()
				self.store:Save(profile, false)
				if player.Parent then
					self:SendState(player)
				end
			end)
		end
	end
end

function PlayerDataService:_flushAll()
	if not self.store then
		return
	end
	local pending = 0
	for _, profile in pairs(self.profiles) do
		if ProfileStore.CanSave(profile) then
			pending = pending + 1
			task.spawn(function()
				self.store:Save(profile, true)
				pending = pending - 1
			end)
		end
	end
	local started = os.clock()
	while (pending > 0 or next(self.releasing)) and os.clock() - started < GameConfig.Persistence.ShutdownBudgetSeconds do
		task.wait(0.1)
	end
end

---------------------------------------------------------------------------------------------
-- API
---------------------------------------------------------------------------------------------
function PlayerDataService:GetProfile(player)
	return self.profiles[player]
end

function PlayerDataService:IsReady(player)
	local profile = self.profiles[player]
	return profile ~= nil and profile.status ~= "Loading"
end

-- fn(data) mutates the profile data; marks dirty and pushes ProfileState.
function PlayerDataService:Update(player, fn)
	local profile = self.profiles[player]
	if not profile or profile.status == "Loading" then
		return false
	end
	fn(profile.data)
	profile.data.level = (ProgressionConfig.LevelForXp(profile.data.xp))
	ProfileStore.MarkDirty(profile)
	self:SendState(player)
	return true
end

-- Important change (a race reward): save now instead of waiting for the autosave.
function PlayerDataService:SaveSoon(player)
	local profile = self.profiles[player]
	if not profile or not self.store or not ProfileStore.CanSave(profile) then
		return
	end
	task.spawn(function()
		self.store:Save(profile, false)
		if player.Parent then
			self:SendState(player)
		end
	end)
end

function PlayerDataService:SetSetting(player, settingKey, value)
	if not PlayerDataSchema.Settings[settingKey] then
		return false
	end
	local clean = PlayerDataSchema.SanitizeSetting(settingKey, value)
	return self:Update(player, function(data)
		data.settings[settingKey] = clean
	end)
end

function PlayerDataService:SetLoadout(player, loadout)
	if not PlayerDataSchema.ValidLoadout(loadout) then
		return false
	end
	return self:Update(player, function(data)
		data.equippedAbilityIds = { loadout[1], loadout[2] }
	end)
end

function PlayerDataService:SendState(player)
	local profile = self.profiles[player]
	local remote = self.remotes:FindFirstChild("ProfileState")
	if not profile or not remote then
		return
	end
	local d = profile.data
	local level, into, nextCost = ProgressionConfig.LevelForXp(d.xp)
	remote:FireClient(player, {
		status = profile.status,
		statusText = STATUS_TEXT[profile.status] or profile.status,
		savedAt = profile.lastSavedAt,
		dirty = profile.dirty == true,
		coins = d.coins,
		xp = d.xp,
		level = level,
		xpIntoLevel = into,
		xpForNext = nextCost,
		maxLevel = ProgressionConfig.Levels.Max,
		raceCount = d.raceCount,
		winCount = d.winCount,
		podiumCount = d.podiumCount,
		bestTimes = d.bestTimes,
		settings = d.settings,
		loadout = d.equippedAbilityIds,
		serverTime = os.time(),
	})
end

-- Studio dev panel only (DevService checks the mode): wipe the MOCK profile.
function PlayerDataService:ResetMockProfile(player)
	local profile = self.profiles[player]
	if not profile or profile.status ~= "Mock" then
		return false
	end
	profile.data = PlayerDataSchema.Defaults()
	ProfileStore.MarkDirty(profile)
	self:SendState(player)
	return true
end

function PlayerDataService:GetMode()
	return self.mode
end

function PlayerDataService:Destroy()
	self.maid:Cleanup()
end

return PlayerDataService
