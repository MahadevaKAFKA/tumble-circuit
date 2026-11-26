--[[
	HubRules (promo pack prompts 03 / 04) — a player's personal destination: which hub they
	stand in (Visit Hub) or roll in (Practice). Pure decision, no Roblox APIs.

	A destination never touches the shared race: the race map, queue and ballots are unchanged.
	Decide(request, ctx) -> { ok, reason, hubId, move }
	  request = { hubId, mode = "Visit" | "Practice", now }
	  ctx     = { built = { [hubId] = true }, allowed = { [hubId] = true }, current = hubId,
	              lastAt = number|nil, racing = bool, inTrial = bool }
	  * unknown / not built (failed to load) -> refused "unavailable"
	  * gated and not allowed for this player -> refused "gated"
	  * faster than CooldownSeconds after the last accepted change -> refused "too_fast"
	  * while this player is on the grid / racing: the hub becomes the RETURN hub, no move
	    ("after_race") so the race is never disturbed
	  * otherwise accepted; move = true (respawn at the hub ring, or at its practice start)
]]

local HubRules = {}

HubRules.CooldownSeconds = 1.5
HubRules.Modes = { "Visit", "Practice" } -- request mode index 1 / 2

function HubRules.Decide(request, ctx)
	local hubId, mode = request.hubId, request.mode
	if type(hubId) ~= "string" or not ctx.built[hubId] then
		return { ok = false, reason = "unavailable" }
	end
	if not ctx.allowed[hubId] then
		return { ok = false, reason = "gated" }
	end
	if mode ~= "Visit" and mode ~= "Practice" then
		return { ok = false, reason = "bad_mode" }
	end
	if ctx.lastAt and (request.now - ctx.lastAt) < HubRules.CooldownSeconds then
		return { ok = false, reason = "too_fast" }
	end
	if ctx.racing then
		return { ok = true, reason = "after_race", hubId = hubId, move = false }
	end
	return { ok = true, reason = ctx.inTrial and "left_trial" or "ok", hubId = hubId, move = true, mode = mode }
end

-- The hub a returning racer lands in: their chosen hub when it still exists, else the default.
function HubRules.ReturnHub(chosen, built, defaultId)
	if chosen and built[chosen] then
		return chosen, false
	end
	return defaultId, chosen ~= nil and chosen ~= defaultId
end

return HubRules
