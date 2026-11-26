--[[
	MotionFeel (owner brief 2026-11-26, "make the racing feel fast" + "launch ramp") — pure maths
	for presentation only. Nothing here changes physics, input, the speed cap, checkpoints or
	timing; the client controllers read it to draw trails, FOV, streaks and the race intro.

	Speed reference = PhysicsConfig.Movement.TerminalSpeed (80 studs/s, the existing cap).

	Speed trail (free for everyone, restyled by an equipped trail):
	  visible length knots  <15% cap: 0 · 35%: 4 studs · 65%: 12 · cap: 24 (linear between,
	  clamped to MaxLength). On above 17% of cap, off below 13% (hysteresis). Length eases up
	  and down (faster down, fastest while braking). Speed is MEASURED from the marble's real
	  movement (position delta / dt, smoothed), so a marble spinning in place has no trail.
	  A jump larger than cap * 1.6 * dt + 14 studs (teleport, respawn, grid snap) or a gap of
	  more than 0.3 s clears the history.
	Camera: up to +8 degrees FOV from 55% to 95% of cap (smoothstep), none under Reduced Motion.
	Streaks: faint screen-edge streaks from 80% of cap, full (50% opacity) at 98%.

	Launch ramp intro (seconds after the intro starts; RaceConfig.Timers.PreparingSeconds holds
	it with margin):
	  0.00-0.60 wide shot of the field on top of the ramp
	  0.60-1.10 burst + accelerate down the ramp
	  1.10-1.75 jump: arc from the lip to the marble's real grid slot (low side camera from 0.95)
	  1.75-2.05 landing flourish, camera hands off to the chase view
	Rows behind the front start up to 0.1 s later (all done by 2.15). Launch Animations only
	change the arc height and the landing flourish: duration, slot and end pose are identical.
]]

local MotionFeel = {}

local UP = Vector3.new(0, 1, 0)

MotionFeel.ReferenceSpeed = 80 -- PhysicsConfig.Movement.TerminalSpeed (a spec keeps them equal)

local function clamp(x, lo, hi)
	if x < lo then
		return lo
	elseif x > hi then
		return hi
	end
	return x
end

local function expAlpha(rate, dt)
	return 1 - math.exp(-rate * dt)
end

local function smoothstep(x)
	x = clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end
MotionFeel.Smoothstep = smoothstep

---------------------------------------------------------------------------------------------
-- Speed trail
MotionFeel.Trail = {
	Knots = { { 0.15, 0 }, { 0.35, 4 }, { 0.65, 12 }, { 1.0, 24 } },
	MaxLength = 24,
	LowMaxLength = 7, -- Low graphics: a brief outline of your own motion only
	OnFraction = 0.17,
	OffFraction = 0.13,
	SpeedResponse = 10,
	GrowResponse = 4,
	ShrinkResponse = 8,
	BrakeShrinkResponse = 14,
	BrakeLengthFactor = 0.45,
	SanityFactor = 1.6,
	TeleportStuds = 14,
	DropoutSeconds = 0.3,
	FadeInStuds = 5, -- opacity ramps in over the first N studs of length
	-- ribbon width per trail profile (studs); Twin = two ribbons this wide
	Widths = { Ribbon = 1.4, Thin = 0.6, Wide = 2.3, Twin = 0.7 },
	TwinGap = 1.1,
}

function MotionFeel.TrailLength(fraction)
	local knots = MotionFeel.Trail.Knots
	if fraction <= knots[1][1] then
		return 0
	end
	for i = 2, #knots do
		local a, b = knots[i - 1], knots[i]
		if fraction <= b[1] then
			local u = (fraction - a[1]) / (b[1] - a[1])
			return a[2] + (b[2] - a[2]) * u
		end
	end
	return math.min(knots[#knots][2], MotionFeel.Trail.MaxLength)
end

function MotionFeel.NewTrailState()
	return { last = nil, speed = 0, length = 0, on = false }
end

-- Advance one trail. Returns length (studs), opacity 0..1, cleared (history must be wiped).
function MotionFeel.StepTrail(st, dt, position, braking, maxLength)
	local cfg = MotionFeel.Trail
	local ref = MotionFeel.ReferenceSpeed
	if st.last == nil or dt <= 0 or dt > cfg.DropoutSeconds then
		st.last, st.speed, st.length, st.on = position, 0, 0, false
		return 0, 0, true
	end
	local distance = (position - st.last).Magnitude
	st.last = position
	if distance > ref * cfg.SanityFactor * dt + cfg.TeleportStuds then
		st.speed, st.length, st.on = 0, 0, false
		return 0, 0, true
	end
	local raw = math.min(distance / dt, ref * cfg.SanityFactor)
	st.speed = st.speed + (raw - st.speed) * expAlpha(cfg.SpeedResponse, dt)
	local fraction = st.speed / ref
	if st.on and fraction < cfg.OffFraction then
		st.on = false
	elseif not st.on and fraction > cfg.OnFraction then
		st.on = true
	end
	local target = st.on and MotionFeel.TrailLength(fraction) or 0
	if braking then
		target = target * cfg.BrakeLengthFactor
	end
	target = math.min(target, maxLength or cfg.MaxLength)
	local rate = target > st.length and cfg.GrowResponse or (braking and cfg.BrakeShrinkResponse or cfg.ShrinkResponse)
	st.length = st.length + (target - st.length) * expAlpha(rate, dt)
	if st.length < 0.05 then
		st.length = 0
	end
	local opacity = clamp(st.length / cfg.FadeInStuds, 0, 1) * (braking and 0.55 or 1)
	return st.length, opacity, false
end

-- Trail.Lifetime that draws `length` studs at `speed` (studs/s)
function MotionFeel.TrailLifetime(length, speed)
	if length <= 0 then
		return 0.02
	end
	return clamp(length / math.max(speed, 6), 0.02, 0.7)
end

---------------------------------------------------------------------------------------------
-- Camera FOV kick and edge streaks
MotionFeel.Fov = { MaxKick = 8, From = 0.55, To = 0.95 }

function MotionFeel.FovKick(fraction, reducedMotion)
	if reducedMotion then
		return 0
	end
	local f = MotionFeel.Fov
	return f.MaxKick * smoothstep((fraction - f.From) / (f.To - f.From))
end

function MotionFeel.StreakAlpha(fraction)
	return 0.5 * smoothstep((fraction - 0.8) / 0.18)
end

---------------------------------------------------------------------------------------------
-- Launch ramp intro
MotionFeel.Launch = {
	StartDelay = 0.2, -- after the Preparing timestamp: the grid replicates first
	Wide = 0.6,
	Lip = 1.1,
	Land = 1.75,
	End = 2.05,
	SideCut = 0.95,
	RowDelay = 0.033, -- per row from the front (4 rows -> 0.1 s)
	Radius = 2,
	-- per launch style: arc height (studs) and landing flourish
	Styles = {
		launch_ramp = { arc = 6, flourish = "Bounce" },
		launch_comet = { arc = 3.2, flourish = "Stick", streak = true },
		launch_spring = { arc = 9, flourish = "Spring" },
		launch_afterimage = { arc = 6, flourish = "Bounce", echoes = { 0.07, 0.14 } },
	},
	DefaultStyle = "launch_ramp",
	-- ramp placement relative to the back grid row (studs)
	LipBack = 12,
	LipUp = 4.5,
	TopBack = 40,
	TopUp = 20,
	RowSpacing = 4.5,
	ColumnScale = 0.85,
}

function MotionFeel.LaunchStyle(id)
	return MotionFeel.Launch.Styles[id or ""] or MotionFeel.Launch.Styles[MotionFeel.Launch.DefaultStyle]
end

function MotionFeel.LaunchEnd(rows)
	local L = MotionFeel.Launch
	return L.End + math.max(0, (rows or 4) - 1) * L.RowDelay
end

-- Ramp geometry from the grid: backCenter = centre of the back row, forward = grid forward.
-- Returns { top, lip, slope (unit, top->lip), right, deckUp, forward }.
function MotionFeel.RampGeometry(backCenter, forward)
	local L = MotionFeel.Launch
	local flat = Vector3.new(forward.X, 0, forward.Z)
	flat = flat.Magnitude > 1e-3 and flat.Unit or Vector3.new(0, 0, -1)
	local right = flat:Cross(UP).Unit
	local lip = backCenter - flat * L.LipBack + UP * L.LipUp
	local top = lip - flat * L.TopBack + UP * L.TopUp
	local slope = (lip - top).Unit
	local deckUp = right:Cross(slope).Unit
	if deckUp.Y < 0 then
		deckUp = -deckUp
	end
	return { top = top, lip = lip, slope = slope, right = right, deckUp = deckUp, forward = flat }
end

-- Start (on the ramp) and lip points for a marble whose grid slot is `slot` (Vector3), in
-- formation row `row` (1 = front) and lateral offset `lateral` (studs, from the grid column).
function MotionFeel.LaunchPath(geo, slot, row, lateral)
	local L = MotionFeel.Launch
	local side = geo.right * (lateral * L.ColumnScale)
	local lift = geo.deckUp * L.Radius
	local start = geo.top - geo.slope * ((row - 1) * L.RowSpacing) + side + lift
	local lip = geo.lip + side + lift
	return { start = start, lip = lip, slot = slot, delay = (row - 1) * L.RowDelay }
end

-- Pose of a stand-in `t` seconds into the intro. Returns position, roll angle (radians about
-- geo.right), phase name. At t >= End + delay the pose is exactly the slot.
function MotionFeel.LaunchPose(path, t, styleId)
	local L = MotionFeel.Launch
	local style = MotionFeel.LaunchStyle(styleId)
	local tt = t - path.delay
	local rampLen = (path.lip - path.start).Magnitude
	local arcLen = (path.slot - path.lip).Magnitude
	if tt < L.Wide then
		return path.start, 0, "Wide"
	elseif tt < L.Lip then
		local u = (tt - L.Wide) / (L.Lip - L.Wide)
		local s = u * u
		return path.start:Lerp(path.lip, s), (rampLen * s) / L.Radius, "Ramp"
	elseif tt < L.Land then
		local u = (tt - L.Lip) / (L.Land - L.Lip)
		local p = path.lip:Lerp(path.slot, u) + UP * (style.arc * 4 * u * (1 - u))
		return p, (rampLen + arcLen * u) / L.Radius, "Arc"
	elseif tt < L.End then
		local v = (tt - L.Land) / (L.End - L.Land)
		local h = 0
		if style.flourish == "Bounce" then
			h = 0.9 * math.sin(math.pi * v) * (1 - v)
		elseif style.flourish == "Spring" then
			h = 2.4 * math.abs(math.sin(3 * math.pi * v)) * (1 - v) * (1 - v)
		end
		return path.slot + UP * h, (rampLen + arcLen) / L.Radius, "Land"
	end
	return path.slot, (rampLen + arcLen) / L.Radius, "Done"
end

-- Scripted camera for 0 .. SideCut (wide) and SideCut .. Land (low side). Returns a CFrame,
-- or nil from Land on (the caller blends into the chase camera).
function MotionFeel.LaunchCamera(geo, t, packCenter)
	local L = MotionFeel.Launch
	if t < L.SideCut then
		local mid = geo.top - geo.slope * 7
		local pos = mid + geo.right * 40 + UP * 16 + geo.forward * 14 + geo.forward * (t * 5)
		return CFrame.lookAt(pos, mid + geo.slope * 8, UP)
	elseif t < L.Land then
		local pos = geo.lip + geo.right * 30 + UP * 1.5 + geo.forward * 10
		local look = packCenter or (geo.lip + geo.forward * 14)
		return CFrame.lookAt(pos, look, UP)
	end
	return nil
end

return MotionFeel
