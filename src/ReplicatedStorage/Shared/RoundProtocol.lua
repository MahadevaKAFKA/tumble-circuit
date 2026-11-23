--[[
	RoundProtocol — the complete A2 network contract (pure module: no services).

	One "Remotes" folder (TumbleRemotes) is created by the SERVER from this table. Clients never
	create remotes. Every client->server remote has a payload schema, a per-player rate limit, and
	is re-validated against round state on the server. The client never sends a checkpoint index,
	finish, time or placement: those are observed by the server.

	Remote                Direction        Payload
	RequestSnapshot       client->server   (none)              resend the current snapshot
	RequestRecover        client->server   (none)              hold-to-recover finished (1 s)
	RequestJoinRace       client->server   (boolean)           true = race next round / play again
	RoundSnapshot         server->client   snapshot table      on join, transitions, standings
	CheckpointFeedback    server->client   {roundId, index, total, serverTime}
	FinishNotice          server->client   {roundId, userId, name, place, seconds}
]]

local RoundProtocol = {}

RoundProtocol.Version = 2
RoundProtocol.FolderName = "TumbleRemotes"

RoundProtocol.Remotes = {
	RequestSnapshot = { Direction = "ClientToServer", Args = {}, MinInterval = 1.0 },
	RequestRecover = { Direction = "ClientToServer", Args = {}, MinInterval = 0.5 },
	RequestJoinRace = { Direction = "ClientToServer", Args = { "boolean" }, MinInterval = 0.3 },
	RoundSnapshot = { Direction = "ServerToClient" },
	CheckpointFeedback = { Direction = "ServerToClient" },
	FinishNotice = { Direction = "ServerToClient" },
}

RoundProtocol.States = {
	Boot = "Boot",
	Lobby = "Lobby",
	Intermission = "Intermission",
	Preparing = "Preparing",
	Countdown = "Countdown",
	Racing = "Racing",
	Results = "Results",
	Cleanup = "Cleanup",
}

local S = RoundProtocol.States
-- Allowed transitions. Anything else is refused (and logged) by RoundService.
RoundProtocol.Transitions = {
	[S.Boot] = { [S.Lobby] = true },
	[S.Lobby] = { [S.Intermission] = true },
	[S.Intermission] = { [S.Preparing] = true, [S.Lobby] = true },
	[S.Preparing] = { [S.Countdown] = true, [S.Cleanup] = true },
	[S.Countdown] = { [S.Racing] = true, [S.Cleanup] = true },
	[S.Racing] = { [S.Results] = true, [S.Cleanup] = true },
	[S.Results] = { [S.Cleanup] = true },
	[S.Cleanup] = { [S.Intermission] = true, [S.Lobby] = true },
}

function RoundProtocol.CanTransition(from, to)
	local allowed = RoundProtocol.Transitions[from]
	return allowed ~= nil and allowed[to] == true
end

-- Validate a client->server payload. Returns ok, reason.
function RoundProtocol.ValidateArgs(remoteName, ...)
	local spec = RoundProtocol.Remotes[remoteName]
	if not spec or spec.Direction ~= "ClientToServer" then
		return false, "unknown or server-only remote"
	end
	local count = select("#", ...)
	if count ~= #spec.Args then
		return false, string.format("expected %d argument(s), got %d", #spec.Args, count)
	end
	for i, expected in ipairs(spec.Args) do
		local value = select(i, ...)
		if type(value) ~= expected then
			return false, string.format("argument %d must be %s", i, expected)
		end
	end
	return true
end

--[[ Snapshot shape (server -> client), all fields plain data:
	{
	  v = Version, roundId = number, state = States.*, stateSeq = number (increments per transition),
	  stateStartedAt = serverTime, stateEndsAt = serverTime or nil,
	  raceStartedAt = serverTime or nil, trackId = string,
	  checkpointTotal = number,
	  racers = { { userId, name, place, checkpoint, finished, seconds?, dnf, isBot } ... }  -- standings order
	  queued = { [tostring(userId)] = true }, humanCount = number,
	}
]]

return RoundProtocol
