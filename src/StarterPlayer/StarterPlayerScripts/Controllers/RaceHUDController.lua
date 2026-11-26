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
		AnchorPoint = Vector2.new(1, 0), -- top right: Roblox chat lives top left
		Position = UDim2.new(1, -14, 0, 112),
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

	-- A4 course progress bar (own marble's route distance; display only)
	local bar = UIKit.panel(root, {
		Name = "Progress",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 92),
		Size = UDim2.fromOffset(420, 10),
		Visible = false,
	})
	self.progressFill = UIKit.new("Frame", { Name = "Fill", Size = UDim2.fromScale(0, 1), BackgroundColor3 = palette.Cyan, BorderSizePixel = 0 }, bar)
	UIKit.corner(self.progressFill, 0.5)
	self.progressMarks = {}
	self.progressBar = bar
	self.rivalDots = {}
	for i = 1, 12 do
		local dot = UIKit.new("Frame", { Name = "Rival" .. i, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(9, 9), BackgroundColor3 = palette.Coral, BorderSizePixel = 0, Visible = false, ZIndex = 3 }, bar)
		UIKit.corner(dot, 0.5)
		self.rivalDots[i] = dot
	end
	self.youDot = UIKit.new("Frame", { Name = "You", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0, 0.5), Size = UDim2.fromOffset(16, 16), BackgroundColor3 = palette.Mint, BorderSizePixel = 0, ZIndex = 4 }, bar)
	UIKit.corner(self.youDot, 0.5)

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
	UIKit.Punch(self.flash, 1.35, 0.35)
	UIKit.Punch(self.checkpoint, 1.4, 0.3)
	self.flashUntil = os.clock() + 1.4
end

function RaceHUD:Flash(text, color, seconds)
	self.flash.Text = text
	self.flash.TextColor3 = color or palette.Violet
	self.flash.Visible = true
	UIKit.Punch(self.flash, 1.3, 0.3)
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

-- A4: checkpoint ticks on the progress bar (fractions 0..1 of the route).
function RaceHUD:SetCheckpointMarks(fractions)
	for _, mark in ipairs(self.progressMarks) do
		mark:Destroy()
	end
	self.progressMarks = {}
	for i, f in ipairs(fractions) do
		self.progressMarks[i] = UIKit.new("Frame", { Name = "Mark" .. i, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(f, 0.5), Size = UDim2.fromOffset(3, 16), BackgroundColor3 = palette.Violet, BorderSizePixel = 0 }, self.progressBar)
	end
end

-- ctx = { now = serverTime, device, queued, spectatingName, stuck, progress (0..1 or nil),
--         rivals = { fraction, ... } (other racers' progress, computed locally from their marbles) }
-- UI overhaul (2026-11-26): the compact race strip. The placement badge becomes one bar at the
-- top centre - PLACE | TIME | CHECKPOINT - with the course progress line under it; the big
-- status line is only used for countdown / results / spectating. Same labels, same data.
function RaceHUD:UseStrip()
	self.stripMode = true
	local strip = self.badge
	strip.AnchorPoint = Vector2.new(0.5, 0)
	strip.Position = UDim2.new(0.5, 0, 0, 8)
	strip.Size = UDim2.fromOffset(440, 46)
	self.place.Position, self.place.Size = UDim2.fromOffset(12, 4), UDim2.new(0.26, -12, 1, -8)
	self.placeOf.Position, self.placeOf.Size = UDim2.new(0.26, -6, 0, 8), UDim2.new(0.14, 0, 1, -16)
	self.placeOf.TextXAlignment = Enum.TextXAlignment.Left
	self.stripTime = UIKit.label(strip, { Name = "Time", Position = UDim2.new(0.4, 0, 0, 4), Size = UDim2.new(0.32, 0, 1, -8), Font = Enum.Font.GothamBlack, TextColor3 = palette.White, Text = "" })
	self.checkpoint.Position, self.checkpoint.Size = UDim2.new(0.72, 0, 0, 8), UDim2.new(0.28, -12, 1, -16)
	self.progressBar.Position = UDim2.new(0.5, 0, 0, 60)
	self.progressBar.Size = UDim2.fromOffset(440, 8)
end

function RaceHUD:SetDensity(density)
	self.density = density
end

-- the course being raced (countdown cue says which one)
function RaceHUD:SetCourseName(name)
	self.courseName = name
end

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
		-- owner request 2026-11-25: the timer keeps running with "Waiting for players" under it
		-- until the race is full; then READY can start it early
		if snap.readyOpen then
			sub = string.format("Race full - tap READY to start now (%d/%d ready)", snap.readyCount or 0, snap.queuedCount or 0)
		else
			sub = string.format("Waiting for players (%d/%d)", snap.queuedCount or 0, snap.raceCapacity or 16)
		end
		if not ctx.queued then
			sub = sub .. " - tap JOIN RACE to race"
		end
	elseif snap.state == S.Preparing then
		status, sub = "GET READY", me and "To the start grid!" or "Racers to the grid"
		if self.stripMode and self.courseName then
			status = string.upper(self.courseName) -- one cue: the course actually selected
		end
	elseif snap.state == S.Countdown then
		status, sub = "GET READY", me and "Wait for GO" or "Race starting"
		if self.stripMode and self.courseName then
			status = string.upper(self.courseName)
		end
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
		sub = "SPECTATING  " .. ctx.spectatingName .. "   (PREV / NEXT to switch)"
	end
	local stripRacing = self.stripMode and snap.state == S.Racing and me ~= nil and not me.finished
	if stripRacing then
		-- the strip carries place / time / checkpoint; the big status line stays clear of the track
		UIKit.setText(self.stripTime, status)
		status = ""
		sub = self.density == "Compact" and "" or sub
	end
	UIKit.setText(self.status, status)
	UIKit.setText(self.sub, sub)
	self.sub.Visible = not (self.density == "Compact" and snap.state == S.Racing and me ~= nil)

	-- placement + checkpoint chip
	self.badge.Visible = racing and snap.state == S.Racing and me ~= nil
	if self.badge.Visible then
		UIKit.setText(self.place, me.finished and UIKit.ordinal(me.place) or UIKit.ordinal(me.place))
		UIKit.setText(self.placeOf, (self.stripMode and "/ " or "of ") .. #snap.racers)
		if self.stripMode and me.finished then
			UIKit.setText(self.stripTime, me.seconds and Utility.formatTime(me.seconds) or "")
		end
		UIKit.setText(self.checkpoint, me.finished and "FINISHED" or string.format("CP %d / %d", me.checkpoint, snap.checkpointTotal))
	end

	self.progressBar.Visible = ctx.progress ~= nil and snap.state == S.Racing and me ~= nil and not me.finished
	if self.progressBar.Visible then
		local f = math.clamp(ctx.progress, 0, 1)
		self.progressFill.Size = UDim2.fromScale(f, 1)
		self.youDot.Position = UDim2.fromScale(f, 0.5)
		for i, dot in ipairs(self.rivalDots) do
			local rf = ctx.rivals and ctx.rivals[i]
			dot.Visible = rf ~= nil and self.density ~= "Compact"
			if rf then
				dot.Position = UDim2.fromScale(math.clamp(rf, 0, 1), 0.5)
			end
		end
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
		if countdownText ~= self.lastCountdown then
			UIKit.Punch(self.countdown, countdownText == "GO!" and 1.8 or 1.55, 0.4) -- each number lands with a punch
		end
		UIKit.setText(self.countdown, countdownText)
		self.countdown.TextColor3 = countdownText == "GO!" and palette.Mint or palette.Yellow
	end

	self.lastCountdown = countdownText
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
