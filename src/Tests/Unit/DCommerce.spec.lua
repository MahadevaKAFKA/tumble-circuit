--[[
	DCommerce.spec — Phase D: the optional shop is off as shipped (every id nil), receipts are
	idempotent on PurchaseId and only acknowledged after a save, season premium is season-keyed,
	paid random capsules don't exist, prices are never hard-coded, anti-cheat aggregation.
	Real purchases can only be tested by the owner in a live/staging game.
]]

local Spec = {}

function Spec.run(m)
	local results = { passed = 0, failed = 0, lines = {}, info = {} }
	local function check(name, ok, detail)
		if ok then
			results.passed = results.passed + 1
			table.insert(results.lines, "PASS  " .. name)
		else
			results.failed = results.failed + 1
			table.insert(results.lines, "FAIL  " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
		end
	end
	local SC, Ids, Schema, C = m.ShopConfig, m.PlaceholderIds, m.PlayerDataSchema, m.Catalog
	------------------------------------------------------------------ off as shipped
	local anyId = false
	for _, offer in ipairs(SC.Offers) do
		if SC.IdFor(offer, Ids) then
			anyId = true
		end
	end
	check("as shipped: no product or Game Pass id is set (nothing purchasable)", not anyId and next(SC.ProductMap(Ids)) == nil)
	check("paid random capsules OFF (ENABLE_PAID_CAPSULES = false)", Ids.ENABLE_PAID_CAPSULES == false)
	check("ids must be positive whole numbers", SC.IdFor(SC.Offers[1], { Products = { MarblePolishedCopper = "123" } }) == nil and SC.IdFor(SC.Offers[1], { Products = { MarblePolishedCopper = 1.5 } }) == nil and SC.IdFor(SC.Offers[1], { Products = { MarblePolishedCopper = 42 } }) == 42)
	local noPrice, realItems = true, true
	for _, offer in ipairs(SC.Offers) do
		for key in pairs(offer) do
			if string.lower(key):find("price") or string.lower(key):find("robux") then
				noPrice = false
			end
		end
		for _, id in ipairs(offer.grants) do
			realItems = realItems and C.Get(id) ~= nil
		end
	end
	check("no prices written in the shop config (Roblox's localized price is shown)", noPrice)
	check("every offer grants real catalog items; season premium is season-keyed", realItems and SC.BySku.season_premium_s1.entitlement == "SeasonPremium:S1")
	local exclusivesOk = true
	for _, tier in ipairs({ "Common", "Rare", "Epic", "Legendary", "Mythic" }) do
		for _, id in ipairs(C.MarblesOfRarity(tier)) do
			exclusivesOk = exclusivesOk and not C.Get(id).Exclusive
		end
	end
	check("Founder / premium exclusives are never in capsule pools", exclusivesOk)
	local CS = m.CapsuleService
	local dd = Schema.Defaults()
	dd.shards = 99999
	check("exclusives are not in the Shard Shop", CS.ShardBuyOn(dd, "trail_founder_gold") == nil and CS.ShardBuyOn(dd, "s1_launch_comet") == nil)

	------------------------------------------------------------------ receipts
	local PS = m.ProductService
	local offer = SC.BySku.marble_phoenix_ember
	local d = Schema.Defaults()
	local r1 = PS.GrantOn(d, offer, "P-1")
	local r2 = PS.GrantOn(d, offer, "P-1")
	local count = 0
	for _, id in ipairs(d.cosmetics.owned) do
		if id == "phoenix_ember" then
			count = count + 1
		end
	end
	check("receipt grant once; the same PurchaseId again = duplicate, nothing granted twice", r1 == "granted" and r2 == "duplicate" and count == 1 and d.purchases.journal[1] == "P-1")
	for i = 1, 250 do
		PS.GrantOn(d, offer, "J-" .. i)
	end
	check("journal keeps the newest 200 purchase ids", #d.purchases.journal == 200 and d.purchases.journal[1] == "J-250")

	-- ProcessReceipt with fakes: player missing / unknown product / save failure then retry
	local D = { PurchaseGranted = "Granted", NotProcessedYet = "NotYet" }
	local player = { UserId = 7, Name = "p", Parent = true, SetAttribute = function() end }
	local profile = { status = "Ready", data = Schema.Defaults() }
	local saves, saveOk = 0, false
	local fakeData = {
		GetProfile = function()
			return profile
		end,
		Update = function(_, _, fn)
			fn(profile.data)
			return true
		end,
		SaveNow = function()
			saves = saves + 1
			return saveOk
		end,
		SaveSoon = function() end,
		ProfileLoaded = { Connect = function() end },
	}
	local fired = {}
	local remote = { FireClient = function(_, _, payload)
		fired[#fired + 1] = payload
	end }
	local svc = PS.new({ data = fakeData, remotes = { ProgressionNotice = remote, ShopState = remote }, decisions = D, ids = { Products = { MarblePhoenixEmber = 555 } }, findPlayer = function(id)
		return id == 7 and player or nil
	end })
	check("receipt for a player not in the server -> NotProcessedYet (Roblox retries on rejoin)", svc:ProcessReceipt({ PlayerId = 8, ProductId = 555, PurchaseId = "X" }) == "NotYet")
	check("receipt for an unknown / unconfigured product -> NotProcessedYet, nothing granted", svc:ProcessReceipt({ PlayerId = 7, ProductId = 999, PurchaseId = "Y" }) == "NotYet" and #profile.data.purchases.journal == 0)
	local first = svc:ProcessReceipt({ PlayerId = 7, ProductId = 555, PurchaseId = "Z" })
	check("save failed -> NotProcessedYet (not acknowledged)", first == "NotYet" and saves == 1)
	saveOk = true
	local second = svc:ProcessReceipt({ PlayerId = 7, ProductId = 555, PurchaseId = "Z" })
	local third = svc:ProcessReceipt({ PlayerId = 7, ProductId = 555, PurchaseId = "Z" })
	local owned = 0
	for _, id in ipairs(profile.data.cosmetics.owned) do
		if id == "phoenix_ember" then
			owned = owned + 1
		end
	end
	check("retry after a good save -> PurchaseGranted; repeated callbacks never grant twice", second == "Granted" and third == "Granted" and owned == 1)
	profile.status = "Loading"
	check("profile still loading -> NotProcessedYet", svc:ProcessReceipt({ PlayerId = 7, ProductId = 555, PurchaseId = "W" }) == "NotYet")

	------------------------------------------------------------------ season premium
	local season = m.SeasonConfig.Seasons[1]
	local p = Schema.Defaults()
	p.season = { id = "S1", xp = 9000, claimed = {} }
	local none, why = PS.PremiumClaimOn(p, 10, season.startsAt + 5)
	check("premium lane needs this season's entitlement", none == nil and string.find(why, "not owned") ~= nil)
	p.purchases.entitlements["SeasonPremium:S1"] = true
	local item = PS.PremiumClaimOn(p, 10, season.startsAt + 5)
	local again = PS.PremiumClaimOn(p, 10, season.startsAt + 6)
	check("premium reward claimed once at level 10", item == "trail_s1_launch" and again == nil)
	check("after the season ends the S1 entitlement claims nothing (never carries over)", PS.PremiumClaimOn(p, 20, season.endsAt + 5) == nil)
	p.season.xp = 2000
	check("premium rewards still need the season level", PS.PremiumClaimOn(p, 30, season.startsAt + 7) == nil)

	------------------------------------------------------------------ profile v5
	local mig = Schema.Migrate({ schemaVersion = 4, coins = 12 })
	check("v4 -> v5: purchases journal added, coins kept", mig.schemaVersion == Schema.Version and mig.coins == 12 and type(mig.purchases.journal) == "table")
	local bad = Schema.Migrate({ schemaVersion = 5, purchases = { journal = { "a", 5 }, entitlements = { ["SeasonPremium:S1"] = true, x = "yes" } } })
	check("v5 sanitize: journal strings only, entitlements true only", #bad.purchases.journal == 1 and bad.purchases.entitlements["SeasonPremium:S1"] == true and bad.purchases.entitlements.x == nil)

	------------------------------------------------------------------ shop UI text / anti-cheat
	local Shop = m.ShopPure
	if Shop then
		check("shop button: no id -> NOT ON SALE YET (disabled)", select(2, Shop.ButtonText({ id = nil }, nil, false)) == false and Shop.ButtonText({ id = nil }) == "NOT ON SALE YET")
		check("shop button: price lookup failed -> PRICE UNAVAILABLE (disabled, never a guess)", Shop.ButtonText({ id = 1 }, nil, true) == "PRICE UNAVAILABLE" and select(2, Shop.ButtonText({ id = 1 }, nil, true)) == false)
		check("shop button: Roblox's price shown; owned -> OWNED", Shop.ButtonText({ id = 1 }, 99, false) == "GET  -  99 Robux" and Shop.ButtonText({ id = 1, owned = true }, 99) == "OWNED")
	end
	local AC = m.AntiCheatService
	if AC then
		check("anti-cheat: scores halve every 60 s (lag blips fade)", math.abs(AC.Decay(8, 60) - 4) < 1e-9)
		check("anti-cheat: flood = over 3x a remote's allowed rate in 5 s", AC.IsFlood(31, 0.5) and not AC.IsFlood(30, 0.5))
		local ac = AC.new({ remotes = {} })
		local t = 0
		ac.clock = function()
			return t
		end
		local warned = 0
		local fake = { Name = "x", UserId = 1, Parent = true, GetAttribute = function()
			return 0
		end, SetAttribute = function()
			warned = warned + 1
		end }
		for _ = 1, 4 do
			ac:Flag(fake, "Malformed", "test")
		end
		local before = warned
		ac:Flag(fake, "Malformed", "test")
		ac:Flag(fake, "Malformed", "test")
		check("anti-cheat: one report when a category crosses its threshold, no ban", before == 0 and warned == 1)
	end
	return results
end

return Spec
