--[[
	Persistence.spec (A5) — schema v1 defaults and migrations, setting sanitizing, best-time keys,
	and ProfileStore over the in-memory backend: session lock wait/takeover, stale locks, refusal
	to overwrite a newer session, bounded retries, honest failure states (Unsaved / Unavailable /
	ReadOnly), release on leave, and rejoin on the same server. Pure; offline and Studio.
]]

local Spec = {}

local function deepEqual(a, b)
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return a == b
	end
	for k, v in pairs(a) do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end
	return true
end

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
	local Schema, PS = m.PlayerDataSchema, m.ProfileStore

	-------------------------------------------------------------------- schema
	local d1, d2 = Schema.Defaults(), Schema.Defaults()
	check("defaults are deterministic", deepEqual(d1, d2))
	check("defaults carry every v1 field", d1.schemaVersion == 1 and d1.coins == 0 and d1.xp == 0 and d1.level == 1 and d1.raceCount == 0 and d1.winCount == 0 and d1.podiumCount == 0 and type(d1.bestTimes) == "table" and #d1.equippedAbilityIds == 2 and type(d1.settings) == "table" and type(d1.rewardLedger) == "table")
	local settingsOk = true
	for _, key in ipairs({ "reducedMotion", "cameraMode", "music", "sfx", "sensitivity", "graphicsMode" }) do
		if d1.settings[key] == nil then
			settingsOk = false
		end
	end
	check("settings: reducedMotion, cameraMode, music, sfx, sensitivity, graphicsMode", settingsOk)
	d1.coins = 99
	check("defaults are fresh tables (no shared state)", d2.coins == 0 and d1.settings ~= d2.settings)

	local fresh = Schema.Migrate(nil)
	check("missing profile -> defaults", deepEqual(fresh, Schema.Defaults()))
	check("garbage profile -> defaults", deepEqual((Schema.Migrate("corrupt")), Schema.Defaults()))
	local ledger = {}
	for i = 1, 40 do
		ledger[i] = "s:" .. i
	end
	local v0 = { coins = 50, xp = 500, loadout = { "Pulse", "Boost" }, settings = { music = 5, cameraMode = "Weird", reducedMotion = "true", sensitivity = 0.73 }, bestTimes = { ["a|1|0|Race"] = 71.5, bad = -3 }, rewardLedger = ledger }
	local migrated, changed = Schema.Migrate(v0)
	check("v0 -> v1: earned values kept, level derived from XP", migrated.schemaVersion == 1 and migrated.coins == 50 and migrated.xp == 500 and migrated.level == 2 and changed == true)
	check("v0 -> v1: flat loadout moved to equippedAbilityIds", migrated.equippedAbilityIds[1] == "Pulse" and migrated.equippedAbilityIds[2] == "Boost")
	check("v0 -> v1: settings sanitized (clamped, rounded, unknown enum -> default)", migrated.settings.music == 1 and migrated.settings.cameraMode == "Chase" and migrated.settings.reducedMotion == true and math.abs(migrated.settings.sensitivity - 0.7) < 1e-9)
	check("v0 -> v1: invalid best times dropped", migrated.bestTimes["a|1|0|Race"] == 71.5 and migrated.bestTimes.bad == nil)
	check("ledger trimmed to the newest 25 (bounded)", #migrated.rewardLedger == 25 and migrated.rewardLedger[25] == "s:40")
	local hostile = Schema.Migrate({ schemaVersion = 1, coins = -5, xp = 0 / 0, raceCount = math.huge, equippedAbilityIds = { "Boost", "Boost" } })
	check("negative / NaN / inf counters become 0; duplicate loadout rejected", hostile.coins == 0 and hostile.xp == 0 and hostile.raceCount == 0 and hostile.equippedAbilityIds[1] == "Boost" and hostile.equippedAbilityIds[2] == "Shield")
	local newer = { schemaVersion = 7, coins = 9999 }
	local same, ok = Schema.Migrate(newer)
	check("a NEWER schema is returned untouched and flagged not-ok", same == newer and ok == false)
	check("SanitizeSetting: unknown key -> nil", Schema.SanitizeSetting("adminMode", true) == nil)
	check("best-time keys separate hazard variations and layouts", Schema.BestTimeKey("NF", 2, 0, "Race") ~= Schema.BestTimeKey("NF", 2, 1, "Race") and Schema.BestTimeKey("NF", 2, 0, "Race") ~= Schema.BestTimeKey("NF", 1, 0, "Race"))

	-------------------------------------------------------------------- ProfileStore
	local clockNow = 1000
	local waits = 0
	local function store(backend, jobId, mock)
		return PS.new({ backend = backend, jobId = jobId, mock = mock, clock = function()
			return clockNow
		end, wait = function(s)
			waits = waits + 1
			clockNow = clockNow + (s or 0)
		end })
	end
	local backend = PS.MemoryBackend()
	local A = store(backend, "server-A", false)
	local pa = A:Load("u_1")
	check("load of a new player: Ready, defaults, lock written", pa.status == "Ready" and pa.data.coins == 0 and backend.records.u_1.meta.jobId == "server-A")
	pa.data.coins = 120
	PS.MarkDirty(pa)
	local saved = A:Save(pa, false)
	check("save writes through UpdateAsync and clears dirty", saved == true and backend.records.u_1.data.coins == 120 and pa.dirty == false)

	-- second server while A is alive: waits, then takes over; A can no longer write
	waits = 0
	local B = store(backend, "server-B", false)
	clockNow = clockNow + 5
	local pb = B:Load("u_1")
	check("second live session waits for the lock, then takes over", pb.status == "Ready" and waits >= 3 and pb.data.coins == 120 and backend.records.u_1.meta.jobId == "server-B")
	pa.data.coins = 999999
	PS.MarkDirty(pa)
	local okA, reasonA = A:Save(pa, false)
	check("the older session can never overwrite the newer one", okA == false and reasonA == "TakenOver" and pa.status == "TakenOver" and backend.records.u_1.data.coins == 120)
	check("a taken-over profile refuses further saves", (A:Save(pa, false)) == false)

	-- stale lock (crashed server) is taken immediately
	backend.records.u_2 = { data = Schema.Defaults(), meta = { jobId = "dead-server", lockedAt = clockNow - 10000 } }
	waits = 0
	local p2 = B:Load("u_2")
	check("stale lock from a crashed server is taken without waiting", p2.status == "Ready" and waits == 0)

	-- bounded save retries + honest failure state
	local p3 = B:Load("u_3")
	p3.data.coins = 40
	PS.MarkDirty(p3)
	backend.failNext = 3
	local callsBefore = backend.calls
	local ok3 = B:Save(p3, false)
	check("save failure: bounded retries (3), status Unsaved, data kept, never 'saved'", ok3 == false and backend.calls - callsBefore == 3 and p3.status == "Unsaved" and p3.dirty == true and p3.data.coins == 40)
	local ok3b = B:Save(p3, false)
	check("the next save after a failure succeeds and clears the warning", ok3b == true and p3.status == "Ready" and backend.records.u_3.data.coins == 40)

	-- load failure never writes defaults over real data
	backend.records.u_4 = { data = { schemaVersion = 1, coins = 777, xp = 0 }, meta = {} }
	backend.failNext = 50
	local writesBefore = backend.writes
	local p4 = B:Load("u_4")
	backend.failNext = 0
	check("load failure: Unavailable, plays on defaults in memory", p4.status == "Unavailable" and p4.data.coins == 0)
	check("an Unavailable profile is never saved (real data untouched)", (B:Save(p4, true)) == false and backend.writes == writesBefore and backend.records.u_4.data.coins == 777)

	-- newer schema: read only
	backend.records.u_5 = { data = { schemaVersion = 9, coins = 5 }, meta = {} }
	local p5 = B:Load("u_5")
	check("profile from a newer game version loads ReadOnly and is never written", p5.status == "ReadOnly" and (B:Save(p5, false)) == false and backend.records.u_5.data.schemaVersion == 9)

	-- leave + rejoin
	local okRelease = B:Save(pb, true)
	check("leaving releases the lock", okRelease and backend.records.u_1.meta.jobId == nil)
	waits = 0
	local C = store(backend, "server-C", false)
	local pc = C:Load("u_1")
	check("rejoin on another server after a clean leave: no wait, data intact", pc.status == "Ready" and waits == 0 and pc.data.coins == 120)
	waits = 0
	local again = C:Load("u_1")
	check("rejoin on the SAME server (own lock) acquires at once", again.status == "Ready" and waits == 0)

	-- mock mode label
	local mockStore = store(PS.MemoryBackend(), "studio", true)
	check("Studio mock profiles say Mock (UI never claims a real save)", mockStore:Load("u_9").status == "Mock")
	check("lock decision table", PS.LockDecision(nil, "a", 0, 60) == "Acquire" and PS.LockDecision({ jobId = "a" }, "a", 0, 60) == "Acquire" and PS.LockDecision({ jobId = "b", lockedAt = 0 }, "a", 30, 60) == "Busy" and PS.LockDecision({ jobId = "b", lockedAt = 0 }, "a", 61, 60) == "Steal")
	return results
end

return Spec
