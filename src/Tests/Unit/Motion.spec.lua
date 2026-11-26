--[[
	Motion.spec (owner request 2026-11-26: animations for everything, the race entry). The motion
	itself only exists in a Roblox runtime; these checks cover the pure parts: the grid drop-in
	timing fits inside Preparing, front row first, the camera swoop's start pose and easing, and
	that a UI entrance can never leave an element away from its resting place.
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

	local RI, RC = m.RaceIntroPure, m.RaceConfig
	if RI and RC then
		local prep = RC.Timers.PreparingSeconds
		local fits, mono, last = true, true, -1
		for rank = 1, 16 do
			local d = RI.DelayFor(rank)
			fits = fits and d + RI.CollectSeconds + RI.DropSeconds <= prep
			mono = mono and d >= last
			last = d
		end
		check("grid drop-in: the last marble (16th) lands inside Preparing", fits)
		check("grid drop-in: front row first, delays never go backwards", RI.DelayFor(1) == 0 and mono)
		local forward = Vector3.new(0, 0, -1)
		local order = RI.Order({ Vector3.new(0, 0, 10), Vector3.new(0, 0, -20), Vector3.new(4, 0, -20), Vector3.new(0, 0, 0) }, forward)
		check("grid order: furthest along the route drops first, ties keep slot order", order[1] == 2 and order[2] == 3 and order[3] == 4 and order[4] == 1)
		check("intro camera swoop ends inside the countdown", RI.CameraSeconds <= prep + RC.Timers.CountdownSeconds - 0.5)
	end

	local Cam = m.CameraPure
	if Cam then
		local focus = Vector3.new(10, 50, 10)
		local start = Cam.IntroStart(focus, Vector3.new(0, 0, -1))
		check("intro starts high above the grid and looks down toward the gate", start.Position.Y > focus.Y + 30 and start.LookVector.Y < 0 and start.LookVector.Z < 0)
		local mono, prev = true, -1
		for i = 0, 20 do
			local a = Cam.IntroAlpha(i * 0.11, 2.2)
			mono = mono and a >= prev - 1e-12 and a >= 0 and a <= 1
			prev = a
		end
		check("intro easing: 0 -> 1, smooth and never overshoots", mono and Cam.IntroAlpha(0, 2.2) == 0 and Cam.IntroAlpha(2.2, 2.2) == 1 and Cam.IntroAlpha(5, 2.2) == 1)
		local straightUp = Cam.IntroStart(focus, Vector3.new(0, 1, 0))
		check("intro pose is safe for a vertical heading (no NaN)", straightUp.Position.Y == straightUp.Position.Y)
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
