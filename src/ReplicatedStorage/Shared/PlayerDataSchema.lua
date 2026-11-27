--[[
	PlayerDataSchema (A5) — the ONE module that owns the profile shape and its migrations
	(master reference "A5 profile schema v1"). Pure; replicated so the client knows the setting
	ranges. The server never trusts a client-sent profile: settings arrive one key at a time and
	are sanitized here.

	v1 = {
	  schemaVersion = 1, coins, xp, level, raceCount, winCount, podiumCount,
	  bestTimes = { ["worldId|layoutVersion|hazardSeedClass|mode"] = seconds },
	  equippedAbilityIds = { "Boost", "Shield" },
	  settings = { reducedMotion, cameraMode, music, sfx, sensitivity, graphicsMode, muteEmotes (A6),
	               hudScale, panelOpacity, hudDensity, uiAccent, highContrast, controlLayout,
	               sceneryDetail, perfOverlay (UI overhaul) },
	  rewardLedger = { raceId, ... }   bounded (newest last), duplicate-award protection
	  botPractice = { day = UTC day number, races = count }
	}
	v2 (B2) adds ownedAbilityIds = { id, ... } — abilities bought with earned Coins (level unlocks
	are derived from the level, starters are always owned); equippedAbilityIds may hold any of
	the twelve ids (the server checks ownership).
	v3 (B3) adds cosmetics = { owned = {id..}, equipped = { marble, trail, burst, emotes = {3} },
	favorites = {id..} }, levelRewardsClaimed = { level.. }, quests (QuestConfig shape).
	v4 (C) adds shards (earned only), capsule = { epicMisses, legendaryMisses, history = { {id,
	tier, dup, shards, at}.. last 20 }, requests = { requestId.. last 20 } } and season
	(SeasonConfig shape).
	v5 (D) adds purchases = { journal = { purchaseId.. last 200 }, entitlements = { key = true },
	premiumClaimed = { "S1:10".. } } — the durable receipt journal (Roblox keeps no per-user
	history for developer products).
	v6 (2026-11-26 economy) adds capsule.pity = { [caseId] = { e, l } } (the Skin case keeps
	epicMisses / legendaryMisses, so nobody loses guarantee progress), quests.milestones
	(QuestConfig), cosmetics.equipped.launch, history entries' seen flag and the new settings.
	Coins, Shards, XP, items, records and purchases are carried over exactly as they were.
]]

local ProgressionConfig = require(script.Parent:WaitForChild("ProgressionConfig"))
local Catalog = require(script.Parent:WaitForChild("Catalog"))
local QuestConfig = require(script.Parent:WaitForChild("QuestConfig"))
local SeasonConfig = require(script.Parent:WaitForChild("SeasonConfig"))
local CapsuleOdds = require(script.Parent:WaitForChild("CapsuleOdds"))
local RankRules = require(script.Parent:WaitForChild("RankRules"))

local PlayerDataSchema = {}

PlayerDataSchema.Version = 7 -- v7 (2026-11-26 ranked/challenges): rank, challenges, mastery
-- v6 (2026-11-26 economy): capsule.pity per case, quests.milestones
PlayerDataSchema.LedgerSize = 25 -- last N rewarded race ids kept (bounded, never grows)

PlayerDataSchema.Settings = {
	reducedMotion = { kind = "boolean", default = false },
	cameraMode = { kind = "enum", default = "Chase", values = { "Chase", "Wide" } },
	music = { kind = "number", default = 0.6, min = 0, max = 1, step = 0.1 },
	sfx = { kind = "number", default = 0.8, min = 0, max = 1, step = 0.1 },
	sensitivity = { kind = "number", default = 1.0, min = 0.5, max = 1.5, step = 0.1 },
	graphicsMode = { kind = "enum", default = "Auto", values = { "Auto", "Low", "High" } },
	muteEmotes = { kind = "boolean", default = false }, -- A6: hide other players' quick emotes
	-- UI overhaul (2026-11-26): presentation-only preferences, same save path, same sanitizer.
	-- Keys stay <= 16 characters (RequestSettings limit). Old profiles get the defaults.
	hudScale = { kind = "number", default = 1.0, min = 0.85, max = 1.25, step = 0.05 },
	panelOpacity = { kind = "number", default = 0.95, min = 0.75, max = 1.0, step = 0.05 },
	hudDensity = { kind = "enum", default = "Standard", values = { "Standard", "Compact" } },
	uiAccent = { kind = "enum", default = "FollowMap", values = { "FollowMap", "Cyan", "Amber", "Violet", "Neutral" } },
	highContrast = { kind = "boolean", default = false },
	controlLayout = { kind = "enum", default = "Default", values = { "Default", "LeftHanded" } },
	sceneryDetail = { kind = "enum", default = "Standard", values = { "Standard", "Low", "High" } },
	perfOverlay = { kind = "boolean", default = false }, -- developer frame-time overlay (off for players)
	-- 2026-11-26 driving feel: race intro skip, whose speed trails you see, FOV kick + streaks
	introSkip = { kind = "boolean", default = false },
	trailVisibility = { kind = "enum", default = "All", values = { "All", "Mine", "Off" } },
	speedEffects = { kind = "boolean", default = true },
	-- the Garage's last filter chip (brief 2026-11-26: persistent filters); not a Settings row
	hudAlign = { kind = "enum", default = "Center", values = { "Center", "Left" } }, -- race strip position
	garageFilter = { kind = "enum", default = "All", values = { "All", "Owned", "Favorites", "Common", "Rare", "Epic", "Legendary", "Mythic" } },
}
PlayerDataSchema.SettingOrder = { "music", "sfx", "graphicsMode", "muteEmotes" }
-- the DRIVING tab (2026-11-26): camera, steering and motion feedback in one place
PlayerDataSchema.DrivingSettingOrder = { "cameraMode", "sensitivity", "controlLayout", "hudAlign", "reducedMotion", "speedEffects", "trailVisibility", "introSkip" }
-- the Settings view's second tab (UI overhaul); perfOverlay is listed only for developers
PlayerDataSchema.DisplaySettingOrder = { "hudScale", "panelOpacity", "hudDensity", "uiAccent", "highContrast", "sceneryDetail", "perfOverlay" }

PlayerDataSchema.StarterAbilities = { "Boost", "Shield", "Pulse" }
-- B2: every ability id a profile may reference (mirrors AbilityConfig.Order; a spec checks)
PlayerDataSchema.KnownAbilities = { "Boost", "Shield", "Pulse", "Magnet", "BounceBurst", "ReverseJet", "FrostWake", "GrappleSpark", "Anchor", "Phase", "GravityGlide", "Decoy" }
PlayerDataSchema.DefaultLoadout = { "Boost", "Shield" }

local function round(x, step)
	return math.floor(x / step + 0.5) * step
end

local function finiteNumber(v)
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- Sanitize one setting value (any type) -> valid value, or nil if the key is unknown.
function PlayerDataSchema.SanitizeSetting(key, value)
	local spec = PlayerDataSchema.Settings[key]
	if not spec then
		return nil
	end
	if spec.kind == "boolean" then
		if type(value) == "boolean" then
			return value
		elseif value == "true" then
			return true
		elseif value == "false" then
			return false
		end
		return spec.default
	elseif spec.kind == "enum" then
		for _, allowed in ipairs(spec.values) do
			if value == allowed then
				return value
			end
		end
		return spec.default
	end
	local n = tonumber(value)
	if not finiteNumber(n) then
		return spec.default
	end
	if n < spec.min then
		n = spec.min
	elseif n > spec.max then
		n = spec.max
	end
	return round(n, spec.step)
end

function PlayerDataSchema.DefaultSettings()
	local out = {}
	for key, spec in pairs(PlayerDataSchema.Settings) do
		out[key] = spec.default
	end
	return out
end

function PlayerDataSchema.DefaultCosmetics()
	local owned = {}
	for i, id in ipairs(Catalog.Starters) do
		owned[i] = id
	end
	local d = Catalog.Defaults
	return { owned = owned, equipped = { marble = d.marble, trail = d.trail, burst = d.burst, launch = d.launch, plate = d.plate, podium = d.podium, emotes = { d.emotes[1], d.emotes[2], d.emotes[3] } }, favorites = {} }
end

-- v3: sanitize the cosmetics table (known ids only; starters always owned; equipped must be
-- owned and of the right kind, else the default)
function PlayerDataSchema.SanitizeCosmetics(raw)
	local c = PlayerDataSchema.DefaultCosmetics()
	if type(raw) ~= "table" then
		return c
	end
	local set = {}
	for _, id in ipairs(c.owned) do
		set[id] = true
	end
	for _, id in ipairs(type(raw.owned) == "table" and raw.owned or {}) do
		if type(id) == "string" and Catalog.Get(id) and not set[id] then
			set[id] = true
			c.owned[#c.owned + 1] = id
		end
	end
	local eq = type(raw.equipped) == "table" and raw.equipped or {}
	for key, kind in pairs({ marble = "Marble", trail = "Trail", burst = "Burst", launch = "Launch", plate = "Plate", podium = "Podium" }) do
		if type(eq[key]) == "string" and set[eq[key]] and Catalog.IsKind(eq[key], kind) then
			c.equipped[key] = eq[key]
		end
	end
	if type(eq.emotes) == "table" then
		local seen = {}
		for i = 1, 3 do
			local id = eq.emotes[i]
			if type(id) == "string" and set[id] and Catalog.IsKind(id, "Emote") and not seen[id] then
				c.equipped.emotes[i] = id
			end
			seen[c.equipped.emotes[i]] = true
		end
		-- never the same emote twice: a duplicate default falls back to an unused owned emote
		local used = {}
		for i = 1, 3 do
			local id = c.equipped.emotes[i]
			if used[id] then
				for _, candidate in ipairs(c.owned) do
					if Catalog.IsKind(candidate, "Emote") and not used[candidate] then
						c.equipped.emotes[i] = candidate
						break
					end
				end
			end
			used[c.equipped.emotes[i]] = true
		end
	end
	local favSeen = {}
	for _, id in ipairs(type(raw.favorites) == "table" and raw.favorites or {}) do
		if type(id) == "string" and Catalog.Get(id) and not favSeen[id] and #c.favorites < 60 then
			favSeen[id] = true
			c.favorites[#c.favorites + 1] = id
		end
	end
	return c
end

function PlayerDataSchema.Defaults()
	return {
		schemaVersion = PlayerDataSchema.Version,
		coins = 0,
		xp = 0,
		level = 1,
		raceCount = 0,
		winCount = 0,
		podiumCount = 0,
		bestTimes = {},
		equippedAbilityIds = { PlayerDataSchema.DefaultLoadout[1], PlayerDataSchema.DefaultLoadout[2] },
		ownedAbilityIds = {}, -- v2: bought with earned Coins
		cosmetics = PlayerDataSchema.DefaultCosmetics(), -- v3
		levelRewardsClaimed = {}, -- v3: levels whose reward was granted
		quests = QuestConfig.Default(), -- v3
		shards = 0, -- v4: earned only (duplicates, season)
		capsule = { epicMisses = 0, legendaryMisses = 0, history = {}, requests = {}, pity = {} }, -- v4; v6 pity = { [caseId] = { e, l } } for every case but the Skin case
		season = SeasonConfig.Default(), -- v4
		purchases = { journal = {}, entitlements = {}, premiumClaimed = {} }, -- v5
		settings = PlayerDataSchema.DefaultSettings(),
		rewardLedger = {},
		botPractice = { day = 0, races = 0 },
		rank = RankRules.Default(), -- v7: opt-in Ranked test (skill only; separate from level)
		challenges = { best = {}, medals = {}, splits = {} }, -- v7: [challengeKey] (id|revision|ruleset)
		mastery = {}, -- v7: [goalId] = true (earned once; survives course revisions)
	}
end

-- v7 challenge / mastery sanitizing (keys are stable ids; values bounded)
local function sanitizeChallenges(raw)
	local out = { best = {}, medals = {}, splits = {} }
	if type(raw) ~= "table" then
		return out
	end
	local n = 0
	for key, seconds in pairs(type(raw.best) == "table" and raw.best or {}) do
		if type(key) == "string" and #key <= 80 and finiteNumber(seconds) and seconds > 0 and n < 60 then
			out.best[key] = seconds
			n = n + 1
		end
	end
	for key, medal in pairs(type(raw.medals) == "table" and raw.medals or {}) do
		if type(key) == "string" and #key <= 80 and (medal == "Gold" or medal == "Silver" or medal == "Bronze") then
			out.medals[key] = medal
		end
	end
	for key, list in pairs(type(raw.splits) == "table" and raw.splits or {}) do
		if type(key) == "string" and #key <= 80 and type(list) == "table" and #list <= 16 then
			local clean = {}
			for _, t in ipairs(list) do
				if finiteNumber(t) and t > 0 then
					clean[#clean + 1] = t
				end
			end
			out.splits[key] = clean
		end
	end
	return out
end
PlayerDataSchema.SanitizeChallenges = sanitizeChallenges

-- Stable personal-best key: different worlds, layouts, hazard variations or modes never compare.
function PlayerDataSchema.BestTimeKey(worldId, layoutVersion, hazardSeedClass, mode)
	return string.format("%s|%s|%s|%s", tostring(worldId), tostring(layoutVersion), tostring(hazardSeedClass), tostring(mode or "Race"))
end

local function count(v)
	if not finiteNumber(v) or v < 0 then
		return 0
	end
	return math.floor(math.min(v, 2 ^ 52))
end

function PlayerDataSchema.ValidLoadout(list)
	if type(list) ~= "table" or #list ~= 2 or list[1] == list[2] then
		return false
	end
	for _, id in ipairs(list) do
		local known = false
		for _, ability in ipairs(PlayerDataSchema.KnownAbilities) do
			if id == ability then
				known = true
			end
		end
		if not known then
			return false
		end
	end
	return true
end

--[[ Migrate anything (nil, garbage, v0 partial, v1) to a valid v1 table.
	 Returns data, changed (bool), note. Never lowers earned values that are valid. A profile from
	 a NEWER schema is returned untouched with ok=false so this server never overwrites it. ]]
function PlayerDataSchema.Migrate(raw)
	if type(raw) ~= "table" then
		return PlayerDataSchema.Defaults(), true, "new profile"
	end
	local version = tonumber(raw.schemaVersion) or 0
	if version > PlayerDataSchema.Version then
		return raw, false, "newer schema " .. tostring(version) .. " - read only"
	end
	local d = PlayerDataSchema.Defaults()
	d.coins = count(raw.coins)
	d.xp = count(raw.xp)
	d.raceCount = count(raw.raceCount)
	d.winCount = count(raw.winCount)
	d.podiumCount = count(raw.podiumCount)
	if type(raw.bestTimes) == "table" then
		for key, seconds in pairs(raw.bestTimes) do
			if type(key) == "string" and #key <= 80 and finiteNumber(seconds) and seconds > 0 then
				d.bestTimes[key] = seconds
			end
		end
	end
	-- v0 (A4 test builds) had a flat "loadout" field
	local loadout = raw.equippedAbilityIds or raw.loadout
	if PlayerDataSchema.ValidLoadout(loadout) then
		d.equippedAbilityIds = { loadout[1], loadout[2] }
	end
	if type(raw.settings) == "table" then
		for key in pairs(PlayerDataSchema.Settings) do
			if raw.settings[key] ~= nil then
				d.settings[key] = PlayerDataSchema.SanitizeSetting(key, raw.settings[key])
			end
		end
	end
	if type(raw.rewardLedger) == "table" then
		for _, id in ipairs(raw.rewardLedger) do
			if type(id) == "string" and #id <= 80 then
				d.rewardLedger[#d.rewardLedger + 1] = id
			end
		end
		while #d.rewardLedger > PlayerDataSchema.LedgerSize do
			table.remove(d.rewardLedger, 1)
		end
	end
	if type(raw.ownedAbilityIds) == "table" then
		local seen = {}
		for _, id in ipairs(raw.ownedAbilityIds) do
			for _, known in ipairs(PlayerDataSchema.KnownAbilities) do
				if id == known and not seen[id] then
					seen[id] = true
					d.ownedAbilityIds[#d.ownedAbilityIds + 1] = id
				end
			end
		end
	end
	d.cosmetics = PlayerDataSchema.SanitizeCosmetics(raw.cosmetics)
	if type(raw.levelRewardsClaimed) == "table" then
		local seen = {}
		for _, level in ipairs(raw.levelRewardsClaimed) do
			if type(level) == "number" and Catalog.LevelRewards[level] and not seen[level] then
				seen[level] = true
				d.levelRewardsClaimed[#d.levelRewardsClaimed + 1] = level
			end
		end
	end
	d.quests = QuestConfig.Sanitize(raw.quests)
	d.season = SeasonConfig.Sanitize(raw.season)
	if type(raw.purchases) == "table" then
		local p = raw.purchases
		for _, id in ipairs(type(p.journal) == "table" and p.journal or {}) do
			if type(id) == "string" and #id <= 80 and #d.purchases.journal < 200 then
				d.purchases.journal[#d.purchases.journal + 1] = id
			end
		end
		for key, v in pairs(type(p.entitlements) == "table" and p.entitlements or {}) do
			if type(key) == "string" and #key <= 40 and v == true then
				d.purchases.entitlements[key] = true
			end
		end
		for _, key in ipairs(type(p.premiumClaimed) == "table" and p.premiumClaimed or {}) do
			if type(key) == "string" and #key <= 20 then
				d.purchases.premiumClaimed[#d.purchases.premiumClaimed + 1] = key
			end
		end
	end
	if type(raw.shards) == "number" and raw.shards == raw.shards then
		d.shards = math.max(0, math.min(math.floor(raw.shards), 10000000))
	end
	if type(raw.capsule) == "table" then
		local c = raw.capsule
		local function misses(v, cap)
			return type(v) == "number" and v == v and math.max(0, math.min(math.floor(v), cap)) or 0
		end
		d.capsule.epicMisses = misses(c.epicMisses, CapsuleOdds.EpicPityAfter)
		d.capsule.legendaryMisses = misses(c.legendaryMisses, CapsuleOdds.LegendaryPityAfter)
		for boxId, p in pairs(type(c.pity) == "table" and c.pity or {}) do -- v6
			if CapsuleOdds.BoxById[boxId] and boxId ~= "Marble" and type(p) == "table" then
				d.capsule.pity[boxId] = { e = misses(p.e, CapsuleOdds.EpicPityAfter), l = misses(p.l, CapsuleOdds.LegendaryPityAfter) }
			end
		end
		for _, h in ipairs(type(c.history) == "table" and c.history or {}) do
			if type(h) == "table" and type(h.id) == "string" and Catalog.Get(h.id) and #d.capsule.history < CapsuleOdds.HistorySize then
				d.capsule.history[#d.capsule.history + 1] = { id = h.id, tier = Catalog.Get(h.id).Rarity, dup = h.dup == true, shards = type(h.shards) == "number" and math.max(0, math.floor(h.shards)) or 0, at = type(h.at) == "number" and h.at or 0, req = type(h.req) == "string" and #h.req <= 40 and h.req or nil, box = (type(h.box) == "string" and (CapsuleOdds.BoxById[h.box] or CapsuleOdds.LegacyNames[h.box])) and h.box or (CapsuleOdds.BoxById[Catalog.Get(h.id).Kind] and Catalog.Get(h.id).Kind or "Marble"), seen = h.seen ~= false }
			end
		end
		for _, r in ipairs(type(c.requests) == "table" and c.requests or {}) do
			if type(r) == "string" and #r <= 40 and #d.capsule.requests < CapsuleOdds.HistorySize then
				d.capsule.requests[#d.capsule.requests + 1] = r
			end
		end
	end
	if type(raw.botPractice) == "table" then
		d.botPractice.day = count(raw.botPractice.day)
		d.botPractice.races = count(raw.botPractice.races)
	end
	d.rank = RankRules.Sanitize(raw.rank) -- v7
	d.challenges = sanitizeChallenges(raw.challenges) -- v7
	if type(raw.mastery) == "table" then -- v7
		for id, done in pairs(raw.mastery) do
			if type(id) == "string" and #id <= 40 and done == true then
				d.mastery[id] = true
			end
		end
	end
	d.level = (ProgressionConfig.LevelForXp(d.xp)) -- level is always derived from XP (no double level-ups)
	return d, version ~= PlayerDataSchema.Version or raw.level ~= d.level, version < PlayerDataSchema.Version and ("migrated v" .. version .. " -> v" .. PlayerDataSchema.Version) or nil
end

function PlayerDataSchema.LedgerHas(data, raceId)
	for _, id in ipairs(data.rewardLedger) do
		if id == raceId then
			return true
		end
	end
	return false
end

function PlayerDataSchema.LedgerAdd(data, raceId)
	if PlayerDataSchema.LedgerHas(data, raceId) then
		return false
	end
	table.insert(data.rewardLedger, raceId)
	while #data.rewardLedger > PlayerDataSchema.LedgerSize do
		table.remove(data.rewardLedger, 1)
	end
	return true
end

function PlayerDataSchema.DeepCopy(t)
	if type(t) ~= "table" then
		return t
	end
	local out = {}
	for k, v in pairs(t) do
		out[k] = PlayerDataSchema.DeepCopy(v)
	end
	return out
end

return PlayerDataSchema
