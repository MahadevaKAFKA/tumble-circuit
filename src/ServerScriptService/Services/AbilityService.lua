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
	self.remotes.EffectState:FireClient(player, { modifiers = mods, shieldUntil = state.shieldUntil, hardCap = AbilityConfig.HardSpeedCap, serverTime = now() })
end

function AbilityService:_skill(player, kind, detail)
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
	local ball = self.marbles:GetBall(player)
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
			local otherBall = other ~= player and self.marbles:GetBall(other)
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
				self.remotes.ApplyImpulse:FireClient(victim, {
					direction = target.direction,
					deltaV = math.min(target.deltaV, def.MaxDeltaV),
					source = "Pulse",
					fromUserId = player.UserId,
				})
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

function AbilityService:Destroy()
	self.maid:Cleanup()
	self.players = {}
end

return AbilityService
