--[[
	MicroSkillService — A3 micro-skills, judged from SERVER-observed samples (ADR-10):
	  Ramp Trick : takeoff = crossing the tagged kicker lip launched (height above the route plane,
	               speed, lateral inside the kicker); press (RequestTrick) within the early/late
	               window; landing back on the route plane within MaxAirtime -> +15% for 1.2 s.
	               One trick per airtime; respawn resets the state (a respawn is never a takeoff).
	  Slipstream : behind another live racer on the same route stretch, <= 12 studs, ahead dot
	               >= 0.7, server raycast line of sight, held 1.5 s -> +12% while held.
	  Near miss  : one judgement per approach to the bumper while it is telegraphing or active;
	               an actual contact during Active consumes a Shield instead.
	Each first-valid event grants Cooldown Charge through AbilityService (3 s global lockout).
	A4: bumper phases come from the round's hazard clock (HazardService: serverTime - epoch, plus
	the seed's per-bumper PhaseOffset); sweeper/hammer contact observed at a server sample
	consumes an active shield (the owner's client skips the kick while shielded). Bots are judged
	by the same rules; their feedback events are simply not sent anywhere.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AbilityConfig = require(Shared:WaitForChild("AbilityConfig"))
local HazardSim = require(Shared:WaitForChild("HazardSim"))
local HazardTiming = require(Shared:WaitForChild("HazardTiming"))
local PhysicsConfig = require(Shared:WaitForChild("PhysicsConfig"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local RoundProtocol = require(Shared:WaitForChild("RoundProtocol"))
local Utility = require(Shared:WaitForChild("Utility"))
local SkillRules = require(script.Parent:WaitForChild("SkillRules"))

local MicroSkillService = {}
MicroSkillService.__index = MicroSkillService

local CFG = AbilityConfig.MicroSkills
local S = RoundProtocol.States

function MicroSkillService.new(deps)
	local self = setmetatable({}, MicroSkillService)
	self.track = deps.track
	self.marbles = deps.marbles
	self.physics = deps.physics
	self.round = deps.round
	self.abilities = deps.abilities
	self.remotes = deps.remotes
	self.hazardService = deps.hazards
	self.players = {}
	self.maid = Utility.Maid.new()
	self.limiter = Utility.RateLimiter.new(RoundProtocol.Remotes.RequestTrick.MinInterval)
	self.losParams = RaycastParams.new()
	self.losParams.FilterType = Enum.RaycastFilterType.Exclude
	return self
end

function MicroSkillService:_state(player)
	local state = self.players[player]
	if not state then
		state = { trick = {}, slip = {}, near = {}, info = nil }
		self.players[player] = state
	end
	return state
end

function MicroSkillService:_reset(player)
	if self.players[player] then
		self.abilities:RemoveModifier(player, "Slipstream")
	end
	self.players[player] = nil
end

function MicroSkillService:_bindWorld()
	local layout = self.track:GetLayout(Protocol.Zones.Race)
	self.trickZones = layout.TrickZones or {}
	self.bumpers, self.movers = {}, {}
	local resolved = self.hazardService and self.hazardService:GetResolved() or layout.Hazards
	for _, hz in ipairs(resolved) do
		if hz.Kind == "PulseBumper" and hz.Frame then
			table.insert(self.bumpers, {
				hazard = hz,
				floorPoint = hz.Frame.Position + hz.Frame.Right * (hz.Offset or 0),
				axis = hz.Frame.Up,
				contact = hz.Definition.Radius + PhysicsConfig.Ball.Radius,
				height = hz.Definition.Height,
			})
		elseif (hz.Kind == "Sweeper" or hz.Kind == "Hammer") and hz.Frame then
			table.insert(self.movers, hz)
		end
	end
end

function MicroSkillService:Start()
	self:_bindWorld()
	if self.hazardService and self.hazardService.WorldBound then
		self.maid:Give(self.hazardService.WorldBound:Connect(function()
			self:_bindWorld()
		end))
	end
	-- Never wait here: ServerBootstrap starts this service before MarbleCharacterService:Start(),
	-- so an unbounded WaitForChild on the marbles folder stalled the whole server (2026-11-25).
	self.losParams.FilterDescendantsInstances = { self.marbles.folder }

	local remote = self.remotes:WaitForChild("RequestTrick")
	self.maid:Give(remote.OnServerEvent:Connect(function(player, ...)
		if RoundProtocol.ValidateArgs("RequestTrick", ...) and self.limiter:Try(player) then
			self:HandleTrickPress(player)
		end
	end))
	self.maid:Give(self.physics.Progress:Connect(function(player, info)
		self:_onSample(player, info)
	end))
	self.maid:Give(self.physics.SampleComplete:Connect(function()
		self:_evaluateSlipstreams()
	end))
	self.maid:Give(self.marbles.MarbleSpawned:Connect(function(player)
		self:_reset(player)
	end))
	self.maid:Give(self.marbles.PlayerLeaving:Connect(function(player)
		self.players[player] = nil
	end))
	self.maid:Give(self.round.StateChanged:Connect(function(state)
		if state ~= S.Racing then
			for player in pairs(self.players) do
				self:_reset(player)
			end
		end
	end))
end

function MicroSkillService:_event(player, kind, detail)
	if type(player) == "table" and player.isBot then
		return
	end
	self.remotes.SkillEvent:FireClient(player, { kind = kind, detail = detail, serverTime = workspace:GetServerTimeNow() })
end

function MicroSkillService:_onSample(player, info)
	if info.zone ~= Protocol.Zones.Race or info.frozen or not self.round:IsActiveRacer(player) then
		return
	end
	local state = self:_state(player)
	state.info = info

	-- Ramp Trick
	for _, zone in ipairs(self.trickZones) do
		local result = SkillRules.TrickStep(state.trick, info, zone, CFG.Trick)
		if result == "Success" then
			self.abilities:SetModifier(player, "Trick", CFG.Trick.SpeedMultiplier, CFG.Trick.Duration)
			self.abilities:ApplyCharge(player, "Trick")
			self:_event(player, "TrickSuccess")
		elseif result == "Takeoff" then
			self:_event(player, "Takeoff", state.trick.pressed and "armed" or nil)
		elseif result == "NoLanding" then
			self:_event(player, "TrickFail", "No clean landing")
		end
	end

	-- Near miss / bumper contact
	local hazardTime = self.hazardService and self.hazardService:Time() or workspace:GetServerTimeNow()
	for i, hz in ipairs(self.bumpers) do
		local offset = (hz.hazard.Params and hz.hazard.Params.PhaseOffset) or 0
		local phase = HazardTiming.PhaseAt(hazardTime + offset, PhysicsConfig.Hazards.PulseBumper)
		local dangerous = phase ~= "Idle"
		local distance, along = HazardTiming.AxisDistance(info.position, hz.floorPoint, hz.axis)
		if along > -2 and along < hz.height + 3 then
			state.near[i] = state.near[i] or {}
			local result = SkillRules.NearMissStep(state.near[i], distance, hz.contact, dangerous, CFG.NearMiss)
			if result == "NearMiss" then
				self.abilities:ApplyCharge(player, "NearMiss")
				self:_event(player, "NearMiss")
			elseif result == "Hit" and phase == "Active" then
				self.abilities:ConsumeShield(player, "Bumper")
			end
		end
	end

	-- A6 Perfect Dodge (commendation only: no Coins, no charge) for sweeper / hammer passes.
	state.dodge = state.dodge or {}
	for _, hz in ipairs(self.movers) do
		if hz.Params then
			local centre = hz.Frame.Position
			if hz.Kind == "Hammer" then
				centre = centre + hz.Frame.Right * HazardSim.HammerLateral(hz.Params, hazardTime)
			end
			local d = (info.position - centre).Magnitude
			state.dodge[hz.Id] = state.dodge[hz.Id] or {}
			local verdict = SkillRules.DodgeStep(state.dodge[hz.Id], d, HazardSim.Clearance(hz, hazardTime, info.position, PhysicsConfig.Ball.Radius), CFG.PerfectDodge)
			if verdict == "PerfectDodge" then
				self:_event(player, "PerfectDodge")
			end
		end
	end

	-- Moving hazards: a shield is spent by the first observed sweeper/hammer contact.
	if self.abilities:IsShielded(player) then
		for _, hz in ipairs(self.movers) do
			if hz.Params and HazardSim.Contact(hz, hazardTime, info.position, PhysicsConfig.Ball.Radius + 0.5) then
				self.abilities:ConsumeShield(player, hz.Kind)
				break
			end
		end
	end
end

function MicroSkillService:HandleTrickPress(player)
	if not self.round:IsActiveRacer(player) then
		return
	end
	local state = self:_state(player)
	local t = os.clock() -- same clock as RacePhysics samples
	local result = SkillRules.TrickPress(state.trick, t, CFG.Trick)
	if result == "Accepted" then
		self:_event(player, "TrickArmed")
	elseif result == "Duplicate" then
		self:_event(player, "TrickFail", "One trick per jump")
	elseif result == "TooLate" then
		self:_event(player, "TrickFail", "Too late - press right after the lip")
	elseif result == "Pending" then
		task.delay(CFG.Trick.EarlyPressSeconds + 0.1, function()
			local current = self.players[player]
			if current == state and state.trick.pressTime == t then
				state.trick.pressTime = nil
				self:_event(player, "TrickFail", "Can't trick here - use the TRICK RAMP")
			end
		end)
	end
end

function MicroSkillService:_evaluateSlipstreams()
	local racers = self.round:GetActiveRacers()
	if #racers == 0 then
		return
	end
	local t = os.clock()
	for _, follower in ipairs(racers) do
		local fState = self.players[follower]
		local fInfo = fState and fState.info
		if fInfo then
			local condition = false
			for _, leader in ipairs(racers) do
				local lState = leader ~= follower and self.players[leader]
				local lInfo = lState and lState.info
				if lInfo and SkillRules.SlipstreamGeometry(
					{ position = fInfo.position, s = fInfo.s, tangent = fInfo.tangent },
					{ position = lInfo.position, s = lInfo.s, tangent = lInfo.tangent },
					CFG.Slipstream
				) then
					local hit = workspace:Raycast(fInfo.position, lInfo.position - fInfo.position, self.losParams)
					if not hit then
						condition = true
						break
					end
				end
			end
			local result = SkillRules.SlipstreamStep(fState.slip, condition, t, CFG.Slipstream)
			if result == "Acquired" then
				self.abilities:SetModifier(follower, "Slipstream", CFG.Slipstream.SpeedMultiplier, nil)
				self.abilities:ApplyCharge(follower, "Slipstream")
				self:_event(follower, "SlipstreamOn")
			elseif result == "Lost" then
				self.abilities:RemoveModifier(follower, "Slipstream")
				self:_event(follower, "SlipstreamOff")
			end
		end
	end
end

function MicroSkillService:Destroy()
	self.maid:Cleanup()
	self.players = {}
end

return MicroSkillService
