--[[
	Challenges.spec (challenges/cups/creator brief, 2026-11-26) — the Drop Shaft loop offline:
	config (keys, medals, codes, weekly windows, mastery), the authored course, and a full
	ChallengeService attempt against mock services: countdown -> GO -> server-judged gates ->
	finish -> best / medal / splits / ghost saved; a fall fails the attempt and RETRY restarts on
	the start; slower and too-fast times never replace a best; mastery grants its reward once;
	friend ghosts only when explicitly shared on the same challenge version. Plus the client's
	pure text / framing helpers. Nothing here ran in a Roblox runtime.
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
	local CC, TD, CS = m.ChallengeConfig, m.TrackDefinitions, m.ChallengeService
	if not CC or not TD then
		check("ChallengeConfig + TrackDefinitions load", false)
		return results
	end
	local c = CC.ById.drop_shaft

	-- config -------------------------------------------------------------------------------
	local key = CC.Key(c)
	local bumped = {}
	for k, v in pairs(c) do
		bumped[k] = v
	end
	bumped.Revision = c.Revision + 1
	check("a challenge key carries id, revision, ruleset and scoring (a revision never mixes times)", key:find("drop_shaft", 1, true) and key:find("R1", 1, true) and CC.Key(bumped) ~= key, key)
	check("medals: 21.00 is gold, 21.01 silver, 28.00 bronze, 28.01 none",
		CC.Medal(c, 20.5) == "Gold" and CC.Medal(c, 21.0) == "Gold" and CC.Medal(c, 21.01) == "Silver" and CC.Medal(c, 28.0) == "Bronze" and CC.Medal(c, 28.01) == nil and CC.Medal(c, -1) == nil)
	check("codes resolve case-insensitively against the allowlist only", CC.Resolve("drop1") == c and CC.Resolve(" DROP1 ") == c and CC.Resolve("NOPE") == nil and CC.Resolve(string.rep("A", 40)) == nil and CC.Resolve(42) == nil)
	local w0, s0, e0 = CC.Week(CC.WeekEpoch)
	local w1 = CC.Week(CC.WeekEpoch + 7 * 86400)
	local wLast = CC.Week(CC.WeekEpoch + 7 * 86400 - 1)
	local weekly = CC.Weekly(CC.WeekEpoch + 3 * 86400)
	check("weekly windows are UTC weeks from the epoch; the rotation starts with the Drop Shaft", w0 == 0 and wLast == 0 and w1 == 1 and e0 - s0 == 7 * 86400 and weekly == c)
	check("the share line names the challenge, the time and the code", CC.ResultLine(c, 24.81):find("24.81 s", 1, true) and CC.ResultLine(c, 24.81):find("DROP1", 1, true))
	local done, total = CC.MasteryProgress("NeonFoundry_A4", { nf_clean = true })
	check("Neon Foundry mastery: 3 goals (clean circuit, fast sector, signature line) -> the Foundry exhaust trail", total == 3 and done == 1 and CC.Mastery.NeonFoundry_A4.Reward == "trail_foundry_exhaust" and (not m.Catalog or m.Catalog.Get("trail_foundry_exhaust") ~= nil))

	-- the authored course ------------------------------------------------------------------
	local radius = m.PhysicsConfig and m.PhysicsConfig.Ball.Radius or 2
	local okLayout, layout = pcall(TD.Generate, TD.DropShaftChallenge, radius)
	local errors = okLayout and TD.Validate(TD.DropShaftChallenge, layout) or { tostring(layout) }
	check("the Drop Shaft course generates and validates", okLayout and #errors == 0, table.concat(errors, "; "))
	if not okLayout or not CS then
		return results
	end
	local qualifyingS = layout.Resolve(TD.DropShaftChallenge.QualifyingLine).S
	check("a single run (not a loop): 3 gates then the finish; the qualifying line sits between the lip and the landing gate",
		not layout.Loop and #layout.Checkpoints == 3 and #layout.Targets == 4 and layout.Targets[4].Kind == "Finish" and qualifyingS > layout.Checkpoints[1].S and qualifyingS < layout.Checkpoints[2].S)
	table.insert(results.info, string.format("Drop Shaft: %.0f studs start->finish, qualifying line at S %.0f", layout.FinishLineS - layout.StartLineS, qualifyingS))

	-- pure service helpers -------------------------------------------------------------------
	check("split delta: negative = ahead of your best; nil without a best", CS.SplitDelta({ 5, 10 }, 2, 9.5) == -0.5 and CS.SplitDelta(nil, 1, 3) == nil)
	check("signature line: the first landing must reach the qualifying line", CS.SignatureLanded(qualifyingS + 1, qualifyingS) and not CS.SignatureLanded(qualifyingS - 1, qualifyingS) and not CS.SignatureLanded(nil, qualifyingS))

	-- a full attempt against mocks ------------------------------------------------------------
	local clock = 1000
	local savedWorkspace, savedTask = rawget(_G, "workspace"), task
	_G.workspace = { GetServerTimeNow = function()
		return clock
	end }
	local delayed = {}
	_G.task = { spawn = function(f, ...)
		return f(...)
	end, delay = function(_, f)
		delayed[#delayed + 1] = f
	end, cancel = function() end }
	local function flush()
		local list = delayed
		delayed = {}
		for _, f in ipairs(list) do
			f()
		end
	end

	local okFlow, flowErr = pcall(function()
		local function newPlayer(id)
			local p = { UserId = id, DisplayName = "P" .. id, Parent = true, friends = {} }
			function p:IsFriendsWith(other)
				return self.friends[other] == true
			end
			return p
		end
		local A, B = newPlayer(101), newPlayer(202)
		local everyone = { A, B }
		if m.ChallengePlayers then
			m.ChallengePlayers.GetPlayers = function()
				return everyone
			end
		end
		local sent = {}
		local remote = { FireClient = function(_, player, payload)
			sent[#sent + 1] = { player = player, p = payload }
		end }
		local remotes = { FindFirstChild = function()
			return remote
		end }
		local profiles = {
			[A] = { data = { challenges = { best = {}, medals = {}, splits = {} }, mastery = {} } },
			[B] = { data = { challenges = { best = {}, medals = {}, splits = {} }, mastery = {} } },
		}
		local data = {
			GetProfile = function(_, p)
				return profiles[p]
			end,
			Update = function(_, p, fn)
				fn(profiles[p].data)
				return true
			end,
			SaveSoon = function() end,
			GetMode = function()
				return "Mock"
			end,
		}
		local grants = {}
		local cosmetics = { Grant = function(_, p, id)
			grants[#grants + 1] = { p = p, id = id }
			return true
		end }
		local svc
		local spawns = {}
		local marbles = {
			SpawnMarble = function(_, p, reason)
				local spot = svc:ResolveSpawn(p, reason)
				spawns[#spawns + 1] = { p = p, reason = reason, spot = spot }
				return spot
			end,
			Release = function(self, p)
				return self:SpawnMarble(p, "Go") ~= nil
			end,
			GetZone = function()
				return "Race"
			end,
		}
		local track = {
			GetChallenge = function(_, id)
				return id == "drop_shaft" and { layout = layout } or nil
			end,
			FrameCFrame = function(_, frame)
				return frame.Position
			end,
		}
		local joined = {}
		local round = { racerByPlayer = {}, GetState = function()
			return "Lobby"
		end, TryJoin = function(_, p, wants)
			joined[p] = wants
		end }
		svc = CS.new({ track = track, marbles = marbles, physics = {}, round = round, remotes = remotes, data = data, cosmetics = cosmetics })
		local function last(player, phase)
			for i = #sent, 1, -1 do
				if sent[i].player == player and (phase == nil or sent[i].p.phase == phase) then
					return sent[i].p
				end
			end
		end
		-- drive a run at `speed` studs/s; airborne over [airFrom, airTo] (race S)
		local function drive(player, speed, airFrom, airTo, stopAtS)
			local run = svc.runs[player]
			local t, s = 0, run.startS
			local prevS, prevTime = nil, nil
			local finishS = layout.FinishLineS
			while s < finishS + 10 and t < 80 do
				local now = run.startClock + t
				local h = (airFrom and s >= airFrom and s < airTo) and 3 or 0
				svc:_onProgress(player, { zone = "Race", hubId = "drop_shaft", s = s, prevS = prevS, time = now, prevTime = prevTime, distance = 0, halfWidth = 13, position = Vector3.new(0, 0, s), frozen = false, height = h })
				if svc.runs[player] ~= run or run.phase ~= "Running" or (stopAtS and s >= stopAtS) then
					break
				end
				prevS, prevTime = s, now
				t = t + 0.1
				s = s + speed * 0.1
			end
			return run
		end

		-- 1) start: frozen on the start, out of the next race, 3 s countdown, ghost note
		svc:_request(A, "drop_shaft", "start")
		local cd = last(A, "Countdown")
		local spot = spawns[#spawns].spot
		check("TRY: placed frozen on the challenge start (tagged with the challenge id) and sat out of the next race",
			cd and cd.total == 3 and spot and spot.Frozen and spot.Hub == "drop_shaft" and spot.Ghost and joined[A] == false)
		check("no ghost yet: the attempt says so plainly (and that no friend has shared one)", last(A, "Ghost") and last(A, "Ghost").ghost == nil and last(A, "Ghost").note ~= nil and last(A, "Ghost").friendNote ~= nil)
		flush()
		check("GO: the attempt runs and the marble is released (free on the start)", svc.runs[A].phase == "Running" and last(A, "Running") ~= nil and spawns[#spawns].reason == "Go" and spawns[#spawns].spot.Frozen == false)

		-- 2) a fall mid-run fails the attempt; the marble waits on the start for RETRY
		drive(A, 45, nil, nil, layout.Checkpoints[1].S + 30)
		local splitsSeen = last(A, "Split")
		marbles:SpawnMarble(A, "Fell")
		check("a fall ends the attempt cleanly: Failed + frozen back on the start, no time saved",
			svc.runs[A].phase == "Failed" and last(A, "Failed") and spawns[#spawns].spot.Frozen and profiles[A].data.challenges.best[key] == nil and splitsSeen ~= nil and splitsSeen.delta == nil)
		svc:_request(A, "drop_shaft", "retry")
		local retry = last(A, "Countdown")
		check("RETRY is one action: a 2 s countdown on the start, attempt 2", retry.attempt == 2 and math.abs((retry.goAt - clock) - CS.RetryCountdownSeconds) < 1e-6)
		flush()

		-- 3) a clean gold run with the precision entry: best, medal, splits, ghost, mastery x2
		local lipS = layout.Checkpoints[1].S
		drive(A, 50, lipS + 4, qualifyingS + 6)
		local fin = last(A, "Finished")
		check("a valid finish saves best + gold medal + splits under the challenge key",
			fin and fin.pb and fin.medal == "Gold" and profiles[A].data.challenges.best[key] == fin.seconds and profiles[A].data.challenges.medals[key] == "Gold" and #profiles[A].data.challenges.splits[key] == 3, fin and fin.seconds)
		check("the result card carries the share line and the code", fin and fin.line:find("DROP1", 1, true) ~= nil)
		check("mastery: Fast Sector (gold) and Signature Line (landed past the qualifying line) - no reward yet (2/3)",
			profiles[A].data.mastery.nf_fast and profiles[A].data.mastery.nf_signature and not profiles[A].data.mastery.nf_clean and #grants == 0 and fin.signature)
		check("the PB ghost is kept (server samples of the valid run)", m.TimeTrialRules.ValidGhost(svc.memoryGhosts["101|" .. key], key))
		table.insert(results.info, string.format("mock gold run: %.2f s", fin and fin.seconds or -1))

		-- 4) a slower finish keeps the best; a short landing does not earn the signature line
		local before = profiles[A].data.challenges.best[key]
		svc:_request(A, "drop_shaft", "retry")
		flush()
		drive(A, 38, lipS + 4, lipS + 12)
		local slow = last(A, "Finished")
		check("a slower finish never replaces the best or downgrades the medal", slow and not slow.pb and profiles[A].data.challenges.best[key] == before and profiles[A].data.challenges.medals[key] == "Gold" and not slow.signature, slow and slow.seconds)
		check("split deltas compare against the saved best (positive = behind)", last(A, "Split") and type(last(A, "Split").delta) == "number" and last(A, "Split").delta > 0)

		-- 5) the third goal grants the reward exactly once
		check("Clean Circuit goals map to their circuits", CS.CleanCircuitGoal("NeonFoundry_A4") == "nf_clean" and CS.CleanCircuitGoal("VolcanoVault_B1") == "vv_clean" and CS.CleanCircuitGoal("nope") == nil)
		svc:OnCleanCircuit(A, "NeonFoundry_A4") -- RoundService: three laps, no reset, no fall
		svc:OnCleanCircuit(A, "NeonFoundry_A4")
		svc:GrantMastery(A, "nf_clean")
		check("all three Foundry goals grant the Foundry exhaust trail once", #grants == 1 and grants[1].id == "trail_foundry_exhaust" and last(A, "Mastery") ~= nil)

		-- 6) friend ghost: only when shared, only for friends, only the same version
		B.friends[A.UserId] = true
		A.friends[B.UserId] = true
		svc:_request(B, "drop_shaft", "start")
		check("a friend's unshared ghost is never shown (honest fallback note)", last(B, "Ghost").friend == nil and last(B, "Ghost").friendNote:find("shared", 1, true) ~= nil)
		svc:_request(A, "drop_shaft", "share")
		check("SHARE MY GHOST is explicit and confirmed", last(A, "Shared") and last(A, "Shared").shared == true)
		svc:_request(B, "drop_shaft", "retry")
		local g = last(B, "Ghost")
		check("after sharing, a friend in the server races it (named)", g.friend ~= nil and g.friendName == "P101")
		B.friends[A.UserId] = nil
		svc:_request(B, "drop_shaft", "retry")
		check("not friends -> no ghost, even when shared", last(B, "Ghost").friend == nil)
		local stale = { v = 1, key = "drop_shaft|r0|R1|s1", seconds = 20, hz = 5, points = { 0, 0, 0, 1, 1, 1 }, shared = true }
		check("a shared ghost from another challenge version never matches", CS.PickFriendGhost({ { isFriend = true, ghost = stale } }, key) == nil)

		-- 7) codes, refusals, quit
		svc:_request(B, "drop1", "code")
		check("a typed code opens the card (resolved on the server)", last(B, "Card") and last(B, "Card").id == "drop_shaft")
		svc:_request(B, "ZZZ9", "code")
		check("an unknown code is refused with a plain reason", last(B, "Refused") ~= nil)
		svc:_request(B, "drop_shaft", "quit")
		check("QUIT ends the attempt and sends you back to the hub", svc.runs[B] == nil and last(B, "Ended") and spawns[#spawns].reason == "ToHub")
		round.racerByPlayer[B] = {}
		svc:_request(B, "drop_shaft", "start")
		check("racers in the current round cannot start an attempt", svc.runs[B] == nil and last(B, "Refused") ~= nil)
		check("too-fast times (< 8 s) can never be a best", not m.TimeTrialRules.IsBetter(5, nil))
	end)
	_G.workspace, _G.task = savedWorkspace, savedTask
	check("the mock attempt flow ran to the end", okFlow, flowErr)

	-- rival gap + post-race story (race side of the brief) ------------------------------------
	local RR = m.RaceRules
	if RR and RR.GateCrossing then
		local gate = {}
		local p1 = RR.GateCrossing(gate, { time = 10.0, name = "A" })
		local p3, ahead3 = RR.GateCrossing(gate, { time = 11.3, name = "C" })
		local p2, ahead2, behind2 = RR.GateCrossing(gate, { time = 10.5, name = "B" }) -- a late sample, earlier time
		check("gate order: crossings sort by interpolated time even when samples arrive late", p1 == 1 and p3 == 2 and ahead3.name == "A" and p2 == 2 and ahead2.name == "A" and behind2.name == "C" and gate[3].name == "C")
		check("signed gap to the racer ahead (B is +0.50 to A)", math.abs((10.5 - ahead2.time) - 0.5) < 1e-9)
		local story = RR.StoryLine({ place = 2, field = 8, grid = 6, finished = true, recoveries = 0, laps = { 66.4, 64.2, 65.0 }, ledGates = 0, gates = 9, bestGain = 2 })
		check("story: 'Climbed from P6 to P2 · clean race · best lap 1:04.2 (lap 2)'", story == "Climbed from P6 to P2  ·  clean race  ·  best lap 1:04.2 (lap 2)", story)
		local win = RR.StoryLine({ place = 1, field = 6, grid = 1, finished = true, recoveries = 1, laps = { 70, 69 }, ledGates = 9, gates = 9, bestGain = 0 })
		local drop = RR.StoryLine({ place = 7, field = 8, grid = 2, finished = true, recoveries = 3, laps = { 80, 75, 76 }, gates = 9, ledGates = 0, bestGain = 0 })
		local dnf = RR.StoryLine({ place = 8, field = 8, grid = 4, finished = false, recoveries = 4 })
		check("story: lights to flag / a drop with its cause / a DNF says what happened", win:find("Led every gate", 1, true) and drop:find("3 recoveries cost you", 1, true) and dnf:find("after 4 recoveries", 1, true) and not dnf:find("clean", 1, true), table.concat({ win, drop, dnf }, " | "))
	end
	local HUD = m.RaceHUDPure
	if HUD and HUD.GapText then
		local behind, tone = HUD.GapText({ gatePlace = 3, aheadName = "Mia", aheadGap = 0.84 })
		local ahead, tone2 = HUD.GapText({ kind = "GapBehind", behindName = "Sam", behindIsBot = true, gap = 1.2 })
		local lead = HUD.GapText({ gatePlace = 1 })
		check("gap chip: '+0.84 to MIA (P2)' / '-1.20 [BOT] SAM behind' / 'P1 AT THIS GATE'", behind == "+0.84  to MIA (P2)" and tone == "behind" and ahead == "-1.20  [BOT] SAM behind" and tone2 == "ahead" and lead == "P1 AT THIS GATE", tostring(behind) .. " | " .. tostring(ahead))
	end

	-- Foundry Cup pilot (staging rules only) ---------------------------------------------------
	local Cup = m.CupConfig
	if Cup then
		local cup = Cup.ById.foundry_cup_pilot
		check("the Foundry Cup pilot is staging-only with no prize", cup.Status == "Staging" and cup.Prize == nil and cup.QualifierChallenge == "drop_shaft")
		local rows = {}
		for i = 1, 20 do
			rows[i] = { userId = i, seconds = 20 + (i % 7) + i / 100, setAt = 100 - i }
		end
		rows[21] = { userId = 99, seconds = 20.07, setAt = 1 } -- same time as user 7, set earlier
		local q = Cup.Qualify(cup, rows)
		local seven, ninetyNine
		for i, r in ipairs(q) do
			if r.userId == 7 then
				seven = i
			elseif r.userId == 99 then
				ninetyNine = i
			end
		end
		check("qualifier: the top 12 weekly times, ties to whoever set the time first", #q == 12 and q[1].seconds <= q[12].seconds and ninetyNine and seven and ninetyNine < seven)
		local st = Cup.Standings(cup, {
			{ [1] = { place = 1, finished = true }, [2] = { place = 2, finished = true }, [3] = { place = 3, finished = false } },
			{ [1] = { place = 2, finished = true }, [2] = { place = 1, finished = true }, [3] = { place = 3, finished = true } },
		}, { [1] = 21.0, [2] = 20.5, [3] = 22 })
		check("final points 25/18/15, DNF 0; tied on points and wins -> qualifier time decides", st[1].userId == 2 and st[1].points == 43 and st[2].userId == 1 and st[3].points == 15, string.format("%d:%d %d:%d", st[1].userId, st[1].points, st[2].userId, st[2].points))
	end

	-- client pure helpers -------------------------------------------------------------------
	local CP = m.ChallengePure
	if CP then
		local text, ahead = CP.DeltaText(-0.42)
		local text2, ahead2 = CP.DeltaText(1.1)
		check("client split delta text: -0.42 ahead, +1.10 behind", text == "-0.42" and ahead and text2 == "+1.10" and not ahead2)
		check("client countdown: 3 / 2 / 1 / GO", CP.CountdownText(103, 100) == "3" and CP.CountdownText(100.5, 100) == "1" and CP.CountdownText(100, 100) == "GO")
		local x, y, w, h = CP.CaptureGuide(1920, 1080)
		check("Clean Capture guide: a centred 9:16 frame in a landscape viewport", math.abs(w / h - 9 / 16) < 1e-6 and h == 1080 and math.abs(x - (1920 - w) / 2) < 1e-6 and y == 0)
		local rx, ry, rw, rh = CP.CaptureGuide(400, 900)
		check("Clean Capture guide fits a portrait viewport too", rw == 400 and math.abs(rh - 400 * 16 / 9) < 1e-6 and rx == 0 and ry > 0)
		local lines = CP.ResultLines({ id = "drop_shaft", seconds = 24.81, best = 24.81, pb = true, previous = 25.5, medal = "Silver", line = CC.ResultLine(c, 24.81), saved = true })
		check("result card: 'THE DROP SHAFT · 24.81 s · SILVER' and NEW BEST", lines.head:find("24.81 s", 1, true) and lines.head:find("SILVER", 1, true) and lines.sub:find("NEW BEST", 1, true))
		local card = CP.CardLines({ id = "drop_shaft", weekly = true, week = 51, weekEnds = 1000 + 3 * 86400 + 4 * 3600, mastery = { done = 2, total = 3 } }, 1000)
		check("challenge card: medal targets, no-time line, mastery 2/3, weekly window", card.medals:find("GOLD 21.00", 1, true) and card.best:find("No time yet", 1, true) and card.mastery:find("2 / 3", 1, true) and card.week:find("ends in 3d 4h", 1, true))
	end
	return results
end

return Spec
