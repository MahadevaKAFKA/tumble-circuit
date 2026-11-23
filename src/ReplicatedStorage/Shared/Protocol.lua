--[[
	Protocol — the complete A1 client/server contract.

	Remotes (created once by the server, never by clients):
	  RequestReset  client -> server, NO payload. Server rate-limits and respawns the marble at the
	                server-chosen start spawn. Clients can never pick a position (no teleport exploit).

	Everything else flows server -> client as replicated Attributes (snapshot semantics: a late or
	re-joining client reads the current value; nothing depends on catching a one-off event).
]]

local Protocol = {}

Protocol.RemotesFolderName = "TumbleRemotes"
Protocol.Remotes = {
	RequestReset = "RequestReset",
}

Protocol.MarblesFolderName = "TumbleMarbles"
Protocol.MarbleNamePrefix = "Marble_" -- + Player.UserId
Protocol.CourseModelName = "TrainingCourse"

Protocol.RunStates = {
	Ready = "Ready", -- on the start pad, timer not started
	Running = "Running", -- crossed the start line
	Finished = "Finished", -- crossed the finish line with all marks
}

-- Attributes on the Player instance.
Protocol.PlayerAttributes = {
	RunState = "TC_RunState",
	RunStartServerTime = "TC_RunStartServerTime", -- workspace:GetServerTimeNow() at start line
	LastRunSeconds = "TC_LastRunSeconds",
	BestSeconds = "TC_BestSeconds", -- session best (no persistence in A1)
	LastRunWasBest = "TC_LastRunWasBest",
	SpawnCount = "TC_SpawnCount",
	LastSpawnReason = "TC_LastSpawnReason", -- "Join" | "Reset" | "Fell" | "Lost"
}

-- Attributes on Workspace.
Protocol.WorkspaceAttributes = {
	CourseReady = "TC_CourseReady",
	CourseError = "TC_CourseError",
}

Protocol.SpawnReasons = {
	Join = "Join",
	Reset = "Reset",
	Fell = "Fell",
	Lost = "Lost",
}

function Protocol.MarbleName(userId)
	return Protocol.MarbleNamePrefix .. tostring(userId)
end

return Protocol
