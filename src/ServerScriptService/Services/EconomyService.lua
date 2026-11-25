--[[
	EconomyService (A5) — grants race Coins/XP once per raceId + player, only from the server's
	own results (RoundService.RaceFinished). There is no client request that grants anything.
	* raceId = server JobId (or a per-session GUID in Studio) + roundId: unique across servers.
	* Activity (AFK guard): RoundService marks a racer active on ReportActive / ability / trick /
	  recover input during Racing. Idle racers get nothing; that is shown, not hidden.
	* Bot practice = exactly one human + bots: transparent daily multiplier (ProgressionConfig).
	* Players who left before Results get nothing for that race (documented; no pending grants).
	* After a grant the profile is saved soon; the client only shows "saved" after it happened.
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local Utility = require(Shared:WaitForChild("Utility"))
local RewardRules = require(script.Parent:WaitForChild("RewardRules"))

local EconomyService = {}
EconomyService.__index = EconomyService

function EconomyService.new(deps)
	local self = setmetatable({}, EconomyService)
	self.round = deps.round
	self.playerData = deps.playerData
	self.track = deps.track
	self.hazards = deps.hazards
	self.remotes = deps.remotes
	self.maid = Utility.Maid.new()
	self.serverId = game.JobId ~= "" and game.JobId or ("studio-" .. HttpService:GenerateGUID(false))
	self.Granted = Utility.Signal.new() -- (player, notice)
	return self
end

function EconomyService:Start()
	self.maid:Give(self.round.RaceFinished:Connect(function(roundId, results)
		self:GrantRace(roundId, results)
	end))
end

function EconomyService:GrantRace(roundId, results)
	local raceId = RewardRules.RaceId(self.serverId, roundId)
	local layout = self.track:GetLayout(Protocol.Zones.Race)
	local def = layout.Definition
	local humans, bots = 0, 0
	for _, entry in ipairs(results) do
		if entry.isBot then
			bots = bots + 1
		else
			humans = humans + 1
		end
	end
	local ctx = {
		worldId = def.Id,
		layoutVersion = def.LayoutVersion,
		seedClass = self.hazards and self.hazards:GetSeed() or 0,
		mode = "Race",
		utcDay = RewardRules.UtcDay(os.time()),
		minPlausibleSeconds = GameConfig.Run.MinPlausibleSeconds,
	}
	for _, entry in ipairs(results) do
		if not entry.isBot then
			local player = self.round:GetPlayerByUserId(entry.userId)
			if player and player.Parent then
				local result = {
					finished = entry.finished == true,
					place = entry.place,
					count = #results,
					seconds = entry.seconds,
					active = entry.active == true,
					checkpoint = entry.checkpoint,
					progressFraction = (entry.progressS or 0) / layout.Route.total,
					botPractice = humans == 1 and bots > 0,
				}
				local notice
				local updated = self.playerData:Update(player, function(data)
					notice = RewardRules.Apply(data, raceId, result, ctx)
				end)
				if updated and notice then
					notice.grantedAt = os.time()
					notice.roundId = roundId
					notice.saveStatus = self.playerData:GetProfile(player).status
					self.remotes.RewardNotice:FireClient(player, notice)
					self.playerData:SaveSoon(player)
					self.Granted:Fire(player, notice)
				end
			end
		end
	end
end

function EconomyService:Destroy()
	self.maid:Cleanup()
end

return EconomyService
