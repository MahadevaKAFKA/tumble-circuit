--[[
	AbilityConfig — A3 starter abilities and micro-skills (master section 4). Exact values are
	starting hypotheses. The server owns every timestamp and effect; clients only display.
]]

local AbilityConfig = {}

AbilityConfig.Ids = { Boost = "Boost", Shield = "Shield", Pulse = "Pulse" }
AbilityConfig.StarterOwned = { "Boost", "Shield", "Pulse" }
AbilityConfig.DefaultLoadout = { "Boost", "Shield" }
AbilityConfig.SlotCount = 2

AbilityConfig.Abilities = {
	Boost = {
		Id = "Boost",
		DisplayName = "BOOST",
		Cooldown = 20,
		Duration = 1.6,
		SpeedMultiplier = 1.3, -- timed modifier on throttle accel, throttle target and terminal
		ExtraForwardAccel = 18, -- studs/s^2 pushed along track-forward even without W
		Color = "Cyan",
		Description = "+30% speed for 1.6 s",
	},
	Shield = {
		Id = "Shield",
		DisplayName = "SHIELD",
		Cooldown = 28,
		Duration = 2.5, -- or until the first hostile Pulse / active bumper hit, whichever first
		Color = "Violet",
		Description = "Blocks one Pulse, bumper, sweeper or hammer hit",
	},
	Pulse = {
		Id = "Pulse",
		DisplayName = "PULSE",
		Cooldown = 26,
		Radius = 12,
		MaxDeltaV = 18, -- studs/s at the centre, falls off to EdgeFraction at the radius
		EdgeFraction = 0.5,
		Color = "Coral",
		Description = "Nudges rivals within 12 studs",
	},
}

-- Absolute cap for any speed modifier (studs/s). Must stay below the movement audit envelope
-- (TerminalSpeed * PlausibleSpeedFactor = 108) so boosted racers are never flagged.
AbilityConfig.HardSpeedCap = 96

AbilityConfig.MicroSkills = {
	Trick = {
		SpeedMultiplier = 1.15,
		Duration = 1.2,
		EarlyPressSeconds = 0.3, -- a press this long before takeoff still counts
		LatePressSeconds = 0.45, -- ...or this long after takeoff while still airborne
		MaxAirtimeSeconds = 1.4, -- landing must follow takeoff within this
		MinTakeoffSpeed = 15,
		MinTakeoffHeight = 0.8, -- above the route plane at the lip (i.e. really launched)
		LandedHeight = 0.6,
	},
	Slipstream = {
		SpeedMultiplier = 1.12,
		MaxDistance = 12,
		MinAheadDot = 0.7,
		HoldSeconds = 1.5, -- continuous before it activates
		GraceSeconds = 0.25, -- brief LOS flicker does not end it
	},
	NearMiss = {
		ApproachRadius = 16, -- an approach starts inside this distance to the hazard axis
		Band = 3.5, -- closest pass within this many studs beyond contact = near miss
	},
	PerfectDodge = { -- A6 commendation for passing a sweeper / hammer close without contact
		ApproachRadius = 16,
		Band = 2.5,
	},
	CooldownCharge = {
		Seconds = 1.5,
		GlobalLockoutSeconds = 3,
	},
}

return AbilityConfig
