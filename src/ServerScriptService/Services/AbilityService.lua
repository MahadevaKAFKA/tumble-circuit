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

	B2: nine play-earned abilities (AbilityConfig, AbilityRules). Owned = 3 starters + every
	ability whose unlock level you reached + those bought with earned Coins (profile
	ownedAbilityIds; RequestUnlockAbility spends Coins atomically, never Robux). Self effects go to
	the owner's motor as EffectState.statuses (GravityGlide, Anchor, Phase, BounceBurst, Chilled);
	rival effects (Frost Wake lane, Magnet pull) are judged from server-observed positions; Grapple
	needs a server raycast to an anchor ring ahead and before the next checkpoint; Decoy is a
	server hologram that can't collide, be queried or count for anything.
	Try-it: in the hub (not racing) any ability can be equipped for PRACTICE and used on yourself;
	a race always uses your owned loadout.

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
local AbilityRules = require(script.Parent:WaitForChild("AbilityRules"))
local RouteTracker = require(Shared:WaitForChild("RouteTracker"))
local RunService = game:GetService("RunService")

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
		RequestUnlockAbility = Utility.RateLimiter.new(RoundProtocol.Remotes.RequestUnlockAbility.MinInterval),
	}
	self.playerData = deps.playerData -- B2 (set by ServerBootstrap): level, Coins, owned abilities
	self.track = deps.track -- B2: grapple anchors / route for decoys
	self.checkpoints = deps.checkpoints -- B2: grapple never reaches past the next checkpoint
	self.frostLanes = {} -- B2 active Frost Wake lanes
	self.magnets = {} -- B2 [caster] = { untilT, nextTick, pulled = {} }
	self.decoys = {} -- B2 [part] = { s, speed, lateral, untilT, route }
	self.Activated = Utility.Signal.new() -- (player, abilityId)
	self.LoadoutChanged = Utility.Signal.new() -- (player, loadout) A5: persisted by PlayerDataService
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
			statuses = {}, -- B2: [kind] = { endsAt, ...fields } for the owner's motor
			shieldUntil = 0,
			lastPulseHit = 0,
			practiceLoadout = nil, -- B2 try-it (hub only)
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
	connect("RequestUnlockAbility", function(player, id)
		self:TryUnlock(player, id)
	end)
	self.maid:Give(RunService.Heartbeat:Connect(function(dt)
		self:_stepB2(dt)
	end))
	self.maid:Give(self.physics.Progress:Connect(function(entity, info)
		self:_onProgress(entity, info)
	end))
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
		if state == S.Preparing then
			for player, st in pairs(self.players) do
				if st.practiceLoadout and self.round.racerByPlayer[player] then
					st.practiceLoadout = nil -- a race always uses the owned loadout
					self:SendState(player)
				end
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
	self:_refreshOwned(player)
	self.remotes.AbilityState:FireClient(player, {
		loadout = { state.loadout[1], state.loadout[2] },
		practice = state.practiceLoadout and { state.practiceLoadout[1], state.practiceLoadout[2] } or nil,
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
	local payload = { modifiers = mods, statuses = AbilityRules.ActiveStatuses(state.statuses, now()), shieldUntil = state.shieldUntil, hardCap = AbilityConfig.HardSpeedCap, serverTime = now() }
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
	local had = next(state.modifiers) ~= nil or state.shieldUntil > 0 or next(state.statuses) ~= nil
	state.modifiers = {}
	state.statuses = {}
	state.shieldUntil = 0
	self.magnets[player] = nil
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

-- B2: timed status for the owner's motor (and bots' motors via the bot hook)
function AbilityService:SetStatus(player, kind, seconds, fields)
	local state = self:_state(player)
	local st = { endsAt = now() + seconds }
	for k, v in pairs(fields or {}) do
		st[k] = v
	end
	state.statuses[kind] = st
	self:SendEffects(player)
end

function AbilityService:HasStatus(entity, kind)
	local state = self.players[entity]
	local st = state and state.statuses[kind]
	return st ~= nil and st.endsAt > now()
end

-- B2: owned abilities = starters + reached unlock levels + bought with Coins (profile)
function AbilityService:_refreshOwned(player)
	if isBot(player) then
		return
	end
	local state = self:_state(player)
	local profile = self.playerData and self.playerData:GetProfile(player)
	local data = profile and profile.data
	local set, owned = {}, {}
	local function add(id)
		if ABILITIES[id] and not set[id] then
			set[id] = true
			owned[#owned + 1] = id
		end
	end
	for _, id in ipairs(AbilityConfig.StarterOwned) do
		add(id)
	end
	if data then
		for _, id in ipairs(data.ownedAbilityIds or {}) do
			add(id)
		end
		for _, id in ipairs(AbilityConfig.Order) do
			local unlock = ABILITIES[id].Unlock
			if unlock and (data.level or 1) >= unlock.Level then
				add(id)
			end
		end
	end
	state.owned = owned
	state.ownedSet = set
end

-- B2: unlock with level (free) or earned Coins (atomic debit). Returns ok, message.
function AbilityService:TryUnlock(player, id)
	self:_refreshOwned(player)
	local state = self:_state(player)
	local def = ABILITIES[id]
	if not def or not def.Unlock then
		return false, "Unknown ability"
	end
	if state.ownedSet[id] then
		return false, "Already unlocked"
	end
	local profile = self.playerData and self.playerData:GetProfile(player)
	if not profile or profile.status == "Loading" or profile.status == "Unavailable" or profile.status == "ReadOnly" then
		return false, "Your progress isn't loaded - try again in a moment"
	end
	local granted, message = false, nil
	self.playerData:Update(player, function(data)
		local set = {}
		for _, owned in ipairs(data.ownedAbilityIds) do
			set[owned] = true
		end
		local ok, how, detail = AbilityConfig.UnlockState(id, set, data.level, data.coins)
		if not ok then
			message = detail
			return
		end
		if set[id] then
			message = "Already unlocked"
			return
		end
		if how == "Coins" then
			data.coins = data.coins - def.Unlock.Coins -- checked >= cost inside the same mutation
		end
		table.insert(data.ownedAbilityIds, id)
		granted = true
		message = how == "Coins" and string.format("%s unlocked for %d Coins", def.DisplayName, def.Unlock.Coins) or (def.DisplayName .. " unlocked")
	end)
	if granted then
		self.playerData:SaveSoon(player)
		self:SendState(player)
	end
	self:_skill(player, granted and "Unlocked" or "Denied", message or "Can't unlock that yet")
	return granted, message
end

function AbilityService:_impulse(entity, direction, deltaV, source, cap)
	if isBot(entity) then
		if self.botHooks then
			self.botHooks.applyImpulse(entity, direction, deltaV, cap)
		end
	else
		self.remotes.ApplyImpulse:FireClient(entity, { direction = direction, deltaV = deltaV, source = source, cap = cap })
	end
end

function AbilityService:_rivalsNear(player, ball)
	local out, byId = {}, {}
	for _, other in ipairs(self.round:GetActiveRacers()) do
		local otherBall = other ~= player and self:_ballFor(other)
		if otherBall and otherBall.Parent and otherBall:GetAttribute(Protocol.BallAttributes.Zone) == Protocol.Zones.Race then
			out[#out + 1] = {
				id = other.UserId,
				position = otherBall.Position,
				protected = otherBall:GetAttribute(Protocol.BallAttributes.Protected) == true,
				frozen = otherBall.Anchored,
			}
			byId[other.UserId] = other
		end
	end
	return out, byId
end

-- B2 Frost Wake lane points for the VFX (centre line every 4 studs)
function AbilityService:_lanePoints(lane)
	local layout = self.track and self.track:GetLayout(Protocol.Zones.Race)
	if not layout then
		return nil
	end
	local points = {}
	local s = lane.fromS
	while s <= lane.toS + 1e-6 do
		local p = RouteTracker.PointAtS(layout.Route, s)
		local tangent = RouteTracker.HorizontalTangentAtS(layout.Route, s) or Vector3.new(0, 0, -1)
		local right = tangent:Cross(Vector3.new(0, 1, 0)).Unit
		points[#points + 1] = p + right * lane.lateral
		s = s + 4
	end
	return points, lane.halfWidth * 2
end

function AbilityService:_spawnDecoy(player, ball, def, info)
	local layout = self.track and self.track:GetLayout(Protocol.Zones.Race)
	if not layout or not info then
		return nil
	end
	local folder = workspace:FindFirstChild("TC_Decoys")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "TC_Decoys"
		folder.Parent = workspace
	end
	local part = Instance.new("Part")
	part.Name = "Decoy"
	part.Shape = Enum.PartType.Ball
	part.Size = ball.Size
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.ForceField
	part.Color = ball.Color
	part.Transparency = 0.3
	part:SetAttribute("TC_Decoy", true)
	local tag = Instance.new("BillboardGui")
	tag.Size = UDim2.fromOffset(120, 26)
	tag.StudsOffsetWorldSpace = Vector3.new(0, 3.4, 0)
	tag.MaxDistance = 140
	tag.LightInfluence = 0
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.TextScaled = true
	text.Font = Enum.Font.GothamBlack
	text.TextColor3 = Color3.fromRGB(255, 212, 90)
	text.TextStrokeTransparency = 0.3
	text.Text = "DECOY"
	text.Parent = tag
	tag.Parent = part
	local side = (info.lateral or 0) > 0 and -1 or 1
	local entry = { s = info.s, speed = math.max(10, ball.AssemblyLinearVelocity.Magnitude), lateral = (info.lateral or 0) + side * def.LateralOffset, untilT = now() + def.Duration, route = layout.Route }
	self.decoys[part] = entry
	self:_moveDecoy(part, entry, 0)
	part.Parent = folder
	return part
end

function AbilityService:_moveDecoy(part, entry, dt)
	entry.s = math.min(entry.route.total, entry.s + entry.speed * dt)
	local p = RouteTracker.PointAtS(entry.route, entry.s)
	local tangent = RouteTracker.HorizontalTangentAtS(entry.route, entry.s) or Vector3.new(0, 0, -1)
	local right = tangent:Cross(Vector3.new(0, 1, 0)).Unit
	part.CFrame = CFrame.new(p + right * entry.lateral + Vector3.new(0, part.Size.Y / 2, 0))
end

function AbilityService:_stepB2(dt)
	local t = now()
	for part, entry in pairs(self.decoys) do
		if t >= entry.untilT or not part.Parent then
			self.decoys[part] = nil
			part:Destroy()
		else
			self:_moveDecoy(part, entry, dt)
		end
	end
	for caster, mag in pairs(self.magnets) do
		if t >= mag.untilT then
			self.magnets[caster] = nil
		elseif t >= mag.nextTick then
			mag.nextTick = t + ABILITIES.Magnet.TickSeconds
			local ball = self:_ballFor(caster)
			if ball and ball.Parent and self.round:IsActiveRacer(caster) then
				local candidates, byId = self:_rivalsNear(caster, ball)
				for _, pull in ipairs(AbilityRules.MagnetPulls(ball.Position, candidates, ABILITIES.Magnet, mag.pulled)) do
					local victim = byId[pull.id]
					if not mag.blocked[pull.id] and self:ConsumeShield(victim, "Magnet") then
						mag.blocked[pull.id] = true
					elseif not mag.blocked[pull.id] then
						mag.pulled[pull.id] = (mag.pulled[pull.id] or 0) + pull.deltaV
						self:_impulse(victim, pull.direction, pull.deltaV, "Magnet", ABILITIES.Magnet.DeltaVPerTick)
					end
				end
			end
		end
	end
	local alive = {}
	for _, lane in ipairs(self.frostLanes) do
		if t < lane.endsAt then
			alive[#alive + 1] = lane
		end
	end
	self.frostLanes = alive
end

-- B2: Frost Wake from server-observed progress samples
function AbilityService:_onProgress(entity, info)
	if #self.frostLanes == 0 or info.zone ~= Protocol.Zones.Race or not self.round:IsActiveRacer(entity) then
		return
	end
	local t = now()
	local id = entity.UserId
	for _, lane in ipairs(self.frostLanes) do
		if lane.owner ~= entity and AbilityRules.InFrostLane(lane, info.s, info.lateral or 0, t, id) then
			lane.chilled[id] = true
			if not self:ConsumeShield(entity, "Frost Wake") then
				self:SetStatus(entity, "Chilled", ABILITIES.FrostWake.ChillSeconds, { steer = ABILITIES.FrostWake.SteerMultiplier })
				self:_skill(entity, "Chilled", "Frost Wake - steering slowed")
			end
		end
	end
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
	self:_refreshOwned(player)
	local practicing = ABILITIES[id] ~= nil and not (state.ownedSet and state.ownedSet[id]) and ABILITIES[id].Unlock ~= nil
	if practicing then
		-- B2 try-it: a locked ability can be equipped for hub practice only
		local base = state.practiceLoadout or state.loadout
		local practice = { base[1], base[2] }
		local otherSlot = slot == 1 and 2 or 1
		if practice[otherSlot] == id then
			practice[otherSlot] = practice[slot]
		end
		practice[slot] = id
		if practice[1] == practice[2] then
			return false
		end
		state.practiceLoadout = practice
		self:SendState(player)
		self:_skill(player, "Denied", "Practice only: try it in the hub, unlock it to race with it")
		return true
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
	state.practiceLoadout = nil -- equipping owned abilities ends the practice set
	self:SendState(player)
	self.LoadoutChanged:Fire(player, { loadout[1], loadout[2] })
	return true
end

-- A5: restore the saved loadout when the profile loads (validated against owned abilities).
function AbilityService:SetLoadout(player, loadout)
	local state = self:_state(player)
	if type(loadout) ~= "table" then
		return false
	end
	local candidate = { loadout[1], loadout[2] }
	self:_refreshOwned(player)
	if not SkillRules.ValidateLoadout(candidate, state.owned, AbilityConfig.SlotCount, ABILITIES) then
		return false
	end
	state.loadout = candidate
	self:SendState(player)
	return true
end

function AbilityService:Activate(player, slot)
	local state = self:_state(player)
	local ball = self:_ballFor(player)
	-- B2 try-it: in the hub (practice chute / platform) abilities act on yourself only
	local practice = not isBot(player) and ball ~= nil and not ball.Anchored and ball:GetAttribute(Protocol.BallAttributes.Zone) == Protocol.Zones.Hub and self.round.racerByPlayer[player] == nil
	if not practice and (not self.round:IsActiveRacer(player) or not ball or ball.Anchored or ball:GetAttribute(Protocol.BallAttributes.Zone) ~= Protocol.Zones.Race) then
		self:_skill(player, "Denied", "Abilities work during a race, or for practice in the hub")
		return false
	end
	local id = (practice and state.practiceLoadout or state.loadout)[slot]
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
		for _, target in ipairs(practice and {} or SkillRules.PulseTargets(ball.Position, forward, candidates, def)) do -- B2: practice never touches anyone
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
	elseif id == "FrostWake" then
		local info = self.physics:GetLastInfo(player)
		if info and info.s and not practice then
			local lane = AbilityRules.FrostLane(info.s, info.lateral or 0, def, t)
			lane.owner = player
			table.insert(self.frostLanes, lane)
			outcome.lane, outcome.laneWidth = self:_lanePoints(lane)
		end
		outcome.endsAt = t + def.Duration
	elseif id == "Magnet" then
		if not practice then
			self.magnets[player] = { untilT = t + def.Duration, nextTick = t, pulled = {}, blocked = {} }
		end
		outcome.endsAt = t + def.Duration
	elseif id == "Phase" then
		self:SetStatus(player, "Phase", def.Duration)
		outcome.endsAt = t + def.Duration
	elseif id == "GrappleSpark" then
		local info = self.physics:GetLastInfo(player)
		local layout = self.track and self.track:GetLayout(practice and Protocol.Zones.Hub or Protocol.Zones.Race)
		local target = nil
		if info and info.s and layout and layout.GrappleAnchors then
			local nextCpS = nil
			if not practice and self.checkpoints then
				local cp = layout.Checkpoints[self.checkpoints:GetConfirmed(player) + 1]
				nextCpS = cp and cp.S or layout.FinishLineS
			end
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { self.marbles.folder }
			target = AbilityRules.GrappleTarget(layout.GrappleAnchors, info.s, ball.Position, nextCpS, def.Range, function(anchor)
				local offset = anchor.Position - ball.Position
				return workspace:Raycast(ball.Position, offset, params) == nil
			end)
		end
		if not target then
			state.cooldowns[slot] = 0 -- nothing to grab: no cooldown spent
			self:SendState(player)
			self:_skill(player, "Denied", "No grapple ring in range ahead")
			return false
		end
		local direction, deltaV = AbilityRules.GrappleImpulse(ball.Position, target, def)
		if direction then
			self:_impulse(player, direction, deltaV, "Grapple", def.MaxDeltaV)
		end
		outcome.anchor = target.Position
		outcome.endsAt = t + 0.4
	elseif id == "BounceBurst" then
		self:SetStatus(player, "BounceBurst", def.Window, { upDeltaV = def.UpDeltaV })
		outcome.endsAt = t + def.Window
	elseif id == "GravityGlide" then
		self:SetStatus(player, "GravityGlide", def.Duration, { gravityReduction = def.GravityReduction, steer = def.SteerMultiplier })
		outcome.endsAt = t + def.Duration
	elseif id == "ReverseJet" then
		local info = self.physics:GetLastInfo(player)
		local direction, deltaV = AbilityRules.ReverseJet(info and info.tangent or Vector3.new(0, 0, -1), def)
		if direction then
			self:_impulse(player, direction, deltaV, "ReverseJet", def.DeltaV)
		end
		outcome.endsAt = t + 0.3
	elseif id == "Decoy" then
		if not practice then
			self:_spawnDecoy(player, ball, def, self.physics:GetLastInfo(player))
		end
		outcome.endsAt = t + def.Duration
	elseif id == "Anchor" then
		self:SetStatus(player, "Anchor", def.Duration, { knockbackScale = def.KnockbackScale, steerAssist = def.SteerAssist })
		outcome.endsAt = t + def.Duration
	end
	outcome.practice = practice or nil
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
