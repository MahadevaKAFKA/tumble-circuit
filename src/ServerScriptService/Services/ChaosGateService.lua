--[[
	ChaosGateService (A4, ADR-11) — trackside half-lane gates. Server-observed crossing only
	(continuous sweep across the gate's route distance, inside the gate's lateral span). Each
	racer collects each gate once per round. Tier at traversal from the live standings:
	  1) top three           -> +8%  for 1.0 s
	  2) else bottom half    -> +22% for 2.0 s + 1.0 s shield
	  3) else (middle)       -> +14% for 1.5 s
	Modifiers never stack (AbilityService keeps the strongest), the 96 studs/s cap still applies.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Protocol = require(Shared:WaitForChild("Protocol"))
local RoundProtocol = require(Shared:WaitForChild("RoundProtocol"))
local Utility = require(Shared:WaitForChild("Utility"))
local RaceRules = require(script.Parent:WaitForChild("RaceRules"))

local ChaosGateService = {}
ChaosGateService.__index = ChaosGateService

ChaosGateService.Tiers = {
	Top = { Multiplier = 1.08, Duration = 1.0, Shield = 0, Label = "SURGE +8%" },
	Bottom = { Multiplier = 1.22, Duration = 2.0, Shield = 1.0, Label = "COMEBACK SURGE +22%" },
	Middle = { Multiplier = 1.14, Duration = 1.5, Shield = 0, Label = "SURGE +14%" },
}

-- Pure: deterministic tier with top-three precedence, then bottom half, then middle.
function ChaosGateService.Tier(place, racerCount)
	if place <= 3 then
		return "Top"
	end
	if place > math.ceil(racerCount / 2) then
		return "Bottom"
	end
	return "Middle"
end

-- Pure: did this sample cross the gate inside its span?
function ChaosGateService.Crossed(gate, prevS, s, lateral)
	if not RaceRules.CrossingFraction(prevS, s, gate.S) then
		return false
	end
	return math.abs(lateral - gate.Offset) <= gate.Width / 2 + 1
end

function ChaosGateService.new(deps)
	local self = setmetatable({}, ChaosGateService)
	self.track = deps.track
	self.physics = deps.physics
	self.round = deps.round
	self.progress = deps.progress
	self.abilities = deps.abilities
	self.remotes = deps.remotes
	self.collected = {}
	self.maid = Utility.Maid.new()
	self.GateCollected = Utility.Signal.new() -- B3: (entity, gateId)
	return self
end

function ChaosGateService:Start()
	self.gates = self.track:GetLayout(Protocol.Zones.Race).ChaosGates or {}
	if self.track.WorldChanged then
		self.maid:Give(self.track.WorldChanged:Connect(function(_, layout)
			self.gates = layout.ChaosGates or {}
			self.collected = {}
		end))
	end
	self.maid:Give(self.round.StateChanged:Connect(function(state)
		if state == RoundProtocol.States.Racing or state == RoundProtocol.States.Cleanup then
			self.collected = {}
		end
	end))
	self.maid:Give(self.physics.Progress:Connect(function(entity, info)
		if info.zone == Protocol.Zones.Race and info.prevS and self.round:IsActiveRacer(entity) then
			self:_check(entity, info)
		end
	end))
end

function ChaosGateService:_check(entity, info)
	for _, gate in ipairs(self.gates) do
		local key = gate.Id
		self.collected[entity] = self.collected[entity] or {}
		if not self.collected[entity][key] and ChaosGateService.Crossed(gate, info.prevS, info.s, info.lateral or 0) then
			self.collected[entity][key] = true
			self.GateCollected:Fire(entity, gate.Id) -- B3 quests
			local standings = self.round:GetStandings()
			local place, count = #standings, #standings
			for _, entry in ipairs(standings) do
				if entry.userId == entity.UserId then
					place = entry.place
				end
			end
			local tierName = ChaosGateService.Tier(place, count)
			local tier = ChaosGateService.Tiers[tierName]
			self.abilities:SetModifier(entity, "ChaosGate", tier.Multiplier, tier.Duration)
			if tier.Shield > 0 then
				self.abilities:GrantShield(entity, tier.Shield)
			end
			self.remotes.ChaosGateVFX:FireAllClients({ userId = entity.UserId, gateId = gate.Id, tier = tierName, label = tier.Label, place = place, count = count })
		end
	end
end

function ChaosGateService:Destroy()
	self.maid:Cleanup()
end

return ChaosGateService
