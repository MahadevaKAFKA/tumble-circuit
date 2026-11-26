--[[
	Closes a circuit definition:  texlua tools/offline/circuit_solver.lua . NeonFoundryCircuit

	A circuit is authored as pieces whose yaw adds up to 360 degrees. Three values are left to the
	solver (def.Solve): the lengths of two straights A and B (at different headings, so together
	they can cancel any horizontal gap) and the climb pitch C of the ascent pieces (cancels the
	height gap). Newton's method on the REAL generator (TrackDefinitions.Generate, so the numbers
	match the game exactly) drives end - start to ~0. Prints the values to paste into the
	definition, the grid/gate positions re-anchored to the main straight, the footprint, the
	validator result and the lap-time MODEL.
]]

local root = arg[1] or "."
local name = arg[2] or "NeonFoundryCircuit"
local H = dofile(root .. "/tools/offline/harness.lua").new(root)
local TD = H.module("ReplicatedStorage/Shared/TrackDefinitions")
local PC = H.module("ReplicatedStorage/Shared/PhysicsConfig")
local def = assert(TD[name], "no definition " .. name)
local solve = assert(def.Solve, "definition has no Solve block")

local byName = {}
for _, piece in ipairs(def.Pieces) do
	byName[piece.Name] = piece
end
local A, B = byName[solve.A], byName[solve.B]
local climb = {}
for _, n in ipairs(solve.Climb) do
	climb[#climb + 1] = assert(byName[n], "no climb piece " .. n)
end
local C0 = -climb[2].Pitch[1] -- the plateau value (pieces store -C)

local function setClimb(c)
	for _, piece in ipairs(climb) do
		for k = 1, 2 do
			if math.abs(piece.Pitch[k] + C0) < 1e-9 then
				piece.Pitch[k] = -c
			end
		end
	end
	C0 = c
end

local function residual(la, lb, c)
	A.Length, B.Length = la, lb
	setClimb(c)
	local saved = def.Loop
	def.Loop = false -- measure the raw walk (Generate would snap the residual away)
	local layout = TD.Generate(def, PC.Ball.Radius)
	def.Loop = saved
	local first, last = layout.Sections[1].Position, layout.Sections[#layout.Sections].Position
	local d = last - first
	return { d.X, d.Y, d.Z }
end

local x = { A.Length, B.Length, C0 }
for iter = 1, 30 do
	local f = residual(x[1], x[2], x[3])
	local norm = math.sqrt(f[1] ^ 2 + f[2] ^ 2 + f[3] ^ 2)
	io.stderr:write(string.format("iter %d  A=%.3f B=%.3f C=%.4f  |gap|=%.4f\n", iter, x[1], x[2], x[3], norm))
	if norm < 0.01 then
		break
	end
	local J = {}
	local h = { 0.5, 0.5, 0.01 }
	for j = 1, 3 do
		local xp = { x[1], x[2], x[3] }
		xp[j] = xp[j] + h[j]
		local fp = residual(xp[1], xp[2], xp[3])
		for i = 1, 3 do
			J[i] = J[i] or {}
			J[i][j] = (fp[i] - f[i]) / h[j]
		end
	end
	-- solve J dx = -f (Cramer's rule, 3x3)
	local function det(m)
		return m[1][1] * (m[2][2] * m[3][3] - m[2][3] * m[3][2]) - m[1][2] * (m[2][1] * m[3][3] - m[2][3] * m[3][1]) + m[1][3] * (m[2][1] * m[3][2] - m[2][2] * m[3][1])
	end
	local D = det(J)
	local dx = {}
	for j = 1, 3 do
		local M = { { J[1][1], J[1][2], J[1][3] }, { J[2][1], J[2][2], J[2][3] }, { J[3][1], J[3][2], J[3][3] } }
		for i = 1, 3 do
			M[i][j] = -f[i]
		end
		dx[j] = det(M) / D
	end
	local step = 1
	if math.abs(dx[3]) > 2 then
		step = 2 / math.abs(dx[3])
	end
	for j = 1, 3 do
		x[j] = x[j] + dx[j] * step
	end
end

local la, lb, c = x[1], x[2], x[3]
residual(la, lb, c)
print(string.format("-- %s closure: %s.Length = %.2f, %s.Length = %.2f, climb pitch C = %.3f deg", name, solve.A, la, solve.B, lb, c))
local main = byName[def.Grid.Piece].Length -- the grid sits at the end of the main straight
print(string.format("Grid Rows = { %.2f, %.2f, %.2f, %.2f }  StartGate At = %.2f  Spawn At = %.2f", main - 10, main - 16.5, main - 23, main - 29.5, main - 3, main - 48))
def.Grid.Rows = { main - 10, main - 16.5, main - 23, main - 29.5 }
def.StartGate.At = main - 3
def.Spawn.At = main - 48
local layout = TD.Generate(def, PC.Ball.Radius)
local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
for _, sec in ipairs(layout.Sections) do
	minX, maxX = math.min(minX, sec.Position.X), math.max(maxX, sec.Position.X)
	minZ, maxZ = math.min(minZ, sec.Position.Z), math.max(maxZ, sec.Position.Z)
end
print(string.format("lap %.0f studs, closure %.3f, footprint X %.0f..%.0f  Z %.0f..%.0f  Y %.0f..%.0f", layout.LapLength or layout.Route.total, layout.ClosureError, minX, maxX, minZ, maxZ, layout.MinY, layout.MaxY))
local errors = TD.Validate(def, layout)
print(#errors == 0 and "validator: OK" or ("validator: " .. table.concat(errors, " | ")))
local standing, flying, race = TD.EstimateLapSeconds(layout, PC.Movement, 196.2 * (PC.GravityMultiplier or 1), def.Laps)
print(string.format("lap MODEL: standing lap %.1f s, flying lap %.1f s, %d-lap race %.0f s (no hazards/braking/steering losses)", standing, flying, def.Laps or 3, race))
for _, cp in ipairs(layout.Checkpoints) do
	io.write(string.format("  CP %-16s S %6.0f\n", cp.Name, cp.S))
end
