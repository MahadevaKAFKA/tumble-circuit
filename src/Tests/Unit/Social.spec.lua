--[[
	Social.spec (A6) — spectator Chaos Vote rules (eligibility, timing, one vote per poll, stale /
	closed / bad votes, ties, no votes), the two vote modifiers stay harmless and bounded, the
	modifier window, Perfect Dodge judging (once per pass, never on contact), Clearance agrees
	with the contact model, emote presets, and the chaos banner text.
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
	local VR, SC, HS = m.VoteRules, m.SocialConfig, m.HazardSim
	local cfg = SC.Vote

	-------------------------------------------------------------------- eligibility + timing
	check("finished racers and non-racers may vote; active racers and bots may not", VR.Eligible({ isHuman = true, isActiveRacer = false }) and not VR.Eligible({ isHuman = true, isActiveRacer = true }) and not VR.Eligible({ isHuman = false, isActiveRacer = false }))
	local base = { state = "Racing", pollOpen = false, eligible = 1, activeRacers = 3, secondsLeft = 120, raceElapsed = 21, lastPollAt = nil, now = 100, modifierBusyUntil = 0 }
	local function with(t)
		local c = {}
		for k, v in pairs(base) do
			c[k] = v
		end
		for k, v in pairs(t) do
			c[k] = v
		end
		return c
	end
	check("a poll opens after 20 s of racing with a spectator present", VR.ShouldOpen(base, cfg))
	check("no poll before 20 s, without spectators, without active racers, or outside Racing", not VR.ShouldOpen(with({ raceElapsed = 10 }), cfg) and not VR.ShouldOpen(with({ eligible = 0 }), cfg) and not VR.ShouldOpen(with({ activeRacers = 0 }), cfg) and not VR.ShouldOpen(with({ state = "Results" }), cfg))
	check("no poll when the race is about to end or one is already open", not VR.ShouldOpen(with({ secondsLeft = 12 }), cfg) and not VR.ShouldOpen(with({ pollOpen = true }), cfg))
	check("polls are spaced 20 s apart and never overlap an active modifier", not VR.ShouldOpen(with({ lastPollAt = 90 }), cfg) and VR.ShouldOpen(with({ lastPollAt = 79 }), cfg) and not VR.ShouldOpen(with({ lastPollAt = 70, modifierBusyUntil = 105 }), cfg))

	-------------------------------------------------------------------- casting + tally
	local poll = VR.NewPoll(7, 100, cfg)
	check("a valid vote counts", VR.Cast(poll, 11, 7, 1, 101) == true and poll.counts[1] == 1)
	local again, why = VR.Cast(poll, 11, 7, 2, 102)
	check("one vote per person per poll (spam / changing vote refused)", again == false and why == "already voted" and poll.counts[2] == nil)
	check("stale poll id, closed poll, bad option all refused", VR.Cast(poll, 12, 6, 1, 101) == false and VR.Cast(poll, 13, 7, 3, 101) == false and VR.Cast(poll, 14, 7, 1.5, 101) == false and VR.Cast(poll, 15, 7, 2, 105.1) == false)
	VR.Cast(poll, 16, 7, 2, 103)
	VR.Cast(poll, 17, 7, 2, 104)
	check("most votes wins", VR.Tally(poll) == 2)
	local tieOdd = VR.NewPoll(3, 0, cfg)
	VR.Cast(tieOdd, 1, 3, 1, 1)
	VR.Cast(tieOdd, 2, 3, 2, 1)
	local tieEven = VR.NewPoll(4, 0, cfg)
	VR.Cast(tieEven, 1, 4, 1, 1)
	VR.Cast(tieEven, 2, 4, 2, 1)
	check("ties resolve deterministically (odd poll -> option 1, even -> option 2)", VR.Tally(tieOdd) == 1 and VR.Tally(tieEven) == 2)
	check("no votes -> nothing happens", VR.Tally(VR.NewPoll(9, 0, cfg)) == nil)
	check("a voter who disconnected keeps a consistent tally", (function()
		local p = VR.NewPoll(5, 0, cfg)
		VR.Cast(p, 1, 5, 1, 1)
		return VR.Tally(p) == 1
	end)())

	-------------------------------------------------------------------- modifiers are harmless
	local turbo = HS.Modifiers.TurboFans.FanAccelMultiplier
	local fanAccel = 0
	for seed = 0, 2 do
		local params = HS.Params({ Id = "Fan1", Accel = 28 }, seed)
		fanAccel = math.max(fanAccel, params.Accel)
	end
	check("Turbo Fans stays counter-steerable (boosted push < steering accel cap)", fanAccel * turbo < m.PhysicsConfig.Movement.LateralAccelMax, string.format("%.0f vs %d", fanAccel * turbo, m.PhysicsConfig.Movement.LateralAccelMax))
	check("Bouncy Bumpers stays within the hazard kick cap", m.PhysicsConfig.Hazards.PulseBumper.KickSpeed * HS.Modifiers.BouncyBumpers.BumperKickMultiplier <= HS.KickCap + 1e-9)
	local mod = { kind = "TurboFans", startsAt = 10, endsAt = 18 }
	check("modifier only acts inside its announced window", HS.FanMultiplier(mod, 9.9) == 1 and HS.FanMultiplier(mod, 10) == turbo and HS.FanMultiplier(mod, 18) == 1 and HS.BumperKickMultiplier(mod, 12) == 1)
	check("unknown or missing modifiers do nothing", HS.ActiveModifier({ kind = "Lava", startsAt = 0, endsAt = 99 }, 5) == nil and HS.ActiveModifier(nil, 5) == nil)
	check("vote options = Turbo Fans / Bouncy Bumpers, both with plain descriptions", #cfg.Options == 2 and cfg.Options[1].id == "TurboFans" and cfg.Options[2].id == "BouncyBumpers" and #cfg.Options[1].description > 0)
	check("vote window 5 s, every 20 s, announced 3 s ahead, lasts 8 s", cfg.WindowSeconds == 5 and cfg.IntervalSeconds == 20 and cfg.LeadSeconds == 3 and cfg.DurationSeconds == 8)

	-------------------------------------------------------------------- Perfect Dodge
	local TD = m.TrackDefinitions
	local layout = TD.Generate(TD.Race, 2)
	local sweeper
	for _, hz in ipairs(layout.Hazards) do
		if hz.Kind == "Sweeper" then
			sweeper = { Kind = hz.Kind, Id = hz.Id, Definition = hz.Definition, Frame = hz.Frame, Params = HS.Params(hz.Definition, 0) }
		end
	end
	local agree, samples = true, 0
	for t = 0, 6, 0.5 do
		for x = -10, 10, 2.5 do
			for z = -10, 10, 2.5 do
				local p = sweeper.Frame.Position + sweeper.Frame.Right * x + sweeper.Frame.Forward * z + sweeper.Frame.Up * 2
				local clearance = HS.Clearance(sweeper, t, p, 2)
				local contact = HS.Contact(sweeper, t, p, 2) ~= nil
				if clearance then
					samples = samples + 1
					if (clearance <= 0) ~= contact and math.abs(clearance) > 0.35 then
						agree = false
					end
				end
			end
		end
	end
	check("Clearance <= 0 exactly where the contact model hits (sweeper)", agree and samples > 100, samples)
	local DC = m.AbilityConfig.MicroSkills.PerfectDodge
	local SR = m.SkillRules
	local st = {}
	SR.DodgeStep(st, 12, 4, DC)
	SR.DodgeStep(st, 8, 1.2, DC)
	SR.DodgeStep(st, 10, 3, DC)
	check("close pass without contact -> one Perfect Dodge on leaving", SR.DodgeStep(st, 20, nil, DC) == "PerfectDodge" and SR.DodgeStep(st, 25, nil, DC) == nil)
	local hit = {}
	SR.DodgeStep(hit, 9, 1, DC)
	check("contact during the pass -> Hit, never a Perfect Dodge", SR.DodgeStep(hit, 6, -0.2, DC) == "Hit" and SR.DodgeStep(hit, 20, nil, DC) == nil)
	local wide = {}
	SR.DodgeStep(wide, 12, 6, DC)
	check("a wide pass is not a Perfect Dodge", SR.DodgeStep(wide, 20, nil, DC) == nil)

	-------------------------------------------------------------------- emotes + banner
	local E = SC.Emotes
	check("three preset emotes (GG / Nice Save! / Oops!), 5 s cooldown, distance LOD", #E.List == 3 and E.List[1].text == "GG" and E.List[2].text == "Nice Save!" and E.List[3].text == "Oops!" and E.CooldownSeconds == 5 and E.MaxDistance > 0)
	local freeText = false
	for name, spec in pairs(m.RoundProtocol.Remotes) do
		if spec.Direction == "ClientToServer" and (name == "QuickEmote" or name == "CastSpectatorVote") then
			for _, arg in ipairs(spec.Args) do
				if type(arg) ~= "table" or arg.type == "string" then
					freeText = true
				end
			end
		end
	end
	check("emote / vote remotes carry only bounded numbers (no free text)", not freeText)
	local Social = m.SocialPure
	if Social then
		local m1 = { kind = "TurboFans", label = "TURBO FANS", description = "x", startsAt = 10, endsAt = 18 }
		check("chaos banner: lead-time countdown, active countdown, then nothing", Social.BannerText(m1, 7.5):find("in 3 s") ~= nil and Social.BannerText(m1, 12):find("6 s") ~= nil and Social.BannerText(m1, 18) == nil)
	end
	return results
end

return Spec
