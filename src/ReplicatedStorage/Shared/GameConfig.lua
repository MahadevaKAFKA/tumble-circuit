--[[
	GameConfig — non-physics tunables for A1: camera, input timings, UI, spawn/reset rules.
	Physics feel lives in PhysicsConfig. Nothing here is a secret; this module replicates to clients.
]]

local GameConfig = {}

GameConfig.Version = "A1.0"
GameConfig.BuildLabel = "A1 prototype - practice course"

GameConfig.Debug = {
	RunTestsInStudio = true, -- TestRunner prints PASS/FAIL to Output when playing in Studio
	VerboseLogging = false,
	-- Frame-time overlay (top left). ON for the private phone playtests so stalls can be read on a
	-- phone with no F2 key; turn it off before anyone else plays. F2 toggles it in game.
	PerfOverlayDefault = true,
	HitchThresholdSeconds = 0.25, -- frames longer than this are logged with where the marble was
}

GameConfig.Spawn = {
	ResetCooldownSeconds = 0.75, -- server rejects resets faster than this
	ClientResetThrottleSeconds = 0.5,
	FallRespawnDelaySeconds = 1.0, -- let the fall read before respawning
	SpawnLift = 0.25, -- studs of clearance between marble and floor at spawn
	ClientWaitTimeoutSeconds = 20, -- client gives up waiting for course/remotes and shows an error
}

GameConfig.Run = {
	MinPlausibleSeconds = 8, -- faster finishes are logged as anomalies and not recorded as best
}

GameConfig.Input = {
	RecoverHoldSeconds = 1.0, -- hold R / Y / touch RESET this long to respawn at start
	TriggerBrakeThreshold = 0.35, -- LT analog value that counts as braking
}

GameConfig.Camera = {
	FieldOfView = 70,
	DefaultMode = "Chase",
	Modes = {
		Chase = { Distance = 20, PitchOffsetDeg = 0 },
		Wide = { Distance = 26, PitchOffsetDeg = 6 },
	},
	BasePitchDeg = 16, -- normal downward look angle
	MinPitchDeg = 8,
	MaxPitchDeg = 58, -- hard cap keeps the look vector far from vertical (no up-vector flip)
	DropPitchGain = 0.85, -- how much of the route's downward angle ahead is added to pitch
	LookAheadStuds = 26, -- route distance ahead used to detect drops
	HeadingLookAheadStuds = 8, -- route distance ahead used for camera heading
	HeadingSmoothingStuds = 10, -- heading = route chord +/- this many studs (0 = raw polyline, turns in kicks)
	AimAheadStuds = 6, -- the camera aims slightly ahead of the marble
	FocusHeight = 1.5,
	HeadingResponse = 4.0, -- 1/s exponential smoothing rates (frame-rate independent)
	PitchResponse = 3.0,
	FocusVerticalResponse = 10,
	ZoomInResponse = 18, -- obstruction pulls the camera in fast...
	ZoomOutResponse = 2.5, -- ...and lets it back out slowly
	MinDistance = 7,
	ObstructionPadding = 0.8,
	SnapDistance = 60, -- marble moved farther than this between frames (respawn) => snap, no swoop
}

GameConfig.UI = {
	ReferenceWidth = 1280,
	ReferenceHeight = 720,
	MinScale = 0.6, -- keeps touch targets >= ~44 px on small phones
	MaxScale = 1.25,
	TouchStickRadius = 70, -- reference px
	TouchButtonSize = 120,
	TouchSmallButtonSize = 84,
}

GameConfig.Tutorial = {
	SteerSecondsRequired = 0.25, -- steer each way this long to complete the hint
}

GameConfig.Audio = {
	MasterVolume = 0.6, -- only used once real sound IDs are set in PLACEHOLDER_IDS
}

-- Procedural palette (master reference section 5).
GameConfig.Palette = {
	Navy = Color3.fromHex("#10172D"),
	NavyFloor = Color3.fromHex("#1E2A52"),
	NavyRail = Color3.fromHex("#2B3A75"),
	Ink = Color3.fromHex("#0A0F1E"),
	Cyan = Color3.fromHex("#27D7F5"),
	Coral = Color3.fromHex("#FF6B70"),
	Yellow = Color3.fromHex("#FFD45A"),
	Violet = Color3.fromHex("#A078FF"),
	Mint = Color3.fromHex("#6EE7BA"),
	White = Color3.fromHex("#F4F7FF"),
}

return GameConfig
