--[[
	AbilityService — A3 starter abilities, server-authoritative (master section 4, ADR-04/10).

	Client sends only RequestAbility(slot) / RequestEquip(slot, id). The server checks: live
	unfinished racer in Racing, unanchored marble on the race track, equipped ability, server
	cooldown timestamp. Effects:
	  Boost  : timed speed modifier (x1.3 for 1.6 s, hard cap 96) sent to the owner's motor
	  Shield : 2.5 s or first hostile Pulse / active bumper hit (server judged)
	  Pulse  : targets from SERVER-observed positions within 12 studs; each un-shielded target's
	           owner receives a bounded impulse (<= 18 studs/s, falloff), 1.2 s anti-chain per target
	Speed modifiers never stack (strongest active wins). Respawn cancels effects; a new race
	resets cooldowns. Timestamps are workspace:GetServerTimeNow() so HUD rings line up.

	A4: bots (server-owned entities, isBot = true) use this same service and the same cooldowns.
	Their effects and impulses go to BotService hooks instead of remotes. Chaos Gates use
	SetModifier("ChaosGate") + GrantShield. Priority: one speed modifier at a time (strongest
	wins, hard cap 96); a shield blocks the next Pulse / bumper / sweeper / hammer hit.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AbilityConfig = require(Shared:WaitForChild("AbilityConfig"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local RaceConfig = require(Shared:WaitForChild("RaceConfig"))
local RoundProtocol = require(Shared:WaitForChild("RoundProtocol"))
local Utility = require(Shared:WaitForChild("Utility"))
local SkillRules = require(script.Parent:WaitForChild("SkillRules"))

local AbilityService = {}
AbilityService.__index = AbilityService

local S = RoundProtocol.States
local ABILITIES = AbilityConfig.Abilities

function AbilityService.new(deps)
	local self = setmetatable({}, AbilityService)
	self.marbles = deps.marbles
	self.physics = deps.physics
	self.round = deps.round
	self.remotes = deps.remotes
	self.players = {}
	self.maid = Utility.Maid.new()
	self.limiters = {
		RequestAbility = Utility.RateLimiter.new(RoundProtocol.Remotes.RequestAbility.MinInterval),
		RequestEquip = Utility.RateLimiter.new(RoundProtocol.Remotes.RequestEquip.MinInterval),
	}
	self.Activated = Utility.Signal.new() -- (player, abilityId)
	return self
end

local function now()
	return workspace:GetServerTimeNow()
end

local function isBot(entity)
	return type(entity) == "table" and entity.isBot == true
end
AbilityService.IsBot = isBot

function AbilityService:SetBotHooks(hooks)
	self.botHooks = hooks
end

function AbilityService:_ballFor(entity)
	if self.round and self.round.GetBallFor then
		return self.round:GetBallFor(entity)
	end
	return self.marbles:GetBall(entity)
end

function AbilityService:Forget(entity)
	self.players[entity] = nil
end

function AbilityService:_state(player)
	local state = self.players[player]
	if not state then
		local owned = {}
		for i, id in ipairs(AbilityConfig.StarterOwned) do
			owned[i] = id
		end
		state = {
			owned = owned,
			loadout = { AbilityConfig.DefaultLoadout[1], AbilityConfig.DefaultLoadout[2] },
			cooldowns = { [1] = 0, [2] = 0 },
			lockoutUntil = 0,
			modifiers = {},
			shieldUntil = 0,
			lastPulseHit = 0,
		}
		self.players[player] = state
	end
	return state
end

function AbilityService:Start()
	local function connect(name, handler)
		local remote = self.remotes:WaitForChild(name)
		self.maid:Give(remote.OnServerEvent:Connect(function(player, ...)
			local ok = RoundProtocol.ValidateArgs(name, ...)
			if not ok or not self.limiters[name]:Try(player) then
				return
			end
			handler(player, ...)
		end))
	end
	connect("RequestAbility", function(player, slot)
		self:Activate(player, slot)
	end)
	connect("RequestEquip", function(player, slot, id)
		self:Equip(player, slot, id)
	end)
	-- The client asks for a snapshot once its listeners exist; resend ability state with it.
	self.limiters.RequestSnapshot = Utility.RateLimiter.new(RoundProtocol.Remotes.RequestSnapshot.MinInterval)
	connect("RequestSnapshot", function(player)
		self:SendState(player)
		self:SendEffects(player)
	end)
	self.maid:Give(self.marbles.PlayerJoined:Connect(function(player)
		self:_state(player)
		self:SendState(player)
	end))
	self.maid:Give(self.marbles.PlayerLeaving:Connect(function(player)
		self.players[player] = nil
	end))
	self.maid:Give(self.marbles.MarbleSpawned:Connect(function(player)
		self:CancelEffects(player)
	end))
	self.maid:Give(self.round.StateChanged:Connect(function(state)
		if state == S.Racing or state == S.Cleanup then
			for player in pairs(self.players) do
				self:ResetForRound(player)
			end
		end
	end))
end

---------------------------------------------------------------------------------------------
-- Replication helpers
---------------------------------------------------------------------------------------------
function AbilityService:SendState(player)
	if isBot(player) then
		return
	end
	local state = self:_state(player)
	self.remotes.AbilityState:FireClient(player, {
		loadout = { state.loadout[1], state.loadout[2] },
		owned = state.owned,
		cooldowns = { state.cooldowns[1], state.cooldowns[2] },
		lockoutUntil = state.lockoutUntil,
		serverTime = now(),
	})
end

function AbilityService:SendEffects(player)
	local state = self:_state(player)
	local mods = {}
	for kind, mod in pairs(state.modifiers) do
		mods[#mods + 1] = { kind = kind, multiplier = mod.multiplier, endsAt = mod.endsAt, extraAccel = mod.extraAccel or 0 }
	end
	local payload = { modifiers = mods, shieldUntil = state.shieldUntil, hardCap = AbilityConfig.HardSpeedCap, serverTime = now() }
	if isBot(player) then
		if self.botHooks then
			self.botHooks.applyEffects(player, payload)
		end
		return
	end
	self.remotes.EffectState:FireClient(player, payload)
end

function AbilityService:_skill(player, kind, detail)
	if isBot(player) then
		return
	end
	self.remotes.SkillEvent:FireClient(player, { kind = kind, detail = detail, serverTime = now() })
end

---------------------------------------------------------------------------------------------
-- Effects API (also used by MicroSkillService)
---------------------------------------------------------------------------------------------
function AbilityService:SetModifier(player, kind, multiplier, duration, extraAccel)
	local state = self:_state(player)
	state.modifiers[kind] = { multiplier = multiplier, endsAt = duration and (now() + duration) or nil, extraAccel = extraAccel }
	self:SendEffects(player)
end

function AbilityService:RemoveModifier(player, kind)
	local state = self.players[player]
	if state and state.modifiers[kind] then
		state.modifiers[kind] = nil
		self:SendEffects(player)
	end
end

function AbilityService:IsShielded(player)
	local state = self.players[player]
	return state ~= nil and state.shieldUntil > now()
end

function AbilityService:ConsumeShield(player, reason)
	local state = self.players[player]
	if state and state.shieldUntil > now() then
		state.shieldUntil = 0
		self:SendEffects(player)
		self:_skill(player, "ShieldBlocked", reason)
		return true
	end
	return false
end

-- A4 Chaos Gate comeback shield (extends, never shortens, an active shield).
function AbilityService:GrantShield(player, seconds)
	local state = self:_state(player)
	state.shieldUntil = math.max(state.shieldUntil, now() + seconds)
	self:SendEffects(player)
end

function AbilityService:ApplyCharge(player, reason)
	local state = self.players[player]
	if not state then
		return false
	end
	local cfg = AbilityConfig.MicroSkills.CooldownCharge
	local changed = SkillRules.ApplyCharge(state, now(), cfg.Seconds, cfg.GlobalLockoutSeconds)
	if changed then
		self:SendState(player)
		self:_skill(player, "Charge", reason)
	end
	return changed
end

function AbilityService:CancelEffects(player)
	local state = self.players[player]
	if not state then
		return
	end
	local had = next(state.modifiers) ~= nil or state.shieldUntil > 0
	state.modifiers = {}
	state.shieldUntil = 0
	if had then
		self:SendEffects(player)
	end
end

function AbilityService:ResetForRound(player)
	local state = self:_state(player)
	state.cooldowns = { [1] = 0, [2] = 0 }
	state.lockoutUntil = 0
	self:CancelEffects(player)
	self:SendState(player)
end

---------------------------------------------------------------------------------------------
-- Requests
---------------------------------------------------------------------------------------------
function AbilityService:Equip(player, slot, id)
	local state = self:_state(player)
	if self.round:IsActiveRacer(player) or (self.round:GetState() == S.Countdown or self.round:GetState() == S.Preparing) and self.round.racerByPlayer[player] then
		self:_skill(player, "Denied", "Change abilities in the hub or on the results screen")
		return false
	end
	local loadout = { state.loadout[1], state.loadout[2] }
	local other = slot == 1 and 2 or 1
	if loadout[other] == id then
		loadout[other] = loadout[slot] -- choosing the other slot's ability swaps them
	end
	loadout[slot] = id
	local ok, reason = SkillRules.ValidateLoadout(loadout, state.owned, AbilityConfig.SlotCount, ABILITIES)
	if not ok then
		self:_skill(player, "Denied", "Loadout rejected: " .. reason)
		return false
	end
	state.loadout = loadout
	self:SendState(player)
	return true
end

function AbilityService:Activate(player, slot)
	local state = self:_state(player)
	local ball = self:_ballFor(player)
	if not self.round:IsActiveRacer(player) or not ball or ball.Anchored or ball:GetAttribute(Protocol.BallAttributes.Zone) ~= Protocol.Zones.Race then
		self:_skill(player, "Denied", "Abilities work during a race")
		return false
	end
	local id = state.loadout[slot]
	local def = id and ABILITIES[id]
	if not def then
		return false
	end
	local t = now()
	if not SkillRules.IsReady(t, state.cooldowns[slot]) then
		self:_skill(player, "Denied", "Cooling down")
		return false
	end
	state.cooldowns[slot] = t + def.Cooldown
	local outcome = { userId = player.UserId, abilityId = id, startedAt = t, position = ball.Position, targets = {}, blocked = {} }

	if id == "Boost" then
		self:SetModifier(player, "Boost", def.SpeedMultiplier, def.Duration, def.ExtraForwardAccel)
		outcome.endsAt = t + def.Duration
	elseif id == "Shield" then
		state.shieldUntil = t + def.Duration
		outcome.endsAt = state.shieldUntil
		self:SendEffects(player)
	elseif id == "Pulse" then
		local info = self.physics:GetLastInfo(player)
		local forward = info and info.tangent or Vector3.new(0, 0, -1)
		local candidates, byId = {}, {}
		for _, other in ipairs(self.round:GetActiveRacers()) do
			local otherBall = other ~= player and self:_ballFor(other)
			if otherBall and otherBall.Parent and otherBall:GetAttribute(Protocol.BallAttributes.Zone) == Protocol.Zones.Race then
				candidates[#candidates + 1] = {
					id = other.UserId,
					position = otherBall.Position,
					protected = otherBall:GetAttribute(Protocol.BallAttributes.Protected) == true,
					frozen = otherBall.Anchored,
				}
				byId[other.UserId] = other
			end
		end
		for _, target in ipairs(SkillRules.PulseTargets(ball.Position, forward, candidates, def)) do
			local victim = byId[target.id]
			local victimState = self:_state(victim)
			if self:ConsumeShield(victim, "Pulse") then
				table.insert(outcome.blocked, target.id)
			elseif t - victimState.lastPulseHit >= RaceConfig.Collisions.AntiChainSeconds then
				victimState.lastPulseHit = t
				local deltaV = math.min(target.deltaV, def.MaxDeltaV)
				if isBot(victim) then
					if self.botHooks then
						self.botHooks.applyImpulse(victim, target.direction, deltaV)
					end
				else
					self.remotes.ApplyImpulse:FireClient(victim, {
						direction = target.direction,
						deltaV = deltaV,
						source = "Pulse",
						fromUserId = player.UserId,
					})
				end
				table.insert(outcome.targets, target.id)
			end
		end
		outcome.endsAt = t + 0.35
	end
	self:SendState(player)
	self.remotes.AbilityOutcome:FireAllClients(outcome)
	self.Activated:Fire(player, id)
	return true
end

-- Bots: which equipped slot (if any) is off cooldown right now.
function AbilityService:ReadySlots(entity)
	local state = self:_state(entity)
	local t = now()
	local out = {}
	for slot = 1, AbilityConfig.SlotCount do
		if state.loadout[slot] and SkillRules.IsReady(t, state.cooldowns[slot]) then
			out[#out + 1] = { slot = slot, id = state.loadout[slot] }
		end
	end
	return out
end

function AbilityService:Destroy()
	self.maid:Cleanup()
	self.players = {}
end

return AbilityService
