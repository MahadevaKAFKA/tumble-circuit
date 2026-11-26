--[[
	RaceStats (graphics/gameplay brief, milestone A, 2026-11-26) — instrumentation, not gameplay.

	Per race and per gate SECTOR (between two lap targets): resets and falls, and "launches" -
	a marble that was rolling on the floor and is suddenly in the air with upward speed where
	the course has NO kicker, drum, bumper or gap. That is the signature of a collision seam,
	so the playtest data says where to look instead of guessing. Plus finish / DNF counts.
	Pure accumulator (offline-testable); RoundService feeds it and logs a one-line summary per
	race through TelemetryService (aggregate counts only, no personal data).
]]

local RaceStats = {}
RaceStats.__index = RaceStats

RaceStats.LaunchHeight = 2.5 -- studs above the floor
RaceStats.GroundedHeight = 0.6
RaceStats.FeatureRadius = 14 -- studs of route around a kicker / drum / bumper / gap

function RaceStats.new(layout)
	local self = setmetatable({}, RaceStats)
	self.layout = layout
	self.sectors = {} -- [checkpoint index within the lap (0 = from the line)] = { resets, falls, launches }
	self.entities = {}
	self.finished, self.dnf = 0, 0
	-- route ranges where leaving the floor is by design
	self.featureRanges = {}
	local function add(s)
		if s then
			self.featureRanges[#self.featureRanges + 1] = { s - RaceStats.FeatureRadius, s + RaceStats.FeatureRadius }
		end
	end
	for _, z in ipairs(layout.TrickZones or {}) do
		add(z.LipS)
	end
	for _, hz in ipairs(layout.Hazards or {}) do
		if hz.Kind == "Trampoline" or hz.Kind == "PulseBumper" or hz.Kind == "Sweeper" or hz.Kind == "Hammer" or hz.Kind == "Tiles" then
			add(hz.Frame and hz.Frame.S)
		end
	end
	for _, piece in ipairs(layout.Pieces or {}) do
		if piece.Definition.HalfFloor then
			local a = layout.Sections[piece.FirstSection].S
			local b = layout.Sections[piece.LastSection].S
			self.featureRanges[#self.featureRanges + 1] = { a - 20, b + 20 }
		end
	end
	return self
end

function RaceStats:_sector(index)
	local s = self.sectors[index]
	if not s then
		s = { resets = 0, falls = 0, launches = 0 }
		self.sectors[index] = s
	end
	return s
end

-- the checkpoint index within the lap a race distance is in (0 = between the line and gate 1)
function RaceStats:SectorAt(raceS)
	local layout = self.layout
	local lapS = raceS
	if layout.Loop and layout.LapLength then
		lapS = raceS - math.floor(raceS / layout.LapLength) * layout.LapLength
	end
	local index = 0
	for i, cp in ipairs(layout.Checkpoints or {}) do
		if cp.S and lapS >= cp.S then
			index = i
		end
	end
	return index, lapS
end

function RaceStats:_designedAir(lapS)
	for _, r in ipairs(self.featureRanges) do
		if lapS >= r[1] and lapS <= r[2] then
			return true
		end
	end
	return false
end

-- info = the monitor sample { s, height, speed } (height above the floor along the road normal)
function RaceStats:OnSample(entity, info)
	if not info or not info.s or not info.height then
		return
	end
	local e = self.entities[entity]
	if not e then
		e = {}
		self.entities[entity] = e
	end
	local sector, lapS = self:SectorAt(info.s)
	if e.lastHeight and e.lastHeight <= RaceStats.GroundedHeight and info.height >= RaceStats.LaunchHeight and not self:_designedAir(lapS) then
		local entry = self:_sector(sector)
		entry.launches = entry.launches + 1
		entry.launchAt = entry.launchAt or {}
		if #entry.launchAt < 8 then
			entry.launchAt[#entry.launchAt + 1] = math.floor(lapS + 0.5)
		end
	end
	e.lastHeight = info.height
	e.lastS = info.s
end

function RaceStats:OnRespawn(entity, reason)
	local e = self.entities[entity]
	local sector = e and e.lastS and self:SectorAt(e.lastS) or 0
	local entry = self:_sector(sector)
	if reason == "Fell" or reason == "Lost" then
		entry.falls = entry.falls + 1
	elseif reason == "Reset" then
		entry.resets = entry.resets + 1
	end
	if e then
		e.lastHeight = nil -- a respawn is never a launch
	end
end

function RaceStats:OnResult(finished)
	if finished then
		self.finished = self.finished + 1
	else
		self.dnf = self.dnf + 1
	end
end

-- { line = "one-line summary", sectors = { {index, resets, falls, launches, launchAt} } }
function RaceStats:Summary()
	local rows, parts = {}, {}
	for index, s in pairs(self.sectors) do
		rows[#rows + 1] = { index = index, resets = s.resets, falls = s.falls, launches = s.launches, launchAt = s.launchAt }
	end
	table.sort(rows, function(a, b)
		return a.index < b.index
	end)
	for _, r in ipairs(rows) do
		if r.resets + r.falls + r.launches > 0 then
			parts[#parts + 1] = string.format("S%d r%d f%d L%d%s", r.index, r.resets, r.falls, r.launches, r.launchAt and ("@" .. table.concat(r.launchAt, "/")) or "")
		end
	end
	return { line = string.format("finished %d, dnf %d | %s", self.finished, self.dnf, #parts > 0 and table.concat(parts, "  ") or "no resets, falls or seam launches"), sectors = rows }
end

return RaceStats
