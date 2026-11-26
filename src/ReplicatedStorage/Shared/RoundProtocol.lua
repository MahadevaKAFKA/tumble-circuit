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
	A6:
	CastSpectatorVote     client->server   (pollId, option 1|2)  only non-racing humans; once per poll
	VoteState             server->client   Open / Voted / Result (+modifier timestamps) / NoVotes / Closed
	QuickEmote            client->server   (id 1|2|3)          preset bubbles only, 5 s server cooldown
	EmoteShown            server->client   {userId, id}
	B1 (v7):
	RequestMapVote        client->server   (option 1..3)       map vote, first 8 s of Intermission, >= 2 humans
	RequestTimeTrial      client->server   (boolean)           start (true) / quit (false) a solo Time Trial
	TimeTrialState        server->client   {phase, ...}        to the runner only
	GhostPath             server->client   {key, seconds, hz, points}  the runner's own PB ghost
	Snapshot adds worldId, nextWorldId, mapVote = {open, endsAt, options, counts},
	party = {available, tags = {[tostring(userId)] = group}, maxSize}.
	B2 (v8):
	RequestUnlockAbility  client->server   (abilityId)         unlock by level (free) or earned Coins
	AbilityState adds owned (all twelve possible) and practice (hub try-it set);
	EffectState adds statuses = {{kind, endsAt, ...}} (GravityGlide, Anchor, Phase, BounceBurst,
	Chilled); ApplyImpulse adds source and cap.
	B3 (v9): CosmeticState, RequestEquipCosmetic(kind, id, slot), RequestFavorite(id, on),
	QuestState, RequestQuestClaim(scope, index), RequestLeaderboard(kind, worldId, seedClass),
	LeaderboardData, ProgressionNotice; EmoteShown adds emoteId (the slot's equipped emote).
	C (v10): CapsuleState, RequestCapsuleState, RequestOpenCapsule(requestId, oddsVersion,
	epicMisses, legendaryMisses) - the counters the player saw; a mismatch is refused -,
	CapsuleResult, RequestShardBuy(id), SeasonState, RequestSeasonClaim(level).
	D (v11): ShopState, RequestShopState, RequestPremiumClaim(level). Purchases themselves are
	Roblox prompts; grants happen only in ProcessReceipt / verified Game Pass ownership.
	Snapshot adds chaosModifier = {kind, startsAt, endsAt} while a voted modifier is pending/active.
	Promo pack 03 (v12): RequestMapVote is replaced by ballots and personal destinations.
	RequestBallot         client->server   (mapIndex, epoch, seq)  vote for the next race; latest
	                                       valid ballot counts; stale epoch / old seq ignored
	RequestDestination    client->server   (hubIndex, mode 1 Visit | 2 Practice)  personal hub
	DestinationResult     server->client   {ok, reason, hubIndex, mode}  to the requester only
	Snapshot: mapVote is gone; ballot = {epoch, maps = {mapId...}, counts, choices = {[userId] =
	mapIndex}, counted}; nextWorldId = the map leading right now (or the rotation pick).
]]

local RoundProtocol = {}

RoundProtocol.Version = 16 -- v16 (2026-11-26 ranked/challenges): RequestRankedOptIn/RankState, RequestChallenge/ChallengeState
-- v15: v15 (2026-11-26 economy): Milestone quest claims, RequestOpenCapsule + price seen (v14: RequestCapsuleSeen)
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
	-- A6
	CastSpectatorVote = { Direction = "ClientToServer", Args = { { type = "number", min = 1, max = 2 ^ 31, integer = true }, { type = "number", oneOf = { 1, 2 } } }, MinInterval = 0.3 },
	VoteState = { Direction = "ServerToClient" },
	QuickEmote = { Direction = "ClientToServer", Args = { { type = "number", oneOf = { 1, 2, 3 } } }, MinInterval = 0.5 },
	EmoteShown = { Direction = "ServerToClient" },
	-- B1
	-- prompt 03: ballots + personal destinations (replace B1's RequestMapVote)
	RequestBallot = { Direction = "ClientToServer", Args = { { type = "number", min = 1, max = 16, integer = true }, { type = "number", min = 0, max = 1000000000, integer = true }, { type = "number", min = 1, max = 1000000000, integer = true } }, MinInterval = 0.25 },
	RequestDestination = { Direction = "ClientToServer", Args = { { type = "number", min = 1, max = 16, integer = true }, { type = "number", min = 1, max = 2, integer = true } }, MinInterval = 0.5 },
	DestinationResult = { Direction = "ServerToClient" },
	RequestTimeTrial = { Direction = "ClientToServer", Args = { "boolean" }, MinInterval = 1.0 },
	TimeTrialState = { Direction = "ServerToClient" }, -- to owner: Countdown / Running / Checkpoint / Finished / Ended / Refused
	GhostPath = { Direction = "ServerToClient" }, -- to owner: their PB ghost for this world + variation
	-- B2
	RequestUnlockAbility = { Direction = "ClientToServer", Args = { { type = "string", maxLength = 16 } }, MinInterval = 0.5 },
	-- B3
	CosmeticState = { Direction = "ServerToClient" }, -- owner: owned / equipped / favorites / claimed level rewards
	RequestEquipCosmetic = { Direction = "ClientToServer", Args = { { type = "string", maxLength = 8 }, { type = "string", maxLength = 40 }, { type = "number", min = 0, max = 3, integer = true } }, MinInterval = 0.25 },
	RequestFavorite = { Direction = "ClientToServer", Args = { { type = "string", maxLength = 40 }, "boolean" }, MinInterval = 0.2 },
	QuestState = { Direction = "ServerToClient" },
	RequestQuestClaim = { Direction = "ClientToServer", Args = { { type = "string", maxLength = 9 }, { type = "number", min = 1, max = 12, integer = true } }, MinInterval = 0.4 }, -- v15: "Milestone" scope
	RequestLeaderboard = { Direction = "ClientToServer", Args = { { type = "string", maxLength = 8 }, { type = "string", maxLength = 40 }, { type = "number", min = 0, max = 2, integer = true } }, MinInterval = 1.0 },
	LeaderboardData = { Direction = "ServerToClient" },
	ProgressionNotice = { Direction = "ServerToClient" }, -- owner: LevelReward / QuestDone / QuestClaimed / Denied
	-- C (earned only: no Robux anywhere in C)
	CapsuleState = { Direction = "ServerToClient" },
	RequestCapsuleState = { Direction = "ClientToServer", Args = {}, MinInterval = 0.5 },
	RequestOpenCapsule = { Direction = "ClientToServer", Args = { { type = "string", maxLength = 40 }, { type = "number", min = 0, max = 99, integer = true }, { type = "number", min = 0, max = 99, integer = true }, { type = "number", min = 0, max = 99, integer = true }, { type = "string", maxLength = 12 }, { type = "number", min = 0, max = 100000, integer = true } }, MinInterval = 1.6 }, -- v15: + the price you saw
	CapsuleResult = { Direction = "ServerToClient" },
	-- v14: the reveal of a saved result was shown (display bookkeeping only: grants nothing)
	RequestCapsuleSeen = { Direction = "ClientToServer", Args = { { type = "string", maxLength = 40 } }, MinInterval = 0.25 },
	RequestShardBuy = { Direction = "ClientToServer", Args = { { type = "string", maxLength = 40 } }, MinInterval = 0.5 },
	SeasonState = { Direction = "ServerToClient" },
	RequestSeasonClaim = { Direction = "ClientToServer", Args = { { type = "number", min = 1, max = 30, integer = true } }, MinInterval = 0.3 },
	-- D (optional shop; every product id nil until the owner configures it)
	ShopState = { Direction = "ServerToClient" },
	-- v16: opt-in Ranked test (boolean = wants ranked); RankState = rating / tier / last delta / wait note
	RequestRankedOptIn = { Direction = "ClientToServer", Args = { "boolean" }, MinInterval = 1.0 },
	RankState = { Direction = "ServerToClient" },
	-- v16: challenges (id, action: "start" | "retry" | "quit" | "code") and their state / results
	RequestChallenge = { Direction = "ClientToServer", Args = { { type = "string", maxLength = 40 }, { type = "string", maxLength = 12 } }, MinInterval = 0.5 },
	ChallengeState = { Direction = "ServerToClient" },
	RequestShopState = { Direction = "ClientToServer", Args = {}, MinInterval = 0.5 },
	RequestPremiumClaim = { Direction = "ClientToServer", Args = { { type = "number", min = 1, max = 30, integer = true } }, MinInterval = 0.3 },
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
