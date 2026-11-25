--[[
	ReadyVote.spec (A4, owner request 2026-11-25) — pure rules for the READY vote:
	  * the race is "full" at min(grid slots, server size) queued players (override for tests)
	  * the vote is closed (timer + "Waiting for players") until the race is full
	  * once open, the race starts early only when every queued player is READY
	  * RequestReady accepts exactly one boolean and is rate limited
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
	local RR, RP, RC = m.RaceRules, m.RoundProtocol, m.RaceConfig

	local grid = #m.TrackDefinitions.Generate(m.TrackDefinitions.Race, m.PhysicsConfig.Ball.Radius).GridSlots
	check("race capacity = grid slots on a big server", RR.RaceCapacity(grid, 50, 0) == grid, RR.RaceCapacity(grid, 50, 0))
	check("race capacity = server size when the server is smaller than the grid", RR.RaceCapacity(16, 8, 0) == 8)
	check("race capacity ignores an unknown server size", RR.RaceCapacity(16, 0, 0) == 16)
	check("test override replaces capacity", RR.RaceCapacity(16, 50, 1) == 1)
	check("shipping config has no capacity override", RC.Ready.Enabled == true and (RC.Ready.CapacityOverride or 0) == 0)

	local solo = RR.ReadyVote(1, 1, grid)
	check("1 player of " .. grid .. ": vote closed, no early start (timer + Waiting for players)", not solo.open and not solo.allReady)
	local almost = RR.ReadyVote(grid - 1, grid - 1, grid)
	check("one slot still free: vote closed", not almost.open and not almost.allReady)
	local full = RR.ReadyVote(grid, grid - 1, grid)
	check("race full, one player not READY: vote open, no start", full.open and not full.allReady and full.ready == grid - 1)
	local go = RR.ReadyVote(grid, grid, grid)
	check("race full and everyone READY: start now", go.open and go.allReady)
	local overflow = RR.ReadyVote(grid + 4, grid, grid)
	check("more queued than slots: every queued player must be READY", overflow.open and not overflow.allReady)
	check("nobody queued: never open", not RR.ReadyVote(0, 0, 1).open)
	check("ready count never exceeds queued", RR.ReadyVote(3, 5, 3).ready == 3)

	local validation = true
	local cases = {
		{ { true }, true },
		{ { false }, true },
		{ {}, false },
		{ { 1 }, false },
		{ { "yes" }, false },
		{ { true, true }, false },
	}
	for _, case in ipairs(cases) do
		local ok = RP.ValidateArgs("RequestReady", table.unpack(case[1]))
		if (ok and true or false) ~= case[2] then
			validation = false
		end
	end
	check("RequestReady accepts exactly one boolean", validation)
	local spec = RP.Remotes.RequestReady
	check("RequestReady is client->server and rate limited", spec and spec.Direction == "ClientToServer" and (spec.MinInterval or 0) > 0)
	return results
end

return Spec
