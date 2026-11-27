--[[
	ShopConfig (D1) — the OPTIONAL direct-sale cosmetic shop. Pick exactly what you want;
	everything is cosmetic (no physics, rewards, XP or matchmaking effect). Prices are NEVER
	written here: the shop shows Roblox's own localized price for the player
	(MarketplaceService product info), or "Price unavailable". An offer whose id in
	PLACEHOLDER_IDS is nil shows "Not on sale yet" and has no working button.
	Paid random capsules do not exist in this build (ENABLE_PAID_CAPSULES = false).

	2026-11-27 shop brief (docs/SHOP.md): the launch catalog (Gridline, Reactor Glass, Afterburn
	Ribbon, Victory Pulse, Pit Crew Pack) as permanent Game Passes; storefront sections
	(Featured / Marble / Trails / Celebrations / Driver Profile); bundle views with partial
	ownership; flags. Every offer has a stable `sku` (never renamed; retired offers stay here
	with availability "Retired" so old receipts and passes still resolve and owners keep and
	equip their items). The proposed Robux numbers live ONLY in PreviewTestData, shown with a
	PREVIEW label until a live id is configured and paid offers are switched on by the owner.
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
	-- 2026-11-27 launch catalog: permanent one-time offers -> Game Passes (ownership is checked
	-- with Roblox on join and after every prompt; grants are idempotent)
	{ sku = "gridline", kind = "GamePass", idKey = "Gridline", grants = { "plate_gridline" }, label = "Gridline", category = "Plate", section = "Profile", term = "Permanent", featured = true, blurb = "A results nameplate with a checkered corner accent." },
	{ sku = "reactor_glass", kind = "GamePass", idKey = "ReactorGlass", grants = { "reactor_glass" }, label = "Reactor Glass", category = "Marble", section = "Marble", term = "Permanent", featured = true, blurb = "A dark blue glass shell around an amber core. Same size, grip and collision as every marble." },
	{ sku = "afterburn_ribbon", kind = "GamePass", idKey = "AfterburnRibbon", grants = { "trail_afterburn" }, label = "Afterburn Ribbon", category = "Trail", section = "Trails", term = "Permanent", featured = true, blurb = "Thin orange twin ribbons that lengthen with your speed (speed itself never changes)." },
	{ sku = "victory_pulse", kind = "GamePass", idKey = "VictoryPulse", grants = { "podium_victory_pulse" }, label = "Victory Pulse", category = "Podium", section = "Celebrations", term = "Permanent", featured = true, blurb = "When you win, a brief gold ring frames your marble on the results podium." },
	{ sku = "pit_crew_pack", kind = "GamePass", idKey = "PitCrewPack", grants = { "reactor_glass", "trail_afterburn", "plate_gridline" }, contains = { "reactor_glass", "afterburn_ribbon", "gridline" }, label = "Pit Crew Pack", category = "Pack", section = "Featured", term = "Permanent", featured = true, blurb = "Reactor Glass + Afterburn Ribbon + Gridline, as one fixed offer." },
}

-- 2026-11-27: storefront sections (Cases stay a separate tab, visibly distinct)
ShopConfig.Sections = { "Featured", "Marble", "Trails", "Celebrations", "Profile" }
ShopConfig.SectionLabels = { Featured = "FEATURED", Marble = "MARBLE", Trails = "TRAILS", Celebrations = "CELEBRATIONS", Profile = "DRIVER PROFILE" }
local SECTION_FOR_CATEGORY = { Marble = "Marble", Launch = "Marble", Trail = "Trails", Burst = "Celebrations", Emote = "Celebrations", Podium = "Celebrations", Plate = "Profile", Pack = "Featured", Season = "Featured" }

-- Feature flags. PaidOffers stays false until the owner approves real prices and activation;
-- then a listed offer with a configured id opens Roblox's own purchase prompt. OwnerPreview lets
-- the experience owner (and Studio) run the whole purchase flow with NO Robux: a preview grant,
-- labelled PREVIEW, that the owner can reset. Turning a listing off never removes ownership.
ShopConfig.Flags = {
	Storefront = true,
	PaidOffers = false,
	OwnerPreview = true,
}

-- Proposed base Robux numbers from the owner's brief (hypotheses). Shown ONLY as "PREVIEW ·
-- proposed N" until the live marketplace price can be read for the player.
ShopConfig.PreviewTestData = { gridline = 39, reactor_glass = 79, afterburn_ribbon = 79, victory_pulse = 99, pit_crew_pack = 149 }

-- Catalog slots for future cosmetics: designed, not built, never listed (docs/SHOP.md).
ShopConfig.FutureSlots = {
	{ key = "map_foundry_shift", label = "Foundry Shift (steel + amber)", status = "Planned" },
	{ key = "map_sky_enamel", label = "Sky Carnival (enamel + ribbons)", status = "Planned" },
	{ key = "map_volcano_obsidian", label = "Volcano Vault (obsidian + ember)", status = "Planned" },
	{ key = "supporter_pack", label = "One-time Supporter Pack (shell, trail, banner, victory pose)", status = "Planned" },
	{ key = "replay_frames", label = "Replay card frames", status = "Planned" },
	{ key = "boost_flares", label = "Visual-only boost flares", status = "Planned" },
}

ShopConfig.BySku = {}
for _, offer in ipairs(ShopConfig.Offers) do
	ShopConfig.BySku[offer.sku] = offer
	offer.section = offer.section or SECTION_FOR_CATEGORY[offer.category] or "Featured"
	offer.availability = offer.availability or "Live"
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

-- Listed in the storefront now? (Live, inside optional start / end times). Retired / hidden
-- offers are never listed, but their items stay owned and equipable.
function ShopConfig.Listed(offer, now)
	if not offer or offer.availability ~= "Live" then
		return false
	end
	if offer.startsAt and now < offer.startsAt then
		return false
	end
	if offer.endsAt and now >= offer.endsAt then
		return false
	end
	return true
end

-- Offers shown in a section (Featured = featured flag or section Featured)
function ShopConfig.InSection(section, now)
	local out = {}
	for _, offer in ipairs(ShopConfig.Offers) do
		if ShopConfig.Listed(offer, now or 0) and (offer.section == section or (section == "Featured" and offer.featured)) then
			out[#out + 1] = offer
		end
	end
	return out
end

-- Ownership of an offer's items: owned / total / missing ids (entitlement offers: the right)
function ShopConfig.Ownership(offer, ownedSet, entitlements)
	if offer.entitlement then
		local has = entitlements ~= nil and entitlements[offer.entitlement] == true
		return { owned = has and 1 or 0, total = 1, missing = has and {} or { offer.entitlement }, all = has }
	end
	local missing, owned = {}, 0
	for _, id in ipairs(offer.grants) do
		if ownedSet[id] then
			owned = owned + 1
		else
			missing[#missing + 1] = id
		end
	end
	return { owned = owned, total = #offer.grants, missing = missing, all = #missing == 0 and #offer.grants > 0 }
end

-- The single-item listed offer that sells exactly this item (the standalone route)
function ShopConfig.StandaloneFor(itemId, now)
	for _, offer in ipairs(ShopConfig.Offers) do
		if #offer.grants == 1 and offer.grants[1] == itemId and not offer.contains and ShopConfig.Listed(offer, now or 0) then
			return offer
		end
	end
	return nil
end

-- A bundle as this player sees it. priceOf(sku) -> number (the live price for this player) or
-- nil (unknown). Savings and the "cheaper separately" hint come ONLY from prices shown now.
function ShopConfig.BundleView(bundle, ownedSet, priceOf, now)
	local items, missingTotal, known = {}, 0, true
	local missing = 0
	for _, id in ipairs(bundle.grants) do
		local single = ShopConfig.StandaloneFor(id, now)
		local price = single and priceOf(single.sku) or nil
		local owned = ownedSet[id] == true
		items[#items + 1] = { id = id, owned = owned, sku = single and single.sku or nil, price = price }
		if not owned then
			missing = missing + 1
			if type(price) == "number" then
				missingTotal = missingTotal + price
			else
				known = false
			end
		end
	end
	local bundlePrice = priceOf(bundle.sku)
	local view = { items = items, missing = missing, allOwned = missing == 0, bundlePrice = bundlePrice, missingTotal = known and missingTotal or nil }
	if type(bundlePrice) == "number" and view.missingTotal and missing > 0 then
		view.standaloneCheaper = view.missingTotal < bundlePrice
		view.savings = bundlePrice < view.missingTotal and (view.missingTotal - bundlePrice) or nil
	end
	view.canBuy = not view.allOwned
	return view
end

-- What the checkout button does. ctx = { owned (all items), equipped, id (configured), price
-- (number | false = lookup failed | nil = loading), paid (PaidOffers flag), preview (owner
-- preview allowed), pending (a purchase is being verified), listed }
-- -> state, enabled. States: Owned, Pending, Unlisted, Buy, Preview, Loading, PriceUnavailable,
-- NotOnSale
function ShopConfig.Checkout(ctx)
	if ctx.owned then
		return "Owned", false
	end
	if ctx.pending then
		return "Pending", false
	end
	if ctx.listed == false then
		return "Unlisted", false
	end
	if ctx.paid and ctx.id then
		if ctx.price == false then
			return "PriceUnavailable", false
		elseif type(ctx.price) ~= "number" then
			return "Loading", false
		end
		return "Buy", true
	end
	if ctx.preview then
		return "Preview", true
	end
	return "NotOnSale", false
end

return ShopConfig
