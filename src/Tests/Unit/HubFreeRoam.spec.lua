--[[
	HubFreeRoam.spec (owner playtest 2026-11-25) — offline only. On the round hub platform there
	is no track, so steering there follows the camera and has no auto-align; the camera keeps the
	player's heading and free look turns it for good. Drives the real CameraController and the real
	shared MarbleMotorController against fakes (tools/offline/run_tests.lua).
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
	if not (m.CameraHarness and m.MotorHarness) then
		check("harnesses available (offline only)", false)
		return results
	end
	local UP = Vector3.new(0, 1, 0)
	local RT = m.RouteTracker
	local layout = m.TrackDefinitions.Generate(m.TrackDefinitions.Race, m.PhysicsConfig.Ball.Radius)
	local route = layout.Route
	local function flat(v)
		local f = Vector3.new(v.X, 0, v.Z)
		return f.Magnitude > 1e-6 and f.Unit or f
	end

	-------------------------------------------------------------------- camera
	local camera, cam = m.CameraHarness.new()
	local ball = { Position = RT.PointAtS(route, 60) + UP * 2, Parent = true }
	camera:Bind(ball, route, {})
	local function step(seconds, s)
		local t = 0
		while t < seconds - 1e-9 do
			camera:Step(1 / 60, s)
			t = t + 1 / 60
		end
	end
	step(0.5, 60)
	camera:SetFreeRoam(true)
	local before = flat(cam.CFrame.LookVector)
	-- jump the progress far into the S-turn: a track camera would swing, a hub camera must not
	step(2, 560)
	local after = flat(cam.CFrame.LookVector)
	check("free roam: heading stays where the player left it (no track following)", before:Dot(after) > 0.999, string.format("%.4f", before:Dot(after)))
	camera:AddLook(90, 0)
	step(4, 560)
	local turned = flat(cam.CFrame.LookVector)
	check("free roam: dragging turns the view for good (no ease-back)", math.abs(turned:Dot(before)) < 0.05 and turned:Dot(before:Cross(UP)) > 0.95, string.format("%.3f", turned:Dot(before:Cross(UP))))
	local fwd = camera:GetFlatForward()
	check("free roam: steering forward = where the camera looks", flat(fwd):Dot(turned) > 0.999)
	camera:SetFreeRoam(false)
	step(4, 560)
	local trackHeading = RT.SmoothHorizontalTangentAtS(route, 560 + m.GameConfig.Camera.HeadingLookAheadStuds, m.GameConfig.Camera.HeadingSmoothingStuds)
	check("leaving the platform: camera turns back to the track", flat(cam.CFrame.LookVector):Dot(trackHeading) > 0.98, string.format("%.3f", flat(cam.CFrame.LookVector):Dot(trackHeading)))

	-------------------------------------------------------------------- motor
	local Modes
	local function force(ctx, velocity)
		local motor, b, f, Motor = m.MotorHarness.new()
		Modes = Motor.Modes
		b.AssemblyLinearVelocity = velocity or Vector3.new(0, 0, 0)
		ctx.mode = ctx.mode or Modes.Play
		ctx.forwardH = ctx.forwardH or Vector3.new(1, 0, 0)
		ctx.brake = ctx.brake or false
		ctx.brakePressed = false
		motor:Step(1 / 60, ctx)
		return f.Force
	end
	m.MotorHarness.new() -- load once for Modes
	local up = force({ freeRoam = true, steer = Vector2.new(0, 1) })
	check("free roam: stick up pushes where the camera faces", up.X > 5 and math.abs(up.Z) < 0.5, string.format("%.1f, %.1f", up.X, up.Z))
	local right = force({ freeRoam = true, steer = Vector2.new(1, 0) })
	check("free roam: stick right pushes to the camera's right", right.Z > 5 and math.abs(right.X) < 0.5, string.format("%.1f, %.1f", right.X, right.Z))
	local diag = force({ freeRoam = true, steer = Vector2.new(1, 1) })
	check("free roam: diagonal stick is capped (no faster diagonals)", diag.Magnitude <= m.PhysicsConfig.Movement.FreeRoamAccelMax * m.PhysicsConfig.Movement.RollingInertiaCompensation + 1e-6)
	local drift = Vector3.new(0, 0, 12)
	local roamDrift = force({ freeRoam = true, steer = Vector2.new(0, 0) }, drift)
	local trackDrift = force({ freeRoam = false, steer = Vector2.new(0, 0) }, drift)
	check("free roam: no auto-align pulling sideways motion back", math.abs(roamDrift.Z) < math.abs(trackDrift.Z) - 5, string.format("roam %.1f vs track %.1f", roamDrift.Z, trackDrift.Z))
	local track = force({ freeRoam = false, steer = Vector2.new(0, 1) })
	check("track steering unchanged off the platform (stick up = along the track)", track.X > 5 and math.abs(track.Z) < 0.5)
	return results
end

return Spec
