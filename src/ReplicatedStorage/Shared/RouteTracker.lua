--[[
	RouteTracker — progress along the course centreline (ADR-09: progress = distance along route,
	never raw height).

	A route is a polyline of ball-centre points with cumulative 3D distance. A tracker remembers
	the last segment and searches a small window around it each update (cheap, and it cannot jump
	to a different part of the course that happens to be nearby). If the marble is far from every
	segment in the window (respawn, big fall) it re-acquires with a full search.

	Pure module: no Roblox services. Used by the client (steering frame, camera) and the server
	(start/finish progress), and by the offline tests.
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
	return self
end

function RouteTracker:Reset()
	self.index = 1
end

function RouteTracker:_search(p, first, last)
	local pts = self.route.points
	local bestD, bestI, bestT, bestQ = math.huge, first, 0, pts[first]
	for i = first, last do
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
	return {
		s = self.route.cumulative[i] + segLen * t,
		index = i,
		distance = d,
		closest = q,
		tangent = tangent,
	}
end

return RouteTracker
