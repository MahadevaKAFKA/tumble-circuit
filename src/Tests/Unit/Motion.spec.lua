--[[
	Motion.spec (owner brief 2026-11-26: speed feel, launch-ramp intro, UI motion). The visuals
	only exist in a Roblox runtime; these checks cover the pure parts: the speed-trail curve and
	its guards (hysteresis, teleport / dropout reset, spinning in place, braking), the FOV kick,
	the launch timeline (fits Preparing, every style lands on the same slot at the same time,
	ends in the real marble's orientation), trail budgets, and UI entrances.
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
	local function near(a, b, eps)
		return math.abs(a - b) <= (eps or 1e-6)
	end

	local MF, RC, PC = m.MotionFeel, m.RaceConfig, m.PhysicsConfig
	if MF then
		check("speed reference = the existing speed cap (TerminalSpeed)", PC == nil or MF.ReferenceSpeed == PC.Movement.TerminalSpeed)
		check("trail knots: 0 below 15%, 4 at 35%, 12 at 65%, 24 at cap", MF.TrailLength(0.1) == 0 and near(MF.TrailLength(0.35), 4) and near(MF.TrailLength(0.65), 12) and near(MF.TrailLength(1), 24) and MF.TrailLength(1.5) <= MF.Trail.MaxLength)
		check("trail curve interpolates (50% between 4 and 12)", near(MF.TrailLength(0.5), 8))
		-- drive a trail along a straight line at a fixed speed
		local function run(speed, seconds, braking, startAt, st)
			st = st or MF.NewTrailState()
			local p = startAt or Vector3.new(0, 0, 0)
			local length, opacity, cleared
			MF.StepTrail(st, 1 / 60, p, braking)
			for _ = 1, math.floor(seconds * 60) do
				p = p + Vector3.new(0, 0, -speed / 60)
				length, opacity, cleared = MF.StepTrail(st, 1 / 60, p, braking)
			end
			return length, opacity, st, p, cleared
		end
		local capLen, capOpacity = run(80, 3)
		check("at the cap the trail grows to ~24 studs, fully visible", capLen > 22 and capLen <= 24 and near(capOpacity, 1))
		local slowLen = run(8, 2)
		check("below 15% of cap (8 studs/s): no trail", slowLen == 0)
		local st = MF.NewTrailState()
		local p = Vector3.new(0, 0, 0)
		MF.StepTrail(st, 1 / 60, p, false)
		for _ = 1, 120 do
			MF.StepTrail(st, 1 / 60, p, false) -- a marble spinning in place: position never moves
		end
		check("a marble spinning in place has no trail (measured movement, not spin)", st.length == 0 and not st.on)
		local _, _, s2, last = run(50, 2)
		local len, _, cleared = MF.StepTrail(s2, 1 / 60, last + Vector3.new(0, 0, -200), false)
		check("a teleport (200 studs in a frame) clears the history", cleared and len == 0)
		local _, _, s3, last3 = run(50, 2)
		local len3, _, cleared3 = MF.StepTrail(s3, 0.5, last3 + Vector3.new(0, 0, -25), false)
		check("a 0.5 s dropout resets instead of drawing a long ribbon", cleared3 and len3 == 0)
		-- hysteresis around the threshold: 16% of cap stays off from rest, stays on when slowing
		local _, _, sOff = run(80 * 0.16, 2)
		local _, _, sOn, lastOn = run(80 * 0.6, 2)
		local _, _, sOn2 = run(80 * 0.15, 0.6, false, lastOn, sOn)
		check("hysteresis: 16% of cap doesn't switch it on, 15% doesn't switch it off", not sOff.on and sOn2.on)
		local brakeLen = run(80, 3, true)
		check("braking shortens the trail (< half of the cap length)", brakeLen < capLen * 0.5)
		check("lifetime draws the length at the current speed, bounded", near(MF.TrailLifetime(24, 80), 0.3) and MF.TrailLifetime(24, 1) <= 0.7 and MF.TrailLifetime(0, 50) > 0)
		check("FOV kick: 0 at cruise, +8 deg at the cap, 0 under Reduced Motion", MF.FovKick(0.4, false) == 0 and near(MF.FovKick(1, false), 8) and MF.FovKick(1, true) == 0)
		check("speed streaks only near top speed", MF.StreakAlpha(0.7) == 0 and MF.StreakAlpha(1) > 0.45)

		-- launch timeline
		local L = MF.Launch
		local prep = RC.Timers.PreparingSeconds
		check("launch intro (start delay + 4 staggered rows) ends inside Preparing", L.StartDelay + MF.LaunchEnd(4) + 0.1 <= prep, L.StartDelay + MF.LaunchEnd(4))
		check("timeline order: wide 0-0.6, ramp to 1.1, jump to 1.75, landing to 2.05", L.Wide == 0.6 and L.Lip == 1.1 and L.Land == 1.75 and L.End == 2.05 and L.SideCut > L.Wide and L.SideCut < L.Land)
		local geo = MF.RampGeometry(Vector3.new(0, 50, 0), Vector3.new(0, 0, -1))
		check("ramp sits behind and above the grid, sloping down toward it", geo.top.Z > geo.lip.Z and geo.top.Y > geo.lip.Y and geo.lip.Z > 0 and geo.deckUp.Y > 0.5 and geo.slope.Z < 0)
		local slot = Vector3.new(3, 52, -20)
		local path = MF.LaunchPath(geo, slot, 2, 3)
		local sameEnd, sameStart = true, true
		for id in pairs(L.Styles) do
			local endP = MF.LaunchPose(path, MF.LaunchEnd(4), id)
			local startP = MF.LaunchPose(path, 0, id)
			sameEnd = sameEnd and (endP - slot).Magnitude < 1e-6
			sameStart = sameStart and (startP - path.start).Magnitude < 1e-6
		end
		check("every launch style starts at the top and ends exactly on the real grid slot", sameEnd and sameStart)
		local landAt = path.delay + L.Land
		local landP = MF.LaunchPose(path, landAt - 1e-6, "launch_ramp")
		check("the arc reaches the slot at Land (no snap at the swap)", (landP - slot).Magnitude < 0.05)
		local mid = MF.LaunchPose(path, path.delay + (L.Lip + L.Land) / 2, "launch_spring")
		local midLow = MF.LaunchPose(path, path.delay + (L.Lip + L.Land) / 2, "launch_comet")
		check("styles differ only in arc height (Spring higher than Comet)", mid.Y > midLow.Y)
		check("unknown or missing style falls back to the free default", MF.LaunchStyle(nil) == L.Styles.launch_ramp and MF.LaunchStyle("nope") == L.Styles.launch_ramp)
		local _, roll1 = MF.LaunchPose(path, path.delay + L.Lip, "launch_ramp")
		local _, roll2 = MF.LaunchPose(path, path.delay + L.Land, "launch_ramp")
		check("the stand-in rolls forward as it travels", roll2 > roll1 and roll1 > 0)
	end

	local RI = m.RaceIntroPure
	if RI then
		local total = 7.3
		local scaled = total * RI.RollScale(total)
		check("roll is scaled to whole turns: the stand-in ends in the real marble's orientation", near(scaled % (2 * math.pi), 0, 1e-9) or near(scaled % (2 * math.pi), 2 * math.pi, 1e-9))
		local function frame(z)
			return { Position = Vector3.new(0, 10, z), Up = Vector3.new(0, 1, 0), Right = Vector3.new(1, 0, 0), Forward = Vector3.new(0, 0, -1) }
		end
		local f1, f2 = frame(-26), frame(-8)
		local slots = { { Frame = f1, Offset = -3 }, { Frame = f1, Offset = 3 }, { Frame = f2, Offset = -3 }, { Frame = f2, Offset = 3 } }
		local back, fwd = RI.GridFrame(slots, 2)
		check("grid frame: centre of the back row, grid forward", near(back.Z, -8) and near(back.Y, 12) and fwd.Z == -1)
		local row, lateral = RI.SlotInfo(slots, Vector3.new(3.2, 12, -8.3))
		local row1 = RI.SlotInfo(slots, Vector3.new(-3, 12, -26))
		check("slot lookup: back row = row 2, lateral offset kept; front = row 1", row == 2 and lateral == 3 and row1 == 1)
		check("each map has a themed ramp; unknown maps get the default", RI.ThemeFor("SkyCarnival_B1") == RI.Themes.SkyCarnival and RI.ThemeFor("nope") == RI.Themes.NeonFoundry)
	end

	local SF = m.SpeedFeelPure
	if SF then
		local entries = { { id = "me", distance = 0, isMine = true } }
		for i = 1, 20 do
			entries[#entries + 1] = { id = "r" .. i, distance = i * 15, isMine = false }
		end
		local function count(set)
			local n = 0
			for _ in pairs(set) do
				n = n + 1
			end
			return n
		end
		local high = SF.Select(entries, SF.Budgets.High, "All")
		local low = SF.Select(entries, SF.Budgets.Low, "All")
		check("trail budget High: you + the 12 nearest rivals within 220 studs", count(high) == 13 and high.me and high.r1 and not high.r14)
		check("trail budget Low: your own trail only", count(low) == 1 and low.me)
		check("trail visibility: Mine shows only yours, Off shows none", count(SF.Select(entries, SF.Budgets.High, "Mine")) == 1 and count(SF.Select(entries, SF.Budgets.High, "Off")) == 0)
		local def = SF.StyleFor(nil)
		local ember = SF.StyleFor("trail_ember")
		check("free default trail without equipping; an equipped trail restyles it (colours + profile)", def.id == "default" and ember.profile == "Twin" and ember.colors[1] ~= nil)
	end

	local Cam = m.CameraPure
	if Cam then
		local focus = Vector3.new(10, 50, 10)
		local start = Cam.IntroStart(focus, Vector3.new(0, 0, -1))
		check("camera intro pose is high above the grid, looking down the course", start.Position.Y > focus.Y + 30 and start.LookVector.Y < 0)
		check("camera easing 0 -> 1 without overshoot", Cam.IntroAlpha(0, 2) == 0 and Cam.IntroAlpha(2, 2) == 1 and Cam.IntroAlpha(1, 2) > 0 and Cam.IntroAlpha(1, 2) < 1)
		check("scripted camera API exists (launch intro shots)", type(Cam.SetScripted) == "function")
	end

	local UI = m.UIKitPure
	if UI then
		local function fake(pos)
			return {
				Visible = false,
				Position = pos,
				FindFirstChild = function()
					return nil
				end,
				FindFirstChildOfClass = function()
					return nil
				end,
			}
		end
		local base = UDim2.fromOffset(40, 60)
		local f = fake(base)
		UI.SetReducedMotion(false)
		UI.Show(f, true, "FromLeft")
		UI.Show(f, false)
		UI.Show(f, true, "FromBelow")
		check("UI entrance: open / close / open leaves the panel exactly where it rests", f.Visible == true and f.Position == base)
		UI.Show(f, false)
		check("UI hide is instant and settled", f.Visible == false and f.Position == base)
		UI.SetReducedMotion(true)
		local g = fake(base)
		UI.Enter(g, "FromRight")
		check("Reduced motion: entrances do nothing", g.Position == base)
		UI.SetReducedMotion(false)
		local pop = { Scale = 1 }
		local h = fake(base)
		h.FindFirstChild = function(_, name)
			return name == "Pop" and pop or nil
		end
		UI.Enter(h, "Pop")
		UI.Punch(h, 1.4)
		check("pop / punch always settle at scale 1", pop.Scale == 1)
	end
	return results
end

return Spec
