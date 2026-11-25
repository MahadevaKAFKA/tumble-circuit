--[[
	SkillRules — pure A3 rules (no services), used by AbilityService / MicroSkillService and the
	offline specs. Every function takes explicit times so tests can drive them deterministically.
]]

local SkillRules = {}

---------------------------------------------------------------------------------------------
-- Loadout & cooldowns
---------------------------------------------------------------------------------------------
function SkillRules.ValidateLoadout(loadout, owned, slotCount, abilities)
	if type(loadout) ~= "table" or #loadout ~= slotCount then
		return false, "wrong slot count"
	end
	local ownedSet, seen = {}, {}
	for _, id in ipairs(owned) do
		ownedSet[id] = true
	end
	for _, id in ipairs(loadout) do
		if type(id) ~= "string" or not abilities[id] then
			return false, "unknown ability"
		end
		if not ownedSet[id] then
			return false, "not owned"
		end
		if seen[id] then
			return false, "duplicate"
		end
		seen[id] = true
	end
	return true
end

function SkillRules.IsReady(now, cooldownEnd)
	return cooldownEnd == nil or now >= cooldownEnd
end

-- Cooldown Charge: subtract `seconds` from every slot still cooling (never below now), at most
-- once per lockout window. Returns true only if something changed (then the lockout starts).
function SkillRules.ApplyCharge(state, now, seconds, lockout)
	if state.lockoutUntil and now < state.lockoutUntil then
		return false, "lockout"
	end
	local changed = false
	for slot, finish in pairs(state.cooldowns) do
		if finish > now then
			state.cooldowns[slot] = math.max(now, finish - seconds)
			changed = true
		end
	end
	if changed then
		state.lockoutUntil = now + lockout
		return true
	end
	return false, "nothing cooling"
end

---------------------------------------------------------------------------------------------
-- Speed modifiers (never stack: the strongest active one applies)
---------------------------------------------------------------------------------------------
function SkillRules.CurrentMultiplier(modifiers, now)
	local best = 1
	for _, mod in pairs(modifiers) do
		if mod.endsAt == nil or now < mod.endsAt then
			if mod.multiplier > best then
				best = mod.multiplier
			end
		end
	end
	return best
end

function SkillRules.EffectiveTerminal(baseTerminal, multiplier, hardCap)
	return math.min(baseTerminal * multiplier, hardCap)
end

---------------------------------------------------------------------------------------------
-- Pulse
---------------------------------------------------------------------------------------------
function SkillRules.PulseDeltaV(distance, cfg)
	if distance > cfg.Radius then
		return nil
	end
	local fraction = math.max(0, distance) / cfg.Radius
	return cfg.MaxDeltaV * (1 - (1 - cfg.EdgeFraction) * fraction)
end

-- candidates: { {id, position, protected, frozen} }. Returns { {id, direction, deltaV} }.
function SkillRules.PulseTargets(casterPosition, casterForward, candidates, cfg)
	local out = {}
	for _, c in ipairs(candidates) do
		if not c.protected and not c.frozen then
			local offset = c.position - casterPosition
			local flat = Vector3.new(offset.X, 0, offset.Z)
			local distance = offset.Magnitude
			local deltaV = SkillRules.PulseDeltaV(distance, cfg)
			if deltaV then
				local direction = flat.Magnitude > 1e-3 and flat.Unit or casterForward
				out[#out + 1] = { id = c.id, direction = direction, deltaV = deltaV, distance = distance }
			end
		end
	end
	return out
end

---------------------------------------------------------------------------------------------
-- Slipstream
---------------------------------------------------------------------------------------------
-- follower/leader: { position, s, tangent }. Line of sight is checked by the caller.
function SkillRules.SlipstreamGeometry(follower, leader, cfg)
	local ds = leader.s - follower.s
	if ds <= 0 or ds > cfg.MaxDistance + 2 then
		return false
	end
	local offset = leader.position - follower.position
	local distance = offset.Magnitude
	if distance > cfg.MaxDistance or distance < 1e-3 then
		return false
	end
	return (offset / distance):Dot(follower.tangent) >= cfg.MinAheadDot
end

-- state: { heldSince, lastTrue, active }. Returns "Acquired" | "Lost" | nil.
function SkillRules.SlipstreamStep(state, condition, now, cfg)
	if condition then
		state.lastTrue = now
		if not state.heldSince then
			state.heldSince = now
		end
		if not state.active and now - state.heldSince >= cfg.HoldSeconds then
			state.active = true
			return "Acquired"
		end
		return nil
	end
	local sinceTrue = state.lastTrue and (now - state.lastTrue) or math.huge
	if sinceTrue > cfg.GraceSeconds then
		state.heldSince = nil
		if state.active then
			state.active = false
			return "Lost"
		end
	end
	return nil
end

---------------------------------------------------------------------------------------------
-- Ramp Trick: takeoff / press / landing
---------------------------------------------------------------------------------------------
-- zone: { LipS, LateralMin, LateralMax }. sample: { s, prevS, time, prevTime, height, lateral, speed }
-- state: { airborne, takeoffTime, pressed, pressTime }. Returns event string or nil.
function SkillRules.TrickStep(state, sample, zone, cfg)
	if state.airborne then
		if sample.height <= cfg.LandedHeight then
			state.airborne = false
			local ok = state.pressed
			state.pressed, state.pressTime = false, nil
			return ok and "Success" or "LandedNoTrick"
		end
		if sample.time - state.takeoffTime > cfg.MaxAirtimeSeconds then
			state.airborne = false
			state.pressed, state.pressTime = false, nil
			return "NoLanding"
		end
		return nil
	end
	if sample.prevS == nil or sample.s <= sample.prevS then
		return nil
	end
	if sample.prevS < zone.LipS and sample.s >= zone.LipS then
		local onKicker = sample.lateral >= zone.LateralMin - 1 and sample.lateral <= zone.LateralMax + 1
		if onKicker and sample.speed >= cfg.MinTakeoffSpeed and sample.height >= cfg.MinTakeoffHeight then
			state.airborne = true
			state.takeoffTime = sample.time
			state.pressed = state.pressTime ~= nil and state.pressTime >= sample.time - cfg.EarlyPressSeconds
			state.pressTime = nil -- consumed by this takeoff
			return "Takeoff"
		end
	end
	return nil
end

-- A Trick press at time `now`. Returns "Accepted" | "Pending" | "Duplicate" | "TooLate".
function SkillRules.TrickPress(state, now, cfg)
	if state.airborne then
		if state.pressed then
			return "Duplicate"
		end
		if now - state.takeoffTime <= cfg.LatePressSeconds then
			state.pressed = true
			return "Accepted"
		end
		return "TooLate"
	end
	state.pressTime = now
	return "Pending"
end

---------------------------------------------------------------------------------------------
-- Near miss: one judgement per approach to a hazard
---------------------------------------------------------------------------------------------
-- state: { inApproach, minGap, hit, dangerousAtMin }. Returns "Hit" | "NearMiss" | nil.
function SkillRules.NearMissStep(state, distance, contactDistance, dangerous, cfg)
	if distance <= cfg.ApproachRadius then
		if not state.inApproach then
			state.inApproach, state.minGap, state.hit, state.dangerousAtMin = true, math.huge, false, false
		end
		local gap = distance - contactDistance
		if gap <= 0 then
			if not state.hit then
				state.hit = true
				return "Hit"
			end
			return nil
		end
		if gap < state.minGap then
			state.minGap = gap
			state.dangerousAtMin = dangerous
		end
		return nil
	end
	if state.inApproach then
		state.inApproach = false
		if not state.hit and state.minGap <= cfg.Band and state.dangerousAtMin then
			return "NearMiss"
		end
	end
	return nil
end

-- A6 Perfect Dodge: an approach to a moving hazard (centre distance <= cfg.ApproachRadius) whose
-- closest clearance stayed within cfg.Band without any contact. One verdict per approach.
-- Returns "PerfectDodge" | "Hit" | nil. clearance = nil means "not level with the hazard".
function SkillRules.DodgeStep(state, centreDistance, clearance, cfg)
	if centreDistance <= cfg.ApproachRadius then
		if not state.inApproach then
			state.inApproach, state.minGap, state.hit = true, math.huge, false
		end
		if clearance then
			if clearance <= 0 then
				if not state.hit then
					state.hit = true
					return "Hit"
				end
				return nil
			end
			state.minGap = math.min(state.minGap, clearance)
		end
		return nil
	end
	if state.inApproach then
		state.inApproach = false
		if not state.hit and state.minGap <= cfg.Band then
			return "PerfectDodge"
		end
	end
	return nil
end

return SkillRules
