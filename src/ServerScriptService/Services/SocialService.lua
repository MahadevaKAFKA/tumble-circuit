--[[
	SocialService (A6) — spectator Chaos Vote, quick emotes and the hub podium displays.

	Chaos Vote: VoteRules decides; every change is broadcast with VoteState:
	  { phase = "Open", pollId, options, closesAt }      eligible clients show two buttons
	  { phase = "Result", pollId, winner, counts, modifier = {kind, startsAt, endsAt} }
	  { phase = "NoVotes", pollId } | { phase = "Closed" }
	The modifier goes to HazardService (bots) and RoundService (snapshot, for late joiners);
	clients apply the same timestamps to their own marble. Racers see it announced LeadSeconds
	before it starts. Leaving Racing cancels the poll and the modifier; finished results are
	never touched (it only changes hazards).
	Quick emotes: QuickEmote(id 1..3) -> EmoteShown { userId, id } to everyone, one per player per
	CooldownSeconds, preset ids only (no free text: chat stays with TextChatService).
	Podium: at Results the top three get anchored, non-colliding display marbles with name
	tags on the Orbital Garage podium; they stay until the next race's results.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local RoundProtocol = require(Shared:WaitForChild("RoundProtocol"))
local SocialConfig = require(Shared:WaitForChild("SocialConfig"))
local TrackDefinitions = require(Shared:WaitForChild("TrackDefinitions"))
local Utility = require(Shared:WaitForChild("Utility"))
local VoteRules = require(script.Parent:WaitForChild("VoteRules"))

local SocialService = {}
SocialService.__index = SocialService

local S = RoundProtocol.States

function SocialService.new(deps)
	local self = setmetatable({}, SocialService)
	self.round = deps.round
	self.hazards = deps.hazards
	self.remotes = deps.remotes
	self.hubBuilder = deps.hubBuilder
	self.maid = Utility.Maid.new()
	self.pollId = 0
	self.poll = nil
	self.lastPollAt = nil
	self.modifier = nil
	self.emoteCooldown = {}
	self.voteLimiter = Utility.RateLimiter.new(RoundProtocol.Remotes.CastSpectatorVote.MinInterval)
	self.emoteLimiter = Utility.RateLimiter.new(RoundProtocol.Remotes.QuickEmote.MinInterval)
	self.podiumParts = {}
	return self
end

function SocialService:Start()
	self.maid:Give(self.remotes:WaitForChild("CastSpectatorVote").OnServerEvent:Connect(function(player, ...)
		if RoundProtocol.ValidateArgs("CastSpectatorVote", ...) and self.voteLimiter:Try(player) then
			self:Vote(player, ...)
		end
	end))
	self.maid:Give(self.remotes:WaitForChild("QuickEmote").OnServerEvent:Connect(function(player, ...)
		if RoundProtocol.ValidateArgs("QuickEmote", ...) and self.emoteLimiter:Try(player) then
			self:Emote(player, ...)
		end
	end))
	self.maid:Give(Players.PlayerRemoving:Connect(function(player)
		self.emoteCooldown[player] = nil -- a cast vote stays counted (keyed by UserId)
		self.voteLimiter:Forget(player)
		self.emoteLimiter:Forget(player)
	end))
	self.maid:Give(self.round.StateChanged:Connect(function(state, snapshot)
		if state ~= S.Racing then
			self:_stopVoting()
		end
		if state == S.Racing then
			self.lastPollAt = nil
		end
		if state == S.Results then
			self:_buildPodium(snapshot.racers)
		end
	end))
	local accumulated = 0
	self.maid:Give(RunService.Heartbeat:Connect(function(dt)
		accumulated = accumulated + dt
		if accumulated >= 0.25 then
			accumulated = 0
			self:_tick()
		end
	end))
end

---------------------------------------------------------------------------------------------
-- Chaos Vote
---------------------------------------------------------------------------------------------
function SocialService:_counts()
	local eligible, active = 0, 0
	for _, player in ipairs(Players:GetPlayers()) do
		if VoteRules.Eligible({ isHuman = true, isActiveRacer = self.round:IsActiveRacer(player) }) then
			eligible = eligible + 1
		end
	end
	active = #self.round:GetActiveRacers()
	return eligible, active
end

function SocialService:_tick()
	local cfg = SocialConfig.Vote
	local now = workspace:GetServerTimeNow()
	local round = self.round
	if self.poll and self.poll.open and now >= self.poll.closesAt then
		self:_closePoll(now)
	end
	if round.state ~= S.Racing or not round.raceStartedAt or not round.stateEndsAt then
		return
	end
	local eligible, active = self:_counts()
	if VoteRules.ShouldOpen({
		state = round.state,
		pollOpen = self.poll ~= nil and self.poll.open,
		eligible = eligible,
		activeRacers = active,
		secondsLeft = round.stateEndsAt - now,
		raceElapsed = now - round.raceStartedAt,
		lastPollAt = self.lastPollAt,
		now = now,
		modifierBusyUntil = self.modifier and self.modifier.endsAt or 0,
	}, cfg) then
		self.pollId = self.pollId + 1
		self.poll = VoteRules.NewPoll(self.pollId, now, cfg)
		self.lastPollAt = now
		self:_broadcast({ phase = "Open", pollId = self.pollId, options = cfg.Options, closesAt = self.poll.closesAt })
	end
end

function SocialService:_closePoll(now)
	local cfg = SocialConfig.Vote
	local poll = self.poll
	poll.open = false
	self.lastPollAt = now
	local winner = VoteRules.Tally(poll)
	if not winner then
		self:_broadcast({ phase = "NoVotes", pollId = poll.id })
		return
	end
	local option = cfg.Options[winner]
	local modifier = { kind = option.id, label = option.label, description = option.description, startsAt = now + cfg.LeadSeconds, endsAt = now + cfg.LeadSeconds + cfg.DurationSeconds }
	self:_setModifier(modifier)
	self:_broadcast({ phase = "Result", pollId = poll.id, winner = winner, counts = { poll.counts[1] or 0, poll.counts[2] or 0 }, modifier = modifier })
end

function SocialService:_setModifier(modifier)
	self.modifier = modifier
	if self.hazards then
		self.hazards:SetModifier(modifier)
	end
	self.round:SetChaosModifier(modifier)
end

function SocialService:_stopVoting()
	local had = (self.poll and self.poll.open) or self.modifier ~= nil
	self.poll = nil
	if self.modifier then
		self:_setModifier(nil)
	end
	if had then
		self:_broadcast({ phase = "Closed" })
	end
end

function SocialService:Vote(player, pollId, option)
	if not VoteRules.Eligible({ isHuman = true, isActiveRacer = self.round:IsActiveRacer(player) }) then
		return false
	end
	local ok = VoteRules.Cast(self.poll, player.UserId, pollId, option, workspace:GetServerTimeNow())
	if ok then
		self.remotes.VoteState:FireClient(player, { phase = "Voted", pollId = pollId, option = option })
	end
	return ok
end

function SocialService:_broadcast(payload)
	self.remotes.VoteState:FireAllClients(payload)
end

---------------------------------------------------------------------------------------------
-- Quick emotes
---------------------------------------------------------------------------------------------
function SocialService:Emote(player, id)
	local now = os.clock()
	if (self.emoteCooldown[player] or 0) > now then
		return false
	end
	self.emoteCooldown[player] = now + SocialConfig.Emotes.CooldownSeconds
	self.remotes.EmoteShown:FireAllClients({ userId = player.UserId, id = id })
	return true
end

---------------------------------------------------------------------------------------------
-- Podium (hub): three display marbles for the last race's top three
---------------------------------------------------------------------------------------------
function SocialService:_buildPodium(racers)
	for _, part in ipairs(self.podiumParts) do
		part:Destroy()
	end
	self.podiumParts = {}
	local hubRoot = workspace:FindFirstChild(Protocol.HubModelName)
	if not hubRoot or not self.hubBuilder or not self.hubBuilder.PodiumSpots then
		return
	end
	local palette = GameConfig.Palette
	local spots = self.hubBuilder.PodiumSpots(TrackDefinitions.Hub)
	for place = 1, math.min(3, #racers) do
		local entry = racers[place]
		local spot = spots[place]
		if entry and spot and entry.finished then
			local ball = Instance.new("Part")
			ball.Name = "PodiumMarble" .. place
			ball.Shape = Enum.PartType.Ball
			ball.Size = Vector3.new(4, 4, 4)
			ball.Anchored, ball.CanCollide, ball.CanQuery, ball.CanTouch = true, false, false, false
			ball.Material = Enum.Material.SmoothPlastic
			ball.Reflectance = 0.25
			ball.Color = entry.isBot and palette.Coral or palette.Cyan
			ball.CFrame = CFrame.new(spot + Vector3.new(0, 2, 0))
			local light = Instance.new("PointLight")
			light.Color = place == 1 and palette.Yellow or palette.White
			light.Range = 10
			light.Brightness = 1.5
			light.Parent = ball
			local tag = Instance.new("BillboardGui")
			tag.Size = UDim2.fromOffset(200, 50)
			tag.StudsOffsetWorldSpace = Vector3.new(0, 4, 0)
			tag.MaxDistance = 120
			tag.LightInfluence = 0
			local label = Instance.new("TextLabel")
			label.Size = UDim2.fromScale(1, 1)
			label.BackgroundTransparency = 1
			label.TextScaled = true
			label.Font = Enum.Font.GothamBlack
			label.TextColor3 = place == 1 and palette.Yellow or palette.White
			label.TextStrokeTransparency = 0.3
			label.Text = string.format("%d. %s%s", place, entry.isBot and "[BOT] " or "", tostring(entry.name))
			label.Parent = tag
			tag.Parent = ball
			ball.Parent = hubRoot
			table.insert(self.podiumParts, ball)
		end
	end
end

function SocialService:GetPollId()
	return self.pollId
end

function SocialService:Destroy()
	self.maid:Cleanup()
	for _, part in ipairs(self.podiumParts) do
		part:Destroy()
	end
end

return SocialService
