--[[
	DevService (A5) — test tools for the owner. Exists only when RunService:IsStudio() or when
	GameConfig.Dev.AuthorizedUserIds lists accounts; otherwise the DevCommand remote is never
	created (ServerBootstrap) and this service does nothing. Every command re-checks the caller.
	Coin grants and profile resets work ONLY on Studio MOCK profiles, never on saved data.
	Commands (DevCommand(cmd, number)):
	  StartNow 0      skip the intermission timer (Intermission -> Preparing now)
	  EndRace 0       end the running race (-> Results)
	  Bots n          fixed bot count for the next races (n = 0, 3, 7...); -1 = back to auto fill
	  MockCoins n     add n Coins to YOUR mock profile (Studio mock only)
	  ResetMock 0     reset YOUR mock profile to defaults (Studio mock only)
	  Diag 0          state / racers / bots / perf / profile mode summary
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local RaceConfig = require(Shared:WaitForChild("RaceConfig"))
local RoundProtocol = require(Shared:WaitForChild("RoundProtocol"))
local Utility = require(Shared:WaitForChild("Utility"))

local DevService = {}
DevService.__index = DevService

function DevService.Enabled()
	return RunService:IsStudio() or #GameConfig.Dev.AuthorizedUserIds > 0
end

function DevService.IsAuthorized(player)
	if RunService:IsStudio() then
		return true
	end
	for _, id in ipairs(GameConfig.Dev.AuthorizedUserIds) do
		if player.UserId == id then
			return true
		end
	end
	return false
end

function DevService.new(deps)
	local self = setmetatable({}, DevService)
	self.round = deps.round
	self.bots = deps.bots
	self.playerData = deps.playerData
	self.remotes = deps.remotes
	self.maid = Utility.Maid.new()
	self.limiter = Utility.RateLimiter.new(RoundProtocol.Remotes.DevCommand.MinInterval)
	return self
end

function DevService:Start()
	local remote = self.remotes:FindFirstChild("DevCommand")
	if not remote or not DevService.Enabled() then
		return
	end
	self.maid:Give(remote.OnServerEvent:Connect(function(player, ...)
		if not DevService.IsAuthorized(player) then
			warn("[Dev] refused DevCommand from unauthorized " .. player.Name)
			return
		end
		if RoundProtocol.ValidateArgs("DevCommand", ...) and self.limiter:Try(player) then
			local text = self:Run(player, ...)
			local out = self.remotes:FindFirstChild("DevResult")
			if out then
				out:FireClient(player, { text = text })
			end
		end
	end))
	print("[Dev] dev panel enabled (" .. (RunService:IsStudio() and "Studio" or "authorized accounts") .. ")")
end

function DevService:Run(player, command, number)
	local S = RoundProtocol.States
	local round = self.round
	if command == "StartNow" then
		if round.state == S.Intermission or round.state == S.Lobby then
			if round.state == S.Lobby then
				round:_transition(S.Intermission)
			end
			round.deadline = os.clock()
			return "starting now"
		end
		return "only from Lobby/Intermission (state " .. round.state .. ")"
	elseif command == "EndRace" then
		return round:EndRound("dev panel") and "race ended" or "no race running"
	elseif command == "Bots" then
		if number < 0 then
			RaceConfig.Bots.FixedCount = nil
			return "bots: auto fill to " .. RaceConfig.Bots.FillTo
		end
		RaceConfig.Bots.FixedCount = math.clamp(math.floor(number), 0, 19)
		return "bots: fixed " .. RaceConfig.Bots.FixedCount .. " from the next race"
	elseif command == "MockCoins" then
		local profile = self.playerData:GetProfile(player)
		if not profile or profile.status ~= "Mock" then
			return "refused: only Studio MOCK profiles can be granted test Coins"
		end
		local amount = math.clamp(math.floor(number), 0, 100000)
		self.playerData:Update(player, function(data)
			data.coins = data.coins + amount
		end)
		return "mock +" .. amount .. " Coins"
	elseif command == "ResetMock" then
		return self.playerData:ResetMockProfile(player) and "mock profile reset" or "refused: not a mock profile"
	elseif command == "Diag" then
		local profile = self.playerData:GetProfile(player)
		return string.format(
			"state %s round %d | racers %d | bots %d | humans %d | profiles %s (%s) | server frame p95 %s ms | instances %s",
			round.state, round.roundId, #round.racers, self.bots and self.bots:Count() or 0, #Players:GetPlayers(),
			self.playerData:GetMode(), profile and profile.status or "?",
			tostring(workspace:GetAttribute("Perf_ServerFrameP95Ms")), tostring(workspace:GetAttribute("Perf_Instances"))
		)
	end
	return "unknown command " .. tostring(command)
end

function DevService:Destroy()
	self.maid:Cleanup()
end

return DevService
