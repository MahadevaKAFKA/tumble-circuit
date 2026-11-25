--[[
	BotBrain (A4) — pure steering decisions for server bots. Bots use EXACTLY the human motor and
	limits; skill (0.8 / 1.0 / 1.2) only changes decision consistency: reaction interval, aim
	noise and route choice. There is no hidden speed multiplier anywhere.

	Decide(state, ctx) -> steerX, throttle, brake
	ctx = { lateral, lateralVelocity, speed, s, halfWidth, hazards = { {kind, s, offset, radius,
	        lateral (current hammer head), solidCols (tiles ahead)} }, splitAhead (bool),
	        dropAhead (bool), skill, rng (function -> [0,1)), now }
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HazardSim = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("HazardSim"))

local BotBrain = {}

BotBrain.Skills = { 0.8, 1.0, 1.2 }
BotBrain.DividerClearance = 4.2 -- divider half-thickness 0.6 + ball radius 2 + margin
BotBrain.Names = { "Bolt", "Pebble", "Nova", "Ziggy", "Comet", "Marbo", "Quartz", "Glint", "Rivet", "Echo", "Sprocket", "Opal" }

-- Deterministic per-bot RNG (Park-Miller) so tests and replays are reproducible.
function BotBrain.Rng(seed)
	local state = (math.floor(seed) % 2147483646) + 1
	return function()
		state = (state * 48271) % 2147483647
		return state / 2147483647
	end
end

local function clamp(x, lo, hi)
	if x < lo then
		return lo
	elseif x > hi then
		return hi
	end
	return x
end

-- Pure: what a bot "sees" ahead at route distance s (resolved hazards from HazardService, t =
-- hazard clock). Moving hazards are predicted at the bot's ARRIVAL time (ahead / speed), the
-- same information a human gets by watching the telegraphs. Tiles: solid columns of the row
-- the bot will be on.
function BotBrain.HazardContext(resolved, sections, s, speed, t)
	local out = {}
	local v = math.max(speed or 0, 12)
	for _, hz in ipairs(resolved) do
		local frame = hz.Frame
		if frame and hz.Params then
			local ahead = frame.S - s
			local item = { kind = hz.Kind, s = frame.S, offset = hz.Offset or 0, radius = hz.Definition.Radius or hz.Definition.ArmLength }
			local arrival = t + math.max(ahead, 0) / v
			if hz.Kind == "Hammer" then
				item.lateral = HazardSim.HammerLateral(hz.Params, arrival)
			elseif hz.Kind == "Sweeper" then
				item.armSide = math.cos(HazardSim.SweeperAngle(hz.Params, arrival)) -- >0: arm on the right
			elseif hz.Kind == "Tiles" and hz.Piece and sections then
				local p = hz.Params
				local startS = sections[hz.Piece.FirstSection].S
				local endS = sections[hz.Piece.LastSection].S
				item.s = startS
				if s > startS - 30 and s < endS then
					local rowLength = (endS - startS) / p.Rows
					local lookS = math.max(s + 6, startS)
					local row = math.min(p.Rows, math.max(1, math.floor((lookS - startS) / rowLength) + 1))
					local rowArrival = t + math.max(lookS - s, 0) / v
					local cols = {}
					for col = 1, p.Cols do
						if HazardSim.TileState(p, row, col, rowArrival) == "Solid" and HazardSim.TileState(p, row, col, rowArrival + 0.4) == "Solid" then
							cols[#cols + 1] = -frame.Width / 2 + (col - 0.5) * (frame.Width / p.Cols)
						end
					end
					item.solidCols = cols
					item.endS = endS
				end
			end
			out[#out + 1] = item
		end
	end
	return out
end

function BotBrain.ChooseTarget(ctx, state)
	local target = state.laneOffset or 0
	local halfLimit = ctx.halfWidth - 3
	if ctx.splitAhead then
		-- skilled bots take the inside shortcut, others the safe outside lane (decided once)
		if state.splitChoice == nil then
			state.splitChoice = (ctx.rng() < (ctx.skill - 0.6)) and 1 or -1
		end
		target = state.splitChoice * (ctx.halfWidth * 0.5)
	end
	for _, hz in ipairs(ctx.hazards) do
		local ahead = hz.s - ctx.s
		local inTiles = hz.kind == "Tiles" and hz.endS and ctx.s <= hz.endS and ahead < 30
		if (ahead > -4 and ahead < 34) or inTiles then
			if hz.kind == "Sweeper" and hz.armSide then
				-- go to the side the arm will NOT be on when we arrive
				target = hz.armSide > 0 and -(ctx.halfWidth - 3) or (ctx.halfWidth - 3)
			elseif hz.kind == "PulseBumper" then
				local clearance = (hz.radius or 3) + 4.5
				local leftRoom = (hz.offset - clearance) + ctx.halfWidth
				local rightRoom = ctx.halfWidth - (hz.offset + clearance)
				if math.abs(target - hz.offset) < clearance then
					target = rightRoom >= leftRoom and (hz.offset + clearance) or (hz.offset - clearance)
				end
			elseif hz.kind == "Hammer" and hz.lateral then
				target = hz.lateral > 0 and -(ctx.halfWidth - 4) or (ctx.halfWidth - 4)
			elseif hz.kind == "Tiles" and hz.solidCols and #hz.solidCols > 0 then
				local best, bestD = hz.solidCols[1], math.huge
				for _, x in ipairs(hz.solidCols) do
					local d = math.abs(x - ctx.lateral)
					if d < bestD then
						best, bestD = x, d
					end
				end
				target = best
			end
		end
	end
	return clamp(target, -halfLimit, halfLimit)
end

-- Ability timing (same AbilityService and cooldowns as humans). ctx = { ready = {[id]=slot},
-- hazardAhead (studs to the next hitting hazard), nearby (racers within 10 studs), speed, skill, rng }
function BotBrain.ChooseAbility(ctx)
	local ready = ctx.ready
	if ready.Shield and ctx.hazardAhead < 22 and ctx.rng() < 0.35 + 0.4 * (ctx.skill - 0.8) then
		return "Shield"
	end
	if ready.Pulse and ctx.nearby >= 1 and ctx.rng() < 0.5 then
		return "Pulse"
	end
	if ready.Boost and ctx.hazardAhead > 60 and ctx.speed > 20 and ctx.rng() < 0.3 + 0.3 * (ctx.skill - 0.8) then
		return "Boost"
	end
	return nil
end

function BotBrain.Decide(state, ctx)
	local interval = 0.25 / ctx.skill
	if not state.nextDecision or ctx.now >= state.nextDecision then
		state.nextDecision = ctx.now + interval
		local noise = (ctx.rng() - 0.5) * 2 * (1.25 - ctx.skill) * 3 -- studs of aim error
		local target = BotBrain.ChooseTarget(ctx, state) + noise
		if ctx.splitAhead and state.splitChoice then
			-- stay inside the chosen lane: never aim at the centre divider
			local inner, outer = BotBrain.DividerClearance, ctx.halfWidth - 3
			target = state.splitChoice * clamp(target * state.splitChoice, inner, outer)
		elseif not ctx.splitAhead then
			state.splitChoice = nil -- next split is a fresh decision
		end
		state.target = target
	end
	local err = (state.target or 0) - ctx.lateral
	local steer = clamp(err * 0.22 - ctx.lateralVelocity * 0.04, -1, 1)
	local brake = false
	local throttle = 1
	if ctx.dropAhead and ctx.speed > 70 and ctx.rng() < 0.3 + 0.4 * (ctx.skill - 0.8) then
		brake, throttle = true, 0
	end
	return steer, throttle, brake
end

return BotBrain
