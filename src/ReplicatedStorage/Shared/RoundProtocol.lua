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
	A3:
	RequestAbility        client->server   (slot 1|2)          server looks up the equipped ability
	RequestTrick          client->server   (none)              judged against server takeoff/landing
	RequestEquip          client->server   (slot 1|2, id)      only outside an active race
	AbilityState / AbilityOutcome / EffectState / ApplyImpulse / SkillEvent   server->client
	A4:
	ChaosGateVFX          server->client   {userId, gateId, tier, label, place, count}
	RequestReady          client->server   (boolean)           READY vote; only counted while the
	                                                            race is full during Intermission
	Snapshot adds queuedCount, raceCapacity, readyOpen, readyCount, ready = {[tostring(userId)]=true}.
	Snapshot adds hazardSeed (0..2) and hazardEpoch (server time of GO) so every machine
	evaluates the same deterministic hazard state; racers[i].isBot marks [BOT] entries.
	A5:
	RequestSettings       client->server   (key, value) strings  one setting; sanitized by PlayerDataSchema
	ReportActive          client->server   (roundId)           "I gave real input this race" (AFK guard only)
	ProfileState          server->client   level/xp/coins/records/settings/loadout + honest save status
	RewardNotice          server->client   one race's Coins/XP breakdown (granted once per raceId)
	DevCommand / DevResult  Studio or authorized test accounts ONLY: the remotes are not even
	                      created on a live server unless GameConfig.Dev.AuthorizedUserIds is set.
	RequestEquip (A3) is the starter-ability equip request; the server refuses it mid-race.
	There is NO remote that grants Coins/XP, sets a time, a best time or a placement.
]]

local RoundProtocol = {}

RoundProtocol.Version = 5
RoundProtocol.FolderName = "TumbleRemotes"

RoundProtocol.Remotes = {
	RequestSnapshot = { Direction = "ClientToServer", Args = {}, MinInterval = 1.0 },
	RequestRecover = { Direction = "ClientToServer", Args = {}, MinInterval = 0.5 },
	RequestJoinRace = { Direction = "ClientToServer", Args = { "boolean" }, MinInterval = 0.3 },
	RoundSnapshot = { Direction = "ServerToClient" },
	CheckpointFeedback = { Direction = "ServerToClient" },
	FinishNotice = { Direction = "ServerToClient" },
	-- A3
	RequestAbility = { Direction = "ClientToServer", Args = { { type = "number", oneOf = { 1, 2 } } }, MinInterval = 0.15 },
	RequestTrick = { Direction = "ClientToServer", Args = {}, MinInterval = 0.1 },
	RequestEquip = { Direction = "ClientToServer", Args = { { type = "number", oneOf = { 1, 2 } }, { type = "string", maxLength = 16 } }, MinInterval = 0.2 },
	AbilityState = { Direction = "ServerToClient" }, -- to owner: loadout, owned, cooldown end times
	AbilityOutcome = { Direction = "ServerToClient" }, -- to all: who used what (VFX), targets, blocks
	EffectState = { Direction = "ServerToClient" }, -- to owner: active speed modifiers + shield
	ApplyImpulse = { Direction = "ServerToClient" }, -- to a target: server-approved bounded nudge
	SkillEvent = { Direction = "ServerToClient" }, -- to owner: trick/slipstream/near-miss/charge feedback
	-- A4
	ChaosGateVFX = { Direction = "ServerToClient" }, -- to all: someone collected a Chaos Gate surge
	-- READY vote (owner request 2026-11-25)
	RequestReady = { Direction = "ClientToServer", Args = { "boolean" }, MinInterval = 0.3 },
	-- A5
	RequestSettings = { Direction = "ClientToServer", Args = { { type = "string", maxLength = 16 }, { type = "string", maxLength = 16 } }, MinInterval = 0.15 },
	ReportActive = { Direction = "ClientToServer", Args = { { type = "number", min = 0, max = 2 ^ 31, integer = true } }, MinInterval = 2 },
	ProfileState = { Direction = "ServerToClient" },
	RewardNotice = { Direction = "ServerToClient" },
	DevCommand = { Direction = "ClientToServer", Args = { { type = "string", maxLength = 24 }, { type = "number", min = -1, max = 100000, integer = true } }, MinInterval = 0.3, StudioOnly = true },
	DevResult = { Direction = "ServerToClient", StudioOnly = true },
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
		local rule = type(expected) == "table" and expected or { type = expected }
		if type(value) ~= rule.type then
			return false, string.format("argument %d must be %s", i, rule.type)
		end
		if rule.type == "number" and (value ~= value or value == math.huge or value == -math.huge) then
			return false, string.format("argument %d is not a finite number", i)
		end
		if rule.oneOf then
			local found = false
			for _, allowed in ipairs(rule.oneOf) do
				if value == allowed then
					found = true
				end
			end
			if not found then
				return false, string.format("argument %d not an allowed value", i)
			end
		end
		if rule.min and (value < rule.min or (rule.max and value > rule.max)) then
			return false, string.format("argument %d out of range", i)
		end
		if rule.integer and value % 1 ~= 0 then
			return false, string.format("argument %d must be a whole number", i)
		end
		if rule.maxLength and #value > rule.maxLength then
			return false, string.format("argument %d too long", i)
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
