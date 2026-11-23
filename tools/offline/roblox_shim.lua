--[[
	Minimal Roblox datatype shim for running the PURE Tumble Circuit modules outside Studio
	(Vector3, Vector2, CFrame, Color3, typeof, math.clamp/sign/round, warn, task).

	This is test scaffolding only. It mirrors the documented Roblox semantics for the subset the
	pure modules use; it is not a Roblox emulator and proves nothing about engine behaviour.
]]

local shim = {}

---------------------------------------------------------------------------------- Vector3
local V3 = {}
V3.__index = function(v, k)
	if k == "X" then
		return rawget(v, 1)
	elseif k == "Y" then
		return rawget(v, 2)
	elseif k == "Z" then
		return rawget(v, 3)
	elseif k == "Magnitude" then
		return math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
	elseif k == "Unit" then
		local m = math.sqrt(v[1] * v[1] + v[2] * v[2] + v[3] * v[3])
		if m == 0 then
			return shim.Vector3.new(0 / 0, 0 / 0, 0 / 0)
		end
		return shim.Vector3.new(v[1] / m, v[2] / m, v[3] / m)
	end
	return V3.methods[k]
end
V3.methods = {}
local function isV3(x)
	return getmetatable(x) == V3
end
local function newV3(x, y, z)
	return setmetatable({ x or 0, y or 0, z or 0 }, V3)
end
V3.__add = function(a, b)
	return newV3(a[1] + b[1], a[2] + b[2], a[3] + b[3])
end
V3.__sub = function(a, b)
	return newV3(a[1] - b[1], a[2] - b[2], a[3] - b[3])
end
V3.__mul = function(a, b)
	if type(a) == "number" then
		return newV3(b[1] * a, b[2] * a, b[3] * a)
	elseif type(b) == "number" then
		return newV3(a[1] * b, a[2] * b, a[3] * b)
	end
	return newV3(a[1] * b[1], a[2] * b[2], a[3] * b[3])
end
V3.__div = function(a, b)
	if type(b) == "number" then
		return newV3(a[1] / b, a[2] / b, a[3] / b)
	end
	return newV3(a[1] / b[1], a[2] / b[2], a[3] / b[3])
end
V3.__unm = function(a)
	return newV3(-a[1], -a[2], -a[3])
end
V3.__eq = function(a, b)
	return a[1] == b[1] and a[2] == b[2] and a[3] == b[3]
end
V3.__tostring = function(a)
	return string.format("%.4f, %.4f, %.4f", a[1], a[2], a[3])
end
function V3.methods.Dot(a, b)
	return a[1] * b[1] + a[2] * b[2] + a[3] * b[3]
end
function V3.methods.Cross(a, b)
	return newV3(a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1])
end
function V3.methods.Lerp(a, b, t)
	return a + (b - a) * t
end
function V3.methods.FuzzyEq(a, b, eps)
	eps = eps or 1e-5
	return math.abs(a[1] - b[1]) <= eps and math.abs(a[2] - b[2]) <= eps and math.abs(a[3] - b[3]) <= eps
end
shim.Vector3 = {
	new = newV3,
	zero = newV3(0, 0, 0),
	one = newV3(1, 1, 1),
	xAxis = newV3(1, 0, 0),
	yAxis = newV3(0, 1, 0),
	zAxis = newV3(0, 0, 1),
}

---------------------------------------------------------------------------------- Vector2
local V2 = {}
V2.__index = function(v, k)
	if k == "X" then
		return rawget(v, 1)
	elseif k == "Y" then
		return rawget(v, 2)
	elseif k == "Magnitude" then
		return math.sqrt(v[1] * v[1] + v[2] * v[2])
	end
	return nil
end
local function newV2(x, y)
	return setmetatable({ x or 0, y or 0 }, V2)
end
V2.__add = function(a, b)
	return newV2(a[1] + b[1], a[2] + b[2])
end
V2.__sub = function(a, b)
	return newV2(a[1] - b[1], a[2] - b[2])
end
V2.__mul = function(a, b)
	if type(a) == "number" then
		return newV2(b[1] * a, b[2] * a)
	end
	return newV2(a[1] * b, a[2] * b)
end
shim.Vector2 = { new = newV2, zero = newV2(0, 0) }

---------------------------------------------------------------------------------- CFrame
local CF = {}
local function newCF(p, xv, yv, zv)
	return setmetatable({ p = p, xv = xv, yv = yv, zv = zv }, CF)
end
local function rot(cf, v)
	return cf.xv * v[1] + cf.yv * v[2] + cf.zv * v[3]
end
local function rotT(cf, v)
	return newV3(cf.xv:Dot(v), cf.yv:Dot(v), cf.zv:Dot(v))
end
CF.__index = function(cf, k)
	if k == "Position" or k == "p" then
		return rawget(cf, "p")
	elseif k == "X" then
		return rawget(cf, "p")[1]
	elseif k == "Y" then
		return rawget(cf, "p")[2]
	elseif k == "Z" then
		return rawget(cf, "p")[3]
	elseif k == "LookVector" then
		return -rawget(cf, "zv")
	elseif k == "RightVector" or k == "XVector" then
		return rawget(cf, "xv")
	elseif k == "UpVector" or k == "YVector" then
		return rawget(cf, "yv")
	elseif k == "ZVector" then
		return rawget(cf, "zv")
	end
	return CF.methods[k]
end
CF.methods = {}
CF.__mul = function(a, b)
	if getmetatable(b) == CF then
		return newCF(a.p + rot(a, b.p), rot(a, b.xv), rot(a, b.yv), rot(a, b.zv))
	end
	return a.p + rot(a, b)
end
CF.__add = function(a, v)
	return newCF(a.p + v, a.xv, a.yv, a.zv)
end
function CF.methods.PointToObjectSpace(cf, v)
	return rotT(cf, v - cf.p)
end
function CF.methods.PointToWorldSpace(cf, v)
	return cf.p + rot(cf, v)
end
function CF.methods.VectorToWorldSpace(cf, v)
	return rot(cf, v)
end
function CF.methods.VectorToObjectSpace(cf, v)
	return rotT(cf, v)
end
function CF.methods.Inverse(cf)
	local xv = newV3(cf.xv[1], cf.yv[1], cf.zv[1])
	local yv = newV3(cf.xv[2], cf.yv[2], cf.zv[2])
	local zv = newV3(cf.xv[3], cf.yv[3], cf.zv[3])
	local inv = newCF(newV3(0, 0, 0), xv, yv, zv)
	inv.p = -rot(inv, cf.p)
	return inv
end
shim.CFrame = {}
function shim.CFrame.new(a, b, c)
	if type(a) == "number" then
		return newCF(newV3(a, b, c), newV3(1, 0, 0), newV3(0, 1, 0), newV3(0, 0, 1))
	end
	a = a or newV3(0, 0, 0)
	return newCF(a, newV3(1, 0, 0), newV3(0, 1, 0), newV3(0, 0, 1))
end
function shim.CFrame.fromMatrix(p, vx, vy, vz)
	vz = vz or vx:Cross(vy).Unit
	return newCF(p, vx, vy, vz)
end
function shim.CFrame.lookAt(at, target, up)
	up = up or newV3(0, 1, 0)
	local look = (target - at).Unit
	local right = look:Cross(up).Unit
	local up2 = right:Cross(look)
	return newCF(at, right, up2, -look)
end
function shim.CFrame.Angles(rx, ry, rz)
	local function rotX(a)
		local c, s = math.cos(a), math.sin(a)
		return newCF(newV3(0, 0, 0), newV3(1, 0, 0), newV3(0, c, s), newV3(0, -s, c))
	end
	local function rotY(a)
		local c, s = math.cos(a), math.sin(a)
		return newCF(newV3(0, 0, 0), newV3(c, 0, -s), newV3(0, 1, 0), newV3(s, 0, c))
	end
	local function rotZ(a)
		local c, s = math.cos(a), math.sin(a)
		return newCF(newV3(0, 0, 0), newV3(c, s, 0), newV3(-s, c, 0), newV3(0, 0, 1))
	end
	return rotX(rx) * rotY(ry) * rotZ(rz)
end

---------------------------------------------------------------------------------- Color3
local C3 = {}
C3.__index = C3
local function newC3(r, g, b)
	return setmetatable({ R = r, G = g, B = b }, C3)
end
function C3:Lerp(o, t)
	return newC3(self.R + (o.R - self.R) * t, self.G + (o.G - self.G) * t, self.B + (o.B - self.B) * t)
end
shim.Color3 = {
	new = newC3,
	fromRGB = function(r, g, b)
		return newC3(r / 255, g / 255, b / 255)
	end,
	fromHex = function(hex)
		hex = hex:gsub("#", "")
		assert(#hex == 6, "bad hex " .. hex)
		return newC3(tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255)
	end,
}

---------------------------------------------------------------------------------- globals
function shim.typeof(v)
	local mt = getmetatable(v)
	if mt == V3 then
		return "Vector3"
	elseif mt == V2 then
		return "Vector2"
	elseif mt == CF then
		return "CFrame"
	elseif mt == C3 then
		return "Color3"
	end
	return type(v)
end

function shim.install(env)
	env.Vector3 = shim.Vector3
	env.Vector2 = shim.Vector2
	env.CFrame = shim.CFrame
	env.Color3 = shim.Color3
	env.typeof = shim.typeof
	env.warn = function(...)
		print("WARN", ...)
	end
	env.task = {
		spawn = function(f, ...)
			return f(...)
		end,
		cancel = function() end,
	}
	math.clamp = function(x, lo, hi)
		assert(lo <= hi, "math.clamp: min > max")
		if x < lo then
			return lo
		elseif x > hi then
			return hi
		end
		return x
	end
	math.sign = function(x)
		if x > 0 then
			return 1
		elseif x < 0 then
			return -1
		end
		return 0
	end
	math.round = function(x)
		if x >= 0 then
			return math.floor(x + 0.5)
		end
		return math.ceil(x - 0.5)
	end
end

shim.isV3 = isV3
return shim
