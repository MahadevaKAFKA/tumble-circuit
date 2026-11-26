--[[
	CapsuleOdds (C1) — the ONE pure function set used by the server roll and by the odds shown in
	the Capsule Lab (master section 10). No Roblox APIs, no hidden state.

	Tier table:
	  base           Common 55% / Rare 30% / Epic 11% / Legendary 3.5% / Mythic 0.5%
	  Epic+ pity     after 14 opens in a row without Epic or better, the next open is
	                 Epic 85% / Legendary 13% / Mythic 2%   (= the 15th open is always Epic+)
	  Legendary pity after 59 opens in a row without Legendary or better, the next open is
	                 Legendary 95% / Mythic 5%               (= the 60th open is always Legendary+)
	  Legendary pity wins when both apply. There is no guaranteed Mythic.
	Item: uniform among every non-exclusive catalog item of the box's kind and the drawn tier
	(owned ones included: a duplicate becomes Shards). Item odds = tier odds / items in that tier.
	A box whose kind has no item in a tier drops that tier and rescales the rest (EffectiveTiers).
	Counters after an open: an Epic+ result resets epicMisses, otherwise +1; a Legendary+ result
	resets legendaryMisses, otherwise +1.
]]

local CapsuleOdds = {}

CapsuleOdds.Version = 3 -- v3 (2026-11-26 economy): tiered cases, a guarantee counter per case
CapsuleOdds.Cost = 650 -- the Skin case (see Boxes); kept for older callers

-- Cases (owner brief 2026-11-26, economy). Earned Coins only (Coins come only from quests),
-- never Robux. Prices are in "daily quest equivalents" (one daily quest = 100 Coins; see
-- docs/ANIMATION_UI_ECONOMY_PLAN.md for the 1 / 7 / 30-day model):
--   STARTER  basic, 2.5 dailies   every kind, Common + Rare only (a mixed case: the reveal
--                                 masks show each entrant's category)
--   SKIN     specialist, 6.5      every marble skin, all rarities
--   TRAIL    specialist, 5.5      every trail, all rarities
--   APEX     high tier, 13        every kind, Epic / Legendary / Mythic only (a stronger pool)
-- Tiers a case can't drop are removed and the rest scaled to 100% (shown like that before
-- opening). Each case has its OWN guarantee counters (the Skin case keeps the old shared
-- counters, so no saved progress is lost); a guarantee for a tier the case can't drop gives
-- that case's best tier instead.
CapsuleOdds.Boxes = {
	{ Id = "Starter", Name = "STARTER CASE", Cost = 250, Tier = "BASIC", Kinds = { "Marble", "Trail", "Burst", "Emote" }, Rarities = { Common = true, Rare = true } },
	{ Id = "Marble", Name = "SKIN CASE", Cost = 650, Tier = "SPECIALIST", Kinds = { "Marble" } },
	{ Id = "Trail", Name = "TRAIL CASE", Cost = 550, Tier = "SPECIALIST", Kinds = { "Trail" } },
	{ Id = "Apex", Name = "APEX CASE", Cost = 1300, Tier = "HIGH TIER", Kinds = { "Marble", "Trail", "Burst", "Emote" }, Rarities = { Epic = true, Legendary = true, Mythic = true } },
}
-- earlier boxes (v2), only so old history lines still have a name
CapsuleOdds.LegacyNames = { Burst = "BURST CAPSULE", Emote = "EMOTE CAPSULE" }
CapsuleOdds.BoxById = {}
for _, box in ipairs(CapsuleOdds.Boxes) do
	box.Kind = #box.Kinds == 1 and box.Kinds[1] or "Mixed"
	box.Mixed = #box.Kinds > 1
	CapsuleOdds.BoxById[box.Id] = box
end
function CapsuleOdds.Box(id)
	return CapsuleOdds.BoxById[id or ""] or CapsuleOdds.BoxById.Marble
end
function CapsuleOdds.BoxName(id)
	local box = CapsuleOdds.BoxById[id or ""]
	return box and box.Name or CapsuleOdds.LegacyNames[id or ""] or "CASE"
end

-- Pools of a case: { [tier] = { ids } } in catalog order. itemsOfRarity(kind, tier) -> ids
-- (Catalog.ItemsOfRarity: never exclusives).
function CapsuleOdds.PoolsFor(box, itemsOfRarity)
	local pools = {}
	for _, tier in ipairs(CapsuleOdds.Tiers or { "Common", "Rare", "Epic", "Legendary", "Mythic" }) do
		local ids = {}
		if not box.Rarities or box.Rarities[tier] then
			for _, kind in ipairs(box.Kinds) do
				for _, id in ipairs(itemsOfRarity(kind, tier)) do
					ids[#ids + 1] = id
				end
			end
		end
		pools[tier] = ids
	end
	return pools
end

-- A case's guarantee counters in a profile's capsule table (the Skin case = the v1/v2 fields)
function CapsuleOdds.Counters(cap, boxId)
	if boxId == nil or boxId == "Marble" then
		return cap.epicMisses or 0, cap.legendaryMisses or 0
	end
	local p = cap.pity and cap.pity[boxId]
	return p and p.e or 0, p and p.l or 0
end

function CapsuleOdds.SetCounters(cap, boxId, e, l)
	if boxId == nil or boxId == "Marble" then
		cap.epicMisses, cap.legendaryMisses = e, l
		return
	end
	cap.pity = cap.pity or {}
	cap.pity[boxId] = { e = e, l = l }
end
CapsuleOdds.Tiers = { "Common", "Rare", "Epic", "Legendary", "Mythic" }
CapsuleOdds.Base = { Common = 0.55, Rare = 0.30, Epic = 0.11, Legendary = 0.035, Mythic = 0.005 }
CapsuleOdds.EpicPity = { Common = 0, Rare = 0, Epic = 0.85, Legendary = 0.13, Mythic = 0.02 }
CapsuleOdds.LegendaryPity = { Common = 0, Rare = 0, Epic = 0, Legendary = 0.95, Mythic = 0.05 }
CapsuleOdds.EpicPityAfter = 14 -- misses before the guaranteed open
CapsuleOdds.LegendaryPityAfter = 59
CapsuleOdds.DuplicateShards = { Common = 5, Rare = 20, Epic = 65, Legendary = 200, Mythic = 600 }
CapsuleOdds.ShardPrice = { Common = 60, Rare = 180, Epic = 600, Legendary = 1900, Mythic = 6000 }
CapsuleOdds.HistorySize = 20

local RANK = { Common = 1, Rare = 2, Epic = 3, Legendary = 4, Mythic = 5 }
CapsuleOdds.Rank = RANK

-- Which table applies for these counters: returns tierTable, branch ("Base"/"EpicPity"/"LegendaryPity")
function CapsuleOdds.TierTable(epicMisses, legendaryMisses)
	if (legendaryMisses or 0) >= CapsuleOdds.LegendaryPityAfter then
		return CapsuleOdds.LegendaryPity, "LegendaryPity"
	end
	if (epicMisses or 0) >= CapsuleOdds.EpicPityAfter then
		return CapsuleOdds.EpicPity, "EpicPity"
	end
	return CapsuleOdds.Base, "Base"
end

-- Opens left until each guarantee (1 = the next open is guaranteed)
function CapsuleOdds.Within(epicMisses, legendaryMisses)
	return CapsuleOdds.EpicPityAfter + 1 - (epicMisses or 0), CapsuleOdds.LegendaryPityAfter + 1 - (legendaryMisses or 0)
end

-- The tier table for THESE pools: tiers with no items are dropped and the rest scaled to 100%.
-- If every tier the table allows is empty (e.g. Legendary pity in a box without Legendary or
-- Mythic items), the box's highest non-empty tier is certain. Same as TierTable when every
-- tier has items (the Marble capsule).
function CapsuleOdds.EffectiveTiers(pools, epicMisses, legendaryMisses)
	local base, branch = CapsuleOdds.TierTable(epicMisses, legendaryMisses)
	local total, out = 0, {}
	for _, tier in ipairs(CapsuleOdds.Tiers) do
		local p = (#(pools[tier] or {}) > 0) and (base[tier] or 0) or 0
		out[tier] = p
		total = total + p
	end
	if total <= 0 then
		local best = nil
		for _, tier in ipairs(CapsuleOdds.Tiers) do
			if #(pools[tier] or {}) > 0 then
				best = tier
			end
		end
		for _, tier in ipairs(CapsuleOdds.Tiers) do
			out[tier] = tier == best and 1 or 0
		end
		return out, branch
	end
	if math.abs(total - 1) > 1e-12 then
		for _, tier in ipairs(CapsuleOdds.Tiers) do
			out[tier] = out[tier] / total
		end
	end
	return out, branch
end

-- Per-item odds for the given pools ({ [tier] = {ids...} }); returns list { id, tier, p }
function CapsuleOdds.ItemOdds(pools, epicMisses, legendaryMisses)
	local tiers = CapsuleOdds.EffectiveTiers(pools, epicMisses, legendaryMisses)
	local out = {}
	for _, tier in ipairs(CapsuleOdds.Tiers) do
		local ids = pools[tier] or {}
		for _, id in ipairs(ids) do
			out[#out + 1] = { id = id, tier = tier, p = (tiers[tier] or 0) / #ids }
		end
	end
	return out
end

-- Pure roll from two uniform numbers in [0, 1): u picks the tier, v the item in it.
function CapsuleOdds.RollWith(u, v, pools, epicMisses, legendaryMisses)
	local tiers, branch = CapsuleOdds.EffectiveTiers(pools, epicMisses, legendaryMisses)
	local acc, chosen = 0, nil
	for _, tier in ipairs(CapsuleOdds.Tiers) do
		local p = tiers[tier] or 0
		if p > 0 then
			acc = acc + p
			chosen = tier
			if u < acc then
				break
			end
		end
	end
	local ids = pools[chosen] or {}
	local index = math.min(#ids, math.floor(v * #ids) + 1)
	return chosen, ids[index], branch
end

-- Counters after an open with result `tier`
function CapsuleOdds.After(tier, epicMisses, legendaryMisses)
	local rank = RANK[tier] or 1
	local e = rank >= RANK.Epic and 0 or (epicMisses or 0) + 1
	local l = rank >= RANK.Legendary and 0 or (legendaryMisses or 0) + 1
	return e, l
end

-- Display: "12.345%" style text with enough decimals that small odds never read as 0
function CapsuleOdds.Percent(p)
	local pct = p * 100
	if pct == 0 then
		return "0%"
	elseif pct >= 1 then
		return string.format("%.2f%%", pct)
	elseif pct >= 0.01 then
		return string.format("%.3f%%", pct)
	end
	return string.format("%.4f%%", pct)
end

return CapsuleOdds
