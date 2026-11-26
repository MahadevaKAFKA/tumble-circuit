--[[
	ClientBootstrap — wires the client (A1-A5).
	A5: UIController owns which layer is visible (Title / Lobby / Race / Spectate / Results +
	Settings / Loadout modals); ProfileState + RewardNotice drive the profile chip and results;
	settings are applied locally and saved through RequestSettings.

	Flow: Loading -> Title (PLAY) -> Live. In Live the server's round snapshot decides what you
	can do: free practice in the hub, frozen on the grid, racing, finished/spectating, results.
	The client never decides checkpoints, placement or finish; it requests recovery and joining
	only. Steering is live only when the marble is unanchored and the round allows it.

	Per frame (one BindToRenderStep after the camera priority):
	  input -> route progress (own zone) -> steering frame -> motor -> hazard -> camera -> HUDs
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")

local player = Players.LocalPlayer

local function fatalScreen(text)
	local gui = Instance.new("ScreenGui")
	gui.Name = "TumbleFatal"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 100
	local textLabel = Instance.new("TextLabel")
	textLabel.Size = UDim2.fromScale(1, 1)
	textLabel.BackgroundColor3 = Color3.fromRGB(10, 15, 30)
	textLabel.TextColor3 = Color3.fromRGB(255, 107, 112)
	textLabel.TextWrapped = true
	textLabel.TextSize = 24
	textLabel.Font = Enum.Font.GothamBold
	textLabel.Text = text
	textLabel.Parent = gui
	gui.Parent = player:WaitForChild("PlayerGui")
	warn("[TumbleCircuit] " .. text)
end

local Shared = ReplicatedStorage:WaitForChild("Shared", 20)
local Controllers = script.Parent:WaitForChild("Controllers", 20)
if not Shared or not Controllers then
	fatalScreen("Tumble Circuit could not find its scripts (ReplicatedStorage.Shared or Controllers). Rebuild the place from the Rojo project.")
	return
end

local GameConfig = require(Shared:WaitForChild("GameConfig"))
local PhysicsConfig = require(Shared:WaitForChild("PhysicsConfig"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local RaceConfig = require(Shared:WaitForChild("RaceConfig"))
local RoundProtocol = require(Shared:WaitForChild("RoundProtocol"))
local RouteTracker = require(Shared:WaitForChild("RouteTracker"))
local TrackDefinitions = require(Shared:WaitForChild("TrackDefinitions"))
local MapRegistry = require(Shared:WaitForChild("MapRegistry"))
local VisualProfiles = require(Shared:WaitForChild("VisualProfiles"))
local Utility = require(Shared:WaitForChild("Utility"))
local PlaceholderIds = require(Shared:WaitForChild("PlaceholderIds"))

local InputController = require(Controllers:WaitForChild("InputController"))
local TouchControls = require(Controllers:WaitForChild("TouchControls"))
local MarbleMotorController = require(Shared:WaitForChild("MarbleMotorController")) -- shared with server bots (A4)
local CameraController = require(Controllers:WaitForChild("CameraController"))
local FreeLookController = require(Controllers:WaitForChild("FreeLookController"))
local HazardController = require(Controllers:WaitForChild("HazardController"))
local HUD = require(Controllers:WaitForChild("PrototypeHUDController"))
local RaceHUD = require(Controllers:WaitForChild("RaceHUDController"))
local MatchUI = require(Controllers:WaitForChild("MatchUIController"))
local SoundController = require(Controllers:WaitForChild("SoundController"))
local AbilityController = require(Controllers:WaitForChild("AbilityController"))
local VFXController = require(Controllers:WaitForChild("VFXController"))
local UIController = require(Controllers:WaitForChild("UIController"))
local SettingsController = require(Controllers:WaitForChild("SettingsController"))
local StarterLoadoutController = require(Controllers:WaitForChild("StarterLoadoutController"))
local ResultsController = require(Controllers:WaitForChild("ResultsController"))
local RaceIntroController = require(Controllers:WaitForChild("RaceIntroController"))
local SpeedFeelController = require(Controllers:WaitForChild("SpeedFeelController"))
local MotionFeel = require(Shared:WaitForChild("MotionFeel"))
local DevPanelController = require(Controllers:WaitForChild("DevPanelController"))
local SocialController = require(Controllers:WaitForChild("SocialController"))
local ModesController = require(Controllers:WaitForChild("ModesController"))
local HubMenusController = require(Controllers:WaitForChild("HubMenusController"))
local MapSelectController = require(Controllers:WaitForChild("MapSelectController"))
local EnvironmentController = require(Controllers:WaitForChild("EnvironmentController"))
local UIKit = require(Controllers:WaitForChild("UIKit"))
local LabController = require(Controllers:WaitForChild("LabController"))
local ShopController = require(Controllers:WaitForChild("ShopController"))
local Lighting = game:GetService("Lighting")

local ATTR = Protocol.PlayerAttributes
local BALL = Protocol.BallAttributes
local ZONES = Protocol.Zones
local REASONS = Protocol.SpawnReasons
local S = RoundProtocol.States
local MODES = MarbleMotorController.Modes

-- Default Roblox controls off: no Humanoid to drive, and exactly one touch thumbstick (ours).
pcall(function()
	GuiService.TouchControlsEnabled = false
end)
task.spawn(function()
	local ok, err = pcall(function()
		local playerModule = player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 10)
		require(playerModule):GetControls():Disable()
	end)
	if not ok then
		warn("[TumbleCircuit] default controls not disabled (" .. tostring(err) .. "); harmless without a Character")
	end
end)

---------------------------------------------------------------------------------------------
-- Controllers
---------------------------------------------------------------------------------------------
-- TouchControls and the HUD read workspace.CurrentCamera when they are created.
if not workspace.CurrentCamera then
	workspace:GetPropertyChangedSignal("CurrentCamera"):Wait()
end

local maid = Utility.Maid.new()
local input = maid:Give(InputController.new())
local hud = maid:Give(HUD.new(input))
local touch = maid:Give(TouchControls.new(input))
local sound = maid:Give(SoundController.new(PlaceholderIds))
local motor = maid:Give(MarbleMotorController.new())
local cameraController = maid:Give(CameraController.new())
-- A4 owner request: look around with right mouse drag, a finger outside the stick area, or the
-- right stick. Display only (steering follows the track).
local freeLook = maid:Give(FreeLookController.new(cameraController, function(position)
	return touch:IsStickZone(position)
end))
local raceHud = maid:Give(RaceHUD.new())
local matchUi = maid:Give(MatchUI.new())
local ui = UIController.new()
raceHud:SetVisible(false)
matchUi:SetLobbyVisible(false)

-- Loading diagnostics (owner report 2026-11-26: stuck on this screen). The screen shows how
-- long it has waited and for what, a server start-up error as soon as the server reports one,
-- and any client script error while loading, so one phone screenshot names the failure.
local loadStage = "waiting for the server"
local loadStarted = os.clock()
local function showLoading()
	hud:ShowMessage(string.format("Building the hub and race tracks... %d s\n(%s)", math.floor(os.clock() - loadStarted), loadStage))
end
showLoading()
pcall(function() -- diagnostics must never be the thing that breaks loading
	maid:Give(game:GetService("ScriptContext").Error:Connect(function(message, trace)
		if hud:GetOverlay() == "Message" and loadStage ~= "ready" then
			local firstLine = string.match(tostring(trace or ""), "[^\n]+") or ""
			hud:ShowMessage("Client error while " .. loadStage .. ":\n" .. tostring(message) .. "\n" .. firstLine, true)
			loadStage = "failed"
		end
	end))
end)
local function serverError()
	return workspace:GetAttribute(Protocol.WorkspaceAttributes.ServerError)
end

---------------------------------------------------------------------------------------------
-- Wait (bounded) for the server
---------------------------------------------------------------------------------------------
local timeout = GameConfig.Spawn.ClientWaitTimeoutSeconds
-- poll for a child with a deadline; stops early (nil, reason) when the server reports an error
local function waitFor(parent, name, seconds)
	local deadline = os.clock() + seconds
	local lastShown = -1
	while os.clock() < deadline do
		local found = parent:FindFirstChild(name)
		if found then
			return found
		end
		local err = serverError()
		if err then
			return nil, err
		end
		local elapsed = math.floor(os.clock() - loadStarted)
		if elapsed ~= lastShown then
			lastShown = elapsed
			showLoading()
		end
		task.wait(0.1)
	end
	return nil
end
local remotes, remotesError = waitFor(ReplicatedStorage, RoundProtocol.FolderName, timeout)

local function waitForWorld()
	local deadline = os.clock() + timeout
	local lastShown = -1
	while os.clock() < deadline do
		local err = serverError()
		if err then
			return nil, nil, "server error: " .. tostring(err)
		end
		local elapsed = math.floor(os.clock() - loadStarted)
		if elapsed ~= lastShown then
			lastShown = elapsed
			showLoading()
		end
		if workspace:GetAttribute(Protocol.WorkspaceAttributes.CourseReady) then
			local course = workspace:FindFirstChild(Protocol.CourseModelName)
			local hubRoot = workspace:FindFirstChild(Protocol.HubModelName)
			if course and hubRoot then
				return course, hubRoot
			end
		elseif workspace:GetAttribute(Protocol.WorkspaceAttributes.CourseError) then
			return nil, nil, workspace:GetAttribute(Protocol.WorkspaceAttributes.CourseError)
		end
		task.wait(0.1)
	end
	return nil, nil, "timed out waiting for the server to build the world"
end

loadStage = "waiting for the world"
local course, hubRoot, worldError = waitForWorld()
if not worldError and remotesError then
	worldError = "server error: " .. tostring(remotesError)
end
loadStage = "waiting for the marbles"
local marblesFolder, marblesError = nil, nil
if course then
	marblesFolder, marblesError = waitFor(workspace, Protocol.MarblesFolderName, timeout)
	if not worldError and marblesError then
		worldError = "server error: " .. tostring(marblesError)
	end
end
loadStage = "connecting"
local remote = {}
if remotes then
	for name, spec in pairs(RoundProtocol.Remotes) do
		-- Studio/authorized-only remotes may legitimately be absent (live servers)
		-- (written as an if: `a and b or c` would fall through to a 5 s WaitForChild whenever the
		-- Studio-only remote is absent, i.e. on every live server - 10 s of extra loading)
		if spec.StudioOnly then
			remote[name] = remotes:FindFirstChild(name)
		else
			remote[name] = remotes:WaitForChild(name, 5)
		end
	end
end
local remotesOk = remotes ~= nil and remotes:GetAttribute("ProtocolVersion") == RoundProtocol.Version
for name, spec in pairs(RoundProtocol.Remotes) do
	if not remote[name] and not spec.StudioOnly then
		remotesOk = false
	end
end
if not remotesOk or not course or not marblesFolder then
	-- Name the actual failure, so a phone screenshot is enough to diagnose it.
	local reason = worldError
	if not reason and not remotes then
		reason = "server remotes folder missing"
	elseif not reason and remotes:GetAttribute("ProtocolVersion") ~= RoundProtocol.Version then
		reason = string.format("protocol mismatch (server v%s, client v%s)", tostring(remotes:GetAttribute("ProtocolVersion")), tostring(RoundProtocol.Version))
	elseif not reason and not remotesOk then
		local missing = {}
		for name, spec in pairs(RoundProtocol.Remotes) do
			if not remote[name] and not spec.StudioOnly then
				missing[#missing + 1] = name
			end
		end
		reason = "server remotes missing: " .. table.concat(missing, ", ")
	elseif not reason then
		reason = "the server did not finish starting (no marbles folder)"
	end
	local late = serverError()
	if late and not string.find(tostring(reason), "server error", 1, true) then
		reason = tostring(reason) .. "\nserver error: " .. tostring(late)
	end
	hud:ShowMessage("Could not start: " .. tostring(reason) .. "\nOpen /console (Log, Server) for [TumbleCircuit] errors, then rejoin.", true)
	return
end
loadStage = "loading maps"
hubRoot:WaitForChild("PracticeChute", 5)

-- B1 / prompt 02: every registry map's layout, keyed by map id (the server built the same maps
-- from the same data); the Race zone means the active one. Maps the server dropped never
-- become active, so generating them here costs a little memory and nothing else.
local worldLayouts = {}
for _, map in ipairs(MapRegistry.Maps) do
	local def = TrackDefinitions.WorldsById[map.Track]
	if def then
		worldLayouts[map.Id] = TrackDefinitions.Generate(def, PhysicsConfig.Ball.Radius)
	end
end
local activeWorldId = workspace:GetAttribute(Protocol.WorkspaceAttributes.ActiveWorld)
if not worldLayouts[activeWorldId] then
	activeWorldId = MapRegistry.DefaultMapId
end
course:WaitForChild(activeWorldId, 5)
local defaultHub = MapRegistry.Hub(MapRegistry.DefaultHubId)
-- prompt 03/04: every hub's practice-lane layout, keyed by hub id; the Hub zone means the one
-- the bound marble is in (its HubId attribute)
local hubLayouts = {}
for _, entry in ipairs(MapRegistry.Hubs) do
	if entry.Status == "Live" or entry.Status == "Gated" then
		hubLayouts[entry.Id] = TrackDefinitions.Generate(entry.Chute, PhysicsConfig.Ball.Radius)
	end
end
local currentHubId = MapRegistry.DefaultHubId
local layouts = {
	[ZONES.Race] = worldLayouts[activeWorldId],
	[ZONES.Hub] = hubLayouts[MapRegistry.DefaultHubId],
}
local hazards = HazardController.new(course:FindFirstChild(activeWorldId) or course, motor, sound, layouts[ZONES.Race])
-- prompts 05 / 06: local-only Foundry visual pass + Garage observation deck (NewHubs gate)
-- UI / environment overhaul: each map's backdrop + hub staging, built on this client only
local environment = EnvironmentController.new({ course = course, worldLayouts = worldLayouts, hubLayouts = hubLayouts })
maid:Give(function()
	environment:Destroy()
end)
motor:SetMarblesFolder(marblesFolder)
local currentZone -- declared early: the environment push below only applies on the race course
motor:SetEnvironmentAccel(function(position)
	if currentZone == ZONES.Race then
		return hazards:EnvironmentAccel(position)
	end
	return nil
end)
local function setCheckpointMarks(raceLayout)
	local total = raceLayout.Route.total
	local marks = {}
	for i, cp in ipairs(raceLayout.Checkpoints) do
		marks[i] = cp.S / total
	end
	raceHud:SetCheckpointMarks(marks)
end
setCheckpointMarks(layouts[ZONES.Race])

-- A3 abilities + micro-skills (display/requests only; the server judges everything)
local abilities = maid:Give(AbilityController.new({
	remotes = remote,
	motor = motor,
	input = input,
	toast = function(text, seconds)
		hud:Toast(text, seconds)
	end,
	flash = function(text, color, seconds)
		raceHud:Flash(text, color, seconds)
	end,
}))
local vfx = maid:Give(VFXController.new(marblesFolder))
-- owner request 2026-11-26: every marble drops onto the grid + a camera swoop (visual only)
-- owner brief 2026-11-26: the free speed trail on every marble, speed streaks (visual only)
local speedFeel = maid:Give(SpeedFeelController.new({ marblesFolder = marblesFolder }))
-- the launch-ramp race intro (stand-ins + scripted camera; the server owns all timing)
local raceIntro = maid:Give(RaceIntroController.new({
	marblesFolder = marblesFolder,
	cameraController = cameraController,
	speedFeel = speedFeel,
	getLayout = function()
		return layouts[ZONES.Race]
	end,
	getMapId = function()
		return activeWorldId
	end,
}))
hazards:SetShieldQuery(function()
	return abilities:IsShielded()
end)
local reducedMotion = false
local speedEffectsOn = true -- Settings > Driving > SPEED FOV + STREAKS
local finishedMarbles = {} -- marble names that crossed the finish (their trails clear)
maid:Give(abilities.OutcomeReceived:Connect(function(outcome)
	vfx:OnOutcome(outcome)
	if outcome.userId == player.UserId and (outcome.abilityId == "Boost" or outcome.abilityId == "Shield") then
		sound:Play(outcome.abilityId) -- short distinct cues (silent until an audio id is set)
	end
end))
maid:Give(abilities.TrickPressed:Connect(function()
	vfx:Trick(player.UserId)
end))
maid:Give(abilities.ReducedMotionChanged:Connect(function(value)
	reducedMotion = value
	vfx:SetReducedMotion(value)
	hazards:SetReducedMotion(value)
end))
-- A5 modals, results, dev panel
local function isDeveloper() -- Studio, or an account with the development gate (TC_Features)
	local text = player:GetAttribute(Protocol.PlayerAttributes.Features)
	return RunService:IsStudio() or (type(text) == "string" and string.find(text, "NewHubs", 1, true) ~= nil)
end
local settings = maid:Give(SettingsController.new({ remotes = remote, showDev = isDeveloper() }))
local loadout = maid:Give(StarterLoadoutController.new({ remotes = remote }))
local results = maid:Give(ResultsController.new())
maid:Give(DevPanelController.new(remotes))
local social = maid:Give(SocialController.new({ remotes = remote, marblesFolder = marblesFolder, localUserId = player.UserId }))
loadStage = "building the menus"
-- prompt 03: Map Selection (Visit Hub / Practice / Vote for Next Race)
local mapSelect = maid:Give(MapSelectController.new({
	remotes = remote,
	toast = function(text, seconds)
		hud:Toast(text, seconds)
	end,
}))
mapSelect:RegisterLayers(ui)
-- B1 modes: ballot strip, Time Trial (+ PB ghost), Party Race
local modes = maid:Give(ModesController.new({
	remotes = remote,
	castBallot = function(mapIndex)
		mapSelect:CastBallot(mapIndex)
	end,
	toast = function(text, seconds)
		hud:Toast(text, seconds)
	end,
	flash = function(text, color, seconds)
		raceHud:Flash(text, color, seconds)
	end,
}))
maid:Give(social.ModifierChanged:Connect(function(modifier)
	hazards:SetModifier(modifier) -- A6 voted modifier: same timestamps as the server
end))
-- UI overhaul (2026-11-26): hub card + MENU drawer + profile drawer, compact race strip. The
-- same buttons and handlers as before, re-placed; GameConfig.UI.LegacyHud restores the old HUD.
if not GameConfig.UI.LegacyHud then
	matchUi:UseCardLayout({ buttons = { modes.trialButton, modes.partyButton }, emotes = social.emoteBar })
	modes:SetCardMode(true)
	raceHud:UseStrip()
end
maid:Give(remote.SkillEvent.OnClientEvent:Connect(function(data)
	if type(data) == "table" and (data.kind == "SlipstreamOn" or data.kind == "SlipstreamOff") then
		vfx:SetSlipstream(player.UserId, data.kind == "SlipstreamOn")
	end
end))
local trickZones = layouts[ZONES.Race].TrickZones or {}

-- The chase camera's obstruction ray ignores rails, decor, hazards, gates and features. Since
-- B1 each map sits in its own folder under the course, so collect them per map (the v16-v20
-- list looked at the course root and found none: audit 2026-11-26), and per hub.
local cameraIgnore = { marblesFolder }
local function ignoreParts(root, folderNames)
	if not root then
		return
	end
	for _, name in ipairs(folderNames) do
		local folder = root:FindFirstChild(name)
		if folder then
			cameraIgnore[#cameraIgnore + 1] = folder
		end
	end
end
local RACE_DECOR = { "Rails", "Decor", "Hazards", "Gates", "Features" }
for _, mapRoot in ipairs(course:GetChildren()) do
	ignoreParts(mapRoot, RACE_DECOR)
end
local function ignoreHub(root)
	ignoreParts(root, { "Rails", "Decor" })
	ignoreParts(root and root:FindFirstChild("PracticeChute"), { "Rails", "Decor" })
end
ignoreHub(hubRoot)
for _, entry in ipairs(MapRegistry.Hubs) do
	if entry.ModelName ~= Protocol.HubModelName then
		ignoreHub(workspace:FindFirstChild(entry.ModelName))
	end
end
local groundIgnore = { marblesFolder }
-- every hub's "next race" board (prompt 04: one per hub), updated from the round snapshot
local boards = {}
local function addBoard(root)
	local decor = root and root:FindFirstChild("Decor")
	local part = decor and decor:FindFirstChild("NextRaceBoard")
	local gui = part and part:FindFirstChild("Board")
	if gui then
		boards[#boards + 1] = gui
	end
end
addBoard(hubRoot)
for _, entry in ipairs(MapRegistry.Hubs) do
	if entry.ModelName ~= Protocol.HubModelName then
		addBoard(workspace:FindFirstChild(entry.ModelName))
	end
end

local function flatUnit(v, fallback)
	return Utility.safeUnit(Vector3.new(v.X, 0, v.Z), fallback)
end

---------------------------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------------------------
local uiState = "Title" -- "Title" | "Live"
local resultsDismissedRound = nil -- PLAY AGAIN / SIT OUT close the results for that round
local snapshot = nil
local currentBall = nil
currentZone = ZONES.Hub
local tracker = RouteTracker.new(layouts[ZONES.Hub].Route)
local steerForward = Vector3.new(1, 0, 0)
local tutorial = { active = false, done = false, left = 0, right = 0 }
local spectate = { active = false, userId = nil, ball = nil, tracker = RouteTracker.new(layouts[ZONES.Race].Route) }
local stuck = { seconds = 0, startS = 0, shown = false }

local function myEntry()
	if not snapshot then
		return nil
	end
	for _, entry in ipairs(snapshot.racers or {}) do
		if entry.userId == player.UserId then
			return entry
		end
	end
	return nil
end

local function roundState()
	return snapshot and snapshot.state or S.Boot
end

local function amRacing()
	local me = myEntry()
	local state = roundState()
	return me ~= nil and not me.finished and (state == S.Preparing or state == S.Countdown or state == S.Racing)
end

local function raceRunning()
	local state = roundState()
	return state == S.Racing or state == S.Countdown
end

local function canSteer()
	if uiState ~= "Live" or not currentBall or currentBall.Anchored or spectate.active or ui:GetModal() then
		return false
	end
	if currentZone == ZONES.Hub then
		return true
	end
	if modes:IsInTrial() then
		return true -- B1 Time Trial (the server froze the marble during its countdown)
	end
	local me = myEntry()
	return roundState() == S.Racing and me ~= nil and not me.finished
end

local function canRecover()
	if uiState ~= "Live" or spectate.active or not currentBall then
		return false
	end
	if currentZone == ZONES.Hub then
		return true
	end
	if modes:IsInTrial() then
		return true -- B1: back to your last Time Trial checkpoint
	end
	local state = roundState()
	return state == S.Racing or state == S.Results
end

-- UIController layers: each ScreenGui shows only when the current screen / modal lists it.
ui:Register("Title", function() end) -- the title overlay is driven by the PLAY flow below
modes:RegisterLayers(ui) -- B1: "Modes" (lobby) and "TimeTrial"
-- B3: GARAGE / QUESTS / BOARDS modals
local hubMenus = maid:Give(HubMenusController.new({
	remotes = remote,
	toast = function(text, seconds)
		hud:Toast(text, seconds)
	end,
}))
hubMenus:RegisterLayers(ui)
-- C: Capsule Lab (free capsule / Shard Shop / free season)
local lab = maid:Give(LabController.new({
	remotes = remote,
	toast = function(text, seconds)
		hud:Toast(text, seconds)
	end,
}))
lab:RegisterLayers(ui)
-- D: the optional shop (every product id nil = "Not on sale yet")
local shop = maid:Give(ShopController.new({
	remotes = remote,
	toast = function(text, seconds)
		hud:Toast(text, seconds)
	end,
}))
shop:RegisterLayers(ui)
maid:Give(hubMenus.EquippedChanged:Connect(function(equipped)
	social:SetEmotes(equipped.emotes) -- B3: the three equipped emotes on the emote row
	lab:SetOwned(hubMenus.cosmetics.ownedList) -- C: Shard Shop marks owned items
end))
ui:Register("Hud", function(visible)
	hud:SetHudVisible(visible)
end)
ui:Register("RaceHud", function(visible)
	raceHud:SetVisible(visible)
end)
ui:Register("Lobby", function(visible)
	matchUi:SetLobbyVisible(visible)
end)
ui:Register("Spectate", function(visible)
	matchUi:SetSpectateVisible(visible)
end)
ui:Register("Results", function(visible)
	results:SetVisible(visible)
end)
ui:Register("Settings", function(visible)
	settings:SetVisible(visible)
end)
ui:Register("Loadout", function(visible)
	loadout:SetVisible(visible)
end)
ui:Register("Touch", function(visible)
	touch:SetVisible(visible and input.device == InputController.Devices.Touch)
end)
ui:Register("Social", function(visible)
	social:SetVisible(visible)
end)
ui:Register("AbilitiesRace", function(visible)
	local me = myEntry()
	local live = visible and roundState() == S.Racing and me ~= nil and not me.finished and currentZone == ZONES.Race
	-- B2 try-it: after TRY in the ability menu, the two buttons work in the hub on yourself
	local practice = not live and visible and currentZone == ZONES.Hub and abilities:HasPractice()
	abilities:SetMode((live or practice) and "Race" or "Hidden", input.device, practice)
end)

local function refreshGates()
	local me = myEntry()
	ui:Refresh({
		started = uiState == "Live",
		spectating = spectate.active,
		timeTrial = modes:IsInTrial(), -- B1
		roundState = roundState(),
		inRace = me ~= nil,
		resultsDismissed = snapshot ~= nil and resultsDismissedRound == snapshot.roundId,
	})
	input:SetSteeringEnabled(canSteer())
	input:SetRecoverEnabled(canRecover())
	-- A6 social: voters = anyone who is not an active racer; emote bar in lobby / spectate
	local screen = ui:GetScreen()
	touch:SetLobbyMode(screen == "Lobby")
	local activeRacer = me ~= nil and not me.finished and roundState() == S.Racing
	social:SetContext(not activeRacer, (screen == "Lobby" or screen == "Spectate") and not ui:GetModal(), uiState == "Live" and not ui:GetModal())
	-- A6 console: give the gamepad a focused button on menus, never during the race
	if input.device == InputController.Devices.Gamepad then
		local modal = ui:GetModal()
		local target = nil
		if modal == "Settings" then
			target = settings:GetFirstButton()
		elseif modal == "Loadout" then
			target = loadout:GetFirstButton()
		elseif screen == "Results" then
			target = results:GetPrimaryButton()
		end
		if GuiService.SelectedObject ~= target and (target or GuiService.SelectedObject) then
			pcall(function()
				GuiService.SelectedObject = target
			end)
		end
	end
end

local resetLimiter = Utility.RateLimiter.new(GameConfig.Spawn.ClientResetThrottleSeconds)
local function requestRecover()
	if canRecover() and resetLimiter:Try("recover") then
		remote.RequestRecover:FireServer()
	end
end

---------------------------------------------------------------------------------------------
-- Spectating (client view only; never affects the race)
---------------------------------------------------------------------------------------------
local function spectateCandidates()
	local ids = {}
	if not snapshot then
		return ids
	end
	for _, entry in ipairs(snapshot.racers or {}) do
		if entry.userId ~= player.UserId then -- A4: bots can be spectated too
			ids[#ids + 1] = entry.userId
		end
	end
	return ids
end

local function bindCameraToOwn()
	if currentBall and currentBall.Parent then
		cameraController:Bind(currentBall, layouts[currentZone].Route, cameraIgnore)
	end
end

local function stopSpectating()
	if spectate.active then
		spectate.active = false
		spectate.userId, spectate.ball = nil, nil
		bindCameraToOwn()
		refreshGates()
	end
end

local function spectateUser(userId)
	local ball = marblesFolder:FindFirstChild(Protocol.MarbleName(userId))
	if not ball then
		return false
	end
	spectate.active = true
	spectate.userId = userId
	spectate.ball = ball
	spectate.tracker:Reset()
	cameraController:Bind(ball, layouts[ZONES.Race].Route, cameraIgnore)
	speedFeel:ClearAll() -- a new camera target: no ribbons carried over
	refreshGates()
	return true
end

local function cycleSpectate(direction)
	local ids = spectateCandidates()
	if #ids == 0 then
		stopSpectating()
		hud:Toast("Nobody to spectate right now", 1.5)
		return
	end
	local index = 0
	for i, id in ipairs(ids) do
		if id == spectate.userId then
			index = i
		end
	end
	for _ = 1, #ids do
		index = (index + direction - 1) % #ids + 1
		if spectateUser(ids[index]) then
			return
		end
	end
	stopSpectating()
end

local function toggleSpectate()
	if spectate.active then
		stopSpectating()
	elseif raceRunning() and not amRacing() then
		cycleSpectate(1)
	end
end

---------------------------------------------------------------------------------------------
-- Own marble binding (every spawn is a new Part; its Zone attribute picks the route)
---------------------------------------------------------------------------------------------
local myMarbleName = Protocol.MarbleName(player.UserId)

local lostBallAt = nil -- baseline audit: respawn time shown on the perf overlay

local function bindBall(ball)
	if currentBall == ball then
		return
	end
	if lostBallAt then
		hud:NoteRespawn(os.clock() - lostBallAt)
		lostBallAt = nil
	end
	currentBall = ball
	currentZone = ball:GetAttribute(BALL.Zone) or ZONES.Hub
	-- UI overhaul: your own marble keeps a thin outline so it never blends into the floor
	-- (local only; other players see nothing; one Highlight, far below the engine's limit)
	pcall(function()
		local outline = Instance.new("Highlight")
		outline.Name = "TC_SelfOutline"
		outline.FillTransparency = 1
		outline.OutlineColor = Color3.fromRGB(255, 244, 214)
		outline.OutlineTransparency = 0.25
		outline.DepthMode = Enum.HighlightDepthMode.Occluded
		outline.Adornee = ball
		outline.Parent = ball
	end)
	if currentZone == ZONES.Hub then
		local hubId = ball:GetAttribute(BALL.HubId)
		currentHubId = hubLayouts[hubId or ""] and hubId or MapRegistry.DefaultHubId
		layouts[ZONES.Hub] = hubLayouts[currentHubId]
	end
	tracker = RouteTracker.new(layouts[currentZone].Route)
	input:ResetState()
	motor:Bind(ball, groundIgnore)
	local plate = ball:FindFirstChild("Nameplate")
	if plate then
		plate.Enabled = false -- your own name never floats in front of the chase camera
	end
	local start = layouts[currentZone].Route
	steerForward = flatUnit(RouteTracker.TangentAtS(start, tracker:Update(ball.Position).s), Vector3.new(1, 0, 0))
	stuck.seconds = 0
	if not spectate.active then
		bindCameraToOwn()
	end
	refreshGates()
end

local function unbindBall(ball)
	if currentBall == ball then
		currentBall = nil
		lostBallAt = os.clock()
		motor:Unbind()
		if not spectate.active then
			cameraController:Unbind()
		end
		refreshGates()
	end
end

maid:Give(marblesFolder.ChildAdded:Connect(function(child)
	if child.Name == myMarbleName and child:IsA("BasePart") then
		bindBall(child)
	elseif spectate.active and child.Name == Protocol.MarbleName(spectate.userId or 0) then
		spectateUser(spectate.userId) -- spectated racer respawned
	end
end))
maid:Give(marblesFolder.ChildRemoved:Connect(function(child)
	unbindBall(child)
end))
local existingBall = marblesFolder:FindFirstChild(myMarbleName)
if existingBall then
	bindBall(existingBall)
end

maid:Give(player:GetAttributeChangedSignal(ATTR.SpawnCount):Connect(function()
	local reason = player:GetAttribute(ATTR.LastSpawnReason)
	if reason == REASONS.Fell or reason == REASONS.Lost then
		hud:Toast(currentZone == ZONES.Race and "Fell off - back to your last checkpoint" or "Fell off - back to the hub", 2)
		sound:Play("Respawn")
	elseif reason == REASONS.Movement then
		hud:Toast("Position corrected", 1.5)
	elseif reason == REASONS.Reset and uiState == "Live" then
		hud:Toast("Recovered", 1)
		sound:Play("Respawn")
	end
end))

---------------------------------------------------------------------------------------------
-- Round snapshots and server notices
---------------------------------------------------------------------------------------------
local lastState = nil
maid:Give(modes.Changed:Connect(function()
	refreshGates() -- B1: Time Trial started / ended changes the screen
end))

-- B1: the server switched the Race zone to another world (between races)
local function setWorld(worldId)
	local layout = worldLayouts[worldId]
	if not layout or worldId == activeWorldId then
		return
	end
	activeWorldId = worldId
	layouts[ZONES.Race] = layout
	local old = hazards
	hazards = HazardController.new(course:FindFirstChild(worldId) or course, motor, sound, layout)
	hazards:SetShieldQuery(function()
		return abilities:IsShielded()
	end)
	hazards:SetReducedMotion(reducedMotion)
	hazards:SetModifier(social.modifier)
	old:Destroy()
	trickZones = layout.TrickZones or {}
	spectate.tracker = RouteTracker.new(layout.Route)
	setCheckpointMarks(layout)
end

maid:Give(remote.RoundSnapshot.OnClientEvent:Connect(function(snap)
	if type(snap) ~= "table" or snap.v ~= RoundProtocol.Version then
		return
	end
	snapshot = snap
	if snap.worldId then
		setWorld(snap.worldId)
	end
	hazards:SetRound(snap.hazardSeed, snap.hazardEpoch)
	local mod = snap.chaosModifier
	if (mod and mod.startsAt) ~= (social.modifier and social.modifier.startsAt) then
		social:SetModifier(mod) -- late joiners get the active vote modifier from the snapshot
	end
	raceHud:ApplySnapshot(snap, player.UserId)
	matchUi:ApplySnapshot(snap, player.UserId)
	modes:ApplySnapshot(snap)
	mapSelect:ApplySnapshot(snap)
	results:ApplySnapshot(snap, player.UserId)
	raceIntro:OnSnapshot(snap)
	finishedMarbles = {}
	for _, entry in ipairs(snap.racers or {}) do
		if entry.finished then
			finishedMarbles[Protocol.MarbleName(entry.userId)] = true -- trails clear at the finish
		end
	end
	if snap.state ~= lastState then
		if snap.state == S.Racing and myEntry() then
			sound:Play("RunStart")
		end
		if snap.state ~= S.Racing and snap.state ~= S.Countdown then
			stopSpectating()
		end
		lastState = snap.state
	end
	if spectate.active then
		local stillRacing = false
		for _, id in ipairs(spectateCandidates()) do
			if id == spectate.userId then
				stillRacing = true
			end
		end
		if not stillRacing then
			cycleSpectate(1)
		end
	end
	refreshGates()
end))
maid:Give(remote.CheckpointFeedback.OnClientEvent:Connect(function(data)
	if type(data) == "table" and type(data.index) == "number" and type(data.total) == "number" then
		raceHud:FlashCheckpoint(data.index, data.total)
		sound:Play("Checkpoint")
	end
end))
maid:Give(remote.FinishNotice.OnClientEvent:Connect(function(data)
	if type(data) ~= "table" or type(data.place) ~= "number" then
		return
	end
	if data.userId == player.UserId then
		raceHud:Flash(string.format("FINISHED  #%d", data.place), GameConfig.Palette.Mint, 2.5)
		sound:Play("Finish")
		if currentBall and currentBall.Parent then
			vfx:Confetti(currentBall.Position + Vector3.new(0, 2, 0), currentBall:GetAttribute("TC_Burst")) -- every finisher gets one (B3: their equipped burst)
		end
	else
		hud:Toast(string.format("%s%s finished #%d", data.isBot and "[BOT] " or "", tostring(data.name), data.place), 2)
	end
end))
maid:Give(remote.ChaosGateVFX.OnClientEvent:Connect(function(data)
	if type(data) ~= "table" or type(data.label) ~= "string" then
		return
	end
	vfx:ChaosSurge(data.userId, data.tier)
	if data.userId == player.UserId then
		raceHud:Flash("CHAOS GATE  " .. data.label, data.tier == "Bottom" and GameConfig.Palette.Mint or GameConfig.Palette.Violet, 1.6)
		sound:Play("Checkpoint")
	end
end))
-- A5 profile + rewards (server truth)
local profileState = nil
maid:Give(remote.ProfileState.OnClientEvent:Connect(function(p)
	if type(p) ~= "table" then
		return
	end
	profileState = p
	matchUi:ApplyProfile(p)
	loadout:SetProfile(p.level, p.coins) -- B2: unlock buttons know your level and Coins
	results:ApplyProfile(p)
	settings:ApplyServer(p.settings)
end))
maid:Give(remote.RewardNotice.OnClientEvent:Connect(function(notice)
	if type(notice) == "table" and type(notice.coins) == "number" then
		results:ApplyNotice(notice)
		if notice.levelUp then
			raceHud:Flash(string.format("LEVEL UP!  LEVEL %d", notice.level), GameConfig.Palette.Violet, 2.5)
		end
	end
end))
maid:Give(abilities.StateReceived:Connect(function(state)
	if type(state.loadout) == "table" then
		loadout:ApplyServer(state.loadout, state)
		refreshGates() -- B2: practice buttons appear / disappear
		local AbilityConfig = require(Shared:WaitForChild("AbilityConfig"))
		local a, b = AbilityConfig.Abilities[state.loadout[1]], AbilityConfig.Abilities[state.loadout[2]]
		matchUi:SetLoadoutText((a and a.DisplayName or "?") .. " + " .. (b and b.DisplayName or "?"))
	end
end))

-- Settings -> live effects (applied at once; saved through RequestSettings)
local function applyGraphics(mode)
	local low = mode == "Low" or (mode == "Auto" and input.device == InputController.Devices.Touch)
	local bloom = Lighting:FindFirstChild("TC_Bloom")
	if bloom then
		bloom.Enabled = not low
	end
	vfx:SetQuality(low and "Low" or "High")
	speedFeel:SetQuality(low and "Low" or (mode == "High" and "High" or "Standard"))
end
-- the map whose accent "Follow map" uses: your hub's map in a hub, the race map on the course
local function accentMapId()
	if currentZone == ZONES.Hub then
		local hub = MapRegistry.RawHub(currentHubId)
		return hub and hub.Map or MapRegistry.DefaultMapId
	end
	return activeWorldId
end
local function applyDisplay(s)
	local style = UIKit.StyleFromSettings(s, accentMapId())
	UIKit.ApplyStyle(style)
	touch:SetLayout(s.controlLayout, style.scale)
	abilities:SetLayout(s.controlLayout, s.hudDensity)
	raceHud:SetDensity(s.hudDensity)
	matchUi:SetDensity(s.hudDensity)
	hud:SetDensity(s.hudDensity)
	hud:SetPerfVisible(s.perfOverlay == true and isDeveloper())
	environment:SetDetail(s.sceneryDetail) -- Low / Standard / High backdrop layers
end
local function applySettings(s)
	applyDisplay(s) -- UI overhaul: HUD size / opacity / accent / contrast / layout / density
	social:SetMuted(s.muteEmotes == true)
	abilities:SetReducedMotion(s.reducedMotion == true)
	results:SetReducedMotion(s.reducedMotion == true)
	lab:SetReducedMotion(s.reducedMotion == true) -- C: instant capsule reveal
	UIKit.SetReducedMotion(s.reducedMotion == true) -- menu / HUD entrances and punches
	raceIntro:SetReducedMotion(s.reducedMotion == true) -- the launch intro goes straight to the grid
	raceIntro:SetSkip(s.introSkip == true)
	speedFeel:SetReducedMotion(s.reducedMotion == true)
	speedFeel:SetVisibility(s.trailVisibility)
	speedFeel:SetSpeedEffects(s.speedEffects ~= false)
	speedEffectsOn = s.speedEffects ~= false
	if cameraController:GetMode() ~= s.cameraMode then
		hud:SetCameraMode(cameraController:SetMode(s.cameraMode))
	end
	input:SetSensitivity(s.sensitivity)
	sound:SetVolumes(s.music, s.sfx)
	applyGraphics(s.graphicsMode)
end
loadStage = "applying settings"
maid:Give(settings.Changed:Connect(applySettings))
applySettings(settings:Get())

-- Modals
local function openModal(name)
	if not ui:OpenModal(name) then
		hud:Toast(name == "Loadout" and "Change abilities in the hub or on the results screen" or "Not now", 1.6)
	end
	refreshGates()
end
maid:Give(matchUi.LoadoutRequested:Connect(function()
	openModal("Loadout")
end))
maid:Give(matchUi.SettingsRequested:Connect(function()
	openModal("Settings")
end))
maid:Give(matchUi.GarageRequested:Connect(function()
	openModal("Garage")
end))
maid:Give(matchUi.QuestsRequested:Connect(function()
	openModal("Quests")
end))
maid:Give(matchUi.BoardsRequested:Connect(function()
	openModal("Boards")
end))
maid:Give(matchUi.LabRequested:Connect(function(tab)
	lab.tab = tab
	openModal("Lab")
end))
maid:Give(lab.CloseRequested:Connect(function()
	ui:CloseModal()
	refreshGates()
end))
maid:Give(matchUi.ShopRequested:Connect(function()
	openModal("Shop")
end))
maid:Give(shop.CloseRequested:Connect(function()
	ui:CloseModal()
	refreshGates()
end))
maid:Give(hubMenus.CloseRequested:Connect(function()
	ui:CloseModal()
	refreshGates()
end))
maid:Give(modes.MapsRequested:Connect(function()
	openModal("MapSelect")
end))
maid:Give(matchUi.MapsRequested:Connect(function()
	openModal("MapSelect")
end))
-- EXIT PRACTICE: back to your hub's spawn ring (the same Visit request Map Selection uses)
maid:Give(matchUi.PracticeExitRequested:Connect(function()
	for i, entry in ipairs(MapRegistry.Hubs) do
		if entry.Id == currentHubId then
			remote.RequestDestination:FireServer(i, 1)
		end
	end
end))
maid:Give(mapSelect.CloseRequested:Connect(function()
	if ui:GetModal() == "MapSelect" then
		ui:CloseModal()
		refreshGates()
	end
end))
maid:Give(abilities.LoadoutRequested:Connect(function()
	openModal("Loadout")
end))
maid:Give(results.LoadoutRequested:Connect(function()
	openModal("Loadout")
end))
maid:Give(results.SettingsRequested:Connect(function()
	openModal("Settings")
end))
maid:Give(settings.CloseRequested:Connect(function()
	ui:CloseModal()
	refreshGates()
end))
maid:Give(loadout.CloseRequested:Connect(function()
	ui:CloseModal()
	refreshGates()
end))
maid:Give(results.Dismissed:Connect(function()
	if snapshot then
		resultsDismissedRound = snapshot.roundId
	end
	refreshGates()
end))

remote.RequestSnapshot:FireServer()

---------------------------------------------------------------------------------------------
-- UI flow
---------------------------------------------------------------------------------------------
local function startPlaying()
	if uiState ~= "Title" then
		return
	end
	sound:Play("UIClick")
	uiState = "Live"
	hud:HideOverlay()
	if not tutorial.done then
		tutorial.active = true
		tutorial.left, tutorial.right = 0, 0
		hud:ShowTutorial()
	end
	refreshGates()
end

local function finishTutorial(message)
	tutorial.active = false
	tutorial.done = true
	if message then
		hud:Toast(message, 1.5)
		task.delay(0.8, function()
			hud:HideTutorial()
		end)
	else
		hud:HideTutorial()
	end
end

local function requestJoin(wants)
	remote.RequestJoinRace:FireServer(wants == true)
	sound:Play("UIClick")
	hud:Toast(wants and "You're in the next race" or "You'll sit out the next race", 1.5)
end

maid:Give(hud.PlayPressed:Connect(startPlaying))
maid:Give(hud.TutorialSkipped:Connect(function()
	finishTutorial(nil)
end))
maid:Give(input.PrimaryActionRequested:Connect(function()
	if hud:GetOverlay() == "Title" then
		startPlaying()
	elseif ui:GetScreen() == "Results" and not ui:GetModal() then
		requestJoin(true)
		if snapshot then
			resultsDismissedRound = snapshot.roundId
		end
		refreshGates()
	end
end))
maid:Give(input.RecoverTriggered:Connect(requestRecover))
maid:Give(matchUi.JoinRequested:Connect(requestJoin))
maid:Give(matchUi.ReadyRequested:Connect(function(ready)
	remote.RequestReady:FireServer(ready == true)
	sound:Play("UIClick")
end))
maid:Give(results.JoinRequested:Connect(requestJoin))
maid:Give(matchUi.SpectateToggled:Connect(toggleSpectate))
maid:Give(matchUi.SpectateCycle:Connect(function(direction)
	if spectate.active then
		cycleSpectate(direction)
	end
end))
maid:Give(input.SpectateCycleRequested:Connect(function(direction)
	if spectate.active then
		cycleSpectate(direction)
	end
end))
maid:Give(input.AbilityRequested:Connect(function(slot)
	if not spectate.active then
		abilities:RequestAbility(slot)
	end
end))
maid:Give(input.TrickRequested:Connect(function()
	if not spectate.active and hud:GetOverlay() ~= "Title" then
		abilities:RequestTrick()
	end
end))
maid:Give(input.ScoreboardToggleRequested:Connect(function()
	raceHud:ToggleStandings()
end))

local function toggleCamera()
	local mode = cameraController:ToggleMode()
	hud:SetCameraMode(mode)
	hud:Toast("Camera: " .. mode, 1)
	settings:SetLocal("cameraMode", mode) -- remembered in your profile
end
maid:Give(input.CameraToggleRequested:Connect(toggleCamera))
maid:Give(hud.CameraPressed:Connect(toggleCamera))
maid:Give(input.PerfToggleRequested:Connect(function()
	hud:TogglePerf()
end))
maid:Give(input.DeviceChanged:Connect(function(device)
	hud:SetDevice(device)
	applyGraphics(settings:Get().graphicsMode)
	refreshGates()
end))
hud:SetCameraMode(cameraController:GetMode())

task.spawn(function()
	local bindable = Instance.new("BindableEvent")
	maid:Give(bindable)
	maid:Give(bindable.Event:Connect(requestRecover))
	for _ = 1, 10 do
		local ok = pcall(function()
			StarterGui:SetCore("ResetButtonCallback", bindable)
		end)
		if ok then
			return
		end
		task.wait(1)
	end
	warn("[TumbleCircuit] could not hook the Roblox menu Reset button; R / Y / RESET still work")
end)

---------------------------------------------------------------------------------------------
-- Frame loop
---------------------------------------------------------------------------------------------
local RENDER_STEP = "TumbleCircuitClient"
local reportedRound = nil -- A5 AFK guard: one ReportActive per race, on the first real input
local rivalTrackers = {}
local rivalWorld = nil
local rivalTimer = 0
local rivalFractions = {}
local steerRequired = GameConfig.Tutorial.SteerSecondsRequired
local hitchThreshold = GameConfig.Debug.HitchThresholdSeconds
local clientStart = os.clock()
local boardTimer = 0
local lastAnchored = nil

---------------------------------------------------------------------------------------------
-- Prompt 04: per-hub practice hazards, per-zone visual profiles, MAPS selector pads
---------------------------------------------------------------------------------------------
-- Practice-lane hazards (Balloon Terminal drum, Basalt piston) run on the client exactly like
-- the course's (HazardSim from a fixed seed and server time), only for the hub you are in.
local hubHazards = {}
local function hubHazardsFor(hubId)
	local cached = hubHazards[hubId or ""]
	if cached ~= nil then
		return cached or nil
	end
	local entry = MapRegistry.RawHub(hubId)
	local layout = hubLayouts[hubId or ""]
	local model = entry and workspace:FindFirstChild(entry.ModelName)
	local chuteRoot = model and model:FindFirstChild("PracticeChute")
	if layout and chuteRoot and #(layout.Hazards or {}) > 0 then
		local controller = HazardController.new(chuteRoot, motor, sound, layout)
		controller:SetShieldQuery(function()
			return abilities:IsShielded()
		end)
		controller:SetReducedMotion(reducedMotion)
		controller:SetRound(0, 0)
		hubHazards[hubId] = controller
		maid:Give(function()
			controller:Destroy()
		end)
		return controller
	end
	hubHazards[hubId or ""] = false
	return nil
end

-- Visual profile of the zone you are in, applied to YOUR Lighting only (never the server's, so
-- another player's hub or race never changes yours). Every profile writes every field, so
-- leaving a zone unwinds the previous one completely (atmosphere included).
local appliedProfile = nil
local function zoneAtmosphere()
	local atmosphere = Lighting:FindFirstChild("TC_Atmosphere")
	if not atmosphere then
		atmosphere = Instance.new("Atmosphere") -- local to this client
		atmosphere.Name = "TC_Atmosphere"
		atmosphere.Parent = Lighting
	end
	return atmosphere
end
local environmentKey = nil
local function applyZoneProfile()
	-- UI / environment overhaul: every player gets the zone's lighting (no longer gated)
	local name = VisualProfiles.Default
	local hub = MapRegistry.RawHub(currentHubId) or defaultHub
	if currentZone == ZONES.Hub then
		name = hub.Profile or name
	else
		local map = MapRegistry.RawMap(activeWorldId)
		name = map and map.Profile or name
	end
	-- backdrops: the race map in play + your hub's map; staging for your hub
	local key = tostring(activeWorldId) .. "|" .. tostring(hub.Map) .. "|" .. tostring(hub.Id)
	if key ~= environmentKey then
		environmentKey = key
		environment:SetMaps({ activeWorldId, hub.Map })
		environment:SetHub(hub.Id)
	end
	if name == appliedProfile then
		return
	end
	local profile, fellBack = VisualProfiles.Get(name)
	if fellBack then
		warn("[Visual] profile " .. tostring(name) .. " missing; using " .. VisualProfiles.Default)
	end
	local ok, err = pcall(function()
		VisualProfiles.Apply(Lighting, profile, { bloom = Lighting:FindFirstChild("TC_Bloom"), grade = Lighting:FindFirstChild("TC_Grade"), atmosphere = zoneAtmosphere() })
	end)
	if not ok then
		warn("[Visual] profile apply failed: " .. tostring(err)) -- the previous look stays; play goes on
	end
	appliedProfile = name
end
loadStage = "dressing the hub"
pcall(function()
	environment:Restyle() -- road midtones, narrow guide lights, practice lanes (once)
end)
maid:Give(player:GetAttributeChangedSignal(Protocol.PlayerAttributes.Features):Connect(function()
	applyZoneProfile()
end))

-- MAPS selector pads (themed hubs): rolling onto one opens Map Selection once; leaving re-arms
local selectorPads = {}
for _, entry in ipairs(MapRegistry.Hubs) do
	local model = workspace:FindFirstChild(entry.ModelName)
	local decor = model and model:FindFirstChild("Decor")
	if decor then
		for _, part in ipairs(decor:GetChildren()) do
			if part:GetAttribute("TC_Selector") then
				selectorPads[#selectorPads + 1] = { part = part, radius = part:GetAttribute("Radius") or 3.5, hubId = entry.Id }
			end
		end
	end
end
local onPad = false
local function checkSelectorPads(position)
	if currentZone ~= ZONES.Hub then
		onPad = false
		return
	end
	local inside = false
	for _, list in ipairs({ selectorPads, environment:GetSelectorPads() }) do
		for _, pad in ipairs(list) do
			if pad.hubId == currentHubId and pad.part.Parent then
				local d = position - pad.part.Position
				if Vector3.new(d.X, 0, d.Z).Magnitude <= pad.radius and math.abs(d.Y) < 6 then
					inside = true
				end
			end
		end
	end
	if inside and not onPad and not ui:GetModal() then
		openModal("MapSelect")
	end
	onPad = inside
end

-- Hub platform free roam (owner playtest 2026-11-25): on the round platform there is no track, so
-- the track-relative steering and auto-align fought the player. On the platform the stick moves the
-- marble relative to the camera; on the practice chute (and the race) steering follows the track.
local function hubDef()
	local entry = MapRegistry.RawHub(currentHubId) or defaultHub
	return entry.Geometry
end
local function onHubPlatform(position)
	if currentZone ~= ZONES.Hub then
		return false
	end
	local def = hubDef()
	local offset = position - def.Center
	return Vector3.new(offset.X, 0, offset.Z).Magnitude <= def.Radius + 1 and math.abs(offset.Y) < 12
end

-- Where the marble is, for the hitch log: zone + course piece under route segment i
-- (segment i runs from section i to i + 1).
local function whereLabel(zone, index)
	local zoneLayout = layouts[zone]
	local section = zoneLayout and (zoneLayout.Sections[index + 1] or zoneLayout.Sections[index])
	local piece = section and zoneLayout.Pieces[section.PieceIndex]
	return string.format("@%s/%s", tostring(zone), piece and piece.Name or "?")
end

loadStage = "starting"
local lastAccentMap, lastHubName = nil, nil
local airborneSince = nil -- landing cue
RunService:BindToRenderStep(RENDER_STEP, Enum.RenderPriority.Camera.Value + 1, function(dt)
	applyZoneProfile()
	-- UI overhaul: "Follow map" accent + hub name on the card follow where you are
	local accentMap = accentMapId()
	if accentMap ~= lastAccentMap then
		lastAccentMap = accentMap
		applyDisplay(settings:Get())
		raceHud:SetCourseName((MapRegistry.RawMap(activeWorldId) or {}).Meta and MapRegistry.RawMap(activeWorldId).Meta.DisplayName or nil)
	end
	if currentHubId ~= lastHubName then
		lastHubName = currentHubId
		matchUi:SetHubName((MapRegistry.RawHub(currentHubId) or defaultHub).Meta.DisplayName)
	end -- prompt 04: no-op unless your zone / hub / race map changed
	hud:RecordFrame(dt)
	modes:Step(workspace:GetServerTimeNow()) -- B1: Time Trial timer + PB ghost
	local ball = currentBall
	if ball and ball.Anchored ~= lastAnchored then
		lastAnchored = ball.Anchored -- released at GO
		refreshGates()
	end
	input:Update(dt)

	local progressS = 0
	local speed = 0
	local state = roundState()
	local me = myEntry()
	local where = "no marble"
	if ball and ball.Parent then
		local info = tracker:Update(ball.Position)
		progressS = info.s
		speed = ball.AssemblyLinearVelocity.Magnitude
		where = whereLabel(currentZone, info.index)

		local freeRoam = onHubPlatform(ball.Position) and not spectate.active
		cameraController:SetFreeRoam(freeRoam)
		local route = layouts[currentZone].Route
		local target
		if freeRoam then
			target = cameraController:GetFlatForward() -- stick up = away from the camera
		else
			target = RouteTracker.SmoothHorizontalTangentAtS(
				route,
				progressS + PhysicsConfig.Movement.SteerFrameLookAhead,
				PhysicsConfig.Movement.SteerFrameSmoothingStuds
			)
		end
		if target then
			if freeRoam then
				steerForward = flatUnit(target, steerForward) -- follows the view exactly
			else
				local turned = Utility.turnToward(steerForward, target, Utility.expAlpha(PhysicsConfig.Movement.SteerFrameResponse, dt))
				steerForward = flatUnit(turned, steerForward)
			end
		end

		local mode = MODES.Idle
		if currentZone == ZONES.Race and ((me and me.finished) or state == S.Results) then
			mode = MODES.Finished
		elseif input.steeringEnabled then
			mode = MODES.Play
		end
		motor:Step(dt, {
			mode = mode,
			steer = input.steer,
			brake = input.brake,
			brakePressed = input.brakePressed,
			forwardH = steerForward,
			freeRoam = freeRoam,
		})
		if currentZone == ZONES.Race then
			hazards:Step(ball)
			matchUi:SetPractice(nil)
		else
			hazards:Step(nil) -- keep the bumper's colours in sync while away
			local practiceHazards = hubHazardsFor(currentHubId) -- prompt 04
			if practiceHazards then
				practiceHazards:Step(ball)
			end
			checkSelectorPads(ball.Position)
			-- UI overhaul: off the deck = on the practice lane -> objective + EXIT PRACTICE
			local hubEntry = MapRegistry.RawHub(currentHubId)
			matchUi:SetPractice((not onHubPlatform(ball.Position)) and hubEntry and hubEntry.Meta.PracticeObjective or nil)
		end

		-- Stuck hint: racing, trying to move, slow, and no route progress for a while.
		local trying = input.steeringEnabled and (math.abs(input.steer.X) > 0.3 or input.steer.Y > 0.3) and not input.brake
		local racingNow = currentZone == ZONES.Race and state == S.Racing and me and not me.finished
		if racingNow and snapshot and reportedRound ~= snapshot.roundId and (math.abs(input.steer.X) > 0.3 or math.abs(input.steer.Y) > 0.3 or input.brake) then
			reportedRound = snapshot.roundId
			remote.ReportActive:FireServer(snapshot.roundId)
		end
		if racingNow and trying and speed < RaceConfig.Recovery.StuckMaxSpeed then
			if stuck.seconds == 0 then
				stuck.startS = progressS
			end
			stuck.seconds = stuck.seconds + dt
		else
			stuck.seconds = 0
		end
		stuck.shown = stuck.seconds >= RaceConfig.Recovery.StuckSeconds and progressS - stuck.startS < RaceConfig.Recovery.StuckMinProgress

		if tutorial.active then
			if input.steer.X < -0.3 then
				tutorial.left = tutorial.left + dt
			elseif input.steer.X > 0.3 then
				tutorial.right = tutorial.right + dt
			end
			local leftDone, rightDone = tutorial.left >= steerRequired, tutorial.right >= steerRequired
			hud:UpdateTutorial(leftDone, rightDone)
			if leftDone and rightDone then
				finishTutorial("Nice steering!")
			end
		end
	end

	if dt >= hitchThreshold then
		hud:RecordHitch(dt, where)
		warn(string.format("[TumbleCircuit] hitch %.2f s %s, %.0f s after join", dt, where, os.clock() - clientStart))
	end

	-- Camera: own marble, or the spectated racer (with its own progress tracker).
	local cameraS = progressS
	local spectatingName = nil
	if spectate.active then
		local target = spectate.ball
		if target and target.Parent then
			cameraS = spectate.tracker:Update(target.Position).s
			for _, entry in ipairs(snapshot and snapshot.racers or {}) do
				if entry.userId == spectate.userId then
					spectatingName = entry.name
				end
			end
		end
	end
	local multiplier = motor:GetSpeedMultiplier()
	-- speed feel (2026-11-26): up to +8 deg FOV near top speed (off: Reduced Motion / setting)
	local speedFraction = speed / MotionFeel.ReferenceSpeed
	local kick = speedEffectsOn and MotionFeel.FovKick(speedFraction, reducedMotion) or 0
	cameraController:SetFovTarget(reducedMotion and GameConfig.Camera.FieldOfView or GameConfig.Camera.FieldOfView + (multiplier - 1) * 40 + kick)
	freeLook:Update(dt)
	raceIntro:Step() -- stand-in poses first: the scripted intro shot follows the pack
	cameraController:Step(dt, cameraS)
	speedFeel:Step(dt, { camera = workspace.CurrentCamera, braking = input.brake == true, finished = finishedMarbles })
	if ball and ball.Parent then
		local grounded = motor:IsGrounded()
		sound:SetRoll(speedFraction, grounded)
		if grounded and airborneSince and os.clock() - airborneSince > 0.35 then
			sound:Play("Land") -- a real landing after a jump or drop
		end
		airborneSince = (not grounded) and (airborneSince or os.clock()) or nil
	else
		sound:SetRoll(0, false)
	end
	abilities:Update()
	vfx:Step()
	if currentZone == ZONES.Race and state == S.Racing and me and not me.finished then
		abilities:ShowHint("ability", "ABILITIES: " .. (input.device == "Gamepad" and "LB / RB" or input.device == "Touch" and "the two round buttons" or "Q / E") .. " - your loadout is set in the hub.")
		for _, zone in ipairs(trickZones) do
			if progressS > zone.LipS - 70 and progressS < zone.LipS - 15 then
				abilities:ShowHint("trick", "TRICK RAMP ahead (green, left side): jump it and press " .. (input.device == "Gamepad" and "(A)" or input.device == "Touch" and "TRICK" or "SPACE") .. " in the air for +15% speed.")
			end
		end
	end

	touch:SetRecoverProgress(input.recoverProgress)
	hud:Update({ speed = speed, recoverProgress = input.recoverProgress })
	local now = workspace:GetServerTimeNow()
	local queued = snapshot and snapshot.queued and snapshot.queued[tostring(player.UserId)] == true
	local raceTotal = layouts[ZONES.Race].Route.total
	local progressFraction = currentZone == ZONES.Race and progressS / raceTotal or nil
	-- rivals on the progress bar: tracked locally from their replicated marbles (no network)
	rivalTimer = rivalTimer + dt
	if rivalTimer >= 0.1 and progressFraction and snapshot then
		rivalTimer = 0
		local seen = {}
		rivalFractions = {}
		for _, entry in ipairs(snapshot.racers or {}) do
			if entry.userId ~= player.UserId and not entry.finished then
				local ball = marblesFolder:FindFirstChild(Protocol.MarbleName(entry.userId))
				if ball and ball:GetAttribute(BALL.Zone) == ZONES.Race then
					if rivalWorld ~= activeWorldId then
						rivalTrackers, rivalWorld = {}, activeWorldId -- B1: new world, new routes
					end
					local t = rivalTrackers[entry.userId] or RouteTracker.new(layouts[ZONES.Race].Route)
					rivalTrackers[entry.userId] = t
					seen[entry.userId] = true
					rivalFractions[#rivalFractions + 1] = t:Update(ball.Position).s / raceTotal
				end
			end
		end
		for id in pairs(rivalTrackers) do
			if not seen[id] then
				rivalTrackers[id] = nil
			end
		end
	end
	raceHud:Update({ now = now, device = input.device, queued = queued, spectatingName = spectatingName, stuck = stuck.shown, progress = progressFraction, rivals = rivalFractions })
	results:Update(now)
	social:Update(now)
	matchUi:Update({ now = now, racing = amRacing(), raceRunning = raceRunning(), spectating = spectate.active })
	mapSelect:SetRacing(amRacing()) -- prompt 03: Visit / Practice wait until after your race
	boardTimer = boardTimer + dt
	if boardTimer >= 0.25 then
		boardTimer = 0
		for _, board in ipairs(boards) do
			matchUi:UpdateBoard(board, { now = now })
		end
	end
end)
maid:Give(function()
	RunService:UnbindFromRenderStep(RENDER_STEP)
end)

script.Destroying:Connect(function()
	maid:Cleanup()
end)

loadStage = "ready"
hud:ShowTitle()
refreshGates()
print("[TumbleCircuit] client ready (" .. GameConfig.Version .. ")")
