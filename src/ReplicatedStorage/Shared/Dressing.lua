--[[
	Dressing (promo pack prompts 05 / 06) — presentation-only parts the CLIENT builds locally for
	players with the NewHubs gate: nothing here replicates, collides, is raycast or touched, so
	race lines, checkpoints, physics and other players are untouched. Pure spec generators.

	FoundrySpecs(layout)  prompt 05, Neon Foundry visual language:
	  * dark metal panel breaks across the rolling surface (every PanelSpacing studs)
	  * industrial spine supports under the track (dark-navy chassis)
	  * amber warning edge marks (amber / ink blocks) on both edges around every hazard
	  * violet checkpoint frames: thin neon insets on dark pillars (emission on small surfaces)
	  * a distant turbine landmark (static ring + blades) off the side of the course
	  FloorColor / RecolorNames say how the client recolours existing parts locally.
	GarageSpecs(hub)      prompt 06, Orbital Garage as a foundry observation deck:
	  * a crisp central violet ring, small cyan edge lights on the rim
	  * an OVERLOOK window on the rim facing the Neon Foundry
	  * a PRACTICE arch over the chute, a MAPS kiosk + selector pad beside the spawn ring,
	    a RACE DEPARTURES sign with a painted lane
	  Navigation panels are static SurfaceGui text (readable on Low).
	Every spec: { Name, Size, CFrame, Color, Material, Transparency?, Shape?, Detail?, Gui?, Attributes? }
	Detail = true parts are skipped on Low graphics.
]]

local Dressing = {}

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

Dressing.Palette = {
	Chassis = rgb(16, 23, 45), -- #10172D
	Surface = rgb(80, 118, 170), -- broad cool-blue rolling surface (lighter than the cobalt marble)
	Cyan = rgb(39, 215, 245), -- #27D7F5
	Violet = rgb(160, 120, 255), -- #A078FF
	Warning = rgb(255, 212, 90), -- #FFD45A
	Ink = rgb(12, 14, 26),
	Metal = rgb(58, 66, 92),
}
Dressing.PanelSpacing = 24
Dressing.SpineSpacing = 72
Dressing.FloorColor = Dressing.Palette.Surface
-- existing parts the client recolours / restyles locally (Name prefix -> style)
Dressing.Restyle = {
	Floor = { Color = Dressing.Palette.Surface }, -- Floor_* except start / finish pieces
	GatePillar = { Color = Dressing.Palette.Metal, Material = "Metal" }, -- frames get neon insets instead
}

local UP = Vector3.new(0, 1, 0)

local function onFloor(frame, lateral, lift)
	return CFrame.fromMatrix(frame.Position + frame.Right * (lateral or 0) + frame.Up * (lift or 0), frame.Right, frame.Up)
end

-- How far a support can drop below `position` (at route distance h) before it would reach
-- another stretch of the same course. Pure; returns 0..maxDrop.
function Dressing.ClearDrop(layout, position, h, maxDrop)
	local drop = maxDrop
	for _, sec in ipairs(layout.Sections) do
		if math.abs(sec.H - h) > 40 then
			local d = sec.Position - position
			local flat = math.sqrt(d.X * d.X + d.Z * d.Z)
			if flat < sec.Width / 2 + 6 and d.Y < 0 and -d.Y < maxDrop + 6 then
				drop = math.min(drop, -d.Y - 6)
			end
		end
	end
	return math.max(0, drop)
end

function Dressing.FoundrySpecs(layout, sample)
	local P = Dressing.Palette
	local specs = {}
	local function add(spec)
		specs[#specs + 1] = spec
		return spec
	end
	local total = layout.TotalH or 0
	local start = layout.StartLineFrame and layout.StartLineFrame.H or 0
	local finish = layout.FinishLineFrame and layout.FinishLineFrame.H or total

	-- panel breaks (dark seams across the floor)
	for h = start + Dressing.PanelSpacing, finish - 4, Dressing.PanelSpacing do
		local f = sample(layout, h)
		add({ Name = "PanelBreak", Size = Vector3.new(f.Width - 0.4, 0.06, 0.35), CFrame = onFloor(f, 0, 0.03), Color = P.Chassis, Material = "Metal", Detail = true })
	end

	-- spine supports: column under the floor down into the dark, with a cross brace. A spine
	-- never pierces a lower stretch of the same course (switchbacks): it is shortened to stop
	-- above it, or skipped.
	for h = 18, total - 18, Dressing.SpineSpacing do
		local f = sample(layout, h)
		local top = f.Position - UP * 1.2
		local height = Dressing.ClearDrop(layout, f.Position, h, 46)
		if height >= 8 then
			add({ Name = "Spine", Size = Vector3.new(2.2, height, 2.2), CFrame = CFrame.new(top - UP * (height / 2)), Color = P.Chassis, Material = "Metal", Detail = true })
			add({ Name = "SpineBrace", Size = Vector3.new(f.Width * 0.8, 1.2, 1.4), CFrame = CFrame.fromMatrix(top - UP * 1.4, f.Right, UP), Color = P.Metal, Material = "Metal", Detail = true })
			add({ Name = "SpineLight", Size = Vector3.new(0.5, 0.5, 0.5), CFrame = CFrame.new(top - UP * 6 + f.Right * 1.4), Color = P.Cyan, Material = "Neon" })
		end
	end

	-- amber warning edge marks around each hazard (both edges, alternating amber / ink)
	for _, hz in ipairs(layout.Hazards or {}) do
		local center = hz.Frame and hz.Frame.H
		if center then
			local from, to = center - 14, center + 14
			if hz.FromFrame and hz.ToFrame then
				from, to = hz.FromFrame.H - 4, hz.ToFrame.H + 4
			end
			local i = 0
			for h = from, to, 2.4 do
				local f = sample(layout, h)
				for _, side in ipairs({ -1, 1 }) do
					add({ Name = "WarningMark", Size = Vector3.new(1.1, 0.07, 2.2), CFrame = onFloor(f, side * (f.Width / 2 - 0.8), 0.04), Color = i % 2 == 0 and P.Warning or P.Ink, Material = i % 2 == 0 and "Neon" or "SmoothPlastic", Transparency = 0.05 })
				end
				i = i + 1
			end
		end
	end

	-- gate frames: the pillars are restyled dark metal; thin neon insets carry the colour
	-- (violet checkpoints, cyan start, mint finish) so emission sits on small surfaces
	local insetColor = { Checkpoint = P.Violet, Start = P.Cyan, Finish = rgb(140, 240, 200) }
	for _, gate in ipairs(layout.Gates or {}) do
		if gate.Frame and insetColor[gate.Kind] then
			local f = gate.Frame
			local half = f.Width / 2 + 1.2 + 1.2
			local base = onFloor(f, 0, 0)
			local color = insetColor[gate.Kind]
			for _, side in ipairs({ -1, 1 }) do
				for _, z in ipairs({ -0.95, 0.95 }) do
					add({ Name = "FrameInset", Size = Vector3.new(0.3, 11, 0.3), CFrame = base * CFrame.new(side * (half - 0.95), 6, z), Color = color, Material = "Neon" })
				end
			end
			add({ Name = "FrameInsetTop", Size = Vector3.new(half * 2, 0.3, 0.3), CFrame = base * CFrame.new(0, 11.2, -0.95), Color = color, Material = "Neon" })
		end
	end

	-- distant turbine landmark (static): beside the course's middle, well clear of the route
	local minX, maxX, minZ, maxZ, sumY, n = math.huge, -math.huge, math.huge, -math.huge, 0, 0
	for _, sec in ipairs(layout.Sections) do
		local p = sec.Position
		minX, maxX = math.min(minX, p.X), math.max(maxX, p.X)
		minZ, maxZ = math.min(minZ, p.Z), math.max(maxZ, p.Z)
		sumY, n = sumY + p.Y, n + 1
	end
	if n > 0 then
		local center = Vector3.new(minX - 420, sumY / n + 40, (minZ + maxZ) / 2)
		local facing = Vector3.new(1, 0, 0) -- the ring faces the course
		local side = Vector3.new(0, 0, 1)
		local ringR = 90
		for k = 0, 23 do
			local a = k / 24 * math.pi * 2
			local p = center + (UP * math.cos(a) + side * math.sin(a)) * ringR
			local tangent = (UP * -math.sin(a) + side * math.cos(a))
			add({ Name = "TurbineRing", Size = Vector3.new(6, 6, 2 * math.pi * ringR / 24 + 1), CFrame = CFrame.fromMatrix(p, facing, tangent:Cross(facing)) * CFrame.Angles(0, 0, 0), Color = P.Metal, Material = "Metal" })
		end
		for k = 0, 5 do
			local a = k / 6 * math.pi * 2 + 0.3
			local dir = UP * math.cos(a) + side * math.sin(a)
			add({ Name = "TurbineBlade", Size = Vector3.new(2, 80, 14), CFrame = CFrame.fromMatrix(center + dir * 44, dir:Cross(facing), dir) * CFrame.Angles(0, math.rad(25), 0), Color = P.Chassis, Material = "Metal", Detail = true })
		end
		add({ Name = "TurbineHub", Shape = "Cylinder", Size = Vector3.new(10, 22, 22), CFrame = CFrame.fromMatrix(center, facing, UP), Color = P.Metal, Material = "Metal" })
		add({ Name = "TurbineGlow", Shape = "Cylinder", Size = Vector3.new(0.3, 8, 8), CFrame = CFrame.fromMatrix(center + facing * 5.2, facing, UP), Color = P.Cyan, Material = "Neon" })
	end
	return specs
end

-- prompt 06: Orbital Garage observation deck. hub = TrackDefinitions.Hub geometry; course =
-- the Foundry layout (for the overlook direction).
function Dressing.GarageSpecs(hub, course, chuteWidth)
	local P = Dressing.Palette
	local specs = {}
	local function add(spec)
		specs[#specs + 1] = spec
		return spec
	end
	local psi = math.rad(hub.ChuteHeadingDeg)
	local look = Vector3.new(math.sin(psi), 0, -math.cos(psi))
	local right = Vector3.new(math.cos(psi), 0, math.sin(psi))
	local R = hub.Radius

	add({ Name = "VioletRing", Shape = "Cylinder", Size = Vector3.new(0.08, 10, 10), CFrame = CFrame.fromMatrix(hub.Center + UP * 0.07, UP, right), Color = P.Violet, Material = "Neon", Transparency = 0.1 })
	add({ Name = "VioletRingInner", Shape = "Cylinder", Size = Vector3.new(0.09, 8.6, 8.6), CFrame = CFrame.fromMatrix(hub.Center + UP * 0.075, UP, right), Color = P.Chassis, Material = "SmoothPlastic" })
	for k = 0, 23 do
		local a = k / 24 * math.pi * 2
		local dir = look * math.cos(a) + right * math.sin(a)
		if dir:Dot(look) < 0.93 then -- not across the chute opening
			add({ Name = "EdgeLight", Size = Vector3.new(0.6, 0.35, 0.6), CFrame = CFrame.new(hub.Center + dir * (R - 0.4) + UP * 0.2), Color = P.Cyan, Material = "Neon" })
		end
	end

	-- overlook: a framed window on the rim facing the course
	local toCourse = look
	if course and course.Sections and course.Sections[1] then
		local d = course.Sections[math.floor(#course.Sections / 2)].Position - hub.Center
		toCourse = Vector3.new(d.X, 0, d.Z).Unit
		if toCourse:Dot(look) > 0.8 then
			toCourse = (toCourse - look * 0.9).Unit -- never over the chute opening
		end
	end
	local across = toCourse:Cross(UP)
	local window = hub.Center + toCourse * (R + 0.8) + UP * 6
	add({ Name = "OverlookGlass", Size = Vector3.new(16, 7, 0.3), CFrame = CFrame.fromMatrix(window, across, UP), Color = P.Cyan, Material = "Glass", Transparency = 0.7 })
	for _, s in ipairs({ -1, 1 }) do
		add({ Name = "OverlookFrame", Size = Vector3.new(0.6, 8, 0.6), CFrame = CFrame.new(window + across * (s * 8.3)), Color = P.Metal, Material = "Metal" })
	end
	add({ Name = "OverlookFrameTop", Size = Vector3.new(17.2, 0.6, 0.6), CFrame = CFrame.fromMatrix(window + UP * 3.8, across, UP), Color = P.Violet, Material = "Neon" })
	local overSign = window + UP * 5.4 - toCourse * 0.2
	add({ Name = "OverlookSign", Size = Vector3.new(12, 1.8, 0.2), CFrame = CFrame.lookAt(overSign, overSign + toCourse), Color = P.Ink, Material = "SmoothPlastic", Gui = { Text = "OVERLOOK - NEON FOUNDRY", Color = P.Cyan } })

	-- practice entrance arch over the chute
	local archBase = hub.Center + look * (R - 1)
	local half = (chuteWidth or 18) / 2 + 1.5
	for _, side in ipairs({ -1, 1 }) do
		add({ Name = "PracticeArchPost", Size = Vector3.new(1, 10, 1), CFrame = CFrame.new(archBase + right * (side * half) + UP * 5), Color = P.Metal, Material = "Metal" })
	end
	local archSign = archBase + UP * 10.5
	add({ Name = "PracticeArch", Size = Vector3.new(half * 2 + 1, 2.4, 0.4), CFrame = CFrame.lookAt(archSign, archSign + look), Color = P.Ink, Material = "SmoothPlastic", Gui = { Text = "PRACTICE CHUTE", Color = P.Cyan } })

	-- MAPS kiosk + selector pad beside the spawn ring (left side; the right side has the pedestal)
	local kiosk = hub.Center - right * (hub.SpawnRingRadius + 9) - look * 4
	local pad = hub.Center - right * (hub.SpawnRingRadius + 4.5) - look * 4
	local toCenter = (hub.Center - kiosk).Unit
	add({ Name = "KioskBody", Size = Vector3.new(6, 6, 3), CFrame = CFrame.lookAt(kiosk + UP * 3, kiosk + UP * 3 + toCenter), Color = P.Chassis, Material = "Metal" })
	add({ Name = "KioskRoof", Size = Vector3.new(7, 0.6, 4), CFrame = CFrame.lookAt(kiosk + UP * 6.4, kiosk + UP * 6.4 + toCenter), Color = P.Violet, Material = "Neon" })
	local kioskSign = kiosk + UP * 4 + toCenter * 1.6
	add({ Name = "KioskSign", Size = Vector3.new(5, 2, 0.2), CFrame = CFrame.lookAt(kioskSign, kioskSign - toCenter), Color = P.Ink, Material = "SmoothPlastic", Gui = { Text = "MAPS", Color = P.Cyan } })
	add({ Name = "SelectorPad", Shape = "Cylinder", Size = Vector3.new(0.12, 7, 7), CFrame = CFrame.fromMatrix(pad + UP * 0.06, UP, right), Color = P.Cyan, Material = "Neon", Transparency = 0.25, Attributes = { TC_Selector = true, Radius = 3.5 } })

	-- race departures: ahead-right of the ring, toward the board, with a painted lane
	local dep = hub.Center + right * 12 + look * 22
	local depSign = dep + UP * 5
	local depFacing = (hub.Center - dep).Unit
	add({ Name = "DeparturesSign", Size = Vector3.new(12, 3.2, 0.4), CFrame = CFrame.lookAt(depSign, depSign - depFacing), Color = P.Ink, Material = "SmoothPlastic", Gui = { Text = "RACE DEPARTURES - TAP JOIN RACE", Color = P.Warning } })
	for i = 0, 2 do
		local p = hub.Center + (dep - hub.Center).Unit * (hub.SpawnRingRadius + 1.5 + i * 2.2)
		add({ Name = "LaneStripe", Size = Vector3.new(1.2, 0.08, 4), CFrame = CFrame.fromMatrix(p + UP * 0.05, (dep - hub.Center).Unit, UP), Color = P.Warning, Material = "Neon", Transparency = 0.3 })
	end
	return specs
end

return Dressing
