--[[
	Protocol — shared instance names, zones and replicated attribute names.
	Network remotes, payload schemas and round states live in RoundProtocol (A2).
	Clients can never pick a spawn position: every respawn location is chosen by the server.
]]

local Protocol = {}

-- Remotes themselves are defined in RoundProtocol (A2).
Protocol.MarblesFolderName = "TumbleMarbles"
Protocol.MarbleNamePrefix = "Marble_" -- + Player.UserId
Protocol.CourseModelName = "TrainingCourse"
Protocol.HubModelName = "OrbitalGarage"

-- Which course a marble is on. Stored as the "Zone" attribute on the ball itself, set before it
-- is parented, so a client always knows which route to use the moment the ball arrives.
Protocol.Zones = {
	Hub = "Hub",
	Race = "Race",
}

-- Attributes on the Player instance.
Protocol.PlayerAttributes = {
	SpawnCount = "TC_SpawnCount",
	LastSpawnReason = "TC_LastSpawnReason",
}

-- Attributes on the marble Part.
Protocol.BallAttributes = {
	OwnerUserId = "OwnerUserId",
	Zone = "Zone",
	Protected = "Protected", -- true while spawn-protected (no marble collisions)
	Frozen = "Frozen", -- true while anchored on the grid before GO
}

-- Attributes on Workspace.
Protocol.WorkspaceAttributes = {
	CourseReady = "TC_CourseReady",
	CourseError = "TC_CourseError",
}

Protocol.SpawnReasons = {
	Join = "Join",
	Reset = "Reset", -- manual hold-to-recover
	Fell = "Fell",
	Lost = "Lost",
	Grid = "Grid", -- placed on the start grid for a round
	ToHub = "ToHub", -- round over / practice chute loop
	Movement = "Movement", -- server rejected implausible movement
}

function Protocol.MarbleName(userId)
	return Protocol.MarbleNamePrefix .. tostring(userId)
end

return Protocol
