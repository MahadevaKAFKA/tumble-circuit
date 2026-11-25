--[[
	TrainingTrackBuilder — turns a TrackDefinitions layout into anchored primitive parts.

	Two layers:
	  1. Pure spec functions (no Instances): floor ribbon (boxes for flat rectangles, WedgePart
	     triangle pairs for curved / banked / tapering quads), guardrails, decor, gates, signs and
	     the hazard. These are executed by the offline tests (top faces of wedges are checked to
	     coincide exactly with the ribbon triangles, so the floor has no steps or gaps).
	  2. Build(): creates Instances from the specs. Server only.

	Floor top surface = the ribbon; slabs hang below it. Guardrails stand on the edges, outside the
	lane. Everything is anchored; only Floor, Rails and the bumper base collide.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local PhysicsConfig = require(Shared:WaitForChild("PhysicsConfig"))
local TrackDefinitions = require(Shared:WaitForChild("TrackDefinitions"))

local Builder = {}

local EPS = 1e-6

---------------------------------------------------------------------------------------------
-- Geometry primitives (pure)
---------------------------------------------------------------------------------------------

-- Right triangle (right angle at R, legs to P and Q) as a WedgePart spec.
-- WedgePart local cross-section (YZ): right angle at (-Y/2, +Z/2), top-back (+Y/2, +Z/2),
-- bottom-front (-Y/2, -Z/2). So Y axis runs R->P, -Z axis runs R->Q, centre = (P + Q) / 2.
local function rightTriangleWedge(R, P, Q, thickness, upHint)
	local legY = P - R
	local legZ = Q - R
	local sizeY = legY.Magnitude
	local sizeZ = legZ.Magnitude
	if sizeY < 1e-3 or sizeZ < 1e-3 then
		return nil
	end
	local yAxis = legY / sizeY
	local zAxis = -(legZ / sizeZ)
	local xAxis = yAxis:Cross(zAxis)
	local down = xAxis
	if xAxis:Dot(upHint) > 0 then
		down = -xAxis
	end
	local center = (P + Q) / 2 + down * (thickness / 2)
	return {
		Class = "WedgePart",
		Size = Vector3.new(thickness, sizeY, sizeZ),
		CFrame = CFrame.fromMatrix(center, xAxis, yAxis, zAxis),
	}
end

-- Any triangle -> two WedgePart specs, split at the foot of the altitude onto the longest edge.
function Builder.TriangleWedgeSpecs(a, b, c, thickness, upHint)
	local ab, bc, ca = (b - a).Magnitude, (c - b).Magnitude, (a - c).Magnitude
	-- reorder so that edge b->c is the longest and a is the opposite vertex
	if ab >= bc and ab >= ca then
		a, b, c = c, a, b
	elseif ca >= ab and ca >= bc then
		a, b, c = b, c, a
	end
	local edge = c - b
	local len2 = edge:Dot(edge)
	if len2 < EPS then
		return {}
	end
	local t = (a - b):Dot(edge) / len2
	local d = b + edge * t
	local specs = {}
	local w1 = rightTriangleWedge(d, a, b, thickness, upHint)
	local w2 = rightTriangleWedge(d, a, c, thickness, upHint)
	if w1 then
		specs[#specs + 1] = w1
	end
	if w2 then
		specs[#specs + 1] = w2
	end
	return specs
end

-- Floor quad between two cross-sections. Flat rectangles become one box; anything else becomes
-- two triangles (four wedges) whose top faces are exactly the quad corners.
function Builder.QuadFloorSpecs(L0, R0, L1, R1, up0, up1, thickness)
	local upAvg = (up0 + up1).Unit
	local leftEdge = L1 - L0
	local rightEdge = R1 - R0
	local across = R0 - L0
	-- equal, perpendicular side edges => planar rectangle (a parallelogram is always planar)
	local isRectangle = (leftEdge - rightEdge).Magnitude < 0.01
		and math.abs(leftEdge:Dot(across)) < 0.01 * leftEdge.Magnitude * across.Magnitude
	if isRectangle then
		local width = across.Magnitude
		local length = leftEdge.Magnitude
		local right = across / width
		local forward = leftEdge / length
		local up = right:Cross(forward)
		if up:Dot(upAvg) < 0 then
			up = -up
		end
		local center = (L0 + R0 + L1 + R1) / 4 - up * (thickness / 2)
		return {
			{
				Class = "Part",
				Size = Vector3.new(width, thickness, length),
				CFrame = CFrame.fromMatrix(center, right, up),
			},
		}
	end
	local specs = {}
	for _, s in ipairs(Builder.TriangleWedgeSpecs(L0, R0, R1, thickness, upAvg)) do
		specs[#specs + 1] = s
	end
	for _, s in ipairs(Builder.TriangleWedgeSpecs(L0, R1, L1, thickness, upAvg)) do
		specs[#specs + 1] = s
	end
	return specs
end

-- A wall standing on segment p0->p1, perpendicular to the surface (upHint), pushed to the
-- outward side so its inner face sits on the edge line. Extends floorThickness below the surface.
function Builder.EdgeWallSpec(p0, p1, upHint, height, thickness, floorThickness, outward, extend)
	local along = p1 - p0
	local length = along.Magnitude
	if length < 1e-3 then
		return nil
	end
	local dir = along / length
	local up = (upHint - dir * upHint:Dot(dir)).Unit
	local side = dir:Cross(up) -- points to the right of travel along p0->p1
	local totalHeight = height + floorThickness
	local center = (p0 + p1) / 2 + side * (outward * thickness / 2) + up * ((height - floorThickness) / 2)
	return {
		Class = "Part",
		Size = Vector3.new(thickness, totalHeight, length + (extend or 0)),
		CFrame = CFrame.fromMatrix(center, side, up),
	}
end

---------------------------------------------------------------------------------------------
-- Full course spec (pure)
---------------------------------------------------------------------------------------------
local function frameCFrame(frame, lift)
	return CFrame.fromMatrix(frame.Position + frame.Up * (lift or 0), frame.Right, frame.Up)
end

local function physics(friction, elasticity, elasticityWeight)
	return { Density = 0.7, Friction = friction, Elasticity = elasticity, FrictionWeight = 1, ElasticityWeight = elasticityWeight or 1 }
end

-- B1: a world's Theme overrides palette keys (floor, rails, accents) and materials; every other
-- colour comes from GameConfig.Palette. Hazard warning colours (Coral / Yellow) never change.
function Builder.ThemePalette(theme)
	local base = GameConfig.Palette
	if not theme then
		return base
	end
	return setmetatable({}, {
		__index = function(_, key)
			local v = theme[key]
			if typeof(v) == "Color3" then
				return v
			end
			return base[key]
		end,
	})
end

function Builder.ComputeSpecs(layout)
	local def = layout.Definition
	local palette = Builder.ThemePalette(def.Theme)
	local floorMaterial = def.Theme and def.Theme.FloorMaterial or "SmoothPlastic"
	local railMaterial = def.Theme and def.Theme.RailMaterial or "SmoothPlastic"
	local trackPhysics = PhysicsConfig.Track
	local specs = {}
	local function add(spec)
		specs[#specs + 1] = spec
		return spec
	end

	local floorPhysics = physics(trackPhysics.FloorFriction, trackPhysics.FloorElasticity)
	local railPhysics = physics(trackPhysics.RailFriction, trackPhysics.RailElasticity)
	local sections = layout.Sections
	local thickness = def.FloorThickness
	local railT = def.RailThickness

	-- Floor ribbon + guardrails
	for i = 1, #sections - 1 do
		local s0, s1 = sections[i], sections[i + 1]
		local L0 = s0.Position - s0.Right * (s0.Width / 2)
		local R0 = s0.Position + s0.Right * (s0.Width / 2)
		local L1 = s1.Position - s1.Right * (s1.Width / 2)
		local R1 = s1.Position + s1.Right * (s1.Width / 2)
		local piece = layout.Pieces[s1.PieceIndex]
		local color = palette.NavyFloor
		if piece.Segment == "Start" or piece.Segment == "Finish" then
			color = palette.Navy:Lerp(palette.Violet, 0.18)
		end
		local floorQuads = piece.Definition.Floor == "Tiles" and {} or Builder.QuadFloorSpecs(L0, R0, L1, R1, s0.Up, s1.Up, thickness)
		for _, q in ipairs(floorQuads) do
			q.Name = "Floor_" .. piece.Name
			q.Folder = "Floor"
			q.Color = color
			q.Material = floorMaterial
			q.Physics = floorPhysics
			add(q)
		end

		local upAvg = (s0.Up + s1.Up).Unit
		local walls = {
			{ p0 = L0, p1 = L1, h = s1.RailLeft, outward = -1, name = "RailL" },
			{ p0 = R0, p1 = R1, h = s1.RailRight, outward = 1, name = "RailR" },
		}
		for _, w in ipairs(walls) do
			local wall = Builder.EdgeWallSpec(w.p0, w.p1, upAvg, w.h, railT, thickness, w.outward, railT)
			if wall then
				wall.Name = w.name .. "_" .. piece.Name
				wall.Folder = "Rails"
				wall.Color = palette.NavyRail
				wall.Material = railMaterial
				wall.Physics = railPhysics
				add(wall)
				-- neon cap strip on top of the rail (visual edge cue, no collision)
				local capColor = palette.Cyan
				if w.h > 5.5 then
					capColor = palette.Violet -- taller outer walls on turns read differently
				end
				add({
					Class = "Part",
					Name = "RailCap",
					Folder = "Decor",
					Size = Vector3.new(railT + 0.1, 0.3, wall.Size.Z),
					CFrame = wall.CFrame * CFrame.new(0, wall.Size.Y / 2 + 0.15, 0),
					Color = capColor,
					Material = "Neon",
					Collide = false,
				})
			end
		end
	end

	-- Back wall behind the start pad and end wall of the finish basin.
	local first, last = sections[1], sections[#sections]
	local function capWall(sec, outwardSign, name, height)
		local L = sec.Position - sec.Right * (sec.Width / 2)
		local R = sec.Position + sec.Right * (sec.Width / 2)
		-- along L->R, "side" points backward (against travel); outwardSign +1 = behind, -1 = ahead
		local wall = Builder.EdgeWallSpec(L, R, sec.Up, height, railT, thickness, outwardSign, railT * 2)
		wall.Name = name
		wall.Folder = "Rails"
		wall.Color = palette.NavyRail
		wall.Material = railMaterial
		wall.Physics = railPhysics
		add(wall)
		add({
			Class = "Part",
			Name = "RailCap",
			Folder = "Decor",
			Size = Vector3.new(railT + 0.1, 0.3, wall.Size.Z),
			CFrame = wall.CFrame * CFrame.new(0, wall.Size.Y / 2 + 0.15, 0),
			Color = palette.Cyan,
			Material = "Neon",
			Collide = false,
		})
	end
	if def.Pieces[1].StartCap then
		capWall(first, 1, "StartBackWall", 5) -- low enough for the chase camera to look over
	end
	if def.Pieces[#def.Pieces].EndCap then
		capWall(last, -1, "FinishEndWall", 7)
	end

	-- Floor chevrons: cyan direction arrows, yellow warning arrows before the hazard.
	local function chevron(frame, color, name)
		local base = frameCFrame(frame, 0.06)
		for _, sideSign in ipairs({ -1, 1 }) do
			local c = Vector3.new(sideSign * 1.2, 0, 0)
			local dir = Vector3.new(sideSign * 2.4, 0, 3.2)
			add({
				Class = "Part",
				Name = name,
				Folder = "Decor",
				Size = Vector3.new(0.7, 0.12, 4),
				CFrame = base * CFrame.lookAt(c, c + dir),
				Color = color,
				Material = "Neon",
				Collide = false,
			})
		end
	end
	local spacing = def.ArrowSpacing or 16
	for _, piece in ipairs(layout.Pieces) do
		if piece.Definition.Arrows then
			local at = spacing / 2
			while at < piece.Definition.Length do
				chevron(TrackDefinitions.SampleAtH(layout, piece.StartH + at), palette.Cyan, "Arrow")
				at = at + spacing
			end
		end
	end
	for _, strip in ipairs(def.WarningStrips or {}) do
		local piece = layout.PieceByName[strip.Piece]
		if piece then
			local at = strip.From
			while at <= strip.To do
				chevron(TrackDefinitions.SampleAtH(layout, piece.StartH + at), palette.Yellow, "WarningArrow")
				at = at + 6
			end
		end
	end

	-- Spawn marker ring (the safe respawn point on the practice pad).
	local spawn = layout.SpawnFrame
	add({
		Class = "Part",
		Shape = "Cylinder",
		Name = "SpawnMarker",
		Folder = "Decor",
		Size = Vector3.new(0.1, 6.5, 6.5),
		CFrame = CFrame.fromMatrix(spawn.Position + spawn.Up * 0.05, spawn.Up, spawn.Forward),
		Color = palette.Mint,
		Material = "Neon",
		Transparency = 0.25,
		Collide = false,
	})

	-- Start line strip and finish checker band.
	local startFrame = layout.StartLineFrame
	add({
		Class = "Part",
		Name = "StartLine",
		Folder = "Decor",
		Size = Vector3.new(startFrame.Width - 0.5, 0.1, 1.2),
		CFrame = frameCFrame(startFrame, 0.05),
		Color = palette.Cyan,
		Material = "Neon",
		Collide = false,
	})
	local finishFrame = layout.FinishLineFrame
	local tiles = math.floor(finishFrame.Width / 2)
	for row = 0, 1 do
		for col = 0, tiles - 1 do
			local x = (col - (tiles - 1) / 2) * 2
			local z = (row - 0.5) * 2
			local white = (row + col) % 2 == 0
			add({
				Class = "Part",
				Name = "FinishTile",
				Folder = "Decor",
				Size = Vector3.new(2, 0.1, 2),
				CFrame = frameCFrame(finishFrame, 0.05) * CFrame.new(x, 0, z),
				Color = white and palette.White or palette.Ink,
				Material = white and "Neon" or "SmoothPlastic",
				Collide = false,
			})
		end
	end

	-- Gates (decor arches with a label facing approaching players).
	for _, gate in ipairs(layout.Gates) do
		local f = gate.Frame
		local half = f.Width / 2 + railT + 1.2
		local color = palette.Cyan
		if gate.Kind == "Finish" then
			color = palette.Mint
		elseif gate.Kind == "Checkpoint" then
			color = palette.Violet
			add({
				Class = "Part",
				Name = "CheckpointLine",
				Folder = "Decor",
				Size = Vector3.new(f.Width - 0.5, 0.1, 0.8),
				CFrame = frameCFrame(f, 0.05),
				Color = palette.Violet,
				Material = "Neon",
				Collide = false,
			})
		end
		local base = frameCFrame(f, 0)
		for _, sideSign in ipairs({ -1, 1 }) do
			add({
				Class = "Part",
				Name = "GatePillar",
				Folder = "Decor",
				Size = Vector3.new(1.6, 12, 1.6),
				CFrame = base * CFrame.new(sideSign * half, 6, 0),
				Color = color,
				Material = "Neon",
				Collide = false,
			})
		end
		add({
			Class = "Part",
			Name = gate.Kind .. "GateBeam",
			Folder = "Decor",
			Size = Vector3.new(half * 2 + 1.6, 2.6, 1.6),
			CFrame = base * CFrame.new(0, 12.6, 0),
			Color = palette.Ink,
			Material = "SmoothPlastic",
			Collide = false,
			Gui = { Kind = "Surface", Text = gate.Text, Color = color },
		})
	end

	-- A2 start gate: a physical barrier the round opens at GO (RoundService toggles it).
	if layout.StartGateFrame and def.StartGate then
		local g = layout.StartGateFrame
		local height = def.StartGate.Height or 5
		add({
			Class = "Part",
			Name = "StartGate",
			Folder = "Gates",
			Size = Vector3.new(g.Width + railT * 2, height, 1),
			CFrame = frameCFrame(g, height / 2),
			Color = palette.Coral,
			Material = "Neon",
			Transparency = 0.35,
			Physics = railPhysics,
		})
	end

	-- A4: split-lane divider walls along the centreline (Rails folder: collidable, camera-ignored)
	for _, piece in ipairs(layout.Pieces) do
		local divider = piece.Definition.Divider
		if divider then
			local h0, h1 = piece.StartH + divider.From, piece.StartH + divider.To
			local steps = math.max(1, math.ceil((h1 - h0) / 8))
			for k = 0, steps - 1 do
				local a = TrackDefinitions.SampleAtH(layout, h0 + (h1 - h0) * k / steps)
				local b = TrackDefinitions.SampleAtH(layout, h0 + (h1 - h0) * (k + 1) / steps)
				local wall = Builder.EdgeWallSpec(a.Position - a.Right * 0.6, b.Position - b.Right * 0.6, (a.Up + b.Up).Unit, divider.Height, 1.2, thickness, 1, 1.2)
				if wall then
					wall.Name = "Divider"
					wall.Folder = "Rails"
					wall.Color = palette.Violet:Lerp(palette.Navy, 0.4)
					wall.Material = "SmoothPlastic"
					wall.Physics = railPhysics
					add(wall)
				end
			end
		end
		if piece.Definition.Roof then
			local at = 6
			while at < piece.Definition.Length do
				local f = TrackDefinitions.SampleAtH(layout, piece.StartH + at)
				local cf = frameCFrame(f, 0)
				local half = f.Width / 2 + railT
				add({ Class = "Part", Name = "TunnelRib", Folder = "Decor", Size = Vector3.new(half * 2 + 1, 1, 1.2), CFrame = cf * CFrame.new(0, 11, 0), Color = palette.NavyRail, Material = "SmoothPlastic", Collide = false })
				for _, side in ipairs({ -1, 1 }) do
					add({ Class = "Part", Name = "TunnelRib", Folder = "Decor", Size = Vector3.new(1, 11, 1.2), CFrame = cf * CFrame.new(side * half, 5.5, 0), Color = palette.NavyRail, Material = "SmoothPlastic", Collide = false })
				end
				at = at + 12
			end
		end
	end

	-- A4 hazards (moving parts are non-colliding visuals animated by clients from HazardSim;
	-- contact is judged by HazardSim for each marble's owner). Static parts collide.
	for _, hz in ipairs(layout.Hazards) do
		local d = hz.Definition or {}
		local f = hz.Frame
		local folder = "Hazards/" .. hz.Id
		local center = f and (f.Position + f.Right * (hz.Offset or 0))
		if hz.Kind == "Sweeper" then
			add({ Class = "Part", Shape = "Cylinder", Name = "Post", Folder = folder, Size = Vector3.new(5, d.PostRadius * 2, d.PostRadius * 2), CFrame = CFrame.fromMatrix(center + f.Up * 2, f.Up, f.Forward), Color = palette.NavyRail, Material = "SmoothPlastic", Physics = railPhysics, Attributes = { HazardId = hz.Id, Role = "Post" } })
			add({ Class = "Part", Name = "Arm", Folder = folder, Size = Vector3.new(d.ArmLength, d.ArmThickness, d.ArmThickness), CFrame = frameCFrame(f, d.ArmHeight) * CFrame.new((hz.Offset or 0) + d.ArmLength / 2, 0, 0), Color = palette.Coral, Material = "Neon", Collide = false, Attributes = { HazardId = hz.Id, Role = "Arm", Kind = "Sweeper" } })
			local zone = d.ArmLength * 2 + 2
			add({ Class = "Part", Shape = "Cylinder", Name = "SweepZone", Folder = folder, Size = Vector3.new(0.1, zone, zone), CFrame = CFrame.fromMatrix(center + f.Up * 0.04, f.Up, f.Forward), Color = palette.Coral, Material = "Neon", Transparency = 0.75, Collide = false })
		elseif hz.Kind == "Hammer" then
			local cf = frameCFrame(f, 0)
			local span = f.Width / 2 + railT + 1
			if d.Style == "Piston" then
				-- B1 Volcano: piston housings in both walls, the head slides between them
				for _, side in ipairs({ -1, 1 }) do
					add({ Class = "Part", Name = "PistonHousing", Folder = "Decor", Size = Vector3.new(2.4, 6, d.HeadSize + 2), CFrame = cf * CFrame.new(side * span, 3, 0), Color = palette.NavyRail, Material = railMaterial, Collide = false })
					add({ Class = "Part", Name = "PistonGlow", Folder = "Decor", Size = Vector3.new(0.3, 4, d.HeadSize), CFrame = cf * CFrame.new(side * (span - 1.3), 3, 0), Color = palette.Cyan, Material = "Neon", Collide = false })
				end
			elseif d.Style == "Flipper" then
				-- B1 Sky Carnival: pinball flipper posts with a striped bar overhead
				for _, side in ipairs({ -1, 1 }) do
					add({ Class = "Part", Shape = "Cylinder", Name = "FlipperPost", Folder = "Decor", Size = Vector3.new(8, 2.2, 2.2), CFrame = CFrame.fromMatrix(cf.Position + cf.RightVector * (side * span) + cf.UpVector * 4, cf.UpVector, cf.LookVector), Color = palette.Violet, Material = "SmoothPlastic", Collide = false })
				end
				add({ Class = "Part", Name = "FlipperBar", Folder = "Decor", Size = Vector3.new(span * 2 + 2.2, 0.8, 0.8), CFrame = cf * CFrame.new(0, 8, 0), Color = palette.White, Material = "Neon", Collide = false })
			else
				for _, side in ipairs({ -1, 1 }) do
					add({ Class = "Part", Name = "HammerPillar", Folder = "Decor", Size = Vector3.new(1.4, 14, 1.4), CFrame = cf * CFrame.new(side * span, 7, 0), Color = palette.NavyRail, Material = "SmoothPlastic", Collide = false })
				end
				add({ Class = "Part", Name = "HammerBeam", Folder = "Decor", Size = Vector3.new(span * 2 + 1.4, 1.4, 1.4), CFrame = cf * CFrame.new(0, 14, 0), Color = palette.Yellow, Material = "Neon", Collide = false })
			end
			add({ Class = "Part", Name = "Head", Folder = folder, Size = Vector3.new(d.HeadSize, d.HeadSize, d.HeadSize), CFrame = cf * CFrame.new(0, d.HeadSize / 2 + 0.2, 0), Color = palette.Coral, Material = "SmoothPlastic", Collide = false, Attributes = { HazardId = hz.Id, Role = "Head", Kind = "Hammer" } })
			add({ Class = "Part", Name = "SwingPath", Folder = folder, Size = Vector3.new(d.Amplitude * 2 + d.HeadSize, 0.1, d.HeadSize), CFrame = cf * CFrame.new(0, 0.05, 0), Color = palette.Yellow, Material = "Neon", Transparency = 0.6, Collide = false })
		elseif hz.Kind == "Trampoline" then
			add({ Class = "Part", Name = "Pad", Folder = folder, Size = Vector3.new(d.Width, 0.4, d.Length), CFrame = frameCFrame(f, 0.2) * CFrame.new(hz.Offset or 0, 0, 0), Color = palette.Mint, Material = "Neon", Physics = { Density = 0.7, Friction = 0.4, Elasticity = 0.9, FrictionWeight = 1, ElasticityWeight = 50 }, Attributes = { HazardId = hz.Id, Role = "Pad" } })
			if d.Style == "Drum" then
				-- B1 Sky Carnival: drum shell around the pad (decor; the pad is the bouncy part)
				for _, side in ipairs({ -1, 1 }) do
					add({ Class = "Part", Name = "DrumShell", Folder = "Decor", Size = Vector3.new(0.6, 1.2, d.Length + 1), CFrame = frameCFrame(f, 0.6) * CFrame.new((hz.Offset or 0) + side * (d.Width / 2 + 0.3), 0, 0), Color = palette.Violet, Material = "SmoothPlastic", Collide = false })
					add({ Class = "Part", Name = "DrumShell", Folder = "Decor", Size = Vector3.new(d.Width + 1.2, 1.2, 0.6), CFrame = frameCFrame(f, 0.6) * CFrame.new(hz.Offset or 0, 0, side * (d.Length / 2 + 0.3)), Color = palette.White, Material = "SmoothPlastic", Collide = false })
				end
			end
		elseif hz.Kind == "Tiles" then
			local piece = hz.Piece
			local rowLength = piece.Definition.Length / d.Rows
			for row = 1, d.Rows do
				local rf = TrackDefinitions.SampleAtH(layout, piece.StartH + (row - 0.5) * rowLength)
				local colWidth = rf.Width / d.Cols
				for col = 1, d.Cols do
					local x = -rf.Width / 2 + (col - 0.5) * colWidth
					add({ Class = "Part", Name = "Tile", Folder = folder, Size = Vector3.new(colWidth - 0.25, thickness, rowLength - 0.25), CFrame = frameCFrame(rf, -thickness / 2) * CFrame.new(x, 0, 0), Color = palette.NavyFloor:Lerp(palette.Cyan, 0.15), Material = floorMaterial, Physics = floorPhysics, Attributes = { HazardId = hz.Id, Role = "Tile", Row = row, Col = col } })
				end
			end
		elseif hz.Kind == "Fan" or hz.Kind == "Conveyor" then
			local at = 0
			while at <= hz.Length do
				local zf = TrackDefinitions.SampleAtH(layout, hz.FromFrame.H + at)
				local base = frameCFrame(zf, 0.08)
				-- one chevron per push direction (Dir = +1 points toward +Right); clients show the set
				-- matching the round's seed and hide the other (no runtime re-orientation needed)
				for _, dir in ipairs({ 1, -1 }) do
					local turn = dir > 0 and CFrame.new() or CFrame.Angles(0, math.pi, 0)
					for _, z in ipairs({ -1.2, 1.2 }) do
						add({ Class = "Part", Name = "PushArrow", Folder = folder, Size = Vector3.new(3, 0.12, 0.5), CFrame = base * turn * CFrame.new(0, 0, z) * CFrame.Angles(0, z > 0 and 0.6 or -0.6, 0) * CFrame.new(1.2, 0, 0), Color = hz.Kind == "Fan" and palette.Cyan or palette.Yellow, Material = "Neon", Transparency = dir > 0 and 0 or 1, Collide = false, Attributes = { HazardId = hz.Id, Role = "Arrow", Kind = hz.Kind, Dir = dir } })
					end
				end
				if hz.Kind == "Fan" then
					for _, side in ipairs({ -1, 1 }) do
						local edge = zf.Position + zf.Right * (side * (zf.Width / 2 + railT + 0.4))
						if d.Style == "Geyser" then
							-- B1 Volcano: vents just outside the lane edge (axis = up), glow while bursting
							add({ Class = "Part", Shape = "Cylinder", Name = "FanDisc", Folder = folder, Size = Vector3.new(0.6, 4, 4), CFrame = CFrame.fromMatrix(edge + zf.Up * 0.3, zf.Up, zf.Forward), Color = palette.Cyan, Material = "Neon", Transparency = 0.2, Collide = false, Attributes = { HazardId = hz.Id, Role = "FanDisc", Side = side } })
						elseif d.Style == "Wind" then
							-- B1 Sky Carnival: open-air wind puffs (no tunnel)
							add({ Class = "Part", Shape = "Ball", Name = "FanDisc", Folder = folder, Size = Vector3.new(5, 5, 5), CFrame = CFrame.fromMatrix(edge + zf.Up * 3, zf.Right, zf.Up), Color = palette.Cyan, Material = "SmoothPlastic", Transparency = 0.45, Collide = false, Attributes = { HazardId = hz.Id, Role = "FanDisc", Side = side } })
						else
							add({ Class = "Part", Shape = "Cylinder", Name = "FanDisc", Folder = folder, Size = Vector3.new(0.6, 6, 6), CFrame = CFrame.fromMatrix(edge + zf.Up * 4, zf.Right, zf.Up), Color = palette.Cyan, Material = "Neon", Transparency = 0.4, Collide = false, Attributes = { HazardId = hz.Id, Role = "FanDisc", Side = side } })
						end
					end
				end
				at = at + (hz.Kind == "Fan" and 16 or 10)
			end
		end
		if hz.Kind == "PulseBumper" then
			hz.Folder = folder
		end
	end

	-- A4 chaos gates (decor half-lane arches; reward judged by the server)
	for _, gate in ipairs(layout.ChaosGates or {}) do
		local base = frameCFrame(gate.Frame, 0) * CFrame.new(gate.Offset, 0, 0)
		for _, side in ipairs({ -1, 1 }) do
			add({ Class = "Part", Name = "ChaosPillar", Folder = "Decor", Size = Vector3.new(0.8, 7, 0.8), CFrame = base * CFrame.new(side * gate.Width / 2, 3.5, 0), Color = palette.Yellow, Material = "Neon", Collide = false })
		end
		add({ Class = "Part", Name = "ChaosBeam", Folder = "Decor", Size = Vector3.new(gate.Width + 0.8, 0.8, 0.8), CFrame = base * CFrame.new(0, 7, 0), Color = palette.Violet, Material = "Neon", Collide = false })
		add({ Class = "Part", Name = "ChaosFloor", Folder = "Decor", Size = Vector3.new(gate.Width, 0.1, 1.6), CFrame = base * CFrame.new(0, 0.06, 0), Color = palette.Yellow, Material = "Neon", Transparency = 0.3, Collide = false, Attributes = { ChaosGateId = gate.Id } })
	end

	-- A3 trick ramp kicker (collidable, its own folder so the camera ignores it).
	for i, zone in ipairs(layout.TrickZones or {}) do
		local mid = zone.MidFrame
		local center = mid.Position + mid.Right * zone.Offset + mid.Up * (zone.Height / 2)
		-- WedgePart: high edge on local +Z. Point +Z along travel so balls roll up and launch.
		add({
			Class = "WedgePart",
			Name = "TrickRamp" .. i,
			Folder = "Features",
			Size = Vector3.new(zone.Width, zone.Height, zone.Length),
			CFrame = CFrame.fromMatrix(center, -mid.Right, mid.Up),
			Color = palette.Mint:Lerp(palette.Navy, 0.35),
			Material = "SmoothPlastic",
			Physics = floorPhysics,
			Attributes = { Feature = "TrickRamp" },
		})
		local lip = zone.LipFrame
		add({
			Class = "Part",
			Name = "TrickLip",
			Folder = "Decor",
			Size = Vector3.new(zone.Width, 0.2, 0.5),
			CFrame = CFrame.fromMatrix(lip.Position + lip.Right * zone.Offset + lip.Up * (zone.Height + 0.1), lip.Right, lip.Up),
			Color = palette.Mint,
			Material = "Neon",
			Collide = false,
		})
	end

	-- Floating signs (billboards, distance-limited).
	for i, sign in ipairs(layout.Signs) do
		add({
			Class = "Part",
			Name = "Sign" .. i,
			Folder = "Decor",
			Size = Vector3.new(1, 1, 1),
			CFrame = frameCFrame(sign.Frame, sign.Lift),
			Color = palette.Ink,
			Material = "SmoothPlastic",
			Transparency = 1,
			Collide = false,
			Gui = { Kind = "Billboard", Text = sign.Text, Color = palette.White },
		})
	end

	-- Hazards
	local bumperPhysics = physics(trackPhysics.BumperFriction, trackPhysics.BumperElasticity, trackPhysics.BumperElasticityWeight)
	for i, hz in ipairs(layout.Hazards) do
		if hz.Kind == "PulseBumper" then
			local f = hz.Frame
			local folder = "Hazards/" .. (hz.Id or ("PulseBumper" .. i))
			local base = f.Position + f.Right * hz.Offset
			local d = hz.Radius * 2
			add({
				Class = "Part",
				Shape = "Cylinder",
				Name = "Base",
				Folder = folder,
				Size = Vector3.new(hz.Height, d, d),
				CFrame = CFrame.fromMatrix(base + f.Up * (hz.Height / 2 - 0.5), f.Up, f.Forward),
				Color = palette.Cyan,
				Material = "SmoothPlastic",
				Physics = bumperPhysics,
				Attributes = { HazardType = "PulseBumper", Radius = hz.Radius, Height = hz.Height, HazardId = hz.Id or ("PulseBumper" .. i), PhaseOffset = (hz.Definition and hz.Definition.PhaseOffset) or 0 },
			})
			add({
				Class = "Part",
				Shape = "Cylinder",
				Name = "Ring",
				Folder = folder,
				Size = Vector3.new(0.6, d + 0.8, d + 0.8),
				CFrame = CFrame.fromMatrix(base + f.Up * (hz.Height - 0.2), f.Up, f.Forward),
				Color = palette.Cyan,
				Material = "Neon",
				Collide = false,
			})
			local zone = (hz.Radius + layout.BallRadius + 0.4) * 2
			add({
				Class = "Part",
				Shape = "Cylinder",
				Name = "FloorRing",
				Folder = folder,
				Size = Vector3.new(0.1, zone, zone),
				CFrame = CFrame.fromMatrix(base + f.Up * 0.04, f.Up, f.Forward),
				Color = palette.Cyan,
				Material = "Neon",
				Transparency = 0.55,
				Collide = false,
			})
			local style = hz.Definition and hz.Definition.Style
			if style == "Balloon" then
				-- B1 Sky Carnival: a balloon tied to the bumper post (decor; the post is the collider)
				add({ Class = "Part", Shape = "Ball", Name = "Balloon", Folder = "Decor", Size = Vector3.new(d + 1, d + 1, d + 1), CFrame = CFrame.new(base + f.Up * (hz.Height + 4 + d / 2)), Color = palette.Violet, Material = "SmoothPlastic", Collide = false })
				add({ Class = "Part", Name = "BalloonString", Folder = "Decor", Size = Vector3.new(0.15, 4, 0.15), CFrame = CFrame.fromMatrix(base + f.Up * (hz.Height + 2), f.Right, f.Up), Color = palette.White, Material = "SmoothPlastic", Collide = false })
			elseif style == "Rock" then
				-- B1 Volcano: the boulder that falls onto the post while it warns (client animates
				-- it from the same bumper timing; contact is still the bumper's kick)
				add({ Class = "Part", Shape = "Ball", Name = "Rock", Folder = folder, Size = Vector3.new(d + 0.6, d + 0.6, d + 0.6), CFrame = CFrame.new(base + f.Up * (hz.Height + d / 2)), Color = palette.NavyRail, Material = "Slate", Collide = false, Attributes = { HazardId = hz.Id, Role = "Rock" } })
			end
		end
	end

	-- B1 world decor (never collides, never queried)
	local decor = def.Theme and def.Theme.Decor
	if decor == "Clouds" then
		for i = 1, #sections, 9 do
			local sec = sections[i]
			local side = (i % 2 == 0) and 1 or -1
			local size = 16 + (i * 7) % 14
			add({ Class = "Part", Shape = "Ball", Name = "Cloud", Folder = "Decor", Size = Vector3.new(size, size * 0.6, size), CFrame = CFrame.new(sec.Position + sec.Right * side * (sec.Width / 2 + 18 + size / 2) - sec.Up * 10), Color = palette.White, Material = "SmoothPlastic", Transparency = 0.15, Collide = false })
		end
	elseif decor == "Lava" then
		local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
		for _, sec in ipairs(sections) do
			minX, maxX = math.min(minX, sec.Position.X), math.max(maxX, sec.Position.X)
			minZ, maxZ = math.min(minZ, sec.Position.Z), math.max(maxZ, sec.Position.Z)
		end
		local y = layout.MinY - 45
		local pad = 120
		local x0, z0 = minX - pad, minZ - pad
		local w, l = maxX - minX + pad * 2, maxZ - minZ + pad * 2
		local nx, nz = math.ceil(w / 2000), math.ceil(l / 2000)
		for ix = 0, nx - 1 do
			for iz = 0, nz - 1 do
				local sx, sz = w / nx, l / nz
				add({ Class = "Part", Name = "LavaSheet", Folder = "Decor", Size = Vector3.new(sx, 1, sz), CFrame = CFrame.new(x0 + sx * (ix + 0.5), y, z0 + sz * (iz + 0.5)), Color = palette.Violet, Material = "Neon", Transparency = 0.1, Collide = false })
			end
		end
	end

	return specs
end

---------------------------------------------------------------------------------------------
-- Instance creation (server only)
---------------------------------------------------------------------------------------------
local function makeGui(part, gui)
	if gui.Kind == "Surface" then
		local surface = Instance.new("SurfaceGui")
		surface.Name = "Label"
		surface.Face = Enum.NormalId.Back -- faces players approaching along the track
		surface.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		surface.PixelsPerStud = 40
		surface.LightInfluence = 0
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Text = gui.Text
		label.TextScaled = true
		label.Font = Enum.Font.GothamBlack
		label.TextColor3 = gui.Color
		label.Parent = surface
		surface.Parent = part
	else
		local billboard = Instance.new("BillboardGui")
		billboard.Name = "Label"
		billboard.Size = UDim2.fromScale(30, 4.5) -- studs
		billboard.LightInfluence = 0
		billboard.MaxDistance = 220
		billboard.AlwaysOnTop = false
		local frame = Instance.new("Frame")
		frame.Size = UDim2.fromScale(1, 1)
		frame.BackgroundColor3 = GameConfig.Palette.Ink
		frame.BackgroundTransparency = 0.25
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.25, 0)
		corner.Parent = frame
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(0.94, 0.8)
		label.Position = UDim2.fromScale(0.03, 0.1)
		label.BackgroundTransparency = 1
		label.Text = gui.Text
		label.TextScaled = true
		label.Font = Enum.Font.GothamBold
		label.TextColor3 = gui.Color
		label.Parent = frame
		frame.Parent = billboard
		billboard.Parent = part
	end
end

local function makePart(spec, parent)
	local part = Instance.new(spec.Class == "WedgePart" and "WedgePart" or "Part")
	if spec.Shape == "Cylinder" then
		part.Shape = Enum.PartType.Cylinder
	elseif spec.Shape == "Ball" then
		part.Shape = Enum.PartType.Ball
	end
	part.Name = spec.Name or "Part"
	part.Anchored = true
	part.Size = spec.Size
	part.CFrame = spec.CFrame
	part.Color = spec.Color or GameConfig.Palette.NavyFloor
	part.Material = Enum.Material[spec.Material or "SmoothPlastic"]
	part.Transparency = spec.Transparency or 0
	part.Reflectance = spec.Reflectance or 0
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	local collide = spec.Collide ~= false
	part.CanCollide = collide
	part.CanQuery = collide -- decor is invisible to raycasts (camera, ground probe)
	part.CanTouch = false
	part.CastShadow = collide and spec.Folder == "Floor"
	if spec.Physics then
		local p = spec.Physics
		part.CustomPhysicalProperties = PhysicalProperties.new(p.Density, p.Friction, p.Elasticity, p.FrictionWeight, p.ElasticityWeight)
	end
	if spec.Attributes then
		for key, value in pairs(spec.Attributes) do
			part:SetAttribute(key, value)
		end
	end
	if spec.Gui then
		makeGui(part, spec.Gui)
	end
	part.Parent = parent
	return part
end

Builder.MakePart = makePart

-- Build the course under `parent` (normally Workspace). Returns the root Folder.
function Builder.Build(layout, parent, name)
	local root = Instance.new("Folder")
	root.Name = name
	root:SetAttribute("CourseId", layout.Definition.Id)
	root:SetAttribute("LayoutVersion", layout.Definition.LayoutVersion)

	local folders = {}
	local function folderFor(path)
		if folders[path] then
			return folders[path]
		end
		local parentFolder = root
		local soFar = nil
		for segment in string.gmatch(path, "[^/]+") do
			soFar = soFar and (soFar .. "/" .. segment) or segment
			local existing = folders[soFar]
			if not existing then
				existing = Instance.new("Folder")
				existing.Name = segment
				existing.Parent = parentFolder
				folders[soFar] = existing
			end
			parentFolder = existing
		end
		return parentFolder
	end
	for _, folderName in ipairs({ "Floor", "Rails", "Decor", "Hazards", "Gates", "Features" }) do
		folderFor(folderName)
	end

	local specs = Builder.ComputeSpecs(layout)
	for _, spec in ipairs(specs) do
		makePart(spec, folderFor(spec.Folder or "Decor"))
	end

	root.Parent = parent -- one replication burst, after everything exists
	return root, #specs
end

return Builder
