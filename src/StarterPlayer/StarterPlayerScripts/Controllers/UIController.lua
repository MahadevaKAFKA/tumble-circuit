--[[
	UIController (A5) — the ONE owner of which UI is on screen. Every ScreenGui layer registers
	here and is shown only when the current screen (or modal) lists it, so controllers never
	compete. Screens: Title, Lobby, Race, Spectate, Results; modals: Settings, Loadout.

	ScreenFor(ctx) is pure (UIState.spec). ctx = { started, spectating, roundState, inRace,
	resultsDismissed }. Modals are allowed only on some screens and close automatically when the
	screen changes to one that does not allow them (e.g. the race starts while Loadout is open:
	abilities can never be switched mid-race).
	Every button a screen shows is listed with its action (no dead buttons: UIState.spec checks
	that each one is in Actions, and the bootstrap binds every action).
]]

local UIController = {}
UIController.__index = UIController

UIController.Screens = {
	Title = { layers = { "Title" }, buttons = { "Play" } },
	Lobby = {
		-- No RaceHud here (owner playtest 2026-11-25): its top-centre status sat on top of the hub's
		-- 3D board; the lobby column now carries the countdown / waiting line itself.
		-- AbilitiesRace here = B2 try-it buttons (only shown after TRY in the ability menu)
		layers = { "Hud", "Lobby", "Modes", "Touch", "Social", "AbilitiesRace" }, -- loadout summary lives on the LOADOUT button
		buttons = { "Queue", "Loadout", "Settings", "Spectate", "Camera", "Reset", "Emote", "Vote", "TimeTrial", "Party", "Invite", "MapVote", "Ability1", "Ability2", "Garage", "Quests", "More", "Boards", "Lab", "Shop", "Maps", "HubDrawer", "ProfileDrawer", "ExitPractice" },
	},
	-- B1 solo Time Trial: timer card + QUIT; no abilities, no lobby column
	TimeTrial = { layers = { "Hud", "TimeTrial", "Touch" }, buttons = { "QuitTrial", "Brake", "Reset", "Camera" } },
	Race = {
		layers = { "Hud", "RaceHud", "AbilitiesRace", "Touch", "Social" }, -- Social: chaos banner only
		buttons = { "Ability1", "Ability2", "Trick", "Brake", "Reset", "Camera" },
	},
	Spectate = { layers = { "RaceHud", "Spectate", "Social" }, buttons = { "SpectatePrev", "SpectateNext", "SpectateExit", "Settings", "Emote", "Vote" } },
	Results = { layers = { "RaceHud", "Results", "Social" }, buttons = { "PlayAgain", "SitOut", "Loadout", "Settings" } },
}

UIController.Modals = {
	Settings = { layer = "Settings", allowedOn = { Lobby = true, Results = true, Spectate = true }, buttons = { "Close", "SettingToggle", "SettingsTab", "SettingsReset" } },
	Loadout = { layer = "Loadout", allowedOn = { Lobby = true, Results = true }, buttons = { "Close", "EquipSlot", "UnlockAbility" } },
	-- B3 hub menus
	Garage = { layer = "Garage", allowedOn = { Lobby = true, Results = true }, buttons = { "Close", "GarageTab", "GarageFilter", "GarageItem", "Equip", "Favorite" } },
	Quests = { layer = "Quests", allowedOn = { Lobby = true, Results = true }, buttons = { "Close", "QuestClaim" } },
	Boards = { layer = "Boards", allowedOn = { Lobby = true, Results = true, Spectate = true }, buttons = { "Close", "BoardWorld", "BoardKind" } },
	-- C: Capsule Lab (free capsule, Shard Shop, free season)
	Lab = { layer = "Lab", allowedOn = { Lobby = true, Results = true }, buttons = { "Close", "LabTab", "CapsuleBox", "OpenCapsule", "SkipReveal", "ShardItem", "SeasonClaim" } },
	-- prompt 03: Map Selection (Visit Hub / Practice / Vote for Next Race)
	MapSelect = { layer = "MapSelect", allowedOn = { Lobby = true, Results = true }, buttons = { "Close", "MapVisit", "MapPractice", "MapBallot", "MapPage" } },
	-- D: the optional shop, lobby only (never during a race or on results)
	Shop = { layer = "Shop", allowedOn = { Lobby = true }, buttons = { "Close", "ShopItem", "ShopGet", "LaneClaim" } },
}

UIController.Actions = {
	"Play", "Queue", "Loadout", "Settings", "Spectate", "Camera", "Reset",
	"Ability1", "Ability2", "Trick", "Brake",
	"SpectatePrev", "SpectateNext", "SpectateExit",
	"PlayAgain", "SitOut", "Close", "SettingToggle", "EquipSlot",
	"Emote", "Vote", -- A6
	"TimeTrial", "Party", "Invite", "MapVote", "QuitTrial", -- B1
	"UnlockAbility", -- B2
	"Garage", "Quests", "More", "Boards", "GarageTab", "GarageFilter", "GarageItem", "Equip", "Favorite", "QuestClaim", "BoardWorld", "BoardKind", -- B3
	"Lab", "LabTab", "CapsuleBox", "OpenCapsule", "SkipReveal", "ShardItem", "SeasonClaim", -- C (CapsuleBox: 2026-11-26)
	"Shop", "ShopItem", "ShopGet", "LaneClaim", -- D (optional shop)
	"Maps", "MapVisit", "MapPractice", "MapBallot", "MapPage", -- promo pack 03 (Map Selection)
	"SettingsTab", "SettingsReset", "HubDrawer", "ProfileDrawer", "ExitPractice", -- UI overhaul
}

local RACE_STATES = { Preparing = true, Countdown = true, Racing = true }

-- Pure.
function UIController.ScreenFor(ctx)
	if not ctx.started then
		return "Title"
	end
	if ctx.spectating then
		return "Spectate"
	end
	if ctx.timeTrial then
		return "TimeTrial" -- B1: a solo run is its own screen, even while others see results
	end
	if ctx.roundState == "Results" and not ctx.resultsDismissed then
		return "Results"
	end
	if ctx.inRace and RACE_STATES[ctx.roundState] then
		return "Race"
	end
	return "Lobby"
end

function UIController.ModalAllowed(modal, screen)
	local spec = UIController.Modals[modal]
	return spec ~= nil and spec.allowedOn[screen] == true
end

-- Pure: the set of visible layer names for (screen, modal).
function UIController.VisibleLayers(screen, modal)
	local visible = {}
	for _, layer in ipairs(UIController.Screens[screen].layers) do
		visible[layer] = true
	end
	if modal and UIController.ModalAllowed(modal, screen) then
		visible[UIController.Modals[modal].layer] = true
		visible.Touch = nil -- no stray touches through a modal
	end
	return visible
end

function UIController.new()
	local self = setmetatable({}, UIController)
	self.layers = {} -- name -> function(visible)
	self.screen = nil
	self.modal = nil
	self.listeners = {}
	return self
end

function UIController:Register(name, setVisible)
	self.layers[name] = setVisible
end

function UIController:OnScreenChanged(fn)
	table.insert(self.listeners, fn)
end

function UIController:OpenModal(name)
	if not UIController.ModalAllowed(name, self.screen) then
		return false
	end
	self.modal = name
	self:_apply()
	return true
end

function UIController:CloseModal()
	if self.modal then
		self.modal = nil
		self:_apply()
	end
end

function UIController:GetScreen()
	return self.screen
end

function UIController:GetModal()
	return self.modal
end

function UIController:Refresh(ctx)
	local screen = UIController.ScreenFor(ctx)
	local changed = screen ~= self.screen
	self.screen = screen
	if self.modal and not UIController.ModalAllowed(self.modal, screen) then
		self.modal = nil -- e.g. the race started: the loadout can't change mid-race
	end
	self:_apply()
	if changed then
		for _, fn in ipairs(self.listeners) do
			fn(screen)
		end
	end
	return screen
end

function UIController:_apply()
	local visible = UIController.VisibleLayers(self.screen or "Title", self.modal)
	for name, setVisible in pairs(self.layers) do
		setVisible(visible[name] == true)
	end
end

return UIController
