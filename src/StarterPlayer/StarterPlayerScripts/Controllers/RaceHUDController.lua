--[[
	RaceHUDController — A2 match HUD driven only by server snapshots + the shared server clock:
	  top centre    status line (next race countdown / race timer / results) + sub line
	  top left      placement badge (2ND of 5) and checkpoint chip (CP 2/3) while you race
	  centre        3-2-1-GO (same server timestamp on every client), checkpoint flash
	  right         Tab / D-pad up standings list
	  bottom centre "Stuck? hold R" hint (client heuristic: trying to move, no progress, slow)
	The client never decides placement or checkpoints; it only displays what the server sent.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local RaceConfig = require(Shared:WaitForChild("RaceConfig"))
local RoundProtocol = require(Shared:WaitForChild("RoundProtocol"))
local Utility = require(Shared:WaitForChild("Utility"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local RaceHUD = {}
RaceHUD.__index = RaceHUD

local S = RoundProtocol.States
local palette = UIKit.Palette

local RECOVER_HINT = {
	KeyboardMouse = "Stuck? Hold R to recover",
	Gamepad = "Stuck? Hold Y to recover",
	Touch = "Stuck? Hold RESET to recover",
}

function RaceHUD.new()
	local self = setmetatable({}, RaceHUD)
	local gui, root, maid = UIKit.screen("TumbleRaceHUD", 6)
	self.gui, self.root, self.maid = gui, root, maid
	self.snapshot = nil
	self.localUserId = nil
	self.flashUntil = 0
	self.standingsVisible = false

	self.status = UIKit.label(root, {
		Name = "Status",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 6),
		Size = UDim2.fromOffset(460, 56),
		Font = Enum.Font.GothamBlack,
		TextStrokeTransparency = 0.4,
	})
	self.sub = UIKit.label(root, {
		Name = "Sub",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 64),
		Size = UDim2.fromOffset(560, 24),
		TextColor3 = palette.Cyan,
		TextStrokeTransparency = 0.5,
	})

	local badge = UIKit.panel(root, {
		Name = "Placement",
		Position = UDim2.fromOffset(14, 40),
		Size = UDim2.fromOffset(150, 96),
		Visible = false,
	})
	UIKit.new("UIStroke", { Color = palette.Yellow, Thickness = 2 }, badge)
	self.place = UIKit.label(badge, { Size = UDim2.new(1, 0, 0.62, 0), Font = Enum.Font.GothamBlack, TextColor3 = palette.Yellow, Text = "-" })
	self.placeOf = UIKit.label(badge, { Position = UDim2.fromScale(0, 0.58), Size = UDim2.new(1, 0, 0.2, 0), Font = Enum.Font.Gotham, Text = "" })
	self.checkpoint = UIKit.label(badge, { Position = UDim2.fromScale(0, 0.78), Size = UDim2.new(1, 0, 0.2, 0), TextColor3 = palette.Violet, Text = "" })
	self.badge = badge

	self.countdown = UIKit.label(root, {
		Name = "Countdown",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.4),
		Size = UDim2.fromOffset(360, 200),
		Font = Enum.Font.GothamBlack,
		TextColor3 = palette.Yellow,
		TextStrokeTransparency = 0.2,
		Visible = false,
	})
	self.flash = UIKit.label(root, {
		Name = "Flash",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.24),
		Size = UDim2.fromOffset(560, 48),
		Font = Enum.Font.GothamBlack,
		TextColor3 = palette.Violet,
		TextStrokeTransparency = 0.3,
		Visible = false,
	})
	self.stuck = UIKit.label(root, {
		Name = "Stuck",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -96),
		Size = UDim2.fromOffset(460, 30),
		TextColor3 = palette.Yellow,
		TextStrokeTransparency = 0.3,
		Visible = false,
	})

	local list = UIKit.panel(root, {
		Name = "Standings",
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -14, 0.5, 0),
		Size = UDim2.fromOffset(300, 300),
		Visible = false,
	})
	self.standingsTitle = UIKit.label(list, { Position = UDim2.fromOffset(12, 8), Size = UDim2.new(1, -24, 0, 26), Font = Enum.Font.GothamBlack, TextColor3 = palette.Cyan, Text = "STANDINGS", TextXAlignment = Enum.TextXAlignment.Left })
	self.rows = {}
	for i = 1, 8 do
		self.rows[i] = UIKit.label(list, {
			Position = UDim2.fromOffset(12, 40 + (i - 1) * 31),
			Size = UDim2.new(1, -24, 0, 26),
			TextXAlignment = Enum.TextXAlignment.Left,
			Font = Enum.Font.Gotham,
		})
	end
	self.list = list
	return self
end

function RaceHUD:SetVisible(visible)
	self.gui.Enabled = visible
end

function RaceHUD:ApplySnapshot(snapshot, localUserId)
	self.snapshot = snapshot
	self.localUserId = localUserId
end

function RaceHUD:GetLocalEntry()
	local snap = self.snapshot
	if not snap then
		return nil
	end
	for _, entry in ipairs(snap.racers or {}) do
		if entry.userId == self.localUserId then
			return entry
		end
	end
	return nil
end

function RaceHUD:FlashCheckpoint(index, total)
	self.flash.Text = string.format("CHECKPOINT %d / %d", index, total)
	self.flash.Visible = true
	self.flashUntil = os.clock() + 1.4
end

function RaceHUD:Flash(text, color, seconds)
	self.flash.Text = text
	self.flash.TextColor3 = color or palette.Violet
	self.flash.Visible = true
	self.flashUntil = os.clock() + (seconds or 1.4)
end

function RaceHUD:ToggleStandings()
	self.standingsVisible = not self.standingsVisible
end

local function remaining(snap, now)
	if not snap.stateEndsAt then
		return nil
	end
	return math.max(0, snap.stateEndsAt - now)
end

-- ctx = { now = serverTime, device, queued, spectatingName, stuck }
function RaceHUD:Update(ctx)
	local snap = self.snapshot
	if not snap then
		UIKit.setText(self.status, "CONNECTING...")
		return
	end
	local now = ctx.now
	local me = self:GetLocalEntry()
	local racing = me ~= nil and (snap.state == S.Racing or snap.state == S.Countdown or snap.state == S.Preparing)
	local left = remaining(snap, now)
	local status, sub = "", ""

	if snap.state == S.Lobby or snap.state == S.Boot then
		status, sub = "WAITING FOR RACERS", "Roll down the practice chute"
	elseif snap.state == S.Intermission then
		status = "NEXT RACE  " .. Utility.formatTime(left or 0):gsub("%.%d+$", "")
		sub = ctx.queued and "You're in the next race" or "Sitting out - tap JOIN RACE to race"
	elseif snap.state == S.Preparing then
		status, sub = "GET READY", me and "To the start grid!" or "Racers to the grid"
	elseif snap.state == S.Countdown then
		status, sub = "GET READY", me and "Wait for GO" or "Race starting"
	elseif snap.state == S.Racing then
		local elapsed = snap.raceStartedAt and (now - snap.raceStartedAt) or 0
		if me and me.finished then
			status = "FINISHED  " .. UIKit.ordinal(me.place)
			sub = me.seconds and Utility.formatTime(me.seconds) or ""
		elseif me then
			status = Utility.formatTime(elapsed)
			sub = string.format("Race ends in %s", Utility.formatTime(left or 0):gsub("%.%d+$", ""))
		else
			status = "RACE IN PROGRESS  " .. Utility.formatTime(elapsed):gsub("%.%d+$", "")
			sub = ctx.queued and "You're in the next race - SPECTATE to watch" or "Sitting out - SPECTATE to watch"
		end
	elseif snap.state == S.Results then
		status, sub = "RESULTS", "Next race soon"
	elseif snap.state == S.Cleanup then
		status, sub = "NEXT RACE SOON", ""
	end
	if ctx.spectatingName then
		sub = "SPECTATING  " .. ctx.spectatingName .. "   (Q / E to switch)"
	end
	UIKit.setText(self.status, status)
	UIKit.setText(self.sub, sub)

	-- placement + checkpoint chip
	self.badge.Visible = racing and snap.state == S.Racing and me ~= nil
	if self.badge.Visible then
		UIKit.setText(self.place, me.finished and UIKit.ordinal(me.place) or UIKit.ordinal(me.place))
		UIKit.setText(self.placeOf, "of " .. #snap.racers)
		UIKit.setText(self.checkpoint, me.finished and "FINISHED" or string.format("CP %d / %d", me.checkpoint, snap.checkpointTotal))
	end

	-- 3-2-1-GO from the shared server clock
	local countdownText = nil
	if me and snap.state == S.Countdown and left then
		countdownText = tostring(math.max(1, math.ceil(left)))
	elseif me and snap.state == S.Racing and snap.raceStartedAt and now - snap.raceStartedAt < RaceConfig.Timers.GoBannerSeconds then
		countdownText = "GO!"
	end
	self.countdown.Visible = countdownText ~= nil
	if countdownText then
		UIKit.setText(self.countdown, countdownText)
		self.countdown.TextColor3 = countdownText == "GO!" and palette.Mint or palette.Yellow
	end

	if self.flash.Visible and os.clock() > self.flashUntil then
		self.flash.Visible = false
	end
	self.stuck.Visible = ctx.stuck == true
	if ctx.stuck then
		UIKit.setText(self.stuck, RECOVER_HINT[ctx.device] or RECOVER_HINT.KeyboardMouse)
	end

	-- standings list
	local showList = self.standingsVisible and #(snap.racers or {}) > 0
	self.list.Visible = showList
	if showList then
		for i, row in ipairs(self.rows) do
			local entry = snap.racers[i]
			if entry then
				local detail
				if entry.finished then
					detail = entry.seconds and Utility.formatTime(entry.seconds) or "FIN"
				elseif entry.dnf then
					detail = "DNF"
				else
					detail = "CP " .. entry.checkpoint
				end
				local tag = entry.isBot and "[BOT] " or ""
				UIKit.setText(row, string.format("%d. %s%s   %s", entry.place, tag, entry.name, detail))
				row.TextColor3 = entry.userId == self.localUserId and palette.Yellow or palette.White
				row.Visible = true
			else
				row.Visible = false
			end
		end
	end
end

function RaceHUD:Destroy()
	self.maid:Cleanup()
end

return RaceHUD
