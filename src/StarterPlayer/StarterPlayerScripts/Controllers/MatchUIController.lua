--[[
	MatchUIController — A2 round UI outside the live race readouts:
	  * Results overlay (top three + your place, server times / DNF) with PLAY AGAIN and SIT OUT
	    (both are RequestJoinRace(bool); the fixed round timer is never affected)
	  * queue button while you are not racing. It is labelled with what tapping it does: SIT OUT
    while you are queued, JOIN RACE while you are sitting out (owner playtest 2026-11-23: a chip
    that showed the current state read as "tap to join" and sat the player out instead).
    Taps update the button at once; the next snapshot confirms.
  * PLAY AGAIN / SIT OUT on the results panel also close the panel (the round timer is fixed,
    so the buttons only choose the next race; closing shows they worked)
	  * READY button (owner request 2026-11-25) under the queue button during the intermission, only
    while the race is full; every queued player READY = the race starts without the timer
  * spectate controls when a race is running and you are not (or no longer) racing
	  * the hub's holographic board (updated locally from the snapshot; no server writes)
	No reward/currency placeholders (economy arrives in A5).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local RaceConfig = require(Shared:WaitForChild("RaceConfig"))
local RoundProtocol = require(Shared:WaitForChild("RoundProtocol"))
local Utility = require(Shared:WaitForChild("Utility"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local MatchUI = {}
MatchUI.__index = MatchUI

local S = RoundProtocol.States
local palette = UIKit.Palette

function MatchUI.new()
	local self = setmetatable({}, MatchUI)
	local gui, root, maid = UIKit.screen("TumbleMatchUI", 8)
	self.gui, self.root, self.maid = gui, root, maid
	self.snapshot = nil
	self.localUserId = nil
	self.queued = true
	self.pendingQueue = nil -- { value, untilClock }: a tap the server has not confirmed yet
	self.dismissedRound = nil -- results panel closed by the player for this round id
	self.JoinRequested = Utility.Signal.new() -- (wantsToRace)
	self.ReadyRequested = Utility.Signal.new() -- (ready)
	self.amReady = false
	self.pendingReady = nil -- { value, untilClock }
	self.SpectateToggled = Utility.Signal.new()
	self.SpectateCycle = Utility.Signal.new() -- (direction)

	-- Queue chip (top right, under the camera/reset buttons)
	self.queueButton = UIKit.button(root, {
		Name = "Queue",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 112),
		Size = UDim2.fromOffset(190, 44),
		Text = "SIT OUT",
	}, palette.White)
	maid:Give(self.queueButton.Activated:Connect(function()
		self:_requestQueue(not self.queued)
	end))

	-- READY vote (under the queue button; only while the race is full)
	self.readyButton = UIKit.button(root, {
		Name = "Ready",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 166),
		Size = UDim2.fromOffset(190, 56),
		Text = "READY",
		Visible = false,
	}, palette.Mint)
	maid:Give(self.readyButton.Activated:Connect(function()
		local wants = not self.amReady
		self.amReady = wants
		self.pendingReady = { value = wants, untilClock = os.clock() + 2 }
		self.ReadyRequested:Fire(wants)
		self:_renderReady()
	end))

	-- Spectate controls (bottom centre, above the speed readout)
	local spectate = UIKit.new("Frame", {
		Name = "Spectate",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -90),
		Size = UDim2.fromOffset(360, 48),
		BackgroundTransparency = 1,
		Visible = false,
	}, root)
	self.spectatePrev = UIKit.button(spectate, { Size = UDim2.fromOffset(60, 48), Text = "<" }, palette.Cyan)
	self.spectateMain = UIKit.button(spectate, { Position = UDim2.fromOffset(70, 0), Size = UDim2.fromOffset(220, 48), Text = "SPECTATE" }, palette.Cyan)
	self.spectateNext = UIKit.button(spectate, { Position = UDim2.fromOffset(300, 0), Size = UDim2.fromOffset(60, 48), Text = ">" }, palette.Cyan)
	maid:Give(self.spectateMain.Activated:Connect(function()
		self.SpectateToggled:Fire()
	end))
	maid:Give(self.spectatePrev.Activated:Connect(function()
		self.SpectateCycle:Fire(-1)
	end))
	maid:Give(self.spectateNext.Activated:Connect(function()
		self.SpectateCycle:Fire(1)
	end))
	self.spectateFrame = spectate

	-- Results overlay
	local results = UIKit.panel(root, {
		Name = "Results",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(620, 430),
		BackgroundTransparency = 0.08,
		Visible = false,
	})
	UIKit.new("UIStroke", { Color = palette.Cyan, Thickness = 2 }, results)
	UIKit.label(results, { Position = UDim2.fromOffset(0, 14), Size = UDim2.new(1, 0, 0, 56), Font = Enum.Font.GothamBlack, TextColor3 = palette.Cyan, Text = "RACE RESULTS" })
	self.resultRows = {}
	local colors = { palette.Yellow, palette.White, palette.Coral }
	for i = 1, 4 do
		self.resultRows[i] = UIKit.label(results, {
			Position = UDim2.fromOffset(40, 84 + (i - 1) * 50),
			Size = UDim2.new(1, -80, 0, 40),
			TextXAlignment = Enum.TextXAlignment.Left,
			Font = i <= 3 and Enum.Font.GothamBlack or Enum.Font.GothamBold,
			TextColor3 = colors[i] or palette.Mint,
		})
	end
	self.resultsTimer = UIKit.label(results, { Position = UDim2.fromOffset(0, 290), Size = UDim2.new(1, 0, 0, 26), Font = Enum.Font.Gotham, TextTransparency = 0.2 })
	self.playAgain = UIKit.button(results, {
		Name = "PlayAgain",
		Position = UDim2.fromOffset(60, 334),
		Size = UDim2.fromOffset(280, 72),
		Text = "PLAY AGAIN",
	}, palette.Mint)
	self.sitOut = UIKit.button(results, {
		Name = "SitOut",
		Position = UDim2.fromOffset(360, 334),
		Size = UDim2.fromOffset(200, 72),
		Text = "SIT OUT",
	}, palette.White)
	maid:Give(self.playAgain.Activated:Connect(function()
		self:_requestQueue(true)
		self:DismissResults()
	end))
	maid:Give(self.sitOut.Activated:Connect(function()
		self:_requestQueue(false)
		self:DismissResults()
	end))
	self.results = results
	return self
end

function MatchUI:SetVisible(visible)
	self.gui.Enabled = visible
end

function MatchUI:IsResultsOpen()
	return self.results.Visible
end

-- Ask to race (true) or sit out (false) in the next round. Shown immediately; the server's
-- snapshot confirms (or, after 2 s without confirmation, wins).
function MatchUI:_requestQueue(wants)
	self.queued = wants
	self.pendingQueue = { value = wants, untilClock = os.clock() + 2 }
	self.JoinRequested:Fire(wants)
	self:_renderReady()
end

-- Close the results panel for the current round (it opens again for the next round's results).
function MatchUI:DismissResults()
	if self.snapshot then
		self.dismissedRound = self.snapshot.roundId
	end
	self.results.Visible = false
end

function MatchUI:ApplySnapshot(snapshot, localUserId)
	self.snapshot = snapshot
	self.localUserId = localUserId
	local serverQueued = snapshot.queued and snapshot.queued[tostring(localUserId)] == true or false
	local pending = self.pendingQueue
	if pending and os.clock() < pending.untilClock and serverQueued ~= pending.value then
		self.queued = pending.value -- this snapshot predates the tap; keep showing the tap
	else
		self.pendingQueue = nil
		self.queued = serverQueued
	end
	local serverReady = snapshot.ready ~= nil and snapshot.ready[tostring(localUserId)] == true
	local pendingReady = self.pendingReady
	if pendingReady and os.clock() < pendingReady.untilClock and serverReady ~= pendingReady.value then
		self.amReady = pendingReady.value -- snapshot predates the tap
	else
		self.pendingReady = nil
		self.amReady = serverReady
	end
	self:_renderResults()
	self:_renderReady()
end

-- READY button: shown in the intermission while the race is full and you are racing next.
function MatchUI:_renderReady()
	local snap = self.snapshot
	local show = snap ~= nil and snap.state == S.Intermission and snap.readyOpen == true and self.queued
	self.readyButton.Visible = show
	if not show then
		return
	end
	local count = snap.readyCount or 0
	if self.amReady and not (snap.ready and snap.ready[tostring(self.localUserId)]) then
		count = count + 1 -- the tap is on its way
	end
	local needed = snap.queuedCount or 0
	UIKit.setText(self.readyButton, string.format("%s %d/%d", self.amReady and "READY" or "READY?", math.min(count, needed), needed))
	self.readyButton.TextColor3 = self.amReady and palette.Mint or palette.Yellow
end

function MatchUI:_renderResults()
	local snap = self.snapshot
	local show = snap ~= nil and snap.state == S.Results and snap.roundId ~= self.dismissedRound
	self.results.Visible = show
	if not show then
		return
	end
	local mine = nil
	for _, entry in ipairs(snap.racers or {}) do
		if entry.userId == self.localUserId then
			mine = entry
		end
	end
	local function describe(entry)
		local detail = entry.dnf and "DNF" or (entry.seconds and Utility.formatTime(entry.seconds) or "")
		local tag = entry.isBot and "[BOT] " or ""
		return string.format("%s  %s%s   %s", UIKit.ordinal(entry.place), tag, entry.name, detail)
	end
	for i = 1, 3 do
		local entry = snap.racers[i]
		self.resultRows[i].Text = entry and describe(entry) or ""
	end
	if mine and mine.place > 3 then
		self.resultRows[4].Text = "You: " .. describe(mine)
	elseif not mine then
		self.resultRows[4].Text = "You watched this one - you're queued for the next race"
	else
		self.resultRows[4].Text = ""
	end
	if #(snap.racers or {}) == 0 then
		self.resultRows[1].Text = "No racers finished this round"
	end
end

-- ctx = { now, racing (local player racing and not finished), raceRunning, spectating }
function MatchUI:Update(ctx)
	local snap = self.snapshot
	if not snap then
		return
	end
	-- queue chip: only meaningful while you are not on the grid / racing
	self.queueButton.Visible = not ctx.racing and snap.state ~= S.Results
	-- Labelled with the action a tap performs, not the current state.
	UIKit.setText(self.queueButton, self.queued and "SIT OUT" or "JOIN RACE")
	self.queueButton.TextColor3 = self.queued and palette.White or palette.Mint

	self.spectateFrame.Visible = ctx.raceRunning and not ctx.racing
	self.spectatePrev.Visible = ctx.spectating
	self.spectateNext.Visible = ctx.spectating
	UIKit.setText(self.spectateMain, ctx.spectating and "EXIT SPECTATE" or "SPECTATE")

	if self.results.Visible and snap.stateEndsAt then
		local left = math.max(0, math.ceil(snap.stateEndsAt - ctx.now))
		local after = RaceConfig.Timers.CleanupSeconds + RaceConfig.Timers.IntermissionSeconds
		UIKit.setText(self.resultsTimer, string.format("Next race in about %d s", left + after))
	end
end

-- Hub board: each client writes its own copy of the SurfaceGui text.
function MatchUI:UpdateBoard(board, ctx)
	local snap = self.snapshot
	if not board or not snap then
		return
	end
	local main, sub = board:FindFirstChild("BoardMain"), board:FindFirstChild("BoardSub")
	if not main or not sub then
		return
	end
	local left = snap.stateEndsAt and math.max(0, math.ceil(snap.stateEndsAt - ctx.now)) or nil
	if snap.state == S.Intermission and left then
		UIKit.setText(main, "NEXT RACE IN " .. left)
		if snap.readyOpen then
			UIKit.setText(sub, string.format("Race full - %d/%d READY", snap.readyCount or 0, snap.queuedCount or 0))
		else
			UIKit.setText(sub, string.format("Waiting for players (%d/%d)", snap.queuedCount or self:_queuedCount(), snap.raceCapacity or 16))
		end
	elseif snap.state == S.Racing then
		UIKit.setText(main, "RACE IN PROGRESS")
		UIKit.setText(sub, "Spectate from the HUD, or keep practising")
	elseif snap.state == S.Results then
		local winner = snap.racers[1]
		UIKit.setText(main, winner and ("WINNER: " .. (winner.isBot and "[BOT] " or "") .. winner.name) or "RESULTS")
		UIKit.setText(sub, "Next race soon")
	elseif snap.state == S.Preparing or snap.state == S.Countdown then
		UIKit.setText(main, "STARTING")
		UIKit.setText(sub, "Racers on the grid")
	else
		UIKit.setText(main, "WAITING FOR RACERS")
		UIKit.setText(sub, "Roll down the practice chute while you wait")
	end
end

function MatchUI:_queuedCount()
	local n = 0
	for _ in pairs(self.snapshot.queued or {}) do
		n = n + 1
	end
	return n
end

function MatchUI:Destroy()
	self.maid:Cleanup()
end

return MatchUI
