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
local TrackDefinitions = require(game:GetService("ReplicatedStorage"):WaitForChild("Shared"):WaitForChild("TrackDefinitions"))

-- B1: display name of the world the next race uses
local function nextWorldName(snap)
	local def = snap and snap.nextWorldId and TrackDefinitions.WorldsById[snap.nextWorldId]
	return def and def.DisplayName or nil
end

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
	self.GarageRequested = Utility.Signal.new() -- B3
	self.QuestsRequested = Utility.Signal.new() -- B3
	self.BoardsRequested = Utility.Signal.new() -- B3

	-- Lobby layer -------------------------------------------------------------------------
	local lobby = UIKit.new("Frame", { Name = "Lobby", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, root)
	self.lobby = lobby
	-- One compact right-hand column, top to bottom (owner playtest 2026-11-25: the hub's buttons
	-- were all over the screen and ran into the touch buttons on a phone):
	--   y   8  status card: NEXT RACE 0:12 / Waiting for players (1/16)   (replaces the race HUD
	--          line that sat on top of the hub's 3D board)
	--   y  72  [READY?] [SIT OUT / JOIN RACE]
	--   y 124  profile: LEVEL + XP, bar, Coins/races/wins, save status
	--   y 216  [ABILITIES] [GARAGE]   (B3)
	--   y 268  [QUESTS] [MORE]        (MORE -> BOARDS / SETTINGS)
	--   y 320  [TIME TRIAL] [PARTY] (B1, ModesController)
	--   y 372  emotes (SocialController)
	-- Clear of Roblox's top bar and chat (top left), the stick (left) and RESET/BRAKE (bottom right).
	local status = UIKit.panel(lobby, { Name = "Status", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 8), Size = UDim2.fromOffset(250, 58) })
	UIKit.new("UIStroke", { Color = palette.Cyan, Thickness = 2 }, status)
	self.statusMain = UIKit.label(status, { Position = UDim2.fromOffset(10, 4), Size = UDim2.new(1, -20, 0, 28), Font = Enum.Font.GothamBlack, TextColor3 = palette.White, Text = "" })
	self.statusSub = UIKit.label(status, { Position = UDim2.fromOffset(10, 34), Size = UDim2.new(1, -20, 0, 18), Font = Enum.Font.Gotham, TextColor3 = palette.Cyan, Text = "" })

	local chip = UIKit.panel(lobby, { Name = "Profile", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 124), Size = UDim2.fromOffset(250, 84) })
	UIKit.new("UIStroke", { Color = palette.Violet, Thickness = 2 }, chip)
	self.levelLabel = UIKit.label(chip, { Position = UDim2.fromOffset(10, 4), Size = UDim2.new(0.42, -10, 0, 24), Font = Enum.Font.GothamBlack, TextColor3 = palette.Violet, TextXAlignment = Enum.TextXAlignment.Left, Text = "LEVEL 1" })
	self.xpLabel = UIKit.label(chip, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 8), Size = UDim2.new(0.58, -10, 0, 18), Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Right, Text = "" })
	local bar = UIKit.new("Frame", { Name = "XpBar", Position = UDim2.fromOffset(10, 32), Size = UDim2.new(1, -20, 0, 8), BackgroundColor3 = palette.Ink, BorderSizePixel = 0 }, chip)
	UIKit.corner(bar, 0.5)
	self.xpFill = UIKit.new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = palette.Violet, BorderSizePixel = 0 }, bar)
	UIKit.corner(self.xpFill, 0.5)
	self.coinLabel = UIKit.label(chip, { Position = UDim2.fromOffset(10, 44), Size = UDim2.new(1, -20, 0, 20), TextColor3 = palette.Yellow, TextXAlignment = Enum.TextXAlignment.Left, Text = "" })
	self.saveLabel = UIKit.label(chip, { Position = UDim2.fromOffset(10, 66), Size = UDim2.new(1, -20, 0, 14), Font = Enum.Font.Gotham, TextTransparency = 0.25, TextXAlignment = Enum.TextXAlignment.Left, Text = "Loading your progress..." })

	self.loadoutButton = UIKit.button(lobby, { Name = "LoadoutButton", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -143, 0, 216), Size = UDim2.fromOffset(121, 44), Text = "ABILITIES" }, palette.Violet)
	self.garageButton = UIKit.button(lobby, { Name = "GarageButton", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 216), Size = UDim2.fromOffset(121, 44), Text = "GARAGE" }, palette.Cyan)
	self.questsButton = UIKit.button(lobby, { Name = "QuestsButton", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -143, 0, 268), Size = UDim2.fromOffset(121, 44), Text = "QUESTS" }, palette.Yellow)
	self.moreButton = UIKit.button(lobby, { Name = "MoreButton", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 268), Size = UDim2.fromOffset(121, 44), Text = "MORE" }, palette.White)
	local more = UIKit.panel(lobby, { Name = "MoreMenu", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -278, 0, 268), Size = UDim2.fromOffset(250, 104), Visible = false })
	self.moreMenu = more
	self.boardsButton = UIKit.button(more, { Name = "BoardsButton", Position = UDim2.fromOffset(6, 6), Size = UDim2.new(1, -12, 0, 44), Text = "LEADERBOARDS" }, palette.Violet)
	self.settingsButton = UIKit.button(more, { Name = "SettingsButton", Position = UDim2.fromOffset(6, 54), Size = UDim2.new(1, -12, 0, 44), Text = "SETTINGS" }, palette.Cyan)
	maid:Give(self.garageButton.Activated:Connect(function()
		self.GarageRequested:Fire()
	end))
	maid:Give(self.questsButton.Activated:Connect(function()
		self.QuestsRequested:Fire()
	end))
	maid:Give(self.moreButton.Activated:Connect(function()
		more.Visible = not more.Visible
	end))
	maid:Give(self.boardsButton.Activated:Connect(function()
		more.Visible = false
		self.BoardsRequested:Fire()
	end))
	maid:Give(self.loadoutButton.Activated:Connect(function()
		self.LoadoutRequested:Fire()
	end))
	maid:Give(self.settingsButton.Activated:Connect(function()
		more.Visible = false
		self.SettingsRequested:Fire()
	end))

	self.queueButton = UIKit.button(lobby, {
		Name = "Queue",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 72),
		Size = UDim2.fromOffset(120, 44),
		Text = "SIT OUT",
	}, palette.White)
	maid:Give(self.queueButton.Activated:Connect(function()
		self:_requestQueue(not self.queued)
	end))
	-- READY vote: same row, left of the queue button; only while the race is full
	self.readyButton = UIKit.button(lobby, {
		Name = "Ready",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -144, 0, 72),
		Size = UDim2.fromOffset(120, 44),
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
	UIKit.setText(self.loadoutButton, "ABILITIES\n" .. text)
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
	UIKit.setText(self.xpLabel, (p.xpForNext and p.xpForNext > 0) and string.format("%d / %d XP", p.xpIntoLevel or 0, p.xpForNext) or "MAX LEVEL")
	UIKit.setText(self.coinLabel, string.format("%d COINS  -  %d races  -  %d wins", p.coins or 0, p.raceCount or 0, p.winCount or 0))
	UIKit.setText(self.saveLabel, p.statusText or "")
	self.saveLabel.TextColor3 = (p.status == "Ready" or p.status == "Mock" or p.status == "Loading") and palette.White or palette.Coral
end

local function clock(seconds)
	return (Utility.formatTime(math.max(0, seconds or 0)):gsub("%.%d+$", ""))
end

-- Status card text for the lobby (what the race HUD used to say at the top of the hub screen).
function MatchUI:_statusText(ctx)
	local snap = self.snapshot
	local left = snap.stateEndsAt and math.max(0, snap.stateEndsAt - (ctx.now or 0)) or 0
	if snap.state == S.Intermission then
		local sub
		if snap.readyOpen then
			sub = string.format("Race full - %d/%d READY", snap.readyCount or 0, snap.queuedCount or 0)
		else
			sub = string.format("Waiting for players (%d/%d)", snap.queuedCount or 0, snap.raceCapacity or 16)
		end
		if not self.queued then
			sub = "Sitting out - tap JOIN RACE"
		end
		local world = nextWorldName(snap)
		if world then
			sub = (snap.mapVote and snap.mapVote.open and "Vote the world! " or (world .. " - ")) .. sub
		end
		return "NEXT RACE  " .. clock(left), sub
	elseif snap.state == S.Preparing or snap.state == S.Countdown then
		return "STARTING", self.queued and "Next one is yours" or "Racers on the grid"
	elseif snap.state == S.Racing then
		local elapsed = snap.raceStartedAt and ((ctx.now or 0) - snap.raceStartedAt) or 0
		return "RACE  " .. clock(elapsed), self.queued and "You're in the next race - SPECTATE" or "Sitting out - SPECTATE to watch"
	elseif snap.state == S.Results or snap.state == S.Cleanup then
		return "NEXT RACE SOON", self.queued and "You're in the next race" or "Sitting out - tap JOIN RACE"
	end
	return "WAITING FOR RACERS", "Roll down the practice chute"
end

-- ctx = { now, racing, raceRunning, spectating }
function MatchUI:Update(ctx)
	local snap = self.snapshot
	if not snap then
		return
	end
	local main, sub = self:_statusText(ctx)
	UIKit.setText(self.statusMain, main)
	UIKit.setText(self.statusSub, sub)
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
		local world = nextWorldName(snap)
		UIKit.setText(main, world and string.format("NEXT: %s IN %d", string.upper(world), left) or ("NEXT RACE IN " .. left))
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
