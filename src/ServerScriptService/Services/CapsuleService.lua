--[[
	CapsuleService (C2) — free capsules (600 EARNED Coins, never Robux) and the Shard Shop.
	Every open is one profile mutation (no yields inside): check the request id was not used,
	check the client saw the current odds (version + both pity counters), check Coins, debit,
	roll on the server (CapsuleOdds, fresh server Random per accepted open; nothing from the
	client picks the outcome), update pity, grant the marble or convert a duplicate to Shards,
	record history (last 20) and the request id. A retried request id returns the stored result
	and never charges twice. Two opens arriving together are processed one after the other.
	Shard Shop: pick ANY not-owned catalog item; its rarity price is debited and the item granted
	in the same mutation. Shards are earned only and can't be bought, traded or cashed out.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CapsuleOdds = require(Shared:WaitForChild("CapsuleOdds"))
local Catalog = require(Shared:WaitForChild("Catalog"))
local RoundProtocol = require(Shared:WaitForChild("RoundProtocol"))
local Utility = require(Shared:WaitForChild("Utility"))

local CapsuleService = {}
CapsuleService.__index = CapsuleService

function CapsuleService.new(deps)
	local self = setmetatable({}, CapsuleService)
	self.data = deps.data
	self.remotes = deps.remotes
	self.cosmetics = deps.cosmetics
	self.telemetry = deps.telemetry
	self.maid = Utility.Maid.new()
	self.counter = 0
	self.pools = {} -- [boxId][tier] = { ids }
	for _, box in ipairs(CapsuleOdds.Boxes) do
		local pools = {}
		for _, tier in ipairs(CapsuleOdds.Tiers) do
			pools[tier] = Catalog.ItemsOfRarity(box.Kind, tier)
		end
		self.pools[box.Id] = pools
	end
	return self
end

-- Pure transaction on profile data. rng = function() -> [0,1). Returns result table or nil, reason.
function CapsuleService.OpenOn(data, requestId, snapshot, pools, rng, now, box)
	box = box or CapsuleOdds.Box("Marble")
	local cost = box.Cost
	local cap = data.capsule
	for _, req in ipairs(cap.requests) do
		if req == requestId then
			for _, h in ipairs(cap.history) do
				if h.req == requestId then
					return { replay = true, id = h.id, tier = h.tier, dup = h.dup, shards = h.shards }
				end
			end
			return nil, "Already opened"
		end
	end
	if type(snapshot) ~= "table" or snapshot.version ~= CapsuleOdds.Version or snapshot.epic ~= cap.epicMisses or snapshot.legendary ~= cap.legendaryMisses then
		return nil, "The odds changed - check them again before opening"
	end
	if data.coins < cost then
		return nil, string.format("You need %d Coins", cost)
	end
	local tier, id, branch = CapsuleOdds.RollWith(rng(), rng(), pools, cap.epicMisses, cap.legendaryMisses)
	if not id then
		return nil, "Capsule unavailable"
	end
	data.coins = data.coins - cost
	cap.epicMisses, cap.legendaryMisses = CapsuleOdds.After(tier, cap.epicMisses, cap.legendaryMisses)
	local owned = false
	for _, ownedId in ipairs(data.cosmetics.owned) do
		if ownedId == id then
			owned = true
		end
	end
	local shards = 0
	if owned then
		shards = CapsuleOdds.DuplicateShards[tier]
		data.shards = data.shards + shards
	else
		table.insert(data.cosmetics.owned, id)
	end
	table.insert(cap.history, 1, { id = id, tier = tier, dup = owned, shards = shards, at = now, req = requestId, box = box.Id, seen = false })
	while #cap.history > CapsuleOdds.HistorySize do
		table.remove(cap.history)
	end
	table.insert(cap.requests, 1, requestId)
	while #cap.requests > CapsuleOdds.HistorySize do
		table.remove(cap.requests)
	end
	return { id = id, tier = tier, dup = owned, shards = shards, branch = branch, box = box.Id, cost = cost }
end

-- Pure: buy `id` with Shards. Returns price or nil, reason.
-- Pure: mark a history entry's reveal as shown. Returns true if something changed.
function CapsuleService.MarkSeen(data, requestId)
	for _, h in ipairs(data.capsule.history) do
		if h.req == requestId and h.seen == false then
			h.seen = true
			return true
		end
	end
	return false
end

function CapsuleService.ShardBuyOn(data, id)
	local item = Catalog.Get(id)
	if not item then
		return nil, "Unknown item"
	end
	if item.Exclusive then
		return nil, "That one isn't in the Shard Shop"
	end
	for _, ownedId in ipairs(data.cosmetics.owned) do
		if ownedId == id then
			return nil, "You already own it"
		end
	end
	local price = CapsuleOdds.ShardPrice[item.Rarity]
	if data.shards < price then
		return nil, string.format("You need %d Shards", price)
	end
	data.shards = data.shards - price
	table.insert(data.cosmetics.owned, id)
	return price
end

function CapsuleService:SendState(player)
	local profile = self.data:GetProfile(player)
	if not profile or not player.Parent then
		return
	end
	local d = profile.data
	self.remotes.CapsuleState:FireClient(player, {
		version = CapsuleOdds.Version,
		cost = CapsuleOdds.Cost,
		coins = d.coins,
		shards = d.shards,
		epicMisses = d.capsule.epicMisses,
		legendaryMisses = d.capsule.legendaryMisses,
		history = d.capsule.history,
		canSave = profile.status ~= "Unavailable" and profile.status ~= "ReadOnly",
	})
end

function CapsuleService:_usable(player)
	local profile = self.data:GetProfile(player)
	if not profile or profile.status == "Loading" then
		return false, "Your progress is still loading"
	end
	if profile.status == "Unavailable" or profile.status == "ReadOnly" then
		return false, "Saving is unavailable right now, so capsules are paused (nothing was spent)"
	end
	return true
end

function CapsuleService:Open(player, requestId, version, epic, legendary, boxId)
	local box = CapsuleOdds.Box(boxId)
	local ok, reason = self:_usable(player)
	if ok and #requestId < 8 then
		ok, reason = false, "Bad request"
	end
	if ok and boxId ~= nil and CapsuleOdds.BoxById[boxId] == nil then
		ok, reason = false, "Unknown capsule" -- never charge for a capsule the player didn't pick
	end
	local result
	if ok then
		self.counter = self.counter + 1
		local rng = Random.new((os.clock() * 1e6 + player.UserId * 7919 + self.counter * 104729) % 2147483647)
		self.data:Update(player, function(data)
			result, reason = CapsuleService.OpenOn(data, requestId, { version = version, epic = epic, legendary = legendary }, self.pools[box.Id], function()
				return rng:NextNumber()
			end, os.time(), box)
		end)
	end
	if result then
		self.data:SaveSoon(player)
		if not result.replay and self.cosmetics then
			self.cosmetics:SendState(player)
		end
		if self.telemetry and not result.replay then
			local profile = self.data:GetProfile(player)
			self.telemetry:Economy(player, "Sink", "Coins", box.Cost, profile and profile.data.coins or 0, "Capsule:" .. box.Id)
		end
	end
	if not result and self.anticheat and reason and string.find(reason, "odds") then
		self.anticheat:Flag(player, "Capsule", reason) -- D3: repeated stale-snapshot opens
	end
	self.remotes.CapsuleResult:FireClient(player, { requestId = requestId, ok = result ~= nil, reason = reason, id = result and result.id, tier = result and result.tier, dup = result and result.dup, shards = result and result.shards, replay = result and result.replay, box = box.Id })
	self:SendState(player)
	return result, reason
end

function CapsuleService:ShardBuy(player, id)
	local ok, reason = self:_usable(player)
	local price
	if ok then
		self.data:Update(player, function(data)
			price, reason = CapsuleService.ShardBuyOn(data, id)
		end)
	end
	if price then
		self.data:SaveSoon(player)
		if self.cosmetics then
			self.cosmetics:SendState(player)
		end
		local item = Catalog.Get(id)
		self.remotes.ProgressionNotice:FireClient(player, { kind = "ShardBuy", text = string.format("%s is yours (-%d Shards)", item.Name, price) })
	else
		self.remotes.ProgressionNotice:FireClient(player, { kind = "Denied", text = reason or "Can't get that" })
	end
	self:SendState(player)
	return price ~= nil
end

function CapsuleService:Start()
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
	connect("RequestOpenCapsule", function(player, requestId, version, epic, legendary, boxId)
		self:Open(player, requestId, version, epic, legendary, boxId)
	end)
	connect("RequestShardBuy", function(player, id)
		self:ShardBuy(player, id)
	end)
	connect("RequestCapsuleState", function(player)
		self:SendState(player)
	end)
	-- 2026-11-26: the client showed the reveal of a saved result (no grant, no charge)
	connect("RequestCapsuleSeen", function(player, requestId)
		local changed = false
		self.data:Update(player, function(data)
			changed = CapsuleService.MarkSeen(data, requestId)
		end)
		if changed then
			self.data:SaveSoon(player)
		end
	end)
	self.maid:Give(self.data.ProfileLoaded:Connect(function(player)
		self:SendState(player)
	end))
end

function CapsuleService:Destroy()
	self.maid:Cleanup()
end

return CapsuleService
