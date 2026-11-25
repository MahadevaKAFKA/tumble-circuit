--[[
	AbilityConfig — A3 starter abilities and micro-skills (master section 4) and the nine B2
	play-earned abilities (master section 8). Exact values are starting hypotheses. The server owns every timestamp and effect; clients only display.
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
	-- B2: nine more active abilities, earned by play only (master section 8). Unlock = reach the
	-- level OR spend earned Coins (800 / 1200 / 1600 tiers). Never Robux. Hitbox and mass never change.
	FrostWake = {
		Id = "FrostWake", DisplayName = "FROST WAKE", Cooldown = 32, Color = "Cyan",
		Duration = 2.2, LaneWidth = 10, LaneLength = 24, SteerMultiplier = 0.75, ChillSeconds = 1.2,
		Description = "Icy 10-stud lane behind you: rivals crossing it steer 25% less for 1.2 s",
		Unlock = { Level = 6, Coins = 1200 },
	},
	Magnet = {
		Id = "Magnet", DisplayName = "MAGNET", Cooldown = 30, Color = "Violet",
		Duration = 1.5, Radius = 10, TickSeconds = 0.5, DeltaVPerTick = 3, MaxTotalDeltaV = 9,
		Description = "Gently pulls rivals within 10 studs toward you for 1.5 s (Shield resists)",
		Unlock = { Level = 3, Coins = 800 },
	},
	Phase = {
		Id = "Phase", DisplayName = "PHASE", Cooldown = 38, Color = "Mint",
		Duration = 1.5,
		Description = "Pass through bumpers, sweepers and hammers for 1.5 s (floor, walls and checkpoints stay)",
		Unlock = { Level = 10, Coins = 1600 },
	},
	GrappleSpark = {
		Id = "GrappleSpark", DisplayName = "GRAPPLE", Cooldown = 30, Color = "Yellow",
		Range = 24, MaxDeltaV = 20,
		Description = "Zips you toward a grapple ring within 24 studs ahead (never past a checkpoint)",
		Unlock = { Level = 6, Coins = 1200 },
	},
	BounceBurst = {
		Id = "BounceBurst", DisplayName = "BOUNCE", Cooldown = 22, Color = "Mint",
		Window = 2, UpDeltaV = 18,
		Description = "Your next landing or hit within 2 s bounces you up",
		Unlock = { Level = 3, Coins = 800 },
	},
	GravityGlide = {
		Id = "GravityGlide", DisplayName = "GLIDE", Cooldown = 35, Color = "Violet",
		Duration = 2.5, GravityReduction = 0.35, SteerMultiplier = 1.2,
		Description = "35% less gravity and sharper steering for 2.5 s",
		Unlock = { Level = 10, Coins = 1600 },
	},
	ReverseJet = {
		Id = "ReverseJet", DisplayName = "REVERSE JET", Cooldown = 28, Color = "Coral",
		DeltaV = 16,
		Description = "A quick backward hop to dodge (16 studs/s)",
		Unlock = { Level = 3, Coins = 800 },
	},
	Decoy = {
		Id = "Decoy", DisplayName = "DECOY", Cooldown = 40, Color = "Yellow",
		Duration = 3, LateralOffset = 5,
		Description = "A labelled hologram rolls beside you for 3 s (it can't touch anything)",
		Unlock = { Level = 10, Coins = 1600 },
	},
	Anchor = {
		Id = "Anchor", DisplayName = "ANCHOR", Cooldown = 30, Color = "Cyan",
		Duration = 2.5, KnockbackScale = 0.3, SteerAssist = 1.5,
		Description = "Absorbs 70% of knockback and steadies your steering for 2.5 s",
		Unlock = { Level = 6, Coins = 1200 },
	},
}

-- Display / menu order (starters first, then by unlock tier)
AbilityConfig.Order = { "Boost", "Shield", "Pulse", "Magnet", "BounceBurst", "ReverseJet", "FrostWake", "GrappleSpark", "Anchor", "Phase", "GravityGlide", "Decoy" }
for _, id in ipairs(AbilityConfig.Order) do
	AbilityConfig.Ids[id] = id
end

-- Pure: can `id` be unlocked now? returns ok, how ("Owned" / "Level" / "Coins"), detail
function AbilityConfig.UnlockState(id, ownedSet, level, coins)
	local def = AbilityConfig.Abilities[id]
	if not def then
		return false, "Unknown", "Unknown ability"
	end
	if ownedSet[id] then
		return true, "Owned", nil
	end
	local unlock = def.Unlock
	if not unlock then
		return false, "Locked", "Not unlockable"
	end
	if (level or 1) >= unlock.Level then
		return true, "Level", nil
	end
	if (coins or 0) >= unlock.Coins then
		return true, "Coins", unlock.Coins
	end
	return false, "Locked", string.format("Reach level %d or have %d Coins", unlock.Level, unlock.Coins)
end

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
