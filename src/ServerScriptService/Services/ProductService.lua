--[[
	ProductService (D1) — the OPTIONAL cosmetic shop's server side. The game never depends on it:
	if products are missing, prices fail or Roblox blocks a purchase, racing is untouched.
	- MarketplaceService.ProcessReceipt is set HERE and nowhere else (one canonical owner).
	- Every receipt: find the player (else NotProcessedYet: Roblox retries when they rejoin),
	  validate the ProductId against the configured offers, then in ONE profile mutation: if the
	  PurchaseId is already in purchases.journal it was granted before; otherwise grant the items /
	  season entitlement and record the PurchaseId. PurchaseGranted is returned only after the
	  profile save succeeds; a failed save returns NotProcessedYet (the retry finds the journal
	  entry and only needs the save). PromptProductPurchaseFinished is never used to grant.
	- Founder's Style Pack = Game Pass: ownership is checked with UserOwnsGamePassAsync on join
	  and after a prompt closes; the pass's items are then granted (idempotent).
	- Season premium lane is season-keyed ("SeasonPremium:S1"): it only unlocks that season's
	  premium rewards, during that season; it never carries into later seasons.
	- PolicyService is read each session, fail-closed. Paid random items do not exist in this
	  build (ENABLE_PAID_CAPSULES = false), so `paidRandomAllowed` is always false.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local PolicyService = game:GetService("PolicyService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Catalog = require(Shared:WaitForChild("Catalog"))
local PlaceholderIds = require(Shared:WaitForChild("PlaceholderIds"))
local RoundProtocol = require(Shared:WaitForChild("RoundProtocol"))
local SeasonConfig = require(Shared:WaitForChild("SeasonConfig"))
local ShopConfig = require(Shared:WaitForChild("ShopConfig"))
local Utility = require(Shared:WaitForChild("Utility"))

local ProductService = {}
ProductService.__index = ProductService

ProductService.JournalSize = 200

function ProductService.new(deps)
	local self = setmetatable({}, ProductService)
	self.data = deps.data
	self.remotes = deps.remotes
	self.cosmetics = deps.cosmetics
	self.telemetry = deps.telemetry
	self.anticheat = deps.anticheat
	self.ids = deps.ids or PlaceholderIds
	self.productMap = ShopConfig.ProductMap(self.ids)
	self.policy = {} -- [player] = { paidRandomAllowed, checked }
	self.clock = os.time
	self.decisions = deps.decisions -- tests inject; live = Enum.ProductPurchaseDecision
	self.findPlayer = deps.findPlayer or function(userId)
		return Players:GetPlayerByUserId(userId)
	end
	self.maid = Utility.Maid.new()
	return self
end

-- Pure: apply an offer for a purchase id. Returns "granted" / "duplicate" / nil, reason.
function ProductService.GrantOn(data, offer, purchaseId)
	local p = data.purchases
	for _, id in ipairs(p.journal) do
		if id == purchaseId then
			return "duplicate"
		end
	end
	local owned = {}
	for _, id in ipairs(data.cosmetics.owned) do
		owned[id] = true
	end
	for _, itemId in ipairs(offer.grants or {}) do
		if Catalog.Get(itemId) and not owned[itemId] then
			owned[itemId] = true
			table.insert(data.cosmetics.owned, itemId)
		end
	end
	if offer.entitlement then
		p.entitlements[offer.entitlement] = true
	end
	table.insert(p.journal, 1, purchaseId)
	while #p.journal > ProductService.JournalSize do
		table.remove(p.journal)
	end
	return "granted"
end

-- Pure: claim a season premium reward (needs THIS season's entitlement, during it)
function ProductService.PremiumClaimOn(data, level, now)
	local season = SeasonConfig.Current(now)
	if not season then
		return nil, "No season running"
	end
	local rewards = ShopConfig.SeasonPremium[season.id]
	local itemId = rewards and rewards[level]
	if not itemId then
		return nil, "No premium reward at that level"
	end
	if not data.purchases.entitlements["SeasonPremium:" .. season.id] then
		return nil, "Premium lane not owned for this season"
	end
	if data.season.id ~= season.id or SeasonConfig.LevelForXp(data.season.xp) < level then
		return nil, "Reach that season level first"
	end
	local key = season.id .. ":" .. level
	for _, k in ipairs(data.purchases.premiumClaimed) do
		if k == key then
			return nil, "Already claimed"
		end
	end
	table.insert(data.purchases.premiumClaimed, key)
	for _, id in ipairs(data.cosmetics.owned) do
		if id == itemId then
			return itemId
		end
	end
	table.insert(data.cosmetics.owned, itemId)
	return itemId
end

function ProductService:ProcessReceipt(receipt)
	local Decision = self.decisions or Enum.ProductPurchaseDecision
	local player = self.findPlayer(receipt.PlayerId)
	if not player then
		return Decision.NotProcessedYet
	end
	local offer = self.productMap[receipt.ProductId]
	if not offer then
		warn(string.format("[Shop] receipt for unknown product %s - not granted", tostring(receipt.ProductId)))
		if self.anticheat then
			self.anticheat:Flag(player, "ReceiptUnknownProduct", tostring(receipt.ProductId))
		end
		return Decision.NotProcessedYet
	end
	local profile = self.data:GetProfile(player)
	if not profile or profile.status == "Loading" or profile.status == "Unavailable" or profile.status == "ReadOnly" then
		return Decision.NotProcessedYet
	end
	local result
	self.data:Update(player, function(data)
		result = ProductService.GrantOn(data, offer, tostring(receipt.PurchaseId))
	end)
	if not result then
		return Decision.NotProcessedYet
	end
	local saved = self.data:SaveNow(player)
	if not saved then
		return Decision.NotProcessedYet -- the journal entry waits for a good save
	end
	if result == "granted" then
		if self.cosmetics then
			self.cosmetics:SendState(player)
		end
		self.remotes.ProgressionNotice:FireClient(player, { kind = "Purchase", text = "Thanks! " .. offer.label .. " is yours." })
		if self.telemetry then
			self.telemetry:Event(player, "shop_purchase", { sku = offer.sku })
		end
	elseif self.anticheat then
		self.anticheat:Flag(player, "ReceiptReplay", offer.sku) -- harmless (Roblox retries), counted only
	end
	self:SendState(player)
	return Decision.PurchaseGranted
end

function ProductService:CheckGamePasses(player)
	for _, offer in ipairs(ShopConfig.Offers) do
		local id = offer.kind == "GamePass" and ShopConfig.IdFor(offer, self.ids)
		if id then
			local ok, owns = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, id)
			end)
			if ok and owns then
				local changed = false
				self.data:Update(player, function(data)
					local owned = {}
					for _, itemId in ipairs(data.cosmetics.owned) do
						owned[itemId] = true
					end
					for _, itemId in ipairs(offer.grants) do
						if not owned[itemId] then
							table.insert(data.cosmetics.owned, itemId)
							changed = true
						end
					end
					data.purchases.entitlements["Pass:" .. offer.sku] = true
				end)
				player:SetAttribute("TC_Founder", offer.sku == "founder_pack" or nil)
				if changed then
					self.data:SaveSoon(player)
					if self.cosmetics then
						self.cosmetics:SendState(player)
					end
				end
			end
		end
	end
end

-- Pure: may this player see paid random items? Fails closed: a PolicyService error, a missing
-- or unknown field, a restricted account or the build flag off all mean NO (earned cases and
-- guaranteed items stay available).
function ProductService.PaidRandomAllowed(ok, info, flag)
	local restricted = not ok or type(info) ~= "table" or info.ArePaidRandomItemsRestricted ~= false
	return flag == true and not restricted
end

function ProductService:CheckPolicy(player)
	local ok, info = pcall(function()
		return PolicyService:GetPolicyInfoForPlayerAsync(player)
	end)
	self.policy[player] = { checked = ok, paidRandomAllowed = ProductService.PaidRandomAllowed(ok, info, PlaceholderIds.ENABLE_PAID_CAPSULES) }
end

function ProductService:SendState(player)
	local profile = self.data:GetProfile(player)
	if not player.Parent then
		return
	end
	local offers = {}
	for _, offer in ipairs(ShopConfig.Offers) do
		local owned = profile ~= nil
		if profile then
			local set = {}
			for _, id in ipairs(profile.data.cosmetics.owned) do
				set[id] = true
			end
			for _, id in ipairs(offer.grants) do
				owned = owned and set[id] == true
			end
			if offer.entitlement then
				owned = profile.data.purchases.entitlements[offer.entitlement] == true
			end
		end
		offers[#offers + 1] = { sku = offer.sku, kind = offer.kind, id = ShopConfig.IdFor(offer, self.ids), owned = owned }
	end
	local season = SeasonConfig.Current(self.clock())
	self.remotes.ShopState:FireClient(player, {
		offers = offers,
		premiumClaimed = profile and profile.data.purchases.premiumClaimed or {},
		seasonId = season and season.id or nil,
		paidRandomAllowed = false,
		saveOk = profile ~= nil and profile.status ~= "Unavailable" and profile.status ~= "ReadOnly",
	})
end

function ProductService:ClaimPremium(player, level)
	local itemId, reason = nil, "Your progress isn't loaded yet"
	self.data:Update(player, function(data)
		itemId, reason = ProductService.PremiumClaimOn(data, level, self.clock())
	end)
	if itemId then
		self.data:SaveSoon(player)
		if self.cosmetics then
			self.cosmetics:SendState(player)
		end
		self.remotes.ProgressionNotice:FireClient(player, { kind = "SeasonClaim", text = "PREMIUM LANE: " .. Catalog.Get(itemId).Name })
	else
		self.remotes.ProgressionNotice:FireClient(player, { kind = "Denied", text = reason })
	end
	self:SendState(player)
end

function ProductService:Start()
	-- the ONE ProcessReceipt owner in the experience
	MarketplaceService.ProcessReceipt = function(receipt)
		local ok, decision = pcall(function()
			return self:ProcessReceipt(receipt)
		end)
		if ok and decision then
			return decision
		end
		warn("[Shop] receipt handler error: " .. tostring(decision))
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	self.maid:Give(MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player)
		task.spawn(function()
			self:CheckGamePasses(player) -- re-verify with Roblox; the prompt result alone grants nothing
			self:SendState(player)
		end)
	end))
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
	connect("RequestShopState", function(player)
		self:SendState(player)
	end)
	connect("RequestPremiumClaim", function(player, level)
		self:ClaimPremium(player, level)
	end)
	self.maid:Give(self.data.ProfileLoaded:Connect(function(player)
		task.spawn(function()
			self:CheckPolicy(player)
			self:CheckGamePasses(player)
			self:SendState(player)
		end)
	end))
	self.maid:Give(Players.PlayerRemoving:Connect(function(player)
		self.policy[player] = nil
	end))
end

function ProductService:Destroy()
	self.maid:Cleanup()
end

return ProductService
