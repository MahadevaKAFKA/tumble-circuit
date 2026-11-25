--[[
	B2Abilities.spec — the nine play-earned abilities: config vs the pack, unlock rules, pure
	judgement (frost lane, magnet, grapple, reverse jet), profile v2, and (offline) the shared
	motor's statuses.
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
	local AC, AR, Schema = m.AbilityConfig, m.AbilityRules, m.PlayerDataSchema
	local A = AC.Abilities
	------------------------------------------------------------------ config vs pack
	local cds = { FrostWake = 32, Magnet = 30, Phase = 38, GrappleSpark = 30, BounceBurst = 22, GravityGlide = 35, ReverseJet = 28, Decoy = 40, Anchor = 30 }
	local okCd = true
	for id, cd in pairs(cds) do
		if not A[id] or A[id].Cooldown ~= cd then
			okCd = false
		end
	end
	check("nine abilities with the pack's cooldowns (32/30/38/30/22/35/28/40/30)", okCd)
	check("pack numbers: frost lane 10 studs 2.2 s -25% 1.2 s; magnet 10 studs 1.5 s; phase 1.5 s; grapple 24 studs", A.FrostWake.LaneWidth == 10 and A.FrostWake.Duration == 2.2 and A.FrostWake.SteerMultiplier == 0.75 and A.FrostWake.ChillSeconds == 1.2 and A.Magnet.Radius == 10 and A.Magnet.Duration == 1.5 and A.Phase.Duration == 1.5 and A.GrappleSpark.Range == 24)
	check("pack numbers: bounce window 2 s; glide -35% 2.5 s; reverse jet 16 studs/s; decoy 3 s; anchor 70% 2.5 s", A.BounceBurst.Window == 2 and A.GravityGlide.GravityReduction == 0.35 and A.GravityGlide.Duration == 2.5 and A.ReverseJet.DeltaV == 16 and A.Decoy.Duration == 3 and math.abs(A.Anchor.KnockbackScale - 0.3) < 1e-9 and A.Anchor.Duration == 2.5)
	local tiers, okTier = {}, true
	for _, id in ipairs(AC.Order) do
		local u = A[id].Unlock
		if u then
			tiers[u.Coins] = (tiers[u.Coins] or 0) + 1
			if u.Coins ~= 800 and u.Coins ~= 1200 and u.Coins ~= 1600 then
				okTier = false
			end
		end
	end
	check("unlock costs are the three tiers 800/1200/1600 (3 each), earned Coins only", okTier and tiers[800] == 3 and tiers[1200] == 3 and tiers[1600] == 3)
	check("12 abilities in menu order, starters first, no unlock on starters", #AC.Order == 12 and AC.Order[1] == "Boost" and A.Boost.Unlock == nil and A.Shield.Unlock == nil and A.Pulse.Unlock == nil)
	local same = #Schema.KnownAbilities == #AC.Order
	for i, id in ipairs(AC.Order) do
		same = same and Schema.KnownAbilities[i] == id
	end
	check("profile schema knows exactly the twelve ability ids", same)
	check("no ability changes hitbox or mass (no Size/Mass/Density fields)", (function()
		for _, id in ipairs(AC.Order) do
			for key in pairs(A[id]) do
				if key == "Size" or key == "Mass" or key == "Density" or key == "Radius" and id ~= "Pulse" and id ~= "Magnet" then
					return false
				end
			end
		end
		return true
	end)())

	------------------------------------------------------------------ unlock rules
	local owned = { Boost = true, Shield = true, Pulse = true }
	local ok1, how1 = AC.UnlockState("Magnet", owned, 3, 0)
	check("level 3 unlocks a tier-1 ability for free", ok1 and how1 == "Level")
	local ok2, how2, cost2 = AC.UnlockState("Phase", owned, 2, 1600)
	check("1600 Coins unlock a tier-3 ability before its level", ok2 and how2 == "Coins" and cost2 == 1600)
	local ok3, how3, why3 = AC.UnlockState("Phase", owned, 9, 1599)
	check("not enough level or Coins: refused with the reason", not ok3 and how3 == "Locked" and type(why3) == "string")
	check("owned abilities report Owned; unknown ids refused", select(2, AC.UnlockState("Boost", owned, 1, 0)) == "Owned" and not AC.UnlockState("Laser", owned, 50, 1e9))
	local LP = m.LoadoutPure
	if LP and LP.CardState then
		local o1, lock1, label1 = LP.CardState("Decoy", owned, 1, 0)
		local _, _, label2 = LP.CardState("Decoy", owned, 1, 5000)
		local _, _, label3 = LP.CardState("Decoy", owned, 12, 0)
		check("menu card: locked text, coin unlock, free unlock at level", not o1 and lock1 == "LOCKED - LV 10" and label1 == "LV 10 or 1600 COINS" and label2 == "UNLOCK  1600 COINS" and label3 == "UNLOCK (FREE)")
	end

	------------------------------------------------------------------ pure judgement
	local lane = AR.FrostLane(500, 2, A.FrostWake, 100)
	check("frost lane: 24 studs behind the caster, 10 wide", lane.fromS == 476 and lane.toS == 500 and lane.halfWidth == 5)
	check("frost lane catches a rival inside it", AR.InFrostLane(lane, 490, 5, 101, 7))
	check("not outside it (laterally / along / after 2.2 s)", not AR.InFrostLane(lane, 490, 8, 101, 7) and not AR.InFrostLane(lane, 470, 2, 101, 7) and not AR.InFrostLane(lane, 490, 2, 102.3, 7))
	lane.chilled[7] = true
	check("one chill per rival per lane", not AR.InFrostLane(lane, 490, 2, 101, 7))
	local cands = {
		{ id = 1, position = Vector3.new(5, 0, 0) },
		{ id = 2, position = Vector3.new(15, 0, 0) },
		{ id = 3, position = Vector3.new(0, 0, 4), protected = true },
		{ id = 4, position = Vector3.new(-3, 0, 0), frozen = true },
	}
	local pulls = AR.MagnetPulls(Vector3.new(0, 0, 0), cands, A.Magnet, {})
	check("magnet pulls only rivals within 10 studs, never protected / frozen", #pulls == 1 and pulls[1].id == 1 and pulls[1].direction.X < -0.99)
	local total = 0
	local given = {}
	for _ = 1, 5 do
		for _, p in ipairs(AR.MagnetPulls(Vector3.new(0, 0, 0), { cands[1] }, A.Magnet, given)) do
			given[p.id] = (given[p.id] or 0) + p.deltaV
			total = total + p.deltaV
		end
	end
	check("magnet displacement capped (total pull <= 9 studs/s)", total <= A.Magnet.MaxTotalDeltaV + 1e-9 and total > 0, total)
	local anchors = { { S = 90, Position = Vector3.new(0, 10, -90) }, { S = 120, Position = Vector3.new(0, 10, -120) }, { S = 140, Position = Vector3.new(0, 10, -140) } }
	local target = AR.GrappleTarget(anchors, 100, Vector3.new(0, 2, -100), 200, 24)
	check("grapple: nearest anchor AHEAD within 24 studs", target and target.S == 120)
	check("grapple: never past the next checkpoint", AR.GrappleTarget(anchors, 100, Vector3.new(0, 2, -100), 110, 24) == nil)
	check("grapple: blocked line of sight -> no target", AR.GrappleTarget(anchors, 100, Vector3.new(0, 2, -100), 200, 24, function()
		return false
	end) == nil)
	local dir, dv = AR.GrappleImpulse(Vector3.new(0, 2, -100), anchors[2], A.GrappleSpark)
	check("grapple impulse bounded by 20 studs/s", dv <= 20 and dir.Z < -0.9)
	local rdir, rdv = AR.ReverseJet(Vector3.new(0, -0.5, -1).Unit, A.ReverseJet)
	check("reverse jet: horizontal, backwards, exactly 16 studs/s", rdv == 16 and rdir.Y == 0 and rdir.Z > 0.99)
	local statuses = AR.ActiveStatuses({ Anchor = { endsAt = 10, knockbackScale = 0.3 }, Phase = { endsAt = 5 } }, 6)
	check("status list drops expired effects", #statuses == 1 and statuses[1].kind == "Anchor" and statuses[1].knockbackScale == 0.3)

	------------------------------------------------------------------ profile v2
	local migrated = Schema.Migrate({ schemaVersion = 1, coins = 900, xp = 0, equippedAbilityIds = { "Boost", "Pulse" } })
	check("v1 -> v2: earned values kept, ownedAbilityIds added", migrated.schemaVersion == Schema.Version and migrated.coins == 900 and type(migrated.ownedAbilityIds) == "table" and #migrated.ownedAbilityIds == 0)
	local hostile = Schema.Migrate({ schemaVersion = 2, ownedAbilityIds = { "Magnet", "Magnet", "Laser", 5 }, equippedAbilityIds = { "Magnet", "Phase" } })
	check("v2 sanitizing: duplicates / unknown ids dropped; any known pair may be equipped", #hostile.ownedAbilityIds == 1 and hostile.ownedAbilityIds[1] == "Magnet" and hostile.equippedAbilityIds[1] == "Magnet")

	------------------------------------------------------------------ motor statuses (offline harness)
	if m.MotorHarness then
		local function step(statuses, steer, velocity, grounded)
			local motor, ball, force, Motor = m.MotorHarness.new()
			ball.AssemblyLinearVelocity = velocity or Vector3.new(0, 0, 0)
			motor:SetEffects({ modifiers = {}, statuses = statuses, hardCap = 96 })
			motor:Step(1 / 60, { mode = Motor.Modes.Play, steer = steer or Vector2.new(0, 0), forwardH = Vector3.new(1, 0, 0), brake = false, brakePressed = false })
			return force.Force, motor, ball
		end
		local far = 1e12
		local plain = step({}, Vector2.new(1, 0))
		local chilled = step({ { kind = "Chilled", endsAt = far, steer = 0.75 } }, Vector2.new(1, 0))
		check("Chilled: steering push reduced to 75%", chilled.Z < plain.Z and math.abs(chilled.Z / plain.Z - 0.75) < 0.02, string.format("%.1f vs %.1f", chilled.Z, plain.Z))
		local glide = step({ { kind = "GravityGlide", endsAt = far, gravityReduction = 0.35, steer = 1.2 } }, Vector2.new(0, 0))
		local g = (m.FakeGravity or 196.2)
		check("Gravity Glide: lifts exactly 35% of gravity (never more)", math.abs(glide.Y - g * 0.35) < 0.5, glide.Y)
		local _, motor, ball = step({ { kind = "Anchor", endsAt = far, knockbackScale = 0.3 } })
		local impulses = {}
		ball.ApplyImpulse = function(_, v)
			impulses[#impulses + 1] = v
		end
		motor:ApplyExternalImpulse(Vector3.new(1, 0, 0), 18, 18)
		check("Anchor: incoming impulse scaled to 30%", #impulses == 1 and math.abs(impulses[1].X - 18 * 0.3) < 1e-6)
		local _, motor2, ball2 = step({ { kind = "BounceBurst", endsAt = far, upDeltaV = 18 } })
		local ups = {}
		ball2.ApplyImpulse = function(_, v)
			ups[#ups + 1] = v
		end
		motor2:ApplyKick(Vector3.new(1, 0, 0), 30)
		motor2:ApplyKick(Vector3.new(1, 0, 0), 60)
		local upCount = 0
		for _, v in ipairs(ups) do
			if v.Y > 0 then
				upCount = upCount + 1
			end
		end
		check("Bounce Burst: one bounded upward bounce on the next hit, only once", upCount == 1)
	end
	return results
end

return Spec
