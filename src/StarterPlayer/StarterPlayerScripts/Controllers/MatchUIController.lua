--[[
	MatchUIController — A2 round UI outside the live race readouts:
	  * Results overlay (top three + your place, server times / DNF) with PLAY AGAIN and SIT OUT
	    (both are RequestJoinRace(bool); the fixed round timer is never affected)
	  * queue chip: IN NEXT RACE / SITTING OUT toggle while you are not racing
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
	self.JoinRequested = Utility.Signal.new() -- (wantsToRace)
	self.SpectateToggled = Utility.Signal.new()
	self.SpectateCycle = Utility.Signal.new() -- (direction)

	-- Queue chip (top right, under the camera/reset buttons)
	self.queueButton = UIKit.button(root, {
		Name = "Queue",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 112),
		Size = UDim2.fromOffset(190, 44),
		Text = "IN NEXT RACE",
	}, palette.Mint)
	maid:Give(self.queueButton.Activated:Connect(function()
		self.JoinRequested:Fire(not self.queued)
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
		self.JoinRequested:Fire(true)
	end))
	maid:Give(self.sitOut.Activated:Connect(function()
		self.JoinRequested:Fire(false)
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

function MatchUI:ApplySnapshot(snapshot, localUserId)
	self.snapshot = snapshot
	self.localUserId = localUserId
	self.queued = snapshot.queued and snapshot.queued[tostring(localUserId)] == true or false
	self:_renderResults()
end

function MatchUI:_renderResults()
	local snap = self.snapshot
	local show = snap ~= nil and snap.state == S.Results
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
	self.playAgain.Text = self.queued and "IN NEXT RACE" or "PLAY AGAIN"
end

-- ctx = { now, racing (local player racing and not finished), raceRunning, spectating }
function MatchUI:Update(ctx)
	local snap = self.snapshot
	if not snap then
		return
	end
	-- queue chip: only meaningful while you are not on the grid / racing
	self.queueButton.Visible = not ctx.racing and snap.state ~= S.Results
	UIKit.setText(self.queueButton, self.queued and "IN NEXT RACE" or "SITTING OUT")
	self.queueButton.TextColor3 = self.queued and palette.Mint or palette.Coral

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
		UIKit.setText(sub, string.format("%d racer(s) queued - practice chute is open", self:_queuedCount()))
	elseif snap.state == S.Racing then
		UIKit.setText(main, "RACE IN PROGRESS")
		UIKit.setText(sub, "Spectate from the HUD, or keep practising")
	elseif snap.state == S.Results then
		local winner = snap.racers[1]
		UIKit.setText(main, winner and ("WINNER: " .. winner.name) or "RESULTS")
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
