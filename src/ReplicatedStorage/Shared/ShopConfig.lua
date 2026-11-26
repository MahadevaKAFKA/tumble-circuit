--[[
	ShopConfig (D1) — the OPTIONAL direct-sale cosmetic shop. Pick exactly what you want;
	everything is cosmetic (no physics, rewards, XP or matchmaking effect). Prices are NEVER
	written here: the shop shows Roblox's own localized price for the player
	(MarketplaceService product info), or "Price unavailable". An offer whose id in
	PLACEHOLDER_IDS is nil shows "Not on sale yet" and has no working button.
	Paid random capsules do not exist in this build (ENABLE_PAID_CAPSULES = false).
]]

local ShopConfig = {}

-- idKey = key in PlaceholderIds.Products / GamePasses; grants = catalog ids; entitlement = a
-- season-keyed right (claim the premium lane of that season only)
ShopConfig.Offers = {
	{ sku = "marble_polished_copper", kind = "DevProduct", idKey = "MarblePolishedCopper", grants = { "polished_copper" }, label = "Polished Copper", category = "Marble", term = "Permanent" },
	{ sku = "marble_quantum_chrome", kind = "DevProduct", idKey = "MarbleQuantumChrome", grants = { "quantum_chrome" }, label = "Quantum Chrome", category = "Marble", term = "Permanent" },
	{ sku = "marble_phoenix_ember", kind = "DevProduct", idKey = "MarblePhoenixEmber", grants = { "phoenix_ember" }, label = "Phoenix Ember", category = "Marble", term = "Permanent" },
	{ sku = "trail_ember", kind = "DevProduct", idKey = "TrailEmber", grants = { "trail_ember" }, label = "Ember trail", category = "Trail", term = "Permanent" },
	{ sku = "trail_rainbow", kind = "DevProduct", idKey = "TrailRainbow", grants = { "trail_rainbow" }, label = "Rainbow trail", category = "Trail", term = "Permanent" },
	{ sku = "burst_lightning", kind = "DevProduct", idKey = "BurstLightning", grants = { "burst_lightning" }, label = "Lightning finish", category = "Burst", term = "Permanent" },
	{ sku = "emote_rematch", kind = "DevProduct", idKey = "EmoteRematch", grants = { "emote_rematch" }, label = "Rematch? emote", category = "Emote", term = "Permanent" },
	{ sku = "founder_pack", kind = "GamePass", idKey = "FounderPack", grants = { "trail_founder_gold", "emote_founder_wave", "emote_founder_salute" }, label = "Founder's Style Pack", category = "Pack", term = "Permanent", extra = "Founder tag on your name and podium" },
	{ sku = "season_premium_s1", kind = "DevProduct", idKey = "SeasonPremium_S1", entitlement = "SeasonPremium:S1", grants = {}, label = "Season 1 premium lane", category = "Season", term = "Season 1 only", extra = "3 extra looks to claim at season levels 10 / 20 / 30, until Season 1 ends" },
	-- 2026-11-26: Launch Animations (look only: same duration, slot and timing as the free one)
	{ sku = "launch_spring", kind = "DevProduct", idKey = "LaunchSpringSnap", grants = { "launch_spring" }, label = "Spring Snap launch", category = "Launch", term = "Permanent" },
	{ sku = "launch_afterimage", kind = "DevProduct", idKey = "LaunchAfterimage", grants = { "launch_afterimage" }, label = "Afterimage Drop launch", category = "Launch", term = "Permanent" },
}

ShopConfig.BySku = {}
for _, offer in ipairs(ShopConfig.Offers) do
	ShopConfig.BySku[offer.sku] = offer
end

-- Season premium lane rewards (claimable only with that season's entitlement, during it)
ShopConfig.SeasonPremium = {
	S1 = { [10] = "trail_s1_launch", [20] = "burst_s1_launch", [30] = "s1_launch_comet" },
}

-- Resolve the configured id for an offer (nil = not on sale)
function ShopConfig.IdFor(offer, ids)
	local bucket = offer.kind == "GamePass" and ids.GamePasses or ids.Products
	local id = bucket and bucket[offer.idKey]
	if type(id) == "number" and id > 0 and id == math.floor(id) then
		return id
	end
	return nil
end

-- product id -> offer, for receipts (only configured products)
function ShopConfig.ProductMap(ids)
	local map = {}
	for _, offer in ipairs(ShopConfig.Offers) do
		local id = offer.kind == "DevProduct" and ShopConfig.IdFor(offer, ids)
		if id then
			map[id] = offer
		end
	end
	return map
end

return ShopConfig
