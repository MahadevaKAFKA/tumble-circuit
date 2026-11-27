--[[
	Catalog (B3) — every cosmetic, with STABLE ids (never derived from display names; saved in
	profiles and later used by capsules). Master section 8: 35 marbles (Common 12 / Rare 10 /
	Epic 7 / Legendary 4 / Mythic 2), 12 trails, 8 finish bursts, 8 emotes.
	Everything here is visual only: a look recolours the BallRoot and adds massless,
	non-colliding welded shells (MarbleLook) — radius, mass, grip and collision never change.
	Original procedural looks from native materials; no external assets.

	How items are earned: starters (owned by everyone), level rewards every 5 levels, earned-Coin
	capsules and the Shard Shop. A few looks are optional direct purchases (ShopConfig); while
	their product id is nil they say "not on sale yet" and cannot be bought.
	2026-11-26: trails have a Profile (Ribbon / Thin / Wide / Twin): the shape of the speed
	trail and of the trail's masked silhouette in the capsule reveal. New kind "Launch": how
	your stand-in lands in the race-start ramp intro (same duration, slot and timing for all).
]]

local Catalog = {}

Catalog.Rarities = { "Common", "Rare", "Epic", "Legendary", "Mythic" }
Catalog.RarityColors = {
	Common = Color3.fromRGB(200, 210, 230),
	Rare = Color3.fromRGB(39, 215, 245),
	Epic = Color3.fromRGB(160, 120, 255),
	Legendary = Color3.fromRGB(255, 212, 90),
	Mythic = Color3.fromRGB(255, 107, 112),
}

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

-- look = { color, material, reflectance, pattern, accent, accent2, glow }
-- pattern: "Stripes" (2 rings), "Ring" (1 ring), "Speckle" (dots), "Halo" (outer ring), "Core"
-- (inner glow), "Bands" (3 rings), "Orbit" (tilted rings), "None"
local M = {
	-- Common (12)
	{ "cobalt", "Cobalt", "Common", { color = rgb(40, 90, 220), material = "SmoothPlastic", pattern = "Stripes", accent = rgb(255, 107, 112), accent2 = rgb(255, 212, 90) } },
	{ "lime_pop", "Lime Pop", "Common", { color = rgb(150, 230, 60), material = "SmoothPlastic", pattern = "Ring", accent = rgb(255, 255, 255) } },
	{ "tangerine", "Tangerine", "Common", { color = rgb(255, 140, 40), material = "SmoothPlastic", pattern = "Ring", accent = rgb(255, 230, 180) } },
	{ "chalk", "Chalk", "Common", { color = rgb(235, 235, 230), material = "Concrete", pattern = "None" } },
	{ "bubblegum", "Bubblegum", "Common", { color = rgb(255, 150, 200), material = "SmoothPlastic", pattern = "Stripes", accent = rgb(255, 255, 255), accent2 = rgb(255, 200, 230) } },
	{ "ocean", "Ocean", "Common", { color = rgb(20, 120, 170), material = "SmoothPlastic", pattern = "Bands", accent = rgb(120, 220, 255) } },
	{ "jade", "Jade", "Common", { color = rgb(40, 160, 110), material = "Marble", pattern = "None" } },
	{ "sunbeam", "Sunbeam", "Common", { color = rgb(255, 215, 70), material = "SmoothPlastic", pattern = "Ring", accent = rgb(255, 140, 40) } },
	{ "slate", "Slate", "Common", { color = rgb(90, 96, 110), material = "Slate", pattern = "None" } },
	{ "ruby_dot", "Ruby Dot", "Common", { color = rgb(240, 240, 240), material = "SmoothPlastic", pattern = "Speckle", accent = rgb(210, 30, 60) } },
	{ "lemon_drop", "Lemon Drop", "Common", { color = rgb(250, 240, 120), material = "SmoothPlastic", pattern = "Speckle", accent = rgb(255, 255, 255) } },
	{ "mist", "Mist", "Common", { color = rgb(200, 215, 230), material = "Glass", reflectance = 0.1, pattern = "None" } },
	-- Rare (10)
	{ "carbon_weave", "Carbon Weave", "Rare", { color = rgb(30, 32, 36), material = "DiamondPlate", pattern = "Ring", accent = rgb(39, 215, 245) } },
	{ "polished_copper", "Polished Copper", "Rare", { color = rgb(200, 110, 60), material = "Metal", reflectance = 0.35, pattern = "None" } },
	{ "galaxy_speckle", "Galaxy Speckle", "Rare", { color = rgb(25, 20, 60), material = "SmoothPlastic", pattern = "Speckle", accent = rgb(255, 255, 255) } },
	{ "aurora_stripe", "Aurora Stripe", "Rare", { color = rgb(20, 40, 80), material = "SmoothPlastic", pattern = "Bands", accent = rgb(110, 231, 186), glow = true } },
	{ "honeycomb", "Honeycomb", "Rare", { color = rgb(240, 170, 30), material = "Fabric", pattern = "Stripes", accent = rgb(120, 70, 10), accent2 = rgb(255, 220, 120) } },
	{ "circuit_blue", "Circuit Blue", "Rare", { color = rgb(16, 23, 45), material = "SmoothPlastic", pattern = "Orbit", accent = rgb(39, 215, 245), glow = true } },
	{ "circuit_pink", "Circuit Pink", "Rare", { color = rgb(16, 23, 45), material = "SmoothPlastic", pattern = "Orbit", accent = rgb(255, 107, 180), glow = true } },
	{ "pixel", "Pixel", "Rare", { color = rgb(80, 200, 120), material = "Pebble", pattern = "Speckle", accent = rgb(20, 60, 30) } },
	{ "icy_glass", "Icy Glass", "Rare", { color = rgb(190, 240, 255), material = "Glass", reflectance = 0.25, pattern = "Core", accent = rgb(120, 220, 255) } },
	{ "tiger_spin", "Tiger Spin", "Rare", { color = rgb(255, 150, 30), material = "SmoothPlastic", pattern = "Bands", accent = rgb(25, 20, 20) } },
	-- Epic (7)
	{ "starforge", "Starforge", "Epic", { color = rgb(60, 40, 20), material = "CrackedLava", pattern = "Core", accent = rgb(255, 180, 60), glow = true } },
	{ "neon_vortex", "Neon Vortex", "Epic", { color = rgb(10, 10, 30), material = "SmoothPlastic", pattern = "Orbit", accent = rgb(160, 120, 255), accent2 = rgb(39, 215, 245), glow = true } },
	{ "molten_core", "Molten Core", "Epic", { color = rgb(40, 20, 20), material = "CrackedLava", pattern = "Core", accent = rgb(255, 90, 30), glow = true } },
	{ "prismatic_prism", "Prismatic Prism", "Epic", { color = rgb(230, 230, 255), material = "Glass", reflectance = 0.3, pattern = "Bands", accent = rgb(255, 107, 112), accent2 = rgb(110, 231, 186), glow = true } },
	{ "quantum_chrome", "Quantum Chrome", "Epic", { color = rgb(200, 205, 215), material = "Foil", reflectance = 0.5, pattern = "Halo", accent = rgb(39, 215, 245) } },
	{ "storm_cloud", "Storm Cloud", "Epic", { color = rgb(80, 85, 100), material = "Granite", pattern = "Orbit", accent = rgb(255, 240, 120), glow = true } },
	{ "crystal_bloom", "Crystal Bloom", "Epic", { color = rgb(255, 180, 230), material = "Glass", reflectance = 0.2, pattern = "Core", accent = rgb(255, 255, 255), glow = true } },
	-- Legendary (4)
	{ "black_hole", "Black Hole", "Legendary", { color = rgb(5, 5, 10), material = "SmoothPlastic", pattern = "Halo", accent = rgb(160, 120, 255), accent2 = rgb(255, 255, 255), glow = true } },
	{ "phoenix_ember", "Phoenix Ember", "Legendary", { color = rgb(200, 50, 20), material = "Neon", pattern = "Orbit", accent = rgb(255, 212, 90), glow = true } },
	{ "solar_crown", "Solar Crown", "Legendary", { color = rgb(255, 200, 60), material = "Foil", reflectance = 0.4, pattern = "Halo", accent = rgb(255, 255, 220), glow = true } },
	{ "abyss_leviathan", "Abyss Leviathan", "Legendary", { color = rgb(10, 40, 60), material = "Glass", reflectance = 0.2, pattern = "Bands", accent = rgb(110, 231, 186), accent2 = rgb(39, 215, 245), glow = true } },
	-- Mythic (2)
	{ "celestial_ouroboros", "Celestial Ouroboros", "Mythic", { color = rgb(20, 10, 50), material = "Glass", reflectance = 0.3, pattern = "Orbit", accent = rgb(255, 212, 90), accent2 = rgb(255, 107, 112), glow = true } },
	{ "chrono_singularity", "Chrono Singularity", "Mythic", { color = rgb(240, 240, 255), material = "Foil", reflectance = 0.6, pattern = "Halo", accent = rgb(39, 215, 245), accent2 = rgb(160, 120, 255), glow = true } },
}

local T = {
	{ "dust", "Dust", "Common", { rgb(200, 190, 170), rgb(120, 110, 100) }, "Ribbon" },
	{ "comet", "Comet", "Common", { rgb(255, 255, 255), rgb(39, 215, 245) }, "Thin" },
	{ "neon_cyan", "Neon Cyan", "Common", { rgb(39, 215, 245), rgb(39, 215, 245) }, "Ribbon" },
	{ "neon_coral", "Neon Coral", "Common", { rgb(255, 107, 112), rgb(255, 107, 112) }, "Ribbon" },
	{ "bubble", "Bubble", "Rare", { rgb(200, 240, 255), rgb(255, 200, 240) }, "Wide" },
	{ "smoke", "Smoke", "Rare", { rgb(120, 125, 135), rgb(40, 42, 50) }, "Wide" },
	{ "frost", "Frost", "Rare", { rgb(220, 250, 255), rgb(120, 200, 255) }, "Thin" },
	{ "ember", "Ember", "Epic", { rgb(255, 212, 90), rgb(255, 60, 30) }, "Twin" },
	{ "sparkle", "Sparkle", "Epic", { rgb(255, 255, 255), rgb(255, 212, 90) }, "Thin" },
	{ "rainbow", "Rainbow", "Legendary", { rgb(255, 107, 112), rgb(110, 231, 186) }, "Wide" },
	{ "starlight", "Starlight", "Legendary", { rgb(255, 255, 220), rgb(160, 120, 255) }, "Twin" },
	{ "aurora", "Aurora", "Mythic", { rgb(110, 231, 186), rgb(160, 120, 255) }, "Twin" },
}
Catalog.TrailProfiles = { "Ribbon", "Thin", "Wide", "Twin" }

-- Launch animations (2026-11-26). Look only: every style takes the same time to the same slot.
local LA = {
	{ "ramp", "Ramp Launch", "Common", "The default jump with a landing ring." },
	{ "comet", "Comet Arc", "Rare", "A low, fast arc behind a narrow ember streak; sticks the landing." },
	{ "spring", "Spring Snap", "Epic", "A high arc and an elastic rebound on the slot." },
	{ "afterimage", "Afterimage Drop", "Epic", "Two translucent echoes follow your marble down." },
}

local B = {
	{ "confetti", "Confetti", "Common" },
	{ "stars", "Stars", "Common" },
	{ "bubbles", "Bubbles", "Rare" },
	{ "sparks", "Sparks", "Rare" },
	{ "snowflakes", "Snowflakes", "Epic" },
	{ "fireworks", "Fireworks", "Epic" },
	{ "lightning", "Lightning", "Legendary" },
	{ "supernova", "Supernova", "Mythic" },
}

-- Preset text only (never free text): no chat filtering needed, nothing to abuse.
local E = {
	{ "gg", "GG", "Common", "★" },
	{ "nice_save", "Nice Save!", "Common", "✦" },
	{ "oops", "Oops!", "Common", "!" },
	{ "wow", "Wow!", "Common", "!" },
	{ "so_close", "So close!", "Rare", "~" },
	{ "lets_go", "Let's go!", "Rare", ">" },
	{ "rematch", "Rematch?", "Epic", "?" },
	{ "good_luck", "Good luck!", "Epic", "+" },
}

Catalog.Items = {} -- [id] = item
-- 2026-11-27 shop brief: "Plate" = your results nameplate (driver identity), "Podium" = the
-- effect that frames you on the podium when you win (celebrations). Kind names stay <= 8 chars
-- (RequestEquipCosmetic validates the kind as a short string).
Catalog.ByKind = { Marble = {}, Trail = {}, Burst = {}, Emote = {}, Launch = {}, Plate = {}, Podium = {} }
Catalog.Kinds = { "Marble", "Trail", "Burst", "Emote", "Launch", "Plate", "Podium" }
local function add(kind, id, name, rarity, extra)
	assert(Catalog.Items[id] == nil, "duplicate catalog id " .. id)
	local item = { Id = id, Kind = kind, Name = name, Rarity = rarity }
	for k, v in pairs(extra or {}) do
		item[k] = v
	end
	Catalog.Items[id] = item
	table.insert(Catalog.ByKind[kind], item)
	return item
end
for _, m in ipairs(M) do
	add("Marble", m[1], m[2], m[3], { Look = m[4] })
end
for _, t in ipairs(T) do
	add("Trail", "trail_" .. t[1], t[2], t[3], { Colors = t[4], Profile = t[5] })
end
for _, b in ipairs(B) do
	add("Burst", "burst_" .. b[1], b[2], b[3])
end
for _, e in ipairs(E) do
	add("Emote", "emote_" .. e[1], e[2], e[3], { Icon = e[4] })
end
for _, l in ipairs(LA) do
	add("Launch", "launch_" .. l[1], l[2], l[3], { Blurb = l[4] })
end
-- Spring Snap and Afterimage Drop: optional direct purchases (ShopConfig), never random
Catalog.Items.launch_spring.Exclusive = "Shop"
Catalog.Items.launch_afterimage.Exclusive = "Shop"

-- 2026-11-27 shop brief: the launch catalog (guaranteed, permanent offers in ShopConfig;
-- never random, never in cases or the Shard Shop). Visual only like everything else.
add("Marble", "reactor_glass", "Reactor Glass", "Epic", { Look = { color = rgb(18, 34, 92), material = "Glass", reflectance = 0.22, pattern = "Core", accent = rgb(255, 170, 40), glow = true }, Exclusive = "Shop" })
add("Trail", "trail_afterburn", "Afterburn Ribbon", "Epic", { Colors = { rgb(255, 150, 40), rgb(255, 80, 20) }, Profile = "Twin", Exclusive = "Shop" })
-- results nameplates: the free standard plate + Gridline (a checkered corner accent). Earned
-- looks (rank tiers, Cup placements, mastery) are reserved and never sold; paid plates carry no
-- rank icons.
add("Plate", "plate_standard", "Standard Plate", "Common", { Accent = "None", Exclusive = "Starter" })
add("Plate", "plate_gridline", "Gridline", "Rare", { Accent = "Checkered", Exclusive = "Shop" })
-- podium effects: none by default; Victory Pulse = a brief gold ring around the winning marble
add("Podium", "podium_standard", "No podium effect", "Common", { Effect = "None", Exclusive = "Starter" })
add("Podium", "podium_victory_pulse", "Victory Pulse", "Epic", { Effect = "GoldRing", Exclusive = "Shop" })

-- D: Founder's Style Pack exclusives (a permanent Game Pass). Never in capsules, the Shard
-- Shop, level rewards or the season; visual only like everything else.
add("Trail", "trail_founder_gold", "Founder Gold", "Legendary", { Colors = { rgb(255, 230, 150), rgb(255, 170, 40) }, Profile = "Twin", Exclusive = "Founder" })
-- 2026-11-26 challenges brief: map mastery reward (earned once; never sold, never in a case)
add("Trail", "trail_foundry_exhaust", "Foundry Exhaust", "Epic", { Colors = { rgb(255, 150, 60), rgb(90, 110, 160) }, Profile = "Wide", Exclusive = "Mastery" })
add("Emote", "emote_founder_wave", "Founder wave!", "Legendary", { Icon = "*", Exclusive = "Founder" })
add("Emote", "emote_founder_salute", "Salute!", "Legendary", { Icon = "^", Exclusive = "Founder" })
-- D: Season 1 premium lane (season-keyed purchase; only claimable during Season 1)
add("Marble", "s1_launch_comet", "Launch Comet", "Epic", { Look = { color = rgb(20, 30, 70), material = "SmoothPlastic", pattern = "Orbit", accent = rgb(255, 212, 90), accent2 = rgb(39, 215, 245), glow = true }, Exclusive = "SeasonPremium:S1" })
add("Trail", "trail_s1_launch", "Launch Streak", "Epic", { Colors = { rgb(39, 215, 245), rgb(255, 212, 90) }, Profile = "Thin", Exclusive = "SeasonPremium:S1" })
add("Burst", "burst_s1_launch", "Launch Burst", "Epic", { Exclusive = "SeasonPremium:S1" })

Catalog.Defaults = {
	marble = "cobalt",
	trail = "trail_dust",
	burst = "burst_confetti",
	emotes = { "emote_gg", "emote_nice_save", "emote_oops" },
	launch = "launch_ramp",
	plate = "plate_standard", -- 2026-11-27
	podium = "podium_standard",
}
-- Owned by everyone from the start
Catalog.Starters = { "cobalt", "trail_dust", "burst_confetti", "emote_gg", "emote_nice_save", "emote_oops", "launch_ramp", "plate_standard", "podium_standard" }

-- Level rewards: every 5 levels (master section 9). Claimed once, server-side.
Catalog.LevelRewards = {
	[5] = "trail_comet",
	[10] = "carbon_weave",
	[15] = "emote_wow",
	[20] = "burst_stars",
	[25] = "aurora_stripe",
	[30] = "emote_lets_go",
	[35] = "trail_starlight",
	[40] = "neon_vortex",
	[45] = "burst_fireworks",
	[50] = "solar_crown",
}

-- How a not-yet-owned item is earned (shown in the garage; never a buy button)
function Catalog.HowToEarn(id)
	local item = Catalog.Items[id]
	if item and item.Exclusive == "Mastery" then
		return "Neon Foundry mastery: Clean Circuit + Fast Sector + Signature Line"
	elseif item and item.Exclusive == "Founder" then
		return "Founder's Style Pack (optional, in SHOP when on sale)"
	elseif item and item.Exclusive == "Shop" then
		return "Direct purchase in SHOP (optional; not on sale yet)"
	elseif item and item.Exclusive == "Starter" then
		return "Owned by everyone"
	elseif item and item.Exclusive then
		return "Season 1 premium lane (optional, in SHOP when on sale)"
	end
	for level, rewardId in pairs(Catalog.LevelRewards) do
		if rewardId == id then
			return string.format("Level %d reward", level)
		end
	end
	if item and item.Kind == "Launch" then
		return "Shard Shop (Shards come from duplicates and the season)"
	end
	return "Coin capsules in the CAPSULE LAB, or pick it in the Shard Shop"
end

-- profile.cosmetics.equipped key for each kind (emotes are a 3-slot list)
Catalog.EquipKey = { Marble = "marble", Trail = "trail", Burst = "burst", Emote = "emotes", Launch = "launch", Plate = "plate", Podium = "podium" }

function Catalog.Get(id)
	return Catalog.Items[id]
end

function Catalog.IsKind(id, kind)
	local item = Catalog.Items[id]
	return item ~= nil and item.Kind == kind
end

-- Items of one kind and rarity, in catalog order, never exclusives (capsule pools)
function Catalog.ItemsOfRarity(kind, rarity)
	local out = {}
	for _, item in ipairs(Catalog.ByKind[kind] or {}) do
		if item.Rarity == rarity and not item.Exclusive then
			out[#out + 1] = item.Id
		end
	end
	return out
end

-- Marbles of one rarity, in catalog order (capsules pick uniformly among these in Phase C)
function Catalog.MarblesOfRarity(rarity)
	return Catalog.ItemsOfRarity("Marble", rarity)
end

return Catalog
