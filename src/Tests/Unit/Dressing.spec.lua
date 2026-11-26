--[[
	Dressing.spec — promo pack prompts 05 / 06: the Neon Foundry visual language and the Orbital
	Garage observation deck (client-local presentation parts). Pure modules + a source read.
]]

local Spec = {}

local function luminance(c)
	return 0.2126 * c.R + 0.7152 * c.G + 0.0722 * c.B
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
	local D, TD = m.Dressing, m.TrackDefinitions
	if not (D and TD) then
		check("dressing module loads", false)
		return results
	end
	local radius = m.PhysicsConfig.Ball.Radius
	local layout = TD.Generate(TD.NeonFoundry, radius)
	local specs = D.FoundrySpecs(layout, TD.SampleAtH)
	local count, sane, by, detail = 0, true, {}, 0
	for _, spec in ipairs(specs) do
		count = count + 1
		local sz = spec.Size
		if not (sz and sz.X > 0 and sz.Y > 0 and sz.Z > 0 and sz.X <= 2048 and sz.Y <= 2048 and sz.Z <= 2048) then
			sane = false
		end
		by[spec.Name] = (by[spec.Name] or 0) + 1
		if spec.Detail then
			detail = detail + 1
		end
	end
	results.info[#results.info + 1] = string.format("Foundry dressing: %d local parts (%d detail, hidden on Low)", count, detail)
	check("Foundry dressing builds (all sizes valid) and stays small (< 800 parts)", sane and count < 800, tostring(count))
	check("metal panel breaks across the rolling surface", (by.PanelBreak or 0) >= math.floor(layout.Route.total / D.PanelSpacing / 1.3))
	check("industrial spine supports under the track", (by.Spine or 0) >= 10)
	check("amber warning edge marks at every hazard (both edges)", (by.WarningMark or 0) >= #layout.Hazards * 4)
	local cps = #layout.Checkpoints
	check("violet checkpoint frames on every checkpoint (+ start / finish insets)", (by.FrameInset or 0) == (cps + 2) * 4 and (by.FrameInsetTop or 0) == cps + 2)
	check("a distant turbine landmark", (by.TurbineRing or 0) == 24 and (by.TurbineBlade or 0) == 6 and (by.TurbineHub or 0) == 1)

	-- spines never pierce a lower stretch of the course (switchbacks)
	local pierce = 0
	for _, spec in ipairs(specs) do
		if spec.Name == "Spine" then
			local c = spec.CFrame.Position
			local top, bottom = c.Y + spec.Size.Y / 2, c.Y - spec.Size.Y / 2
			local ownH, best = 0, math.huge
			for _, sec in ipairs(layout.Sections) do
				local dist = (sec.Position - Vector3.new(c.X, top, c.Z)).Magnitude
				if dist < best then
					best, ownH = dist, sec.H
				end
			end
			for _, sec in ipairs(layout.Sections) do
				local dx, dz = sec.Position.X - c.X, sec.Position.Z - c.Z
				-- another stretch (not the spine's own few studs of floor) inside the column's reach
				if math.abs(sec.H - ownH) > 30 and math.sqrt(dx * dx + dz * dz) < sec.Width / 2 + 2 and sec.Position.Y < top - 3 and sec.Position.Y > bottom - 2 then
					pierce = pierce + 1
				end
			end
		end
	end
	check("no support pierces a lower stretch of track", pierce == 0, tostring(pierce))
	local far = math.huge
	for _, spec in ipairs(specs) do
		if spec.Name == "TurbineHub" then
			for _, sec in ipairs(layout.Sections) do
				far = math.min(far, (sec.Position - spec.CFrame.Position).Magnitude)
			end
		end
	end
	check("the turbine stays well away from the route (>= 300 studs)", far >= 300, string.format("%.0f", far))
	-- readable marble: the rolling surface differs clearly in brightness from the cobalt marble
	local cobalt = Color3.fromRGB(40, 90, 220)
	local surface = D.Palette.Surface
	check("cool-blue surface is lighter than the cobalt marble and the navy chassis", luminance(surface) > luminance(cobalt) + 0.05 and luminance(surface) > luminance(D.Palette.Chassis) + 0.15)
	local strong = 0
	for _, spec in ipairs(specs) do
		if spec.Material == "Neon" and spec.Size.X * spec.Size.Y * spec.Size.Z > 30 then
			strong = strong + 1
		end
	end
	check("emission only on small surfaces (no large neon parts added)", strong == 0, tostring(strong))

	------------------------------------------------------------------ Orbital Garage observation deck (06)
	local hub = TD.Hub
	local garage = D.GarageSpecs(hub, layout, TD.PracticeChute.Pieces[1].Width[1])
	local g = {}
	local psi = math.rad(hub.ChuteHeadingDeg)
	local look = Vector3.new(math.sin(psi), 0, -math.cos(psi))
	local right = Vector3.new(math.cos(psi), 0, math.sin(psi))
	local blocking = 0
	for _, spec in ipairs(garage) do
		g[spec.Name] = spec
		local d = spec.CFrame.Position - hub.Center
		local along, lateral = d:Dot(look), d:Dot(right)
		if along > hub.Radius - 6 and math.abs(lateral) < TD.PracticeChute.Pieces[1].Width[1] / 2 and d.Y < 9 and spec.Name ~= "PracticeArchPost" then
			blocking = blocking + 1
		end
	end
	check("observation deck: violet ring, edge lights, overlook, practice arch, MAPS kiosk, departures", g.VioletRing and g.EdgeLight and g.OverlookGlass and g.PracticeArch and g.KioskSign and g.SelectorPad and g.DeparturesSign)
	check("nothing in the practice entrance (the chute mouth stays clear)", blocking == 0, tostring(blocking))
	local pad = g.SelectorPad.CFrame.Position - hub.Center
	local padFlat = Vector3.new(pad.X, 0, pad.Z).Magnitude
	check("MAPS pad is a short roll from the spawn ring and on the deck", padFlat > hub.SpawnRingRadius + 3 and padFlat < hub.Radius - 4)
	local window = g.OverlookGlass.CFrame.Position - hub.Center
	local mid = layout.Sections[math.floor(#layout.Sections / 2)].Position - hub.Center
	check("the overlook faces the Neon Foundry and not the chute opening", Vector3.new(window.X, 0, window.Z).Unit:Dot(Vector3.new(mid.X, 0, mid.Z).Unit) > 0.3 and Vector3.new(window.X, 0, window.Z).Unit:Dot(look) < 0.9)
	local lightsInGap = 0
	for _, spec in ipairs(garage) do
		if spec.Name == "EdgeLight" then
			local d = spec.CFrame.Position - hub.Center
			if Vector3.new(d.X, 0, d.Z).Unit:Dot(look) >= 0.93 then
				lightsInGap = lightsInGap + 1
			end
		end
	end
	check("no edge light across the chute opening", lightsInGap == 0)
	local navigation = 0
	for _, spec in ipairs(garage) do
		if spec.Gui then
			navigation = navigation + 1
		end
	end
	check("navigation panels are static text signs (readable on Low)", navigation >= 4)

	------------------------------------------------------------------ presentation only
	if m.ReadFile then
		local src = m.ReadFile("src/StarterPlayer/StarterPlayerScripts/Controllers/EnvironmentController.lua")
		check("backdrop parts never collide, raycast, touch or cast shadows", src:find("part.CanCollide = false", 1, true) and src:find("part.CanQuery = false", 1, true) and src:find("part.CanTouch = false", 1, true) and src:find("part.CastShadow = false", 1, true))
		check("a map / hub / detail change destroys the old folder first", src:find("folder:Destroy()", 1, true) and src:find("self.hubFolder:Destroy()", 1, true))
		check("road restyle changes colour only (physics stay the server's)", src:find("part.Color = profile.Road", 1, true) ~= nil and not src:find("profile.Road.Material", 1, true) and not src:find("CustomPhysicalProperties", 1, true))
		local round = m.ReadFile("src/ServerScriptService/Services/RoundService.lua")
		local hubBranch = round:find("if info.zone == ZONES.Hub then", 1, true)
		local checkpoint = round:find("self.checkpoints:Process(player, info)", 1, true)
		check("race triggers are blocked inside hubs (hub progress returns before checkpoints)", hubBranch and checkpoint and hubBranch < checkpoint)
		local boot = m.ReadFile("src/StarterPlayer/StarterPlayerScripts/ClientBootstrap.client.lua")
		check("environments apply to every player (the zone lighting is no longer gated)", boot:find("every player gets the zone's lighting", 1, true) ~= nil and not boot:find("if myFeatures().NewHubs then", 1, true))
	end
	return results
end

return Spec
