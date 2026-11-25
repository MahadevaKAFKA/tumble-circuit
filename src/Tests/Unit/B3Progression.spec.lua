--[[
	B3Progression.spec — catalog (counts, stable ids, rarities), visual-only looks, inventory
	rules, level rewards, profile v3, quests (UTC resets, bot limit, single claims), leaderboard
	naming, garage filters, emote text.
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
	local C, Q, Schema = m.Catalog, m.QuestConfig, m.PlayerDataSchema
	------------------------------------------------------------------ catalog
	-- the master section 8 catalog; D adds a few clearly-marked exclusives (Founder pack,
	-- Season 1 premium lane) on top, counted separately
	local function base(kind)
		local out = {}
		for _, item in ipairs(C.ByKind[kind]) do
			if not item.Exclusive then
				out[#out + 1] = item
			end
		end
		return out
	end
	local byRarity = {}
	for _, item in ipairs(base("Marble")) do
		byRarity[item.Rarity] = (byRarity[item.Rarity] or 0) + 1
	end
	check("35 marbles: 12 Common / 10 Rare / 7 Epic / 4 Legendary / 2 Mythic", #base("Marble") == 35 and byRarity.Common == 12 and byRarity.Rare == 10 and byRarity.Epic == 7 and byRarity.Legendary == 4 and byRarity.Mythic == 2)
	check("12 trails, 8 finish bursts, 8 emotes", #base("Trail") == 12 and #base("Burst") == 8 and #base("Emote") == 8)
	local exclusives = 0
	for _, item in pairs(C.Items) do
		if item.Exclusive then
			exclusives = exclusives + 1
		end
	end
	check("D exclusives: 3 Founder + 3 Season 1 premium, nothing else", exclusives == 6)
	local idsOk = true
	for id, item in pairs(C.Items) do
		if not string.match(id, "^[a-z0-9_]+$") or item.Id ~= id or #id > 40 then
			idsOk = false
		end
	end
	check("ids are stable lowercase slugs (not display names), <= 40 chars", idsOk)
	local startersOk = true
	for _, id in ipairs(C.Starters) do
		startersOk = startersOk and C.Get(id) ~= nil
	end
	check("starters and defaults exist (Cobalt, Dust, Confetti, 3 emotes)", startersOk and C.Get(C.Defaults.marble).Kind == "Marble" and #C.Defaults.emotes == 3)
	local levelsOk, n = true, 0
	for level, id in pairs(C.LevelRewards) do
		n = n + 1
		levelsOk = levelsOk and level % 5 == 0 and C.Get(id) ~= nil
	end
	check("level rewards every 5 levels (5..50), all real items", levelsOk and n == 10)
	check("locked items say how they're earned (no buy button)", C.HowToEarn("carbon_weave") == "Level 10 reward" and string.find(C.HowToEarn("black_hole"), "capsule") ~= nil)
	check("capsule pools: every rarity has marbles", #C.MarblesOfRarity("Mythic") == 2 and #C.MarblesOfRarity("Common") == 12)

	------------------------------------------------------------------ looks are visual only
	local ML = m.MarbleLook
	local looksOk = true
	for _, item in ipairs(C.ByKind.Marble) do
		local ok, specs = pcall(ML.Specs, item.Look, 4)
		if not ok then
			looksOk = false
		else
			for _, spec in ipairs(specs) do
				if spec.size.X > 6 or spec.size.Y > 6 or spec.size.Z > 6 then
					looksOk = false
				end
			end
		end
	end
	check("every marble look builds; shells stay within 1.5x the ball", looksOk)
	if m.ReadFile then -- offline only: read the source
		local src = m.ReadFile("src/ReplicatedStorage/Shared/MarbleLook.lua")
		check("MarbleLook never writes Size / CustomPhysicalProperties / CanCollide on the ball", not string.find(src, "ball%.Size%s*=") and not string.find(src, "CustomPhysicalProperties") and not string.find(src, "ball%.CanCollide"))
	end

	------------------------------------------------------------------ inventory rules
	local CS = m.CosmeticService
	local c = Schema.DefaultCosmetics()
	check("equip a non-owned item refused", not CS.ApplyEquip(c, "Marble", "black_hole"))
	table.insert(c.owned, "black_hole")
	check("equip an owned marble", CS.ApplyEquip(c, "Marble", "black_hole") and c.equipped.marble == "black_hole")
	check("kind mismatch refused (a trail as a marble)", not CS.ApplyEquip(c, "Marble", "trail_dust"))
	table.insert(c.owned, "emote_wow")
	CS.ApplyEquip(c, "Emote", "emote_wow", 2)
	CS.ApplyEquip(c, "Emote", "emote_gg", 2)
	check("emote slots: choosing one already slotted swaps (never duplicates)", c.equipped.emotes[2] == "emote_gg" and c.equipped.emotes[1] == "emote_wow")
	check("emote slot must be 1-3", not CS.ApplyEquip(c, "Emote", "emote_gg", 0) and not CS.ApplyEquip(c, "Emote", "emote_gg", 4))
	local due = CS.DueLevelRewards({ 5 }, 17)
	check("level rewards due: 10 and 15 at level 17 when 5 was claimed", #due == 2 and due[1].level == 10 and due[2].level == 15)

	------------------------------------------------------------------ profile v3
	local migrated = Schema.Migrate({ schemaVersion = 2, coins = 40, ownedAbilityIds = { "Magnet" } })
	check("v2 -> v3: earned values kept, defaults added", migrated.schemaVersion == Schema.Version and migrated.coins == 40 and migrated.ownedAbilityIds[1] == "Magnet" and migrated.cosmetics.equipped.marble == "cobalt" and type(migrated.quests) == "table")
	local hostile = Schema.Migrate({ schemaVersion = 3, cosmetics = { owned = { "black_hole", "black_hole", "fake_item", 7 }, equipped = { marble = "chrono_singularity", trail = "black_hole", emotes = { "emote_gg", "emote_gg", "x" } }, favorites = { "nope", "cobalt" } }, levelRewardsClaimed = { 5, 5, 7, "x" } })
	local hc = hostile.cosmetics
	check("v3 sanitize: unknown / duplicate ids dropped, starters kept", #hc.owned == #C.Starters + 1)
	check("v3 sanitize: can't equip what you don't own or the wrong kind", hc.equipped.marble == "cobalt" and hc.equipped.trail == "trail_dust")
	check("v3 sanitize: no duplicate emotes", hc.equipped.emotes[1] ~= hc.equipped.emotes[2] and hc.equipped.emotes[2] ~= hc.equipped.emotes[3] and hc.equipped.emotes[1] ~= hc.equipped.emotes[3])
	check("v3 sanitize: favorites known only, claimed levels valid only", #hc.favorites == 1 and #hostile.levelRewardsClaimed == 1)

	------------------------------------------------------------------ quests
	local monday = 1764547200 -- 2025-12-01 00:00 UTC (a Monday)
	check("UTC week turns on Monday 00:00", Q.UtcWeek(monday) == Q.UtcWeek(monday - 1) + 1 and Q.UtcWeek(monday + 6 * 86400 + 86399) == Q.UtcWeek(monday))
	local d1, d2 = Q.DailyFor(20000), Q.DailyFor(20000)
	check("daily quests: 3 distinct, the same for everyone that day", #d1 == 3 and d1[1] == d2[1] and d1[2] == d2[2] and d1[1] ~= d1[2] and d1[2] ~= d1[3] and d1[1] ~= d1[3])
	local q = Q.Default()
	Q.Refresh(q, monday + 100)
	check("refresh: 3 daily + 4 weekly", #q.daily == 3 and #q.weekly == 4)
	for _ = 1, 20 do
		Q.Apply(q, "finish", 1, monday + 200, {})
	end
	local fin
	for i, e in ipairs(q.weekly) do
		if e.id == "w_finish15" then
			fin = i
		end
	end
	check("progress caps at the target", q.weekly[fin].progress == 15)
	local reward = Q.Claim(q, "Weekly", fin, monday + 300)
	local again = Q.Claim(q, "Weekly", fin, monday + 301)
	check("claim pays once (250 Coins + 400 XP), a second claim is refused", reward and reward.coins == 250 and reward.xp == 400 and again == nil)
	local q2 = Q.Default()
	Q.Refresh(q2, monday)
	local _, reason = Q.Claim(q2, "Weekly", 1, monday)
	check("unfinished quest can't be claimed", reason == "Not finished yet")
	Q.Apply(q2, "world", 1, monday, { worldId = "A" })
	Q.Apply(q2, "world", 1, monday, { worldId = "A" })
	Q.Apply(q2, "world", 1, monday, { worldId = "B" })
	local worlds
	for _, e in ipairs(q2.weekly) do
		if e.id == "w_worlds2" then
			worlds = e
		end
	end
	check("'2 different worlds' counts distinct worlds only", worlds.progress == 2)
	local q3 = Q.Default()
	for race = 1, 5 do
		Q.Apply(q3, "botstart", 0, monday, { botPractice = true, countsBotRace = true })
		Q.Apply(q3, "race", 1, monday, { botPractice = true })
	end
	local raced = 0
	for _, e in ipairs(q3.daily) do
		if Q.Def("Daily", e.id).event == "race" then
			raced = e.progress
		end
	end
	local hasRace = false
	for _, id in ipairs(Q.DailyFor(Q.UtcDay(monday))) do
		hasRace = hasRace or id == "d_race3"
	end
	check("bot practice: only the first 3 bot races a day count for quests", q3.botRaces == 5 and (not hasRace or raced == 3))
	local q4 = Q.Default()
	Q.Refresh(q4, monday)
	q4.daily[1].progress = 99
	Q.Refresh(q4, monday + 86400)
	check("new UTC day = fresh daily quests (no streak, nothing lost but the old day)", q4.daily[1].progress == 0 and q4.day == Q.UtcDay(monday + 86400))
	local sane = Q.Sanitize({ day = 5, daily = { { id = "d_race3", progress = 99, claimed = "yes" }, { id = "bogus" } }, weekly = "x" })
	check("stored quests sanitized (unknown dropped, progress capped)", #sane.daily == 1 and sane.daily[1].progress == 3 and sane.daily[1].claimed == false and #sane.weekly == 0)

	------------------------------------------------------------------ boards / garage / emotes
	local LB = m.LeaderboardService
	if LB then
		local name = LB.BestStoreName("VolcanoVault_B1", 1, 2)
		check("board names stable and short", name == "TCBest_VolcanoVault_B1_L1_S2" and #name <= 50 and LB.WinsStoreName(2900) == "TCWins_W2900")
		check("times stored as whole ms (ascending)", LB.ToMs(62.3456) == 62346 and LB.ToMs(0) == 1)
	end
	local HM = m.HubMenusPure
	if HM then
		local state = { owned = { cobalt = true, lime_pop = true }, favorites = { lime_pop = true } }
		check("garage filters: owned / favorites / rarity", #HM.FilterItems("Marble", "Owned", state) == 2 and #HM.FilterItems("Marble", "Favorites", state) == 1 and #HM.FilterItems("Marble", "Mythic", state) == 2 and #HM.FilterItems("Trail", "All", state) == 14)
		check("reset timer text", HM.Duration(90061) == "1d 1h" and HM.Duration(3720) == "1h 2m")
	end
	local SP = m.SocialPure
	if SP and SP.EmoteText then
		check("emote bubble uses the equipped catalog emote, falls back to the A6 slot", SP.EmoteText(1, "emote_wow").text == "Wow!" and SP.EmoteText(2, nil).text == "Nice Save!")
	end
	return results
end

return Spec
