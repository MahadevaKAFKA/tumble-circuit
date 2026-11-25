--[[
	HazardTiming — deterministic hazard phases from server time (shared by the client visuals and
	the server's near-miss / shield judging, so both agree without network traffic).
]]

local HazardTiming = {}

function HazardTiming.PhaseAt(serverTime, cfg)
	local phase = serverTime % cfg.Period
	if phase >= cfg.ActiveAt then
		return "Active", 1
	elseif phase >= cfg.TelegraphAt then
		return "Telegraph", (phase - cfg.TelegraphAt) / (cfg.ActiveAt - cfg.TelegraphAt)
	end
	return "Idle", 0
end

-- Distance from a point to a vertical-ish hazard axis, and the height along it.
function HazardTiming.AxisDistance(position, floorPoint, axis)
	local rel = position - floorPoint
	local along = rel:Dot(axis)
	local radial = rel - axis * along
	return radial.Magnitude, along, radial
end

return HazardTiming
