--[[ AbilitySecurity.spec — malformed / forged A3 requests are rejected by schema (pure). The
	server additionally re-checks racer/state/cooldown; those paths need Studio (TEST_PLAN §6). ]]

local Spec = {}

function Spec.run(m)
	local r = { passed = 0, failed = 0, lines = {}, info = {} }
	local function check(name, ok, detail)
		r[ok and "passed" or "failed"] = r[ok and "passed" or "failed"] + 1
		table.insert(r.lines, (ok and "PASS  " or "FAIL  ") .. name .. ((not ok and detail) and ("  -- " .. tostring(detail)) or ""))
	end
	local V = m.RoundProtocol.ValidateArgs
	local nan = 0 / 0
	local cases = {
		{ "RequestAbility", { 1 }, true },
		{ "RequestAbility", { 2 }, true },
		{ "RequestAbility", { 3 }, false },
		{ "RequestAbility", { 0 }, false },
		{ "RequestAbility", { 1.5 }, false },
		{ "RequestAbility", { "1" }, false },
		{ "RequestAbility", { nan }, false },
		{ "RequestAbility", { math.huge }, false },
		{ "RequestAbility", {}, false },
		{ "RequestAbility", { 1, "Pulse" }, false },
		{ "RequestTrick", {}, true },
		{ "RequestTrick", { true }, false },
		{ "RequestEquip", { 1, "Boost" }, true },
		{ "RequestEquip", { 2, "Pulse" }, true },
		{ "RequestEquip", { 3, "Boost" }, false },
		{ "RequestEquip", { 1, string.rep("x", 17) }, false },
		{ "RequestEquip", { 1, 5 }, false },
		{ "RequestEquip", { "Boost", 1 }, false },
		{ "AbilityOutcome", {}, false },
		{ "ApplyImpulse", {}, false },
	}
	local bad = {}
	for _, case in ipairs(cases) do
		local ok = V(case[1], table.unpack(case[2]))
		if ok ~= case[3] then
			bad[#bad + 1] = case[1] .. "(" .. #case[2] .. " args)"
		end
	end
	check("A3 payload schema rejects every malformed / out-of-range / server-only call", #bad == 0, table.concat(bad, ", "))

	local constrained = true
	for name, spec in pairs(m.RoundProtocol.Remotes) do
		if spec.Direction == "ClientToServer" then
			for _, arg in ipairs(spec.Args) do
				local rule = type(arg) == "table" and arg or { type = arg }
				local unboundedNumber = rule.type == "number" and not (rule.oneOf or (rule.min and rule.max))
				local unboundedString = rule.type == "string" and not (rule.maxLength or rule.oneOf)
				local otherType = rule.type ~= "number" and rule.type ~= "string" and rule.type ~= "boolean"
				if unboundedNumber or unboundedString or otherType then
					constrained = false
				end
			end
		end
	end
	check("every client argument is bounded (numbers enumerated or ranged, strings length-capped, no tables)", constrained)
	local noTargets = true
	for name in pairs(m.RoundProtocol.Remotes) do
		local lower = string.lower(name)
		if m.RoundProtocol.Remotes[name].Direction == "ClientToServer" and (string.find(lower, "target") or string.find(lower, "position") or string.find(lower, "impulse") or string.find(lower, "cooldown")) then
			noTargets = false
		end
	end
	check("no client remote can name targets, positions, impulses or cooldowns", noTargets)
	check("protocol version bumped for A3", m.RoundProtocol.Version >= 3)
	return r
end

return Spec
