-- Tumble Circuit: Chaos Drop — tuning constants (Phase A1 practice build)
-- Distances are studs, times are seconds, speeds are studs per second.
-- Change numbers here; nothing else needs editing to retune the marble.

local Config = {}

Config.Version = "A1-mobile-1"

Config.Marble = {
	Diameter = 4,
	Density = 1.2,
	Friction = 0.6,
	Elasticity = 0.2,
	FrictionWeight = 1,
	ElasticityWeight = 1,
	Color = Color3.fromRGB(0, 170, 255),
	Material = Enum.Material.Marble,
}

Config.Movement = {
	GroundAcceleration = 95, -- push while touching the floor
	AirAcceleration = 35, -- steering while airborne
	MaxSpeed = 60, -- input stops adding speed past this (slopes can still go faster)
	TurnAssist = 3, -- how quickly sideways drift is cancelled when steering (per second)
	ReverseBrake = 2.5, -- extra stopping power when steering against your motion
	CoastDamping = 0.6, -- gentle slow-down with no input on the floor (per second)
	JumpVelocity = 52, -- upward speed added by a jump (about 7 studs high)
	JumpCooldown = 0.35,
	JumpBuffer = 0.15, -- a jump pressed this long before landing still fires
	CoyoteTime = 0.12, -- a jump pressed this long after leaving an edge still fires
	GroundProbeExtra = 0.6, -- ground check reaches this far past the marble's bottom
	InputDeadzone = 0.08,
}

Config.Camera = {
	MinZoom = 10,
	MaxZoom = 45,
}

Config.Respawn = {
	DeathReloadDelay = 1.5, -- after a Humanoid death, reload the character this much later
	FallLockTime = 0.5, -- ignore new falls for this long after a respawn
	ServerWatchdogDepth = 120, -- server reloads the character if the marble is this far below KillY
}

Config.Checkpoints = {
	PollInterval = 0.1,
	RestartCooldown = 0.5,
}

return Config
