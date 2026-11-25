--[[
	TrackValidator — A4 world validation (pure; offline + Studio). Runs TrackDefinitions.Validate
	and adds the module contract checks:
	  * every module's ExitPort meets the next EntryPort (position <= 0.01 stud, tangent dot
	    >= 0.9999, same width), modules have positive route length
	  * 8-20 spawn slots; start, finish, ordered checkpoints (base validator)
	  * every hazard kind has a controller and resolves for every seed class; moving hazards stay
	    inside the lane at all sampled times; falling tiles always leave a passable path
	  * split-lane dividers end inside their piece so both lanes join the route again
	A graph check cannot prove a human can finish: Studio Play tests do (TEST_PLAN §7).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local TrackDefinitions = require(Shared:WaitForChild("TrackDefinitions"))
local HazardSim = require(Shared:WaitForChild("HazardSim"))

local TrackValidator = {}

TrackValidator.KnownHazards = { PulseBumper = true, Sweeper = true, Hammer = true, Tiles = true, Fan = true, Conveyor = true, Trampoline = true }

function TrackValidator.Validate(def, layout)
	local errors = TrackDefinitions.Validate(def, layout)
	local function fail(msg)
		errors[#errors + 1] = msg
	end

	for i = 1, #layout.Modules - 1 do
		local a, b = layout.Modules[i], layout.Modules[i + 1]
		if (a.Exit.Position - b.Entry.Position).Magnitude > 0.01 then
			fail(string.format("module %s exit does not meet %s entry", a.Name, b.Name))
		end
		if a.Exit.Forward:Dot(b.Entry.Forward) < 0.9999 then
			fail(string.format("module %s -> %s facing mismatch", a.Name, b.Name))
		end
		if math.abs(a.Exit.Width - b.Entry.Width) > 0.01 then
			fail(string.format("module %s -> %s width mismatch", a.Name, b.Name))
		end
	end
	for _, m in ipairs(layout.Modules) do
		if not (m.RouteLength and m.RouteLength > 0) then
			fail("module " .. m.Name .. " has no route length")
		end
	end
	local slots = #layout.GridSlots
	if def.Grid and (slots < 8 or slots > 20) then
		fail("spawn slots must be 8-20, has " .. slots)
	end

	for _, piece in ipairs(layout.Pieces) do
		local divider = piece.Definition.Divider
		if divider and (divider.From <= 0 or divider.To >= piece.Definition.Length) then
			fail("divider in " .. piece.Name .. " must start and end inside the piece (both lanes rejoin)")
		end
	end

	for _, hz in ipairs(layout.Hazards) do
		if not TrackValidator.KnownHazards[hz.Kind] then
			fail("hazard " .. tostring(hz.Id) .. " has no controller for kind " .. tostring(hz.Kind))
		elseif hz.Frame then
			local half = hz.Frame.Width / 2
			for seed = 0, HazardSim.SeedClasses - 1 do
				local p = HazardSim.Params(hz.Definition, seed)
				if hz.Kind == "Hammer" then
					for t = 0, p.Period, p.Period / 24 do
						local lateral = HazardSim.HammerLateral(p, t)
						if math.abs(lateral) + p.HeadSize / 2 > half - 1 then
							fail("hammer " .. hz.Id .. " leaves the lane (seed " .. seed .. ")")
							break
						end
					end
				elseif hz.Kind == "Tiles" then
					for t = 0, p.Period, p.Period / 48 do
						local solidCols = {}
						for row = 1, p.Rows do
							solidCols[row] = {}
							local solid = 0
							for col = 1, p.Cols do
								if HazardSim.TileState(p, row, col, t) ~= "Dropped" then
									solid = solid + 1
									solidCols[row][col] = true
								end
							end
							if solid < 2 then
								fail(string.format("tiles %s row %d has < 2 solid tiles (seed %d, t %.2f)", hz.Id, row, seed, t))
							end
						end
						for row = 1, p.Rows - 1 do
							local shared = false
							for col = 1, p.Cols do
								if solidCols[row][col] and solidCols[row + 1][col] then
									shared = true
								end
							end
							if not shared then
								fail(string.format("tiles %s rows %d/%d share no solid column (seed %d, t %.2f)", hz.Id, row, row + 1, seed, t))
							end
						end
					end
				elseif hz.Kind == "Sweeper" then
					if not (p.Speed > 0 and p.Speed <= 2) then
						fail("sweeper " .. hz.Id .. " speed out of range (seed " .. seed .. ")")
					end
				elseif hz.Kind == "Fan" then
					if p.OnSeconds <= 0 or p.OffSeconds < p.TelegraphSeconds then
						fail("fan " .. hz.Id .. " cycle invalid (seed " .. seed .. ")")
					end
				end
			end
		end
	end
	return errors
end

return TrackValidator
