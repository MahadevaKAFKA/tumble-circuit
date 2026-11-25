--[[
	HazardSim — deterministic A4 hazards (pure; shared by clients, server and tests).

	Every moving hazard's state is a function of (t, params) where t = serverTime - epoch
	(epoch = the race's GO time, or 0 outside races) and params come from the hazard definition
	merged with the round's seed class (0 = base, 1 and 2 = the two deterministic variations).
	Same seed + same t => identical state on every machine and in every replay (HazardReset.spec).

	Kinds:
	  Sweeper    rotating arm around a floor post; contact -> tangential kick
	  Hammer     head swinging across the lane; contact -> sideways kick in its swing direction
	  Tiles      grid of floor tiles: solid -> telegraph (0.8 s) -> dropped -> solid
	  Fan        tunnel gust (lateral push) with a 0.7 s warning, on/off cycle
	  Conveyor   constant sideways push on a floor strip
	  Trampoline pad that adds an upward kick on contact
	  PulseBumper (A1 bumper) is timed by HazardTiming; listed here for seeds/phases.
	All kicks are capped (KickCap) and are velocity CHANGES applied by the marble's owner.
]]

local HazardSim = {}

HazardSim.KickCap = 30 -- absolute studs/s cap for any hazard kick
HazardSim.SeedClasses = 3

-- Per seed class overrides by hazard Id. Base (0) uses the definition values.
HazardSim.Variants = {
	[1] = {
		Sweeper1 = { Direction = -1, Speed = 1.3 },
		Hammer1 = { Period = 2.6, PhaseOffset = 0.5 },
		Tiles1 = { SeedOffset = 3 },
		Fan1 = { Direction = -1, PhaseOffset = 1.2 },
		Conveyor1 = { Direction = -1 },
		BumperA = { PhaseOffset = 1.1 },
		BumperB = { PhaseOffset = 2.0 },
	},
	[2] = {
		Sweeper1 = { Direction = 1, Speed = 1.55 },
		Hammer1 = { Period = 3.4, PhaseOffset = 1.3 },
		Tiles1 = { SeedOffset = 5, Period = 4.2 },
		Fan1 = { Direction = 1, OnSeconds = 1.6, PhaseOffset = 0.4 },
		Conveyor1 = { Direction = 1, Accel = 26 },
		BumperA = { PhaseOffset = 0.4 },
		BumperB = { PhaseOffset = 1.6 },
	},
}

function HazardSim.Params(definition, seedClass)
	local out = {}
	for key, value in pairs(definition) do
		out[key] = value
	end
	local variant = HazardSim.Variants[seedClass or 0]
	local override = variant and definition.Id and variant[definition.Id]
	if override then
		for key, value in pairs(override) do
			out[key] = value
		end
	end
	return out
end

local function clamp(x, lo, hi)
	if x < lo then
		return lo
	elseif x > hi then
		return hi
	end
	return x
end

---------------------------------------------------------------------------------------------
-- State (visuals and contact both use these)
---------------------------------------------------------------------------------------------
function HazardSim.SweeperAngle(p, t)
	return (p.PhaseOffset or 0) + (p.Direction or 1) * p.Speed * t
end

function HazardSim.HammerLateral(p, t)
	local w = 2 * math.pi / p.Period
	local phase = w * t + (p.PhaseOffset or 0)
	return p.Amplitude * math.sin(phase), p.Amplitude * w * math.cos(phase)
end

-- "Solid" | "Telegraph" | "Dropped"
function HazardSim.TileState(p, row, col, t)
	local period = p.Period
	local k = p.Rows * p.Cols
	local index = ((row - 1) * 3 + (col - 1) * 7 + (p.SeedOffset or 0)) % k
	local phase = (t + index / k * period) % period
	local dropAt = period - p.DropSeconds
	local warnAt = dropAt - p.TelegraphSeconds
	if phase >= dropAt then
		return "Dropped"
	elseif phase >= warnAt then
		return "Telegraph"
	end
	return "Solid"
end

-- Fan: "Off" | "Warning" | "On" and the push multiplier (0/0/1)
function HazardSim.FanState(p, t)
	local cycle = p.OnSeconds + p.OffSeconds
	local phase = (t + (p.PhaseOffset or 0)) % cycle
	if phase < p.OnSeconds then
		return "On", 1
	elseif phase >= cycle - p.TelegraphSeconds then
		return "Warning", 0
	end
	return "Off", 0
end

---------------------------------------------------------------------------------------------
-- Resolved hazard instances (geometry from the layout frame, params from the seed)
---------------------------------------------------------------------------------------------
-- h = { Kind, Id, Params, Frame (centre frame on the floor), FromFrame/ToFrame for zones }
function HazardSim.Local(h, position)
	local rel = position - h.Frame.Position
	return rel:Dot(h.Frame.Right), rel:Dot(h.Frame.Up), rel:Dot(h.Frame.Forward) -- x, y, z (z = along travel)
end

-- Returns a velocity-change Vector3 (or nil) for a marble at `position` with radius r at time t.
function HazardSim.Contact(h, t, position, r)
	local p = h.Params
	local f = h.Frame
	local x, y, z = HazardSim.Local(h, position)
	if h.Kind == "Sweeper" then
		if y > p.ArmHeight + 2 or y < -1 then
			return nil
		end
		local angle = HazardSim.SweeperAngle(p, t)
		local ax, az = math.cos(angle), math.sin(angle)
		local along = clamp(x * ax + z * az, 0, p.ArmLength)
		local cx, cz = ax * along, az * along
		local dx, dz = x - cx, z - cz
		local d = math.sqrt(dx * dx + dz * dz)
		if d > r + p.ArmThickness / 2 + 0.3 then
			return nil
		end
		-- tangential direction of the arm's motion at the contact point
		local dir = p.Direction or 1
		local tx, tz = -az * dir, ax * dir
		local speed = clamp(p.Speed * along + 8, 10, 26)
		local v = (f.Right * tx + f.Forward * tz) * speed + f.Up * 4
		return v.Magnitude > HazardSim.KickCap and v.Unit * HazardSim.KickCap or v
	elseif h.Kind == "Hammer" then
		local lateral, velocity = HazardSim.HammerLateral(p, t)
		local dx, dz = x - lateral, z
		local half = p.HeadSize / 2
		if math.abs(dx) > half + r or math.abs(dz) > half + r or y > p.HeadSize + 1 then
			return nil
		end
		local side = velocity ~= 0 and (velocity > 0 and 1 or -1) or (dx >= 0 and 1 or -1)
		local speed = clamp(math.abs(velocity) * 1.3 + 6, 10, 28)
		return f.Right * (side * speed) + f.Up * 6
	elseif h.Kind == "Trampoline" then
		if math.abs(x - (p.Offset or 0)) <= p.Width / 2 and math.abs(z) <= p.Length / 2 and y <= r + 0.9 then
			return f.Up * math.min(p.UpDeltaV, HazardSim.KickCap + 15)
		end
	end
	return nil
end

-- Continuous push (studs/s^2) from zone hazards, or nil.
function HazardSim.EnvironmentAccel(h, t, position)
	local p = h.Params
	if h.Kind ~= "Fan" and h.Kind ~= "Conveyor" then
		return nil
	end
	local rel = position - h.FromFrame.Position
	local along = rel:Dot(h.FromFrame.Forward)
	if along < 0 or along > h.Length then
		return nil
	end
	local x = (position - h.Frame.Position):Dot(h.Frame.Right)
	if math.abs(x) > h.Frame.Width / 2 + 2 then
		return nil
	end
	local strength = p.Accel
	if h.Kind == "Fan" then
		local _, on = HazardSim.FanState(p, t)
		strength = strength * on
	end
	if strength == 0 then
		return nil
	end
	return h.Frame.Right * ((p.Direction or 1) * strength)
end

-- Is the hazard currently dangerous near `position` (for near-miss judging)?
function HazardSim.Dangerous(h, t)
	if h.Kind == "Fan" then
		local state = HazardSim.FanState(h.Params, t)
		return state ~= "Off"
	end
	return h.Kind == "Sweeper" or h.Kind == "Hammer"
end

return HazardSim
