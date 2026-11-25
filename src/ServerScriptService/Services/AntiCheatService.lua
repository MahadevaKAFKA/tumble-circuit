--[[
	AntiCheatService (D3) — one place that sees the suspicious signals the A2–C services already
	reject, so a pattern stands out. It never bans and never blocks play by itself: every service
	still rejects bad input on its own. Occasional lag-like events decay away.
	Signals:
	  - every client -> server remote: malformed arguments (RoundProtocol.ValidateArgs) and floods
	    (more than FloodFactor x the remote's allowed rate over a 5 s window)
	  - RacePhysicsService.MovementRejected (implausible movement), checkpoint "Rejected" events
	  - explicit Flag() calls: receipt replays / unknown products, capsule refusals
	Each category scores per player with a half-life; crossing a threshold logs ONE warning and
	sets the player attribute TC_Suspicion (for the owner's review in Studio/live logs).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RoundProtocol = require(Shared:WaitForChild("RoundProtocol"))
local Utility = require(Shared:WaitForChild("Utility"))

local AntiCheatService = {}
AntiCheatService.__index = AntiCheatService

AntiCheatService.HalfLifeSeconds = 60
AntiCheatService.FloodFactor = 3
AntiCheatService.Thresholds = { Malformed = 5, Flood = 3, Movement = 6, Checkpoint = 6, ReceiptUnknownProduct = 1, ReceiptReplay = 20, Capsule = 10 }

function AntiCheatService.new(deps)
	local self = setmetatable({}, AntiCheatService)
	self.remotes = deps.remotes
	self.physics = deps.physics
	self.clock = os.clock
	self.scores = {} -- [player] = { [category] = { score, at, reported } }
	self.windows = {} -- [player] = { [remote] = { start, count } }
	self.maid = Utility.Maid.new()
	return self
end

-- Pure: decayed score after `dt` seconds
function AntiCheatService.Decay(score, dt)
	return score * 0.5 ^ (dt / AntiCheatService.HalfLifeSeconds)
end

-- Pure: is this many calls in a 5 s window a flood for a remote with MinInterval?
function AntiCheatService.IsFlood(count, minInterval)
	local allowed = 5 / math.max(minInterval or 0.1, 0.05)
	return count > allowed * AntiCheatService.FloodFactor
end

function AntiCheatService:Flag(player, category, detail)
	local now = self.clock()
	local perPlayer = self.scores[player] or {}
	self.scores[player] = perPlayer
	local entry = perPlayer[category] or { score = 0, at = now, reported = false }
	entry.score = AntiCheatService.Decay(entry.score, now - entry.at) + 1
	entry.at = now
	perPlayer[category] = entry
	local threshold = AntiCheatService.Thresholds[category] or 5
	if entry.score >= threshold and not entry.reported then
		entry.reported = true
		warn(string.format("[AntiCheat] %s (%d): %s x%.1f (%s) - review, no action taken", player.Name, player.UserId, category, entry.score, tostring(detail)))
		if player.Parent then
			player:SetAttribute("TC_Suspicion", (player:GetAttribute("TC_Suspicion") or 0) + 1)
		end
	elseif entry.score < threshold / 2 then
		entry.reported = false
	end
	return entry.score
end

function AntiCheatService:GetScore(player, category)
	local entry = self.scores[player] and self.scores[player][category]
	if not entry then
		return 0
	end
	return AntiCheatService.Decay(entry.score, self.clock() - entry.at)
end

function AntiCheatService:_watchRemote(remote)
	local spec = RoundProtocol.Remotes[remote.Name]
	if not spec or spec.Direction ~= "ClientToServer" or not remote:IsA("RemoteEvent") then
		return
	end
	self.maid:Give(remote.OnServerEvent:Connect(function(player, ...)
		local ok, why = RoundProtocol.ValidateArgs(remote.Name, ...)
		if not ok then
			self:Flag(player, "Malformed", remote.Name .. ": " .. tostring(why))
		end
		local now = self.clock()
		local perPlayer = self.windows[player] or {}
		self.windows[player] = perPlayer
		local w = perPlayer[remote.Name]
		if not w or now - w.start > 5 then
			w = { start = now, count = 0 }
			perPlayer[remote.Name] = w
		end
		w.count = w.count + 1
		if AntiCheatService.IsFlood(w.count, spec.MinInterval) and not w.flagged then
			w.flagged = true
			self:Flag(player, "Flood", remote.Name)
		end
	end))
end

function AntiCheatService:Start()
	for _, child in ipairs(self.remotes:GetChildren()) do
		self:_watchRemote(child)
	end
	self.maid:Give(self.remotes.ChildAdded:Connect(function(child)
		self:_watchRemote(child)
	end))
	if self.physics and self.physics.MovementRejected then
		self.maid:Give(self.physics.MovementRejected:Connect(function(player)
			if typeof(player) == "Instance" and player:IsA("Player") then
				self:Flag(player, "Movement", "implausible movement")
			end
		end))
	end
	self.maid:Give(Players.PlayerRemoving:Connect(function(player)
		self.scores[player] = nil
		self.windows[player] = nil
	end))
end

function AntiCheatService:Destroy()
	self.maid:Cleanup()
end

return AntiCheatService
