--[[
	Shop.spec (shop brief, 2026-11-27) — the launch catalog and its purchase paths offline:
	catalog + sections, bundle views with partial ownership and honest savings, checkout states,
	the owner's no-Robux preview (grant, no second grant, reset takes back only what it added),
	server-initiated prompts (never for owned durable offers, never twice while pending),
	cancellation, delayed pass verification and rejoin, overlapping offers across sessions,
	retired offers, validated race looks, legacy profiles, results plate/pulse and client text.
	Real Roblox purchases cannot run here: the marketplace is a scripted fake.
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
	local SC, C, Schema, PS = m.ShopConfig, m.Catalog, m.PlayerDataSchema, m.ProductService
	local now = 1800000000

	---------------------------------------------------------------- catalog
	local five = { "gridline", "reactor_glass", "afterburn_ribbon", "victory_pulse", "pit_crew_pack" }
	local okFive = true
	for _, sku in ipairs(five) do
		local o = SC.BySku[sku]
		okFive = okFive and o ~= nil and o.kind == "GamePass" and o.term == "Permanent" and SC.Listed(o, now)
		for _, id in ipairs(o and o.grants or {}) do
			okFive = okFive and C.Get(id) ~= nil and C.Get(id).Exclusive == "Shop"
		end
	end
	check("the five launch offers: permanent passes granting real shop-only items", okFive)
	local pack = SC.BySku.pit_crew_pack
	check("Pit Crew Pack = Reactor Glass + Afterburn Ribbon + Gridline (fixed contents)", #pack.grants == 3 and pack.grants[1] == "reactor_glass" and pack.grants[2] == "trail_afterburn" and pack.grants[3] == "plate_gridline")
	check("paid offers are OFF as shipped; no pass id configured; preview prices are the brief's proposals", SC.Flags.PaidOffers == false and SC.IdFor(pack, m.PlaceholderIds) == nil and SC.PreviewTestData.gridline == 39 and SC.PreviewTestData.reactor_glass == 79 and SC.PreviewTestData.afterburn_ribbon == 79 and SC.PreviewTestData.victory_pulse == 99 and SC.PreviewTestData.pit_crew_pack == 149)
	local feat = {}
	for _, o in ipairs(SC.InSection("Featured", now)) do
		feat[o.sku] = true
	end
	local sectionsOk = feat.gridline and feat.pit_crew_pack and feat.victory_pulse and SC.BySku.gridline.section == "Profile" and SC.BySku.victory_pulse.section == "Celebrations" and SC.BySku.afterburn_ribbon.section == "Trails" and SC.BySku.reactor_glass.section == "Marble" and SC.BySku.launch_spring.section == "Marble" and SC.BySku.burst_lightning.section == "Celebrations"
	check("sections: Featured shows the launch catalog; each offer sits in its section (D1 offers mapped too)", sectionsOk)
	local timed = { availability = "Live", startsAt = now + 10, endsAt = now + 100 }
	check("listing windows and retirement: future / ended / retired offers are not listed", not SC.Listed(timed, now) and SC.Listed(timed, now + 50) and not SC.Listed(timed, now + 100) and not SC.Listed({ availability = "Retired" }, now))
	check("future slots are designed but never listed", #SC.FutureSlots >= 5 and SC.BySku.supporter_pack == nil)

	---------------------------------------------------------------- bundle view
	local prices = { reactor_glass = 79, afterburn_ribbon = 79, gridline = 39, pit_crew_pack = 149 }
	local function priceOf(sku)
		return prices[sku]
	end
	local v0 = SC.BundleView(pack, {}, priceOf, now)
	check("nothing owned: missing items separately 197, pack 149 -> savings 48 (from the shown prices)", v0.missing == 3 and v0.missingTotal == 197 and v0.savings == 48 and v0.standaloneCheaper == false and v0.canBuy)
	local v1 = SC.BundleView(pack, { reactor_glass = true, trail_afterburn = true }, priceOf, now)
	check("partial (2 of 3 owned): Gridline alone 39 < pack 149 -> standalone route made prominent, no savings claim", v1.missing == 1 and v1.missingTotal == 39 and v1.standaloneCheaper == true and v1.savings == nil and v1.items[3].sku == "gridline")
	local v2 = SC.BundleView(pack, { reactor_glass = true, trail_afterburn = true, plate_gridline = true }, priceOf, now)
	check("everything owned: no purchase action", v2.allOwned and not v2.canBuy)
	local v3 = SC.BundleView(pack, {}, function(sku)
		return sku == "pit_crew_pack" and 149 or nil
	end, now)
	check("unknown standalone prices: no combined price and no savings claim", v3.missingTotal == nil and v3.savings == nil and v3.standaloneCheaper == nil)
	local v4 = SC.BundleView(pack, {}, function(sku)
		return sku == "pit_crew_pack" and 249 or prices[sku]
	end, now)
	check("a regional price where the pack costs more than the parts: no savings, separately is cheaper", v4.savings == nil and v4.standaloneCheaper == true)

	---------------------------------------------------------------- checkout states
	local CO = SC.Checkout
	check("checkout: owned / pending / unlisted always disabled", CO({ owned = true, paid = true, id = 1, price = 79 }) == "Owned" and CO({ pending = true, paid = true, id = 1, price = 79 }) == "Pending" and CO({ listed = false, preview = true }) == "Unlisted")
	local s1, e1 = CO({ paid = true, id = 1, price = 79 })
	local s2, e2 = CO({ paid = true, id = 1, price = false })
	local s3, e3 = CO({ paid = true, id = 1 })
	check("checkout: live price -> Buy; failed lookup -> Price unavailable (disabled); loading disabled", s1 == "Buy" and e1 and s2 == "PriceUnavailable" and not e2 and s3 == "Loading" and not e3)
	local s4, e4 = CO({ paid = false, id = 1, preview = true })
	local s5, e5 = CO({ paid = false, id = nil, preview = false })
	check("checkout: paid off -> owner Preview (no Robux) or Not on sale yet", s4 == "Preview" and e4 and s5 == "NotOnSale" and not e5)

	---------------------------------------------------------------- server flows (fake marketplace)
	local market = m.ShopMarket
	local prompts, owns = {}, {}
	if market then
		market.PromptGamePassPurchase = function(_, player, id)
			prompts[#prompts + 1] = { player = player, id = id }
		end
		market.PromptProductPurchase = function(_, player, id)
			prompts[#prompts + 1] = { player = player, id = id, product = true }
		end
		market.UserOwnsGamePassAsync = function(_, userId, id)
			return owns[userId .. ":" .. id] == true
		end
	end
	local savedTask = task
	_G.task = { spawn = function(f, ...)
		return f(...)
	end, wait = function() end, delay = function() end }
	local okFlow, flowErr = pcall(function()
		check("owner preview: Studio or the experience's owning user only, and only while paid offers are off",
			PS.OwnerPreviewAllowed({ OwnerPreview = true, PaidOffers = false }, false, 42, { isUser = true, id = 42 })
				and not PS.OwnerPreviewAllowed({ OwnerPreview = true, PaidOffers = false }, false, 43, { isUser = true, id = 42 })
				and not PS.OwnerPreviewAllowed({ OwnerPreview = true, PaidOffers = false }, false, 42, { isUser = false, id = 42 })
				and PS.OwnerPreviewAllowed({ OwnerPreview = true, PaidOffers = false }, true, 7, nil)
				and not PS.OwnerPreviewAllowed({ OwnerPreview = true, PaidOffers = true }, true, 42, { isUser = true, id = 42 }))
		local function newPlayer(id)
			return { UserId = id, Parent = true, SetAttribute = function() end }
		end
		local owner, guest = newPlayer(42), newPlayer(77)
		local profiles = { [owner] = { status = "Ready", data = Schema.Defaults() }, [guest] = { status = "Ready", data = Schema.Defaults() } }
		table.insert(profiles[owner].data.cosmetics.owned, "plate_gridline") -- earned / owned before any preview
		local states, notices = {}, {}
		local remote = { FireClient = function(_, player, payload)
			if payload.offers then
				states[#states + 1] = { player = player, p = payload }
			else
				notices[#notices + 1] = { player = player, p = payload }
			end
		end }
		local data = {
			GetProfile = function(_, p)
				return profiles[p]
			end,
			Update = function(_, p, fn)
				fn(profiles[p].data)
				return true
			end,
			SaveSoon = function() end,
			SaveNow = function()
				return true
			end,
		}
		local flags = { Storefront = true, PaidOffers = false, OwnerPreview = true }
		local ids = { GamePasses = { PitCrewPack = 9001, ReactorGlass = 9002, Gridline = 9003, AfterburnRibbon = 9004 }, Products = {} }
		local svc = PS.new({ data = data, remotes = { ShopState = remote, ProgressionNotice = remote }, flags = flags, ids = ids, isStudio = false, creator = { isUser = true, id = 42 } })
		svc.clock = function()
			return now
		end
		local function lastState(p)
			for i = #states, 1, -1 do
				if states[i].player == p then
					return states[i].p
				end
			end
		end
		local function count(p, id)
			local n = 0
			for _, x in ipairs(profiles[p].data.cosmetics.owned) do
				if x == id then
					n = n + 1
				end
			end
			return n
		end
		-- owner preview of the pack (already owns Gridline from elsewhere)
		local r = svc:RequestPurchase(owner, "pit_crew_pack")
		local st = lastState(owner)
		check("paid off: the owner's purchase is a labelled preview grant (receipt with EQUIP), no prompt", r == "preview" and #prompts == 0 and st.receipt and st.receipt.preview == true and st.preview == true and count(owner, "reactor_glass") == 1 and count(owner, "trail_afterburn") == 1 and count(owner, "plate_gridline") == 1)
		check("the preview flags only what it added (Gridline was already owned)", profiles[owner].data.purchases.entitlements["Preview:reactor_glass"] and not profiles[owner].data.purchases.entitlements["Preview:plate_gridline"])
		check("owning everything: no second purchase of a durable offer", svc:RequestPurchase(owner, "pit_crew_pack") == "owned" and svc:RequestPurchase(owner, "gridline") == "owned")
		profiles[owner].data.cosmetics.equipped.marble = "reactor_glass"
		local removed = svc:ResetPreview(owner)
		check("RESET PREVIEW takes back only preview items; earned Gridline stays; an equipped preview look falls back to the default", #removed == 2 and count(owner, "reactor_glass") == 0 and count(owner, "plate_gridline") == 1 and profiles[owner].data.cosmetics.equipped.marble == C.Defaults.marble)
		check("a guest can't preview or buy while paid offers are off", svc:RequestPurchase(guest, "reactor_glass") == "not_on_sale" and count(guest, "reactor_glass") == 0)

		-- paid offers on (simulated owner approval): server-initiated prompt only
		flags.PaidOffers = true
		local rr = svc:RequestPurchase(guest, "reactor_glass")
		check("paid on + configured: the server opens Roblox's pass prompt (the client only asked)", rr == "prompted" and #prompts == 1 and prompts[1].id == 9002 and lastState(guest).offers ~= nil)
		check("no second prompt while that purchase is pending", svc:RequestPurchase(guest, "reactor_glass") == "pending" and #prompts == 1)
		svc:_afterPassPrompt(guest, 9002, false)
		check("prompt closed without buying: cancelled, nothing granted, pending cleared", lastState(guest).cancelled == "reactor_glass" and count(guest, "reactor_glass") == 0 and not (svc.pending[guest] or {}).reactor_glass)
		svc:RequestPurchase(guest, "reactor_glass")
		svc:_afterPassPrompt(guest, 9002, true) -- Roblox hasn't reported ownership yet
		check("bought but not yet visible: stays pending (VERIFYING), nothing granted early", count(guest, "reactor_glass") == 0 and (svc.pending[guest] or {}).reactor_glass ~= nil)
		owns["77:9002"] = true
		svc:CheckGamePasses(guest) -- rejoin / next check
		check("on the next check (or rejoin) the pass grants once", count(guest, "reactor_glass") == 1)
		svc:CheckGamePasses(guest)
		check("repeated checks never grant twice", count(guest, "reactor_glass") == 1)
		-- overlapping offers in another session: owns Reactor Glass, then buys the pack
		svc.pending[guest] = nil
		local rp = svc:RequestPurchase(guest, "pit_crew_pack")
		owns["77:9001"] = true
		svc:_afterPassPrompt(guest, 9001, true)
		local rec = lastState(guest).receipt
		check("overlap: the pack grants the missing two, keeps Reactor Glass once, and sends a receipt", rp == "prompted" and rec and rec.sku == "pit_crew_pack" and count(guest, "reactor_glass") == 1 and count(guest, "trail_afterburn") == 1 and count(guest, "plate_gridline") == 1)
		check("after owning the pack, its parts can't be prompted again", svc:RequestPurchase(guest, "gridline") == "owned" and svc:RequestPurchase(guest, "afterburn_ribbon") == "owned")
		-- a retired listing: no checkout, owners keep and equip it
		SC.BySku.victory_pulse.availability = "Retired"
		check("a retired offer can't be bought", svc:RequestPurchase(guest, "victory_pulse") == "unlisted")
		SC.BySku.victory_pulse.availability = "Live"
		flags.PaidOffers = false
		local offerState
		for _, o in ipairs(lastState(guest).offers) do
			if o.sku == "pit_crew_pack" then
				offerState = o
			end
		end
		check("shop state reports ownership counts per offer", offerState and offerState.owned == true and offerState.ownedCount == 3 and offerState.total == 3)
	end)
	_G.task = savedTask
	check("server purchase flows ran to the end", okFlow, flowErr)

	---------------------------------------------------------------- inventory + race looks
	local CosS = m.CosmeticService
	local d = Schema.Defaults()
	table.insert(d.cosmetics.owned, "reactor_glass")
	d.cosmetics.equipped.marble = "reactor_glass"
	d.cosmetics.equipped.trail = "trail_afterburn" -- not owned
	d.cosmetics.equipped.plate = "nope"
	local look = CosS.ValidLook(d.cosmetics)
	check("race snapshot look: owned items kept, unowned / unknown fall back to the free default", look.marble == "reactor_glass" and look.trail == C.Defaults.trail and look.plate == "plate_standard" and look.podium == "podium_standard")
	local okEquip = CosS.ApplyEquip(d.cosmetics, "Plate", "plate_gridline", 0)
	table.insert(d.cosmetics.owned, "plate_gridline")
	local okEquip2 = CosS.ApplyEquip(d.cosmetics, "Plate", "plate_gridline", 0)
	check("equipping needs ownership and the right slot (new Plate / Podium slots)", okEquip == false and okEquip2 == true and d.cosmetics.equipped.plate == "plate_gridline" and CosS.ApplyEquip(d.cosmetics, "Podium", "plate_gridline", 0) == false)
	local legacy = Schema.Migrate({ schemaVersion = 7, coins = 300, cosmetics = { owned = { "cobalt", "phoenix_ember" }, equipped = { marble = "phoenix_ember", trail = "trail_dust" } }, purchases = { journal = { "P-9" }, entitlements = { ["Pass:founder_pack"] = true } } })
	check("an older profile keeps coins, items, equipped look and purchase history; gains the free plate / podium", legacy.coins == 300 and legacy.cosmetics.equipped.marble == "phoenix_ember" and legacy.cosmetics.equipped.plate == "plate_standard" and legacy.cosmetics.equipped.podium == "podium_standard" and legacy.purchases.journal[1] == "P-9" and legacy.purchases.entitlements["Pass:founder_pack"] == true)

	---------------------------------------------------------------- results + client text
	local R = m.ResultsPure
	if R and R.PlateStyle then
		check("results plate: Gridline shows the checkered corner; unknown plates are plain", R.PlateStyle("plate_gridline").checkered and not R.PlateStyle("plate_standard").checkered and not R.PlateStyle(nil).checkered)
		local s0 = R.PulseRing(0.1, false)
		local s1x = R.PulseRing(0.7, false)
		local sOff = R.PulseRing(2, false)
		local sRed, aRed = R.PulseRing(0.5, true)
		check("Victory Pulse: two quick growing gold rings, then gone; Reduced Motion = one steady ring", s0 and s1x and s1x > s0 and sOff == nil and sRed == 80 and aRed < 0.5)
	end
	local Shop = m.ShopPure
	if Shop and Shop.CheckoutText then
		check("button text: BUY · price / EQUIP / EQUIPPED / PREVIEW BUY / PRICE UNAVAILABLE", Shop.CheckoutText("Buy", 79) == "BUY  ·  79 Robux" and Shop.CheckoutText("Owned", nil, "Equip") == "EQUIP" and Shop.CheckoutText("Owned", nil, "Equipped") == "EQUIPPED" and Shop.CheckoutText("Preview"):find("NO ROBUX", 1, true) and Shop.CheckoutText("PriceUnavailable") == "PRICE UNAVAILABLE")
		local line, isPreview = Shop.PriceLine(SC.BySku.reactor_glass, { paid = false })
		local live = Shop.PriceLine(SC.BySku.reactor_glass, { paid = true, id = 5, price = 85 })
		check("price line: PREVIEW · proposed 79 while off; the live (regional) price once on sale", line:find("PREVIEW", 1, true) and line:find("79", 1, true) and isPreview and live == "85 Robux")
		local _, _, slow = Shop.TrailLoop(1, false, 300, 120)
		local _, _, fast = Shop.TrailLoop(1, true, 300, 120)
		check("trail preview: FAST draws a longer trail than SLOW", #fast > #slow)
	end
	return results
end

return Spec
