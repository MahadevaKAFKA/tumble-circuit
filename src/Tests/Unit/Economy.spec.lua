--[[
	Economy.spec (owner brief 2026-11-26, section 5): Coins only from quests, durable and
	idempotent quest claims (retries, reset boundaries, milestones), the 1 / 7 / 30-day model,
	and that paid random cases stay off. Race-Coin and case maths live in RewardIdempotence /
	CCapsules specs.
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
	local QC, Schema, QS, EM, O = m.QuestConfig, m.PlayerDataSchema, m.QuestService, m.EconomyModel, m.CapsuleOdds
	if not QC then
		return results
	end
	local day0 = 20000 * 86400 + 3600 -- a Thursday, 01:00 UTC

	check("quest rewards: daily 100 Coins, weekly 400, nine one-time milestones (skill goals marked)", QC.Rewards.Daily.coins == 100 and QC.Rewards.Weekly.coins == 400 and #QC.Milestones == 9 and QC.Milestones[6].skill == true)
	-- complete a daily quest, claim twice (a retry / double tap)
	local d = Schema.Defaults()
	d.coins = 500 -- an existing balance stays exactly as it is
	local q = d.quests
	QC.Refresh(q, day0)
	local def = QC.Def("Daily", q.daily[1].id)
	QC.Apply(q, def.event, def.target, day0 + 10, {})
	local r1 = QC.Claim(q, "Daily", 1, day0 + 20)
	local r2, why2 = QC.Claim(q, "Daily", 1, day0 + 21)
	check("a daily claim pays once; the retry is refused ('Already claimed')", r1 and r1.coins == 100 and r2 == nil and why2 == "Already claimed")
	-- service path: claim flag + Coins in ONE mutation
	if QS then
		local data = Schema.Defaults()
		data.coins = 500
		QC.Refresh(data.quests, day0)
		local dd = QC.Def("Daily", data.quests.daily[2].id)
		QC.Apply(data.quests, dd.event, dd.target, day0 + 5, {})
		local profile = { data = data, status = "Loaded" }
		local fakeData = {
			Update = function(_, _, fn)
				fn(profile.data)
				return true
			end,
			GetProfile = function()
				return profile
			end,
			SaveSoon = function() end,
		}
		local sent = {}
		local remote = { FireClient = function(_, _, payload)
			sent[#sent + 1] = payload
		end }
		local service = QS.new({ data = fakeData, remotes = { ProgressionNotice = remote, QuestState = remote }, round = {}, track = {} })
		service.clock = function()
			return day0 + 30
		end
		local fakePlayer = setmetatable({ Parent = true }, { __index = function()
			return nil
		end })
		service:Claim(fakePlayer, "Daily", 2)
		service:Claim(fakePlayer, "Daily", 2) -- duplicate request
		check("QuestService: claim + Coins in one mutation, a duplicate request pays nothing", data.coins == 600 and data.quests.daily[2].claimed)
	end
	-- reset boundary: a finished but unclaimed daily is paid when the day rolls over
	local d2 = Schema.Defaults()
	local q2 = d2.quests
	QC.Refresh(q2, day0)
	local def2 = QC.Def("Daily", q2.daily[1].id)
	QC.Apply(q2, def2.event, def2.target, day0 + 100, {})
	local _, paid = QC.Refresh(q2, day0 + 86400) -- next UTC day
	check("reset boundary: a finished, unclaimed daily is auto-claimed at the rollover (never lost)", #paid == 1 and paid[1].reward.coins == 100 and q2.daily[1].progress == 0)
	local _, paidAgain = QC.Refresh(q2, day0 + 86400 + 5)
	check("...and only once", #paidAgain == 0)
	if QS then
		local before = d2.coins
		local c = QS.PayAuto(d2, paid)
		check("auto-claimed rewards are added in the same mutation", c == 100 and d2.coins == before + 100)
	end
	-- an unfinished quest at the boundary pays nothing
	local d3 = Schema.Defaults()
	QC.Refresh(d3.quests, day0)
	local _, none = QC.Refresh(d3.quests, day0 + 86400)
	check("an unfinished quest at the reset pays nothing", #none == 0)
	-- milestones: progress never resets, claim once
	local d4 = Schema.Defaults()
	local q4 = d4.quests
	QC.Refresh(q4, day0)
	for k = 1, 10 do
		QC.Apply(q4, "finish", 1, day0 + k * 86400, {}) -- ten races over ten days
	end
	local m1 = QC.Claim(q4, "Milestone", 1, day0 + 11 * 86400)
	local m1b = QC.Claim(q4, "Milestone", 1, day0 + 11 * 86400)
	local m2 = QC.Claim(q4, "Milestone", 2, day0 + 11 * 86400)
	check("milestones keep progress across days (Finish 10 races) and pay once each", m1 and m1.coins == 150 and m1b == nil and m2 and m2.coins == 300 and q4.milestones[2].progress == 10)
	QC.Apply(q4, "win", 1, day0 + 12 * 86400, {})
	check("skill milestone 'Win a race' counts wins only", q4.milestones[7].progress == 1 and q4.milestones[9].progress == 1)
	local saved = Schema.Migrate((function()
		local raw = Schema.Defaults()
		raw.quests = q4
		raw.schemaVersion = 6
		return raw
	end)())
	check("milestone progress and claims survive a save + reload", saved.quests.milestones[2].claimed == true and saved.quests.milestones[7].progress == 1)
	local old = Schema.Migrate({ schemaVersion = 5, coins = 4321, quests = { day = 5, daily = {}, weekly = {} } })
	check("v5 -> v6: Coins kept exactly; milestones start fresh", old.coins == 4321 and #old.quests.milestones == #QC.Milestones and old.quests.milestones[1].progress == 0)
	local hostile = QC.Sanitize({ milestones = { { id = "m_finish10", progress = 1e9, claimed = true }, { id = "nope", progress = 3 } } })
	check("milestone sanitize: progress capped at the target, unknown ids dropped", hostile.milestones[2].progress == 10 and hostile.milestones[2].claimed and #hostile.milestones == #QC.Milestones)

	-- the model
	if EM and O then
		local t = EM.Table()
		for _, name in ipairs({ "Active", "Casual" }) do
			for _, day in ipairs({ 1, 7, 30 }) do
				local row = t[name][day]
				results.info[#results.info + 1] = string.format("economy model %s day %d: %d Coins -> Starter %d / Skin %d / Trail %d / Apex %d", name, day, row.coins, row.cases.Starter, row.cases.Marble, row.cases.Trail, row.cases.Apex)
			end
		end
		check("day 1: an active player can open a basic case, not yet a high-tier one", t.Active[1].cases.Starter >= 1 and t.Active[1].cases.Apex == 0)
		check("30 days: a viable earned path to every tier (active: 10+ Apex, casual: 5+)", t.Active[30].cases.Apex >= 10 and t.Casual[30].cases.Apex >= 5)
		check("cases are materially less frequent than before (30-day Skin cases < 60% of the old Marble capsules)", t.Active[30].cases.Marble < 0.6 * math.floor(EM.CoinsBefore(30) / 600))
	end
	-- PolicyService gate (Paid Random Items): fails closed
	local PSvc = m.ProductService
	if PSvc and PSvc.PaidRandomAllowed then
		local f = PSvc.PaidRandomAllowed
		check("paid random gate: PolicyService error / missing field / restricted account -> no", f(false, nil, true) == false and f(true, {}, true) == false and f(true, { ArePaidRandomItemsRestricted = true }, true) == false)
		check("paid random gate: even an eligible account gets nothing while the build flag is off", f(true, { ArePaidRandomItemsRestricted = false }, false) == false and f(true, { ArePaidRandomItemsRestricted = false }, true) == true)
	end
	-- paid random stays off
	local ids = m.PlaceholderIds
	if ids then
		check("paid random cases stay OFF (no flag on, no product listed)", ids.ENABLE_PAID_CAPSULES == false and ids.Products.LaunchSpringSnap == nil and ids.Products.LaunchAfterimage == nil)
	end
	return results
end

return Spec
