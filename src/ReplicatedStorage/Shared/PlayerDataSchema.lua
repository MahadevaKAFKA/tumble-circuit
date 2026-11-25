--[[
	PlayerDataSchema (A5) — the ONE module that owns the profile shape and its migrations
	(master reference "A5 profile schema v1"). Pure; replicated so the client knows the setting
	ranges. The server never trusts a client-sent profile: settings arrive one key at a time and
	are sanitized here.

	v1 = {
	  schemaVersion = 1, coins, xp, level, raceCount, winCount, podiumCount,
	  bestTimes = { ["worldId|layoutVersion|hazardSeedClass|mode"] = seconds },
	  equippedAbilityIds = { "Boost", "Shield" },
	  settings = { reducedMotion, cameraMode, music, sfx, sensitivity, graphicsMode, muteEmotes (A6) },
	  rewardLedger = { raceId, ... }   bounded (newest last), duplicate-award protection
	  botPractice = { day = UTC day number, races = count }
	}
	v2 (B2) adds ownedAbilityIds = { id, ... } — abilities bought with earned Coins (level unlocks
	are derived from the level, starters are always owned); equippedAbilityIds may hold any of
	the twelve ids (the server checks ownership).
	v3 (B3) adds cosmetics = { owned = {id..}, equipped = { marble, trail, burst, emotes = {3} },
	favorites = {id..} }, levelRewardsClaimed = { level.. }, quests (QuestConfig shape).
]]

local ProgressionConfig = require(script.Parent:WaitForChild("ProgressionConfig"))
local Catalog = require(script.Parent:WaitForChild("Catalog"))
local QuestConfig = require(script.Parent:WaitForChild("QuestConfig"))

local PlayerDataSchema = {}

PlayerDataSchema.Version = 3
PlayerDataSchema.LedgerSize = 25 -- last N rewarded race ids kept (bounded, never grows)

PlayerDataSchema.Settings = {
	reducedMotion = { kind = "boolean", default = false },
	cameraMode = { kind = "enum", default = "Chase", values = { "Chase", "Wide" } },
	music = { kind = "number", default = 0.6, min = 0, max = 1, step = 0.1 },
	sfx = { kind = "number", default = 0.8, min = 0, max = 1, step = 0.1 },
	sensitivity = { kind = "number", default = 1.0, min = 0.5, max = 1.5, step = 0.1 },
	graphicsMode = { kind = "enum", default = "Auto", values = { "Auto", "Low", "High" } },
	muteEmotes = { kind = "boolean", default = false }, -- A6: hide other players' quick emotes
}
PlayerDataSchema.SettingOrder = { "reducedMotion", "cameraMode", "music", "sfx", "sensitivity", "graphicsMode", "muteEmotes" }

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
	return { owned = owned, equipped = { marble = d.marble, trail = d.trail, burst = d.burst, emotes = { d.emotes[1], d.emotes[2], d.emotes[3] } }, favorites = {} }
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
	for key, kind in pairs({ marble = "Marble", trail = "Trail", burst = "Burst" }) do
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
		settings = PlayerDataSchema.DefaultSettings(),
		rewardLedger = {},
		botPractice = { day = 0, races = 0 },
	}
end

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
	if type(raw.botPractice) == "table" then
		d.botPractice.day = count(raw.botPractice.day)
		d.botPractice.races = count(raw.botPractice.races)
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
