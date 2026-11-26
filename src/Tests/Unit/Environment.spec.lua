--[[
	Environment.spec (2026-11-26) — per-map backdrops: every implemented map has a profile, each
	detail level keeps the signature landmark, backdrops stay clear of the route, roads are a
	visible midtone apart from the cobalt marble, guide lights are narrow, unbuilt maps get none.
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
	local E, R, TD, VP = m.EnvironmentProfiles, m.MapRegistry, m.TrackDefinitions, m.VisualProfiles
	if not (E and R and TD and VP) then
		check("environment modules load", false)
		return results
	end
	local radius = m.PhysicsConfig.Ball.Radius
	local cobalt = Color3.fromRGB(40, 90, 220)
	for _, map in ipairs(R.Maps) do
		local profile = E.Maps[map.Id]
		check(map.Id .. ": has an environment profile and a lighting profile", profile ~= nil and VP.Profiles[profile.Lighting] ~= nil and select(2, VP.Get(map.Profile)) == false)
		if profile then
			local layout = TD.Generate(TD.WorldsById[map.Track], radius)
			local counts, sane = {}, true
			for _, detail in ipairs({ "Low", "Standard", "High" }) do
				local specs = E.CourseSpecs(map.Id, layout, detail)
				counts[detail] = #specs
				local signature = false
				for _, spec in ipairs(specs) do
					local sz = spec.Size
					if not (sz.X > 0 and sz.Y > 0 and sz.Z > 0 and sz.X <= 2048 and sz.Y <= 2048 and sz.Z <= 2048) then
						sane = false
					end
					signature = signature or spec.Layer == "Signature"
					if detail == "Low" and spec.Layer ~= "Signature" and spec.Layer ~= "Track" then
						sane = false
					end
				end
				check(map.Id .. " " .. detail .. ": the signature landmark is there", signature)
			end
			results.info[#results.info + 1] = string.format("%s backdrop parts: Low %d / Standard %d / High %d", map.Id, counts.Low, counts.Standard, counts.High)
			check(map.Id .. ": sizes valid; Low keeps only the signature + hazard tells; more detail = more parts", sane and counts.Low <= counts.Standard and counts.Standard <= counts.High)
			-- clearance: backdrop >= 150 studs from the route; near framing outside the lane / high
			local tooClose = 0
			for _, spec in ipairs(E.CourseSpecs(map.Id, layout, "High")) do
				local p = spec.CFrame.Position
				for _, sec in ipairs(layout.Sections) do
					local d = p - sec.Position
					local flat = math.sqrt(d.X * d.X + d.Z * d.Z)
					local up = d:Dot(sec.Up)
					local lateral = math.abs(d:Dot(sec.Right))
					local along = math.abs(d:Dot(sec.Forward))
					if spec.Layer == "Track" or spec.Layer == "TrackDetail" or spec.Layer == "Under" then
						-- on / under the course by design (Dressing.spec checks these)
					elseif spec.Layer == "Near" then
						if along < 3 and lateral < sec.Width / 2 + 2 and up < 18 then
							tooClose = tooClose + 1
						end
					elseif flat < 150 and math.abs(d.Y) < 60 then
						tooClose = tooClose + 1
					end
				end
			end
			check(map.Id .. ": backdrop stays clear of the race line (start, lanes, finish stay legible)", tooClose == 0, tostring(tooClose))
			-- owner playtest 2026-11-26: nothing from a course backdrop inside or over any hub
			local inHub = 0
			for _, spec in ipairs(E.CourseSpecs(map.Id, layout, "High")) do
				if spec.Layer ~= "Track" and spec.Layer ~= "TrackDetail" and spec.Layer ~= "Under" then
					local p = spec.CFrame.Position
					local half = math.max(spec.Size.X, spec.Size.Y, spec.Size.Z) / 2
					for _, hub in ipairs(R.Hubs) do
						local c = hub.Geometry.Center
						local d = math.sqrt((p.X - c.X) ^ 2 + (p.Z - c.Z) ^ 2) - half
						if d < hub.Geometry.Radius + 200 and math.abs(p.Y - c.Y) < 300 then
							inHub = inHub + 1
						end
					end
				end
			end
			check(map.Id .. ": no backdrop part in or over any hub deck or practice lane", inHub == 0, tostring(inHub))
			local road = profile.Road
			local spread = math.max(road.R, road.G, road.B) - math.min(road.R, road.G, road.B)
			check(map.Id .. ": road is a visible midtone (not black, not white)", luminance(road) > 0.3 and luminance(road) < 0.8)
			check(map.Id .. ": road differs from the cobalt marble in brightness or colour", math.abs(luminance(road) - luminance(cobalt)) > 0.05 or spread < 0.25)
			check(map.Id .. ": guide lights are narrow (emission on small surfaces)", profile.Edge.Width <= 0.3 and profile.Edge.Height <= 0.2)
		end
	end
	-- hubs
	for _, entry in ipairs(R.Hubs) do
		local chute = TD.Generate(entry.Chute, radius)
		local low = E.HubSpecs(entry.Id, entry.Geometry, chute, "Low")
		local high = E.HubSpecs(entry.Id, entry.Geometry, chute, "High")
		check(entry.Id .. ": hub staging has its landmark on Low and more on High", #low > 0 and #high >= #low)
		local onDeck = 0
		for _, spec in ipairs(high) do
			local d = spec.CFrame.Position - entry.Geometry.Center
			if math.sqrt(d.X * d.X + d.Z * d.Z) < entry.Geometry.Radius - 2 and d.Y > -1 and d.Y < 6 and spec.Size.Y > 4 and spec.Name ~= "ShelterPost" then
				onDeck = onDeck + 1
			end
		end
		check(entry.Id .. ": staging leaves the deck floor open (nothing tall on the roll area)", onDeck == 0, tostring(onDeck))
		check(entry.Id .. ": practice lane gets its own road colour", E.Hubs[entry.Id] and E.Hubs[entry.Id].ChuteRoad ~= nil)
	end
	check("a map without a profile gets no backdrop (unbuilt maps stay off)", #E.CourseSpecs("Tideworks_X", nil, "High") == 0)
	check("same layout -> same backdrop (deterministic on every client)", (function()
		local layout = TD.Generate(TD.SkyCarnival, radius)
		local a, b = E.CourseSpecs("SkyCarnival_B1", layout, "Standard"), E.CourseSpecs("SkyCarnival_B1", layout, "Standard")
		return #a == #b and a[5].CFrame.Position == b[5].CFrame.Position
	end)())
	local UI = m.UIKitPure
	if UI then
		local same = true
		for id, profile in pairs(E.Maps) do
			same = same and UI.MapAccents[id] ~= nil and math.abs(UI.MapAccents[id].R - profile.Accent.R) < 0.01
		end
		check("UI 'Follow map' accents match the environment accents", same)
	end
	return results
end

return Spec
