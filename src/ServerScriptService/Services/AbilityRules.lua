--[[
	AbilityRules (B2) — pure judgement for the nine play-earned abilities. No Roblox APIs.
	Positions/progress always come from the server's own observations (RacePhysicsService),
	never from the client.
]]

local AbilityRules = {}

-- Frost Wake: a lane from (casterS - length) to casterS, centred on the caster's lateral offset.
function AbilityRules.FrostLane(casterS, casterLateral, def, now)
	return { fromS = casterS - def.LaneLength, toS = casterS, lateral = casterLateral, halfWidth = def.LaneWidth / 2, endsAt = now + def.Duration, chilled = {} }
end

-- Is a racer at (s, lateral) inside the lane and not yet chilled by it?
function AbilityRules.InFrostLane(lane, s, lateral, now, targetId)
	if not lane or now >= lane.endsAt or lane.chilled[targetId] then
		return false
	end
	return s >= lane.fromS and s <= lane.toS and math.abs(lateral - lane.lateral) <= lane.halfWidth
end

-- Magnet: rivals within radius (not protected / frozen); each gets a bounded pull toward the
-- caster. `pulled[id]` = total delta-v already given this activation (capped).
function AbilityRules.MagnetPulls(origin, candidates, def, pulled)
	local out = {}
	for _, c in ipairs(candidates) do
		local offset = origin - c.position
		local d = offset.Magnitude
		local given = pulled[c.id] or 0
		if d > 0.5 and d <= def.Radius and not c.protected and not c.frozen and given < def.MaxTotalDeltaV then
			local dv = math.min(def.DeltaVPerTick, def.MaxTotalDeltaV - given)
			local flat = Vector3.new(offset.X, 0, offset.Z)
			if flat.Magnitude > 0.1 then
				out[#out + 1] = { id = c.id, direction = flat.Unit, deltaV = dv }
			end
		end
	end
	return out
end

-- Grapple Spark: the nearest anchor AHEAD on the route (anchor.S > s), within range in a
-- straight line, and not past the next checkpoint. losClear(anchor) is the server raycast.
function AbilityRules.GrappleTarget(anchors, s, position, nextCheckpointS, range, losClear)
	local best, bestD = nil, math.huge
	for _, a in ipairs(anchors) do
		if a.S > s and (not nextCheckpointS or a.S <= nextCheckpointS) then
			local d = (a.Position - position).Magnitude
			if d <= range and d < bestD and (not losClear or losClear(a)) then
				best, bestD = a, d
			end
		end
	end
	return best, bestD
end

-- Grapple impulse: toward the anchor, bounded; never more than MaxDeltaV.
function AbilityRules.GrappleImpulse(position, anchor, def)
	local offset = anchor.Position - position
	if offset.Magnitude < 0.5 then
		return nil
	end
	return offset.Unit, math.min(def.MaxDeltaV, offset.Magnitude * 1.2)
end

-- Reverse Jet: straight back along the horizontal track direction, exactly def.DeltaV.
function AbilityRules.ReverseJet(tangent, def)
	local flat = Vector3.new(-tangent.X, 0, -tangent.Z)
	if flat.Magnitude < 1e-3 then
		return nil
	end
	return flat.Unit, def.DeltaV
end

-- Status list for the owner's motor (EffectState.statuses). Expired entries are dropped.
function AbilityRules.ActiveStatuses(statuses, now)
	local out = {}
	for kind, st in pairs(statuses) do
		if st.endsAt > now then
			local entry = { kind = kind, endsAt = st.endsAt }
			for k, v in pairs(st) do
				entry[k] = v
			end
			out[#out + 1] = entry
		end
	end
	table.sort(out, function(a, b)
		return a.kind < b.kind
	end)
	return out
end

return AbilityRules
