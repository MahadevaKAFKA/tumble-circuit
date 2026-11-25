--[[ Ability.spec — A3 ability config, cooldowns, Cooldown Charge lockout, non-stacking modifiers,
	Pulse falloff/targets and loadout validation (pure). ]]

local Spec = {}

function Spec.run(m)
	local r = { passed = 0, failed = 0, lines = {}, info = {} }
	local function check(name, ok, detail)
		r[ok and "passed" or "failed"] = r[ok and "passed" or "failed"] + 1
		table.insert(r.lines, (ok and "PASS  " or "FAIL  ") .. name .. ((not ok and detail) and ("  -- " .. tostring(detail)) or ""))
	end
	local AC, SR = m.AbilityConfig, m.SkillRules
	local A = AC.Abilities
	local terminal = m.PhysicsConfig.Movement.TerminalSpeed
	local envelope = terminal * m.RaceConfig.Validation.PlausibleSpeedFactor

	check("starter cooldowns 20 / 28 / 26 s", A.Boost.Cooldown == 20 and A.Shield.Cooldown == 28 and A.Pulse.Cooldown == 26)
	check("Boost +30% for 1.6 s; Shield 2.5 s; Pulse 12 studs / 18 studs/s", A.Boost.SpeedMultiplier == 1.3 and A.Boost.Duration == 1.6 and A.Shield.Duration == 2.5 and A.Pulse.Radius == 12 and A.Pulse.MaxDeltaV == 18)
	check("hard speed cap above terminal but inside the movement audit envelope", AC.HardSpeedCap > terminal and AC.HardSpeedCap < envelope, AC.HardSpeedCap .. " vs " .. envelope)
	check("Pulse impulse below the marble-bump cap", A.Pulse.MaxDeltaV <= m.RaceConfig.Collisions.MaxBumpDeltaV)
	check("default loadout Boost + Shield, 3 starters owned", AC.DefaultLoadout[1] == "Boost" and AC.DefaultLoadout[2] == "Shield" and #AC.StarterOwned == 3)

	check("ready only at/after the cooldown end", SR.IsReady(10, 10) and not SR.IsReady(9.99, 10) and SR.IsReady(0, nil))

	local state = { cooldowns = { [1] = 20, [2] = 8 }, lockoutUntil = 0 }
	local changed = SR.ApplyCharge(state, 10, 1.5, 3)
	check("charge removes 1.5 s from cooling slots only, never below now", changed and state.cooldowns[1] == 18.5 and state.cooldowns[2] == 8)
	local again = SR.ApplyCharge(state, 11, 1.5, 3)
	check("second charge inside the 3 s global lockout is refused", not again and state.cooldowns[1] == 18.5)
	local later = SR.ApplyCharge(state, 13.1, 1.5, 3)
	check("charge works again after the lockout", later and math.abs(state.cooldowns[1] - 17) < 1e-9)
	local edge = { cooldowns = { [1] = 10.5, [2] = 0 }, lockoutUntil = 0 }
	SR.ApplyCharge(edge, 10, 1.5, 3)
	check("charge clamps at now (no negative / past timestamps)", edge.cooldowns[1] == 10)
	local idle = { cooldowns = { [1] = 0, [2] = 0 }, lockoutUntil = 0 }
	local none = SR.ApplyCharge(idle, 50, 1.5, 3)
	check("nothing cooling: no change and lockout not consumed", not none and idle.lockoutUntil == 0)

	local mods = { Boost = { multiplier = 1.3, endsAt = 11.6 }, Trick = { multiplier = 1.15, endsAt = 11.2 }, Slip = { multiplier = 1.12 } }
	check("modifiers never stack: strongest active wins", SR.CurrentMultiplier(mods, 11) == 1.3)
	check("expired modifiers ignored; open-ended ones stay", SR.CurrentMultiplier(mods, 12) == 1.12)
	check("effective terminal respects the hard cap", SR.EffectiveTerminal(terminal, 1.3, AC.HardSpeedCap) == math.min(terminal * 1.3, AC.HardSpeedCap))

	check("Pulse 18 at centre, half at the edge, none outside", SR.PulseDeltaV(0, A.Pulse) == 18 and SR.PulseDeltaV(12, A.Pulse) == 9 and SR.PulseDeltaV(12.01, A.Pulse) == nil)
	local mono = true
	for d = 0, 11.5, 0.5 do
		if SR.PulseDeltaV(d + 0.5, A.Pulse) > SR.PulseDeltaV(d, A.Pulse) then
			mono = false
		end
	end
	check("Pulse falloff never increases with distance", mono)
	local origin = Vector3.new(0, 10, 0)
	local targets = SR.PulseTargets(origin, Vector3.new(0, 0, -1), {
		{ id = 1, position = Vector3.new(5, 10, 0) },
		{ id = 2, position = Vector3.new(0, 10, 30) },
		{ id = 3, position = Vector3.new(-3, 10, 0), protected = true },
		{ id = 4, position = Vector3.new(0, 10, 4), frozen = true },
		{ id = 5, position = Vector3.new(0, 10, 0) },
	}, A.Pulse)
	local ids, bounded = {}, true
	for _, t in ipairs(targets) do
		ids[#ids + 1] = t.id
		if t.deltaV > 18 or math.abs(t.direction.Magnitude - 1) > 1e-6 or math.abs(t.direction.Y) > 1e-9 then
			bounded = false
		end
	end
	table.sort(ids)
	check("Pulse targets: in radius only, skips protected/frozen", table.concat(ids, ",") == "1,5", table.concat(ids, ","))
	check("Pulse impulses bounded and horizontal unit directions (incl. zero offset)", bounded)

	local owned = AC.StarterOwned
	check("loadout: default valid", SR.ValidateLoadout({ "Boost", "Shield" }, owned, 2, A))
	check("loadout: duplicate rejected", not SR.ValidateLoadout({ "Boost", "Boost" }, owned, 2, A))
	check("loadout: unknown id rejected", not SR.ValidateLoadout({ "Boost", "Laser" }, owned, 2, A))
	check("loadout: wrong slot count rejected", not SR.ValidateLoadout({ "Boost" }, owned, 2, A))
	check("loadout: unowned rejected", not SR.ValidateLoadout({ "Boost", "Pulse" }, { "Boost", "Shield" }, 2, A))
	return r
end

return Spec
