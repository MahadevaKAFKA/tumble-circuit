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
	Item: uniform among every catalog marble of the drawn tier (owned ones included: a duplicate
	becomes Shards). Item odds = tier odds / items in that tier.
	Counters after an open: an Epic+ result resets epicMisses, otherwise +1; a Legendary+ result
	resets legendaryMisses, otherwise +1.
]]

local CapsuleOdds = {}

CapsuleOdds.Version = 1
CapsuleOdds.Cost = 600 -- earned Coins only
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

-- Per-item odds for the given pools ({ [tier] = {ids...} }); returns list { id, tier, p }
function CapsuleOdds.ItemOdds(pools, epicMisses, legendaryMisses)
	local tiers = CapsuleOdds.TierTable(epicMisses, legendaryMisses)
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
	local tiers, branch = CapsuleOdds.TierTable(epicMisses, legendaryMisses)
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
