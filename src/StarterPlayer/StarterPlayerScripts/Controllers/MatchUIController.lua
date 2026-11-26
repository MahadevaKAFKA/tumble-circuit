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
	self.LabRequested = Utility.Signal.new() -- C: (tab) Capsule Lab / Season
	self.ShopRequested = Utility.Signal.new() -- D: the optional shop
	self.MapsRequested = Utility.Signal.new() -- UI overhaul: MAPS on the hub card
	self.PracticeExitRequested = Utility.Signal.new() -- UI overhaul: EXIT PRACTICE

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
	--   y 268  [QUESTS] [MORE]        (MORE -> LEADERBOARDS / CAPSULE LAB / SEASON / SETTINGS)
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
	local more = UIKit.panel(lobby, { Name = "MoreMenu", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -278, 0, 268), Size = UDim2.fromOffset(250, 248), Visible = false })
	self.moreMenu = more
	self.boardsButton = UIKit.button(more, { Name = "BoardsButton", Position = UDim2.fromOffset(6, 6), Size = UDim2.new(1, -12, 0, 44), Text = "LEADERBOARDS" }, palette.Violet)
	self.labButton = UIKit.button(more, { Name = "LabButton", Position = UDim2.fromOffset(6, 54), Size = UDim2.new(1, -12, 0, 44), Text = "CAPSULE LAB" }, palette.Mint)
	self.seasonButton = UIKit.button(more, { Name = "SeasonButton", Position = UDim2.fromOffset(6, 102), Size = UDim2.new(1, -12, 0, 44), Text = "SEASON" }, palette.Yellow)
	self.shopButton = UIKit.button(more, { Name = "ShopButton", Position = UDim2.fromOffset(6, 150), Size = UDim2.new(1, -12, 0, 44), Text = "SHOP (OPTIONAL)" }, palette.White)
	self.settingsButton = UIKit.button(more, { Name = "SettingsButton", Position = UDim2.fromOffset(6, 198), Size = UDim2.new(1, -12, 0, 44), Text = "SETTINGS" }, palette.Cyan)
	maid:Give(self.shopButton.Activated:Connect(function()
		more.Visible = false
		self.ShopRequested:Fire()
	end))
	maid:Give(self.labButton.Activated:Connect(function()
		more.Visible = false
		self.LabRequested:Fire("Capsule")
	end))
	maid:Give(self.seasonButton.Activated:Connect(function()
		more.Visible = false
		self.LabRequested:Fire("Season")
	end))
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
	-- named target controls (UI overhaul): PREV RACER / EXIT SPECTATE / NEXT RACER
	self.spectatePrev = UIKit.button(spectate, { Position = UDim2.fromOffset(-60, 0), Size = UDim2.fromOffset(120, 48), Text = "< PREV" }, palette.Cyan)
	self.spectateMain = UIKit.button(spectate, { Position = UDim2.fromOffset(70, 0), Size = UDim2.fromOffset(220, 48), Text = "EXIT SPECTATE" }, palette.Cyan)
	self.spectateNext = UIKit.button(spectate, { Position = UDim2.fromOffset(300, 0), Size = UDim2.fromOffset(120, 48), Text = "NEXT >" }, palette.Cyan)
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

---------------------------------------------------------------------------------------------
-- UI overhaul (2026-11-26): the hub card layout. The SAME widgets and handlers as the legacy
-- column (one queue listener, one remote path); they are only re-parented and re-placed:
--   card (top right): hub name / NEXT RACE + countdown / course + queue line /
--                     [READY?][JOIN RACE | LEAVE QUEUE] / [MAPS][SETTINGS][MENU]
--   MENU drawer (left of the card, closed by default): ABILITIES, GARAGE, QUESTS, TIME TRIAL,
--                     PARTY, LEADERBOARDS, CAPSULE LAB, SEASON, SHOP + the emote bar
--   profile pill (under the card): LEVEL + COINS; tap opens the profile drawer
--   practice: card and drawers step aside for a top strip with the objective + EXIT PRACTICE
-- GameConfig.UI.LegacyHud = true keeps the old column (development flag, parity fallback).
---------------------------------------------------------------------------------------------
function MatchUI:UseCardLayout(adopt)
	adopt = adopt or {}
	self.cardMode = true
	local lobby = self.lobby
	local maid = self.maid
	local card = UIKit.panel(lobby, { Name = "HubCard", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 8), Size = UDim2.fromOffset(290, 184) })
	UIKit.TrackAccent(UIKit.new("UIStroke", { Thickness = 2 }, card), "Color")
	self.card = card
	self.hubLabel = UIKit.label(card, { Position = UDim2.fromOffset(12, 6), Size = UDim2.new(1, -24, 0, 18), Font = Enum.Font.GothamBold, TextColor3 = palette.Cyan, TextXAlignment = Enum.TextXAlignment.Left, Text = "ORBITAL GARAGE" })
	-- status lines move into the card (the old status panel is hidden: one NEXT RACE on screen)
	local oldStatus = self.statusMain.Parent
	self.statusMain.Parent = card
	self.statusMain.Position, self.statusMain.Size = UDim2.fromOffset(12, 26), UDim2.new(1, -24, 0, 30)
	self.statusMain.TextXAlignment = Enum.TextXAlignment.Left
	self.statusSub.Parent = card
	self.statusSub.Position, self.statusSub.Size = UDim2.fromOffset(12, 58), UDim2.new(1, -24, 0, 18)
	self.statusSub.TextXAlignment = Enum.TextXAlignment.Left
	self.statusSub.TextColor3 = palette.White
	oldStatus.Visible = false
	self.queueButton.Parent = card
	self.readyButton.Parent = card
	self.queueButton.AnchorPoint, self.readyButton.AnchorPoint = Vector2.new(0, 0), Vector2.new(0, 0)
	-- bottom row: MAPS, SETTINGS, MENU
	local maps = UIKit.button(card, { Name = "Maps", Position = UDim2.fromOffset(10, 136), Size = UDim2.fromOffset(84, 40), Text = "MAPS" }, palette.Cyan)
	maid:Give(maps.Activated:Connect(function()
		self.MapsRequested:Fire()
	end))
	self.settingsButton.Parent = card
	self.settingsButton.Position, self.settingsButton.Size = UDim2.fromOffset(100, 136), UDim2.fromOffset(100, 40)
	local menu = UIKit.button(card, { Name = "HubDrawer", Position = UDim2.fromOffset(206, 136), Size = UDim2.fromOffset(74, 40), Text = "MENU" }, palette.White)
	self.menuButton = menu
	-- the drawer: every secondary hub action, closed by default
	local drawer = UIKit.panel(lobby, { Name = "HubDrawerPanel", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -314, 0, 8), Size = UDim2.fromOffset(268, 296), Visible = false })
	self.drawer = drawer
	local items = { self.loadoutButton, self.garageButton, self.questsButton }
	for _, b in ipairs(adopt.buttons or {}) do
		items[#items + 1] = b
	end
	for _, b in ipairs({ self.boardsButton, self.labButton, self.seasonButton, self.shopButton }) do
		items[#items + 1] = b
	end
	for i, b in ipairs(items) do
		local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
		b.Parent = drawer
		b.AnchorPoint = Vector2.new(0, 0)
		b.Position = UDim2.fromOffset(8 + col * 128, 8 + row * 50)
		b.Size = UDim2.fromOffset(124, 44)
		b.Visible = true
		maid:Give(b.Activated:Connect(function()
			drawer.Visible = false -- opening something closes the drawer
		end))
	end
	local rows = math.ceil(#items / 2)
	if adopt.emotes then
		adopt.emotes.Parent = drawer
		adopt.emotes.AnchorPoint = Vector2.new(0, 0)
		adopt.emotes.Position = UDim2.fromOffset(8, 8 + rows * 50)
		rows = rows + 1
	end
	drawer.Size = UDim2.fromOffset(268, 16 + rows * 50)
	self.moreButton.Visible = false
	self.moreMenu.Visible = false
	maid:Give(menu.Activated:Connect(function()
		UIKit.Show(drawer, not drawer.Visible, "FromAbove", 0.2)
		self.profileOpen = false
		self:_renderProfileDrawer()
	end))
	-- profile pill + drawer (collapsed)
	local pill = UIKit.button(lobby, { Name = "ProfileDrawer", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 198), Size = UDim2.fromOffset(290, 34), Text = "LEVEL 1" }, palette.Violet)
	pill.TextXAlignment = Enum.TextXAlignment.Left
	UIKit.new("UIPadding", { PaddingLeft = UDim.new(0, 12) }, pill)
	self.profilePill = pill
	self.profileChip = self.levelLabel.Parent
	self.profileChip.Position = UDim2.new(1, -14, 0, 238)
	self.profileChip.Size = UDim2.fromOffset(290, 84)
	self.profileOpen = false
	maid:Give(pill.Activated:Connect(function()
		self.profileOpen = not self.profileOpen
		drawer.Visible = false
		self:_renderProfileDrawer()
	end))
	self:_renderProfileDrawer()
	-- practice strip (top centre): objective + EXIT PRACTICE
	local practice = UIKit.panel(lobby, { Name = "PracticeStrip", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 52), Size = UDim2.fromOffset(560, 56), Visible = false }) -- under the phase strip
	self.practiceStrip = practice
	self.practiceText = UIKit.label(practice, { Position = UDim2.fromOffset(14, 6), Size = UDim2.new(1, -200, 1, -12), TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, Text = "" })
	local exit = UIKit.button(practice, { Name = "ExitPractice", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.fromOffset(176, 42), Text = "EXIT PRACTICE" }, palette.Coral)
	maid:Give(exit.Activated:Connect(function()
		self.PracticeExitRequested:Fire()
	end))
	self:_renderReady()
end

---------------------------------------------------------------------------------------------
-- Hub layout v2 (owner feedback 2026-11-26: "the UI looks the same"). The same widgets and
-- handlers, a new arrangement:
--   top right    profile chip (LEVEL · COINS, tap = profile) and the PLAY card: hub name,
--                your queue status, [READY?] [JOIN RACE | LEAVE QUEUE] (the one primary action)
--   bottom dock  icon tiles between the thumbs: GARAGE, CASES, SHOP, QUESTS, ABILITIES, MAPS,
--                MORE (MORE pops up SEASON, TIME TRIAL, PARTY, LEADERBOARDS, SETTINGS + emotes)
--   top centre   the phase strip (map · phase · timer) - the only countdown on screen
--   practice     the card, chip and dock step aside for the objective strip + EXIT PRACTICE
---------------------------------------------------------------------------------------------
MatchUI.DockItems = {
	{ key = "garage", icon = "Marble", text = "GARAGE" },
	{ key = "lab", icon = "Case", text = "CASES" },
	{ key = "shop", icon = "Bag", text = "SHOP" },
	{ key = "quests", icon = "Quests", text = "QUESTS" },
	{ key = "loadout", icon = "Bolt", text = "ABILITIES" },
	{ key = "maps", icon = "Map", text = "MAPS" },
	{ key = "more", icon = "More", text = "MORE" },
}

function MatchUI:UseDockLayout(adopt)
	adopt = adopt or {}
	self.cardMode = true
	local lobby = self.lobby
	local maid = self.maid
	-- profile chip (top right)
	local pill = UIKit.button(lobby, { Name = "ProfileDrawer", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 8), Size = UDim2.fromOffset(300, 34), Text = "LEVEL 1", TextXAlignment = Enum.TextXAlignment.Right }, palette.White)
	UIKit.new("UIPadding", { PaddingRight = UDim.new(0, 12) }, pill)
	self.profilePill = pill
	self.profileChip = self.levelLabel.Parent
	self.profileChip.Position = UDim2.new(1, -14, 0, 48)
	self.profileChip.Size = UDim2.fromOffset(300, 84)
	self.profileChip.ZIndex = 5
	self.profileOpen = false
	maid:Give(pill.Activated:Connect(function()
		self.profileOpen = not self.profileOpen
		if self.drawer then
			self.drawer.Visible = false
		end
		self:_renderProfileDrawer()
	end))
	-- the PLAY card
	local card = UIKit.panel(lobby, { Name = "HubCard", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 50), Size = UDim2.fromOffset(300, 128) })
	self.card = card
	local bar = UIKit.new("Frame", { Name = "AccentBar", Size = UDim2.new(0, 4, 1, 0), BorderSizePixel = 0 }, card)
	UIKit.TrackAccent(bar, "BackgroundColor3")
	self.hubLabel = UIKit.label(card, { Position = UDim2.fromOffset(16, 8), Size = UDim2.new(1, -28, 0, 16), Font = Enum.Font.GothamBold, TextColor3 = UIKit.Colors.Muted, TextXAlignment = Enum.TextXAlignment.Left, Text = "ORBITAL GARAGE" })
	local oldStatus = self.statusMain.Parent
	self.statusMain.Parent = card
	self.statusMain.Position, self.statusMain.Size = UDim2.fromOffset(16, 26), UDim2.new(1, -28, 0, 26)
	self.statusMain.TextXAlignment = Enum.TextXAlignment.Left
	self.statusMain.Font = UIKit.Fonts.Display or self.statusMain.Font
	self.statusSub.Parent = card
	self.statusSub.Position, self.statusSub.Size = UDim2.fromOffset(16, 54), UDim2.new(1, -28, 0, 16)
	self.statusSub.TextXAlignment = Enum.TextXAlignment.Left
	self.statusSub.TextColor3 = UIKit.Colors.Muted
	oldStatus.Visible = false
	self.queueButton.Parent = card
	self.readyButton.Parent = card
	self.queueButton.AnchorPoint, self.readyButton.AnchorPoint = Vector2.new(0, 0), Vector2.new(0, 0)
	-- bottom dock
	local dock = UIKit.panel(lobby, { Name = "HubDock", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -10), Size = UDim2.fromOffset(#MatchUI.DockItems * 76 + 12, 74), BackgroundTransparency = 0.2 })
	self.dock = dock
	local more = UIKit.panel(lobby, { Name = "HubDrawerPanel", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -94), Size = UDim2.fromOffset(268, 296), Visible = false })
	self.drawer = more
	local maps = UIKit.button(lobby, { Name = "Maps", Text = "" }, palette.White)
	maid:Give(maps.Activated:Connect(function()
		self.MapsRequested:Fire()
	end))
	local menu = UIKit.button(lobby, { Name = "HubDrawer", Text = "" }, palette.White)
	self.menuButton = menu
	maid:Give(menu.Activated:Connect(function()
		UIKit.Show(more, not more.Visible, "FromBelow", 0.2)
		self.profileOpen = false
		self:_renderProfileDrawer()
	end))
	local byKey = { garage = self.garageButton, lab = self.labButton, shop = self.shopButton, quests = self.questsButton, loadout = self.loadoutButton, maps = maps, more = menu }
	for i, item in ipairs(MatchUI.DockItems) do
		local b = byKey[item.key]
		b.Parent = dock
		b.AnchorPoint = Vector2.new(0, 0)
		b.Position = UDim2.fromOffset(6 + (i - 1) * 76, 5)
		b.Size = UDim2.fromOffset(72, 64)
		b.Text = ""
		b.BackgroundTransparency = 0.6
		b.Visible = true
		UIKit.Icon(b, item.icon, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, -2), Size = UDim2.fromOffset(26, 26) })
		UIKit.label(b, { Name = "DockLabel", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, 4), Size = UDim2.new(1, 0, 0, 14), Font = Enum.Font.GothamBold, Text = item.text })
		if item.key ~= "more" then
			maid:Give(b.Activated:Connect(function()
				more.Visible = false
			end))
		end
	end
	-- MORE: the rest, two columns + the emote bar
	local items = { self.seasonButton }
	for _, b in ipairs(adopt.buttons or {}) do
		items[#items + 1] = b
	end
	items[#items + 1] = self.boardsButton
	items[#items + 1] = self.settingsButton
	for i, b in ipairs(items) do
		local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
		b.Parent = more
		b.AnchorPoint = Vector2.new(0, 0)
		b.Position = UDim2.fromOffset(8 + col * 128, 10 + row * 50)
		b.Size = UDim2.fromOffset(124, 44)
		b.Visible = true
		maid:Give(b.Activated:Connect(function()
			more.Visible = false
		end))
	end
	local rows = math.ceil(#items / 2)
	if adopt.emotes then
		adopt.emotes.Parent = more
		adopt.emotes.AnchorPoint = Vector2.new(0, 0)
		adopt.emotes.Position = UDim2.fromOffset(8, 10 + rows * 50)
		rows = rows + 1
	end
	more.Size = UDim2.fromOffset(268, 18 + rows * 50)
	self.moreButton.Visible = false
	self.moreMenu.Visible = false
	self:_renderProfileDrawer()
	-- practice strip (top centre, under the phase strip): objective + EXIT PRACTICE
	local practice = UIKit.panel(lobby, { Name = "PracticeStrip", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 52), Size = UDim2.fromOffset(560, 56), Visible = false })
	self.practiceStrip = practice
	self.practiceText = UIKit.label(practice, { Position = UDim2.fromOffset(14, 6), Size = UDim2.new(1, -200, 1, -12), TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, Text = "" })
	local exit = UIKit.button(practice, { Name = "ExitPractice", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.fromOffset(176, 42), Text = "EXIT PRACTICE" }, palette.Coral)
	maid:Give(exit.Activated:Connect(function()
		self.PracticeExitRequested:Fire()
	end))
	self:_renderReady()
end

function MatchUI:_renderProfileDrawer()
	if self.profileChip then
		UIKit.Show(self.profileChip, self.profileOpen == true and not self.practicing, "FromAbove", 0.2)
	end
	if self.profilePill then
		local p = self.lastProfile or {}
		UIKit.setText(self.profilePill, string.format("LV %d   |   %d COINS%s", p.level or 1, p.coins or 0, self.profileOpen and "   (close)" or ""))
	end
end

function MatchUI:SetHubName(name)
	if self.hubLabel then
		UIKit.setText(self.hubLabel, string.upper(name or ""))
	end
end

-- objective text while on a practice lane, nil when back on the deck
function MatchUI:SetPractice(objective)
	if not self.cardMode then
		return
	end
	local practicing = objective ~= nil
	if practicing then
		UIKit.setText(self.practiceText, "PRACTICE  -  " .. objective)
	end
	if practicing == self.practicing then
		return
	end
	self.practicing = practicing
	UIKit.Show(self.practiceStrip, practicing, "FromAbove")
	UIKit.Show(self.card, not practicing, "FromRight")
	UIKit.Show(self.profilePill, not practicing, "FromRight")
	if self.dock then
		UIKit.Show(self.dock, not practicing, "FromBelow")
	end
	if practicing then
		self.drawer.Visible = false
	end
	self:_renderProfileDrawer()
end

function MatchUI:SetDensity(density)
	self.density = density
	if self.statusSub then
		self.statusSub.Visible = density ~= "Compact" or not self.cardMode
	end
end

-- e.g. "BOOST + SHIELD": the equipped pair, shown on the LOADOUT button itself
function MatchUI:SetLoadoutText(text)
	self.loadoutText = text
	if self.dock and self.loadoutButton.Parent == self.dock then
		return -- docked: the tile shows its icon + label only (owner screenshot: text overlapped)
	end
	UIKit.setText(self.loadoutButton, "ABILITIES\n" .. text)
end

function MatchUI:SetLobbyVisible(visible)
	local was = self.lobby.Visible == true
	self.lobby.Visible = visible
	if visible and not was and self.cardMode and not self.practicing then
		UIKit.Enter(self.card, "FromRight") -- back from a race / results: the hub slides in
		UIKit.Enter(self.profilePill, "FromRight")
		if self.dock then
			UIKit.Enter(self.dock, "FromBelow")
		end
	end
end

function MatchUI:SetSpectateVisible(visible)
	UIKit.Show(self.spectateFrame, visible, "FromBelow")
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
	if self.cardMode then -- one row inside the card: [READY?][LEAVE QUEUE] or one wide button
		local w = self.dock and 272 or 270 -- v2 card is 300 wide (accent bar on the left)
		local x = self.dock and 16 or 10
		if show then
			self.readyButton.Position, self.readyButton.Size = UDim2.fromOffset(x, 76), UDim2.fromOffset(w / 2 - 4, 44)
			self.queueButton.Position, self.queueButton.Size = UDim2.fromOffset(x + w / 2 + 4, 76), UDim2.fromOffset(w / 2 - 4, 44)
		else
			self.queueButton.Position, self.queueButton.Size = UDim2.fromOffset(x, 76), UDim2.fromOffset(w, 44)
		end
	end
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
	self.lastProfile = p
	self:_renderProfileDrawer()
	self.saveLabel.TextColor3 = (p.status == "Ready" or p.status == "Mock" or p.status == "Loading") and palette.White or palette.Coral
end

local function clock(seconds)
	return (Utility.formatTime(math.max(0, seconds or 0)):gsub("%.%d+$", ""))
end

-- Status card text for the lobby (what the race HUD used to say at the top of the hub screen).
function MatchUI:_statusText(ctx)
	local snap = self.snapshot
	if snap.state == S.Intermission then
		local sub
		if snap.readyOpen then
			sub = string.format("Race full - %d/%d READY", snap.readyCount or 0, snap.queuedCount or 0)
		else
			sub = string.format("Waiting for players (%d/%d)", snap.queuedCount or 0, snap.raceCapacity or 16)
		end
		if not self.queued then
			sub = string.format("%d/%d racers queued - join to race", snap.queuedCount or 0, snap.raceCapacity or 16)
		end
		-- the countdown itself is on the phase strip (one timer on screen, brief 2026-11-26)
		return self.queued and "YOU'RE IN" or "NOT QUEUED", sub
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
	if self.cardMode then
		UIKit.setText(self.queueButton, self.queued and "LEAVE QUEUE" or "JOIN RACE")
	else
		UIKit.setText(self.queueButton, self.queued and "SIT OUT" or "JOIN RACE")
	end
	UIKit.SetPrimary(self.queueButton, not self.queued) -- JOIN is the hub's one primary action
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
		UIKit.setText(main, world and ("NEXT MAP: " .. string.upper(world)) or "NEXT RACE") -- the timer is on the HUD strip
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
