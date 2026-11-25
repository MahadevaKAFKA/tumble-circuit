--[[
	TrackValidation.spec (A4) — the Neon Foundry against the module contract and the validator:
	module count and ports, route length, checkpoint order, hazard sockets, grid slots, self-
	clearance of the generated ribbon, distance from the hub, and mutation tests proving the
	validator actually catches broken definitions. Pure; offline and Studio.
]]

local Spec = {}

local function deepCopy(t)
	if type(t) ~= "table" or getmetatable(t) ~= nil then
		return t -- datatypes (Vector3 etc.) are immutable: share them
	end
	local out = {}
	for k, v in pairs(t) do
		out[k] = deepCopy(v)
	end
	return out
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
	local TD, TV = m.TrackDefinitions, m.TrackValidator
	local radius = m.PhysicsConfig.Ball.Radius
	local def = TD.Race
	local layout = TD.Generate(def, radius)

	check("the race track is the Neon Foundry", def == TD.NeonFoundry)
	local errors = TV.Validate(def, layout)
	check("Neon Foundry passes TrackValidator with 0 errors", #errors == 0, table.concat(errors, " | "))
	check("12-16 modules", #layout.Modules >= 12 and #layout.Modules <= 16, #layout.Modules)

	local portsOk, portDetail = true, nil
	for i = 1, #layout.Modules - 1 do
		local a, b = layout.Modules[i], layout.Modules[i + 1]
		if (a.Exit.Position - b.Entry.Position).Magnitude > 0.01 or a.Exit.Forward:Dot(b.Entry.Forward) < 0.9999 then
			portsOk, portDetail = false, a.Name .. "->" .. b.Name
		end
	end
	check("every module exit meets the next entry (no gap, same facing)", portsOk, portDetail)

	local metaOk = true
	for _, mod in ipairs(layout.Modules) do
		if not (mod.RouteLength and mod.RouteLength > 0 and mod.Entry.Width and mod.Exit.Width and mod.ElevationDelta) then
			metaOk = false
		end
	end
	check("module metadata: route length, widths, elevation delta present", metaOk)

	local total = layout.Route.total
	check("route length inside 1500-3500 studs", total >= 1500 and total <= 3500, total)

	local cpOk, prev = #layout.Checkpoints >= 5, -1
	for _, cp in ipairs(layout.Checkpoints) do
		if not cp.S or cp.S <= prev or not cp.RespawnFrame then
			cpOk = false
		end
		prev = cp.S or prev
	end
	check("checkpoints strictly ordered along the route, each with a respawn frame", cpOk and prev < layout.FinishLineS)
	local gapOk, worst = true, 0
	local last = layout.StartLineS
	for _, cp in ipairs(layout.Checkpoints) do
		worst = math.max(worst, cp.S - last)
		last = cp.S
	end
	worst = math.max(worst, layout.FinishLineS - last)
	gapOk = worst <= 650
	check("no checkpoint gap longer than 650 studs (recovery never costs a huge chunk)", gapOk, string.format("%.0f", worst))

	check("8-20 grid slots", #layout.GridSlots >= 8 and #layout.GridSlots <= 20, #layout.GridSlots)
	check("3-4 chaos gates", #layout.ChaosGates >= 3 and #layout.ChaosGates <= 4, #layout.ChaosGates)
	local kinds = {}
	for _, hz in ipairs(layout.Hazards) do
		kinds[hz.Kind] = true
	end
	check("hazard variety: bumper, sweeper, hammer, tiles, fan, conveyor, trampoline", kinds.PulseBumper and kinds.Sweeper and kinds.Hammer and kinds.Tiles and kinds.Fan and kinds.Conveyor and kinds.Trampoline)

	-- ribbon self-clearance: sections far apart along the route never overlap in space
	local clashes = 0
	local secs = layout.Sections
	for i = 1, #secs, 2 do
		for j = i + 1, #secs, 2 do
			local a, b = secs[i], secs[j]
			if math.abs(a.S - b.S) > 80 then
				local d = a.Position - b.Position
				local horizontal = math.sqrt(d.X * d.X + d.Z * d.Z)
				if horizontal < (a.Width + b.Width) / 2 + 8 and math.abs(d.Y) < 18 then
					clashes = clashes + 1
				end
			end
		end
	end
	check("generated track never passes through itself", clashes == 0, clashes)
	local hub = TD.Hub
	local nearest = math.huge
	for _, sec in ipairs(secs) do
		local d = sec.Position - hub.Center
		if math.abs(d.Y) < 80 then
			nearest = math.min(nearest, math.sqrt(d.X * d.X + d.Z * d.Z))
		end
	end
	check("race course stays clear of the hub platform", nearest > hub.Radius + 60, string.format("%.0f", nearest))

	-- split lanes: progress is projection onto the centreline, so two marbles level with each
	-- other in the inside and outside lanes get the same route distance (no lane bias)
	local split = layout.PieceByName.SplitCurve
	local worstBias = 0
	for at = 10, split.Definition.Length - 10, 15 do
		local f = TD.SampleAtH(layout, split.StartH + at)
		local inside = m.RouteTracker.new(layout.Route)
		local outside = m.RouteTracker.new(layout.Route)
		local lift = f.Up * radius
		-- warm both trackers up along the approach, as a real marble would be tracked
		for k = 30, 1, -5 do
			local g = TD.SampleAtH(layout, split.StartH + at - k)
			inside:Update(g.Position + g.Right * 8.5 + g.Up * radius)
			outside:Update(g.Position - g.Right * 8.5 + g.Up * radius)
		end
		local si = inside:Update(f.Position + f.Right * 8.5 + lift).s
		local so = outside:Update(f.Position - f.Right * 8.5 + lift).s
		worstBias = math.max(worstBias, math.abs(si - so))
	end
	check("split lane: inside and outside marbles level with each other get the same progress (+-2 studs)", worstBias <= 2, string.format("%.2f", worstBias))

	-- mutation tests: the validator must catch these
	local function mutated(fn)
		local copy = deepCopy(def)
		fn(copy)
		return TV.Validate(copy, TD.Generate(copy, radius))
	end
	local function hazard(copy, id)
		for _, hz in ipairs(copy.Hazards) do
			if hz.Id == id then
				return hz
			end
		end
	end
	check("mutation: hammer swinging out of the lane is rejected", #mutated(function(c)
		hazard(c, "Hammer1").Amplitude = 14
	end) > 0)
	check("mutation: impassable falling-tile pattern is rejected", #mutated(function(c)
		local tiles = hazard(c, "Tiles1")
		tiles.DropSeconds = tiles.Period * 0.9
		tiles.TelegraphSeconds = 0.05
	end) > 0)
	check("mutation: unknown hazard kind is rejected", #mutated(function(c)
		table.insert(c.Hazards, { Kind = "Laser", Id = "Laser1", Piece = "RestA", At = 5 })
	end) > 0)
	check("mutation: a split-lane divider that never rejoins is rejected", #mutated(function(c)
		for _, piece in ipairs(c.Pieces) do
			if piece.Divider then
				piece.Divider.To = piece.Length + 10
			end
		end
	end) > 0)
	check("mutation: too few grid slots is rejected", #mutated(function(c)
		c.Grid.Rows = { 26 }
	end) > 0)

	local est = TD.EstimateRunSeconds(layout, m.PhysicsConfig.Movement, 196.2 * (m.PhysicsConfig.GravityMultiplier or 1))
	table.insert(results.info, string.format("Neon Foundry: %d modules, %.0f studs, %d checkpoints, %d hazards, %d chaos gates", #layout.Modules, total, #layout.Checkpoints, #layout.Hazards, #layout.ChaosGates))
	table.insert(results.info, string.format("1-D MODEL perfect run (full throttle, no hazards/braking/steering losses) ~%.0f s -- not a measurement; target 90-150 s is a playtest item", est))
	return results
end

return Spec
