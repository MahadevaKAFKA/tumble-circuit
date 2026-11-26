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

---------------------------------------------------------------------------------------------
-- 2026-11-26 three-lap brief: NEON FOUNDRY CIRCUIT (layout v3). A closed lap that starts and
-- ends on the main straight: wide launch straight -> turbine bank -> bumper field -> split A
-- (outside conveyor carry | inside sweeper shortcut) -> inspection hall drop + braked hairpin ->
-- alternating conveyor lines -> split B (wide safe rail | narrow ramp-and-gap carry) -> hammer
-- -> banked maintenance ascent (boost lane on the outside) -> final turn -> main straight/grid.
-- The three closure values (ConveyorLines / MainStraight lengths, climb pitch C) come from
-- tools/offline/circuit_solver.lua. Records use layout v3, so v2 single-run times are kept apart.
---------------------------------------------------------------------------------------------
TrackDefinitions.NeonFoundryCircuit = {
	Id = "NeonFoundry_A4", -- the map id (hub, ballots, signage) - the LAYOUT version separates records
	DisplayName = "Neon Foundry",
	LayoutVersion = 3,
	Loop = true,
	Laps = 3,
	Origin = Vector3.new(0, 420, 0), -- the start/finish line
	StartHeadingDeg = -90, -- the lap runs away from the Orbital Garage (320 studs clear of the hub)
	FloorThickness = 1.6,
	RailThickness = 1.2,
	DefaultRails = { 4.5, 4.5 },
	MaxStepLength = 24,
	MaxYawStepDeg = 5,
	MaxPitchStepDeg = 2,
	MaxBankStepDeg = 3,
	Solve = { A = "PassingA", B = "PassingB", Climb = { "AscentIn", "AscentBankA", "AscentBankB", "AscentBankC", "AscentOut" } },
	Pieces = {
		{ Name = "LineExit", Segment = "LaunchStraight", Kind = "StraightRamp", Length = 60, Pitch = { 0, 0 }, Width = { 30, 30 }, Rails = { 5, 5 }, Arrows = true },
		{ Name = "LaunchStraight", Segment = "LaunchStraight", Length = 200, Pitch = { 0, 2 }, Width = { 30, 26 }, Arrows = true },
		{ Name = "TurbineIn", Segment = "TurbineBank", Kind = "STurn", Length = 60, Yaw = 25, Pitch = { 2, 2 }, Bank = { 0, 12 }, Width = { 26, 26 }, Rails = { 7, 4.5 } },
		{ Name = "TurbineBank", Segment = "TurbineBank", Length = 200, Yaw = 100, Pitch = { 2, 2 }, Bank = { 12, 12 }, Width = { 26, 26 }, Rails = { 8, 4.5 } },
		{ Name = "TurbineOut", Segment = "TurbineBank", Length = 60, Yaw = 25, Pitch = { 2, 2 }, Bank = { 12, 0 }, Width = { 26, 26 }, Rails = { 7, 4.5 } },
		{ Name = "FieldIn", Segment = "BumperField", Kind = "BumperField", Length = 30, Pitch = { 2, 2 }, Width = { 26, 30 }, Arrows = true },
		{ Name = "Field", Segment = "BumperField", Length = 140, Pitch = { 2, 1 }, Width = { 30, 30 } },
		{ Name = "FieldOut", Segment = "BumperField", Length = 30, Pitch = { 1, 1 }, Width = { 30, 26 } },
		-- compression valley (brief 3 slice): dip down and back up - a clean line keeps speed
		{ Name = "ValleyIn", Segment = "CompressionValley", Kind = "Valley", Length = 40, Pitch = { 1, 6 }, Width = { 26, 28 }, Rails = { 5, 5 } },
		{ Name = "ValleyFloor", Segment = "CompressionValley", Length = 60, Pitch = { 6, -5 }, Width = { 28, 28 }, Rails = { 5, 5 } },
		{ Name = "ValleyOut", Segment = "CompressionValley", Length = 40, Pitch = { -5, 1 }, Width = { 28, 26 }, Rails = { 5, 5 } },
		{ Name = "PassingA", Segment = "PassingA", Kind = "Passing", Length = 177.77, Pitch = { 1, 1 }, Width = { 26, 26 }, Arrows = true },
		{ Name = "SplitAIn", Segment = "SplitA", Kind = "SplitLane", Length = 24, Yaw = -10, Pitch = { 1, 2 }, Bank = { 0, -6 }, Width = { 26, 34 } },
		{ Name = "SplitACurve", Segment = "SplitA", Length = 120, Yaw = -60, Pitch = { 2, 2 }, Bank = { -6, -6 }, Width = { 34, 34 }, Rails = { 5, 7 }, Divider = { From = 4, To = 116, Height = 4.5 } },
		{ Name = "SplitAOut", Segment = "SplitA", Length = 24, Yaw = -10, Pitch = { 2, 2 }, Bank = { -6, 0 }, Width = { 34, 26 } },
		{ Name = "HallApproach", Segment = "InspectionHall", Kind = "DropShaft", Length = 60, Pitch = { 2, 2 }, Width = { 26, 26 }, Rails = { 6, 6 }, Roof = true },
		{ Name = "HallDrop", Segment = "InspectionHall", Length = 40, Pitch = { 2, 14 }, Width = { 26, 26 }, Rails = { 7, 7 } },
		{ Name = "HallDropOut", Segment = "InspectionHall", Length = 40, Pitch = { 14, 0 }, Width = { 26, 26 }, Rails = { 7, 7 } },
		{ Name = "HallBrake", Segment = "InspectionHall", Length = 40, Pitch = { 0, 0 }, Width = { 26, 26 }, Rails = { 6, 6 }, Roof = true },
		{ Name = "HairpinA", Segment = "InspectionHall", Length = 70, Yaw = 75, Pitch = { 0, 0 }, Bank = { 0, 14 }, Width = { 26, 26 }, Rails = { 8, 4.5 }, Roof = true },
		{ Name = "HairpinB", Segment = "InspectionHall", Length = 70, Yaw = 75, Pitch = { 0, 0 }, Bank = { 14, 0 }, Width = { 26, 26 }, Rails = { 8, 4.5 }, Roof = true },
		{ Name = "HallExit", Segment = "InspectionHall", Length = 40, Pitch = { 0, 1 }, Width = { 26, 24 }, Arrows = true },
		{ Name = "ConveyorLines", Segment = "ConveyorLines", Kind = "SideConveyor", Length = 190, Pitch = { 1, 1 }, Width = { 24, 24 }, Rails = { 6, 6 } },
		{ Name = "PassingB", Segment = "PassingB", Kind = "Passing", Length = 129.92, Pitch = { 1, 1 }, Width = { 24, 24 }, Arrows = true },
		{ Name = "SplitBIn", Segment = "SplitB", Kind = "SplitLane", Length = 24, Yaw = 5, Pitch = { 1, 2 }, Bank = { 0, 6 }, Width = { 24, 34 } },
		{ Name = "SplitBCurveA", Segment = "SplitB", Length = 60, Yaw = 22, Pitch = { 2, 2 }, Bank = { 6, 6 }, Width = { 34, 34 }, Rails = { 7, 5 }, Divider = { From = 2, To = 60, Height = 4.5 } },
		{ Name = "SplitBGap", Segment = "SplitB", Length = 6, Yaw = 2, Pitch = { 2, 2 }, Bank = { 6, 6 }, Width = { 34, 34 }, Rails = { 7, 5 }, Divider = { From = 0, To = 6, Height = 4.5 }, HalfFloor = "Left" },
		{ Name = "SplitBCurveB", Segment = "SplitB", Length = 60, Yaw = 21, Pitch = { 2, 2 }, Bank = { 6, 6 }, Width = { 34, 34 }, Rails = { 7, 5 }, Divider = { From = 0, To = 58, Height = 4.5 } },
		{ Name = "SplitBOut", Segment = "SplitB", Length = 24, Yaw = 5, Pitch = { 2, 2 }, Bank = { 6, 0 }, Width = { 34, 26 } },
		{ Name = "HammerRun", Segment = "Hammer", Kind = "SwingingHammer", Length = 80, Pitch = { 2, 1 }, Width = { 26, 26 } },
		{ Name = "AscentIn", Segment = "MaintenanceAscent", Kind = "GuidedAscent", Length = 40, Pitch = { 1, -7.321 }, Width = { 26, 28 }, Rails = { 6, 6 } },
		{ Name = "AscentBankA", Segment = "MaintenanceAscent", Length = 60, Yaw = 10, Pitch = { -7.321, -7.321 }, Bank = { 0, 10 }, Width = { 28, 28 }, Rails = { 7, 5 } },
		{ Name = "AscentBankB", Segment = "MaintenanceAscent", Length = 280, Yaw = 40, Pitch = { -7.321, -7.321 }, Bank = { 10, 10 }, Width = { 28, 28 }, Rails = { 7, 5 } },
		{ Name = "AscentBankC", Segment = "MaintenanceAscent", Length = 60, Yaw = 10, Pitch = { -7.321, -7.321 }, Bank = { 10, 0 }, Width = { 28, 28 }, Rails = { 7, 5 } },
		{ Name = "AscentOut", Segment = "MaintenanceAscent", Length = 50, Pitch = { -7.321, 0 }, Width = { 28, 26 }, Rails = { 6, 6 } },
		{ Name = "FinalTurnA", Segment = "FinalTurn", Kind = "Finish", Length = 35, Yaw = 12.5, Pitch = { 0, 0 }, Bank = { 0, 8 }, Width = { 26, 28 }, Rails = { 6, 4.5 } },
		{ Name = "FinalTurnB", Segment = "FinalTurn", Length = 35, Yaw = 12.5, Pitch = { 0, 0 }, Bank = { 8, 0 }, Width = { 28, 30 }, Rails = { 6, 4.5 } },
		{ Name = "MainStraight", Segment = "MainStraight", Kind = "Start", Length = 200, Pitch = { 0, 0 }, Width = { 30, 30 }, Rails = { 5, 5 }, Arrows = true },
	},
	Spawn = { Piece = "MainStraight", At = 152 },
	StartLine = { Piece = "LineExit", At = 0 },
	FinishLine = { Piece = "LineExit", At = 0 },
	Checkpoints = {
		{ Name = "Turbine Bank", Piece = "TurbineIn", At = 2 },
		{ Name = "Bumper Field", Piece = "FieldIn", At = 4 },
		{ Name = "Split A", Piece = "SplitAIn", At = 2 },
		{ Name = "Inspection Hall", Piece = "HallApproach", At = 10 },
		{ Name = "Hairpin", Piece = "HallBrake", At = 4 },
		{ Name = "Conveyor Lines", Piece = "ConveyorLines", At = 4 },
		{ Name = "Split B", Piece = "SplitBIn", At = 2 },
		{ Name = "Hammer", Piece = "HammerRun", At = 4 },
		{ Name = "Ascent", Piece = "AscentIn", At = 2 },
		{ Name = "Final Turn", Piece = "FinalTurnA", At = 2 },
	},
	Grid = { Piece = "MainStraight", Rows = { 190, 184, 178, 172 }, Columns = { -9.3, -3.1, 3.1, 9.3 } }, -- re-anchored by the solver
	StartGate = { Piece = "MainStraight", At = 197, Height = 5 },
	Features = {
		{ Kind = "TrickRamp", Piece = "LaunchStraight", At = 120, Offset = -6.5, Width = 9, Length = 7, Height = 3.4 },
		-- split B risk line: the kicker carries a fast marble over the 6-stud gap in the right lane
		{ Kind = "TrickRamp", Piece = "SplitBCurveA", At = 59, Offset = 8.5, Width = 12, Length = 6, Height = 2.2 },
	},
	Hazards = {
		{ Kind = "PulseBumper", Id = "BumperA", Piece = "Field", At = 30, Offset = -7, Radius = 3, Height = 4.5 },
		{ Kind = "PulseBumper", Id = "BumperB", Piece = "Field", At = 72, Offset = 7, Radius = 3, Height = 4.5, PhaseOffset = 1.0 },
		{ Kind = "PulseBumper", Id = "BumperC", Piece = "Field", At = 112, Offset = -1, Radius = 3, Height = 4.5, PhaseOffset = 2.1 },
		-- split A: inside lane = a short arm sweeper (faster line), outside lane = a forward conveyor
		{ Kind = "Sweeper", Id = "Sweeper1", Piece = "SplitACurve", At = 60, Offset = -9, ArmLength = 6, ArmHeight = 2.2, ArmThickness = 1.4, Speed = 1.1, Direction = 1, PostRadius = 1.2 },
		{ Kind = "Boost", Id = "CarryA1", Piece = "SplitACurve", From = 6, To = 60, Offset = 8.8, Width = 15, Accel = 10 },
		{ Kind = "Boost", Id = "CarryA2", Piece = "SplitACurve", From = 60, To = 114, Offset = 8.8, Width = 15, Accel = 10 },
		{ Kind = "Conveyor", Id = "Conveyor1", Piece = "ConveyorLines", From = 12, To = 82, Direction = 1, Accel = 18 },
		{ Kind = "Conveyor", Id = "Conveyor2", Piece = "ConveyorLines", From = 106, To = 176, Direction = -1, Accel = 18 },
		{ Kind = "Hammer", Id = "Hammer1", Piece = "HammerRun", At = 44, Amplitude = 8, Period = 3.0, HeadSize = 3.4 },
		-- maintenance ascent: the outside (left) lane is boost-assisted - roughly cancels the climb
		{ Kind = "Boost", Id = "Lift1", Piece = "AscentIn", From = 16, To = 40, Offset = -6, Width = 13, Accel = 17 },
		{ Kind = "Boost", Id = "Lift2", Piece = "AscentBankA", From = 0, To = 60, Offset = -6, Width = 13, Accel = 17 },
		{ Kind = "Boost", Id = "Lift3", Piece = "AscentBankB", From = 0, To = 70, Offset = -6, Width = 13, Accel = 17 },
		{ Kind = "Boost", Id = "Lift4", Piece = "AscentBankB", From = 70, To = 140, Offset = -6, Width = 13, Accel = 17 },
		{ Kind = "Boost", Id = "Lift5", Piece = "AscentBankB", From = 140, To = 210, Offset = -6, Width = 13, Accel = 17 },
		{ Kind = "Boost", Id = "Lift6", Piece = "AscentBankB", From = 210, To = 280, Offset = -6, Width = 13, Accel = 17 },
		{ Kind = "Boost", Id = "Lift7", Piece = "AscentBankC", From = 0, To = 60, Offset = -6, Width = 13, Accel = 17 },
		{ Kind = "Boost", Id = "Lift8", Piece = "AscentOut", From = 0, To = 30, Offset = -6, Width = 13, Accel = 17 },
	},
	ChaosGates = {
		{ Id = "Gate1", Piece = "TurbineBank", At = 100, Offset = -7, Width = 9 },
		{ Id = "Gate2", Piece = "ConveyorLines", At = 94, Offset = 6, Width = 9 },
		{ Id = "Gate3", Piece = "FinalTurnB", At = 12, Offset = -7, Width = 9 },
	},
	WarningStrips = {
		{ Piece = "HallBrake", From = 2, To = 38 },
	},
	Signs = {
		{ Piece = "LaunchStraight", At = 96, Text = "TRICK RAMP - LEFT", Lift = 9 },
		{ Piece = "TurbineIn", At = 0, Text = "TURBINE BANK", Lift = 9 },
		{ Piece = "FieldIn", At = 0, Text = "BUMPER FIELD - CORAL KICKS", Lift = 9 },
		{ Piece = "SplitAIn", At = 0, Text = "INSIDE: SWEEPER SHORTCUT  |  OUTSIDE: CONVEYOR", Lift = 9 },
		{ Piece = "HallApproach", At = 30, Text = "DROP + HAIRPIN - BRAKE", Lift = 9 },
		{ Piece = "ConveyorLines", At = 0, Text = "CONVEYOR LINES", Lift = 9 },
		{ Piece = "SplitBIn", At = 0, Text = "LEFT: SAFE RAIL  |  RIGHT: RAMP + GAP", Lift = 9 },
		{ Piece = "AscentIn", At = 0, Text = "ASCENT - BOOST LANE LEFT", Lift = 9 },
	},
	Gates = {
		{ Kind = "Start", Piece = "LineExit", At = 0, Text = "START  /  FINISH" },
	},
	Validation = { MinSegments = 10, MaxSegments = 16, MinLength = 2200, MaxLength = 3600 },
	ArrowSpacing = 18,
	MaxRaceSeconds = 480, -- provisional, from the lap MODEL (no slow-finisher data yet)
}

---------------------------------------------------------------------------------------------
-- 2026-11-26 challenges brief: THE DROP SHAFT (challenge course, revision 1). A short authored
-- Foundry sector built on its own (identical for every attempt, whatever map is racing):
-- start pad + gate -> launch slope (the same "controlled launch" speed for everyone) ->
-- approach -> marked braking zone -> the lip (a kicker on the right = the precision entry) ->
-- the shaft -> a wide landing with the qualifying line -> split hairpin (inside: the faster,
-- marked line | outside: wide and safe) -> exit straight -> finish basin. No moving hazards.
---------------------------------------------------------------------------------------------
TrackDefinitions.DropShaftChallenge = {
	Id = "DropShaft_C1",
	DisplayName = "The Drop Shaft",
	LayoutVersion = 1,
	Origin = Vector3.new(1300, 640, -200),
	StartHeadingDeg = 0,
	FloorThickness = 1.6,
	RailThickness = 1.2,
	DefaultRails = { 5, 5 },
	MaxStepLength = 24,
	MaxYawStepDeg = 5,
	MaxPitchStepDeg = 2,
	MaxBankStepDeg = 3,
	Roadside = true,
	Pieces = {
		{ Name = "StartPad", Segment = "Start", Kind = "Start", Length = 30, Pitch = { 0, 0 }, Width = { 26, 26 }, Rails = { 5, 5 }, StartCap = true },
		{ Name = "LaunchSlope", Segment = "Launch", Kind = "StraightRamp", Length = 50, Pitch = { 0, 8 }, Width = { 26, 26 }, Arrows = true },
		{ Name = "Approach", Segment = "Approach", Length = 120, Pitch = { 8, 2 }, Width = { 26, 26 } },
		{ Name = "BrakeZone", Segment = "Approach", Length = 50, Pitch = { 2, 2 }, Width = { 26, 26 } },
		{ Name = "Lip", Segment = "Shaft", Kind = "DropShaft", Length = 14, Pitch = { 2, 4 }, Width = { 26, 26 } },
		{ Name = "DropIn", Segment = "Shaft", Length = 30, Pitch = { 4, 16 }, Width = { 26, 30 }, Rails = { 7, 7 } },
		{ Name = "Shaft", Segment = "Shaft", Length = 50, Pitch = { 16, 16 }, Width = { 30, 30 }, Rails = { 8, 8 } },
		{ Name = "DropOut", Segment = "Shaft", Length = 40, Pitch = { 16, 1 }, Width = { 30, 32 }, Rails = { 7, 7 } },
		{ Name = "Landing", Segment = "Landing", Length = 70, Pitch = { 1, 1 }, Width = { 32, 32 }, Rails = { 6, 6 } },
		{ Name = "SplitIn", Segment = "Hairpin", Kind = "SplitLane", Length = 24, Yaw = 10, Pitch = { 1, 1 }, Bank = { 0, 8 }, Width = { 32, 34 } },
		{ Name = "Hairpin", Segment = "Hairpin", Length = 150, Yaw = 150, Pitch = { 1, 1 }, Bank = { 8, 8 }, Width = { 34, 34 }, Rails = { 8, 5 }, Divider = { From = 4, To = 146, Height = 4.5 } },
		{ Name = "SplitOut", Segment = "Hairpin", Length = 24, Yaw = 20, Pitch = { 1, 1 }, Bank = { 8, 0 }, Width = { 34, 26 } },
		{ Name = "ExitStraight", Segment = "Exit", Length = 120, Pitch = { 1, 2 }, Width = { 26, 26 }, Arrows = true },
		{ Name = "FinishStraight", Segment = "Finish", Kind = "Finish", Length = 40, Pitch = { 2, 1 }, Width = { 26, 28 } },
		{ Name = "FinishBasin", Segment = "Finish", Length = 40, Pitch = { 1, -3 }, Width = { 28, 30 }, Rails = { 6, 6 }, EndCap = true },
	},
	Spawn = { Piece = "StartPad", At = 14 },
	StartLine = { Piece = "StartPad", At = 30 },
	FinishLine = { Piece = "FinishStraight", At = 40 },
	Checkpoints = {
		{ Name = "Lip", Piece = "Lip", At = 2 },
		{ Name = "Landing", Piece = "Landing", At = 56 },
		{ Name = "Hairpin Exit", Piece = "ExitStraight", At = 10 },
	},
	Grid = { Piece = "StartPad", Rows = { 18 }, Columns = { -6.5, 0, 6.5 } },
	StartGate = { Piece = "StartPad", At = 27, Height = 5 },
	Features = {
		-- the precision entry: hit this kicker fast and you land beyond the qualifying line
		{ Kind = "TrickRamp", Piece = "BrakeZone", At = 49, Offset = 7, Width = 9, Length = 6, Height = 2.4 },
	},
	Hazards = {},
	WarningStrips = {
		{ Piece = "BrakeZone", From = 2, To = 40 },
	},
	Signs = {
		{ Piece = "BrakeZone", At = 0, Text = "BRAKE ZONE  |  RIGHT KICKER = PRECISION ENTRY", Lift = 9 },
		{ Piece = "Landing", At = 30, Text = "QUALIFYING LINE", Lift = 8 },
		{ Piece = "SplitIn", At = 0, Text = "INSIDE: FAST LINE  |  OUTSIDE: SAFE", Lift = 9 },
	},
	Gates = {
		{ Kind = "Start", Piece = "StartPad", At = 30, Text = "DROP SHAFT" },
		{ Kind = "Finish", Piece = "FinishStraight", At = 40, Text = "FINISH" },
	},
	QualifyingLine = { Piece = "Landing", At = 30 }, -- mastery "Signature Line": first landing beyond this
	Validation = { MinSegments = 6, MaxSegments = 10, MinLength = 500, MaxLength = 1200 },
	ArrowSpacing = 16,
}

-- 2026-11-26 three-lap brief: true = standard races are three-lap circuits; false = the v2
-- single-run courses (development fallback / rollback - one flag). While true, a map without a
-- validated circuit stays OFF rotation and out of the vote (MapRegistry asks RaceReady).
TrackDefinitions.CircuitRaces = true

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
---------------------------------------------------------------------------------------------
-- 2026-11-26 three-lap brief: SKY CARNIVAL CIRCUIT (layout v2). A different shape and skill
-- from the Foundry: it turns LEFT (counter-clockwise), the choices are about BOUNCES not
-- sweepers, and the lap climbs home on a 300-degree ribbon helix with a lift lane:
-- float deck -> carousel bank -> cloud gap (inside: drum bounce over the gap | outside: bridge)
-- -> balloon field -> sweep -> wind lane -> sky arc (inside: two short kicker hops | outside:
-- wide arc) -> drum landing -> ribbon helix (lift lane outside) -> final turn -> main straight.
---------------------------------------------------------------------------------------------
TrackDefinitions.SkyCarnivalCircuit = {
	Id = "SkyCarnival_B1",
	DisplayName = "Sky Carnival",
	LayoutVersion = 2, -- v1 = the single run (records stay apart)
	Loop = true,
	Laps = 3,
	Origin = Vector3.new(2600, 560, 0),
	StartHeadingDeg = 90,
	FloorThickness = 1.6,
	RailThickness = 1.2,
	DefaultRails = { 4.5, 4.5 },
	MaxStepLength = 24,
	MaxYawStepDeg = 5,
	MaxPitchStepDeg = 2,
	MaxBankStepDeg = 3,
	Theme = TrackDefinitions.SkyCarnival.Theme,
	FinisherDeckSide = -1,
	Solve = { A = "CarouselStraight", B = "CloudStraight", Climb = { "HelixIn", "HelixA", "HelixB", "HelixC", "HelixOut" } },
	Pieces = {
		-- leg 1: line -> float deck (forward)
		{ Name = "LineExit", Segment = "FloatDeck", Kind = "StraightRamp", Length = 60, Pitch = { 0, 0 }, Width = { 30, 30 }, Rails = { 5, 5 }, Arrows = true },
		{ Name = "FloatDeck", Segment = "FloatDeck", Length = 240, Pitch = { 0, 3 }, Width = { 30, 26 }, Arrows = true },
		{ Name = "FieldIn", Segment = "BalloonField", Kind = "BumperField", Length = 30, Pitch = { 3, 3 }, Width = { 26, 30 }, Arrows = true },
		{ Name = "Field", Segment = "BalloonField", Length = 140, Pitch = { 3, 3 }, Width = { 30, 30 } },
		{ Name = "FieldOut", Segment = "BalloonField", Length = 30, Pitch = { 3, 3 }, Width = { 30, 26 } },
		{ Name = "WindLane", Segment = "WindLane", Kind = "FanTunnel", Length = 200, Pitch = { 3, 3 }, Width = { 26, 26 }, Rails = { 6, 6 } },
		-- carousel: a banked left-hand half circle onto the back leg
		{ Name = "CarouselIn", Segment = "CarouselBank", Kind = "STurn", Length = 45, Yaw = -20, Pitch = { 3, 3 }, Bank = { 0, -12 }, Width = { 26, 26 }, Rails = { 4.5, 7 } },
		{ Name = "CarouselBankA", Segment = "CarouselBank", Length = 90, Yaw = -70, Pitch = { 3, 2 }, Bank = { -12, -12 }, Width = { 26, 26 }, Rails = { 4.5, 8 } },
		{ Name = "CarouselStraight", Segment = "CarouselBank", Length = 83.35, Pitch = { 2, 2 }, Bank = { -12, -12 }, Width = { 26, 26 }, Rails = { 4.5, 8 } },
		{ Name = "CarouselBankB", Segment = "CarouselBank", Length = 90, Yaw = -70, Pitch = { 2, 2 }, Bank = { -12, -12 }, Width = { 26, 26 }, Rails = { 4.5, 8 } },
		{ Name = "CarouselOut", Segment = "CarouselBank", Length = 45, Yaw = -20, Pitch = { 2, 2 }, Bank = { -12, 0 }, Width = { 26, 26 }, Rails = { 4.5, 7 } },
		-- leg 2 (back): cloud gap choice (inside drum bounce | outside bridge)
		{ Name = "GapSplitIn", Segment = "CloudGap", Kind = "SplitLane", Length = 24, Yaw = -5, Pitch = { 2, 2 }, Bank = { 0, -6 }, Width = { 26, 34 } },
		{ Name = "GapApproach", Segment = "CloudGap", Length = 50, Yaw = -12, Pitch = { 2, 2 }, Bank = { -6, -6 }, Width = { 34, 34 }, Rails = { 5, 7 }, Divider = { From = 2, To = 50, Height = 4.5 } },
		{ Name = "CloudGapA", Segment = "CloudGap", Length = 8, Yaw = -2, Pitch = { 2, 2 }, Bank = { -6, -6 }, Width = { 34, 34 }, Rails = { 5, 7 }, Divider = { From = 0, To = 8, Height = 4.5 }, HalfFloor = "Right" },
		{ Name = "GapLanding", Segment = "CloudGap", Length = 50, Yaw = -16, Pitch = { 2, 2 }, Bank = { -6, -6 }, Width = { 34, 34 }, Rails = { 5, 7 }, Divider = { From = 0, To = 48, Height = 4.5 } },
		{ Name = "GapSplitOut", Segment = "CloudGap", Length = 24, Yaw = -5, Pitch = { 2, 2 }, Bank = { -6, 0 }, Width = { 34, 26 } },
		{ Name = "CloudStraight", Segment = "CloudStraight", Kind = "Passing", Length = 143.0, Pitch = { 2, 2 }, Width = { 26, 26 }, Arrows = true },
		{ Name = "SweepA", Segment = "Sweep", Kind = "STurn", Length = 60, Yaw = 20, Pitch = { 2, 2 }, Bank = { 0, 8 }, Width = { 26, 26 }, Rails = { 6, 4.5 } },
		{ Name = "SweepB", Segment = "Sweep", Length = 60, Yaw = 20, Pitch = { 2, 2 }, Bank = { 8, 0 }, Width = { 26, 26 }, Rails = { 6, 4.5 } },
		-- sky arc choice (inside: two short kicker hops | outside: the wide arc)
		{ Name = "ArcIn", Segment = "SkyArc", Kind = "SplitLane", Length = 24, Yaw = 6, Pitch = { 2, 2 }, Bank = { 0, 6 }, Width = { 26, 34 } },
		{ Name = "ArcA", Segment = "SkyArc", Length = 50, Yaw = 14, Pitch = { 2, 2 }, Bank = { 6, 6 }, Width = { 34, 34 }, Rails = { 7, 5 }, Divider = { From = 2, To = 50, Height = 4.5 } },
		{ Name = "HopGap1", Segment = "SkyArc", Length = 6, Yaw = 2, Pitch = { 2, 2 }, Bank = { 6, 6 }, Width = { 34, 34 }, Rails = { 7, 5 }, Divider = { From = 0, To = 6, Height = 4.5 }, HalfFloor = "Left" },
		{ Name = "ArcB", Segment = "SkyArc", Length = 40, Yaw = 12, Pitch = { 2, 2 }, Bank = { 6, 6 }, Width = { 34, 34 }, Rails = { 7, 5 }, Divider = { From = 0, To = 40, Height = 4.5 } },
		{ Name = "HopGap2", Segment = "SkyArc", Length = 6, Yaw = 2, Pitch = { 2, 2 }, Bank = { 6, 6 }, Width = { 34, 34 }, Rails = { 7, 5 }, Divider = { From = 0, To = 6, Height = 4.5 }, HalfFloor = "Left" },
		{ Name = "ArcC", Segment = "SkyArc", Length = 50, Yaw = 18, Pitch = { 2, 2 }, Bank = { 6, 6 }, Width = { 34, 34 }, Rails = { 7, 5 }, Divider = { From = 0, To = 48, Height = 4.5 } },
		{ Name = "ArcOut", Segment = "SkyArc", Length = 24, Yaw = 6, Pitch = { 2, 2 }, Bank = { 6, 0 }, Width = { 34, 26 } },
		{ Name = "ArcRecoverA", Segment = "ArcRecover", Kind = "STurn", Length = 60, Yaw = -30, Pitch = { 2, 2 }, Bank = { 0, -8 }, Width = { 26, 26 }, Rails = { 4.5, 6 } },
		{ Name = "ArcRecoverB", Segment = "ArcRecover", Length = 60, Yaw = -30, Pitch = { 2, 2 }, Bank = { -8, 0 }, Width = { 26, 26 }, Rails = { 4.5, 6 } },
		-- the cloud drop (this map's big moment), then the stable drum landing
		{ Name = "DropIn", Segment = "CloudDrop", Kind = "DropShaft", Length = 30, Pitch = { 2, 12 }, Width = { 26, 28 }, Rails = { 7, 7 } },
		{ Name = "DropMid", Segment = "CloudDrop", Length = 70, Pitch = { 12, 12 }, Width = { 28, 28 }, Rails = { 8, 8 } },
		{ Name = "DropOut", Segment = "CloudDrop", Length = 40, Pitch = { 12, 1 }, Width = { 28, 26 }, Rails = { 7, 7 } },
		{ Name = "DrumZone", Segment = "DrumLanding", Kind = "TrampolinePad", Length = 60, Pitch = { 1, 1 }, Width = { 26, 26 } },
		{ Name = "LandingRun", Segment = "DrumLanding", Length = 70, Pitch = { 1, 1 }, Width = { 26, 26 }, Arrows = true },
		-- ribbon helix: one and a half climbing left turns (stacked), out onto the main straight
		{ Name = "HelixIn", Segment = "RibbonHelix", Kind = "GuidedAscent", Length = 40, Pitch = { 1, -5.298 }, Width = { 26, 28 }, Rails = { 6, 6 } },
		{ Name = "HelixA", Segment = "RibbonHelix", Length = 60, Yaw = -30, Pitch = { -5.298, -5.298 }, Bank = { 0, -10 }, Width = { 28, 28 }, Rails = { 5, 7 } },
		{ Name = "HelixB", Segment = "RibbonHelix", Length = 840, Yaw = -480, Pitch = { -5.298, -5.298 }, Bank = { -10, -10 }, Width = { 28, 28 }, Rails = { 5, 8 } },
		{ Name = "HelixC", Segment = "RibbonHelix", Length = 60, Yaw = -30, Pitch = { -5.298, -5.298 }, Bank = { -10, 0 }, Width = { 28, 28 }, Rails = { 5, 7 } },
		{ Name = "HelixOut", Segment = "RibbonHelix", Length = 40, Pitch = { -5.298, 0 }, Width = { 28, 30 }, Rails = { 6, 6 } },
		{ Name = "MainStraight", Segment = "MainStraight", Kind = "Start", Length = 200, Pitch = { 0, 0 }, Width = { 30, 30 }, Rails = { 5, 5 }, Arrows = true },
	},
	Spawn = { Piece = "MainStraight", At = 152 },
	StartLine = { Piece = "LineExit", At = 0 },
	FinishLine = { Piece = "LineExit", At = 0 },
	Checkpoints = {
		{ Name = "Balloon Field", Piece = "FieldIn", At = 4 },
		{ Name = "Wind Lane", Piece = "WindLane", At = 4 },
		{ Name = "Carousel", Piece = "CarouselIn", At = 2 },
		{ Name = "Cloud Gap", Piece = "GapSplitIn", At = 2 },
		{ Name = "Cloud Straight", Piece = "CloudStraight", At = 8 },
		{ Name = "Sky Arc", Piece = "ArcIn", At = 2 },
		{ Name = "Cloud Drop", Piece = "DropIn", At = 2 },
		{ Name = "Drum", Piece = "DrumZone", At = 2 },
		{ Name = "Helix", Piece = "HelixIn", At = 2 },
		{ Name = "Helix Top", Piece = "HelixB", At = 460 },
	},
	Grid = { Piece = "MainStraight", Rows = { 190, 183.5, 177, 170.5 }, Columns = { -9.3, -3.1, 3.1, 9.3 } },
	StartGate = { Piece = "MainStraight", At = 197, Height = 5 },
	Features = {
		-- sky arc hops: a kicker before each short inside-lane gap
		{ Kind = "TrickRamp", Piece = "ArcA", At = 49, Offset = 8.5, Width = 12, Length = 6, Height = 2.2 },
		{ Kind = "TrickRamp", Piece = "ArcB", At = 39, Offset = 8.5, Width = 12, Length = 6, Height = 2.2 },
	},
	Hazards = {
		-- cloud gap bounce: a drum in the inside (left) lane throws you over the 8-stud gap
		{ Kind = "Trampoline", Id = "GapDrum", Style = "Drum", Piece = "GapApproach", At = 43, Offset = -8.5, Width = 12, Length = 5, UpDeltaV = 34 },
		{ Kind = "PulseBumper", Id = "BalloonA", Style = "Balloon", Piece = "Field", At = 28, Offset = 7, Radius = 3, Height = 4.5 },
		{ Kind = "PulseBumper", Id = "BalloonB", Style = "Balloon", Piece = "Field", At = 70, Offset = -7, Radius = 3, Height = 4.5, PhaseOffset = 1.2 },
		{ Kind = "PulseBumper", Id = "BalloonC", Style = "Balloon", Piece = "Field", At = 110, Offset = 1, Radius = 3, Height = 4.5, PhaseOffset = 2.3 },
		{ Kind = "Fan", Id = "Wind1", Style = "Wind", Piece = "WindLane", From = 12, To = 148, Direction = -1, Accel = 24, OnSeconds = 2.4, OffSeconds = 2.0, TelegraphSeconds = 0.7 },
		-- the stable drum landing: a full-lane drum, then a long flat landing run
		{ Kind = "Trampoline", Id = "Drum1", Style = "Drum", Piece = "DrumZone", At = 30, Offset = 0, Width = 18, Length = 6, UpDeltaV = 30 },
		-- ribbon helix lift lane (outside = right)
		{ Kind = "Boost", Id = "Lift1", Piece = "HelixIn", From = 14, To = 40, Offset = 6, Width = 13, Accel = 13 },
		{ Kind = "Boost", Id = "Lift2", Piece = "HelixA", From = 0, To = 60, Offset = 6, Width = 13, Accel = 13 },
		{ Kind = "Boost", Id = "Lift3", Piece = "HelixB", From = 0, To = 60, Offset = 6, Width = 13, Accel = 13 },
		{ Kind = "Boost", Id = "Lift4", Piece = "HelixB", From = 60, To = 120, Offset = 6, Width = 13, Accel = 13 },
		{ Kind = "Boost", Id = "Lift5", Piece = "HelixB", From = 120, To = 180, Offset = 6, Width = 13, Accel = 13 },
		{ Kind = "Boost", Id = "Lift6", Piece = "HelixB", From = 180, To = 240, Offset = 6, Width = 13, Accel = 13 },
		{ Kind = "Boost", Id = "Lift7", Piece = "HelixB", From = 240, To = 300, Offset = 6, Width = 13, Accel = 13 },
		{ Kind = "Boost", Id = "Lift8", Piece = "HelixB", From = 300, To = 360, Offset = 6, Width = 13, Accel = 13 },
		{ Kind = "Boost", Id = "Lift9", Piece = "HelixB", From = 360, To = 420, Offset = 6, Width = 13, Accel = 13 },
		{ Kind = "Boost", Id = "Lift10", Piece = "HelixB", From = 420, To = 480, Offset = 6, Width = 13, Accel = 13 },
		{ Kind = "Boost", Id = "Lift11", Piece = "HelixB", From = 480, To = 540, Offset = 6, Width = 13, Accel = 13 },
		{ Kind = "Boost", Id = "Lift12", Piece = "HelixB", From = 540, To = 600, Offset = 6, Width = 13, Accel = 13 },
		{ Kind = "Boost", Id = "Lift13", Piece = "HelixB", From = 600, To = 660, Offset = 6, Width = 13, Accel = 13 },
		{ Kind = "Boost", Id = "Lift14", Piece = "HelixB", From = 660, To = 720, Offset = 6, Width = 13, Accel = 13 },
		{ Kind = "Boost", Id = "Lift15", Piece = "HelixB", From = 720, To = 780, Offset = 6, Width = 13, Accel = 13 },
		{ Kind = "Boost", Id = "Lift16", Piece = "HelixB", From = 780, To = 840, Offset = 6, Width = 13, Accel = 13 },
		{ Kind = "Boost", Id = "Lift17", Piece = "HelixC", From = 0, To = 60, Offset = 6, Width = 13, Accel = 13 },
		{ Kind = "Boost", Id = "Lift18", Piece = "HelixOut", From = 0, To = 26, Offset = 6, Width = 13, Accel = 13 },
	},
	ChaosGates = {
		{ Id = "Gate1", Piece = "CarouselStraight", At = 60, Offset = 7, Width = 9 },
		{ Id = "Gate2", Piece = "CloudStraight", At = 60, Offset = -6, Width = 9 },
		{ Id = "Gate3", Piece = "LandingRun", At = 40, Offset = 6, Width = 9 },
	},
	Signs = {
		{ Piece = "CarouselIn", At = 0, Text = "CAROUSEL BANK", Lift = 9 },
		{ Piece = "GapSplitIn", At = 0, Text = "INSIDE: DRUM BOUNCE  |  OUTSIDE: BRIDGE", Lift = 9 },
		{ Piece = "FieldIn", At = 0, Text = "BALLOON FIELD", Lift = 9 },
		{ Piece = "WindLane", At = 0, Text = "WIND LANE - GUSTS", Lift = 9 },
		{ Piece = "DropIn", At = 0, Text = "CLOUD DROP - BRAKE TO LAND", Lift = 9 },
		{ Piece = "ArcIn", At = 0, Text = "INSIDE: TWO HOPS  |  OUTSIDE: WIDE ARC", Lift = 9 },
		{ Piece = "DrumZone", At = 0, Text = "DRUM - BOUNCE AND LAND", Lift = 9 },
		{ Piece = "HelixIn", At = 0, Text = "RIBBON HELIX - LIFT LANE RIGHT", Lift = 9 },
	},
	Gates = {
		{ Kind = "Start", Piece = "LineExit", At = 0, Text = "START  /  FINISH" },
	},
	Validation = { MinSegments = 10, MaxSegments = 16, MinLength = 2200, MaxLength = 3600 },
	ArrowSpacing = 18,
	MaxRaceSeconds = 480, -- provisional, from the lap MODEL
}

---------------------------------------------------------------------------------------------
-- 2026-11-26 (graphics/gameplay brief, milestone C): VOLCANO VAULT CIRCUIT (layout v2). The
-- timing-and-braking course, clockwise like the Foundry but built from bowls and chicanes:
-- vent straight -> basalt bowl A -> rock chicane -> passing straight -> vent split (inside: one
-- big timed vent | outside: three small vents, frequent safe gaps) -> cool maintenance corridor
-- (roofed, piston) -> basalt bowl B -> passing straight -> brake split (inside: brake-heavy
-- tight line | outside: longer exit) -> uphill tunnel through the ridge (roofed, boost lane)
-- -> final turn -> main straight. Neutral-grey road against warm lava channels.
---------------------------------------------------------------------------------------------
do
	local theme = {}
	for k, v in pairs(TrackDefinitions.VolcanoVault.Theme) do
		theme[k] = v
	end
	theme.NavyFloor = Color3.fromRGB(98, 98, 104) -- neutral grey road (brief: readable midtone)
	theme.Navy = Color3.fromRGB(64, 62, 68)
	theme.NavyRail = Color3.fromRGB(124, 120, 124)
	TrackDefinitions.VolcanoVaultCircuit = {
		Id = "VolcanoVault_B1",
		DisplayName = "Volcano Vault",
		LayoutVersion = 2,
		Loop = true,
		Laps = 3,
		Origin = Vector3.new(-2600, 440, 0),
		StartHeadingDeg = -90,
		FloorThickness = 1.6,
		RailThickness = 1.2,
		DefaultRails = { 4.5, 4.5 },
		MaxStepLength = 24,
		MaxYawStepDeg = 5,
		MaxPitchStepDeg = 2,
		MaxBankStepDeg = 3,
		Theme = theme,
		Solve = { A = "PassingA", B = "PassingB", Climb = { "TunnelIn", "Tunnel", "TunnelOut" } },
		Pieces = {
			{ Name = "LineExit", Segment = "VentStraight", Kind = "StraightRamp", Length = 60, Pitch = { 0, 0 }, Width = { 30, 30 }, Rails = { 5, 5 }, Arrows = true },
			{ Name = "VentStraight", Segment = "VentStraight", Length = 220, Pitch = { 0, 2 }, Width = { 30, 26 }, Rails = { 6, 6 } },
			{ Name = "BowlAIn", Segment = "BasaltBowlA", Kind = "STurn", Length = 50, Yaw = 15, Pitch = { 2, 2 }, Bank = { 0, 14 }, Width = { 26, 28 }, Rails = { 7, 4.5 } },
			{ Name = "BowlA", Segment = "BasaltBowlA", Length = 150, Yaw = 60, Pitch = { 2, 2 }, Bank = { 14, 14 }, Width = { 28, 28 }, Rails = { 8, 4.5 } },
			{ Name = "BowlAOut", Segment = "BasaltBowlA", Length = 50, Yaw = 15, Pitch = { 2, 2 }, Bank = { 14, 0 }, Width = { 28, 26 }, Rails = { 7, 4.5 } },
			{ Name = "ChicaneA", Segment = "RockChicane", Kind = "BumperField", Length = 50, Yaw = -20, Pitch = { 2, 2 }, Bank = { 0, -8 }, Width = { 26, 26 }, Rails = { 4.5, 6 } },
			{ Name = "ChicaneB", Segment = "RockChicane", Length = 50, Yaw = -20, Pitch = { 2, 2 }, Bank = { -8, 0 }, Width = { 26, 26 }, Rails = { 4.5, 6 } },
			{ Name = "ChicaneC", Segment = "RockChicane", Length = 50, Yaw = 20, Pitch = { 2, 2 }, Bank = { 0, 8 }, Width = { 26, 26 }, Rails = { 6, 4.5 } },
			{ Name = "ChicaneD", Segment = "RockChicane", Length = 50, Yaw = 20, Pitch = { 2, 2 }, Bank = { 8, 0 }, Width = { 26, 26 }, Rails = { 6, 4.5 } },
			{ Name = "PassingA", Segment = "PassingA", Kind = "Passing", Length = 59.54, Pitch = { 2, 2 }, Width = { 26, 26 }, Arrows = true },
			{ Name = "VentSplitIn", Segment = "VentSplit", Kind = "SplitLane", Length = 24, Pitch = { 2, 2 }, Width = { 26, 34 } },
			{ Name = "VentSplit", Segment = "VentSplit", Length = 120, Pitch = { 2, 2 }, Width = { 34, 34 }, Rails = { 6, 6 }, Divider = { From = 4, To = 116, Height = 4.5 } },
			{ Name = "VentSplitOut", Segment = "VentSplit", Length = 24, Pitch = { 2, 2 }, Width = { 34, 26 } },
			{ Name = "BowlBIn", Segment = "BasaltBowlB", Kind = "STurn", Length = 50, Yaw = 15, Pitch = { 2, 2 }, Bank = { 0, 14 }, Width = { 26, 28 }, Rails = { 7, 4.5 } },
			{ Name = "BowlB", Segment = "BasaltBowlB", Length = 150, Yaw = 60, Pitch = { 2, 2 }, Bank = { 14, 14 }, Width = { 28, 28 }, Rails = { 8, 4.5 } },
			{ Name = "BowlBOut", Segment = "BasaltBowlB", Length = 50, Yaw = 15, Pitch = { 2, 2 }, Bank = { 14, 0 }, Width = { 28, 26 }, Rails = { 7, 4.5 } },
			{ Name = "Corridor", Segment = "MaintenanceCorridor", Kind = "SwingingHammer", Length = 160, Pitch = { 2, 2 }, Width = { 26, 26 }, Rails = { 6, 6 }, Roof = true },
			{ Name = "PassingB", Segment = "PassingB", Kind = "Passing", Length = 325.4, Pitch = { 2, 2 }, Width = { 26, 26 }, Arrows = true },
			{ Name = "BrakeSplitIn", Segment = "BrakeSplit", Kind = "SplitLane", Length = 24, Yaw = 10, Pitch = { 2, 2 }, Bank = { 0, 6 }, Width = { 26, 34 } },
			{ Name = "BrakeSplit", Segment = "BrakeSplit", Length = 140, Yaw = 70, Pitch = { 2, 2 }, Bank = { 6, 6 }, Width = { 34, 34 }, Rails = { 7, 5 }, Divider = { From = 4, To = 136, Height = 4.5 } },
			{ Name = "BrakeSplitOut", Segment = "BrakeSplit", Length = 24, Yaw = 10, Pitch = { 2, 2 }, Bank = { 6, 0 }, Width = { 34, 26 } },
			{ Name = "TunnelIn", Segment = "RidgeTunnel", Kind = "GuidedAscent", Length = 40, Pitch = { 2, -6.761 }, Width = { 26, 28 }, Rails = { 6, 6 }, Roof = true },
			{ Name = "Tunnel", Segment = "RidgeTunnel", Length = 470, Pitch = { -6.761, -6.761 }, Width = { 28, 28 }, Rails = { 6, 6 }, Roof = true },
			{ Name = "TunnelOut", Segment = "RidgeTunnel", Length = 40, Pitch = { -6.761, 0 }, Width = { 28, 28 }, Rails = { 6, 6 }, Roof = true },
			{ Name = "FinalTurnA", Segment = "FinalTurn", Kind = "Finish", Length = 45, Yaw = 45, Pitch = { 0, 0 }, Bank = { 0, 10 }, Width = { 28, 28 }, Rails = { 7, 4.5 } },
			{ Name = "FinalTurnB", Segment = "FinalTurn", Length = 45, Yaw = 45, Pitch = { 0, 0 }, Bank = { 10, 0 }, Width = { 28, 30 }, Rails = { 7, 4.5 } },
			{ Name = "MainStraight", Segment = "MainStraight", Kind = "Start", Length = 200, Pitch = { 0, 0 }, Width = { 30, 30 }, Rails = { 5, 5 }, Arrows = true },
		},
		Spawn = { Piece = "MainStraight", At = 152 },
		StartLine = { Piece = "LineExit", At = 0 },
		FinishLine = { Piece = "LineExit", At = 0 },
		Checkpoints = {
			{ Name = "Bowl A", Piece = "BowlAIn", At = 2 },
			{ Name = "Chicane", Piece = "ChicaneA", At = 2 },
			{ Name = "Passing", Piece = "PassingA", At = 4 },
			{ Name = "Vent Split", Piece = "VentSplitIn", At = 2 },
			{ Name = "Bowl B", Piece = "BowlBIn", At = 2 },
			{ Name = "Corridor", Piece = "Corridor", At = 6 },
			{ Name = "Brake Split", Piece = "BrakeSplitIn", At = 2 },
			{ Name = "Tunnel", Piece = "TunnelIn", At = 2 },
			{ Name = "Tunnel Top", Piece = "Tunnel", At = 280 },
			{ Name = "Final Turn", Piece = "FinalTurnA", At = 2 },
		},
		Grid = { Piece = "MainStraight", Rows = { 190, 183.5, 177, 170.5 }, Columns = { -9.3, -3.1, 3.1, 9.3 } },
		StartGate = { Piece = "MainStraight", At = 197, Height = 5 },
		Features = {},
		Hazards = {
			{ Kind = "Fan", Id = "Geyser1", Style = "Geyser", Piece = "VentStraight", From = 30, To = 200, Direction = 1, Accel = 22, OnSeconds = 1.4, OffSeconds = 2.4, TelegraphSeconds = 0.8 },
			{ Kind = "PulseBumper", Id = "RockA", Style = "Rock", Piece = "ChicaneB", At = 25, Offset = -5, Radius = 3, Height = 4.5 },
			{ Kind = "PulseBumper", Id = "RockB", Style = "Rock", Piece = "ChicaneD", At = 25, Offset = 5, Radius = 3, Height = 4.5, PhaseOffset = 1.4 },
			-- vent split: inside (left) one big vent to time | outside (right) three small ones
			{ Kind = "PulseBumper", Id = "VentBig", Style = "Rock", Piece = "VentSplit", At = 60, Offset = -9, Radius = 3.4, Height = 4.5 },
			{ Kind = "PulseBumper", Id = "VentS1", Style = "Rock", Piece = "VentSplit", At = 30, Offset = 7, Radius = 2.2, Height = 4.5, PhaseOffset = 0.5 },
			{ Kind = "PulseBumper", Id = "VentS2", Style = "Rock", Piece = "VentSplit", At = 62, Offset = 11, Radius = 2.2, Height = 4.5, PhaseOffset = 1.6 },
			{ Kind = "PulseBumper", Id = "VentS3", Style = "Rock", Piece = "VentSplit", At = 94, Offset = 7, Radius = 2.2, Height = 4.5, PhaseOffset = 2.7 },
			{ Kind = "Hammer", Id = "Piston1", Style = "Piston", Piece = "Corridor", At = 80, Amplitude = 8, Period = 3.2, HeadSize = 3.4 },
			{ Kind = "Conveyor", Id = "Magma1", Style = "Magma", Piece = "PassingB", From = 30, To = 110, Direction = -1, Accel = 16 },
			{ Kind = "Boost", Id = "Lift1", Piece = "TunnelIn", From = 14, To = 40, Offset = -6, Width = 13, Accel = 17 },
			{ Kind = "Boost", Id = "Lift2", Piece = "Tunnel", From = 0, To = 67, Offset = -6, Width = 13, Accel = 17 },
			{ Kind = "Boost", Id = "Lift3", Piece = "Tunnel", From = 67, To = 134, Offset = -6, Width = 13, Accel = 17 },
			{ Kind = "Boost", Id = "Lift4", Piece = "Tunnel", From = 134, To = 200, Offset = -6, Width = 13, Accel = 17 },
			{ Kind = "Boost", Id = "Lift5", Piece = "Tunnel", From = 200, To = 267, Offset = -6, Width = 13, Accel = 17 },
			{ Kind = "Boost", Id = "Lift6", Piece = "Tunnel", From = 267, To = 334, Offset = -6, Width = 13, Accel = 17 },
			{ Kind = "Boost", Id = "Lift7", Piece = "Tunnel", From = 334, To = 400, Offset = -6, Width = 13, Accel = 17 },
			{ Kind = "Boost", Id = "Lift9", Piece = "Tunnel", From = 400, To = 470, Offset = -6, Width = 13, Accel = 17 },
			{ Kind = "Boost", Id = "Lift8", Piece = "TunnelOut", From = 0, To = 26, Offset = -6, Width = 13, Accel = 17 },
		},
		ChaosGates = {
			{ Id = "Gate1", Piece = "BowlA", At = 75, Offset = -7, Width = 9 },
			{ Id = "Gate2", Piece = "PassingA", At = 30, Offset = 6, Width = 9 },
			{ Id = "Gate3", Piece = "PassingB", At = 20, Offset = -6, Width = 9 },
		},
		WarningStrips = {
			{ Piece = "BrakeSplitIn", From = 0, To = 20 },
		},
		Signs = {
			{ Piece = "VentStraight", At = 10, Text = "VENTS - WATCH THE GLOW", Lift = 9 },
			{ Piece = "BowlAIn", At = 0, Text = "BASALT BOWL", Lift = 9 },
			{ Piece = "VentSplitIn", At = 0, Text = "INSIDE: ONE BIG VENT  |  OUTSIDE: SMALL VENTS", Lift = 9 },
			{ Piece = "Corridor", At = 10, Text = "MAINTENANCE CORRIDOR - PISTON", Lift = 9 },
			{ Piece = "BrakeSplitIn", At = 0, Text = "INSIDE: BRAKE HARD  |  OUTSIDE: LONG EXIT", Lift = 9 },
			{ Piece = "TunnelIn", At = 10, Text = "RIDGE TUNNEL - BOOST LANE LEFT", Lift = 9 },
		},
		Gates = {
			{ Kind = "Start", Piece = "LineExit", At = 0, Text = "START  /  FINISH" },
		},
		Validation = { MinSegments = 10, MaxSegments = 16, MinLength = 2200, MaxLength = 3600 },
		ArrowSpacing = 18,
		MaxRaceSeconds = 480,
	}
end

TrackDefinitions.LegacyWorlds = { TrackDefinitions.NeonFoundry, TrackDefinitions.SkyCarnival, TrackDefinitions.VolcanoVault }
TrackDefinitions.Circuits = {
	NeonFoundry_A4 = TrackDefinitions.NeonFoundryCircuit,
	SkyCarnival_B1 = TrackDefinitions.SkyCarnivalCircuit,
	VolcanoVault_B1 = TrackDefinitions.VolcanoVaultCircuit,
}
TrackDefinitions.Worlds = {}
for _, legacy in ipairs(TrackDefinitions.LegacyWorlds) do
	local circuit = TrackDefinitions.CircuitRaces and TrackDefinitions.Circuits[legacy.Id] or nil
	TrackDefinitions.Worlds[#TrackDefinitions.Worlds + 1] = circuit or legacy
end
-- Can this map host a standard race right now? (circuits on: only maps with a circuit)
function TrackDefinitions.RaceReady(id)
	if not TrackDefinitions.CircuitRaces then
		return true
	end
	return TrackDefinitions.Circuits[id] ~= nil
end
-- The race track used by the round by default (the Neon Foundry). Training stays the A1 reference.
TrackDefinitions.Race = TrackDefinitions.Worlds[1]
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
-- Promo pack prompts 04 / 07: map hubs (gated until their lifecycle tests pass). Same contract
-- as the Garage: deck centre / in-radius / spawn ring / practice lane leaving toward +X.
-- Positions mirror the Garage's offset from the Foundry start (120 below, 320 behind it).
---------------------------------------------------------------------------------------------
TrackDefinitions.BalloonTerminal = {
	Center = Vector3.new(2600, 440, 320),
	Radius = 40, -- octagon in-radius
	FloorThickness = 2,
	RimHeight = 5,
	SpawnRingRadius = 16,
	SpawnSlots = 16,
	ChuteHeadingDeg = 90,
	Style = "Terminal",
	LandingTarget = { Piece = "LandingDeck", At = 8 }, -- where a clean drum bounce comes down (estimate)
}

TrackDefinitions.BalloonPractice = {
	Id = "BalloonPractice_P04",
	DisplayName = "Bounce Practice",
	LayoutVersion = 1,
	Origin = Vector3.new(2638, 440, 320),
	StartHeadingDeg = 90,
	FloorThickness = 1.6,
	RailThickness = 1.2,
	DefaultRails = { 4.5, 4.5 },
	MaxStepLength = 24,
	MaxYawStepDeg = 5,
	MaxPitchStepDeg = 2,
	MaxBankStepDeg = 3,
	Theme = TrackDefinitions.SkyCarnival.Theme,
	Pieces = {
		{ Name = "ChuteLip", Segment = "Lip", Length = 8, Pitch = { 0, 0 }, Width = { 22, 22 } },
		{ Name = "CanvasRamp", Segment = "Ramp", Length = 50, Pitch = { 0, 6 }, Width = { 22, 24 }, Arrows = true },
		{ Name = "DrumApproach", Segment = "Drum", Length = 16, Pitch = { 6, 3 }, Width = { 24, 26 } },
		{ Name = "DrumZone", Segment = "Drum", Length = 30, Pitch = { 3, 2 }, Width = { 26, 26 }, Rails = { 6, 6 } },
		{ Name = "LandingDeck", Segment = "Landing", Length = 50, Pitch = { 2, 2 }, Width = { 26, 26 }, Rails = { 7, 7 } },
		{ Name = "ChuteBasin", Segment = "Basin", Length = 26, Pitch = { 2, -3 }, Width = { 26, 28 }, Rails = { 6, 6 }, EndCap = true },
	},
	Spawn = { Piece = "ChuteLip", At = 2 },
	StartLine = { Piece = "ChuteLip", At = 8 },
	FinishLine = { Piece = "ChuteBasin", At = 10 }, -- crossing it returns the marble to the hub
	Hazards = {
		{ Kind = "Trampoline", Id = "PracticeDrum", Style = "Drum", Piece = "DrumZone", At = 10, Offset = 0, Width = 14, Length = 8, UpDeltaV = 36 },
	},
	Signs = {
		{ Piece = "ChuteLip", At = 4, Text = "BOUNCE PRACTICE", Lift = 9 },
		{ Piece = "DrumApproach", At = 2, Text = "DRUM - LAND ON THE TARGET", Lift = 9 },
	},
	Validation = { MinSegments = 3, MaxSegments = 6, MinLength = 100, MaxLength = 400 },
	ArrowSpacing = 14,
}

TrackDefinitions.BasaltDeck = {
	Center = Vector3.new(-2600, 320, 320),
	Radius = 40, -- hexagon in-radius
	FloorThickness = 2,
	RimHeight = 5,
	SpawnRingRadius = 16,
	SpawnSlots = 16,
	ChuteHeadingDeg = 90,
	Style = "Basalt",
}

TrackDefinitions.BasaltPractice = {
	Id = "BasaltPractice_P04",
	DisplayName = "Piston Practice",
	LayoutVersion = 1,
	Origin = Vector3.new(-2562, 320, 320),
	StartHeadingDeg = 90,
	FloorThickness = 1.6,
	RailThickness = 1.2,
	DefaultRails = { 4.5, 4.5 },
	MaxStepLength = 24,
	MaxYawStepDeg = 5,
	MaxPitchStepDeg = 2,
	MaxBankStepDeg = 3,
	Theme = TrackDefinitions.VolcanoVault.Theme,
	Pieces = {
		{ Name = "ChuteLip", Segment = "Lip", Length = 8, Pitch = { 0, 0 }, Width = { 22, 22 } },
		{ Name = "InspectionRamp", Segment = "Ramp", Length = 40, Pitch = { 0, 5 }, Width = { 22, 22 }, Arrows = true },
		{ Name = "PistonLane", Segment = "Piston", Length = 50, Pitch = { 5, 3 }, Width = { 22, 22 }, Rails = { 6, 6 } },
		{ Name = "BrakeStraight", Segment = "Brake", Length = 40, Pitch = { 3, 2 }, Width = { 22, 22 }, Arrows = true },
		{ Name = "ShortDrop", Segment = "Drop", Length = 24, Pitch = { 2, 10 }, Width = { 22, 22 }, Rails = { 7, 7 } },
		{ Name = "DropEase", Segment = "Drop", Length = 20, Pitch = { 10, 3 }, Width = { 22, 22 }, Rails = { 7, 7 } },
		{ Name = "ChuteBasin", Segment = "Basin", Length = 26, Pitch = { 3, -3 }, Width = { 22, 26 }, Rails = { 6, 6 }, EndCap = true },
	},
	Spawn = { Piece = "ChuteLip", At = 2 },
	StartLine = { Piece = "ChuteLip", At = 8 },
	FinishLine = { Piece = "ChuteBasin", At = 10 },
	Hazards = {
		{ Kind = "Hammer", Id = "DemoPiston", Style = "Piston", Piece = "PistonLane", At = 25, Amplitude = 6, Period = 4.6, HeadSize = 3.4 },
	},
	Signs = {
		{ Piece = "ChuteLip", At = 4, Text = "PISTON PRACTICE", Lift = 9 },
		{ Piece = "PistonLane", At = 2, Text = "SLOW PISTON - WATCH THE CYCLE", Lift = 9 },
		{ Piece = "BrakeStraight", At = 4, Text = "BRAKE BEFORE THE DROP", Lift = 9 },
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
	local closureError = nil
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

	-- Closed circuits (2026-11-26 three-lap brief): the authored pieces end where they began.
	-- The closure is solved offline (tools/offline/circuit_solver.lua) to a few hundredths of a
	-- stud; the tiny residual of the numeric walk is spread over the last piece so the ribbon
	-- meets its own start exactly (no step at the start/finish line).
	if def.Loop then
		local first, last = sections[1], sections[#sections]
		local residual = last.Position - first.Position
		closureError = residual.Magnitude
		local fromIndex = #sections
		for i = #sections, 1, -1 do
			if sections[i].PieceIndex ~= #def.Pieces then
				break
			end
			fromIndex = i
		end
		local h0, h1 = sections[fromIndex].H, last.H
		for i = fromIndex, #sections do
			local u = (h1 > h0) and (sections[i].H - h0) / (h1 - h0) or 1
			sections[i].Position = sections[i].Position - residual * u
		end
		last.Position = first.Position
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
		Route = { points = routePoints, cumulative = cumulative, total = cumulative[#cumulative], loop = def.Loop == true },
		TotalH = h,
		Loop = def.Loop == true,
		ClosureError = closureError or 0,
	}
	if layout.Loop then
		layout.LapLength = layout.Route.total
		layout.Laps = def.Laps or 3
	end

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

	-- B2 Grapple Spark anchors: every GrappleSpacing studs of route (after the start, before the
	-- finish straight), floating GrappleHeight above the lane centre. Generated, never hand-placed,
	-- so every world gets them. The server only lets a grapple reach an anchor before the next
	-- checkpoint (no slingshot past a checkpoint).
	layout.GrappleAnchors = {}
	do
		local spacing, height = def.GrappleSpacing or 150, def.GrappleHeight or 10
		local fromS = (layout.StartLineS or 0) + 120
		local toS = (layout.Loop and layout.LapLength or layout.FinishLineS or layout.Route.total) - 80
		local h = 0
		for _, sec in ipairs(layout.Sections) do
			if sec.S >= fromS and sec.S <= toS and sec.S >= h then
				layout.GrappleAnchors[#layout.GrappleAnchors + 1] = { S = sec.S, Position = sec.Position + sec.Up * height, Index = #layout.GrappleAnchors + 1 }
				h = sec.S + spacing
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

	-- Laps: the start/finish line is S = 0 of the lap; a lap restart respawns just past it.
	if layout.Loop and layout.StartLineFrame then
		layout.LineRespawnFrame = TrackDefinitions.SampleAtH(layout, layout.StartLineFrame.H + 6)
		-- finisher deck: a flat pad beside the line where finished marbles wait (off the road)
		local f = TrackDefinitions.SampleAtH(layout, layout.StartLineFrame.H + 20)
		local side = (def.FinisherDeckSide or 1)
		local flatRight = Vector3.new(f.Right.X, 0, f.Right.Z).Unit
		local flatForward = Vector3.new(f.Forward.X, 0, f.Forward.Z).Unit
		layout.FinisherDeck = {
			Position = f.Position + flatRight * side * (f.Width / 2 + 34) - Vector3.new(0, 2, 0),
			Forward = flatForward,
			Right = flatRight,
			Up = Vector3.new(0, 1, 0),
			Size = Vector3.new(36, 1.6, 44),
		}
	end
	layout.Targets = TrackDefinitions.Targets(layout)

	return layout
end

-- The ordered list a racer must cross, as distances along the WHOLE race ("race S"):
-- a linear course = its checkpoints then the finish; a circuit = for every lap its checkpoints,
-- then the start/finish line (a lap) and, after the last lap, the finish. Race S of lap k =
-- (k - 1) * LapLength + lap S, so the same ordered/swept-crossing rules judge laps too: the
-- grid is behind the line (negative race S), a backwards crossing never matches the next
-- target, and a skipped gate leaves the next target unconfirmed.
function TrackDefinitions.Targets(layout, laps)
	local out = {}
	if not layout.Loop then
		for i, cp in ipairs(layout.Checkpoints or {}) do
			out[#out + 1] = { Kind = "Checkpoint", Lap = 1, Checkpoint = i, S = cp.S, RespawnFrame = cp.RespawnFrame, Name = cp.Name }
		end
		out[#out + 1] = { Kind = "Finish", Lap = 1, S = layout.FinishLineS }
	else
		laps = laps or layout.Laps or 1
		local L = layout.LapLength
		for lap = 1, laps do
			local base = (lap - 1) * L
			for i, cp in ipairs(layout.Checkpoints or {}) do
				out[#out + 1] = { Kind = "Checkpoint", Lap = lap, Checkpoint = i, S = cp.S and (base + cp.S), RespawnFrame = cp.RespawnFrame, Name = cp.Name }
			end
			out[#out + 1] = { Kind = lap < laps and "Lap" or "Finish", Lap = lap, S = lap * L, RespawnFrame = layout.LineRespawnFrame }
		end
	end
	for i, t in ipairs(out) do
		t.Index = i
	end
	return out
end

-- Lap state from a count of confirmed targets (HUD + standings): lap (1-based, capped at laps),
-- checkpoint within the lap, checkpoints per lap.
function TrackDefinitions.LapState(layout, confirmed, laps)
	local per = #(layout.Checkpoints or {})
	if not layout.Loop then
		return 1, math.min(confirmed, per), per, 1
	end
	laps = laps or layout.Laps or 1
	local stride = per + 1
	local lap = math.floor(confirmed / stride) + 1
	local cp = confirmed % stride
	if lap > laps then
		return laps, per, per, laps
	end
	return lap, cp, per, laps
end

-- Lap-local S (0 .. LapLength) of a race S on a circuit; identity on a linear course.
function TrackDefinitions.LapS(layout, raceS)
	if not layout.Loop or not raceS then
		return raceS
	end
	local L = layout.LapLength
	return raceS - math.floor(raceS / L) * L
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
	local loop = layout.Loop == true
	local lapLength = layout.LapLength or layout.Route.total
	if loop then
		-- a circuit closes on itself: position, heading, pitch, bank and width all match
		if (layout.ClosureError or 0) > 1.0 then
			fail(string.format("circuit does not close (%.2f studs off) - re-run tools/offline/circuit_solver.lua", layout.ClosureError))
		end
		local yawSum = 0
		for _, piece in ipairs(def.Pieces) do
			yawSum = yawSum + (piece.Yaw or 0)
		end
		-- a whole number of turns: 360 for a plain loop, 720 when a stacked helix adds one
		local turns = math.abs(yawSum) / 360
		if turns < 0.99 or math.abs(turns - math.floor(turns + 0.5)) > 0.01 / 360 then
			fail(string.format("circuit turns %.2f degrees in total (must be a whole number of turns)", yawSum))
		end
		local p1, pn = def.Pieces[1], def.Pieces[#def.Pieces]
		for _, key in ipairs({ "Pitch", "Bank", "Width" }) do
			local a = pieceValue(p1, key, key == "Width" and { 22, 22 } or { 0, 0 })
			local b = pieceValue(pn, key, key == "Width" and { 22, 22 } or { 0, 0 })
			if math.abs(a[1] - b[2]) > 0.01 then
				fail("circuit " .. key .. " does not match across the start/finish line")
			end
		end
		if p1.StartCap or pn.EndCap then
			fail("a circuit has no start back wall or finish end wall")
		end
		if layout.SpawnFrame and layout.SpawnFrame.S < lapLength - 120 then
			fail("circuit spawn must be on the main straight behind the line")
		end
	elseif layout.SpawnFrame and layout.StartLineS and layout.SpawnFrame.S >= layout.StartLineS then
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
	if loop then
		if previous > lapLength - diameter * 5 then
			fail("the last checkpoint must leave room before the start/finish line")
		end
	elseif layout.FinishLineS and layout.FinishLineS <= previous then
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
	if loop then
		for i, slot in ipairs(layout.GridSlots) do
			if slot.Frame.S < lapLength - 80 then
				fail("grid slot " .. i .. " must be on the main straight just behind the line")
			end
		end
	else
		if layout.StartGateFrame and layout.StartLineS and layout.StartGateFrame.S > layout.StartLineS then
			fail("start gate must be on or before the start line")
		end
		if layout.FinishLineS and layout.FinishLineS >= layout.Route.total - diameter * 2 then
			fail("finish line needs a run-off area after it")
		end
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
			elseif hz.Kind == "Boost" then
				-- assisted ascent: a visible forward push that roughly cancels a climb (never a launcher)
				if not d.Accel or d.Accel <= 0 or d.Accel > 30 then
					fail("boost " .. tostring(hz.Id) .. " accel must be 0-30 studs/s^2")
				end
				if not hz.Length or hz.Length > 70 then
					fail("boost " .. tostring(hz.Id) .. " strips are at most 70 studs (they follow the road in short pieces)")
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
			local apart = secs[j].S - secs[i].S
			if loop then
				apart = math.min(apart, lapLength - apart) -- around the line the lap meets itself
			end
			if apart > 80 then
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

-- Lap-time MODEL for a circuit (same 1-D rolling model as below, plus boost strips): a standing
-- start from the grid, then a flying lap. Returns standingLap, flyingLap, raceSeconds(laps).
-- Not a measurement - real times come from phone playtests.
function TrackDefinitions.EstimateLapSeconds(layout, movement, gravity, laps)
	gravity = gravity or 196.2
	laps = laps or layout.Laps or 3
	local rollFactor = 5 / 7
	local sections = layout.Sections
	local boosts = {}
	for _, hz in ipairs(layout.Hazards or {}) do
		if hz.Kind == "Boost" and hz.FromFrame then
			boosts[#boosts + 1] = { a = hz.FromFrame.S, b = hz.ToFrame.S, accel = hz.Definition.Accel or 0 }
		end
	end
	local v = 0.1
	local function run(fromS, toS)
		local t = 0
		for i = 1, #sections - 1 do
			local a, b = sections[i], sections[i + 1]
			local ds = b.S - a.S
			if b.S > fromS and a.S < toS and ds > 0 then
				local sinPitch = math.sin(rad((a.PitchDeg + b.PitchDeg) / 2))
				local throttle = 0
				if v < movement.ThrottleTargetSpeed then
					throttle = movement.AlongTrackAccel * math.min(1, (movement.ThrottleTargetSpeed - v) / movement.ThrottleTaperRange)
				end
				local boost = 0
				for _, bz in ipairs(boosts) do
					if a.S >= bz.a and a.S < bz.b then
						boost = boost + bz.accel
					end
				end
				local resist = (movement.RollingResistance or 0) + movement.LinearDrag * v
				local accel = rollFactor * gravity * sinPitch + throttle + boost - resist
				if v > movement.TerminalSpeed then
					accel = accel - math.min(movement.TerminalDragMax, (v - movement.TerminalSpeed) * movement.TerminalDragResponse)
				end
				local vNext = math.sqrt(math.max(1, v * v + 2 * accel * ds))
				t = t + ds / ((v + vNext) / 2)
				v = vNext
			end
		end
		return t
	end
	if not layout.Loop then
		local t = run(layout.StartLineS or 0, layout.FinishLineS or layout.Route.total)
		return t, t, t
	end
	local L = layout.LapLength
	local grid = layout.GridSlots[1] and layout.GridSlots[1].Frame.S or (L - 20)
	local lead = run(grid, L) -- grid to the line (the clock starts at GO, so this counts too)
	local standing = run(0, L)
	local flying = run(0, L)
	return standing + lead, flying, lead + standing + flying * (laps - 1)
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
