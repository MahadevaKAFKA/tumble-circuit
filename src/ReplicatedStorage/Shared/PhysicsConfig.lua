--[[
	PhysicsConfig — every marble-feel tunable lives here (A1).

	All values are starting HYPOTHESES from the master reference, not tested truths.
	The client motor reads this table every frame, so editing a value in Studio
	(before pressing Play) changes how the marble handles. Units: studs, seconds.

	Roblox default gravity (Workspace.Gravity) is 196.2 studs/s^2 and is kept unchanged.
]]

local PhysicsConfig = {}

-- The one physical body. 4-stud DIAMETER sphere => Radius 2. Hitbox never changes with cosmetics.
PhysicsConfig.Ball = {
	Radius = 2,
	Density = 1.0, -- mass = density * volume (~33.5 for r=2)
	Friction = 0.55,
	Elasticity = 0.2,
	FrictionWeight = 1,
	ElasticityWeight = 1,
}

-- Workspace.Gravity multiplier. 1.0 = Roblox default; spec allows 1.05-1.15 only if playtests show a need.
PhysicsConfig.GravityMultiplier = 1.0

PhysicsConfig.Movement = {
	-- Forward (W / stick up). Thrust tapers to zero as forward speed approaches ThrottleTargetSpeed,
	-- so slopes (gravity) are what take you toward TerminalSpeed.
	AlongTrackAccel = 35, -- studs/s^2 (spec hypothesis)
	ThrottleTargetSpeed = 44, -- studs/s, above this W adds nothing
	ThrottleTaperRange = 8, -- thrust fades over the last N studs/s below the target

	-- Back bias (S / stick down): gentle backwards push, capped.
	ReverseAccel = 22,
	ReverseSpeedCap = 10,

	-- Lateral steering (A/D / stick X), measured against the stable track-forward axis.
	LateralSpeedCap = 22, -- studs/s envelope that steering can push you to (spec hypothesis)
	LateralResponse = 6, -- 1/s, how fast lateral velocity approaches the steering target
	LateralAccelMax = 70, -- studs/s^2 clamp on steering acceleration
	LateralAssistDamping = 1.0, -- 1/s, mild pull of sideways drift back toward 0 when not steering (0 = off)

	-- Hub platform free roam (owner playtest 2026-11-25: on the round hub the track-relative
	-- steering and auto-align fought the player). On the open platform the stick moves the marble
	-- relative to the camera: it is pulled toward stick direction * FreeRoamSpeed. No auto-align.
	FreeRoamSpeed = 30, -- studs/s at full stick
	FreeRoamResponse = 3, -- 1/s
	FreeRoamAccelMax = 40, -- studs/s^2

	-- Terminal envelope: smooth drag above TerminalSpeed (never a velocity teleport).
	TerminalSpeed = 80,
	TerminalDragResponse = 4, -- 1/s
	TerminalDragMax = 240, -- studs/s^2, must exceed steepest-slope gravity component

	-- Airborne: steering & thrust are multiplied by AirControl.
	AirControl = 0.4,

	-- Brake (Shift / LT / touch BRAKE). On press, the target speed becomes
	-- BrakeTargetSpeedMultiplier * speed-at-press (never below BrakeMinTargetSpeed).
	-- While held, a bounded retarding force pulls speed down to that target and holds it there
	-- (e.g. on a downhill). Release and press again to cut another 35%.
	BrakeTargetSpeedMultiplier = 0.65,
	BrakeMinTargetSpeed = 6,
	BrakeResponse = 5, -- 1/s
	BrakeMaxDecel = 70, -- studs/s^2

	-- Speed envelope on gentle slopes. Without these a sphere on any downhill accelerates until
	-- TerminalSpeed (the offline 1-D model showed a ~11 s run pinned at 80). Equilibrium speed on
	-- a slope is roughly (g*sin(pitch) - RollingResistance) / LinearDrag: ~36 at 3deg, ~53 at 4deg.
	RollingResistance = 3, -- studs/s^2, constant decel while grounded and moving
	LinearDrag = 0.2, -- 1/s, proportional drag (air + rolling losses lumped together)

	-- After crossing the finish line input is off and this decel stops the marble in the basin.
	FinishBrakeDecel = 45,

	-- A force through the centre of a rolling solid sphere only produces 5/7 of F/m (the rest
	-- spins it up). While grounded the motor multiplies its forces by this, so every acceleration
	-- above is what the rolling marble really gets. Set to 1 to disable.
	RollingInertiaCompensation = 1.4,

	-- Analog steer radial deadzone (gamepad stick + touch stick).
	SteerDeadzone = 0.12,

	-- How quickly the steering frame turns to follow the track tangent (1/s), and how far ahead
	-- along the route it samples the tangent (studs).
	SteerFrameResponse = 8,
	SteerFrameLookAhead = 4,
	-- The steering frame follows the route chord +/- this many studs, so it turns smoothly through
	-- curves instead of in 5-degree kicks at every polyline vertex (0 = raw polyline).
	SteerFrameSmoothingStuds = 10,
}

PhysicsConfig.Ground = {
	ProbeRadiusFactor = 0.9, -- spherecast radius = Radius * factor
	ProbeExtra = 0.6, -- extra sweep distance below the ball surface
	MinNormalY = 0.35, -- surfaces steeper than this are walls, not ground
	CoyoteSeconds = 0.12, -- stay "grounded" briefly after leaving a surface (bump smoothing)
}

-- Surface materials built by the course builder.
PhysicsConfig.Track = {
	FloorFriction = 0.6,
	FloorElasticity = 0.1,
	RailFriction = 0.15, -- low so scraping a wall does not kill all speed
	RailElasticity = 0.35,
	BumperFriction = 0.2,
	BumperElasticity = 0.85,
	BumperElasticityWeight = 50, -- bumper bounciness dominates the combined value
}

PhysicsConfig.Hazards = {
	PulseBumper = {
		-- Timing is a deterministic function of server time, identical on every client.
		Period = 3.2, -- seconds per cycle
		TelegraphAt = 1.4, -- phase where the warning colour ramp starts
		ActiveAt = 2.2, -- phase where the bumper kicks (lasts until the cycle ends)
		KickSpeed = 24, -- outward speed (studs/s) the kick guarantees; gentle, capped
		ContactPadding = 0.4, -- extra studs beyond touching counted as contact
		CooldownSeconds = 0.5, -- one kick per contact
	},
}

-- Server-side observation only (A1 logs anomalies, it never punishes).
PhysicsConfig.Server = {
	AnomalySpeedFactor = 1.6, -- speed above TerminalSpeed * factor ...
	AnomalySustainSeconds = 0.5, -- ... for this long gets logged
	KillDepthBelowCourse = 40, -- studs below the course's lowest point = fell off
	MonitorHz = 20,
}

return PhysicsConfig
