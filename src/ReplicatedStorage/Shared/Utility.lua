--[[
	Utility — small shared helpers: cleanup (Maid), signals, frame-rate-independent smoothing,
	vector helpers, input deadzones and time formatting.

	Written in the Lua 5.1 subset of Luau (no type annotations) so the pure parts can also be
	executed by the offline test harness in tools/offline.
]]

local Utility = {}

---------------------------------------------------------------------------------------------
-- Maid: owns connections / instances / functions / objects and cleans them up in reverse order.
---------------------------------------------------------------------------------------------
local Maid = {}
Maid.__index = Maid

function Maid.new()
	return setmetatable({ _tasks = {} }, Maid)
end

function Maid:Give(item)
	if item ~= nil then
		table.insert(self._tasks, item)
	end
	return item
end

function Maid:Cleanup()
	local items = self._tasks
	self._tasks = {}
	for i = #items, 1, -1 do
		local item = items[i]
		local kind = typeof(item)
		if kind == "RBXScriptConnection" then
			item:Disconnect()
		elseif kind == "Instance" then
			item:Destroy()
		elseif kind == "function" then
			item()
		elseif kind == "thread" then
			pcall(task.cancel, item)
		elseif kind == "table" then
			if type(item.Destroy) == "function" then
				item:Destroy()
			elseif type(item.Disconnect) == "function" then
				item:Disconnect()
			end
		end
	end
end

Maid.Destroy = Maid.Cleanup
Utility.Maid = Maid

---------------------------------------------------------------------------------------------
-- Signal: synchronous, error-isolated (one failing handler never stops the others).
---------------------------------------------------------------------------------------------
local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ _entries = {} }, Signal)
end

function Signal:Connect(fn)
	local entries = self._entries
	local entry = { fn = fn, connected = true }
	table.insert(entries, entry)
	local connection = { Connected = true }
	function connection:Disconnect()
		if not entry.connected then
			return
		end
		entry.connected = false
		connection.Connected = false
		for i = #entries, 1, -1 do
			if entries[i] == entry then
				table.remove(entries, i)
				break
			end
		end
	end
	return connection
end

function Signal:Fire(...)
	local snapshot = {}
	for i, entry in ipairs(self._entries) do
		snapshot[i] = entry
	end
	for _, entry in ipairs(snapshot) do
		if entry.connected then
			local ok, err = pcall(entry.fn, ...)
			if not ok then
				warn("[TumbleCircuit] signal handler error: " .. tostring(err))
			end
		end
	end
end

function Signal:DisconnectAll()
	for _, entry in ipairs(self._entries) do
		entry.connected = false
	end
	self._entries = {}
end

Signal.Destroy = Signal.DisconnectAll
Utility.Signal = Signal

---------------------------------------------------------------------------------------------
-- Math
---------------------------------------------------------------------------------------------
function Utility.clamp(x, lo, hi)
	if x < lo then
		return lo
	elseif x > hi then
		return hi
	end
	return x
end

function Utility.lerp(a, b, t)
	return a + (b - a) * t
end

-- Exponential smoothing factor for a rate (1/s) over dt seconds. Exact for any dt, so smoothing
-- behaves the same at 30, 60 or 144 FPS and never needs dt clamping.
function Utility.expAlpha(rate, dt)
	if rate <= 0 or dt <= 0 then
		return 0
	end
	return 1 - math.exp(-rate * dt)
end

function Utility.safeUnit(v, fallback)
	local m = v.Magnitude
	if m < 1e-6 or m ~= m then
		return fallback
	end
	return v / m
end

function Utility.flatten(v)
	return Vector3.new(v.X, 0, v.Z)
end

function Utility.projectOnPlane(v, normal)
	return v - normal * v:Dot(normal)
end

-- Turn unit vector `current` toward unit vector `target` by fraction alpha.
-- If they are nearly opposite, turn through a perpendicular instead of collapsing through zero,
-- which is what would otherwise cause a sudden 180-degree snap.
function Utility.turnToward(current, target, alpha, axis)
	if current:Dot(target) < -0.995 then
		local perp = current:Cross(axis or Vector3.yAxis)
		target = Utility.safeUnit(perp, target)
	end
	return Utility.safeUnit(current:Lerp(target, alpha), current)
end

-- Radial deadzone with rescale so output still reaches 1.0 at full deflection.
function Utility.radialDeadzone(x, y, deadzone)
	local m = math.sqrt(x * x + y * y)
	if m <= deadzone or m < 1e-6 then
		return 0, 0
	end
	local scaled = math.min(1, (m - deadzone) / (1 - deadzone))
	return x / m * scaled, y / m * scaled
end

function Utility.formatTime(seconds)
	if type(seconds) ~= "number" or seconds ~= seconds then
		return "--.--"
	end
	if seconds < 0 then
		seconds = 0
	end
	local minutes = math.floor(seconds / 60)
	local rest = seconds - minutes * 60
	if minutes > 0 then
		return string.format("%d:%05.2f", minutes, rest)
	end
	return string.format("%.2f", rest)
end

-- Per-key rate limiter (server remote throttling, client double-press guards).
local RateLimiter = {}
RateLimiter.__index = RateLimiter

function RateLimiter.new(minInterval, clock)
	return setmetatable({ minInterval = minInterval, clock = clock or os.clock, last = {} }, RateLimiter)
end

function RateLimiter:Try(key)
	local now = self.clock()
	local last = self.last[key]
	if last and now - last < self.minInterval then
		return false
	end
	self.last[key] = now
	return true
end

function RateLimiter:Forget(key)
	self.last[key] = nil
end

Utility.RateLimiter = RateLimiter

return Utility
