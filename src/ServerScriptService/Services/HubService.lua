--[[
	HubService (promo pack prompts 03 / 04) — per-player hub lifecycle, independent of the round.
	  * every player has a chosen hub (player attribute TC_Hub; default Orbital Garage)
	  * RequestDestination(hubIndex, modeIndex): Visit Hub / Practice (HubRules decides; the
	    remote is validated and rate limited by RoundService, which forwards it here)
	  * RoundService asks HubFor(player) whenever it sends someone to a hub (join, practice loop,
	    end of a race), so racers return to the hub they chose; a hub that is missing falls back
	    to Orbital Garage (the race result is already recorded by then)
	  * gated hubs: offered only to players FeatureGates allows (TC_Features attribute)
	Visiting or practising never changes the race map, the queue or anyone else's hub.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local MapRegistry = require(Shared:WaitForChild("MapRegistry"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local Utility = require(Shared:WaitForChild("Utility"))
local FeatureGates = require(script.Parent:WaitForChild("FeatureGates"))
local HubRules = require(script.Parent:WaitForChild("HubRules"))

local HubService = {}
HubService.__index = HubService

local ATTR = Protocol.PlayerAttributes

function HubService.new(deps)
	local self = setmetatable({}, HubService)
	self.track = deps.track
	self.marbles = deps.marbles
	self.remotes = deps.remotes
	self.round = deps.round -- set after construction (RoundService needs HubService too)
	self.timeTrial = deps.timeTrial
	self.featuresFor = deps.featuresFor or FeatureGates.ForPlayer
	self.chosen = {} -- [player] = hubId
	self.features = {} -- [player] = gates
	self.lastAt = {} -- [player] = os.clock() of the last accepted change
	self.maid = Utility.Maid.new()
	self.Changed = Utility.Signal.new() -- (player, hubId, mode)
	return self
end

function HubService:_built()
	local built = {}
	for _, id in ipairs(self.track:GetHubIds()) do
		built[id] = true
	end
	return built
end

function HubService:_allowed(player)
	local allowed = {}
	for _, entry in ipairs(MapRegistry.EnabledHubs(self.features[player])) do
		allowed[entry.Id] = true
	end
	return allowed
end

function HubService:_setup(player)
	self.features[player] = self.featuresFor(player) or {}
	self.chosen[player] = MapRegistry.DefaultHubId
	player:SetAttribute(ATTR.Hub, MapRegistry.DefaultHubId)
	player:SetAttribute(ATTR.Features, FeatureGates.Encode(self.features[player]))
end

function HubService:Start()
	for _, player in ipairs(Players:GetPlayers()) do
		self:_setup(player)
	end
	self.maid:Give(Players.PlayerAdded:Connect(function(player)
		self:_setup(player)
	end))
	self.maid:Give(Players.PlayerRemoving:Connect(function(player)
		self.chosen[player] = nil
		self.features[player] = nil
		self.lastAt[player] = nil
	end))
end

-- The hub this player is sent to (always a built hub).
function HubService:HubFor(player)
	local hubId = HubRules.ReturnHub(self.chosen[player], self:_built(), MapRegistry.DefaultHubId)
	return hubId
end

function HubService:GetFeatures(player)
	return self.features[player] or {}
end

function HubService:_reply(player, payload)
	local remote = self.remotes:FindFirstChild("DestinationResult")
	if remote then
		remote:FireClient(player, payload)
	end
end

function HubService:TryDestination(player, hubIndex, modeIndex)
	local entry = MapRegistry.Hubs[hubIndex]
	local mode = HubRules.Modes[modeIndex]
	local round = self.round
	local racing = false
	if round and round.IsOnGridOrRacing then
		racing = round:IsOnGridOrRacing(player)
	end
	local inTrial = self.timeTrial and self.timeTrial:IsRunning(player) or false
	local decision = HubRules.Decide({ hubId = entry and entry.Id, mode = mode, now = os.clock() }, {
		built = self:_built(),
		allowed = self:_allowed(player),
		current = self.chosen[player],
		lastAt = self.lastAt[player],
		racing = racing,
		inTrial = inTrial,
	})
	if decision.ok then
		self.lastAt[player] = os.clock()
		self.chosen[player] = decision.hubId
		player:SetAttribute(ATTR.Hub, decision.hubId)
		if decision.move then
			if inTrial then
				-- Stop already sends the marble to the (newly chosen) hub ring
				self.timeTrial:Stop(player, "You left the Time Trial")
			end
			if decision.mode == "Practice" then
				self.marbles:SpawnMarble(player, Protocol.SpawnReasons.Practice)
			elseif not inTrial then
				self.marbles:SpawnMarble(player, Protocol.SpawnReasons.ToHub)
			end
		end
		self.Changed:Fire(player, decision.hubId, decision.mode)
	end
	self:_reply(player, { ok = decision.ok, reason = decision.reason, hubIndex = hubIndex, mode = modeIndex })
	return decision
end

function HubService:Destroy()
	self.maid:Cleanup()
end

return HubService
