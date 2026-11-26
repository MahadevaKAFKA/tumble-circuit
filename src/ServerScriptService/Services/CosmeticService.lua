--[[
	CosmeticService (B3) — the cosmetic inventory (named so it can't be confused with Roblox's
	CollectionService). Server-owned:
	- owned / equipped / favorites live in profile.cosmetics (schema v3); starters always owned
	- RequestEquipCosmetic(kind, id, slot): only owned items of that kind; emotes have 3 slots
	  (choosing an emote already in another slot swaps them); the marble's look is rebuilt in
	  place (visual only — MarbleLook never touches size, mass, grip or collision)
	- RequestFavorite(id, on)
	- level rewards every 5 levels (Catalog.LevelRewards): granted once, recorded in
	  levelRewardsClaimed, inside one profile mutation; announced with ProgressionNotice
	- Grant(player, id, source) is the only way new items enter an inventory (Phase C capsules use
	  it too)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Catalog = require(Shared:WaitForChild("Catalog"))
local RoundProtocol = require(Shared:WaitForChild("RoundProtocol"))
local Utility = require(Shared:WaitForChild("Utility"))

local CosmeticService = {}
CosmeticService.__index = CosmeticService

local KIND_KEY = { Marble = "marble", Trail = "trail", Burst = "burst", Emote = "emotes", Launch = "launch" }

function CosmeticService.new(deps)
	local self = setmetatable({}, CosmeticService)
	self.data = deps.data
	self.marbles = deps.marbles
	self.remotes = deps.remotes
	self.telemetry = deps.telemetry
	self.maid = Utility.Maid.new()
	self.checking = {}
	return self
end

local function ownedSet(c)
	local set = {}
	for _, id in ipairs(c.owned) do
		set[id] = true
	end
	return set
end

-- Pure: equip `id` of `kind` (slot for emotes). Returns ok, reason. Mutates c.equipped.
function CosmeticService.ApplyEquip(c, kind, id, slot)
	local key = KIND_KEY[kind]
	if not key or not Catalog.IsKind(id, kind) then
		return false, "Not that kind of item"
	end
	if not ownedSet(c)[id] then
		return false, "You don't own that yet"
	end
	if kind == "Emote" then
		if type(slot) ~= "number" or slot < 1 or slot > 3 or slot ~= math.floor(slot) then
			return false, "Pick an emote slot"
		end
		local emotes = c.equipped.emotes
		for i = 1, 3 do
			if i ~= slot and emotes[i] == id then
				emotes[i] = emotes[slot] -- swap
			end
		end
		emotes[slot] = id
	else
		c.equipped[key] = id
	end
	return true, nil
end

-- Pure: level rewards due at `level` that were not granted yet → list of { level, id }
function CosmeticService.DueLevelRewards(claimedList, level)
	local claimed = {}
	for _, l in ipairs(claimedList) do
		claimed[l] = true
	end
	local due = {}
	for l, id in pairs(Catalog.LevelRewards) do
		if l <= level and not claimed[l] then
			due[#due + 1] = { level = l, id = id }
		end
	end
	table.sort(due, function(a, b)
		return a.level < b.level
	end)
	return due
end

function CosmeticService:_cosmetics(player)
	local profile = self.data:GetProfile(player)
	return profile and profile.data.cosmetics, profile
end

function CosmeticService:LookFor(player)
	local c = self:_cosmetics(player)
	if not c then
		return nil
	end
	return { marble = c.equipped.marble, trail = c.equipped.trail, burst = c.equipped.burst, launch = c.equipped.launch }
end

function CosmeticService:EmoteFor(player, slot)
	local c = self:_cosmetics(player)
	local id = c and c.equipped.emotes[slot] or Catalog.Defaults.emotes[slot]
	return id
end

function CosmeticService:SendState(player)
	local c, profile = self:_cosmetics(player)
	if not c or not player.Parent then
		return
	end
	self.remotes.CosmeticState:FireClient(player, {
		owned = c.owned,
		equipped = c.equipped,
		favorites = c.favorites,
		claimedLevels = profile.data.levelRewardsClaimed,
		level = profile.data.level,
	})
end

function CosmeticService:_notice(player, kind, text)
	if player.Parent then
		self.remotes.ProgressionNotice:FireClient(player, { kind = kind, text = text })
	end
end

-- Grant an item (idempotent). Returns true if it was new. Call only from server logic.
function CosmeticService:Grant(player, id, source)
	if not Catalog.Get(id) then
		return false
	end
	local isNew = false
	self.data:Update(player, function(data)
		local set = ownedSet(data.cosmetics)
		if not set[id] then
			table.insert(data.cosmetics.owned, id)
			isNew = true
		end
	end)
	if isNew then
		self.data:SaveSoon(player)
		self:SendState(player)
		if self.telemetry then
			self.telemetry:Event(player, "cosmetic_granted", { id = id, source = source })
		end
	end
	return isNew
end

function CosmeticService:CheckLevelRewards(player)
	if self.checking[player] then
		return
	end
	local profile = self.data:GetProfile(player)
	if not profile or profile.status == "Loading" then
		return
	end
	local due = CosmeticService.DueLevelRewards(profile.data.levelRewardsClaimed, profile.data.level or 1)
	if #due == 0 then
		return
	end
	self.checking[player] = true
	local granted = {}
	self.data:Update(player, function(data)
		local set = ownedSet(data.cosmetics)
		for _, reward in ipairs(CosmeticService.DueLevelRewards(data.levelRewardsClaimed, data.level or 1)) do
			table.insert(data.levelRewardsClaimed, reward.level)
			if not set[reward.id] then
				set[reward.id] = true
				table.insert(data.cosmetics.owned, reward.id)
			end
			granted[#granted + 1] = reward
		end
	end)
	self.checking[player] = nil
	if #granted > 0 then
		self.data:SaveSoon(player)
		self:SendState(player)
		for _, reward in ipairs(granted) do
			local item = Catalog.Get(reward.id)
			self:_notice(player, "LevelReward", string.format("LEVEL %d REWARD: %s %s", reward.level, item.Name, string.upper(item.Kind)))
		end
	end
end

function CosmeticService:Equip(player, kind, id, slot)
	local ok, reason = false, "Your progress isn't loaded yet"
	self.data:Update(player, function(data)
		ok, reason = CosmeticService.ApplyEquip(data.cosmetics, kind, id, slot)
	end)
	if ok then
		self.data:SaveSoon(player)
		if kind == "Marble" or kind == "Trail" or kind == "Burst" or kind == "Launch" then
			self.marbles:RefreshLook(player)
		end
	else
		self:_notice(player, "Denied", reason)
	end
	self:SendState(player)
	return ok
end

function CosmeticService:Favorite(player, id, on)
	if not Catalog.Get(id) then
		return false
	end
	self.data:Update(player, function(data)
		local favs = data.cosmetics.favorites
		for i = #favs, 1, -1 do
			if favs[i] == id then
				table.remove(favs, i)
			end
		end
		if on and #favs < 60 then
			table.insert(favs, id)
		end
	end)
	self:SendState(player)
	return true
end

function CosmeticService:Start()
	local function connect(name, handler)
		local remote = self.remotes:WaitForChild(name, 10)
		if not remote then
			return
		end
		local limiter = Utility.RateLimiter.new(RoundProtocol.Remotes[name].MinInterval)
		self.maid:Give(remote.OnServerEvent:Connect(function(player, ...)
			if RoundProtocol.ValidateArgs(name, ...) and limiter:Try(player) then
				handler(player, ...)
			end
		end))
	end
	connect("RequestEquipCosmetic", function(player, kind, id, slot)
		self:Equip(player, kind, id, slot)
	end)
	connect("RequestFavorite", function(player, id, on)
		self:Favorite(player, id, on)
	end)
	self.maid:Give(self.data.ProfileLoaded:Connect(function(player)
		self:CheckLevelRewards(player)
		self:SendState(player)
		self.marbles:RefreshLook(player)
	end))
	self.maid:Give(self.data.Updated:Connect(function(player)
		self:CheckLevelRewards(player)
	end))
end

function CosmeticService:Destroy()
	self.maid:Cleanup()
end

return CosmeticService
