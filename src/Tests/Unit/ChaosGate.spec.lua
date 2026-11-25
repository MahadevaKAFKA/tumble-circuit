--[[
	ChaosGate.spec (A4) — tiers for 1, 2, 8 and 12 racers (top-three precedence, then bottom
	half, then middle), one payout per gate per racer per round even when bouncing back and forth
	across the gate, lateral span enforcement, modifier/shield priority, the "no client remote can
	claim a gate" contract, and the bot fill rule. Uses ChaosGateService with fake dependencies.
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
	local CG, RP, RR = m.ChaosGateService, m.RoundProtocol, m.RaceRules

	-------------------------------------------------------------------- tiers
	local function tiers(count)
		local out = {}
		for place = 1, count do
			out[place] = CG.Tier(place, count):sub(1, 1)
		end
		return table.concat(out)
	end
	check("1 racer: top", tiers(1) == "T", tiers(1))
	check("2 racers: both top (top-three precedence beats bottom half)", tiers(2) == "TT", tiers(2))
	check("8 racers: 1-3 top, 4 middle, 5-8 bottom", tiers(8) == "TTTMBBBB", tiers(8))
	check("12 racers: 1-3 top, 4-6 middle, 7-12 bottom", tiers(12) == "TTTMMMBBBBBB", tiers(12))
	local T = CG.Tiers
	check("tier values match the spec (+8%/1s, +22%/2s+shield, +14%/1.5s)", T.Top.Multiplier == 1.08 and T.Top.Duration == 1 and T.Bottom.Multiplier == 1.22 and T.Bottom.Duration == 2 and T.Bottom.Shield > 0 and T.Middle.Multiplier == 1.14 and T.Middle.Duration == 1.5)

	-------------------------------------------------------------------- service with fakes
	local function signal()
		local handlers = {}
		return {
			Connect = function(_, fn)
				handlers[#handlers + 1] = fn
				return { Disconnect = function() end }
			end,
			Fire = function(_, ...)
				for _, fn in ipairs(handlers) do
					fn(...)
				end
			end,
		}
	end
	local gate = { Id = "Gate1", S = 500, Offset = 5, Width = 9 }
	local calls = { modifiers = {}, shields = {}, vfx = {} }
	local standings = {}
	local deps = {
		track = { GetLayout = function()
			return { ChaosGates = { gate } }
		end },
		physics = { Progress = signal() },
		round = {
			StateChanged = signal(),
			IsActiveRacer = function()
				return true
			end,
			GetStandings = function()
				return standings
			end,
		},
		abilities = {
			SetModifier = function(_, entity, kind, mult, duration)
				table.insert(calls.modifiers, { entity = entity, kind = kind, mult = mult, duration = duration })
			end,
			GrantShield = function(_, entity, seconds)
				table.insert(calls.shields, { entity = entity, seconds = seconds })
			end,
		},
		remotes = { ChaosGateVFX = { FireAllClients = function(_, data)
			table.insert(calls.vfx, data)
		end } },
	}
	local service = CG.new(deps)
	service:Start()
	local alice = { UserId = 1, Name = "alice" }
	local bot = { UserId = -1, Name = "[BOT] Bolt", isBot = true }
	for i = 1, 8 do
		standings[i] = { userId = i == 7 and 1 or (100 + i), place = i }
	end
	standings[8] = { userId = -1, place = 8 }
	local function sample(entity, prevS, s, lateral)
		deps.physics.Progress:Fire(entity, { zone = "Race", prevS = prevS, s = s, lateral = lateral })
	end
	sample(alice, 490, 502, 5) -- crosses inside the span
	sample(alice, 502, 497, 5) -- bounces back...
	sample(alice, 497, 505, 5) -- ...and across again
	check("gate pays once even when a marble bounces back and forth across it", #calls.modifiers == 1, #calls.modifiers)
	check("7th of 8 gets the bottom-half comeback surge + shield", calls.modifiers[1] and calls.modifiers[1].mult == 1.22 and #calls.shields == 1)
	check("surge uses the ChaosGate modifier slot (strongest-wins, never stacks)", calls.modifiers[1] and calls.modifiers[1].kind == "ChaosGate")
	sample(bot, 490, 505, -6) -- outside the half-lane span
	check("crossing the route distance outside the gate's lateral span pays nothing", #calls.modifiers == 1)
	sample(bot, 505, 520, 6)
	check("a bot can still collect it later only by actually passing through", #calls.modifiers == 1)
	deps.round.StateChanged:Fire(RP.States.Racing)
	sample(alice, 490, 502, 5)
	check("a new round resets collection (each gate once per round)", #calls.modifiers == 2)
	check("every payout is announced for VFX", #calls.vfx == #calls.modifiers)

	-------------------------------------------------------------------- contracts
	local claimable = false
	for name, spec in pairs(RP.Remotes) do
		if spec.Direction == "ClientToServer" and (name:find("Gate") or name:find("Chaos") or name:find("Surge")) then
			claimable = true
		end
	end
	check("no client remote can claim a gate (server-observed crossing only)", not claimable and RP.Remotes.ChaosGateVFX.Direction == "ServerToClient")
	check("bot fill: 0 humans -> no bots (bots never race alone)", RR.BotFillCount(0, 16, 8, true) == 0)
	check("bot fill: 1 human -> 7 bots, 7 -> 1, 8+ -> 0", RR.BotFillCount(1, 16, 8, true) == 7 and RR.BotFillCount(7, 16, 8, true) == 1 and RR.BotFillCount(8, 16, 8, true) == 0 and RR.BotFillCount(12, 16, 8, true) == 0)
	check("bot fill respects the grid size and the kill switch", RR.BotFillCount(1, 6, 8, true) == 5 and RR.BotFillCount(1, 16, 8, false) == 0)
	return results
end

return Spec
