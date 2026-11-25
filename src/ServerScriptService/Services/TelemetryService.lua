--[[
	TelemetryService (B3) — a thin, failure-proof wrapper over Roblox's own AnalyticsService
	(named Telemetry so it can't be confused with the built-in service). Aggregate, Roblox-hosted,
	no personal data of ours: event names + small numeric/string fields only. A failing call is
	swallowed (never blocks gameplay). Off in Studio unless GameConfig.Debug.TelemetryInStudio.
	Funnel: onboarding (title -> first roll -> first race -> first finish) and the race loop
	(race_start, finish, play_again, world, ability_used, quest_claim, garage_preview, return).
]]

local AnalyticsService = game:GetService("AnalyticsService")
local RunService = game:GetService("RunService")

local TelemetryService = {}
TelemetryService.__index = TelemetryService

TelemetryService.Onboarding = { "Title", "FirstRoll", "FirstRace", "FirstFinish" }

function TelemetryService.new(deps)
	local self = setmetatable({}, TelemetryService)
	self.enabled = deps and deps.enabled
	if self.enabled == nil then
		self.enabled = not RunService:IsStudio()
	end
	self.failures = 0
	self.onboarded = {} -- [userId] = highest step logged this session
	return self
end

function TelemetryService:_call(fn)
	if not self.enabled then
		return false
	end
	local ok = pcall(fn)
	if not ok then
		self.failures = self.failures + 1
	end
	return ok
end

-- custom event: name (string), fields = { value = number?, ... } (customFields: up to 3 strings)
function TelemetryService:Event(player, name, fields)
	fields = fields or {}
	local custom = {}
	local n = 0
	for k, v in pairs(fields) do
		if k ~= "value" and n < 3 then
			n = n + 1
			custom[Enum.AnalyticsCustomFieldKeys["CustomField0" .. n].Name] = tostring(k) .. ":" .. tostring(v)
		end
	end
	return self:_call(function()
		AnalyticsService:LogCustomEvent(player, name, type(fields.value) == "number" and fields.value or 1, custom)
	end)
end

function TelemetryService:Onboarding(player, step)
	local index = table.find(TelemetryService.Onboarding, step)
	if not index or (self.onboarded[player.UserId] or 0) >= index then
		return false
	end
	self.onboarded[player.UserId] = index
	return self:_call(function()
		AnalyticsService:LogOnboardingFunnelStepEvent(player, index, step)
	end)
end

-- direction "Source" / "Sink"; currency "Coins"; balance = Coins after the change; sku e.g.
-- "Quest:Daily", "Unlock:Magnet". Transaction type is Gameplay (there is no paid flow in B).
function TelemetryService:Economy(player, direction, currency, amount, balance, sku)
	return self:_call(function()
		AnalyticsService:LogEconomyEvent(player, Enum.AnalyticsEconomyFlowType[direction], currency, amount, balance, Enum.AnalyticsEconomyTransactionType.Gameplay.Name, sku)
	end)
end

function TelemetryService:Forget(player)
	self.onboarded[player.UserId] = nil
end

return TelemetryService
