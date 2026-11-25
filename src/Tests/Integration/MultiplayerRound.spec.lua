--[[
	MultiplayerRound.spec — Studio integration checks against the LIVE services
	(_G.TumbleCircuitServer, set by ServerBootstrap). Safe in Play Solo and in the Test tab's
	multi-client server. It never forges remotes from a client (impossible from the server); it
	exercises server entry points directly and observes the round for a while.

	run(ctx) returns immediate results; observe(ctx, seconds) logs the state timeline afterwards.
]]

local Players = game:GetService("Players")

local Spec = {}

function Spec.run(ctx)
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
	local server = _G.TumbleCircuitServer
	check("server services published for tests", server ~= nil)
	if not server then
		return results
	end
	local RP = ctx.RoundProtocol
	local round = server.round

	local remotes = server.remotes
	local names = {}
	for _, child in ipairs(remotes:GetChildren()) do
		if not child:IsA("RemoteEvent") then
			names[#names + 1] = "non-RemoteEvent " .. child.Name
		end
	end
	local expectedCount = 0
	for name in pairs(RP.Remotes) do
		expectedCount = expectedCount + 1
		if not remotes:FindFirstChild(name) then
			names[#names + 1] = "missing " .. name
		end
	end
	check("remotes folder matches RoundProtocol exactly", #names == 0 and #remotes:GetChildren() == expectedCount, table.concat(names, ", "))

	local snap = round:GetSnapshot()
	check("snapshot carries protocol version, round id, state, seq", snap.v == RP.Version and type(snap.roundId) == "number" and RP.States[snap.state] ~= nil and type(snap.stateSeq) == "number")
	check("round left Boot", snap.state ~= RP.States.Boot)
	if #Players:GetPlayers() > 0 then
		check("with a human present the round is not stuck in Lobby", snap.state ~= RP.States.Lobby, snap.state)
	end

	-- Idempotent / illegal transitions are refused without side effects.
	local seq = round.stateSeq
	local accepted = round:_transition(round.state)
	check("same-state transition is a no-op", accepted == false and round.stateSeq == seq)
	local illegal = round:_transition(round.state == RP.States.Racing and RP.States.Lobby or RP.States.Racing)
	check("illegal transition refused", illegal == false and round.stateSeq == seq)

	-- Hub geometry and gate
	check("hub and practice chute exist", workspace:FindFirstChild("OrbitalGarage") ~= nil and workspace.OrbitalGarage:FindFirstChild("PracticeChute") ~= nil)
	local gate = workspace:FindFirstChild("TrainingCourse") and workspace.TrainingCourse:FindFirstChild("Gates") and workspace.TrainingCourse.Gates:FindFirstChild("StartGate")
	check("start gate exists", gate ~= nil)
	if gate and snap.state ~= RP.States.Racing then
		check("start gate closed outside Racing", gate.CanCollide == true)
	end

	-- A4 services
	check("A4 services published (hazards, bots, chaos gates, perf)", server.hazards ~= nil and server.bots ~= nil and server.chaos ~= nil and server.perf ~= nil)
	check("snapshot carries hazard seed class + epoch", type(snap.hazardSeed) == "number" and snap.hazardSeed >= 0 and snap.hazardSeed <= 2 and type(snap.hazardEpoch) == "number")
	if round.state ~= RP.States.Preparing and round.state ~= RP.States.Countdown and round.state ~= RP.States.Racing and round.state ~= RP.States.Results then
		check("no bots exist outside a round", server.bots:Count() == 0, server.bots:Count())
	end
	local botBalls = 0
	for _, child in ipairs(workspace:WaitForChild("TumbleMarbles"):GetChildren()) do
		if child:GetAttribute("IsBot") then
			botBalls = botBalls + 1
			check("bot marble " .. child.Name .. " is labelled [BOT] and in the race zone", child:FindFirstChild("Nameplate") ~= nil and child:GetAttribute("Zone") == "Race")
		end
	end
	check("bot marbles == bot records", botBalls <= server.bots:Count(), botBalls .. " vs " .. server.bots:Count())

	-- A5 persistence (Studio: mock unless the owner opted into a live test store)
	check("A5 services published (playerData, economy, dev)", server.playerData ~= nil and server.economy ~= nil and server.dev ~= nil)
	check("Studio profiles use the MOCK store unless explicitly configured", server.playerData:GetMode() == "Mock" or require(game:GetService("ReplicatedStorage").Shared.GameConfig).Persistence.StudioMode == "Live", server.playerData:GetMode())
	for _, player in ipairs(Players:GetPlayers()) do
		local profile = server.playerData:GetProfile(player)
		check(player.Name .. ": profile loaded (status " .. tostring(profile and profile.status) .. ")", profile ~= nil and profile.status ~= "Loading" or false)
	end
	check("DevCommand exists only because this is Studio", remotes:FindFirstChild("DevCommand") ~= nil)

	for _, player in ipairs(Players:GetPlayers()) do
		local ball = server.marbles:GetBall(player)
		if ball then
			check(player.Name .. ": marble has a zone", ball:GetAttribute("Zone") == "Hub" or ball:GetAttribute("Zone") == "Race")
			-- recover is refused while frozen on the grid
			if round.state == RP.States.Countdown and round.racerByPlayer[player] then
				check(player.Name .. ": recover refused during countdown", round:HandleRecover(player) == false)
			end
		end
	end
	return results
end

-- Logs every transition for `seconds` so the owner can compare against TEST_PLAN expectations.
function Spec.observe(ctx, seconds, report)
	local server = _G.TumbleCircuitServer
	if not server then
		return
	end
	local started = os.clock()
	local timeline = {}
	local connection
	connection = server.round.StateChanged:Connect(function(state, snapshot)
		local bots, botBalls = 0, 0
		for _, entry in ipairs(snapshot.racers) do
			if entry.isBot then
				bots = bots + 1
			end
		end
		for _, child in ipairs(workspace.TumbleMarbles:GetChildren()) do
			if child:GetAttribute("IsBot") then
				botBalls = botBalls + 1
			end
		end
		-- A4 leak check: instance count at every Intermission should stay flat across rounds
		table.insert(timeline, string.format("%6.1fs %s (round %d, racers %d, bots %d, bot marbles %d, hazard seed %d, instances %d)", os.clock() - started, state, snapshot.roundId, #snapshot.racers, bots, botBalls, snapshot.hazardSeed or -1, #workspace:GetDescendants()))
	end)
	task.delay(seconds, function()
		connection:Disconnect()
		report(timeline)
	end)
end

return Spec
