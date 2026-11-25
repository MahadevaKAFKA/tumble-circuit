--[[
	HazardService (A4) — the round's hazard seed + epoch, server-driven falling tiles (so bots and
	humans collide with identical floors), and server-side hazard queries for bots.
	Moving hazards (sweeper, hammer, fans, conveyors, trampoline) are NOT moved on the server:
	every machine evaluates HazardSim from (seed, serverTime - epoch). Only tile CanCollide /
	Transparency / Color change here, and only when a tile's state changes (15 Hz check).
	Deterministic reset: a new round = new (seed, epoch); state is a pure function of them.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local HazardSim = require(Shared:WaitForChild("HazardSim"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local Utility = require(Shared:WaitForChild("Utility"))

local HazardService = {}
HazardService.__index = HazardService

function HazardService.new(track)
	local self = setmetatable({}, HazardService)
	self.track = track
	self.seed = 0
	self.epoch = 0
	self.maid = Utility.Maid.new()
	self.tiles = {}
	return self
end

function HazardService:Start()
	local layout = self.track:GetLayout(Protocol.Zones.Race)
	self.resolved = {}
	for _, hz in ipairs(layout.Hazards) do
		self.resolved[#self.resolved + 1] = { Kind = hz.Kind, Id = hz.Id, Definition = hz.Definition, Frame = hz.Frame, FromFrame = hz.FromFrame, Length = hz.Length, Offset = hz.Offset, Piece = hz.Piece }
	end
	self:SetRound(0, 0)
	local root = self.track:GetRaceRoot()
	local hazards = root and root:FindFirstChild("Hazards")
	for _, hz in ipairs(self.resolved) do
		if hz.Kind == "Tiles" then
			local folder = hazards and hazards:FindFirstChild(hz.Id)
			for _, tile in ipairs(folder and folder:GetChildren() or {}) do
				if tile:IsA("BasePart") and tile:GetAttribute("Role") == "Tile" then
					table.insert(self.tiles, { part = tile, hazard = hz, row = tile:GetAttribute("Row"), col = tile:GetAttribute("Col"), baseColor = tile.Color, state = "Solid" })
				end
			end
		end
	end
	local accumulated = 0
	self.maid:Give(RunService.Heartbeat:Connect(function(dt)
		accumulated = accumulated + dt
		if accumulated >= 1 / 15 then
			accumulated = 0
			self:_updateTiles()
		end
	end))
end

function HazardService:SetRound(seed, epoch)
	self.seed = seed % HazardSim.SeedClasses
	self.epoch = epoch
	for _, hz in ipairs(self.resolved or {}) do
		hz.Params = HazardSim.Params(hz.Definition, self.seed)
	end
end

function HazardService:GetSeed()
	return self.seed
end

function HazardService:GetEpoch()
	return self.epoch
end

function HazardService:Time()
	return workspace:GetServerTimeNow() - self.epoch
end

function HazardService:GetResolved()
	return self.resolved
end

function HazardService:_updateTiles()
	local t = self:Time()
	local palette = GameConfig.Palette
	for _, tile in ipairs(self.tiles) do
		local state = HazardSim.TileState(tile.hazard.Params, tile.row, tile.col, t)
		if state ~= tile.state then
			tile.state = state
			local part = tile.part
			if state == "Dropped" then
				part.CanCollide = false
				part.CanQuery = false -- ground probes must not "stand" on a dropped tile
				part.Transparency = 0.85
			else
				part.CanCollide = true
				part.CanQuery = true
				part.Transparency = 0
				part.Color = state == "Telegraph" and palette.Yellow or tile.baseColor
			end
		end
	end
end

-- Bots: velocity change from any moving hazard at `position` (nil if none).
function HazardService:ContactFor(position, radius)
	local t = self:Time()
	for _, hz in ipairs(self.resolved) do
		if hz.Params and hz.Frame and (hz.Kind == "Sweeper" or hz.Kind == "Hammer" or hz.Kind == "Trampoline") then
			local kick = HazardSim.Contact(hz, t, position, radius)
			if kick then
				return kick, hz.Id, hz.Kind
			end
		end
	end
	return nil
end

function HazardService:EnvironmentAccelFor(position)
	local t = self:Time()
	local total = nil
	for _, hz in ipairs(self.resolved) do
		if hz.Params and (hz.Kind == "Fan" or hz.Kind == "Conveyor") then
			local push = HazardSim.EnvironmentAccel(hz, t, position)
			if push then
				total = (total or Vector3.new(0, 0, 0)) + push
			end
		end
	end
	return total
end

function HazardService:Destroy()
	self.maid:Cleanup()
end

return HazardService
