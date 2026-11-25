--[[
	TrackDefinitions — the A1 Training Chute, as pure data + a deterministic generator.

	The course is a centreline "turtle" walk: each piece advances a horizontal distance while
	turning (Yaw), descending (Pitch, + = downhill), banking (Bank, + = right edge lower) and
	changing width. Pitch/Bank/Width interpolate linearly inside a piece and must match at piece
	boundaries (the validator checks this), so the floor ribbon never has steps or gaps.

	Both server (to build parts and judge progress) and client (steering frame, camera) call
	Generate() with the same definition, so they agree exactly without replicating route data.

	Conventions (Roblox world): heading 0 travels toward -Z; positive Yaw turns right (toward +X).
	Pure module: Vector3 math only, no services, so tools/offline can execute it.
]]

local TrackDefinitions = {}

local function rad(d)
	return d * math.pi / 180
end

local function lerp(a, b, t)
	return a + (b - a) * t
end

---------------------------------------------------------------------------------------------
-- Course data: 6 segments (Start, StraightRamp, STurn, Bumper, BankedDrop, Finish)
---------------------------------------------------------------------------------------------
TrackDefinitions.Training = {
	Id = "TrainingChute_A1",
	DisplayName = "Training Chute",
	LayoutVersion = 1,
	Origin = Vector3.new(0, 240, 0), -- start pad back edge, floor surface
	StartHeadingDeg = 0,
	FloorThickness = 1.6,
	RailThickness = 1.2,
	DefaultRails = { 4.5, 4.5 }, -- {left, right} height above the floor surface
	MaxStepLength = 24, -- floor quads are at most this long
	MaxYawStepDeg = 5, -- curves are subdivided finely enough to look round
	MaxPitchStepDeg = 2, -- crests and sags are eased, not kinked
	MaxBankStepDeg = 3,

	Pieces = {
		-- Segment 1: START — flat practice pad (also the safe respawn point) + launch lip
		{ Name = "StartPad", Segment = "Start", Length = 36, Pitch = { 0, 0 }, Width = { 30, 30 }, Rails = { 5, 5 }, StartCap = true },
		{ Name = "Launch", Segment = "Start", Length = 14, Pitch = { 0, 5 }, Width = { 30, 22 }, Arrows = true },

		-- Segment 2: STRAIGHT RAMP
		{ Name = "StraightRamp", Segment = "StraightRamp", Length = 180, Pitch = { 5, 4 }, Width = { 22, 22 }, Arrows = true },
		{ Name = "RampEase", Segment = "StraightRamp", Length = 20, Pitch = { 4, 3 }, Width = { 22, 22 }, Arrows = true },

		-- Segment 3: S-TURN (left then right, net heading change 0, banked into each turn)
		{ Name = "SCurveA", Segment = "STurn", Length = 55, Yaw = -35, Pitch = { 3, 3 }, Bank = { 0, -10 }, Width = { 22, 22 }, Rails = { 4.5, 6 } },
		{ Name = "SCurveB", Segment = "STurn", Length = 55, Yaw = -35, Pitch = { 3, 3 }, Bank = { -10, 0 }, Width = { 22, 22 }, Rails = { 4.5, 6 } },
		{ Name = "SCurveC", Segment = "STurn", Length = 55, Yaw = 35, Pitch = { 3, 3 }, Bank = { 0, 10 }, Width = { 22, 22 }, Rails = { 6, 4.5 } },
		{ Name = "SCurveD", Segment = "STurn", Length = 55, Yaw = 35, Pitch = { 3, 3 }, Bank = { 10, 0 }, Width = { 22, 22 }, Rails = { 6, 4.5 } },

		-- Segment 4: BUMPER — widened lane with one telegraphed pulse bumper in the middle
		{ Name = "BumperApproach", Segment = "Bumper", Length = 40, Pitch = { 3, 3 }, Width = { 22, 26 }, Arrows = true },
		{ Name = "BumperZone", Segment = "Bumper", Length = 90, Pitch = { 3, 3 }, Width = { 26, 26 } },
		{ Name = "BumperExit", Segment = "Bumper", Length = 20, Pitch = { 3, 5 }, Width = { 26, 22 }, Arrows = true },

		-- Segment 5: BANKED DROP — descending 90-degree right turn, steepest part of the course
		{ Name = "BankedDropIn", Segment = "BankedDrop", Length = 30, Yaw = 20, Pitch = { 5, 18 }, Bank = { 0, 16 }, Width = { 22, 24 }, Rails = { 7, 4.5 } },
		{ Name = "BankedDropMid", Segment = "BankedDrop", Length = 90, Yaw = 50, Pitch = { 18, 20 }, Bank = { 16, 18 }, Width = { 24, 24 }, Rails = { 7.5, 4.5 } },
		{ Name = "BankedDropOut", Segment = "BankedDrop", Length = 40, Yaw = 20, Pitch = { 20, 4 }, Bank = { 18, 0 }, Width = { 24, 22 }, Rails = { 7, 4.5 } },

		-- Segment 6: FINISH — run-out, finish line, uphill catch basin with an end wall
		{ Name = "RunOut", Segment = "Finish", Length = 80, Pitch = { 4, 2 }, Width = { 22, 22 }, Arrows = true },
		{ Name = "FinishStraight", Segment = "Finish", Length = 40, Pitch = { 2, 1 }, Width = { 22, 26 }, Arrows = true },
		{ Name = "FinishBasin", Segment = "Finish", Length = 40, Pitch = { 1, -3 }, Width = { 26, 30 }, Rails = { 6, 6 }, EndCap = true },
	},

	-- At 14 the chase camera (20 studs back, 16 deg) looks over the 5-stud back wall with ~1.5 studs spare.
	Spawn = { Piece = "StartPad", At = 14 },
	StartLine = { Piece = "StartPad", At = 36 },
	FinishLine = { Piece = "FinishStraight", At = 40 },
	-- A2: ordered server-observed checkpoints (also the safe respawn points).
	Checkpoints = {
		{ Name = "S-Turn Exit", Piece = "BumperApproach", At = 2 },
		{ Name = "Bumper Exit", Piece = "BumperExit", At = 12 },
		{ Name = "Drop Exit", Piece = "RunOut", At = 6 },
	},
	-- A2: 16 start slots on the pad (4 x 4), front row first. Rows are piece-relative distances,
	-- columns lateral offsets. Validator checks spacing and rail clearance.
	Grid = { Piece = "StartPad", Rows = { 26, 20, 14, 8 }, Columns = { -9, -3, 3, 9 } },
	StartGate = { Piece = "StartPad", At = 33, Height = 5 },
	-- A3: tagged qualifying ramp for the Ramp Trick. Half-width kicker on the left; the right half
	-- stays flat (safe line). Lip = piece-relative At; it rises over Length to Height.
	Features = {
		{ Kind = "TrickRamp", Piece = "StraightRamp", At = 100, Offset = -5.5, Width = 9, Length = 7, Height = 3.4 },
	},
	Validation = { MinSegments = 4, MaxSegments = 6, MinLength = 500, MaxLength = 2000 },

	Hazards = {
		-- Gentle, telegraphed: cyan = idle (plain bounce), yellow ramp = warning, coral = kicks.
		{ Kind = "PulseBumper", Piece = "BumperZone", At = 44, Offset = 0, Radius = 3, Height = 4.5 },
	},
	-- Yellow warning chevrons on the floor before the hazard.
	WarningStrips = {
		{ Piece = "BumperZone", From = 6, To = 30 },
	},
	Signs = {
		{ Piece = "StartPad", At = 26, Text = "ROLL FORWARD TO START", Lift = 11 },
		{ Piece = "StraightRamp", At = 78, Text = "TRICK RAMP  -  JUMP, PRESS TRICK IN THE AIR", Lift = 10 },
		{ Piece = "SCurveA", At = 2, Text = "S-TURN", Lift = 10 },
		{ Piece = "BumperApproach", At = 6, Text = "PULSE BUMPER  -  CORAL = KICK", Lift = 10 },
		{ Piece = "BankedDropIn", At = 0, Text = "BANKED DROP  -  BRAKE IF FAST", Lift = 10 },
		{ Piece = "FinishStraight", At = 4, Text = "FINISH AHEAD", Lift = 10 },
	},
	Gates = {
		{ Kind = "Start", Piece = "StartPad", At = 36, Text = "START" },
		{ Kind = "Finish", Piece = "FinishStraight", At = 40, Text = "FINISH" },
	},
	ArrowSpacing = 16,
}


---------------------------------------------------------------------------------------------
-- A4: NEON FOUNDRY — the full World 1 race (16 modules). Segment = module name.
-- Hazards are data; their motion comes from HazardSim (deterministic, seeded per round).
---------------------------------------------------------------------------------------------
TrackDefinitions.NeonFoundry = {
	Id = "NeonFoundry_A4",
	DisplayName = "Neon Foundry",
	LayoutVersion = 2, -- v2: lengthened toward the 90-150 s race target (+8 travel pieces, 8 CPs)
	Origin = Vector3.new(0, 420, 0),
	StartHeadingDeg = 0,
	FloorThickness = 1.6,
	RailThickness = 1.2,
	DefaultRails = { 4.5, 4.5 },
	MaxStepLength = 24,
	MaxYawStepDeg = 5,
	MaxPitchStepDeg = 2,
	MaxBankStepDeg = 3,
	Pieces = {
		{ Name = "StartPad", Segment = "StartGrid", Kind = "Start", Length = 36, Pitch = { 0, 0 }, Width = { 30, 30 }, Rails = { 5, 5 }, StartCap = true },
		{ Name = "Launch", Segment = "StartGrid", Length = 14, Pitch = { 0, 5 }, Width = { 30, 22 }, Arrows = true },
		{ Name = "StraightRamp", Segment = "StraightRamp", Kind = "StraightRamp", Length = 240, Pitch = { 5, 4 }, Width = { 22, 22 }, Arrows = true },
		{ Name = "RampEase", Segment = "StraightRamp", Length = 20, Pitch = { 4, 3 }, Width = { 22, 22 } },
		{ Name = "SweepInto", Segment = "STurn", Kind = "STurn", Length = 100, Yaw = 35, Pitch = { 3, 3 }, Bank = { 0, 9 }, Width = { 22, 22 }, Rails = { 6, 4.5 } },
		{ Name = "SweepOut", Segment = "STurn", Length = 100, Yaw = 35, Pitch = { 3, 3 }, Bank = { 9, 0 }, Width = { 22, 22 }, Rails = { 6, 4.5 } },
		{ Name = "SCurveA", Segment = "STurn", Length = 70, Yaw = -35, Pitch = { 3, 3 }, Bank = { 0, -10 }, Width = { 22, 22 }, Rails = { 4.5, 6 } },
		{ Name = "SCurveB", Segment = "STurn", Length = 70, Yaw = -35, Pitch = { 3, 3 }, Bank = { -10, 0 }, Width = { 22, 22 }, Rails = { 4.5, 6 } },
		{ Name = "SCurveC", Segment = "STurn", Length = 70, Yaw = 35, Pitch = { 3, 3 }, Bank = { 0, 10 }, Width = { 22, 22 }, Rails = { 6, 4.5 } },
		{ Name = "SCurveD", Segment = "STurn", Length = 70, Yaw = 35, Pitch = { 3, 3 }, Bank = { 10, 0 }, Width = { 22, 22 }, Rails = { 6, 4.5 } },
		{ Name = "FieldIn", Segment = "BumperField", Kind = "BumperField", Length = 30, Pitch = { 3, 3 }, Width = { 22, 28 }, Arrows = true },
		{ Name = "Field", Segment = "BumperField", Length = 130, Pitch = { 3, 3 }, Width = { 28, 28 } },
		{ Name = "FieldOut", Segment = "BumperField", Length = 20, Pitch = { 3, 4 }, Width = { 28, 26 } },
		{ Name = "FieldRunOut", Segment = "BumperField", Length = 90, Yaw = -30, Pitch = { 4, 4 }, Width = { 26, 26 } },
		{ Name = "SweeperZone", Segment = "RotatingSweeper", Kind = "RotatingSweeper", Length = 70, Pitch = { 4, 3 }, Width = { 26, 26 } },
		{ Name = "SplitIn", Segment = "SplitLane", Kind = "SplitLane", Length = 24, Yaw = 10, Pitch = { 3, 3 }, Bank = { 0, 6 }, Width = { 26, 34 } },
		{ Name = "SplitCurve", Segment = "SplitLane", Length = 100, Yaw = 50, Pitch = { 3, 3 }, Bank = { 6, 6 }, Width = { 34, 34 }, Rails = { 7, 5 }, Divider = { From = 4, To = 96, Height = 4.5 } },
		{ Name = "SplitOut", Segment = "SplitLane", Length = 24, Pitch = { 3, 2 }, Bank = { 6, 0 }, Width = { 34, 26 } },
		{ Name = "RestA", Segment = "SafeCheckpointA", Kind = "SafeCheckpoint", Length = 30, Pitch = { 2, 2 }, Width = { 26, 26 }, Arrows = true },
		{ Name = "HairpinIn", Segment = "SafeCheckpointA", Length = 40, Pitch = { 2, 3 }, Width = { 26, 26 } },
		{ Name = "HairpinA", Segment = "SafeCheckpointA", Length = 85, Yaw = -80, Pitch = { 3, 3 }, Bank = { 0, -14 }, Width = { 26, 26 }, Rails = { 4.5, 7 } },
		{ Name = "HairpinB", Segment = "SafeCheckpointA", Length = 85, Yaw = -80, Pitch = { 3, 3 }, Bank = { -14, 0 }, Width = { 26, 26 }, Rails = { 4.5, 7 } },
		{ Name = "HairpinOut", Segment = "SafeCheckpointA", Length = 40, Pitch = { 3, 2 }, Width = { 26, 26 }, Arrows = true },
		{ Name = "FanTunnel", Segment = "FanTunnel", Kind = "FanTunnel", Length = 120, Pitch = { 2, 3 }, Width = { 26, 24 }, Rails = { 6, 6 }, Roof = true },
		{ Name = "DropIn", Segment = "DropShaft", Kind = "DropShaft", Length = 24, Pitch = { 3, 20 }, Width = { 24, 24 }, Rails = { 7, 7 } },
		{ Name = "Shaft", Segment = "DropShaft", Length = 46, Pitch = { 20, 28 }, Width = { 24, 24 }, Rails = { 8, 8 } },
		{ Name = "DropOut", Segment = "DropShaft", Length = 34, Pitch = { 28, 4 }, Width = { 24, 24 }, Rails = { 7, 7 } },
		{ Name = "TrampolineZone", Segment = "TrampolinePad", Kind = "TrampolinePad", Length = 60, Yaw = -20, Pitch = { 4, 2 }, Width = { 24, 24 } },
		{ Name = "LandingRun", Segment = "TrampolinePad", Length = 70, Pitch = { 2, 2 }, Width = { 24, 24 } },
		{ Name = "TilesApproach", Segment = "FallingTiles", Kind = "FallingTiles", Length = 16, Yaw = 0, Pitch = { 2, 0 }, Width = { 24, 24 } },
		{ Name = "Tiles", Segment = "FallingTiles", Length = 48, Pitch = { 0, 0 }, Width = { 24, 24 }, Floor = "Tiles" },
		{ Name = "TilesExit", Segment = "FallingTiles", Length = 16, Pitch = { 0, 3 }, Width = { 24, 24 } },
		{ Name = "HammerZone", Segment = "SwingingHammer", Kind = "SwingingHammer", Length = 80, Pitch = { 3, 3 }, Width = { 24, 24 } },
		{ Name = "HammerRunOut", Segment = "SwingingHammer", Length = 60, Yaw = 25, Pitch = { 3, 3 }, Width = { 24, 24 } },
		{ Name = "ConveyorZone", Segment = "SideConveyor", Kind = "SideConveyor", Length = 90, Yaw = -40, Pitch = { 3, 4 }, Width = { 24, 24 }, Rails = { 6, 6 } },
		{ Name = "ConveyorRunOut", Segment = "SideConveyor", Length = 60, Yaw = -20, Pitch = { 4, 4 }, Width = { 24, 24 } },
		{ Name = "RestB", Segment = "SafeCheckpointB", Kind = "SafeCheckpoint", Length = 30, Yaw = 0, Pitch = { 4, 3 }, Width = { 24, 24 }, Arrows = true },
		{ Name = "LongSweepA", Segment = "SafeCheckpointB", Length = 110, Yaw = 55, Pitch = { 3, 3 }, Bank = { 0, 9 }, Width = { 24, 24 }, Rails = { 6, 4.5 } },
		{ Name = "LongSweepB", Segment = "SafeCheckpointB", Length = 110, Yaw = 55, Pitch = { 3, 3 }, Bank = { 9, 0 }, Width = { 24, 24 }, Rails = { 6, 4.5 } },
		{ Name = "FunnelIn", Segment = "FunnelBowl", Kind = "FunnelBowl", Length = 30, Pitch = { 3, 5 }, Width = { 24, 34 }, Rails = { 6, 6 } },
		{ Name = "FunnelNeck", Segment = "FunnelBowl", Length = 40, Pitch = { 5, 6 }, Width = { 34, 16 }, Rails = { 6, 6 } },
		{ Name = "FunnelOut", Segment = "FunnelBowl", Length = 30, Pitch = { 6, 3 }, Width = { 16, 22 }, Rails = { 6, 6 } },
		{ Name = "FinalCarveA", Segment = "Finish", Kind = "Finish", Length = 75, Yaw = -25, Pitch = { 3, 3 }, Bank = { 0, -8 }, Width = { 22, 22 }, Rails = { 4.5, 6 } },
		{ Name = "FinalCarveB", Segment = "Finish", Length = 75, Yaw = -25, Pitch = { 3, 3 }, Bank = { -8, 0 }, Width = { 22, 22 }, Rails = { 4.5, 6 } },
		{ Name = "RunOut", Segment = "Finish", Length = 60, Pitch = { 3, 2 }, Width = { 22, 22 }, Arrows = true },
		{ Name = "FinishStraight", Segment = "Finish", Length = 40, Pitch = { 2, 1 }, Width = { 22, 26 }, Arrows = true },
		{ Name = "FinishBasin", Segment = "Finish", Length = 40, Pitch = { 1, -3 }, Width = { 26, 30 }, Rails = { 6, 6 }, EndCap = true },
	},
	Spawn = { Piece = "StartPad", At = 14 },
	StartLine = { Piece = "StartPad", At = 36 },
	FinishLine = { Piece = "FinishStraight", At = 40 },
	Checkpoints = {
		{ Name = "S-Turn", Piece = "SCurveA", At = 4 },
		{ Name = "Bumper Field", Piece = "FieldOut", At = 10 },
		{ Name = "Split Exit", Piece = "RestA", At = 10 },
		{ Name = "Hairpin Exit", Piece = "HairpinOut", At = 20 },
		{ Name = "Drop Exit", Piece = "TrampolineZone", At = 4 },
		{ Name = "Before Tiles", Piece = "TilesApproach", At = 4 },
		{ Name = "Rest B", Piece = "RestB", At = 10 },
		{ Name = "Final Carve", Piece = "FinalCarveA", At = 4 },
	},
	Grid = { Piece = "StartPad", Rows = { 26, 20, 14, 8 }, Columns = { -9, -3, 3, 9 } },
	StartGate = { Piece = "StartPad", At = 33, Height = 5 },
	Features = {
		{ Kind = "TrickRamp", Piece = "StraightRamp", At = 120, Offset = -5.5, Width = 9, Length = 7, Height = 3.4 },
	},
	Hazards = {
		{ Kind = "PulseBumper", Id = "BumperA", Piece = "Field", At = 30, Offset = -6, Radius = 3, Height = 4.5 },
		{ Kind = "PulseBumper", Id = "BumperB", Piece = "Field", At = 70, Offset = 6, Radius = 3, Height = 4.5, PhaseOffset = 1.0 },
		{ Kind = "PulseBumper", Id = "BumperC", Piece = "Field", At = 108, Offset = -1, Radius = 3, Height = 4.5, PhaseOffset = 2.1 },
		{ Kind = "PulseBumper", Id = "BumperD", Piece = "SplitCurve", At = 50, Offset = 9, Radius = 2.6, Height = 4.5, PhaseOffset = 0.6 },
		{ Kind = "Sweeper", Id = "Sweeper1", Piece = "SweeperZone", At = 35, Offset = 0, ArmLength = 11, ArmHeight = 2.2, ArmThickness = 1.6, Speed = 1.1, Direction = 1, PostRadius = 1.4 },
		{ Kind = "Fan", Id = "Fan1", Piece = "FanTunnel", From = 12, To = 108, Direction = 1, Accel = 28, OnSeconds = 2.2, OffSeconds = 2.2, TelegraphSeconds = 0.7 },
		{ Kind = "Trampoline", Id = "Trampoline1", Piece = "TrampolineZone", At = 30, Offset = 0, Width = 10, Length = 6, UpDeltaV = 40 },
		{ Kind = "Tiles", Id = "Tiles1", Piece = "Tiles", Rows = 8, Cols = 4, Period = 4.8, TelegraphSeconds = 0.8, DropSeconds = 1.6 },
		{ Kind = "Hammer", Id = "Hammer1", Piece = "HammerZone", At = 40, Amplitude = 8, Period = 3.0, HeadSize = 3.4 },
		{ Kind = "Conveyor", Id = "Conveyor1", Piece = "ConveyorZone", From = 6, To = 84, Direction = 1, Accel = 20 },
	},
	ChaosGates = {
		{ Id = "Gate1", Piece = "SCurveD", At = 50, Offset = 5, Width = 9 },
		{ Id = "Gate2", Piece = "SweeperZone", At = 6, Offset = -6, Width = 9 },
		{ Id = "Gate3", Piece = "TrampolineZone", At = 50, Offset = 6, Width = 9 },
		{ Id = "Gate4", Piece = "FunnelIn", At = 6, Offset = -5, Width = 9 },
	},
	Signs = {
		{ Piece = "StartPad", At = 26, Text = "NEON FOUNDRY", Lift = 11 },
		{ Piece = "StraightRamp", At = 98, Text = "TRICK RAMP - JUMP, PRESS TRICK IN THE AIR", Lift = 10 },
		{ Piece = "FieldIn", At = 4, Text = "BUMPER FIELD - CORAL = KICK", Lift = 10 },
		{ Piece = "SweeperZone", At = 2, Text = "ROTATING SWEEPER", Lift = 10 },
		{ Piece = "SplitIn", At = 2, Text = "SPLIT: OUTSIDE SAFE  |  INSIDE SHORTCUT", Lift = 10 },
		{ Piece = "FanTunnel", At = 2, Text = "FAN TUNNEL - GUSTS PUSH SIDEWAYS", Lift = 10 },
		{ Piece = "DropIn", At = 0, Text = "DROP SHAFT - BRAKE IF FAST", Lift = 10 },
		{ Piece = "TilesApproach", At = 0, Text = "FALLING TILES - AVOID YELLOW", Lift = 10 },
		{ Piece = "HammerZone", At = 4, Text = "SWINGING HAMMER", Lift = 10 },
		{ Piece = "ConveyorZone", At = 2, Text = "SIDE CONVEYOR", Lift = 10 },
		{ Piece = "FunnelIn", At = 0, Text = "FUNNEL", Lift = 10 },
		{ Piece = "FinishStraight", At = 4, Text = "FINISH AHEAD", Lift = 10 },
	},
	Gates = {
		{ Kind = "Start", Piece = "StartPad", At = 36, Text = "START" },
		{ Kind = "Finish", Piece = "FinishStraight", At = 40, Text = "FINISH" },
	},
	Validation = { MinSegments = 12, MaxSegments = 16, MinLength = 1500, MaxLength = 3500 },
	ArrowSpacing = 18,
}

-- The race track used by the round (A4: the Neon Foundry). Training stays as the A1 reference.
TrackDefinitions.Race = TrackDefinitions.NeonFoundry

---------------------------------------------------------------------------------------------
-- B1: two more worlds. Same module contract and the same proven hazard kinds as the Foundry
-- (HazardSim contact model, bots and validator understand them); `Style` only changes how a
-- hazard looks and what the signs call it. `Theme` recolours the course (Builder.ThemePalette).
---------------------------------------------------------------------------------------------
TrackDefinitions.SkyCarnival = {
	Id = "SkyCarnival_B1",
	DisplayName = "Sky Carnival",
	LayoutVersion = 1,
	Origin = Vector3.new(2600, 560, 0),
	StartHeadingDeg = 0,
	FloorThickness = 1.6,
	RailThickness = 1.2,
	DefaultRails = { 4.5, 4.5 },
	MaxStepLength = 24,
	MaxYawStepDeg = 5,
	MaxPitchStepDeg = 2,
	MaxBankStepDeg = 3,
	Theme = {
		NavyFloor = Color3.fromRGB(196, 186, 238),
		Navy = Color3.fromRGB(150, 140, 214),
		NavyRail = Color3.fromRGB(246, 244, 255),
		Violet = Color3.fromRGB(255, 150, 214),
		Cyan = Color3.fromRGB(70, 200, 255),
		Mint = Color3.fromRGB(120, 230, 190),
		FloorMaterial = "SmoothPlastic",
		RailMaterial = "SmoothPlastic",
		Decor = "Clouds",
	},
	Pieces = {
		{ Name = "StartPad", Segment = "StartGrid", Kind = "Start", Length = 36, Pitch = { 0, 0 }, Width = { 30, 30 }, Rails = { 5, 5 }, StartCap = true },
		{ Name = "Launch", Segment = "StartGrid", Length = 14, Pitch = { 0, 5 }, Width = { 30, 22 }, Arrows = true },
		{ Name = "CloudRamp", Segment = "CloudRamp", Kind = "StraightRamp", Length = 200, Pitch = { 5, 4 }, Width = { 22, 22 }, Arrows = true },
		{ Name = "RampEase", Segment = "CloudRamp", Length = 20, Pitch = { 4, 3 }, Width = { 22, 22 } },
		{ Name = "WindIn", Segment = "WindLanes", Kind = "FanTunnel", Length = 20, Pitch = { 3, 2 }, Width = { 22, 26 } },
		{ Name = "WindLane", Segment = "WindLanes", Length = 120, Pitch = { 2, 3 }, Width = { 26, 26 }, Rails = { 6, 6 } },
		{ Name = "WindOut", Segment = "WindLanes", Length = 30, Yaw = 20, Pitch = { 3, 3 }, Width = { 26, 22 } },
		{ Name = "FieldIn", Segment = "BalloonField", Kind = "BumperField", Length = 30, Pitch = { 3, 3 }, Width = { 22, 28 }, Arrows = true },
		{ Name = "Field", Segment = "BalloonField", Length = 120, Pitch = { 3, 3 }, Width = { 28, 28 } },
		{ Name = "FieldOut", Segment = "BalloonField", Length = 20, Pitch = { 3, 4 }, Width = { 28, 26 } },
		{ Name = "RingApproach", Segment = "RingCarousel", Kind = "RotatingSweeper", Length = 40, Yaw = -30, Pitch = { 4, 3 }, Width = { 26, 26 } },
		{ Name = "RingZone", Segment = "RingCarousel", Length = 70, Pitch = { 3, 3 }, Width = { 26, 26 } },
		{ Name = "RingOut", Segment = "RingCarousel", Length = 60, Yaw = -30, Pitch = { 3, 3 }, Width = { 26, 22 } },
		{ Name = "RibbonA", Segment = "Ribbon", Kind = "STurn", Length = 80, Yaw = 40, Pitch = { 3, 3 }, Bank = { 0, 10 }, Width = { 22, 22 }, Rails = { 6, 4.5 } },
		{ Name = "RibbonB", Segment = "Ribbon", Length = 80, Yaw = 40, Pitch = { 3, 3 }, Bank = { 10, 0 }, Width = { 22, 22 }, Rails = { 6, 4.5 } },
		{ Name = "RibbonC", Segment = "Ribbon", Length = 70, Yaw = -40, Pitch = { 3, 3 }, Bank = { 0, -10 }, Width = { 22, 22 }, Rails = { 4.5, 6 } },
		{ Name = "RibbonD", Segment = "Ribbon", Length = 70, Yaw = -40, Pitch = { 3, 3 }, Bank = { -10, 0 }, Width = { 22, 24 }, Rails = { 4.5, 6 } },
		{ Name = "DrumZone", Segment = "DrumBounce", Kind = "TrampolinePad", Length = 60, Pitch = { 3, 2 }, Width = { 24, 24 } },
		{ Name = "LandingRun", Segment = "DrumBounce", Length = 70, Pitch = { 2, 3 }, Width = { 24, 26 } },
		{ Name = "SplitIn", Segment = "CloudSplit", Kind = "SplitLane", Length = 24, Yaw = -10, Pitch = { 3, 3 }, Bank = { 0, -6 }, Width = { 26, 34 } },
		{ Name = "SplitCurve", Segment = "CloudSplit", Length = 100, Yaw = -50, Pitch = { 3, 3 }, Bank = { -6, -6 }, Width = { 34, 34 }, Rails = { 5, 7 }, Divider = { From = 4, To = 96, Height = 4.5 } },
		{ Name = "SplitOut", Segment = "CloudSplit", Length = 24, Pitch = { 3, 2 }, Bank = { -6, 0 }, Width = { 34, 26 } },
		{ Name = "RestA", Segment = "CloudRest", Kind = "SafeCheckpoint", Length = 30, Pitch = { 2, 2 }, Width = { 26, 26 }, Arrows = true },
		{ Name = "HairpinIn", Segment = "CloudRest", Length = 40, Pitch = { 2, 3 }, Width = { 26, 26 } },
		{ Name = "HairpinA", Segment = "CloudRest", Length = 85, Yaw = 80, Pitch = { 3, 3 }, Bank = { 0, 14 }, Width = { 26, 26 }, Rails = { 7, 4.5 } },
		{ Name = "HairpinB", Segment = "CloudRest", Length = 85, Yaw = 80, Pitch = { 3, 3 }, Bank = { 14, 0 }, Width = { 26, 26 }, Rails = { 7, 4.5 } },
		{ Name = "HairpinOut", Segment = "CloudRest", Length = 40, Pitch = { 3, 3 }, Width = { 26, 24 }, Arrows = true },
		{ Name = "FlipperZone", Segment = "Flippers", Kind = "SwingingHammer", Length = 80, Pitch = { 3, 3 }, Width = { 24, 24 } },
		{ Name = "FlipperRunOut", Segment = "Flippers", Length = 60, Yaw = -25, Pitch = { 3, 3 }, Width = { 24, 24 } },
		{ Name = "DropIn", Segment = "SkyDrop", Kind = "DropShaft", Length = 24, Pitch = { 3, 20 }, Width = { 24, 24 }, Rails = { 8, 8 } },
		{ Name = "Shaft", Segment = "SkyDrop", Length = 46, Pitch = { 20, 28 }, Width = { 24, 24 }, Rails = { 9, 9 } },
		{ Name = "DropOut", Segment = "SkyDrop", Length = 34, Pitch = { 28, 3 }, Width = { 24, 24 }, Rails = { 8, 8 } },
		{ Name = "FunnelIn", Segment = "PinballFunnel", Kind = "FunnelBowl", Length = 30, Pitch = { 3, 5 }, Width = { 24, 34 }, Rails = { 6, 6 } },
		{ Name = "FunnelNeck", Segment = "PinballFunnel", Length = 40, Pitch = { 5, 6 }, Width = { 34, 16 }, Rails = { 6, 6 } },
		{ Name = "FunnelOut", Segment = "PinballFunnel", Length = 30, Pitch = { 6, 3 }, Width = { 16, 24 }, Rails = { 6, 6 } },
		{ Name = "RestB", Segment = "RainbowSweep", Kind = "SafeCheckpoint", Length = 30, Pitch = { 3, 3 }, Width = { 24, 24 }, Arrows = true },
		{ Name = "LongSweepA", Segment = "RainbowSweep", Length = 110, Yaw = -55, Pitch = { 3, 3 }, Bank = { 0, -9 }, Width = { 24, 24 }, Rails = { 4.5, 6 } },
		{ Name = "LongSweepB", Segment = "RainbowSweep", Length = 110, Yaw = -55, Pitch = { 3, 3 }, Bank = { -9, 0 }, Width = { 24, 22 }, Rails = { 4.5, 6 } },
		{ Name = "FinalCarveA", Segment = "Finish", Kind = "Finish", Length = 75, Yaw = 25, Pitch = { 3, 3 }, Bank = { 0, 8 }, Width = { 22, 22 }, Rails = { 6, 4.5 } },
		{ Name = "FinalCarveB", Segment = "Finish", Length = 75, Yaw = 25, Pitch = { 3, 3 }, Bank = { 8, 0 }, Width = { 22, 22 }, Rails = { 6, 4.5 } },
		{ Name = "RunOut", Segment = "Finish", Length = 60, Pitch = { 3, 2 }, Width = { 22, 22 }, Arrows = true },
		{ Name = "FinishStraight", Segment = "Finish", Length = 40, Pitch = { 2, 1 }, Width = { 22, 26 }, Arrows = true },
		{ Name = "FinishBasin", Segment = "Finish", Length = 40, Pitch = { 1, -3 }, Width = { 26, 30 }, Rails = { 6, 6 }, EndCap = true },
	},
	Spawn = { Piece = "StartPad", At = 14 },
	StartLine = { Piece = "StartPad", At = 36 },
	FinishLine = { Piece = "FinishStraight", At = 40 },
	Checkpoints = {
		{ Name = "Wind Lanes", Piece = "WindOut", At = 10 },
		{ Name = "Balloon Field", Piece = "FieldOut", At = 10 },
		{ Name = "Ring Carousel", Piece = "RingOut", At = 30 },
		{ Name = "Ribbon", Piece = "DrumZone", At = 4 },
		{ Name = "Cloud Split", Piece = "RestA", At = 10 },
		{ Name = "Hairpin", Piece = "HairpinOut", At = 20 },
		{ Name = "Sky Drop", Piece = "FunnelIn", At = 4 },
		{ Name = "Rainbow Sweep", Piece = "RestB", At = 10 },
	},
	Grid = { Piece = "StartPad", Rows = { 26, 20, 14, 8 }, Columns = { -9, -3, 3, 9 } },
	StartGate = { Piece = "StartPad", At = 33, Height = 5 },
	Features = {
		{ Kind = "TrickRamp", Piece = "CloudRamp", At = 110, Offset = 5.5, Width = 9, Length = 7, Height = 3.4 },
	},
	Hazards = {
		{ Kind = "PulseBumper", Id = "BalloonA", Style = "Balloon", Piece = "Field", At = 25, Offset = 6, Radius = 3, Height = 4.5 },
		{ Kind = "PulseBumper", Id = "BalloonB", Style = "Balloon", Piece = "Field", At = 60, Offset = -7, Radius = 3, Height = 4.5, PhaseOffset = 1.2 },
		{ Kind = "PulseBumper", Id = "BalloonC", Style = "Balloon", Piece = "Field", At = 95, Offset = 2, Radius = 3, Height = 4.5, PhaseOffset = 2.3 },
		{ Kind = "PulseBumper", Id = "BalloonD", Style = "Balloon", Piece = "SplitCurve", At = 50, Offset = -9, Radius = 2.6, Height = 4.5, PhaseOffset = 0.7 },
		{ Kind = "Sweeper", Id = "Ring1", Style = "Ring", Piece = "RingZone", At = 35, Offset = 0, ArmLength = 11, ArmHeight = 2.2, ArmThickness = 1.6, Speed = 1.0, Direction = -1, PostRadius = 1.4 },
		{ Kind = "Fan", Id = "Wind1", Style = "Wind", Piece = "WindLane", From = 8, To = 112, Direction = -1, Accel = 26, OnSeconds = 2.4, OffSeconds = 2.0, TelegraphSeconds = 0.7 },
		{ Kind = "Trampoline", Id = "Drum1", Style = "Drum", Piece = "DrumZone", At = 30, Offset = 0, Width = 10, Length = 6, UpDeltaV = 40 },
		{ Kind = "Hammer", Id = "Flipper1", Style = "Flipper", Piece = "FlipperZone", At = 40, Amplitude = 8, Period = 2.8, HeadSize = 3.4 },
	},
	ChaosGates = {
		{ Id = "Gate1", Piece = "RibbonB", At = 40, Offset = -5, Width = 9 },
		{ Id = "Gate2", Piece = "RingApproach", At = 10, Offset = 6, Width = 9 },
		{ Id = "Gate3", Piece = "LandingRun", At = 40, Offset = -6, Width = 9 },
		{ Id = "Gate4", Piece = "FunnelIn", At = 6, Offset = 5, Width = 9 },
	},
	Signs = {
		{ Piece = "StartPad", At = 26, Text = "SKY CARNIVAL", Lift = 11 },
		{ Piece = "CloudRamp", At = 88, Text = "TRICK RAMP - JUMP, PRESS TRICK IN THE AIR", Lift = 10 },
		{ Piece = "WindIn", At = 2, Text = "WIND LANES - GUSTS PUSH SIDEWAYS", Lift = 10 },
		{ Piece = "FieldIn", At = 4, Text = "BALLOON BUMPERS - CORAL = KICK", Lift = 10 },
		{ Piece = "RingApproach", At = 30, Text = "RING CAROUSEL", Lift = 10 },
		{ Piece = "DrumZone", At = 2, Text = "BOUNCY DRUM", Lift = 10 },
		{ Piece = "SplitIn", At = 2, Text = "SPLIT: OUTSIDE SAFE  |  INSIDE SHORTCUT", Lift = 10 },
		{ Piece = "FlipperZone", At = 4, Text = "PINBALL FLIPPER", Lift = 10 },
		{ Piece = "DropIn", At = 0, Text = "SKY DROP - BRAKE IF FAST", Lift = 10 },
		{ Piece = "FunnelIn", At = 0, Text = "PINBALL FUNNEL", Lift = 10 },
		{ Piece = "FinishStraight", At = 4, Text = "FINISH AHEAD", Lift = 10 },
	},
	Gates = {
		{ Kind = "Start", Piece = "StartPad", At = 36, Text = "START" },
		{ Kind = "Finish", Piece = "FinishStraight", At = 40, Text = "FINISH" },
	},
	Validation = { MinSegments = 12, MaxSegments = 16, MinLength = 1500, MaxLength = 3500 },
	ArrowSpacing = 18,
}

TrackDefinitions.VolcanoVault = {
	Id = "VolcanoVault_B1",
	DisplayName = "Volcano Vault",
	LayoutVersion = 1,
	Origin = Vector3.new(-2600, 440, 0),
	StartHeadingDeg = 0,
	FloorThickness = 1.6,
	RailThickness = 1.2,
	DefaultRails = { 4.5, 4.5 },
	MaxStepLength = 24,
	MaxYawStepDeg = 5,
	MaxPitchStepDeg = 2,
	MaxBankStepDeg = 3,
	Theme = {
		NavyFloor = Color3.fromRGB(44, 36, 40),
		Navy = Color3.fromRGB(30, 22, 26),
		NavyRail = Color3.fromRGB(70, 58, 60),
		Violet = Color3.fromRGB(196, 60, 40),
		Cyan = Color3.fromRGB(255, 140, 40),
		Mint = Color3.fromRGB(255, 200, 80),
		FloorMaterial = "Basalt",
		RailMaterial = "Slate",
		Decor = "Lava",
	},
	Pieces = {
		{ Name = "StartPad", Segment = "StartGrid", Kind = "Start", Length = 36, Pitch = { 0, 0 }, Width = { 30, 30 }, Rails = { 5, 5 }, StartCap = true },
		{ Name = "Launch", Segment = "StartGrid", Length = 14, Pitch = { 0, 5 }, Width = { 30, 22 }, Arrows = true },
		{ Name = "ObsidianRamp", Segment = "ObsidianRamp", Kind = "StraightRamp", Length = 200, Pitch = { 5, 4 }, Width = { 22, 22 }, Arrows = true },
		{ Name = "RampEase", Segment = "ObsidianRamp", Length = 20, Pitch = { 4, 3 }, Width = { 22, 22 } },
		{ Name = "GeyserIn", Segment = "GeyserField", Kind = "FanTunnel", Length = 20, Pitch = { 3, 2 }, Width = { 22, 26 } },
		{ Name = "Geysers", Segment = "GeyserField", Length = 110, Pitch = { 2, 3 }, Width = { 26, 26 }, Rails = { 6, 6 } },
		{ Name = "GeyserOut", Segment = "GeyserField", Length = 20, Pitch = { 3, 3 }, Width = { 26, 24 } },
		{ Name = "SpiralA", Segment = "StoneSpiral", Kind = "STurn", Length = 85, Yaw = 70, Pitch = { 3, 5 }, Bank = { 0, 12 }, Width = { 24, 24 }, Rails = { 7, 4.5 } },
		{ Name = "SpiralB", Segment = "StoneSpiral", Length = 85, Yaw = 70, Pitch = { 5, 5 }, Bank = { 12, 12 }, Width = { 24, 24 }, Rails = { 7, 4.5 } },
		{ Name = "SpiralC", Segment = "StoneSpiral", Length = 85, Yaw = 70, Pitch = { 5, 5 }, Bank = { 12, 12 }, Width = { 24, 24 }, Rails = { 7, 4.5 } },
		{ Name = "SpiralD", Segment = "StoneSpiral", Length = 85, Yaw = 70, Pitch = { 5, 3 }, Bank = { 12, 0 }, Width = { 24, 24 }, Rails = { 7, 4.5 } },
		{ Name = "PistonZone", Segment = "PistonHall", Kind = "SwingingHammer", Length = 80, Pitch = { 3, 3 }, Width = { 24, 24 } },
		{ Name = "PistonRunOut", Segment = "PistonHall", Length = 60, Yaw = -20, Pitch = { 3, 3 }, Width = { 24, 22 } },
		{ Name = "RockIn", Segment = "Rockfall", Kind = "BumperField", Length = 30, Pitch = { 3, 3 }, Width = { 22, 28 }, Arrows = true },
		{ Name = "RockRun", Segment = "Rockfall", Length = 130, Pitch = { 3, 3 }, Width = { 28, 28 } },
		{ Name = "RockOut", Segment = "Rockfall", Length = 20, Pitch = { 3, 2 }, Width = { 28, 26 } },
		{ Name = "RestA", Segment = "CoolingVent", Kind = "SafeCheckpoint", Length = 30, Yaw = -30, Pitch = { 2, 2 }, Width = { 26, 26 }, Arrows = true },
		{ Name = "VentRun", Segment = "CoolingVent", Length = 60, Yaw = -30, Pitch = { 2, 3 }, Width = { 26, 24 } },
		{ Name = "TilesApproach", Segment = "CrumblingBasalt", Kind = "FallingTiles", Length = 16, Yaw = 0, Pitch = { 3, 0 }, Width = { 24, 24 } },
		{ Name = "Tiles", Segment = "CrumblingBasalt", Length = 48, Pitch = { 0, 0 }, Width = { 24, 24 }, Floor = "Tiles" },
		{ Name = "TilesExit", Segment = "CrumblingBasalt", Length = 16, Pitch = { 0, 3 }, Width = { 24, 24 } },
		{ Name = "ConveyorZone", Segment = "MagmaConveyor", Kind = "SideConveyor", Length = 90, Yaw = -40, Pitch = { 3, 4 }, Width = { 24, 24 }, Rails = { 6, 6 } },
		{ Name = "ConveyorRunOut", Segment = "MagmaConveyor", Length = 60, Yaw = -20, Pitch = { 4, 3 }, Width = { 24, 26 } },
		{ Name = "SplitIn", Segment = "LavaSplit", Kind = "SplitLane", Length = 24, Yaw = 10, Pitch = { 3, 3 }, Bank = { 0, 6 }, Width = { 26, 34 } },
		{ Name = "SplitCurve", Segment = "LavaSplit", Length = 100, Yaw = 50, Pitch = { 3, 3 }, Bank = { 6, 6 }, Width = { 34, 34 }, Rails = { 7, 5 }, Divider = { From = 4, To = 96, Height = 4.5 } },
		{ Name = "SplitOut", Segment = "LavaSplit", Length = 24, Pitch = { 3, 3 }, Bank = { 6, 0 }, Width = { 34, 24 } },
		{ Name = "DropIn", Segment = "LavaDrop", Kind = "DropShaft", Length = 24, Pitch = { 3, 20 }, Width = { 24, 24 }, Rails = { 8, 8 } },
		{ Name = "Shaft", Segment = "LavaDrop", Length = 46, Pitch = { 20, 28 }, Width = { 24, 24 }, Rails = { 9, 9 } },
		{ Name = "DropOut", Segment = "LavaDrop", Length = 34, Pitch = { 28, 4 }, Width = { 24, 24 }, Rails = { 8, 8 } },
		{ Name = "RestB", Segment = "ObsidianSweep", Kind = "SafeCheckpoint", Length = 30, Pitch = { 4, 3 }, Width = { 24, 24 }, Arrows = true },
		{ Name = "LongSweepA", Segment = "ObsidianSweep", Length = 110, Yaw = 55, Pitch = { 3, 3 }, Bank = { 0, 9 }, Width = { 24, 24 }, Rails = { 6, 4.5 } },
		{ Name = "LongSweepB", Segment = "ObsidianSweep", Length = 110, Yaw = 55, Pitch = { 3, 3 }, Bank = { 9, 0 }, Width = { 24, 24 }, Rails = { 6, 4.5 } },
		{ Name = "FunnelIn", Segment = "MagmaFunnel", Kind = "FunnelBowl", Length = 30, Pitch = { 3, 5 }, Width = { 24, 34 }, Rails = { 6, 6 } },
		{ Name = "FunnelNeck", Segment = "MagmaFunnel", Length = 40, Pitch = { 5, 6 }, Width = { 34, 16 }, Rails = { 6, 6 } },
		{ Name = "FunnelOut", Segment = "MagmaFunnel", Length = 30, Pitch = { 6, 3 }, Width = { 16, 22 }, Rails = { 6, 6 } },
		{ Name = "FinalCarveA", Segment = "Finish", Kind = "Finish", Length = 75, Yaw = -25, Pitch = { 3, 3 }, Bank = { 0, -8 }, Width = { 22, 22 }, Rails = { 4.5, 6 } },
		{ Name = "FinalCarveB", Segment = "Finish", Length = 75, Yaw = -25, Pitch = { 3, 3 }, Bank = { -8, 0 }, Width = { 22, 22 }, Rails = { 4.5, 6 } },
		{ Name = "RunOut", Segment = "Finish", Length = 60, Pitch = { 3, 2 }, Width = { 22, 22 }, Arrows = true },
		{ Name = "FinishStraight", Segment = "Finish", Length = 40, Pitch = { 2, 1 }, Width = { 22, 26 }, Arrows = true },
		{ Name = "FinishBasin", Segment = "Finish", Length = 40, Pitch = { 1, -3 }, Width = { 26, 30 }, Rails = { 6, 6 }, EndCap = true },
	},
	Spawn = { Piece = "StartPad", At = 14 },
	StartLine = { Piece = "StartPad", At = 36 },
	FinishLine = { Piece = "FinishStraight", At = 40 },
	Checkpoints = {
		{ Name = "Geyser Field", Piece = "GeyserOut", At = 10 },
		{ Name = "Stone Spiral", Piece = "PistonZone", At = 4 },
		{ Name = "Piston Hall", Piece = "PistonRunOut", At = 40 },
		{ Name = "Rockfall", Piece = "RestA", At = 10 },
		{ Name = "Crumbling Basalt", Piece = "TilesExit", At = 10 },
		{ Name = "Lava Split", Piece = "SplitOut", At = 16 },
		{ Name = "Lava Drop", Piece = "RestB", At = 10 },
		{ Name = "Final Carve", Piece = "FinalCarveA", At = 4 },
	},
	Grid = { Piece = "StartPad", Rows = { 26, 20, 14, 8 }, Columns = { -9, -3, 3, 9 } },
	StartGate = { Piece = "StartPad", At = 33, Height = 5 },
	Features = {
		{ Kind = "TrickRamp", Piece = "ObsidianRamp", At = 110, Offset = -5.5, Width = 9, Length = 7, Height = 3.4 },
	},
	Hazards = {
		{ Kind = "Fan", Id = "Geyser1", Style = "Geyser", Piece = "Geysers", From = 10, To = 100, Direction = 1, Accel = 30, OnSeconds = 1.6, OffSeconds = 2.2, TelegraphSeconds = 0.8 },
		{ Kind = "Hammer", Id = "Piston1", Style = "Piston", Piece = "PistonZone", At = 40, Amplitude = 8, Period = 3.2, HeadSize = 3.4 },
		{ Kind = "PulseBumper", Id = "RockA", Style = "Rock", Piece = "RockRun", At = 30, Offset = -6, Radius = 3, Height = 4.5 },
		{ Kind = "PulseBumper", Id = "RockB", Style = "Rock", Piece = "RockRun", At = 68, Offset = 6, Radius = 3, Height = 4.5, PhaseOffset = 1.1 },
		{ Kind = "PulseBumper", Id = "RockC", Style = "Rock", Piece = "RockRun", At = 104, Offset = 0, Radius = 3, Height = 4.5, PhaseOffset = 2.2 },
		{ Kind = "PulseBumper", Id = "RockD", Style = "Rock", Piece = "SplitCurve", At = 50, Offset = 9, Radius = 2.6, Height = 4.5, PhaseOffset = 0.5 },
		{ Kind = "Tiles", Id = "Basalt1", Style = "Basalt", Piece = "Tiles", Rows = 8, Cols = 4, Period = 4.8, TelegraphSeconds = 0.8, DropSeconds = 1.6 },
		{ Kind = "Conveyor", Id = "Magma1", Style = "Magma", Piece = "ConveyorZone", From = 6, To = 84, Direction = -1, Accel = 20 },
	},
	ChaosGates = {
		{ Id = "Gate1", Piece = "SpiralB", At = 40, Offset = -5, Width = 9 },
		{ Id = "Gate2", Piece = "RockIn", At = 10, Offset = 6, Width = 9 },
		{ Id = "Gate3", Piece = "VentRun", At = 30, Offset = -6, Width = 9 },
		{ Id = "Gate4", Piece = "FunnelIn", At = 6, Offset = -5, Width = 9 },
	},
	Signs = {
		{ Piece = "StartPad", At = 26, Text = "VOLCANO VAULT", Lift = 11 },
		{ Piece = "ObsidianRamp", At = 88, Text = "TRICK RAMP - JUMP, PRESS TRICK IN THE AIR", Lift = 10 },
		{ Piece = "GeyserIn", At = 2, Text = "GEYSER VENTS - BURSTS PUSH SIDEWAYS", Lift = 10 },
		{ Piece = "SpiralA", At = 4, Text = "STONE SPIRAL", Lift = 10 },
		{ Piece = "PistonZone", At = 4, Text = "PISTON HALL", Lift = 10 },
		{ Piece = "RockIn", At = 4, Text = "ROCKFALL - WATCH THE SHADOWS", Lift = 10 },
		{ Piece = "TilesApproach", At = 0, Text = "CRUMBLING BASALT - AVOID GLOWING CRACKS", Lift = 10 },
		{ Piece = "ConveyorZone", At = 2, Text = "MAGMA CONVEYOR", Lift = 10 },
		{ Piece = "SplitIn", At = 2, Text = "SPLIT: OUTSIDE SAFE  |  INSIDE SHORTCUT", Lift = 10 },
		{ Piece = "DropIn", At = 0, Text = "LAVA DROP - BRAKE IF FAST", Lift = 10 },
		{ Piece = "FunnelIn", At = 0, Text = "MAGMA FUNNEL", Lift = 10 },
		{ Piece = "FinishStraight", At = 4, Text = "FINISH AHEAD", Lift = 10 },
	},
	Gates = {
		{ Kind = "Start", Piece = "StartPad", At = 36, Text = "START" },
		{ Kind = "Finish", Piece = "FinishStraight", At = 40, Text = "FINISH" },
	},
	Validation = { MinSegments = 12, MaxSegments = 16, MinLength = 1500, MaxLength = 3500 },
	ArrowSpacing = 18,
}

-- B1: every race world, in rotation order. Ids are stable (best times are keyed by them).
TrackDefinitions.Worlds = { TrackDefinitions.NeonFoundry, TrackDefinitions.SkyCarnival, TrackDefinitions.VolcanoVault }
TrackDefinitions.WorldsById = {}
for index, def in ipairs(TrackDefinitions.Worlds) do
	TrackDefinitions.WorldsById[def.Id] = def
	def.WorldIndex = index
end
function TrackDefinitions.World(id)
	return TrackDefinitions.WorldsById[id] or TrackDefinitions.NeonFoundry
end

---------------------------------------------------------------------------------------------
-- A2: Practice Chute — the short free-roll lane off the Orbital Garage hub. Late joiners and
-- waiting players roll here; reaching its basin returns them to the hub automatically.
---------------------------------------------------------------------------------------------
TrackDefinitions.Hub = {
	Center = Vector3.new(0, 300, 320), -- platform top surface centre
	Radius = 40,
	FloorThickness = 2,
	RimHeight = 5,
	SpawnRingRadius = 16, -- 16 spots: chord 6.2 studs (>= 1.5 marble widths)
	SpawnSlots = 16,
	ChuteHeadingDeg = 90, -- chute leaves the platform toward +X
}

TrackDefinitions.PracticeChute = {
	Id = "PracticeChute_A2",
	DisplayName = "Practice Chute",
	LayoutVersion = 1,
	Origin = Vector3.new(38, 300, 320), -- 2 studs inside the hub edge so the floors overlap flush
	StartHeadingDeg = 90,
	FloorThickness = 1.6,
	RailThickness = 1.2,
	DefaultRails = { 4.5, 4.5 },
	MaxStepLength = 24,
	MaxYawStepDeg = 5,
	MaxPitchStepDeg = 2,
	MaxBankStepDeg = 3,
	Pieces = {
		{ Name = "ChuteLip", Segment = "Lip", Length = 8, Pitch = { 0, 0 }, Width = { 18, 18 } },
		{ Name = "ChuteDrop", Segment = "Drop", Length = 50, Pitch = { 0, 6 }, Width = { 18, 18 }, Arrows = true },
		{ Name = "ChuteBendL", Segment = "Bends", Length = 45, Yaw = -35, Pitch = { 6, 4 }, Width = { 18, 18 }, Rails = { 4.5, 6 } },
		{ Name = "ChuteBendR", Segment = "Bends", Length = 45, Yaw = 35, Pitch = { 4, 3 }, Width = { 18, 18 }, Rails = { 6, 4.5 } },
		{ Name = "ChuteBasin", Segment = "Basin", Length = 26, Pitch = { 3, -3 }, Width = { 18, 22 }, Rails = { 6, 6 }, EndCap = true },
	},
	Spawn = { Piece = "ChuteLip", At = 2 },
	StartLine = { Piece = "ChuteLip", At = 8 },
	FinishLine = { Piece = "ChuteBasin", At = 10 }, -- crossing it returns the marble to the hub
	Signs = {
		{ Piece = "ChuteLip", At = 4, Text = "PRACTICE CHUTE", Lift = 9 },
	},
	Validation = { MinSegments = 3, MaxSegments = 6, MinLength = 100, MaxLength = 400 },
	ArrowSpacing = 14,
}

---------------------------------------------------------------------------------------------
-- Frame math
---------------------------------------------------------------------------------------------

-- Orthonormal frame for heading psi, pitch theta (+ = descending) and bank phi (+ = right lower).
-- Returns forward, right, up (surface normal), horizontal heading.
function TrackDefinitions.FrameVectors(psi, theta, phi)
	local Y = Vector3.new(0, 1, 0)
	local dirH = Vector3.new(math.sin(psi), 0, -math.cos(psi))
	local r0 = Vector3.new(math.cos(psi), 0, math.sin(psi))
	local f = dirH * math.cos(theta) - Y * math.sin(theta)
	local n0 = Y * math.cos(theta) + dirH * math.sin(theta)
	local r = r0 * math.cos(phi) - n0 * math.sin(phi)
	local n = n0 * math.cos(phi) + r0 * math.sin(phi)
	return f, r, n, dirH
end

local function pieceValue(piece, key, default)
	local v = piece[key]
	if v == nil then
		return default
	end
	return v
end

---------------------------------------------------------------------------------------------
-- Generate(def, ballRadius) -> layout
---------------------------------------------------------------------------------------------
function TrackDefinitions.Generate(def, ballRadius)
	ballRadius = ballRadius or 2
	local sections = {}
	local pieces = {}
	local pieceByName = {}

	local pos = def.Origin
	local heading = rad(def.StartHeadingDeg or 0)
	local h = 0
	local Y = Vector3.new(0, 1, 0)

	local function pushSection(pieceIndex, psi, pitchDeg, bankDeg, width, rails)
		local f, r, n, dirH = TrackDefinitions.FrameVectors(psi, rad(pitchDeg), rad(bankDeg))
		sections[#sections + 1] = {
			H = h,
			Position = pos,
			Forward = f,
			Right = r,
			Up = n,
			HeadingDir = dirH,
			HeadingRad = psi,
			PitchDeg = pitchDeg,
			BankDeg = bankDeg,
			Width = width,
			RailLeft = rails[1],
			RailRight = rails[2],
			PieceIndex = pieceIndex,
		}
	end

	local first = def.Pieces[1]
	pushSection(
		1,
		heading,
		pieceValue(first, "Pitch", { 0, 0 })[1],
		pieceValue(first, "Bank", { 0, 0 })[1],
		pieceValue(first, "Width", { 22, 22 })[1],
		pieceValue(first, "Rails", def.DefaultRails)
	)

	for pi, piece in ipairs(def.Pieces) do
		local length = piece.Length
		local yawDeg = pieceValue(piece, "Yaw", 0)
		local pitch = pieceValue(piece, "Pitch", { 0, 0 })
		local bank = pieceValue(piece, "Bank", { 0, 0 })
		local width = pieceValue(piece, "Width", { 22, 22 })
		local rails = pieceValue(piece, "Rails", def.DefaultRails)

		local steps = math.max(
			1,
			math.ceil(length / def.MaxStepLength - 1e-9),
			math.ceil(math.abs(yawDeg) / def.MaxYawStepDeg - 1e-9),
			math.ceil(math.abs(pitch[2] - pitch[1]) / def.MaxPitchStepDeg - 1e-9),
			math.ceil(math.abs(bank[2] - bank[1]) / def.MaxBankStepDeg - 1e-9)
		)
		local dL = length / steps
		local psi0 = heading
		local yaw = rad(yawDeg)
		local startH = h
		local firstSection = #sections

		for k = 1, steps do
			local tm = (k - 0.5) / steps
			local t1 = k / steps
			-- midpoint integration of the centreline
			local psiM = psi0 + yaw * tm
			local thetaM = rad(lerp(pitch[1], pitch[2], tm))
			local dirM = Vector3.new(math.sin(psiM), 0, -math.cos(psiM))
			pos = pos + dirM * dL - Y * (dL * math.tan(thetaM))
			h = h + dL
			pushSection(pi, psi0 + yaw * t1, lerp(pitch[1], pitch[2], t1), lerp(bank[1], bank[2], t1), lerp(width[1], width[2], t1), rails)
		end
		heading = psi0 + yaw

		local record = {
			Index = pi,
			Name = piece.Name,
			Segment = piece.Segment,
			FirstSection = firstSection,
			LastSection = #sections,
			StartH = startH,
			EndH = h,
			Definition = piece,
		}
		pieces[pi] = record
		pieceByName[piece.Name] = record
	end

	-- Route along the ball centre (floor + normal * radius); section i <-> route point i.
	local routePoints = {}
	for i, sec in ipairs(sections) do
		routePoints[i] = sec.Position + sec.Up * ballRadius
	end
	local cumulative = { 0 }
	for i = 2, #routePoints do
		cumulative[i] = cumulative[i - 1] + (routePoints[i] - routePoints[i - 1]).Magnitude
	end
	for i, sec in ipairs(sections) do
		sec.S = cumulative[i]
	end

	local layout = {
		Definition = def,
		BallRadius = ballRadius,
		Sections = sections,
		Pieces = pieces,
		PieceByName = pieceByName,
		Route = { points = routePoints, cumulative = cumulative, total = cumulative[#cumulative] },
		TotalH = h,
	}

	local minY, maxY = math.huge, -math.huge
	for _, sec in ipairs(sections) do
		minY = math.min(minY, sec.Position.Y)
		maxY = math.max(maxY, sec.Position.Y)
	end
	layout.MinY, layout.MaxY = minY, maxY

	-- Resolve features (piece-relative horizontal distance -> absolute H, S and frame).
	local function resolve(feature)
		local rec = pieceByName[feature.Piece]
		if not rec then
			return nil
		end
		local at = feature.At or 0
		return TrackDefinitions.SampleAtH(layout, rec.StartH + at)
	end
	layout.Resolve = resolve

	layout.SpawnFrame = resolve(def.Spawn)
	layout.StartLineFrame = resolve(def.StartLine)
	layout.FinishLineFrame = resolve(def.FinishLine)
	layout.StartLineS = layout.StartLineFrame and layout.StartLineFrame.S
	layout.FinishLineS = layout.FinishLineFrame and layout.FinishLineFrame.S

	layout.Checkpoints = {}
	for i, cp in ipairs(def.Checkpoints or {}) do
		local frame = resolve(cp)
		local respawn = frame and TrackDefinitions.SampleAtH(layout, frame.H + 6)
		layout.Checkpoints[i] = { Index = i, Name = cp.Name, S = frame and frame.S, Frame = frame, RespawnFrame = respawn }
	end

	layout.GridSlots = {}
	if def.Grid then
		local rec = pieceByName[def.Grid.Piece]
		if rec then
			for _, row in ipairs(def.Grid.Rows) do
				local frame = TrackDefinitions.SampleAtH(layout, rec.StartH + row)
				for _, offset in ipairs(def.Grid.Columns) do
					layout.GridSlots[#layout.GridSlots + 1] = { Frame = frame, Offset = offset }
				end
			end
		end
	end
	layout.StartGateFrame = def.StartGate and resolve(def.StartGate)

	layout.TrickZones = {}
	for _, feature in ipairs(def.Features or {}) do
		if feature.Kind == "TrickRamp" then
			local lip = resolve(feature)
			local rec = pieceByName[feature.Piece]
			local mid = rec and TrackDefinitions.SampleAtH(layout, rec.StartH + feature.At - feature.Length / 2)
			if lip and mid then
				layout.TrickZones[#layout.TrickZones + 1] = {
					LipS = lip.S,
					LipFrame = lip,
					MidFrame = mid,
					Offset = feature.Offset,
					Width = feature.Width,
					Length = feature.Length,
					Height = feature.Height,
					LateralMin = feature.Offset - feature.Width / 2,
					LateralMax = feature.Offset + feature.Width / 2,
				}
			end
		end
	end

	layout.Hazards = {}
	for i, hz in ipairs(def.Hazards or {}) do
		local entry = { Kind = hz.Kind, Id = hz.Id or (hz.Kind .. i), Definition = hz, Frame = resolve(hz), Offset = hz.Offset or 0, Radius = hz.Radius, Height = hz.Height }
		local rec = pieceByName[hz.Piece]
		if rec and hz.From and hz.To then
			entry.FromFrame = TrackDefinitions.SampleAtH(layout, rec.StartH + hz.From)
			entry.ToFrame = TrackDefinitions.SampleAtH(layout, rec.StartH + hz.To)
			entry.Frame = TrackDefinitions.SampleAtH(layout, rec.StartH + (hz.From + hz.To) / 2)
			entry.Length = hz.To - hz.From
		elseif rec and hz.Kind == "Tiles" then
			entry.Piece = rec
			entry.Frame = TrackDefinitions.SampleAtH(layout, (rec.StartH + rec.EndH) / 2)
		end
		layout.Hazards[i] = entry
	end

	layout.ChaosGates = {}
	for i, gate in ipairs(def.ChaosGates or {}) do
		local frame = resolve(gate)
		layout.ChaosGates[i] = { Id = gate.Id, Index = i, Frame = frame, S = frame and frame.S, Offset = gate.Offset, Width = gate.Width }
	end

	-- Module contract metadata (A4): one entry per Segment with entry/exit ports.
	layout.Modules = {}
	for _, piece in ipairs(pieces) do
		local last = layout.Modules[#layout.Modules]
		if not last or last.Name ~= piece.Segment then
			local entry = sections[piece.FirstSection]
			last = {
				Name = piece.Segment,
				Kind = piece.Definition.Kind or piece.Segment,
				FirstPiece = piece.Index,
				Entry = { Position = entry.Position, Forward = entry.Forward, Up = entry.Up, Width = entry.Width, S = entry.S },
			}
			layout.Modules[#layout.Modules + 1] = last
		end
		local exit = sections[piece.LastSection]
		last.LastPiece = piece.Index
		last.Exit = { Position = exit.Position, Forward = exit.Forward, Up = exit.Up, Width = exit.Width, S = exit.S }
		last.RouteLength = exit.S - last.Entry.S
		last.ElevationDelta = exit.Position.Y - last.Entry.Position.Y
	end

	layout.Signs = {}
	for i, sign in ipairs(def.Signs or {}) do
		layout.Signs[i] = { Text = sign.Text, Lift = sign.Lift or 10, Frame = resolve(sign) }
	end

	layout.Gates = {}
	for i, gate in ipairs(def.Gates or {}) do
		layout.Gates[i] = { Kind = gate.Kind, Text = gate.Text, Frame = resolve(gate) }
	end
	for i, cp in ipairs(layout.Checkpoints) do
		layout.Gates[#layout.Gates + 1] = { Kind = "Checkpoint", Text = "CHECKPOINT " .. i, Frame = cp.Frame }
	end

	return layout
end

-- Interpolated frame at absolute horizontal distance h.
function TrackDefinitions.SampleAtH(layout, h)
	local sections = layout.Sections
	local n = #sections
	if h <= sections[1].H then
		h = sections[1].H
	end
	if h >= sections[n].H then
		h = sections[n].H
	end
	local lo, hi = 1, n - 1
	while lo < hi do
		local mid = math.floor((lo + hi + 1) / 2)
		if sections[mid].H <= h then
			lo = mid
		else
			hi = mid - 1
		end
	end
	local a, b = sections[lo], sections[math.min(lo + 1, n)]
	local span = b.H - a.H
	local t = 0
	if span > 1e-9 then
		t = (h - a.H) / span
	end
	local forward = (a.Forward + (b.Forward - a.Forward) * t).Unit
	local up = a.Up + (b.Up - a.Up) * t
	up = (up - forward * up:Dot(forward)).Unit
	local right = forward:Cross(up)
	return {
		H = h,
		S = a.S + (b.S - a.S) * t,
		Position = a.Position + (b.Position - a.Position) * t,
		Forward = forward,
		Right = right,
		Up = up,
		Width = a.Width + (b.Width - a.Width) * t,
		SectionIndex = lo,
	}
end

---------------------------------------------------------------------------------------------
-- Validate(def, layout) -> errors (list of strings, empty = valid)
-- Geometry checks only; a graph check cannot prove a human can finish (manual Play Solo does).
---------------------------------------------------------------------------------------------
function TrackDefinitions.Validate(def, layout)
	local errors = {}
	local function fail(msg)
		errors[#errors + 1] = msg
	end
	local diameter = layout.BallRadius * 2

	if #def.Pieces < 4 then
		fail("course needs at least 4 pieces")
	end
	local segments, seen = {}, {}
	for i, piece in ipairs(def.Pieces) do
		if type(piece.Name) ~= "string" or seen[piece.Name] then
			fail("piece " .. i .. " has a missing or duplicate Name")
		end
		seen[piece.Name or i] = true
		if not (piece.Length and piece.Length > 0) then
			fail(piece.Name .. ": Length must be > 0")
		end
		local width = pieceValue(piece, "Width", { 22, 22 })
		local pitch = pieceValue(piece, "Pitch", { 0, 0 })
		local bank = pieceValue(piece, "Bank", { 0, 0 })
		local rails = pieceValue(piece, "Rails", def.DefaultRails)
		if math.min(width[1], width[2]) < diameter * 4 then
			fail(piece.Name .. ": lane narrower than 4 ball diameters")
		end
		if math.max(math.abs(pitch[1]), math.abs(pitch[2])) > 30 then
			fail(piece.Name .. ": pitch beyond 30 degrees")
		end
		if math.max(math.abs(bank[1]), math.abs(bank[2])) > 25 then
			fail(piece.Name .. ": bank beyond 25 degrees")
		end
		if math.min(rails[1], rails[2]) < diameter then
			fail(piece.Name .. ": guardrail lower than one ball diameter")
		end
		if not segments[piece.Segment or "?"] then
			segments[piece.Segment or "?"] = true
			segments[#segments + 1] = piece.Segment
		end
		local nextPiece = def.Pieces[i + 1]
		if nextPiece then
			local nw = pieceValue(nextPiece, "Width", { 22, 22 })
			local np = pieceValue(nextPiece, "Pitch", { 0, 0 })
			local nb = pieceValue(nextPiece, "Bank", { 0, 0 })
			if math.abs(nw[1] - width[2]) > 0.01 then
				fail(piece.Name .. " -> " .. nextPiece.Name .. ": width discontinuity")
			end
			if math.abs(np[1] - pitch[2]) > 0.01 then
				fail(piece.Name .. " -> " .. nextPiece.Name .. ": pitch discontinuity")
			end
			if math.abs(nb[1] - bank[2]) > 0.01 then
				fail(piece.Name .. " -> " .. nextPiece.Name .. ": bank discontinuity")
			end
		end
	end
	local limits = def.Validation or { MinSegments = 4, MaxSegments = 6, MinLength = 500, MaxLength = 2000 }
	if #segments < limits.MinSegments or #segments > limits.MaxSegments then
		fail(string.format("course should have %d-%d segments, has %d", limits.MinSegments, limits.MaxSegments, #segments))
	end

	if not layout.SpawnFrame then
		fail("spawn does not resolve")
	end
	if not layout.StartLineS then
		fail("start line does not resolve")
	end
	if not layout.FinishLineS then
		fail("finish line does not resolve")
	end
	if layout.SpawnFrame and layout.StartLineS and layout.SpawnFrame.S >= layout.StartLineS then
		fail("spawn must be before the start line")
	end
	local previous = layout.StartLineS or 0
	for _, cp in ipairs(layout.Checkpoints) do
		if not cp.S or not cp.RespawnFrame then
			fail("checkpoint " .. tostring(cp.Name) .. " does not resolve")
		elseif cp.S <= previous + diameter * 5 then
			fail("checkpoints must be ascending and spaced after the start line")
		else
			previous = cp.S
		end
	end
	if layout.FinishLineS and layout.FinishLineS <= previous then
		fail("finish line must come after every checkpoint")
	end

	-- Start grid: inside the lane, rail clearance, slots never closer than 1.5 ball diameters.
	local slotPositions = {}
	for i, slot in ipairs(layout.GridSlots) do
		local half = slot.Frame.Width / 2
		if math.abs(slot.Offset) + layout.BallRadius + 1 > half then
			fail("grid slot " .. i .. " is too close to the rail")
		end
		if layout.StartGateFrame and slot.Frame.S >= layout.StartGateFrame.S - diameter then
			fail("grid slot " .. i .. " is not behind the start gate")
		end
		slotPositions[i] = slot.Frame.Position + slot.Frame.Right * slot.Offset
	end
	for i = 1, #slotPositions do
		for j = i + 1, #slotPositions do
			if (slotPositions[i] - slotPositions[j]).Magnitude < diameter * 1.5 then
				fail(string.format("grid slots %d and %d overlap", i, j))
			end
		end
	end
	if layout.StartGateFrame and layout.StartLineS and layout.StartGateFrame.S > layout.StartLineS then
		fail("start gate must be on or before the start line")
	end
	if layout.FinishLineS and layout.FinishLineS >= layout.Route.total - diameter * 2 then
		fail("finish line needs a run-off area after it")
	end

	for _, zone in ipairs(layout.TrickZones or {}) do
		local half = zone.LipFrame.Width / 2
		local freeLeft = (zone.LateralMin + half)
		local freeRight = (half - zone.LateralMax)
		if math.max(freeLeft, freeRight) < diameter * 2 then
			fail("trick ramp leaves no flat lane beside it")
		end
		if math.atan(zone.Height / zone.Length) > math.rad(35) then
			fail("trick ramp steeper than 35 degrees")
		end
	end

	for _, sign in ipairs(layout.Signs) do
		if not sign.Frame then
			fail("sign '" .. tostring(sign.Text) .. "' does not resolve")
		end
	end
	for _, gate in ipairs(layout.Gates) do
		if not gate.Frame then
			fail("gate " .. tostring(gate.Kind) .. " does not resolve")
		end
	end

	for _, hz in ipairs(layout.Hazards) do
		local d = hz.Definition or {}
		if not hz.Frame then
			fail("hazard " .. tostring(hz.Kind) .. " does not resolve")
		else
			local half = hz.Frame.Width / 2
			if hz.Kind == "PulseBumper" then
				local leftGap = half + hz.Offset - hz.Radius
				local rightGap = half - hz.Offset - hz.Radius
				if math.max(leftGap, rightGap) < diameter * 1.5 then
					fail("hazard " .. tostring(hz.Id) .. " leaves no passable lane")
				end
			elseif hz.Kind == "Sweeper" then
				if d.ArmLength > half - 1 then
					fail("sweeper " .. tostring(hz.Id) .. " arm reaches the rails")
				end
			elseif hz.Kind == "Hammer" then
				if d.Amplitude + d.HeadSize / 2 > half - 1 then
					fail("hammer " .. tostring(hz.Id) .. " swing reaches the rails")
				end
				if d.Period < 2 then
					fail("hammer " .. tostring(hz.Id) .. " swings too fast to read")
				end
			elseif hz.Kind == "Tiles" then
				local def0 = hz.Piece and hz.Piece.Definition
				if not def0 or (def0.Yaw or 0) ~= 0 or def0.Pitch[1] ~= def0.Pitch[2] or def0.Floor ~= "Tiles" then
					fail("tiles " .. tostring(hz.Id) .. " must sit on a straight, constant-pitch Floor=\"Tiles\" piece")
				end
				if d.TelegraphSeconds < 0.5 or d.TelegraphSeconds > 1 then
					fail("tiles " .. tostring(hz.Id) .. " telegraph must be 0.5-1 s")
				end
				if d.DropSeconds / d.Period > 0.4 then
					fail("tiles " .. tostring(hz.Id) .. " drop too large a share of the time")
				end
			elseif hz.Kind == "Fan" then
				if d.TelegraphSeconds < 0.5 or d.TelegraphSeconds > 1 then
					fail("fan " .. tostring(hz.Id) .. " telegraph must be 0.5-1 s")
				end
			end
		end
	end
	for _, gate in ipairs(layout.ChaosGates or {}) do
		if not gate.Frame then
			fail("chaos gate " .. tostring(gate.Id) .. " does not resolve")
		elseif math.abs(gate.Offset) + gate.Width / 2 > gate.Frame.Width / 2 then
			fail("chaos gate " .. tostring(gate.Id) .. " sticks outside the lane")
		end
	end

	-- No unintended overlap between distant parts of the course.
	local secs = layout.Sections
	for i = 1, #secs do
		for j = i + 1, #secs do
			if secs[j].S - secs[i].S > 80 then
				local d = (secs[j].Position - secs[i].Position).Magnitude
				if d < 30 then
					fail(string.format("course passes within %.1f studs of itself (sections %d/%d)", d, i, j))
				end
			end
		end
	end

	if layout.MinY < 20 then
		fail("course dips too close to the world floor")
	end
	if layout.Route.total < limits.MinLength or layout.Route.total > limits.MaxLength then
		fail(string.format("route length %.0f outside the %d-%d stud envelope", layout.Route.total, limits.MinLength, limits.MaxLength))
	end

	return errors
end

---------------------------------------------------------------------------------------------
-- A crude 1-D rolling model for a ballpark clean-run time. This is a MODEL, not a measurement:
-- no braking, no steering losses, no bounces. Real times must come from Play Solo.
---------------------------------------------------------------------------------------------
function TrackDefinitions.EstimateRunSeconds(layout, movement, gravity)
	gravity = gravity or 196.2
	local rollFactor = 5 / 7 -- solid sphere rolling without slip
	local sections = layout.Sections
	local v, t = 0.1, 0
	local startS = layout.StartLineS or 0
	local finishS = layout.FinishLineS or layout.Route.total
	for i = 1, #sections - 1 do
		local a, b = sections[i], sections[i + 1]
		local ds = b.S - a.S
		if b.S > startS and a.S < finishS and ds > 0 then
			local sinPitch = math.sin(rad((a.PitchDeg + b.PitchDeg) / 2))
			local throttle = 0
			if v < movement.ThrottleTargetSpeed then
				throttle = movement.AlongTrackAccel * math.min(1, (movement.ThrottleTargetSpeed - v) / movement.ThrottleTaperRange)
			end
			-- motor forces are inertia-compensated (see RollingInertiaCompensation); gravity is not
			local resist = (movement.RollingResistance or 0) + movement.LinearDrag * v
			local accel = rollFactor * gravity * sinPitch + throttle - resist
			if v > movement.TerminalSpeed then
				accel = accel - math.min(movement.TerminalDragMax, (v - movement.TerminalSpeed) * movement.TerminalDragResponse)
			end
			local v2 = math.max(1, v * v + 2 * accel * ds)
			local vNext = math.sqrt(v2)
			t = t + ds / ((v + vNext) / 2)
			v = vNext
		end
	end
	return t, v
end

return TrackDefinitions
