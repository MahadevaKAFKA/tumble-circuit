--[[
	ResultsController (A5) — the results screen, driven only by server data:
	  * three-marble podium (1st / 2nd / 3rd with [BOT] labels, times or DNF)
	  * your place, time, personal-best delta (only against a PB on the SAME track configuration:
	    world | layout version | hazard variation | mode; a first time on a variation says so)
	  * the exact Coins + XP breakdown from RewardNotice, the bot-practice note when it applies,
	    level progress, and an honest save line (only "saved" after the server saved)
	  * a success animation for every finisher (your card pops in and the Coin total counts up)
	  * PLAY AGAIN (primary), SIT OUT, LOADOUT, SETTINGS
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local RaceConfig = require(Shared:WaitForChild("RaceConfig"))
local RoundProtocol = require(Shared:WaitForChild("RoundProtocol"))
local Utility = require(Shared:WaitForChild("Utility"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local Results = {}
Results.__index = Results

local S = RoundProtocol.States
local palette = UIKit.Palette

-- Pure: personal-best line for a notice.pb table.
function Results.PbLine(pb)
	if not pb or not pb.seconds then
		return nil
	end
	if pb.isNew and pb.previous then
		return string.format("NEW PERSONAL BEST  -%.2f s", pb.previous - pb.seconds)
	elseif pb.isNew then
		return "FIRST TIME ON THIS HAZARD VARIATION - personal best set"
	elseif pb.previous then
		return string.format("Personal best %s  (+%.2f s)", Utility.formatTime(pb.previous), pb.seconds - pb.previous)
	end
	return nil
end

function Results.new()
	local self = setmetatable({}, Results)
	self.JoinRequested = Utility.Signal.new() -- (wants)
	self.LoadoutRequested = Utility.Signal.new()
	self.SettingsRequested = Utility.Signal.new()
	self.Dismissed = Utility.Signal.new()
	local gui, root, maid = UIKit.screen("TumbleResults", 12)
	self.gui, self.maid = gui, maid
	gui.Enabled = false

	local panel = UIKit.panel(root, { Name = "Results", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(980, 560), BackgroundTransparency = 0.06 })
	UIKit.new("UIStroke", { Color = palette.Cyan, Thickness = 2 }, panel)
	UIKit.label(panel, { Position = UDim2.fromOffset(0, 10), Size = UDim2.new(1, 0, 0, 44), Font = Enum.Font.GothamBlack, TextColor3 = palette.Cyan, Text = "RACE RESULTS" })

	-- podium (left half)
	self.podium = {}
	local heights = { 150, 112, 84 }
	local xs = { 165, 20, 310 }
	local colors = { palette.Yellow, palette.White, palette.Coral }
	for place = 1, 3 do
		local column = UIKit.new("Frame", { Name = "Podium" .. place, BackgroundTransparency = 1, Position = UDim2.fromOffset(xs[place], 70), Size = UDim2.fromOffset(140, 330) }, panel)
		local block = UIKit.panel(column, { AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 0, 1, 0), Size = UDim2.new(1, 0, 0, heights[place]), BackgroundColor3 = palette.NavyFloor, BackgroundTransparency = 0 })
		UIKit.label(block, { Size = UDim2.new(1, 0, 0, 48), Position = UDim2.fromOffset(0, 8), Font = Enum.Font.GothamBlack, TextColor3 = colors[place], Text = tostring(place) })
		local marble = UIKit.new("Frame", { Name = "Marble", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -heights[place] - 70), Size = UDim2.fromOffset(64, 64), BackgroundColor3 = colors[place] }, column)
		UIKit.corner(marble, 0.5)
		local name = UIKit.label(column, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -heights[place] - 38), Size = UDim2.new(1, 10, 0, 28), Text = "" })
		local time = UIKit.label(column, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -heights[place] - 10), Size = UDim2.new(1, 0, 0, 24), Font = Enum.Font.Gotham, Text = "" })
		self.podium[place] = { column = column, marble = marble, name = name, time = time }
	end

	-- your card (right half)
	local card = UIKit.panel(panel, { Name = "You", Position = UDim2.fromOffset(470, 66), Size = UDim2.fromOffset(490, 350), BackgroundColor3 = palette.NavyFloor, BackgroundTransparency = 0.05 })
	self.cardScale = UIKit.new("UIScale", { Scale = 1 }, card)
	self.headline = UIKit.label(card, { Position = UDim2.fromOffset(16, 8), Size = UDim2.new(1, -32, 0, 40), Font = Enum.Font.GothamBlack, TextColor3 = palette.Mint, Text = "" })
	self.timeLine = UIKit.label(card, { Position = UDim2.fromOffset(16, 50), Size = UDim2.new(1, -32, 0, 28), Text = "" })
	self.pbLine = UIKit.label(card, { Position = UDim2.fromOffset(16, 80), Size = UDim2.new(1, -32, 0, 24), TextColor3 = palette.Yellow, Text = "" })
	self.lines = {}
	for i = 1, 6 do
		self.lines[i] = UIKit.label(card, { Position = UDim2.fromOffset(16, 110 + (i - 1) * 27), Size = UDim2.new(1, -32, 0, 24), Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left, Text = "" })
	end
	self.totals = UIKit.label(card, { Position = UDim2.fromOffset(16, 274), Size = UDim2.new(1, -32, 0, 30), Font = Enum.Font.GothamBlack, TextColor3 = palette.Yellow, Text = "" })
	self.levelLine = UIKit.label(card, { Position = UDim2.fromOffset(16, 306), Size = UDim2.new(1, -32, 0, 22), Font = Enum.Font.Gotham, TextColor3 = palette.Violet, Text = "" })
	self.saveLine = UIKit.label(card, { Position = UDim2.fromOffset(16, 328), Size = UDim2.new(1, -32, 0, 18), Font = Enum.Font.Gotham, TextTransparency = 0.2, Text = "" })
	self.card = card
	self.note = UIKit.label(panel, { Position = UDim2.fromOffset(470, 420), Size = UDim2.fromOffset(490, 34), Font = Enum.Font.Gotham, TextWrapped = true, TextColor3 = palette.Mint, Text = "" })
	self.timer = UIKit.label(panel, { Position = UDim2.fromOffset(20, 410), Size = UDim2.fromOffset(420, 26), Font = Enum.Font.Gotham, TextTransparency = 0.2, Text = "" })

	local function button(name, x, w, text, accent, fn)
		local b = UIKit.button(panel, { Name = name, Position = UDim2.fromOffset(x, 470), Size = UDim2.fromOffset(w, 72), Text = text }, accent)
		maid:Give(b.Activated:Connect(fn))
		return b
	end
	self.playAgain = button("PlayAgain", 20, 300, "PLAY AGAIN", palette.Mint, function()
		self.JoinRequested:Fire(true)
		self.Dismissed:Fire()
	end)
	UIKit.Primary(self.playAgain) -- requeue is the results screen's one primary action
	button("SitOut", 336, 180, "SIT OUT", palette.White, function()
		self.JoinRequested:Fire(false)
		self.Dismissed:Fire()
	end)
	button("Loadout", 532, 210, "LOADOUT", palette.Violet, function()
		self.LoadoutRequested:Fire()
	end)
	button("Settings", 758, 202, "SETTINGS", palette.Cyan, function()
		self.SettingsRequested:Fire()
	end)
	return self
end

function Results:SetVisible(visible)
	if visible and not self.gui.Enabled then
		self:_animateIn()
	end
	self.gui.Enabled = visible
end

function Results:ApplySnapshot(snap, localUserId)
	self.snapshot = snap
	self.localUserId = localUserId
	if snap.state == S.Results and snap.roundId ~= self.roundShown then
		self.roundShown = snap.roundId
		if self.notice and self.notice.roundId ~= snap.roundId then
			self.notice = nil -- the reward can arrive just before the Results snapshot: keep it
		end
		self:_renderNotice()
	end
	if snap.state ~= S.Results then
		return
	end
	for place = 1, 3 do
		local entry = snap.racers[place]
		local p = self.podium[place]
		p.column.Visible = entry ~= nil
		if entry then
			UIKit.setText(p.name, (entry.isBot and "[BOT] " or "") .. tostring(entry.name))
			-- DNF shows how far they got (owner report 2026-11-25: every bot DNF, no clue why)
			UIKit.setText(p.time, entry.dnf and string.format("DNF CP %d/%d", entry.checkpoint or 0, snap.checkpointTotal or 0) or (entry.seconds and Utility.formatTime(entry.seconds) or ""))
			p.marble.BackgroundColor3 = entry.userId == localUserId and palette.Mint or (entry.isBot and palette.Coral or p.marble.BackgroundColor3)
		end
	end
	local mine
	for _, entry in ipairs(snap.racers) do
		if entry.userId == localUserId then
			mine = entry
		end
	end
	self.mine = mine
	if not mine then
		UIKit.setText(self.headline, "YOU WATCHED THIS ONE")
		UIKit.setText(self.timeLine, "You're queued for the next race")
	elseif mine.finished then
		UIKit.setText(self.headline, string.format("FINISHED %s OF %d", UIKit.ordinal(mine.place), #snap.racers))
		UIKit.setText(self.timeLine, mine.seconds and ("Time " .. Utility.formatTime(mine.seconds)) or "")
	else
		UIKit.setText(self.headline, "DID NOT FINISH")
		UIKit.setText(self.timeLine, string.format("Reached checkpoint %d of %d", mine.checkpoint or 0, snap.checkpointTotal or 0))
	end
	-- always the action (owner playtest 2026-11-23: a state label here read as a dead button)
	self.playAgain.Text = "PLAY AGAIN"
end

function Results:ApplyNotice(notice)
	self.notice = notice
	self:_renderNotice()
	self:_countUp(notice.totalCoins - notice.coins, notice.totalCoins)
end

function Results:ApplyProfile(profile)
	self.profile = profile
	self:_renderSave()
end

function Results:_renderNotice()
	local n = self.notice
	for i, label in ipairs(self.lines) do
		local l = n and n.lines and n.lines[i]
		if l then
			local parts = {}
			if l.coins ~= 0 then
				parts[#parts + 1] = string.format("%+d Coins", l.coins)
			end
			if l.xp ~= 0 then
				parts[#parts + 1] = string.format("%+d XP", l.xp)
			end
			label.Text = l.label .. (#parts > 0 and ("   " .. table.concat(parts, "  ")) or "")
		else
			label.Text = (i == 1 and not n and self.mine) and "Adding up your rewards..." or ""
		end
	end
	UIKit.setText(self.pbLine, n and Results.PbLine(n.pb) or "")
	UIKit.setText(self.totals, n and string.format("+%d COINS   +%d XP", n.coins, n.xp) or "")
	if n then
		local level = n.levelUp and string.format("LEVEL UP!  Level %d", n.level) or string.format("Level %d", n.level)
		if n.xpForNext and n.xpForNext > 0 then
			level = level .. string.format("  -  %d / %d XP to level %d", n.xpIntoLevel, n.xpForNext, n.level + 1)
		end
		UIKit.setText(self.levelLine, level)
	else
		UIKit.setText(self.levelLine, "")
	end
	UIKit.setText(self.note, n and n.multiplierNote or "")
	self:_renderSave()
end

function Results:_renderSave()
	local n, p = self.notice, self.profile
	if not n then
		UIKit.setText(self.saveLine, "")
		return
	end
	local text
	if p and p.status == "Mock" then
		text = "Studio test profile - not saved to Roblox"
	elseif p and p.status == "Ready" and p.savedAt and p.savedAt >= (n.grantedAt or math.huge) and not p.dirty then
		text = "Progress saved"
	elseif p and (p.status == "Unsaved" or p.status == "Ready") then
		text = p.status == "Unsaved" and "Not saved yet - retrying" or "Saving..."
	else
		text = p and p.statusText or "Saving..."
	end
	UIKit.setText(self.saveLine, text)
end

function Results:_animateIn()
	-- genuine success moment for everyone: the card pops in (skipped with reduced motion)
	if self.reducedMotion then
		self.cardScale.Scale = 1
		return
	end
	self.cardScale.Scale = 0.85
	TweenService:Create(self.cardScale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	-- the podium rises 3rd, 2nd, then 1st
	UIKit.Stagger({ self.podium[3].column, self.podium[2].column, self.podium[1].column }, "FromBelow", 0.12)
end

function Results:_countUp(from, to)
	if self.reducedMotion or to <= from then
		UIKit.setText(self.totals, self.notice and string.format("+%d COINS   +%d XP   (%d total)", self.notice.coins, self.notice.xp, to) or "")
		return
	end
	local started = os.clock()
	task.spawn(function()
		while self.notice and os.clock() - started < 1 do
			local f = (os.clock() - started) / 1
			UIKit.setText(self.totals, string.format("+%d COINS   +%d XP   (%d total)", math.floor(self.notice.coins * f), self.notice.xp, math.floor(from + (to - from) * f)))
			task.wait(0.03)
		end
		if self.notice then
			UIKit.setText(self.totals, string.format("+%d COINS   +%d XP   (%d total)", self.notice.coins, self.notice.xp, to))
		end
	end)
end

function Results:GetPrimaryButton()
	return self.playAgain
end

function Results:SetReducedMotion(value)
	self.reducedMotion = value == true
end

function Results:Update(now)
	local snap = self.snapshot
	if self.gui.Enabled and snap and snap.stateEndsAt then
		local left = math.max(0, math.ceil(snap.stateEndsAt - now))
		UIKit.setText(self.timer, string.format("Next race in about %d s", left + RaceConfig.Timers.CleanupSeconds + RaceConfig.Timers.IntermissionSeconds))
	end
end

function Results:Destroy()
	self.maid:Cleanup()
end

return Results
