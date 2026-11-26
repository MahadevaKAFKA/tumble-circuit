--[[
	HazardReset.spec (A4) — deterministic hazards: same (seed, t) gives identical state on every
	call (= every machine, every round); the three seed classes differ; every kick is bounded;
	zone pushes only act inside their zone; the client's sweeper/hammer visuals sit exactly where
	the contact model says they are. Pure; offline and Studio.
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
	local HS, TD = m.HazardSim, m.TrackDefinitions
	local layout = TD.Generate(TD.NeonFoundry, m.PhysicsConfig.Ball.Radius)
	local function resolve(seed)
		local out = {}
		for _, hz in ipairs(layout.Hazards) do
			out[hz.Id] = { Kind = hz.Kind, Id = hz.Id, Definition = hz.Definition, Frame = hz.Frame, FromFrame = hz.FromFrame, Length = hz.Length, Offset = hz.Offset, Params = HS.Params(hz.Definition, seed) }
		end
		return out
	end

	-- 1) reset determinism: two independent resolutions (two "rounds") at the same t agree
	local a, b = resolve(1), resolve(1)
	local same = true
	for _, t in ipairs({ 0, 0.37, 3.3, 17.25, 101.9 }) do
		if HS.SweeperAngle(a.Sweeper1.Params, t) ~= HS.SweeperAngle(b.Sweeper1.Params, t) then
			same = false
		end
		if HS.HammerLateral(a.Hammer1.Params, t) ~= HS.HammerLateral(b.Hammer1.Params, t) then
			same = false
		end
		for row = 1, 8 do
			for col = 1, 4 do
				if HS.TileState(a.Tiles1.Params, row, col, t) ~= HS.TileState(b.Tiles1.Params, row, col, t) then
					same = false
				end
			end
		end
		if HS.FanState(a.Fan1.Params, t) ~= HS.FanState(b.Fan1.Params, t) then
			same = false
		end
	end
	check("same seed + same t -> identical sweeper/hammer/tiles/fan state", same)
	check("t = 0 at GO: a new round starts every hazard from the same phase", HS.SweeperAngle(resolve(0).Sweeper1.Params, 0) == HS.SweeperAngle(resolve(0).Sweeper1.Params, 0) and HS.TileState(resolve(2).Tiles1.Params, 1, 1, 0) == HS.TileState(resolve(2).Tiles1.Params, 1, 1, 0))

	-- 2) the seed classes are real variations
	local differ = 0
	local s0, s1, s2 = resolve(0), resolve(1), resolve(2)
	for _, t in ipairs({ 1, 2.5, 4 }) do
		if HS.SweeperAngle(s0.Sweeper1.Params, t) ~= HS.SweeperAngle(s1.Sweeper1.Params, t) then
			differ = differ + 1
		end
		if HS.HammerLateral(s0.Hammer1.Params, t) ~= HS.HammerLateral(s2.Hammer1.Params, t) then
			differ = differ + 1
		end
	end
	check("seed classes 0/1/2 produce different hazard timing", differ >= 4, differ)
	check("Params never mutates the definition (no cross-round leakage)", TD.NeonFoundry.Hazards[5].Speed == 1.1 and s1.Sweeper1.Params.Speed ~= s0.Sweeper1.Params.Speed)
	check("seed classes wrap: 3 hazard variations exist", HS.SeedClasses == 3)

	-- 3) bounded kicks: sample positions around every contact hazard at many times
	local maxKick, contacts = 0, 0
	for seed = 0, 2 do
		local res = resolve(seed)
		for _, hz in pairs(res) do
			if hz.Kind == "Sweeper" or hz.Kind == "Hammer" or hz.Kind == "Trampoline" then
				for t = 0, 6, 0.25 do
					for x = -12, 12, 2 do
						for z = -12, 12, 3 do
							local p = hz.Frame.Position + hz.Frame.Right * x + hz.Frame.Forward * z + hz.Frame.Up * 2
							local kick = HS.Contact(hz, t, p, 2)
							if kick then
								contacts = contacts + 1
								maxKick = math.max(maxKick, kick.Magnitude)
							end
						end
					end
				end
			end
		end
	end
	check("hazard contacts happen and every kick is <= KickCap + 15 studs/s", contacts > 0 and maxKick <= HS.KickCap + 15 + 1e-6, string.format("%d contacts, max %.1f", contacts, maxKick))

	-- 4) zone pushes only inside their zone
	local fan = s0.Fan1
	local inside = fan.Frame.Position + fan.Frame.Up * 2
	local outside = fan.FromFrame.Position - fan.FromFrame.Forward * 20 + fan.FromFrame.Up * 2
	local onT
	for t = 0, 5, 0.1 do
		if HS.FanState(fan.Params, t) == "On" then
			onT = t
			break
		end
	end
	check("fan pushes inside its zone while On", onT ~= nil and HS.EnvironmentAccel(fan, onT, inside) ~= nil)
	check("fan never pushes outside its zone", onT ~= nil and HS.EnvironmentAccel(fan, onT, outside) == nil)
	local offT
	for t = 0, 5, 0.1 do
		if HS.FanState(fan.Params, t) == "Off" then
			offT = t
			break
		end
	end
	check("fan is calm while Off (players get a window)", offT ~= nil and HS.EnvironmentAccel(fan, offT, inside) == nil)
	local conveyor = s0.Conveyor1
	local push = HS.EnvironmentAccel(conveyor, 1, conveyor.Frame.Position + conveyor.Frame.Up * 2)
	check("conveyor push is sideways (perpendicular to travel) and bounded", push ~= nil and math.abs(push:Dot(conveyor.Frame.Forward)) < 1e-6 and push.Magnitude <= 30)

	-- 5) client visuals agree with the contact model
	local HC = m.HazardControllerPure
	if HC then
		local sw = s1.Sweeper1
		local t = 2.2
		local armCF = HC.SweeperArmCFrame(sw.Frame, sw.Params, HS.SweeperAngle(sw.Params, t))
		check("sweeper arm visual centre is inside the contact model", HS.Contact(sw, t, armCF.Position, 2) ~= nil)
		local pivot = sw.Frame.Position + sw.Frame.Up * sw.Params.ArmHeight
		local opposite = pivot * 2 - armCF.Position -- mirror of the arm centre across the post
		check("the opposite side of the post is clear while the arm points away", HS.Contact(sw, t, opposite, 2) == nil)
		local hm = s2.Hammer1
		local lateral = HS.HammerLateral(hm.Params, 1.1)
		local headCF = HC.HammerHeadCFrame(hm.Frame, hm.Params, lateral)
		check("hammer head visual is where the contact model hits", HS.Contact(hm, 1.1, headCF.Position, 2) ~= nil)
	end
	return results
end

return Spec
