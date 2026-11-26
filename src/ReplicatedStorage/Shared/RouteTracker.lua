--[[
	RouteTracker — progress along the course centreline (ADR-09: progress = distance along route,
	never raw height).

	A route is a polyline of ball-centre points with cumulative 3D distance. A tracker remembers
	the last segment and searches a small window around it each update (cheap, and it cannot jump
	to a different part of the course that happens to be nearby). If the marble is far from every
	segment in the window (respawn, big fall) it re-acquires with a full search.

	Pure module: no Roblox services. Used by the client (steering frame, camera) and the server
	(start/finish progress), and by the offline tests.

	Circuits (2026-11-26, route.loop): the polyline closes on itself. Lookups take S modulo the
	lap length, the search window wraps across the start/finish line, and Update returns the
	UNWRAPPED race distance (lap base + lap S) so progress keeps growing lap after lap; `localS`
	is the lap-local value. A new tracker places itself on the right lap from options.hintS
	(the spawn's race S: grid = just below 0, a checkpoint respawn = that checkpoint's race S).
]]

local RouteTracker = {}
RouteTracker.__index = RouteTracker

local function clamp(x, lo, hi)
	if x < lo then
		return lo
	elseif x > hi then
		return hi
	end
	return x
end

function RouteTracker.BuildRoute(points)
	assert(#points >= 2, "route needs at least two points")
	local cumulative = { 0 }
	for i = 2, #points do
		cumulative[i] = cumulative[i - 1] + (points[i] - points[i - 1]).Magnitude
	end
	return { points = points, cumulative = cumulative, total = cumulative[#points] }
end

-- Index i such that cumulative[i] <= s <= cumulative[i + 1] (binary search).
function RouteTracker.SegmentAtS(route, s)
	local cumulative = route.cumulative
	local n = #cumulative
	if route.loop and route.total > 0 then
		s = s - math.floor(s / route.total) * route.total
	end
	if s <= 0 then
		return 1, 0
	end
	if s >= route.total then
		return n - 1, 1
	end
	local lo, hi = 1, n - 1
	while lo < hi do
		local mid = math.floor((lo + hi + 1) / 2)
		if cumulative[mid] <= s then
			lo = mid
		else
			hi = mid - 1
		end
	end
	local segLen = cumulative[lo + 1] - cumulative[lo]
	local t = 0
	if segLen > 1e-9 then
		t = (s - cumulative[lo]) / segLen
	end
	return lo, clamp(t, 0, 1)
end

function RouteTracker.PointAtS(route, s)
	local i, t = RouteTracker.SegmentAtS(route, s)
	local a, b = route.points[i], route.points[i + 1]
	return a + (b - a) * t
end

function RouteTracker.TangentAtS(route, s)
	local i = RouteTracker.SegmentAtS(route, s)
	local d = route.points[i + 1] - route.points[i]
	local m = d.Magnitude
	if m < 1e-9 then
		return Vector3.new(0, 0, -1)
	end
	return d / m
end

-- Gravity-projected (horizontal) tangent. Returns nil on a near-vertical segment so callers keep
-- their last stable direction instead of flipping.
function RouteTracker.HorizontalTangentAtS(route, s)
	local t = RouteTracker.TangentAtS(route, s)
	local flat = Vector3.new(t.X, 0, t.Z)
	local m = flat.Magnitude
	if m < 0.2 then
		return nil
	end
	return flat / m
end

-- Gravity-projected tangent taken from the chord between the route points halfWindow studs before
-- and after s. HorizontalTangentAtS is constant along each polyline segment, so on a curve it jumps
-- by the curve's yaw step (5 deg) at every vertex; anything that follows it (camera, steering frame)
-- then turns in little kicks, which feels like the marble has corners. The chord turns
-- continuously instead, and on a circular arc it is parallel to the true tangent at s, so it does
-- not lag the curve. halfWindow <= 0 falls back to HorizontalTangentAtS.
-- Returns nil on a near-vertical stretch so callers keep their last stable direction.
function RouteTracker.SmoothHorizontalTangentAtS(route, s, halfWindow)
	if not halfWindow or halfWindow <= 0 then
		return RouteTracker.HorizontalTangentAtS(route, s)
	end
	local chord = RouteTracker.PointAtS(route, s + halfWindow) - RouteTracker.PointAtS(route, s - halfWindow)
	local length = chord.Magnitude
	if length < 1e-6 then
		return RouteTracker.HorizontalTangentAtS(route, s)
	end
	local flat = Vector3.new(chord.X, 0, chord.Z)
	local m = flat.Magnitude
	if m < 0.2 * length then
		return nil
	end
	return flat / m
end

local function closestOnSegment(a, b, p)
	local ab = b - a
	local len2 = ab:Dot(ab)
	local t = 0
	if len2 > 1e-9 then
		t = clamp((p - a):Dot(ab) / len2, 0, 1)
	end
	local q = a + ab * t
	return q, t, (p - q).Magnitude
end

function RouteTracker.new(route, options)
	options = options or {}
	local self = setmetatable({}, RouteTracker)
	self.route = route
	self.window = options.window or 6
	self.reacquireDistance = options.reacquireDistance or 45
	self.index = 1
	self.hintS = options.hintS
	self.lapBase = nil -- circuits: race S of this lap's start/finish line
	self.lastLocal = nil
	return self
end

function RouteTracker:Reset()
	self.index = 1
	self.lapBase, self.lastLocal = nil, nil
end

-- Circuits: tell the tracker where the marble is in the race (a respawn on lap k).
function RouteTracker:SetHint(hintS)
	self.hintS = hintS
	self.lapBase, self.lastLocal = nil, nil
end

function RouteTracker:_search(p, first, last)
	local pts = self.route.points
	local segCount = #pts - 1
	local bestD, bestI, bestT, bestQ = math.huge, first, 0, pts[first]
	for k = first, last do
		local i = k
		if self.route.loop then
			i = ((k - 1) % segCount) + 1 -- the window wraps across the start/finish line
		end
		local q, t, d = closestOnSegment(pts[i], pts[i + 1], p)
		if d < bestD then
			bestD, bestI, bestT, bestQ = d, i, t, q
		end
	end
	return bestI, bestT, bestQ, bestD
end

-- Returns { s, index, distance, closest, tangent } for world position p.
function RouteTracker:Update(p)
	local pts = self.route.points
	local segCount = #pts - 1
	local first = math.max(1, self.index - self.window)
	local last = math.min(segCount, self.index + self.window)
	if self.route.loop then
		first, last = self.index - self.window, self.index + self.window
	end
	local i, t, q, d = self:_search(p, first, last)
	if d > self.reacquireDistance then
		i, t, q, d = self:_search(p, 1, segCount)
	end
	self.index = i
	local segVec = pts[i + 1] - pts[i]
	local segLen = segVec.Magnitude
	local tangent = Vector3.new(0, 0, -1)
	if segLen > 1e-9 then
		tangent = segVec / segLen
	end
	local localS = self.route.cumulative[i] + segLen * t
	local s = localS
	if self.route.loop then
		local total = self.route.total
		if self.lapBase == nil then
			local hint = self.hintS or 0
			self.lapBase = math.floor((hint - localS) / total + 0.5) * total
		elseif self.lastLocal ~= nil then
			local delta = localS - self.lastLocal
			if delta < -total / 2 then
				self.lapBase = self.lapBase + total -- crossed the start/finish line forwards
			elseif delta > total / 2 then
				self.lapBase = self.lapBase - total -- ...or backwards
			end
		end
		self.lastLocal = localS
		s = self.lapBase + localS
	end
	return {
		s = s,
		localS = localS,
		index = i,
		distance = d,
		closest = q,
		tangent = tangent,
	}
end

return RouteTracker
