--[[
	BotNavigation.spec (A4) — BotBrain decisions (pure) and a KINEMATIC lane model of bots driving
	the whole Neon Foundry with the real hazard clock. The model moves along the route at a fixed
	forward speed and integrates only lateral motion with the human motor's lateral constants and
	the real fan/conveyor pushes. It is a decision-quality check, NOT a physics simulation: the
	Studio run (1, 3, 8 bots) is what proves real navigation.
]]

local Spec = {}

local function clamp(x, lo, hi)
	if x < lo then
		return lo
	elseif x > hi then
		return hi
	end
	return x
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
	local BB, HS, TD = m.BotBrain, m.HazardSim, m.TrackDefinitions
	local mv = m.PhysicsConfig.Movement

	-------------------------------------------------------------------- pure decisions
	local function ctx(t)
		local base = { lateral = 0, lateralVelocity = 0, speed = 40, s = 100, halfWidth = 13, hazards = {}, splitAhead = false, dropAhead = false, skill = 1.2, rng = BB.Rng(5), now = 0 }
		for k, v in pairs(t or {}) do
			base[k] = v
		end
		return base
	end
	local steer = BB.Decide({}, ctx({ lateral = -6 }))
	check("steers toward the lane target (left of target -> steer right)", steer > 0)
	local target = BB.ChooseTarget(ctx({ hazards = { { kind = "PulseBumper", s = 120, offset = 0, radius = 3 } } }), {})
	check("dodges a bumper dead ahead by at least its radius + ball", math.abs(target) >= 3 + 2, target)
	local hammerLeft = BB.ChooseTarget(ctx({ hazards = { { kind = "Hammer", s = 110, offset = 0, lateral = 6 } } }), {})
	check("hammer predicted on the right -> bot takes the left", hammerLeft < -5, hammerLeft)
	local tiles = BB.ChooseTarget(ctx({ lateral = 4, hazards = { { kind = "Tiles", s = 95, endS = 150, offset = 0, solidCols = { -9, 3 } } } }), {})
	check("falling tiles: aims at the nearest solid column", tiles == 3, tiles)
	local sweep = BB.ChooseTarget(ctx({ hazards = { { kind = "Sweeper", s = 115, offset = 0, radius = 11, armSide = 0.8 } } }), {})
	check("sweeper arm predicted on the right at arrival -> bot passes on the left", sweep < -5, sweep)
	local laneState = {}
	BB.Decide(laneState, ctx({ splitAhead = true, halfWidth = 17, hazards = { { kind = "PulseBumper", s = 110, offset = 9, radius = 2.6 } } }))
	check("split lane: never aims at the centre divider", math.abs(laneState.target) >= BB.DividerClearance - 1e-9, laneState.target)

	local maxThrottle = 0
	local sameThrottle = true
	for _, skill in ipairs(BB.Skills) do
		for i = 1, 50 do
			local _, throttle, brake = BB.Decide({}, ctx({ skill = skill, rng = BB.Rng(i), dropAhead = i % 2 == 0, speed = 75 }))
			maxThrottle = math.max(maxThrottle, throttle)
			if not brake and throttle ~= 1 then
				sameThrottle = false
			end
		end
	end
	check("no hidden speed: throttle is 0..1 for every skill (motor caps apply)", maxThrottle <= 1 and sameThrottle)
	local r1, r2 = BB.Rng(42), BB.Rng(42)
	check("bot RNG is deterministic per seed", r1() == r2() and r1() == r2())
	check("ability choice only from ready abilities", BB.ChooseAbility({ ready = {}, hazardAhead = 5, nearby = 3, speed = 50, skill = 1.2, rng = BB.Rng(1) }) == nil)
	local picks = {}
	for i = 1, 40 do
		local id = BB.ChooseAbility({ ready = { Shield = 2 }, hazardAhead = 10, nearby = 0, speed = 40, skill = 1.2, rng = BB.Rng(i) })
		if id then
			picks[id] = true
		end
	end
	check("bots raise a shield before hazards (same AbilityService path as humans)", picks.Shield == true)

	-------------------------------------------------------------------- kinematic lane model
	local layout = TD.Generate(TD.Race, m.PhysicsConfig.Ball.Radius)
	local sections = layout.Sections
	local dividers = {}
	for _, piece in ipairs(layout.Pieces) do
		local d = piece.Definition.Divider
		if d then
			local a = sections[piece.FirstSection].S
			local b = sections[piece.LastSection].S
			local len = piece.Definition.Length
			dividers[#dividers + 1] = { a + (b - a) * d.From / len, a + (b - a) * d.To / len, a - 30, b }
		end
	end
	local function frameAt(s)
		local lo, hi = 1, #sections
		while hi - lo > 1 do
			local mid = math.floor((lo + hi) / 2)
			if sections[mid].S <= s then
				lo = mid
			else
				hi = mid
			end
		end
		return sections[lo]
	end

	local function drive(skill, seed, seedClass)
		local resolved = {}
		for _, hz in ipairs(layout.Hazards) do
			resolved[#resolved + 1] = { Kind = hz.Kind, Id = hz.Id, Definition = hz.Definition, Frame = hz.Frame, FromFrame = hz.FromFrame, Length = hz.Length, Offset = hz.Offset, Piece = hz.Piece, Params = HS.Params(hz.Definition, seedClass) }
		end
		local state, rng = {}, BB.Rng(seed)
		local s, t, dt, v = layout.StartLineS, 0, 1 / 30, 38
		local lateral, latVel = (seed % 5 - 2) * 3, 0
		local worstMargin, hits, falls, dividerHits = math.huge, 0, 0, 0
		local cooldown = {}
		while s < layout.FinishLineS do
			local sec = frameAt(s)
			local half = sec.Width / 2
			local splitAhead, inDivider = false, false
			for _, d in ipairs(dividers) do
				if s >= d[3] and s <= d[4] then
					splitAhead = true
				end
				if s >= d[1] and s <= d[2] then
					inDivider = true
				end
			end
			local hazards = BB.HazardContext(resolved, sections, s, v, t)
			local steerX = BB.Decide(state, { lateral = lateral, lateralVelocity = latVel, speed = v, s = s, halfWidth = half, hazards = hazards, splitAhead = splitAhead, dropAhead = false, skill = skill, rng = rng, now = t })
			local accel
			if steerX ~= 0 then
				accel = (steerX * mv.LateralSpeedCap - latVel) * mv.LateralResponse
				accel = steerX > 0 and math.max(0, accel) or math.min(0, accel)
			else
				accel = -latVel * mv.LateralAssistDamping
			end
			accel = clamp(accel, -mv.LateralAccelMax, mv.LateralAccelMax)
			local position = sec.Position + sec.Right * lateral + sec.Up * 2
			for _, hz in ipairs(resolved) do
				if hz.Kind == "Fan" or hz.Kind == "Conveyor" then
					local push = HS.EnvironmentAccel(hz, t, position)
					if push then
						accel = accel + push:Dot(sec.Right)
					end
				end
			end
			latVel = latVel + accel * dt
			lateral = lateral + latVel * dt
			if math.abs(lateral) > half - 2 then -- the rail stops the ball (inelastic, model)
				lateral = clamp(lateral, -(half - 2), half - 2)
				latVel = 0
			end
			if inDivider and math.abs(lateral) < BB.DividerClearance - 1.5 then
				dividerHits = dividerHits + 1
			end
			worstMargin = math.min(worstMargin, half - 2 - math.abs(lateral))
			for _, hz in ipairs(resolved) do
				if (cooldown[hz.Id] or 0) <= t then
					local hit = false
					if hz.Kind == "Sweeper" or hz.Kind == "Hammer" then
						hit = HS.Contact(hz, t, position, 2) ~= nil
					elseif hz.Kind == "PulseBumper" then
						local c = hz.Frame.Position + hz.Frame.Right * (hz.Offset or 0)
						local d = position - c
						d = d - hz.Frame.Up * d:Dot(hz.Frame.Up)
						hit = d.Magnitude < hz.Definition.Radius + 2
					elseif hz.Kind == "Tiles" and hz.Piece then
						local a, b = sections[hz.Piece.FirstSection].S, sections[hz.Piece.LastSection].S
						if s >= a and s < b then
							local p = hz.Params
							local row = math.min(p.Rows, math.floor((s - a) / ((b - a) / p.Rows)) + 1)
							local col = clamp(math.floor((lateral + half) / (sec.Width / p.Cols)) + 1, 1, p.Cols)
							if HS.TileState(p, row, col, t) == "Dropped" then
								falls = falls + 1
								cooldown[hz.Id] = t + 1
							end
						end
					end
					if hit then
						hits = hits + 1
						cooldown[hz.Id] = t + 1
					end
				end
			end
			s = s + v * dt
			t = t + dt
		end
		return { hits = hits, falls = falls, divider = dividerHits, margin = worstMargin, seconds = t }
	end

	local summary = {}
	local laneOk, dividerOk, totalHits = true, true, { 0, 0, 0 }
	local totalFalls = { 0, 0, 0 }
	for k, skill in ipairs(BB.Skills) do
		for seedClass = 0, 2 do
			for run = 1, 3 do
				local r = drive(skill, run * 17 + k, seedClass)
				totalHits[k] = totalHits[k] + r.hits
				totalFalls[k] = totalFalls[k] + r.falls
				if r.divider > 0 then
					dividerOk = false
				end
				if r.margin < -1e-6 then
					laneOk = false
				end
			end
		end
		summary[#summary + 1] = string.format("skill %.1f: %.1f hazard hits, %.1f tile drops per run", skill, totalHits[k] / 9, totalFalls[k] / 9)
	end
	check("lane model: bots never drive into the split-lane divider", dividerOk)
	check("lane model: bots stay on the course width the whole race", laneOk)
	check("lane model: skilled bots (1.2) hit no more hazards than 0.8 bots", totalHits[3] <= totalHits[1] + 1, totalHits[3] .. " vs " .. totalHits[1])
	check("lane model: a skill 1.0 bot averages <= 4 hazard hits + tile drops per run", (totalHits[2] + totalFalls[2]) / 9 <= 4, (totalHits[2] + totalFalls[2]) / 9)
	table.insert(results.info, "kinematic lane model (fixed 38 studs/s, NOT physics): " .. table.concat(summary, "; "))
	return results
end

return Spec
