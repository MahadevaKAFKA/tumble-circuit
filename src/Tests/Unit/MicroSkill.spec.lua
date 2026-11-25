--[[ MicroSkill.spec — Ramp Trick takeoff/press/landing, Slipstream hold/grace/no-farming,
	Near Miss once per approach (pure, simulated samples on the real trick zone). ]]

local Spec = {}

function Spec.run(m)
	local r = { passed = 0, failed = 0, lines = {}, info = {} }
	local function check(name, ok, detail)
		r[ok and "passed" or "failed"] = r[ok and "passed" or "failed"] + 1
		table.insert(r.lines, (ok and "PASS  " or "FAIL  ") .. name .. ((not ok and detail) and ("  -- " .. tostring(detail)) or ""))
	end
	local SR, CFG = m.SkillRules, m.AbilityConfig.MicroSkills
	local layout = m.TrackDefinitions.Generate(m.TrackDefinitions.Training, 2)
	local zone = layout.TrickZones[1]
	check("training track has a tagged trick ramp", zone ~= nil)
	if not zone then
		return r
	end
	check("trick ramp leaves a flat lane (validator)", #m.TrackDefinitions.Validate(m.TrackDefinitions.Training, layout) == 0)
	local lateral = (zone.LateralMin + zone.LateralMax) / 2

	-- Simulated pass over the lip: rolling up (height grows), lip at 3.4, airborne, landing.
	local function pass(opts)
		local st, events, t, s = {}, {}, 0, zone.LipS - 10
		local press = opts.pressAt
		local prevS, prevT = nil, nil
		for i = 1, 60 do
			prevS, prevT = s, t
			t = t + 0.05
			s = s + 2 -- 40 studs/s
			local h
			if s < zone.LipS then
				h = math.max(0, (s - (zone.LipS - zone.Length)) / zone.Length) * zone.Height * (opts.onKicker and 1 or 0)
			else
				local air = (s - zone.LipS) / 40
				h = (opts.onKicker and zone.Height or 0) + 6 * air - 98 * air * air
			end
			if opts.noLanding and s >= zone.LipS then
				h = 5
			end
			local sample = { s = s, prevS = prevS, time = t, prevTime = prevT, height = math.max(0, h), lateral = opts.lateral or lateral, speed = opts.speed or 40 }
			if press and t >= press and not opts.pressed then
				opts.pressed = true
				table.insert(events, "press:" .. SR.TrickPress(st, t, CFG.Trick))
				if opts.pressTwice then
					table.insert(events, "press:" .. SR.TrickPress(st, t + 0.01, CFG.Trick))
				end
			end
			local ev = SR.TrickStep(st, sample, zone, CFG.Trick)
			if ev then
				table.insert(events, ev)
			end
		end
		return table.concat(events, ","), st
	end
	local lipT = 0.25 -- s reaches the lip at the 5th sample
	local seq = pass({ onKicker = true, pressAt = lipT - 0.1 })
	check("early press (just before the lip) -> takeoff -> success", seq == "press:Pending,Takeoff,Success", seq)
	seq = pass({ onKicker = true, pressAt = lipT + 0.1 })
	check("press in the air after takeoff -> success", seq == "Takeoff,press:Accepted,Success", seq)
	seq = pass({ onKicker = true })
	check("jump without pressing -> no reward", seq == "Takeoff,LandedNoTrick", seq)
	seq = pass({ onKicker = false, pressAt = lipT })
	check("press on the flat lane never becomes a trick", seq == "press:Pending", seq)
	seq = pass({ onKicker = true, lateral = zone.LateralMax + 6, pressAt = lipT - 0.1 })
	check("crossing the lip beside the kicker is not a takeoff", seq == "press:Pending", seq)
	seq = pass({ onKicker = true, speed = 5, pressAt = lipT - 0.1 })
	check("crawling over the lip (too slow) is not a takeoff", seq == "press:Pending", seq)
	seq = pass({ onKicker = true, pressAt = lipT + 0.1, pressTwice = true })
	check("one trick per airtime (second press is a duplicate)", seq == "Takeoff,press:Accepted,press:Duplicate,Success", seq)
	seq = pass({ onKicker = true, pressAt = lipT + 0.1, noLanding = true })
	check("no landing within the airtime window -> fail, no reward", seq == "Takeoff,press:Accepted,NoLanding", seq)
	local st = {}
	check("a respawn (fresh state, no previous sample) is never a takeoff", SR.TrickStep(st, { s = zone.LipS + 1, prevS = nil, time = 1, height = 3, lateral = lateral, speed = 40 }, zone, CFG.Trick) == nil)

	-- Slipstream
	local follower = { position = Vector3.new(0, 0, 0), s = 100, tangent = Vector3.new(0, 0, -1) }
	local behind = { position = Vector3.new(0, 0, -9), s = 109, tangent = Vector3.new(0, 0, -1) }
	local ahead = { position = Vector3.new(0, 0, 9), s = 91, tangent = Vector3.new(0, 0, -1) }
	local side = { position = Vector3.new(8, 0, -2), s = 102, tangent = Vector3.new(0, 0, -1) }
	local far = { position = Vector3.new(0, 0, -20), s = 120, tangent = Vector3.new(0, 0, -1) }
	check("draft geometry: directly behind a leader within 12 studs", SR.SlipstreamGeometry(follower, behind, CFG.Slipstream))
	check("draft geometry: not when you are ahead, alongside or too far", not SR.SlipstreamGeometry(follower, ahead, CFG.Slipstream) and not SR.SlipstreamGeometry(follower, side, CFG.Slipstream) and not SR.SlipstreamGeometry(follower, far, CFG.Slipstream))
	local slip, events = {}, {}
	local t, firstTrue, acquiredAt = 0, nil, nil
	for _ = 1, 40 do -- 2 s of continuous drafting at 20 Hz
		t = t + 0.05
		firstTrue = firstTrue or t
		local ev = SR.SlipstreamStep(slip, true, t, CFG.Slipstream)
		if ev then
			events[#events + 1] = ev
			acquiredAt = acquiredAt or t
		end
	end
	local held = acquiredAt and (acquiredAt - firstTrue) or -1
	check("slipstream acquires once after a 1.5 s hold and does not repeat every sample", #events == 1 and events[1] == "Acquired" and held >= 1.5 - 1e-9 and held < 1.55 + 1e-9, string.format("%d events, held %.3f", #events, held))
	local flicker = SR.SlipstreamStep(slip, false, t + 0.2, CFG.Slipstream)
	check("brief LOS flicker (< grace) keeps it", flicker == nil and slip.active)
	local lost = SR.SlipstreamStep(slip, false, t + 0.3, CFG.Slipstream)
	check("breaking the draft ends it", lost == "Lost" and not slip.active)
	local re = SR.SlipstreamStep(slip, true, t + 0.35, CFG.Slipstream)
	check("re-acquiring needs another full hold (no oscillation farming)", re == nil and not slip.active)

	-- Near miss
	local nm, out = {}, {}
	local contact = 5
	for _, d in ipairs({ 20, 15, 10, 7, 5.8, 7, 10, 15, 17 }) do
		local ev = SR.NearMissStep(nm, d, contact, true, CFG.NearMiss)
		if ev then
			out[#out + 1] = ev
		end
	end
	check("clean close pass while dangerous -> exactly one near miss", table.concat(out, ",") == "NearMiss", table.concat(out, ","))
	nm, out = {}, {}
	for _, d in ipairs({ 15, 10, 5.8, 10, 17 }) do
		local ev = SR.NearMissStep(nm, d, contact, false, CFG.NearMiss)
		if ev then
			out[#out + 1] = ev
		end
	end
	check("close pass while the hazard is idle is not a near miss", #out == 0)
	nm, out = {}, {}
	for _, d in ipairs({ 15, 9, 4.5, 6, 17 }) do
		local ev = SR.NearMissStep(nm, d, contact, true, CFG.NearMiss)
		if ev then
			out[#out + 1] = ev
		end
	end
	check("touching the hazard is a hit, never a near miss", table.concat(out, ",") == "Hit", table.concat(out, ","))
	nm, out = {}, {}
	for _ = 1, 10 do
		for _, d in ipairs({ 15.9, 16.1 }) do
			local ev = SR.NearMissStep(nm, d, contact, true, CFG.NearMiss)
			if ev then
				out[#out + 1] = ev
			end
		end
	end
	check("bobbing at the approach boundary far from the hazard farms nothing", #out == 0)
	return r
end

return Spec
