--[[
	RaceConfig — A2 round timings, recovery, collision and validation tunables.
	Hypotheses from the master reference; adjust from playtests.
]]

local RaceConfig = {}

RaceConfig.Timers = {
	IntermissionSeconds = 15,
	PreparingSeconds = 2.5, -- racers placed on the grid, frozen (2026-11-26: 2 -> 2.5 for the launch-ramp intro, which ends at 2.35)
	CountdownSeconds = 3, -- 3-2-1, then GO opens the gate
	MaxRaceSeconds = 180, -- Racing only; loading/countdown excluded
	ResultsSeconds = 12,
	CleanupSeconds = 1,
	GoBannerSeconds = 1, -- client shows "GO!" this long after Racing begins
	-- Circuits (2026-11-26 three-lap brief). PROVISIONAL until phone slow-finisher data exists:
	-- the course's own MaxRaceSeconds (Foundry: 480 s = ~2.3x the lap model's clean race) is the
	-- hard cap; once the leader finishes everyone else gets this long (never more than was left).
	FinishGraceSeconds = 90,
	FinishRollOutSeconds = 1.2, -- a finisher rolls on this long, then moves to the finisher deck
}

-- Time Trial on a circuit: 1 lap (its own record key); set to 3 for full-race trials
RaceConfig.TimeTrialLaps = 1

RaceConfig.Recovery = {
	FallRespawnDelaySeconds = 1.5, -- master target 1.5-2 s
	ManualHoldSeconds = 1.0,
	ServerRecoverCooldownSeconds = 1.5,
	ProtectionSeconds = 2.0, -- ghost (no marble collisions) after any spawn
	OffRouteDistance = 40, -- farther than this from the centreline = off course
	OffRouteSeconds = 0.6, -- ...for this long counts as a fall (plus the kill height)
	CheckpointRespawnAhead = 6, -- respawn this many studs past the confirmed checkpoint
	-- Client-side stuck hint: trying to move, < MinProgress studs gained and < MaxSpeed for Seconds.
	StuckSeconds = 3,
	StuckMinProgress = 2,
	StuckMaxSpeed = 1.5,
}

RaceConfig.Validation = {
	-- A checkpoint/finish crossing is rejected if the route distance since the previous
	-- confirmed crossing was covered faster than TerminalSpeed * PlausibleSpeedFactor.
	PlausibleSpeedFactor = 1.35,
	-- Movement audit: distance moved within any WindowSeconds may not exceed
	-- TerminalSpeed * PlausibleSpeedFactor * WindowSeconds + SlackStuds (teleport check).
	WindowSeconds = 1.0,
	SlackStuds = 15,
	CorridorExtra = 4, -- a crossing must be within half-width + this of the centreline
}

RaceConfig.Collisions = {
	MarbleGroup = "TC_Marble",
	ProtectedGroup = "TC_Protected",
	-- Client-side bump limiter: a single-frame velocity change from touching another marble is
	-- capped to MaxBumpDeltaV; after a big bump, further bumps are capped to ChainBumpDeltaV for
	-- AntiChainSeconds (master: bounded knockback, 1.2 s anti-chain-stun).
	MaxBumpDeltaV = 45,
	ChainBumpDeltaV = 18,
	AntiChainSeconds = 1.2,
	BumpProximity = 5.5, -- centres within this distance = marble contact
}

-- READY vote (owner request, 2026-11-25). Open only while the race is full: the queued players
-- fill every slot humans can take (min(grid slots, server size)), so nobody else can join. Once
-- every queued player is READY the intermission ends at once. Otherwise the timer runs and the
-- HUD says "Waiting for players".
RaceConfig.Ready = {
	Enabled = true,
	CapacityOverride = 0, -- > 0: count the race as full at this many queued players (test builds only)
}

-- A4 bots (ADR-08): fill the grid to FillTo racers when 1-7 humans are queued. Bots never
-- start a round on their own, never enter the hub, and are excluded from human records.
RaceConfig.Bots = {
	Enabled = true,
	FillTo = 8,
	HumansDoneGraceSeconds = 10, -- after every human finished, bots get this long to finish
	FixedCount = nil, -- set at runtime by the Studio dev panel (A5 DevService) to force a bot count
}

RaceConfig.Snapshot = {
	StandingsHz = 2, -- standings pushed at most this often, and only when they changed
}

RaceConfig.Spectate = {
	Enabled = true,
}

return RaceConfig
