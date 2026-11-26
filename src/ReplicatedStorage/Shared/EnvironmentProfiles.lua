--[[
	EnvironmentProfiles (UI / environment overhaul, 2026-11-26) — a backdrop per map, keyed by
	the MapRegistry map id. Pure data + spec generators; EnvironmentController builds the parts
	on each client only (anchored, no collision, no queries, no touch, no shadows).

	Per map:
	  Lighting   VisualProfiles name (sky colour, fog, atmosphere)
	  Road       local floor recolour: a visible midtone, clearly apart from the cobalt marble
	  Edge       rail-top guide lights: kept neon but narrow (emission on small surfaces)
	  Accent     map accent (UI "Follow map" uses UIKit.MapAccents with the same values)
	  Course(layout, detail)  -> specs: signature landmark (every detail level), middle-
	             distance layers (Standard+), near-track framing (High). Everything stays
	             clear of the route: backdrop >= 150 studs from any section; near framing
	             outside the lane and at least 18 studs above the floor.
	  Hub(hubGeometry, chute, detail) -> specs: the hub's landmark + practice framing
	Detail: "Low" | "Standard" | "High". Low keeps lighting, road, edges, hazard tells and the
	signature landmark; it drops middle layers, near framing and the dense extras.
	Maps without a profile (none yet) get no backdrop: the registry decides what is playable.
]]

local Dressing = require(script.Parent:WaitForChild("Dressing"))
local TrackDefinitions = require(script.Parent:WaitForChild("TrackDefinitions"))

local EnvironmentProfiles = {}

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

local UP = Vector3.new(0, 1, 0)

EnvironmentProfiles.Levels = { Low = 1, Standard = 2, High = 3 }

local function level(detail)
	return EnvironmentProfiles.Levels[detail or ""] or 2
end
EnvironmentProfiles.Level = level

-- Course bounds (pure)
function EnvironmentProfiles.Bounds(layout)
	local minX, maxX, minY, maxY, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge, math.huge, -math.huge
	for _, sec in ipairs(layout.Sections) do
		local p = sec.Position
		minX, maxX = math.min(minX, p.X), math.max(maxX, p.X)
		minY, maxY = math.min(minY, p.Y), math.max(maxY, p.Y)
		minZ, maxZ = math.min(minZ, p.Z), math.max(maxZ, p.Z)
	end
	local center = Vector3.new((minX + maxX) / 2, (minY + maxY) / 2, (minZ + maxZ) / 2)
	local radius = math.max(maxX - minX, maxZ - minZ) / 2
	return center, radius, minY, maxY
end

-- deterministic pseudo-random (same backdrop on every client, every session)
local function rand(seed)
	local state = seed
	return function(a, b)
		state = (state * 1103515245 + 12345) % 2147483648
		return a + (b - a) * (state / 2147483648)
	end
end

-- Points on rings around the course, never closer than `minClear` to any section.
local function ringPoints(layout, center, radius, distances, count, seed, minClear)
	local r = rand(seed)
	local out = {}
	for ring, d in ipairs(distances) do
		for i = 1, count do
			local a = (i / count) * math.pi * 2 + r(0, 0.4) + ring * 0.37
			local p = center + Vector3.new(math.cos(a), 0, math.sin(a)) * (radius + d)
			local clear = true
			for _, sec in ipairs(layout.Sections) do
				local dx, dz = sec.Position.X - p.X, sec.Position.Z - p.Z
				if dx * dx + dz * dz < minClear * minClear then
					clear = false
					break
				end
			end
			if clear then
				out[#out + 1] = { position = p, ring = ring, roll = r(0, 1) }
			end
		end
	end
	return out
end

---------------------------------------------------------------------------------------------
-- Neon Foundry: cobalt dusk, layered factory silhouettes, suspended catwalks, cool-blue track
-- face with narrow cyan guide lights. Signature: the main turbine (Shared/Dressing).
---------------------------------------------------------------------------------------------
local function foundryCourse(layout, detail, add)
	local center, radius, minY = EnvironmentProfiles.Bounds(layout)
	local lv = level(detail)
	-- the prompt-05 dressing: turbine = signature; hazard warning marks and gate insets stay at
	-- every level (hazard tells); panel breaks and spines are Standard+ detail
	for _, spec in ipairs(Dressing.FoundrySpecs(layout, TrackDefinitions.SampleAtH)) do
		local n = spec.Name
		if n == "WarningMark" or n == "FrameInset" or n == "FrameInsetTop" then
			spec.Layer = "Track"
		elseif n == "PanelBreak" then
			spec.Layer = "TrackDetail"
		elseif string.sub(n, 1, 5) == "Spine" then
			spec.Layer = "Under"
		else
			spec.Layer = spec.Detail and "Mid" or "Signature"
		end
		add(spec)
	end
	if lv >= 2 then
		local tints = { rgb(30, 38, 70), rgb(42, 52, 90), rgb(58, 68, 110) } -- near -> far (into the fog)
		for _, pt in ipairs(ringPoints(layout, center, radius, { 360, 620, 900 }, 12, 11, 180)) do
			local w, h = 50 + pt.roll * 90, 90 + pt.roll * 200
			local base = Vector3.new(pt.position.X, minY - 120, pt.position.Z)
			add({ Name = "FactorySilhouette", Size = Vector3.new(w, h, w * 0.7), CFrame = CFrame.new(base + UP * (h / 2)), Color = tints[pt.ring], Material = "SmoothPlastic", Layer = "Mid" })
			if pt.ring == 1 and pt.roll > 0.35 then
				add({ Name = "FactoryWindows", Size = Vector3.new(w * 0.8, 0.8, w * 0.72), CFrame = CFrame.new(base + UP * (h * 0.7)), Color = pt.roll > 0.7 and rgb(255, 196, 96) or rgb(39, 215, 245), Material = "Neon", Layer = "Mid" })
			end
		end
	end
	if lv >= 3 then
		-- suspended catwalks high over the course every ~300 studs (outside the camera's lane view)
		for h = 150, (layout.TotalH or 0) - 150, 300 do
			local s = layout.Sections[1]
			for _, sec in ipairs(layout.Sections) do
				if sec.H >= h then
					s = sec
					break
				end
			end
			local p = s.Position + UP * 26
			local span = s.Width + 40
			add({ Name = "Catwalk", Size = Vector3.new(span, 0.8, 3), CFrame = CFrame.fromMatrix(p, s.Right, UP), Color = rgb(58, 66, 92), Material = "Metal", Layer = "Near" })
			add({ Name = "CatwalkLight", Size = Vector3.new(span, 0.15, 0.2), CFrame = CFrame.fromMatrix(p - UP * 0.5, s.Right, UP), Color = rgb(39, 215, 245), Material = "Neon", Layer = "Near" })
		end
	end
end

local function foundryHub(hub, chute, detail, add)
	local lv = level(detail)
	-- assembly arms beside the deck (signature of the hub): base, two segments, a claw
	local psi = math.rad(hub.ChuteHeadingDeg)
	local look = Vector3.new(math.sin(psi), 0, -math.cos(psi))
	local right = Vector3.new(math.cos(psi), 0, math.sin(psi))
	for i, side in ipairs({ -1, 1 }) do
		if lv >= 2 or i == 1 then
			local base = hub.Center - look * 20 + right * side * (hub.Radius + 26) - UP * 30
			add({ Name = "ArmBase", Shape = "Cylinder", Size = Vector3.new(8, 14, 14), CFrame = CFrame.fromMatrix(base, UP, right), Color = rgb(44, 52, 84), Material = "Metal", Layer = "Signature" })
			local elbow = base + UP * 34 + look * 6
			local a1 = (elbow - base)
			add({ Name = "ArmSegment", Size = Vector3.new(4, 4, a1.Magnitude), CFrame = CFrame.lookAt((base + elbow) / 2, elbow), Color = rgb(255, 212, 90), Material = "SmoothPlastic", Layer = "Signature" })
			local tip = elbow + look * 22 - right * side * 10 + UP * 6
			add({ Name = "ArmSegment", Size = Vector3.new(3, 3, (tip - elbow).Magnitude), CFrame = CFrame.lookAt((elbow + tip) / 2, tip), Color = rgb(255, 212, 90), Material = "SmoothPlastic", Layer = "Signature" })
			add({ Name = "ArmClaw", Size = Vector3.new(5, 2, 5), CFrame = CFrame.new(tip), Color = rgb(58, 66, 92), Material = "Metal", Layer = "Signature" })
			add({ Name = "ArmLight", Size = Vector3.new(0.6, 0.6, 0.6), CFrame = CFrame.new(tip - UP * 1.4), Color = rgb(39, 215, 245), Material = "Neon", Layer = "Signature" })
		end
	end
end

---------------------------------------------------------------------------------------------
-- Sky Carnival: peach daylight, floating islands, layered cumulus, bunting; clear sky behind
-- each landing (clouds stay below the course and far out). Signature: the ring island.
---------------------------------------------------------------------------------------------
local function cloud(add, p, size, layer, tint)
	add({ Name = "Cumulus", Shape = "Ball", Size = Vector3.new(size, size * 0.7, size), CFrame = CFrame.new(p), Color = tint or rgb(255, 250, 246), Material = "SmoothPlastic", Layer = layer })
	add({ Name = "Cumulus", Shape = "Ball", Size = Vector3.new(size * 0.7, size * 0.55, size * 0.7), CFrame = CFrame.new(p + Vector3.new(size * 0.45, -size * 0.05, size * 0.1)), Color = tint or rgb(255, 246, 240), Material = "SmoothPlastic", Layer = layer })
	add({ Name = "Cumulus", Shape = "Ball", Size = Vector3.new(size * 0.6, size * 0.5, size * 0.6), CFrame = CFrame.new(p + Vector3.new(-size * 0.42, -size * 0.08, -size * 0.12)), Color = tint or rgb(255, 242, 236), Material = "SmoothPlastic", Layer = layer })
end

local function island(add, p, size, layer)
	add({ Name = "IslandRock", Shape = "Cylinder", Size = Vector3.new(size * 0.9, size * 1.2, size * 1.2), CFrame = CFrame.fromMatrix(p - UP * size * 0.45, UP, Vector3.new(1, 0, 0)), Color = rgb(150, 120, 120), Material = "Slate", Layer = layer })
	add({ Name = "IslandTop", Shape = "Cylinder", Size = Vector3.new(size * 0.18, size * 1.3, size * 1.3), CFrame = CFrame.fromMatrix(p, UP, Vector3.new(1, 0, 0)), Color = rgb(160, 233, 206), Material = "Grass", Layer = layer })
end

local function skyCourse(layout, detail, add)
	local center, radius, minY = EnvironmentProfiles.Bounds(layout)
	local lv = level(detail)
	-- signature: a big ring island off one side of the course
	local sig = center + Vector3.new(radius + 520, -60, -radius * 0.3)
	island(add, sig, 140, "Signature")
	add({ Name = "SkyRing", Shape = "Cylinder", Size = Vector3.new(8, 150, 150), CFrame = CFrame.fromMatrix(sig + UP * 90, Vector3.new(1, 0, 0), UP), Color = rgb(240, 139, 174), Material = "SmoothPlastic", Layer = "Signature" })
	if lv >= 2 then
		for _, pt in ipairs(ringPoints(layout, center, radius, { 300, 650 }, 8, 23, 200)) do
			island(add, pt.position + UP * ((pt.roll - 0.5) * 120 - 20), 40 + pt.roll * 60, "Mid")
		end
		-- cumulus layers below the course (the sky behind the landings stays clear)
		for _, pt in ipairs(ringPoints(layout, center, radius * 0.6, { 0, 380, 760 }, 10, 31, 0)) do
			cloud(add, Vector3.new(pt.position.X, minY - 90 - pt.ring * 40, pt.position.Z), 60 + pt.roll * 70, "Mid")
		end
	end
	if lv >= 3 then
		-- bunting strings on poles beside the course every ~240 studs (outside the lane)
		for h = 120, (layout.TotalH or 0) - 120, 240 do
			local s = layout.Sections[1]
			for _, sec in ipairs(layout.Sections) do
				if sec.H >= h then
					s = sec
					break
				end
			end
			for _, side in ipairs({ -1, 1 }) do
				local pole = s.Position + s.Right * side * (s.Width / 2 + 6)
				add({ Name = "BuntingPole", Size = Vector3.new(0.6, 24, 0.6), CFrame = CFrame.new(pole + UP * 12), Color = rgb(40, 70, 141), Material = "SmoothPlastic", Layer = "Near" })
			end
			local a = s.Position - s.Right * (s.Width / 2 + 6) + UP * 22
			local b = s.Position + s.Right * (s.Width / 2 + 6) + UP * 22
			add({ Name = "BuntingLine", Size = Vector3.new(0.15, 0.15, (b - a).Magnitude), CFrame = CFrame.lookAt((a + b) / 2, b), Color = rgb(255, 242, 203), Material = "SmoothPlastic", Layer = "Near" })
			for k = 1, 7 do
				local p = a + (b - a) * (k / 8) - UP * 1
				add({ Name = "Pennant", Size = Vector3.new(1.6, 1.8, 0.1), CFrame = CFrame.fromMatrix(p, (b - a).Unit, UP), Color = k % 2 == 0 and rgb(240, 139, 174) or rgb(160, 233, 206), Material = "SmoothPlastic", Layer = "Near" })
			end
		end
	end
end

local function skyHub(hub, chute, detail, add)
	local lv = level(detail)
	-- tethered balloons above the practice drum (signature of the hub)
	local drum = nil
	for _, hz in ipairs(chute and chute.Hazards or {}) do
		if hz.Kind == "Trampoline" then
			drum = hz.Frame
		end
	end
	if drum then
		local colors = { rgb(240, 139, 174), rgb(160, 233, 206), rgb(255, 196, 96) }
		for i = 1, (lv >= 2 and 3 or 1) do
			local offset = drum.Right * ((i - 2) * 16) + drum.Forward * ((i % 2) * 8)
			local anchor = drum.Position + drum.Right * ((i - 2) * (drum.Width / 2 + 5))
			local balloon = drum.Position + offset + UP * (34 + i * 4)
			add({ Name = "DrumBalloon", Shape = "Ball", Size = Vector3.new(9, 10, 9), CFrame = CFrame.new(balloon), Color = colors[i], Material = "SmoothPlastic", Layer = "Signature" })
			add({ Name = "DrumTether", Size = Vector3.new(0.15, 0.15, (balloon - anchor).Magnitude), CFrame = CFrame.lookAt((balloon + anchor) / 2, balloon), Color = rgb(255, 242, 203), Material = "SmoothPlastic", Layer = "Signature" })
		end
	end
	if lv >= 2 then
		-- ticket canopy over the MAPS kiosk side of the deck
		local psi = math.rad(hub.ChuteHeadingDeg)
		local look = Vector3.new(math.sin(psi), 0, -math.cos(psi))
		local right = Vector3.new(math.cos(psi), 0, math.sin(psi))
		local kiosk = hub.Center - right * (hub.SpawnRingRadius + 9) - look * 4
		for k = -2, 2 do
			add({ Name = "TicketCanopy", Size = Vector3.new(3, 0.3, 10), CFrame = CFrame.fromMatrix(kiosk + look * (k * 3) + UP * 10, look, UP) * CFrame.Angles(0, 0, math.rad(12)), Color = k % 2 == 0 and rgb(240, 139, 174) or rgb(255, 242, 203), Material = "Fabric", Layer = "Mid" })
		end
		cloud(add, hub.Center + Vector3.new(0, -40, 0), 90, "Mid")
	end
end

---------------------------------------------------------------------------------------------
-- Volcano Vault: smoky copper sky, stepped basalt ridges, distant lava channels; the race
-- surface stays a neutral warm grey. Signature: the stepped volcano cone with a glowing rim.
---------------------------------------------------------------------------------------------
local function volcanoCourse(layout, detail, add)
	local center, radius, minY = EnvironmentProfiles.Bounds(layout)
	local lv = level(detail)
	local cone = center + Vector3.new(-(radius + 700), minY - 140, radius * 0.2)
	for step = 0, 3 do
		local w = 520 - step * 110
		add({ Name = "VolcanoStep", Shape = "Cylinder", Size = Vector3.new(70, w, w), CFrame = CFrame.fromMatrix(cone + UP * (35 + step * 70), UP, Vector3.new(1, 0, 0)), Color = step % 2 == 0 and rgb(41, 35, 41) or rgb(54, 44, 48), Material = "Basalt", Layer = "Signature" })
	end
	add({ Name = "CraterGlow", Shape = "Cylinder", Size = Vector3.new(2, 150, 150), CFrame = CFrame.fromMatrix(cone + UP * 281, UP, Vector3.new(1, 0, 0)), Color = rgb(255, 112, 71), Material = "Neon", Layer = "Signature" })
	if lv >= 2 then
		for _, pt in ipairs(ringPoints(layout, center, radius, { 340, 700 }, 10, 41, 200)) do
			local w, h = 120 + pt.roll * 140, 60 + pt.roll * 120
			for k = 0, 2 do
				add({ Name = "BasaltRidge", Size = Vector3.new(w - k * 30, h * 0.4, w * 0.5), CFrame = CFrame.new(Vector3.new(pt.position.X, minY - 100 + k * h * 0.35, pt.position.Z)), Color = pt.ring == 1 and rgb(41, 35, 41) or rgb(66, 50, 50), Material = "Basalt", Layer = "Mid" })
			end
		end
		-- distant lava channels: long, low, narrow glowing lines far below the course
		local r = rand(53)
		for i = 1, 5 do
			local a = i / 5 * math.pi * 2 + r(0, 0.6)
			local p = center + Vector3.new(math.cos(a), 0, math.sin(a)) * (radius + 500)
			add({ Name = "LavaChannel", Size = Vector3.new(6, 1, 260), CFrame = CFrame.new(Vector3.new(p.X, minY - 170, p.Z)) * CFrame.Angles(0, a, 0), Color = rgb(255, 112, 71), Material = "Neon", Layer = "Mid" })
		end
	end
	if lv >= 3 then
		local r = rand(61)
		for i = 1, 6 do
			local a = i / 6 * math.pi * 2 + r(0, 0.5)
			local p = center + Vector3.new(math.cos(a), 0, math.sin(a)) * (radius + 260)
			add({ Name = "SmokeColumn", Shape = "Cylinder", Size = Vector3.new(160, 22, 22), CFrame = CFrame.fromMatrix(Vector3.new(p.X, minY - 40, p.Z), UP, Vector3.new(1, 0, 0)), Color = rgb(110, 96, 92), Material = "SmoothPlastic", Transparency = 0.55, Layer = "Near" })
		end
	end
end

local function volcanoHub(hub, chute, detail, add)
	local lv = level(detail)
	-- vent field below the deck (signature of the hub)
	local r = rand(71)
	for i = 1, (lv >= 2 and 9 or 3) do
		local a = i / 9 * math.pi * 2 + r(0, 0.4)
		local p = hub.Center + Vector3.new(math.cos(a), 0, math.sin(a)) * (hub.Radius + 30 + r(0, 50)) - UP * (36 + r(0, 20))
		add({ Name = "Vent", Shape = "Cylinder", Size = Vector3.new(14, 16, 16), CFrame = CFrame.fromMatrix(p, UP, Vector3.new(1, 0, 0)), Color = rgb(41, 35, 41), Material = "Basalt", Layer = "Signature" })
		add({ Name = "VentGlow", Shape = "Cylinder", Size = Vector3.new(0.4, 9, 9), CFrame = CFrame.fromMatrix(p + UP * 7.2, UP, Vector3.new(1, 0, 0)), Color = rgb(255, 112, 71), Material = "Neon", Layer = "Signature" })
	end
	if lv >= 2 then
		-- warm shelter over the back of the deck
		local psi = math.rad(hub.ChuteHeadingDeg)
		local look = Vector3.new(math.sin(psi), 0, -math.cos(psi))
		local right = Vector3.new(math.cos(psi), 0, math.sin(psi))
		local roof = hub.Center - look * (hub.Radius - 12) + UP * 13
		add({ Name = "ShelterRoof", Size = Vector3.new(40, 1, 16), CFrame = CFrame.fromMatrix(roof, right, UP), Color = rgb(70, 58, 60), Material = "Slate", Layer = "Mid" })
		add({ Name = "ShelterLight", Size = Vector3.new(36, 0.2, 0.4), CFrame = CFrame.fromMatrix(roof - UP * 0.6 + look * 6, right, UP), Color = rgb(255, 189, 93), Material = "Neon", Layer = "Mid" })
		for _, s in ipairs({ -1, 1 }) do
			add({ Name = "ShelterPost", Size = Vector3.new(1, 13, 1), CFrame = CFrame.new(roof + right * s * 19 - UP * 6.5 + look * 7), Color = rgb(70, 58, 60), Material = "Slate", Layer = "Mid" })
		end
	end
end

---------------------------------------------------------------------------------------------
EnvironmentProfiles.Maps = {
	NeonFoundry_A4 = {
		Lighting = "NeonFoundry",
		Road = rgb(92, 110, 146), -- cool-blue midtone track face
		Edge = { Color = rgb(39, 215, 245), Width = 0.28, Height = 0.14 },
		Accent = rgb(39, 215, 245),
		Course = foundryCourse,
		UsesDressing = true, -- gate pillars restyled as dark metal (insets carry the colour)
	},
	SkyCarnival_B1 = {
		Lighting = "SkyCarnival",
		Road = rgb(184, 172, 214), -- soft lavender midtone (the light theme kept, a touch deeper)
		Edge = { Color = rgb(255, 242, 203), Width = 0.28, Height = 0.14 },
		Accent = rgb(240, 139, 174),
		Course = skyCourse,
	},
	VolcanoVault_B1 = {
		Lighting = "VolcanoVault",
		Road = rgb(118, 110, 108), -- neutral warm grey: contrasts with lava and the marble
		Edge = { Color = rgb(255, 189, 93), Width = 0.28, Height = 0.14 },
		Accent = rgb(255, 189, 93),
		Course = volcanoCourse,
	},
}

EnvironmentProfiles.Hubs = {
	OrbitalGarage = { Build = foundryHub, ChuteRoad = rgb(92, 110, 146), UsesGarageDeck = true },
	BalloonTerminal = { Build = skyHub, ChuteRoad = rgb(184, 172, 214) },
	BasaltDeck = { Build = volcanoHub, ChuteRoad = rgb(118, 110, 108) },
}

-- Keep a spec at this detail level? Layers: Signature / Track (hazard tells, gate insets):
-- always; Mid / TrackDetail / Under: Standard+; Near (framing by the course): High only.
function EnvironmentProfiles.Keep(spec, detail)
	local lv = level(detail)
	if spec.Layer == "Near" then
		return lv >= 3
	elseif spec.Layer == "Mid" or spec.Layer == "TrackDetail" or spec.Layer == "Under" then
		return lv >= 2
	end
	return true
end

-- Hub keep-out (owner playtest 2026-11-26: a floating island landed in the middle of Balloon
-- Terminal). No course backdrop may come within HubClearance studs (horizontally) of any hub
-- deck or its practice lane, at any height that could be seen from the deck.
EnvironmentProfiles.HubClearance = 320
EnvironmentProfiles.HubClearanceHeight = 400
local MapRegistry = require(script.Parent:WaitForChild("MapRegistry"))

function EnvironmentProfiles.NearHub(position, extent)
	extent = extent or 0
	for _, entry in ipairs(MapRegistry.Hubs) do
		local c = entry.Geometry.Center
		-- the practice lane leaves toward the chute heading: centre the keep-out between them
		local psi = math.rad(entry.Geometry.ChuteHeadingDeg or 0)
		local mid = c + Vector3.new(math.sin(psi), 0, -math.cos(psi)) * 90
		local dx, dz = position.X - mid.X, position.Z - mid.Z
		local reach = EnvironmentProfiles.HubClearance + extent
		if dx * dx + dz * dz < reach * reach and math.abs(position.Y - c.Y) < EnvironmentProfiles.HubClearanceHeight + extent then
			return true
		end
	end
	return false
end

function EnvironmentProfiles.CourseSpecs(mapId, layout, detail)
	local profile = EnvironmentProfiles.Maps[mapId or ""]
	local out = {}
	if not (profile and layout) then
		return out
	end
	profile.Course(layout, detail, function(spec)
		local onCourse = spec.Layer == "Track" or spec.Layer == "TrackDetail" or spec.Layer == "Under"
		local extent = math.max(spec.Size.X, spec.Size.Y, spec.Size.Z) / 2
		if EnvironmentProfiles.Keep(spec, detail) and (onCourse or not EnvironmentProfiles.NearHub(spec.CFrame.Position, extent)) then
			out[#out + 1] = spec
		end
	end)
	return out
end

function EnvironmentProfiles.HubSpecs(hubId, hub, chute, detail)
	local profile = EnvironmentProfiles.Hubs[hubId or ""]
	local out = {}
	if not (profile and hub) then
		return out
	end
	profile.Build(hub, chute, detail, function(spec)
		if EnvironmentProfiles.Keep(spec, detail) then
			out[#out + 1] = spec
		end
	end)
	return out
end

return EnvironmentProfiles
