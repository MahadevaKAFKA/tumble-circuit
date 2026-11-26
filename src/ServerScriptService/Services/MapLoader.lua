--[[
	MapLoader (promo pack prompt 02) — server-side load checks for registry maps and hubs, and
	the fallback decision. Pure: works on generated layouts and plain numbers, no services.

	ValidateCourse(layout, killY)  -> errors   (reachable checkpoints, finite transforms, grid)
	ValidateHub(geometry, chute, spawnCFrames, killY) -> errors (spawn ring, practice entry/return)
	Decide(results, defaultId)     -> enabled ids, dropped { id = reason }, fatal reason or nil
	  results = { { id = ..., ok = bool, errors = {...} }, ... } in registry order.
	  A failing non-default entry is dropped (logged, the rest keep running). If the default map
	  fails it stays in (there is nothing safer to fall back to) and the failure is reported.
]]

local MapLoader = {}

local function finite(n)
	return type(n) == "number" and n == n and math.abs(n) < 1e6
end

local function finitePos(p)
	return p ~= nil and finite(p.X) and finite(p.Y) and finite(p.Z)
end
MapLoader.FinitePosition = finitePos

function MapLoader.ValidateCourse(layout, killY)
	local errors = {}
	local function err(fmt, ...)
		errors[#errors + 1] = string.format(fmt, ...)
	end
	if not (layout and layout.Route and finite(layout.Route.total) and layout.Route.total > 0) then
		err("no route")
		return errors
	end
	local startS, finishS = layout.StartLineS, layout.FinishLineS
	if not (finite(startS) and finite(finishS) and startS < finishS) then
		err("start line must come before the finish line")
		return errors
	end
	if not (layout.SpawnFrame and finitePos(layout.SpawnFrame.Position)) then
		err("invalid spawn transform")
	end
	local lastS = startS
	for i, cp in ipairs(layout.Checkpoints or {}) do
		if not finite(cp.S) then
			err("checkpoint %d is off the route", i)
		elseif cp.S <= lastS or cp.S >= finishS then
			err("checkpoint %d unreachable in order (S %.0f, previous %.0f, finish %.0f)", i, cp.S, lastS, finishS)
		else
			lastS = cp.S
		end
		local respawn = cp.RespawnFrame
		if not (respawn and finitePos(respawn.Position)) then
			err("checkpoint %d has an invalid respawn transform", i)
		elseif killY and respawn.Position.Y <= killY then
			err("checkpoint %d respawns below the kill height", i)
		end
	end
	local slots = layout.GridSlots or {}
	if #slots == 0 then
		err("no grid slots")
	end
	for i, slot in ipairs(slots) do
		if not (slot.Frame and finitePos(slot.Frame.Position) and finite(slot.Offset)) then
			err("grid slot %d has an invalid transform", i)
			break
		end
	end
	return errors
end

function MapLoader.ValidateHub(geometry, chute, spawnCFrames, killY)
	local errors = {}
	local function err(fmt, ...)
		errors[#errors + 1] = string.format(fmt, ...)
	end
	if not (geometry and finitePos(geometry.Center) and finite(geometry.Radius)) then
		err("invalid hub centre")
		return errors
	end
	local center = geometry.Center
	if not spawnCFrames or #spawnCFrames == 0 then
		err("no hub spawns")
	end
	for i, cf in ipairs(spawnCFrames or {}) do
		local p = cf.Position
		if not finitePos(p) then
			err("hub spawn %d has an invalid transform", i)
			break
		end
		local flat = math.sqrt((p.X - center.X) ^ 2 + (p.Z - center.Z) ^ 2)
		if flat > geometry.Radius - 2 then
			err("hub spawn %d is off the deck", i)
			break
		end
		if killY and p.Y <= killY then
			err("hub spawn %d is below the kill height", i)
			break
		end
	end
	if not (chute and chute.SpawnFrame and finitePos(chute.SpawnFrame.Position)) then
		err("no practice entry")
	else
		local p = chute.SpawnFrame.Position
		local flat = math.sqrt((p.X - center.X) ^ 2 + (p.Z - center.Z) ^ 2)
		if flat > geometry.Radius + 6 then
			err("practice entry is not reachable from the deck (%.0f studs out)", flat - geometry.Radius)
		end
	end
	if not (chute and finite(chute.FinishLineS) and chute.FinishLineS > 0) then
		err("no practice return point")
	end
	return errors
end

function MapLoader.Decide(results, defaultId)
	local enabled, dropped = {}, {}
	local fatal = nil
	for _, result in ipairs(results) do
		local ok = result.ok and #(result.errors or {}) == 0
		if ok then
			enabled[#enabled + 1] = result.id
		elseif result.id == defaultId then
			if result.ok then
				enabled[#enabled + 1] = result.id -- built but with validation notes: keep the safe map
			else
				fatal = "default map failed to build: " .. tostring((result.errors or {})[1])
			end
		else
			dropped[result.id] = tostring((result.errors or {})[1] or "failed")
		end
	end
	return enabled, dropped, fatal
end

return MapLoader
