--[[
	ProgressService — live standings (ADR-09): finishers by finish order, then confirmed
	checkpoint index, then route distance capped at the next unconfirmed checkpoint, DNF last,
	ties by stable join ordinal. Path abstraction: progress is "checkpoint index + distance along
	this checkpoint's route segment", so A4 branch lanes only need per-branch route distance.
]]

local RaceRules = require(script.Parent:WaitForChild("RaceRules"))

local ProgressService = {}
ProgressService.__index = ProgressService

function ProgressService.new(checkpointService, physicsService)
	local self = setmetatable({}, ProgressService)
	self.checkpoints = checkpointService
	self.physics = physicsService
	return self
end

-- racers: array of racer records { player, userId, name, ordinal, finished, finishOrdinal,
-- seconds, dnf, isBot }. Returns sorted plain entries with .place.
function ProgressService:Standings(racers)
	local entries = {}
	for _, racer in ipairs(racers) do
		local s = 0
		if racer.player then
			local info = self.physics:GetLastInfo(racer.player)
			if info and info.zone == "Race" then
				s = self.checkpoints:CapProgress(racer.player, info.s)
			elseif racer.lastProgressS then
				s = racer.lastProgressS
			end
			racer.lastProgressS = s
		end
		entries[#entries + 1] = {
			userId = racer.userId,
			name = racer.name,
			isBot = racer.isBot == true,
			ordinal = racer.ordinal,
			finished = racer.finished == true,
			finishOrdinal = racer.finishOrdinal or math.huge,
			seconds = racer.seconds,
			dnf = racer.dnf == true,
			checkpoint = racer.player and self.checkpoints:GetConfirmed(racer.player) or (racer.checkpoint or 0),
			progressS = s,
		}
	end
	return RaceRules.SortStandings(entries)
end

return ProgressService
