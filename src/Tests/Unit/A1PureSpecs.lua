--[[
	A1PureSpecs — self-contained assertions over the PURE modules (config ranges, utility math,
	course generation/validation, floor geometry, route tracking, hazard timing).

	Runs in two places with identical code:
	  * Studio: TestRunner.server.lua (Play Solo), output in the Output window
	  * Offline: tools/offline/run_tests.lua under texlua with a Roblox datatype shim
	Engine behaviour (physics feel, camera, input devices) is NOT covered here; see TEST_PLAN.md.
]]

local Specs = {}

function Specs.run(m)
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
	local function info(text)
		table.insert(results.info, text)
	end
	local function near(a, b, eps)
		return math.abs(a - b) <= (eps or 1e-6)
	end
	local function finite(x)
		return x == x and x ~= math.huge and x ~= -math.huge
	end

	local P, G, U = m.PhysicsConfig, m.GameConfig, m.Utility
	local mv = P.Movement

	-------------------------------------------------------------------- config
	check("ball is a 4-stud diameter sphere (radius 2)", P.Ball.Radius == 2)
	check("ball density within Roblox range", P.Ball.Density >= 0.01 and P.Ball.Density <= 100)
	check("ball friction/elasticity in [0,2]/[0,1]", P.Ball.Friction >= 0 and P.Ball.Friction <= 2 and P.Ball.Elasticity >= 0 and P.Ball.Elasticity <= 1)
	check("along-track accel positive and bounded", mv.AlongTrackAccel > 0 and mv.AlongTrackAccel <= 200)
	check("lateral cap below terminal speed", mv.LateralSpeedCap > 0 and mv.LateralSpeedCap < mv.TerminalSpeed)
	check("throttle target below terminal speed", mv.ThrottleTargetSpeed > 0 and mv.ThrottleTargetSpeed < mv.TerminalSpeed)
	check("air control within [0,1]", mv.AirControl >= 0 and mv.AirControl <= 1)
	check("brake target multiplier within (0,1)", mv.BrakeTargetSpeedMultiplier > 0 and mv.BrakeTargetSpeedMultiplier < 1)
	check("steer deadzone within [0,0.5)", mv.SteerDeadzone >= 0 and mv.SteerDeadzone < 0.5)
	check("rolling inertia compensation within [1,1.4]", mv.RollingInertiaCompensation >= 1 and mv.RollingInertiaCompensation <= 1.4 + 1e-9)
	check("gravity multiplier within spec window", P.GravityMultiplier >= 1 and P.GravityMultiplier <= 1.15)
	check("terminal drag can beat a 30-degree slope", mv.TerminalDragMax > 196.2 * P.GravityMultiplier * math.sin(math.rad(30)))
	-- zero-order-hold stability: each controller gain * frame time stays < 1 down to 15 FPS
	local worstGain = math.max(mv.LateralResponse, mv.BrakeResponse, mv.TerminalDragResponse, mv.LateralAssistDamping)
	check("controller gains stable down to 15 FPS (k*dt < 1)", worstGain / 15 < 1, "worst k = " .. worstGain)
	info(string.format(
		"tunables: accel %g, lateral cap %g, terminal %g, air %.0f%%, brake x%.2f, deadzone %.2f (spec hypotheses 35/22/80/40%%/0.65/0.12)",
		mv.AlongTrackAccel, mv.LateralSpeedCap, mv.TerminalSpeed, mv.AirControl * 100, mv.BrakeTargetSpeedMultiplier, mv.SteerDeadzone
	))

	local cam = G.Camera
	check("chase distance within 18-26", cam.Modes.Chase.Distance >= 18 and cam.Modes.Chase.Distance <= 26)
	check("wide distance within 18-26", cam.Modes.Wide.Distance >= 18 and cam.Modes.Wide.Distance <= 26)
	check("default FOV is 70", cam.FieldOfView == 70)
	check("camera pitch cap far from vertical (< 75 deg)", cam.MaxPitchDeg < 75 and cam.MinPitchDeg > 0)
	check("camera min distance clears the marble", cam.MinDistance > P.Ball.Radius * 2)
	check("recover hold is 1 second", G.Input.RecoverHoldSeconds == 1)
	check("touch buttons >= 44 px at minimum UI scale", G.UI.MinScale * G.UI.TouchSmallButtonSize >= 44)
	for _, name in ipairs({ "Navy", "Cyan", "Coral", "Yellow", "Violet", "Mint" }) do
		check("palette has " .. name, G.Palette[name] ~= nil)
	end

	local ids = m.PlaceholderIds
	local known = {}
	for _, key in ipairs(ids.KnownSoundKeys or {}) do
		known[key] = true
	end
	local idsOk, badId = true, nil
	for key, value in pairs(ids.Sounds or {}) do
		if not known[key] or type(value) ~= "string" or not string.match(value, "^rbxassetid://%d+$") then
			idsOk, badId = false, key
		end
	end
	check("placeholder sound ids are nil or well-formed (none invented)", idsOk, badId)

	local attrOk, seen = true, {}
	for _, name in pairs(m.Protocol.PlayerAttributes) do
		if #name > 50 or seen[name] then
			attrOk = false
		end
		seen[name] = true
	end
	check("attribute names unique and <= 50 chars", attrOk)

	-------------------------------------------------------------------- utility
	local rate, dt = 7, 1 / 30
	local twoSmall = 1 - (1 - U.expAlpha(rate, dt)) ^ 2
	check("exponential smoothing is frame-rate independent", near(twoSmall, U.expAlpha(rate, 2 * dt), 1e-12))
	local x0, y0 = U.radialDeadzone(0.1, 0, 0.12)
	local x1, y1 = U.radialDeadzone(0.6, 0.8, 0.12)
	check("deadzone zeroes small input", x0 == 0 and y0 == 0)
	check("deadzone rescales full deflection to 1", near(math.sqrt(x1 * x1 + y1 * y1), 1, 1e-9) and near(x1 / y1, 0.75, 1e-9))
	check("formatTime", U.formatTime(5.2) == "5.20" and U.formatTime(65.5) == "1:05.50" and U.formatTime(nil) == "--.--")
	local a = Vector3.new(0, 0, -1)
	local turned = U.turnToward(a, Vector3.new(0, 0, 1), 0.1)
	check("turnToward handles opposite vectors without NaN or flip", finite(turned.X) and turned:Dot(a) > 0.5)
	local sig = U.Signal.new()
	local hits = 0
	local failing = sig:Connect(function()
		error("deliberate test error (expected warning)")
	end)
	local conn = sig:Connect(function()
		hits = hits + 1
	end)
	sig:Fire()
	failing:Disconnect()
	conn:Disconnect()
	sig:Fire()
	check("signal isolates handler errors and disconnects", hits == 1)
	local fakeNow = 0
	local limiter = U.RateLimiter.new(0.75, function()
		return fakeNow
	end)
	local first = limiter:Try("p")
	fakeNow = 0.5
	local second = limiter:Try("p")
	fakeNow = 0.8
	local third = limiter:Try("p")
	check("rate limiter enforces the reset cooldown", first and not second and third)

	-------------------------------------------------------------------- course
	local TD = m.TrackDefinitions
	local def = TD.Training
	local layout = TD.Generate(def, P.Ball.Radius)
	local errors = TD.Validate(def, layout)
	check("training course validates", #errors == 0, table.concat(errors, "; "))
	local segments, seenSeg = 0, {}
	for _, piece in ipairs(def.Pieces) do
		if not seenSeg[piece.Segment] then
			seenSeg[piece.Segment] = true
			segments = segments + 1
		end
	end
	check("4-6 hand-built segments", segments >= 4 and segments <= 6, segments)
	check("deterministic generation", TD.Generate(def, P.Ball.Radius).Route.total == layout.Route.total)

	local maxGap, monotonic = 0, true
	for i = 2, #layout.Route.points do
		maxGap = math.max(maxGap, (layout.Route.points[i] - layout.Route.points[i - 1]).Magnitude)
		if layout.Route.cumulative[i] <= layout.Route.cumulative[i - 1] then
			monotonic = false
		end
	end
	check("route continuous (no gap > step + slack)", maxGap <= def.MaxStepLength * 1.2, maxGap)
	check("route distance strictly increasing", monotonic)
	local maxYaw = 0
	for i = 2, #layout.Sections do
		maxYaw = math.max(maxYaw, math.abs(math.deg(layout.Sections[i].HeadingRad - layout.Sections[i - 1].HeadingRad)))
	end
	check("curves subdivided (<= MaxYawStep per section)", maxYaw <= def.MaxYawStepDeg + 1e-6, maxYaw)

	local spawn = layout.SpawnFrame
	local spawnPos = spawn.Position + spawn.Up * (P.Ball.Radius + G.Spawn.SpawnLift)
	local padPiece = layout.PieceByName[def.Spawn.Piece]
	check("spawn sits on the practice pad", spawn.H >= padPiece.StartH and spawn.H <= padPiece.EndH)
	check("spawn clearance: marble bottom above floor", (spawnPos - spawn.Position):Dot(spawn.Up) - P.Ball.Radius >= 0.2)
	check("spawn has room each side", spawn.Width / 2 >= P.Ball.Radius * 4)

	local okSteer, worstTurn = true, 0
	local prev = nil
	local s = 0
	while s <= layout.Route.total do
		local t = m.RouteTracker.HorizontalTangentAtS(layout.Route, s)
		if not t then
			okSteer = false
		elseif prev then
			local d = math.max(-1, math.min(1, prev:Dot(t)))
			worstTurn = math.max(worstTurn, math.deg(math.acos(d)))
		end
		prev = t or prev
		s = s + 2
	end
	check("steering frame defined along the whole route (no vertical shaft flip)", okSteer)
	check("steering frame never jumps > 10 deg per 2 studs", worstTurn <= 10, string.format("%.2f deg", worstTurn))

	-- Smoothed (chord) heading used by the camera and the steering frame: defined everywhere, turns
	-- continuously, and stays on the curve (no lag) — owner playtest 2026-11-23: turns "jumped".
	local function angleDeg(a, b)
		return math.deg(math.acos(math.max(-1, math.min(1, a:Dot(b)))))
	end
	for _, use in ipairs({
		{ "camera", G.Camera.HeadingSmoothingStuds },
		{ "steering frame", mv.SteerFrameSmoothingStuds },
	}) do
		local okSmooth, worstStep, worstDev, prevSmooth = true, 0, 0, nil
		s = 0
		while s <= layout.Route.total do
			local smooth = m.RouteTracker.SmoothHorizontalTangentAtS(layout.Route, s, use[2])
			local raw = m.RouteTracker.HorizontalTangentAtS(layout.Route, s)
			if not smooth or not raw then
				okSmooth = false
			else
				if prevSmooth then
					worstStep = math.max(worstStep, angleDeg(prevSmooth, smooth))
				end
				worstDev = math.max(worstDev, angleDeg(raw, smooth))
				prevSmooth = smooth
			end
			s = s + 1
		end
		check(use[1] .. " heading smoothing enabled (> 0 studs)", use[2] > 0)
		check(use[1] .. " smoothed heading defined along the whole route", okSmooth)
		check(use[1] .. " smoothed heading turns <= 1.5 deg per stud", worstStep <= 1.5, string.format("%.2f deg", worstStep))
		check(use[1] .. " smoothed heading stays within 5 deg of the track", worstDev <= 5, string.format("%.2f deg", worstDev))
	end

	-- Camera turn rate must change gradually: simulate the camera heading filter riding the route at
	-- 35 studs/s, 60 fps, and measure how much the turn rate changes from one frame to the next.
	do
		local cam, frameDt, speedSim = G.Camera, 1 / 60, 35
		local atan2 = math.atan2 or math.atan -- Luau has atan2; plain Lua 5.3 uses two-argument atan
		local heading = m.RouteTracker.SmoothHorizontalTangentAtS(layout.Route, cam.HeadingLookAheadStuds, cam.HeadingSmoothingStuds)
		local prevYaw, prevRate, worstKick = nil, nil, 0
		local sim = 0
		while sim < layout.Route.total - cam.HeadingLookAheadStuds do
			local target = m.RouteTracker.SmoothHorizontalTangentAtS(layout.Route, sim + cam.HeadingLookAheadStuds, cam.HeadingSmoothingStuds)
				or heading
			local turned = U.turnToward(heading, target, U.expAlpha(cam.HeadingResponse, frameDt), Vector3.new(0, 1, 0))
			heading = U.safeUnit(Vector3.new(turned.X, 0, turned.Z), heading)
			local yaw = atan2(heading.X, heading.Z)
			if prevYaw then
				local d = yaw - prevYaw
				if d > math.pi then
					d = d - 2 * math.pi
				elseif d < -math.pi then
					d = d + 2 * math.pi
				end
				local rate = math.deg(d) / frameDt
				if prevRate then
					worstKick = math.max(worstKick, math.abs(rate - prevRate))
				end
				prevRate = rate
			end
			prevYaw = yaw
			sim = sim + speedSim * frameDt
		end
		info(string.format("camera turn-rate kick at 35 studs/s, 60 fps: %.2f deg/s per frame (raw polyline: ~20)", worstKick))
		check("camera turn rate changes <= 5 deg/s per frame through curves", worstKick <= 5, string.format("%.2f deg/s", worstKick))
	end

	-- Route tracker: walking the centreline yields monotonic progress; a jump re-acquires.
	local tracker = m.RouteTracker.new(layout.Route)
	local lastS, trackOk, maxDist = -1, true, 0
	for i = 1, #layout.Route.points - 1 do
		local mid = (layout.Route.points[i] + layout.Route.points[i + 1]) / 2
		local result = tracker:Update(mid)
		if result.s < lastS then
			trackOk = false
		end
		lastS = result.s
		maxDist = math.max(maxDist, result.distance)
	end
	check("route tracker progress monotonic along the course", trackOk and maxDist < 1e-6)
	local back = tracker:Update(spawnPos)
	check("route tracker re-acquires after respawn jump", math.abs(back.s - spawn.S) < 2, back.s)
	check("route tracker finish beyond start", layout.FinishLineS > layout.StartLineS + 400)

	-------------------------------------------------------------------- geometry
	local B = m.Builder
	local thickness = def.FloorThickness
	local function wedgeWorldVertices(spec)
		local sx, sy, sz = spec.Size.X / 2, spec.Size.Y / 2, spec.Size.Z / 2
		local cf = spec.CFrame
		local top, bottom = {}, {}
		for _, xs in ipairs({ -1, 1 }) do
			local face = {}
			for _, yz in ipairs({ { -1, 1 }, { 1, 1 }, { -1, -1 } }) do
				table.insert(face, cf * Vector3.new(xs * sx, yz[1] * sy, yz[2] * sz))
			end
			if xs == 1 then
				top = face
			else
				bottom = face
			end
		end
		return top, bottom
	end
	local function boxTopCorners(spec)
		local cf, h = spec.CFrame, spec.Size / 2
		local out = {}
		for _, c in ipairs({ { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }) do
			table.insert(out, cf * Vector3.new(c[1] * h.X, h.Y, c[2] * h.Z))
		end
		return out
	end
	local function hasPoint(list, p, eps)
		for _, q in ipairs(list) do
			if (q - p).Magnitude <= eps then
				return true
			end
		end
		return false
	end

	-- every ribbon triangle: wedge pair top faces reproduce its 3 corners exactly; slab hangs below
	local geoOk, geoDetail, wedgeCount, boxCount = true, nil, 0, 0
	local secs = layout.Sections
	for i = 1, #secs - 1 do
		local s0, s1 = secs[i], secs[i + 1]
		local L0 = s0.Position - s0.Right * (s0.Width / 2)
		local R0 = s0.Position + s0.Right * (s0.Width / 2)
		local L1 = s1.Position - s1.Right * (s1.Width / 2)
		local R1 = s1.Position + s1.Right * (s1.Width / 2)
		local up = (s0.Up + s1.Up).Unit
		local quadSpecs = B.QuadFloorSpecs(L0, R0, L1, R1, s0.Up, s1.Up, thickness)
		if #quadSpecs == 1 and quadSpecs[1].Class == "Part" then
			boxCount = boxCount + 1
			local corners = boxTopCorners(quadSpecs[1])
			for _, p in ipairs({ L0, R0, L1, R1 }) do
				if not hasPoint(corners, p, 1e-3) then
					geoOk, geoDetail = false, "box corner mismatch at section " .. i
				end
			end
		else
			for _, tri in ipairs({ { L0, R0, R1 }, { L0, R1, L1 } }) do
				local wedges = B.TriangleWedgeSpecs(tri[1], tri[2], tri[3], thickness, up)
				wedgeCount = wedgeCount + #wedges
				local normal = (tri[2] - tri[1]):Cross(tri[3] - tri[1]).Unit
				if normal:Dot(up) < 0 then
					normal = -normal
				end
				local allTop = {}
				for _, w in ipairs(wedges) do
					local topA, topB = wedgeWorldVertices(w)
					-- whichever face lies on the triangle plane is the walking surface
					local function onPlane(face)
						for _, p in ipairs(face) do
							if math.abs((p - tri[1]):Dot(normal)) > 1e-4 then
								return false
							end
						end
						return true
					end
					local surface, other = topA, topB
					if not onPlane(surface) then
						surface, other = topB, topA
					end
					if not onPlane(surface) then
						geoOk, geoDetail = false, "wedge face off the ribbon plane at section " .. i
					end
					for _, p in ipairs(other) do
						if not near((p - tri[1]):Dot(normal), -thickness, 1e-4) then
							geoOk, geoDetail = false, "wedge slab not below the surface at section " .. i
						end
					end
					for _, p in ipairs(surface) do
						table.insert(allTop, p)
					end
				end
				for _, corner in ipairs(tri) do
					if not hasPoint(allTop, corner, 1e-4) then
						geoOk, geoDetail = false, "triangle corner not covered at section " .. i
					end
				end
			end
		end
	end
	check("floor ribbon: wedge/box top faces match the track surface exactly", geoOk, geoDetail)
	info(string.format("floor: %d flat quads as boxes, %d wedges for curved/banked quads", boxCount, wedgeCount))

	local specs = B.ComputeSpecs(layout)
	local sizeOk, railOk, collideCount = true, true, 0
	for _, spec in ipairs(specs) do
		local sz = spec.Size
		if not (finite(sz.X) and finite(sz.Y) and finite(sz.Z) and sz.X > 0 and sz.Y > 0 and sz.Z > 0) then
			sizeOk = false
		end
		if spec.Folder == "Rails" and sz.Y - thickness < P.Ball.Radius * 2 then
			railOk = false
		end
		if spec.Collide ~= false then
			collideCount = collideCount + 1
		end
	end
	check("all part sizes finite and positive", sizeOk)
	check("guardrails at least one ball diameter tall", railOk)
	check("part budget under 1500", #specs < 1500, #specs)
	info(string.format("course parts: %d total, %d collidable", #specs, collideCount))

	local bumperSpecs = 0
	for _, spec in ipairs(specs) do
		if spec.Attributes and spec.Attributes.HazardType == "PulseBumper" then
			bumperSpecs = bumperSpecs + 1
		end
	end
	check("exactly one gentle bumper hazard", bumperSpecs == 1)

	-------------------------------------------------------------------- hazard timing
	if m.HazardPhase then
		local hz = P.Hazards.PulseBumper
		local s0 = m.HazardPhase(0.01, hz)
		local s1 = m.HazardPhase(hz.TelegraphAt + 0.05, hz)
		local s2 = m.HazardPhase(hz.ActiveAt + 0.05, hz)
		local s3 = m.HazardPhase(hz.Period * 7 + 0.01, hz)
		check("pulse bumper cycles Idle -> Telegraph -> Active -> Idle", s0 == "Idle" and s1 == "Telegraph" and s2 == "Active" and s3 == "Idle")
		local warning = hz.ActiveAt - hz.TelegraphAt
		check("hazard telegraph lasts 0.5-1.0 s before activating", warning >= 0.5 and warning <= 1.0, warning)
	end

	local est, endSpeed = TD.EstimateRunSeconds(layout, mv, 196.2 * P.GravityMultiplier)
	info(string.format(
		"route %.0f studs; 1-D MODEL (full throttle, no braking/steering losses) clean run ~%.1f s, end speed %.0f -- not a measurement",
		layout.Route.total, est, endSpeed
	))

	return results
end

return Specs
