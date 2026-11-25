--[[
	FreeLook.spec (A4, owner request 2026-11-25) — offline only: drives the real CameraController
	against a fake camera/workspace (tools/offline/run_tests.lua builds m.CameraHarness) along the
	Neon Foundry route and checks the free-look behaviour:
	  * no look input -> the camera sits behind the marble, as before
	  * AddLook(+90) turns the view to the right of the track direction; 270 wraps to -90 (left)
	  * while a finger / mouse button is held the view stays; after release it waits
	    ReturnDelaySeconds, then eases back behind the marble
	  * total pitch stays inside FreeLook.MinPitchDeg..MaxPitchDeg however far you drag
	  * a new marble (respawn) resets the look
	  * the marble motor never reads the camera, so looking cannot change steering
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

	local H = m.CameraHarness
	if not H then
		check("camera harness available (offline only)", false)
		return results
	end
	local look = m.GameConfig.Camera.FreeLook
	local RT = m.RouteTracker
	local UP = Vector3.new(0, 1, 0)
	local layout = m.TrackDefinitions.Generate(m.TrackDefinitions.Race, m.PhysicsConfig.Ball.Radius)
	local route = layout.Route
	local s = 60 -- a straight stretch after the grid
	local ball = { Position = RT.PointAtS(route, s) + UP * 2, Parent = true }

	local controller, camera = H.new()
	controller:Bind(ball, route, {})
	local function step(seconds)
		local dt = 1 / 60
		local t = 0
		while t < seconds - 1e-9 do
			controller:Step(dt, s)
			t = t + dt
		end
	end
	local function flat(v)
		local f = Vector3.new(v.X, 0, v.Z)
		return f.Magnitude > 1e-6 and f.Unit or f
	end
	local function heading()
		return RT.SmoothHorizontalTangentAtS(route, s + m.GameConfig.Camera.HeadingLookAheadStuds, m.GameConfig.Camera.HeadingSmoothingStuds)
	end
	local function behindDot()
		return flat(camera.CFrame.Position - ball.Position):Dot(heading())
	end
	local function rightDot()
		return flat(camera.CFrame.LookVector):Dot(heading():Cross(UP))
	end
	local function pitchDeg()
		local rel = camera.CFrame.Position - camera.Focus.Position
		return math.deg(math.asin(math.max(-1, math.min(1, rel.Y / rel.Magnitude))))
	end

	step(1)
	check("no look input: camera behind the marble", behindDot() < -0.95, string.format("%.3f", behindDot()))

	controller:SetLookHeld(true)
	controller:AddLook(90, 0)
	step(0.1)
	check("look right 90: view faces right of the track", rightDot() > 0.95, string.format("%.3f", rightDot()))
	step(3)
	check("held: view stays turned (no return while looking)", rightDot() > 0.95, string.format("%.3f", rightDot()))

	controller:SetLookHeld(false)
	step(look.ReturnDelaySeconds - 0.2)
	check("released: still turned before ReturnDelaySeconds", rightDot() > 0.9, string.format("%.3f", rightDot()))
	step(3)
	check("released: eased back behind the marble", behindDot() < -0.95 and not controller:IsLooking(), string.format("%.3f", behindDot()))

	controller:AddLook(270, 0)
	step(0.05)
	check("270 wraps to -90: view faces left of the track", rightDot() < -0.95, string.format("%.3f", rightDot()))
	controller:ResetLook()

	controller:SetLookHeld(true)
	controller:AddLook(0, 500)
	step(0.5)
	local high = pitchDeg()
	controller:AddLook(0, -1000)
	step(0.5)
	local low = pitchDeg()
	controller:SetLookHeld(false)
	check("pitch never above FreeLook.MaxPitchDeg", high <= look.MaxPitchDeg + 0.5, string.format("%.1f", high))
	check("pitch never below FreeLook.MinPitchDeg", low >= look.MinPitchDeg - 0.5, string.format("%.1f", low))
	check("pitch range actually reachable (looked well up and down)", high > 60 and low < 0, string.format("%.1f / %.1f", high, low))

	controller:AddLook(120, 20)
	controller:Bind(ball, route, {})
	check("new marble (respawn) resets the look", not controller:IsLooking())

	check("marble motor never reads the camera (looking cannot steer)", m.MotorSource ~= nil and not string.find(m.MotorSource, "CurrentCamera", 1, true))
	table.insert(results.info, string.format("free look pitch range seen: %.1f .. %.1f deg", low, high))
	return results
end

return Spec
