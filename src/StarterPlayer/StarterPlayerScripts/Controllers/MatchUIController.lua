--[[
	MatchUIController — the lobby and spectate layers (shown by UIController):
	  Lobby    : profile chip (level, XP to next, Coins, races, wins, save status), LOADOUT and
	             SETTINGS buttons, the queue button, SPECTATE when a race runs
	             * queue button is labelled with what a tap does: SIT OUT while you are queued,
	               JOIN RACE while you sit out (owner playtest 2026-11-23: a chip that showed the
	               state, IN NEXT RACE, read as "tap to join" and sat the player out). Taps show at
	               once; the next snapshot confirms.
	             * READY button left of it (owner request 2026-11-25), only in the intermission
	               while the race is full; every queued player READY = the race starts now
	  Spectate : < EXIT SPECTATE >
	  plus the hub's holographic board (each client writes its own copy; no server writes).
	Results moved to ResultsController (A5). No shop, capsule or season entries exist.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
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
	self.amReady = false
	self.pendingReady = nil
	self.JoinRequested = Utility.Signal.new() -- (wantsToRace)
	self.ReadyRequested = Utility.Signal.new() -- (ready)
	self.SpectateToggled = Utility.Signal.new()
	self.SpectateCycle = Utility.Signal.new() -- (direction)
	self.LoadoutRequested = Utility.Signal.new()
	self.SettingsRequested = Utility.Signal.new()

	-- Lobby layer -------------------------------------------------------------------------
	local lobby = UIKit.new("Frame", { Name = "Lobby", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, root)
	self.lobby = lobby
	-- right column, under the queue chip: clear of Roblox chat (top left) and the touch stick (left)
	local chip = UIKit.panel(lobby, { Name = "Profile", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 164), Size = UDim2.fromOffset(250, 120) })
	UIKit.new("UIStroke", { Color = palette.Violet, Thickness = 2 }, chip)
	self.levelLabel = UIKit.label(chip, { Position = UDim2.fromOffset(12, 6), Size = UDim2.new(1, -24, 0, 30), Font = Enum.Font.GothamBlack, TextColor3 = palette.Violet, TextXAlignment = Enum.TextXAlignment.Left, Text = "LEVEL 1" })
	local bar = UIKit.new("Frame", { Name = "XpBar", Position = UDim2.fromOffset(12, 40), Size = UDim2.new(1, -24, 0, 10), BackgroundColor3 = palette.Ink, BorderSizePixel = 0 }, chip)
	UIKit.corner(bar, 0.5)
	self.xpFill = UIKit.new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = palette.Violet, BorderSizePixel = 0 }, bar)
	UIKit.corner(self.xpFill, 0.5)
	self.xpLabel = UIKit.label(chip, { Position = UDim2.fromOffset(12, 52), Size = UDim2.new(1, -24, 0, 18), Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left, Text = "" })
	self.coinLabel = UIKit.label(chip, { Position = UDim2.fromOffset(12, 72), Size = UDim2.new(1, -24, 0, 22), TextColor3 = palette.Yellow, TextXAlignment = Enum.TextXAlignment.Left, Text = "" })
	self.saveLabel = UIKit.label(chip, { Position = UDim2.fromOffset(12, 96), Size = UDim2.new(1, -24, 0, 16), Font = Enum.Font.Gotham, TextTransparency = 0.25, TextXAlignment = Enum.TextXAlignment.Left, Text = "Loading your progress..." })

	self.loadoutButton = UIKit.button(lobby, { Name = "LoadoutButton", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -143, 0, 292), Size = UDim2.fromOffset(121, 52), Text = "LOADOUT" }, palette.Violet)
	self.settingsButton = UIKit.button(lobby, { Name = "SettingsButton", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 292), Size = UDim2.fromOffset(121, 52), Text = "SETTINGS" }, palette.Cyan)
	maid:Give(self.loadoutButton.Activated:Connect(function()
		self.LoadoutRequested:Fire()
	end))
	maid:Give(self.settingsButton.Activated:Connect(function()
		self.SettingsRequested:Fire()
	end))

	self.queueButton = UIKit.button(lobby, {
		Name = "Queue",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 112),
		Size = UDim2.fromOffset(190, 44),
		Text = "SIT OUT",
	}, palette.White)
	maid:Give(self.queueButton.Activated:Connect(function()
		self:_requestQueue(not self.queued)
	end))
	-- READY vote: same row, left of the queue button; only while the race is full
	self.readyButton = UIKit.button(lobby, {
		Name = "Ready",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -214, 0, 112),
		Size = UDim2.fromOffset(170, 44),
		Text = "READY?",
		Visible = false,
	}, palette.Yellow)
	maid:Give(self.readyButton.Activated:Connect(function()
		local wants = not self.amReady
		self.amReady = wants
		self.pendingReady = { value = wants, untilClock = os.clock() + 2 }
		self.ReadyRequested:Fire(wants)
		self:_renderReady()
	end))
	self.spectateStart = UIKit.button(lobby, { Name = "SpectateStart", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -90), Size = UDim2.fromOffset(220, 48), Text = "SPECTATE" }, palette.Cyan)
	maid:Give(self.spectateStart.Activated:Connect(function()
		self.SpectateToggled:Fire()
	end))

	-- Spectate layer ----------------------------------------------------------------------
	local spectate = UIKit.new("Frame", {
		Name = "Spectate",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -90),
		Size = UDim2.fromOffset(360, 48),
		BackgroundTransparency = 1,
		Visible = false,
	}, root)
	self.spectatePrev = UIKit.button(spectate, { Size = UDim2.fromOffset(60, 48), Text = "<" }, palette.Cyan)
	self.spectateMain = UIKit.button(spectate, { Position = UDim2.fromOffset(70, 0), Size = UDim2.fromOffset(220, 48), Text = "EXIT SPECTATE" }, palette.Cyan)
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
	return self
end

-- e.g. "BOOST + SHIELD": the equipped pair, shown on the LOADOUT button itself
function MatchUI:SetLoadoutText(text)
	UIKit.setText(self.loadoutButton, "LOADOUT\n" .. text)
end

function MatchUI:SetLobbyVisible(visible)
	self.lobby.Visible = visible
end

function MatchUI:SetSpectateVisible(visible)
	self.spectateFrame.Visible = visible
end

-- Ask to race (true) or sit out (false) in the next round. Shown at once; the server's snapshot
-- confirms (or, after 2 s without confirmation, wins).
function MatchUI:_requestQueue(wants)
	self.queued = wants
	self.pendingQueue = { value = wants, untilClock = os.clock() + 2 }
	self.JoinRequested:Fire(wants)
	self:_renderReady()
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
		self.amReady = pendingReady.value
	else
		self.pendingReady = nil
		self.amReady = serverReady
	end
	self:_renderReady()
end

-- READY button: in the intermission while the race is full and you are racing next.
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

-- ProfileState from the server (status text is the server's honest save state).
function MatchUI:ApplyProfile(p)
	if type(p) ~= "table" then
		return
	end
	UIKit.setText(self.levelLabel, string.format("LEVEL %d", p.level or 1))
	local fraction = (p.xpForNext and p.xpForNext > 0) and (p.xpIntoLevel or 0) / p.xpForNext or 1
	self.xpFill.Size = UDim2.fromScale(math.clamp(fraction, 0, 1), 1)
	UIKit.setText(self.xpLabel, (p.xpForNext and p.xpForNext > 0) and string.format("%d / %d XP to level %d", p.xpIntoLevel or 0, p.xpForNext, (p.level or 1) + 1) or "MAX LEVEL")
	UIKit.setText(self.coinLabel, string.format("%d COINS  -  %d races  -  %d wins", p.coins or 0, p.raceCount or 0, p.winCount or 0))
	UIKit.setText(self.saveLabel, p.statusText or "")
	self.saveLabel.TextColor3 = (p.status == "Ready" or p.status == "Mock" or p.status == "Loading") and palette.White or palette.Coral
end

-- ctx = { racing, raceRunning, spectating }
function MatchUI:Update(ctx)
	local snap = self.snapshot
	if not snap then
		return
	end
	self.queueButton.Visible = not ctx.racing and snap.state ~= S.Results
	-- Labelled with the action a tap performs, not the current state.
	UIKit.setText(self.queueButton, self.queued and "SIT OUT" or "JOIN RACE")
	self.queueButton.TextColor3 = self.queued and palette.White or palette.Mint
	self.spectateStart.Visible = ctx.raceRunning and not ctx.racing and not ctx.spectating
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
