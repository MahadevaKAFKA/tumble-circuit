--[[
	Worlds.spec (B1) — Sky Carnival and Volcano Vault against the same module contract and
	validator as the Neon Foundry, plus checks that the three worlds and the hub never overlap.
	Graph checks cannot prove a human can finish: that needs a real run (TEST_PLAN §11).
]]

local Spec = {}

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
	check("three worlds: Foundry, Sky Carnival, Volcano Vault (a circuit replaces a single run once validated)", #TD.Worlds == 3 and TD.Worlds[1].Id == "NeonFoundry_A4" and TD.Worlds[2].Id == "SkyCarnival_B1" and TD.Worlds[3].Id == "VolcanoVault_B1")
	check("the single-run worlds are kept as the one-flag fallback", #TD.LegacyWorlds == 3 and TD.LegacyWorlds[1] == TD.NeonFoundry and TD.LegacyWorlds[2] == TD.SkyCarnival and TD.LegacyWorlds[3] == TD.VolcanoVault)
	local ids, layouts = {}, {}
	for _, def in ipairs(TD.LegacyWorlds) do
		check(def.DisplayName .. ": stable unique id", def.Id and not ids[def.Id], def.Id)
		ids[def.Id] = true
		local layout = TD.Generate(def, radius)
		layouts[#layouts + 1] = layout
		local errors = TV.Validate(def, layout)
		check(def.DisplayName .. ": TrackValidator 0 errors (all 3 hazard seeds)", #errors == 0, table.concat(errors, " | "))
		check(def.DisplayName .. ": 12-16 modules", #layout.Modules >= 12 and #layout.Modules <= 16, #layout.Modules)
		check(def.DisplayName .. ": 8 ordered checkpoints", #layout.Checkpoints == 8)
		local ordered = true
		for i = 2, #layout.Checkpoints do
			if layout.Checkpoints[i].S <= layout.Checkpoints[i - 1].S then
				ordered = false
			end
		end
		check(def.DisplayName .. ": checkpoints ascend along the route", ordered)
		check(def.DisplayName .. ": 16 grid slots, trick ramp, 4 chaos gates", #layout.GridSlots == 16 and #(layout.TrickZones or {}) >= 1 and #(layout.ChaosGates or {}) == 4)
		local est = TD.EstimateRunSeconds(layout, m.PhysicsConfig.Movement)
		results.info[#results.info + 1] = string.format("%s: %.0f studs, %d modules, drop %.0f, 1-D model clean run %.0f s (a model, not a measurement)", def.DisplayName, layout.Route.total, #layout.Modules, layout.MaxY - layout.MinY, est)
		check(def.DisplayName .. ": modelled clean run 45-150 s (real times need a playtest)", est >= 45 and est <= 150, string.format("%.0f s", est))
		local styled = true
		for _, hz in ipairs(def.Hazards) do
			if def ~= TD.NeonFoundry and not hz.Style then
				styled = false
			end
		end
		check(def.DisplayName .. ": every new-world hazard names its look (Style)", styled)
	end

	-- every world builds: finite part sizes, under the 2048-stud part limit, themed floors
	local B = m.Builder or m.TrainingTrackBuilder
	if B then
		for _, def in ipairs(TD.Worlds) do
			local ok, specs = pcall(B.ComputeSpecs, TD.Generate(def, radius))
			local sane, parts, collide = ok, 0, 0
			if ok then
				for _, spec in ipairs(specs) do
					parts = parts + 1
					local sz = spec.Size
					if not (sz and sz.X > 0 and sz.Y > 0 and sz.Z > 0 and sz.X <= 2048 and sz.Y <= 2048 and sz.Z <= 2048) then
						sane = false
					end
					if spec.Collide ~= false then
						collide = collide + 1
					end
				end
			end
			check(def.DisplayName .. ": builds (all part sizes valid)", sane, ok and "" or tostring(specs))
			results.info[#results.info + 1] = string.format("%s: %d parts, %d collidable", def.DisplayName, parts, collide)
		end
		local themed = TD.VolcanoVault.Theme
		local pal = B.ThemePalette(themed)
		check("theme overrides floor colour, keeps hazard warning colours", pal.NavyFloor == themed.NavyFloor and pal.Coral == m.GameConfig.Palette.Coral and pal.Yellow == m.GameConfig.Palette.Yellow)
	end

	-- worlds and hub never overlap (60-stud clearance between any two sections)
	local hub = TD.Hub
	local minWorlds, minHub = math.huge, math.huge
	for a = 1, #layouts do
		for _, sa in ipairs(layouts[a].Sections) do
			local h = sa.Position - hub.Center
			minHub = math.min(minHub, h.Magnitude)
			for b = a + 1, #layouts do
				for _, sb in ipairs(layouts[b].Sections) do
					minWorlds = math.min(minWorlds, (sa.Position - sb.Position).Magnitude)
				end
			end
		end
	end
	check("worlds stay >= 200 studs apart", minWorlds >= 200, string.format("%.0f", minWorlds))
	check("no world comes within 150 studs of the hub", minHub >= 150, string.format("%.0f", minHub))
	return results
end

return Spec
