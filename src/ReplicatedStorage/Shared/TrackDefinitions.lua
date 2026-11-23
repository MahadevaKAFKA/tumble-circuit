--[[
	TrackDefinitions — the A1 Training Chute, as pure data + a deterministic generator.

	The course is a centreline "turtle" walk: each piece advances a horizontal distance while
	turning (Yaw), descending (Pitch, + = downhill), banking (Bank, + = right edge lower) and
	changing width. Pitch/Bank/Width interpolate linearly inside a piece and must match at piece
	boundaries (the validator checks this), so the floor ribbon never has steps or gaps.

	Both server (to build parts and judge progress) and client (steering frame, camera) call
	Generate() with the same definition, so they agree exactly without replicating route data.

	Conventions (Roblox world): heading 0 travels toward -Z; positive Yaw turns right (toward +X).
	Pure module: Vector3 math only, no services, so tools/offline can execute it.
]]

local TrackDefinitions = {}

local function rad(d)
	return d * math.pi / 180
end

local function lerp(a, b, t)
	return a + (b - a) * t
end

---------------------------------------------------------------------------------------------
-- Course data: 6 segments (Start, StraightRamp, STurn, Bumper, BankedDrop, Finish)
---------------------------------------------------------------------------------------------
TrackDefinitions.Training = {
	Id = "TrainingChute_A1",
	DisplayName = "Training Chute",
	LayoutVersion = 1,
	Origin = Vector3.new(0, 240, 0), -- start pad back edge, floor surface
	StartHeadingDeg = 0,
	FloorThickness = 1.6,
	RailThickness = 1.2,
	DefaultRails = { 4.5, 4.5 }, -- {left, right} height above the floor surface
	MaxStepLength = 24, -- floor quads are at most this long
	MaxYawStepDeg = 5, -- curves are subdivided finely enough to look round
	MaxPitchStepDeg = 2, -- crests and sags are eased, not kinked
	MaxBankStepDeg = 3,

	Pieces = {
		-- Segment 1: START — flat practice pad (also the safe respawn point) + launch lip
		{ Name = "StartPad", Segment = "Start", Length = 36, Pitch = { 0, 0 }, Width = { 30, 30 }, Rails = { 5, 5 }, StartCap = true },
		{ Name = "Launch", Segment = "Start", Length = 14, Pitch = { 0, 5 }, Width = { 30, 22 }, Arrows = true },

		-- Segment 2: STRAIGHT RAMP
		{ Name = "StraightRamp", Segment = "StraightRamp", Length = 180, Pitch = { 5, 4 }, Width = { 22, 22 }, Arrows = true },
		{ Name = "RampEase", Segment = "StraightRamp", Length = 20, Pitch = { 4, 3 }, Width = { 22, 22 }, Arrows = true },

		-- Segment 3: S-TURN (left then right, net heading change 0, banked into each turn)
		{ Name = "SCurveA", Segment = "STurn", Length = 55, Yaw = -35, Pitch = { 3, 3 }, Bank = { 0, -10 }, Width = { 22, 22 }, Rails = { 4.5, 6 } },
		{ Name = "SCurveB", Segment = "STurn", Length = 55, Yaw = -35, Pitch = { 3, 3 }, Bank = { -10, 0 }, Width = { 22, 22 }, Rails = { 4.5, 6 } },
		{ Name = "SCurveC", Segment = "STurn", Length = 55, Yaw = 35, Pitch = { 3, 3 }, Bank = { 0, 10 }, Width = { 22, 22 }, Rails = { 6, 4.5 } },
		{ Name = "SCurveD", Segment = "STurn", Length = 55, Yaw = 35, Pitch = { 3, 3 }, Bank = { 10, 0 }, Width = { 22, 22 }, Rails = { 6, 4.5 } },

		-- Segment 4: BUMPER — widened lane with one telegraphed pulse bumper in the middle
		{ Name = "BumperApproach", Segment = "Bumper", Length = 40, Pitch = { 3, 3 }, Width = { 22, 26 }, Arrows = true },
		{ Name = "BumperZone", Segment = "Bumper", Length = 90, Pitch = { 3, 3 }, Width = { 26, 26 } },
		{ Name = "BumperExit", Segment = "Bumper", Length = 20, Pitch = { 3, 5 }, Width = { 26, 22 }, Arrows = true },

		-- Segment 5: BANKED DROP — descending 90-degree right turn, steepest part of the course
		{ Name = "BankedDropIn", Segment = "BankedDrop", Length = 30, Yaw = 20, Pitch = { 5, 18 }, Bank = { 0, 16 }, Width = { 22, 24 }, Rails = { 7, 4.5 } },
		{ Name = "BankedDropMid", Segment = "BankedDrop", Length = 90, Yaw = 50, Pitch = { 18, 20 }, Bank = { 16, 18 }, Width = { 24, 24 }, Rails = { 7.5, 4.5 } },
		{ Name = "BankedDropOut", Segment = "BankedDrop", Length = 40, Yaw = 20, Pitch = { 20, 4 }, Bank = { 18, 0 }, Width = { 24, 22 }, Rails = { 7, 4.5 } },

		-- Segment 6: FINISH — run-out, finish line, uphill catch basin with an end wall
		{ Name = "RunOut", Segment = "Finish", Length = 80, Pitch = { 4, 2 }, Width = { 22, 22 }, Arrows = true },
		{ Name = "FinishStraight", Segment = "Finish", Length = 40, Pitch = { 2, 1 }, Width = { 22, 26 }, Arrows = true },
		{ Name = "FinishBasin", Segment = "Finish", Length = 40, Pitch = { 1, -3 }, Width = { 26, 30 }, Rails = { 6, 6 }, EndCap = true },
	},

	-- At 14 the chase camera (20 studs back, 16 deg) looks over the 5-stud back wall with ~1.5 studs spare.
	Spawn = { Piece = "StartPad", At = 14 },
	StartLine = { Piece = "StartPad", At = 36 },
	FinishLine = { Piece = "FinishStraight", At = 40 },
	-- Ordered marks a run must pass before the finish counts (cheap anti-shortcut for A1).
	Marks = {
		{ Name = "Bumper", Piece = "BumperZone", At = 0 },
		{ Name = "BankedDrop", Piece = "BankedDropMid", At = 0 },
	},

	Hazards = {
		-- Gentle, telegraphed: cyan = idle (plain bounce), yellow ramp = warning, coral = kicks.
		{ Kind = "PulseBumper", Piece = "BumperZone", At = 44, Offset = 0, Radius = 3, Height = 4.5 },
	},
	-- Yellow warning chevrons on the floor before the hazard.
	WarningStrips = {
		{ Piece = "BumperZone", From = 6, To = 30 },
	},
	Signs = {
		{ Piece = "StartPad", At = 26, Text = "ROLL FORWARD TO START", Lift = 11 },
		{ Piece = "SCurveA", At = 2, Text = "S-TURN", Lift = 10 },
		{ Piece = "BumperApproach", At = 6, Text = "PULSE BUMPER  -  CORAL = KICK", Lift = 10 },
		{ Piece = "BankedDropIn", At = 0, Text = "BANKED DROP  -  BRAKE IF FAST", Lift = 10 },
		{ Piece = "FinishStraight", At = 4, Text = "FINISH AHEAD", Lift = 10 },
	},
	Gates = {
		{ Kind = "Start", Piece = "StartPad", At = 36, Text = "START" },
		{ Kind = "Finish", Piece = "FinishStraight", At = 40, Text = "FINISH" },
	},
	ArrowSpacing = 16,
}

---------------------------------------------------------------------------------------------
-- Frame math
---------------------------------------------------------------------------------------------

-- Orthonormal frame for heading psi, pitch theta (+ = descending) and bank phi (+ = right lower).
-- Returns forward, right, up (surface normal), horizontal heading.
function TrackDefinitions.FrameVectors(psi, theta, phi)
	local Y = Vector3.new(0, 1, 0)
	local dirH = Vector3.new(math.sin(psi), 0, -math.cos(psi))
	local r0 = Vector3.new(math.cos(psi), 0, math.sin(psi))
	local f = dirH * math.cos(theta) - Y * math.sin(theta)
	local n0 = Y * math.cos(theta) + dirH * math.sin(theta)
	local r = r0 * math.cos(phi) - n0 * math.sin(phi)
	local n = n0 * math.cos(phi) + r0 * math.sin(phi)
	return f, r, n, dirH
end

local function pieceValue(piece, key, default)
	local v = piece[key]
	if v == nil then
		return default
	end
	return v
end

---------------------------------------------------------------------------------------------
-- Generate(def, ballRadius) -> layout
---------------------------------------------------------------------------------------------
function TrackDefinitions.Generate(def, ballRadius)
	ballRadius = ballRadius or 2
	local sections = {}
	local pieces = {}
	local pieceByName = {}

	local pos = def.Origin
	local heading = rad(def.StartHeadingDeg or 0)
	local h = 0
	local Y = Vector3.new(0, 1, 0)

	local function pushSection(pieceIndex, psi, pitchDeg, bankDeg, width, rails)
		local f, r, n, dirH = TrackDefinitions.FrameVectors(psi, rad(pitchDeg), rad(bankDeg))
		sections[#sections + 1] = {
			H = h,
			Position = pos,
			Forward = f,
			Right = r,
			Up = n,
			HeadingDir = dirH,
			HeadingRad = psi,
			PitchDeg = pitchDeg,
			BankDeg = bankDeg,
			Width = width,
			RailLeft = rails[1],
			RailRight = rails[2],
			PieceIndex = pieceIndex,
		}
	end

	local first = def.Pieces[1]
	pushSection(
		1,
		heading,
		pieceValue(first, "Pitch", { 0, 0 })[1],
		pieceValue(first, "Bank", { 0, 0 })[1],
		pieceValue(first, "Width", { 22, 22 })[1],
		pieceValue(first, "Rails", def.DefaultRails)
	)

	for pi, piece in ipairs(def.Pieces) do
		local length = piece.Length
		local yawDeg = pieceValue(piece, "Yaw", 0)
		local pitch = pieceValue(piece, "Pitch", { 0, 0 })
		local bank = pieceValue(piece, "Bank", { 0, 0 })
		local width = pieceValue(piece, "Width", { 22, 22 })
		local rails = pieceValue(piece, "Rails", def.DefaultRails)

		local steps = math.max(
			1,
			math.ceil(length / def.MaxStepLength - 1e-9),
			math.ceil(math.abs(yawDeg) / def.MaxYawStepDeg - 1e-9),
			math.ceil(math.abs(pitch[2] - pitch[1]) / def.MaxPitchStepDeg - 1e-9),
			math.ceil(math.abs(bank[2] - bank[1]) / def.MaxBankStepDeg - 1e-9)
		)
		local dL = length / steps
		local psi0 = heading
		local yaw = rad(yawDeg)
		local startH = h
		local firstSection = #sections

		for k = 1, steps do
			local tm = (k - 0.5) / steps
			local t1 = k / steps
			-- midpoint integration of the centreline
			local psiM = psi0 + yaw * tm
			local thetaM = rad(lerp(pitch[1], pitch[2], tm))
			local dirM = Vector3.new(math.sin(psiM), 0, -math.cos(psiM))
			pos = pos + dirM * dL - Y * (dL * math.tan(thetaM))
			h = h + dL
			pushSection(pi, psi0 + yaw * t1, lerp(pitch[1], pitch[2], t1), lerp(bank[1], bank[2], t1), lerp(width[1], width[2], t1), rails)
		end
		heading = psi0 + yaw

		local record = {
			Index = pi,
			Name = piece.Name,
			Segment = piece.Segment,
			FirstSection = firstSection,
			LastSection = #sections,
			StartH = startH,
			EndH = h,
			Definition = piece,
		}
		pieces[pi] = record
		pieceByName[piece.Name] = record
	end

	-- Route along the ball centre (floor + normal * radius); section i <-> route point i.
	local routePoints = {}
	for i, sec in ipairs(sections) do
		routePoints[i] = sec.Position + sec.Up * ballRadius
	end
	local cumulative = { 0 }
	for i = 2, #routePoints do
		cumulative[i] = cumulative[i - 1] + (routePoints[i] - routePoints[i - 1]).Magnitude
	end
	for i, sec in ipairs(sections) do
		sec.S = cumulative[i]
	end

	local layout = {
		Definition = def,
		BallRadius = ballRadius,
		Sections = sections,
		Pieces = pieces,
		PieceByName = pieceByName,
		Route = { points = routePoints, cumulative = cumulative, total = cumulative[#cumulative] },
		TotalH = h,
	}

	local minY, maxY = math.huge, -math.huge
	for _, sec in ipairs(sections) do
		minY = math.min(minY, sec.Position.Y)
		maxY = math.max(maxY, sec.Position.Y)
	end
	layout.MinY, layout.MaxY = minY, maxY

	-- Resolve features (piece-relative horizontal distance -> absolute H, S and frame).
	local function resolve(feature)
		local rec = pieceByName[feature.Piece]
		if not rec then
			return nil
		end
		local at = feature.At or 0
		return TrackDefinitions.SampleAtH(layout, rec.StartH + at)
	end
	layout.Resolve = resolve

	layout.SpawnFrame = resolve(def.Spawn)
	layout.StartLineFrame = resolve(def.StartLine)
	layout.FinishLineFrame = resolve(def.FinishLine)
	layout.StartLineS = layout.StartLineFrame and layout.StartLineFrame.S
	layout.FinishLineS = layout.FinishLineFrame and layout.FinishLineFrame.S

	layout.Marks = {}
	for i, mark in ipairs(def.Marks or {}) do
		local frame = resolve(mark)
		layout.Marks[i] = { Name = mark.Name, S = frame and frame.S, Frame = frame }
	end

	layout.Hazards = {}
	for i, hz in ipairs(def.Hazards or {}) do
		layout.Hazards[i] = { Kind = hz.Kind, Frame = resolve(hz), Offset = hz.Offset or 0, Radius = hz.Radius, Height = hz.Height }
	end

	layout.Signs = {}
	for i, sign in ipairs(def.Signs or {}) do
		layout.Signs[i] = { Text = sign.Text, Lift = sign.Lift or 10, Frame = resolve(sign) }
	end

	layout.Gates = {}
	for i, gate in ipairs(def.Gates or {}) do
		layout.Gates[i] = { Kind = gate.Kind, Text = gate.Text, Frame = resolve(gate) }
	end

	return layout
end

-- Interpolated frame at absolute horizontal distance h.
function TrackDefinitions.SampleAtH(layout, h)
	local sections = layout.Sections
	local n = #sections
	if h <= sections[1].H then
		h = sections[1].H
	end
	if h >= sections[n].H then
		h = sections[n].H
	end
	local lo, hi = 1, n - 1
	while lo < hi do
		local mid = math.floor((lo + hi + 1) / 2)
		if sections[mid].H <= h then
			lo = mid
		else
			hi = mid - 1
		end
	end
	local a, b = sections[lo], sections[math.min(lo + 1, n)]
	local span = b.H - a.H
	local t = 0
	if span > 1e-9 then
		t = (h - a.H) / span
	end
	local forward = (a.Forward + (b.Forward - a.Forward) * t).Unit
	local up = a.Up + (b.Up - a.Up) * t
	up = (up - forward * up:Dot(forward)).Unit
	local right = forward:Cross(up)
	return {
		H = h,
		S = a.S + (b.S - a.S) * t,
		Position = a.Position + (b.Position - a.Position) * t,
		Forward = forward,
		Right = right,
		Up = up,
		Width = a.Width + (b.Width - a.Width) * t,
		SectionIndex = lo,
	}
end

---------------------------------------------------------------------------------------------
-- Validate(def, layout) -> errors (list of strings, empty = valid)
-- Geometry checks only; a graph check cannot prove a human can finish (manual Play Solo does).
---------------------------------------------------------------------------------------------
function TrackDefinitions.Validate(def, layout)
	local errors = {}
	local function fail(msg)
		errors[#errors + 1] = msg
	end
	local diameter = layout.BallRadius * 2

	if #def.Pieces < 4 then
		fail("course needs at least 4 pieces")
	end
	local segments, seen = {}, {}
	for i, piece in ipairs(def.Pieces) do
		if type(piece.Name) ~= "string" or seen[piece.Name] then
			fail("piece " .. i .. " has a missing or duplicate Name")
		end
		seen[piece.Name or i] = true
		if not (piece.Length and piece.Length > 0) then
			fail(piece.Name .. ": Length must be > 0")
		end
		local width = pieceValue(piece, "Width", { 22, 22 })
		local pitch = pieceValue(piece, "Pitch", { 0, 0 })
		local bank = pieceValue(piece, "Bank", { 0, 0 })
		local rails = pieceValue(piece, "Rails", def.DefaultRails)
		if math.min(width[1], width[2]) < diameter * 4 then
			fail(piece.Name .. ": lane narrower than 4 ball diameters")
		end
		if math.max(math.abs(pitch[1]), math.abs(pitch[2])) > 30 then
			fail(piece.Name .. ": pitch beyond 30 degrees")
		end
		if math.max(math.abs(bank[1]), math.abs(bank[2])) > 25 then
			fail(piece.Name .. ": bank beyond 25 degrees")
		end
		if math.min(rails[1], rails[2]) < diameter then
			fail(piece.Name .. ": guardrail lower than one ball diameter")
		end
		if not segments[piece.Segment or "?"] then
			segments[piece.Segment or "?"] = true
			segments[#segments + 1] = piece.Segment
		end
		local nextPiece = def.Pieces[i + 1]
		if nextPiece then
			local nw = pieceValue(nextPiece, "Width", { 22, 22 })
			local np = pieceValue(nextPiece, "Pitch", { 0, 0 })
			local nb = pieceValue(nextPiece, "Bank", { 0, 0 })
			if math.abs(nw[1] - width[2]) > 0.01 then
				fail(piece.Name .. " -> " .. nextPiece.Name .. ": width discontinuity")
			end
			if math.abs(np[1] - pitch[2]) > 0.01 then
				fail(piece.Name .. " -> " .. nextPiece.Name .. ": pitch discontinuity")
			end
			if math.abs(nb[1] - bank[2]) > 0.01 then
				fail(piece.Name .. " -> " .. nextPiece.Name .. ": bank discontinuity")
			end
		end
	end
	if #segments < 4 or #segments > 6 then
		fail("A1 course should have 4-6 segments, has " .. #segments)
	end

	if not layout.SpawnFrame then
		fail("spawn does not resolve")
	end
	if not layout.StartLineS then
		fail("start line does not resolve")
	end
	if not layout.FinishLineS then
		fail("finish line does not resolve")
	end
	if layout.SpawnFrame and layout.StartLineS and layout.SpawnFrame.S >= layout.StartLineS then
		fail("spawn must be before the start line")
	end
	local previous = layout.StartLineS or 0
	for _, mark in ipairs(layout.Marks) do
		if not mark.S then
			fail("mark " .. tostring(mark.Name) .. " does not resolve")
		elseif mark.S <= previous then
			fail("marks must be in ascending order after the start line")
		else
			previous = mark.S
		end
	end
	if layout.FinishLineS and layout.FinishLineS <= previous then
		fail("finish line must come after every mark")
	end
	if layout.FinishLineS and layout.FinishLineS >= layout.Route.total - diameter * 2 then
		fail("finish line needs a run-off area after it")
	end

	for _, sign in ipairs(layout.Signs) do
		if not sign.Frame then
			fail("sign '" .. tostring(sign.Text) .. "' does not resolve")
		end
	end
	for _, gate in ipairs(layout.Gates) do
		if not gate.Frame then
			fail("gate " .. tostring(gate.Kind) .. " does not resolve")
		end
	end

	for _, hz in ipairs(layout.Hazards) do
		if not hz.Frame then
			fail("hazard " .. tostring(hz.Kind) .. " does not resolve")
		else
			local half = hz.Frame.Width / 2
			local leftGap = half + hz.Offset - hz.Radius
			local rightGap = half - hz.Offset - hz.Radius
			if math.max(leftGap, rightGap) < diameter * 1.5 then
				fail("hazard " .. hz.Kind .. " leaves no passable lane")
			end
		end
	end

	-- No unintended overlap between distant parts of the course.
	local secs = layout.Sections
	for i = 1, #secs do
		for j = i + 1, #secs do
			if secs[j].S - secs[i].S > 80 then
				local d = (secs[j].Position - secs[i].Position).Magnitude
				if d < 30 then
					fail(string.format("course passes within %.1f studs of itself (sections %d/%d)", d, i, j))
				end
			end
		end
	end

	if layout.MinY < 20 then
		fail("course dips too close to the world floor")
	end
	if layout.Route.total < 500 or layout.Route.total > 2000 then
		fail(string.format("route length %.0f outside the 500-2000 stud A1 envelope", layout.Route.total))
	end

	return errors
end

---------------------------------------------------------------------------------------------
-- A crude 1-D rolling model for a ballpark clean-run time. This is a MODEL, not a measurement:
-- no braking, no steering losses, no bounces. Real times must come from Play Solo.
---------------------------------------------------------------------------------------------
function TrackDefinitions.EstimateRunSeconds(layout, movement, gravity)
	gravity = gravity or 196.2
	local rollFactor = 5 / 7 -- solid sphere rolling without slip
	local sections = layout.Sections
	local v, t = 0.1, 0
	local startS = layout.StartLineS or 0
	local finishS = layout.FinishLineS or layout.Route.total
	for i = 1, #sections - 1 do
		local a, b = sections[i], sections[i + 1]
		local ds = b.S - a.S
		if b.S > startS and a.S < finishS and ds > 0 then
			local sinPitch = math.sin(rad((a.PitchDeg + b.PitchDeg) / 2))
			local throttle = 0
			if v < movement.ThrottleTargetSpeed then
				throttle = movement.AlongTrackAccel * math.min(1, (movement.ThrottleTargetSpeed - v) / movement.ThrottleTaperRange)
			end
			-- motor forces are inertia-compensated (see RollingInertiaCompensation); gravity is not
			local resist = (movement.RollingResistance or 0) + movement.LinearDrag * v
			local accel = rollFactor * gravity * sinPitch + throttle - resist
			if v > movement.TerminalSpeed then
				accel = accel - math.min(movement.TerminalDragMax, (v - movement.TerminalSpeed) * movement.TerminalDragResponse)
			end
			local v2 = math.max(1, v * v + 2 * accel * ds)
			local vNext = math.sqrt(v2)
			t = t + ds / ((v + vNext) / 2)
			v = vNext
		end
	end
	return t, v
end

return TrackDefinitions
