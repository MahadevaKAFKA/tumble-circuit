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
	2026-11-27 shop brief:
	- RequestShopPurchase(sku): the client only asks. The server checks the listing, that the
	  player doesn't already own everything (no second prompt for a durable offer), that no
	  purchase of it is pending, then opens Roblox's own prompt - only while
	  ShopConfig.Flags.PaidOffers is on and the id is configured (owner approval). With paid
	  offers off, the experience OWNER (or Studio) gets a no-Robux PREVIEW grant of the same
	  items, flagged "Preview:<item>" so RequestShopPreviewReset can take back only what the
	  preview added (items owned from any other source stay).
	- Every confirmed grant (receipt, verified pass, preview) sends a receipt to the client
	  (ShopState.receipt) so it can offer EQUIP. Prompt closed without buying -> "cancelled".
	- Game Pass ownership can lag right after a purchase: re-checked 3 times (2 s apart), the
	  client shows "Verifying" meanwhile; rejoining re-checks too.
	- Aggregate analytics: shop_view, checkout_start, purchase_confirmed, purchase_cancelled,
	  purchase_failed (reason), preview_grant.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local PolicyService = game:GetService("PolicyService")
local RunService = game:GetService("RunService")
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
ProductService.PendingSeconds = 120 -- a prompt that never reported back stops blocking after this

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
	self.pending = {} -- [player] = { [sku] = os.clock() } purchases waiting for Roblox / verification
	self.flags = deps.flags or ShopConfig.Flags
	self.isStudio = deps.isStudio
	if self.isStudio == nil then
		local ok, studio = pcall(function()
			return RunService:IsStudio()
		end)
		self.isStudio = ok and studio == true
	end
	self.creator = deps.creator
	if not self.creator then
		local ok, isUser, id = pcall(function()
			return game.CreatorType == Enum.CreatorType.User, game.CreatorId
		end)
		self.creator = { isUser = ok and isUser == true, id = ok and id or 0 }
	end
	self.marbles = deps.marbles
	return self
end

-- Pure: may this player run the no-Robux preview purchase? Only while paid offers are OFF, and
-- only in Studio or for the account that owns the experience (a user-owned experience).
function ProductService.OwnerPreviewAllowed(flags, isStudio, userId, creator)
	if not flags.OwnerPreview or flags.PaidOffers then
		return false
	end
	if isStudio then
		return true
	end
	return creator ~= nil and creator.isUser == true and creator.id == userId and type(userId) == "number" and userId > 0
end

-- Pure: a preview grant: adds the missing items, flags each one it added. Returns added ids.
function ProductService.PreviewGrantOn(data, offer, stamp)
	local owned = {}
	for _, id in ipairs(data.cosmetics.owned) do
		owned[id] = true
	end
	local added = {}
	for _, itemId in ipairs(offer.grants or {}) do
		if Catalog.Get(itemId) and not owned[itemId] then
			owned[itemId] = true
			table.insert(data.cosmetics.owned, itemId)
			data.purchases.entitlements["Preview:" .. itemId] = true
			added[#added + 1] = itemId
		end
	end
	table.insert(data.purchases.journal, 1, "preview:" .. offer.sku .. ":" .. tostring(stamp))
	while #data.purchases.journal > ProductService.JournalSize do
		table.remove(data.purchases.journal)
	end
	return added
end

-- Pure: take back exactly the items a preview added (equipped ones fall back to the default)
function ProductService.PreviewResetOn(data)
	local removed = {}
	for key in pairs(data.purchases.entitlements) do
		local itemId = string.match(key, "^Preview:(.+)$")
		if itemId then
			removed[itemId] = true
		end
	end
	for itemId in pairs(removed) do
		data.purchases.entitlements["Preview:" .. itemId] = nil
	end
	local keep = {}
	for _, id in ipairs(data.cosmetics.owned) do
		if not removed[id] then
			keep[#keep + 1] = id
		end
	end
	data.cosmetics.owned = keep
	local eq = data.cosmetics.equipped
	for _, key in pairs(Catalog.EquipKey) do
		if key ~= "emotes" and eq[key] and removed[eq[key]] then
			eq[key] = Catalog.Defaults[key]
		end
	end
	local list = {}
	for id in pairs(removed) do
		list[#list + 1] = id
	end
	table.sort(list)
	return list
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
			self.telemetry:Event(player, "purchase_confirmed", { sku = offer.sku })
		end
		self:_clearPending(player, offer.sku)
		self:SendState(player, { sku = offer.sku, items = offer.grants })
		return Decision.PurchaseGranted
	elseif self.anticheat then
		self.anticheat:Flag(player, "ReceiptReplay", offer.sku) -- harmless (Roblox retries), counted only
	end
	self:SendState(player)
	return Decision.PurchaseGranted
end

function ProductService:CheckGamePasses(player)
	local verified = {}
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
				if offer.sku == "founder_pack" then
					player:SetAttribute("TC_Founder", true)
				end
				verified[offer.sku] = true
				if changed then
					self.data:SaveSoon(player)
					if self.cosmetics then
						self.cosmetics:SendState(player)
					end
				end
			end
		end
	end
	return verified
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

function ProductService:SendState(player, receipt, cancelled)
	local profile = self.data:GetProfile(player)
	if not player.Parent then
		return
	end
	local offers = {}
	local set = {}
	for _, id in ipairs(profile and profile.data.cosmetics.owned or {}) do
		set[id] = true
	end
	local previewItems = {}
	for key in pairs(profile and profile.data.purchases.entitlements or {}) do
		local itemId = string.match(key, "^Preview:(.+)$")
		if itemId then
			previewItems[#previewItems + 1] = itemId
		end
	end
	local now = self.clock()
	local pending = self.pending[player] or {}
	for _, offer in ipairs(ShopConfig.Offers) do
		local own = ShopConfig.Ownership(offer, set, profile and profile.data.purchases.entitlements)
		offers[#offers + 1] = {
			sku = offer.sku,
			kind = offer.kind,
			id = ShopConfig.IdFor(offer, self.ids),
			owned = profile ~= nil and own.all,
			ownedCount = own.owned,
			total = own.total,
			listed = ShopConfig.Listed(offer, now),
			pending = pending[offer.sku] ~= nil,
		}
	end
	local season = SeasonConfig.Current(now)
	self.remotes.ShopState:FireClient(player, {
		offers = offers,
		premiumClaimed = profile and profile.data.purchases.premiumClaimed or {},
		seasonId = season and season.id or nil,
		paidRandomAllowed = false,
		saveOk = profile ~= nil and profile.status ~= "Unavailable" and profile.status ~= "ReadOnly",
		storefront = self.flags.Storefront == true,
		paid = self.flags.PaidOffers == true,
		preview = ProductService.OwnerPreviewAllowed(self.flags, self.isStudio, player.UserId, self.creator),
		previewItems = previewItems,
		receipt = receipt,
		cancelled = cancelled,
	})
end

function ProductService:_clearPending(player, sku)
	local p = self.pending[player]
	if p then
		p[sku] = nil
	end
end

function ProductService:_fail(player, sku, reason, text)
	if self.telemetry then
		self.telemetry:Event(player, "purchase_failed", { sku = sku, reason = reason })
	end
	self:_clearPending(player, sku)
	if player.Parent then
		self.remotes.ProgressionNotice:FireClient(player, { kind = "Denied", text = text })
	end
	self:SendState(player)
	return reason
end

-- The client asked to buy `sku` (a button press; never automatic). Returns a result word.
function ProductService:RequestPurchase(player, sku)
	local offer = ShopConfig.BySku[sku]
	if not offer or not self.flags.Storefront or not ShopConfig.Listed(offer, self.clock()) then
		return self:_fail(player, sku, "unlisted", "That offer isn't available")
	end
	local profile = self.data:GetProfile(player)
	if not profile or profile.status == "Loading" or profile.status == "Unavailable" or profile.status == "ReadOnly" then
		return self:_fail(player, sku, "profile", "Your progress isn't loaded - try again in a moment")
	end
	local set = {}
	for _, id in ipairs(profile.data.cosmetics.owned) do
		set[id] = true
	end
	if ShopConfig.Ownership(offer, set, profile.data.purchases.entitlements).all then
		return self:_fail(player, sku, "owned", "You already own everything in " .. offer.label)
	end
	self.pending[player] = self.pending[player] or {}
	if self.pending[player][sku] and os.clock() - self.pending[player][sku] < ProductService.PendingSeconds then
		return "pending" -- a prompt / verification for this offer is already open
	end
	local id = ShopConfig.IdFor(offer, self.ids)
	if self.flags.PaidOffers and id then
		self.pending[player][sku] = os.clock()
		if self.telemetry then
			self.telemetry:Event(player, "checkout_start", { sku = sku })
		end
		self:SendState(player)
		local ok = pcall(function()
			if offer.kind == "GamePass" then
				MarketplaceService:PromptGamePassPurchase(player, id)
			else
				MarketplaceService:PromptProductPurchase(player, id)
			end
		end)
		if not ok then
			return self:_fail(player, sku, "prompt", "Roblox couldn't open the purchase prompt right now")
		end
		return "prompted"
	end
	if ProductService.OwnerPreviewAllowed(self.flags, self.isStudio, player.UserId, self.creator) then
		local added
		self.data:Update(player, function(data)
			added = ProductService.PreviewGrantOn(data, offer, self.clock())
		end)
		if not added then
			return self:_fail(player, sku, "profile", "Your progress isn't loaded - try again in a moment")
		end
		self.data:SaveSoon(player)
		if self.cosmetics then
			self.cosmetics:SendState(player)
		end
		if self.telemetry then
			self.telemetry:Event(player, "preview_grant", { sku = sku })
		end
		self:SendState(player, { sku = sku, items = offer.grants, preview = true })
		return "preview"
	end
	return self:_fail(player, sku, "not_on_sale", "Not on sale yet")
end

function ProductService:ResetPreview(player)
	if not ProductService.OwnerPreviewAllowed(self.flags, self.isStudio, player.UserId, self.creator) then
		return nil
	end
	local removed = {}
	self.data:Update(player, function(data)
		removed = ProductService.PreviewResetOn(data)
	end)
	self.data:SaveSoon(player)
	if self.cosmetics then
		self.cosmetics:SendState(player)
	end
	if self.marbles then
		self.marbles:RefreshLook(player)
	end
	self.remotes.ProgressionNotice:FireClient(player, { kind = "Purchase", text = string.format("Preview reset: %d item(s) taken back", #removed) })
	self:SendState(player)
	return removed
end

-- After Roblox's pass prompt closes: verify with Roblox (it can lag), then receipt or cancel
function ProductService:_afterPassPrompt(player, passId, purchased)
	local sku
	for _, offer in ipairs(ShopConfig.Offers) do
		if offer.kind == "GamePass" and ShopConfig.IdFor(offer, self.ids) == passId then
			sku = offer.sku
		end
	end
	if not purchased then
		if sku then
			self:_clearPending(player, sku)
			if self.telemetry then
				self.telemetry:Event(player, "purchase_cancelled", { sku = sku })
			end
		end
		self:CheckGamePasses(player)
		self:SendState(player, nil, sku)
		return
	end
	for attempt = 1, 3 do
		local verified = self:CheckGamePasses(player)
		if sku and verified[sku] then
			self:_clearPending(player, sku)
			if self.telemetry then
				self.telemetry:Event(player, "purchase_confirmed", { sku = sku })
			end
			self:SendState(player, { sku = sku, items = ShopConfig.BySku[sku].grants })
			return
		end
		if attempt < 3 then
			task.wait(2)
		end
	end
	-- still not visible: stays pending (re-checked on rejoin); the client shows "Verifying"
	self:SendState(player)
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
	self.maid:Give(MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
		task.spawn(function()
			self:_afterPassPrompt(player, passId, purchased) -- re-verify with Roblox; the prompt result alone grants nothing
		end)
	end))
	self.maid:Give(MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, productId, purchased)
		local player = Players:GetPlayerByUserId(userId)
		local offer = self.productMap[productId]
		if player and offer and not purchased then
			self:_clearPending(player, offer.sku)
			if self.telemetry then
				self.telemetry:Event(player, "purchase_cancelled", { sku = offer.sku })
			end
			self:SendState(player, nil, offer.sku)
		end
		-- purchased: the grant arrives through ProcessReceipt (never from this event)
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
		if self.telemetry then
			self.telemetry:Event(player, "shop_view", {})
		end
		-- a purchase still "verifying": ask Roblox again when the shop opens
		if next(self.pending[player] or {}) then
			task.spawn(function()
				local verified = self:CheckGamePasses(player)
				for sku in pairs(verified) do
					if self.pending[player] and self.pending[player][sku] then
						self:_clearPending(player, sku)
						self:SendState(player, { sku = sku, items = ShopConfig.BySku[sku].grants })
					end
				end
				self:SendState(player)
			end)
			return
		end
		self:SendState(player)
	end)
	connect("RequestShopPurchase", function(player, sku)
		task.spawn(function()
			self:RequestPurchase(player, sku)
		end)
	end)
	connect("RequestShopPreviewReset", function(player)
		self:ResetPreview(player)
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
		self.pending[player] = nil
	end))
end

function ProductService:Destroy()
	self.maid:Cleanup()
end

return ProductService
