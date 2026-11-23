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

function Builder.ComputeSpecs(layout)
	local def = layout.Definition
	local palette = GameConfig.Palette
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
		for _, q in ipairs(Builder.QuadFloorSpecs(L0, R0, L1, R1, s0.Up, s1.Up, thickness)) do
			q.Name = "Floor_" .. piece.Name
			q.Folder = "Floor"
			q.Color = color
			q.Material = "SmoothPlastic"
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
				wall.Material = "SmoothPlastic"
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
		wall.Material = "SmoothPlastic"
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
			local folder = "Hazards/PulseBumper" .. i
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
				Attributes = { HazardType = "PulseBumper", Radius = hz.Radius, Height = hz.Height },
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
	for _, folderName in ipairs({ "Floor", "Rails", "Decor", "Hazards", "Gates" }) do
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
