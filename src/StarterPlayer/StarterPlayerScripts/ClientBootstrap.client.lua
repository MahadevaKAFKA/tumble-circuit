--[[
	ClientBootstrap — wires the A2 client.

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
local Utility = require(Shared:WaitForChild("Utility"))
local PlaceholderIds = require(Shared:WaitForChild("PlaceholderIds"))

local InputController = require(Controllers:WaitForChild("InputController"))
local TouchControls = require(Controllers:WaitForChild("TouchControls"))
local MarbleMotorController = require(Shared:WaitForChild("MarbleMotorController")) -- shared with server bots (A4)
local CameraController = require(Controllers:WaitForChild("CameraController"))
local HazardController = require(Controllers:WaitForChild("HazardController"))
local HUD = require(Controllers:WaitForChild("PrototypeHUDController"))
local RaceHUD = require(Controllers:WaitForChild("RaceHUDController"))
local MatchUI = require(Controllers:WaitForChild("MatchUIController"))
local SoundController = require(Controllers:WaitForChild("SoundController"))
local AbilityController = require(Controllers:WaitForChild("AbilityController"))
local VFXController = require(Controllers:WaitForChild("VFXController"))

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
local raceHud = maid:Give(RaceHUD.new())
local matchUi = maid:Give(MatchUI.new())
raceHud:SetVisible(false)
matchUi:SetVisible(false)

hud:ShowMessage("Building the Orbital Garage and race track...")

---------------------------------------------------------------------------------------------
-- Wait (bounded) for the server
---------------------------------------------------------------------------------------------
local timeout = GameConfig.Spawn.ClientWaitTimeoutSeconds
local remotes = ReplicatedStorage:WaitForChild(RoundProtocol.FolderName, timeout)

local function waitForWorld()
	local deadline = os.clock() + timeout
	while os.clock() < deadline do
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

local course, hubRoot, worldError = waitForWorld()
local marblesFolder = course and workspace:WaitForChild(Protocol.MarblesFolderName, timeout)
local remote = {}
if remotes then
	for name in pairs(RoundProtocol.Remotes) do
		remote[name] = remotes:WaitForChild(name, 5)
	end
end
local remotesOk = remotes ~= nil and remotes:GetAttribute("ProtocolVersion") == RoundProtocol.Version
for name in pairs(RoundProtocol.Remotes) do
	if not remote[name] then
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
		for name in pairs(RoundProtocol.Remotes) do
			if not remote[name] then
				missing[#missing + 1] = name
			end
		end
		reason = "server remotes missing: " .. table.concat(missing, ", ")
	elseif not reason then
		reason = "the server did not finish starting (no marbles folder)"
	end
	hud:ShowMessage("Could not start: " .. tostring(reason) .. "\nOpen /console (Log, Server) for [TumbleCircuit] errors, then rejoin.", true)
	return
end
course:WaitForChild("Hazards", 5)
hubRoot:WaitForChild("PracticeChute", 5)

local layouts = {
	[ZONES.Race] = TrackDefinitions.Generate(TrackDefinitions.Race, PhysicsConfig.Ball.Radius), -- A4 Neon Foundry
	[ZONES.Hub] = TrackDefinitions.Generate(TrackDefinitions.PracticeChute, PhysicsConfig.Ball.Radius),
}
local hazards = HazardController.new(course, motor, sound, layouts[ZONES.Race])
motor:SetMarblesFolder(marblesFolder)
local currentZone -- declared early: the environment push below only applies on the race course
motor:SetEnvironmentAccel(function(position)
	if currentZone == ZONES.Race then
		return hazards:EnvironmentAccel(position)
	end
	return nil
end)
do
	local raceLayout = layouts[ZONES.Race]
	local total = raceLayout.Route.total
	local marks = {}
	for i, cp in ipairs(raceLayout.Checkpoints) do
		marks[i] = cp.S / total
	end
	raceHud:SetCheckpointMarks(marks)
end

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
hazards:SetShieldQuery(function()
	return abilities:IsShielded()
end)
local reducedMotion = false
maid:Give(abilities.OutcomeReceived:Connect(function(outcome)
	vfx:OnOutcome(outcome)
end))
maid:Give(abilities.TrickPressed:Connect(function()
	vfx:Trick(player.UserId)
end))
maid:Give(abilities.ReducedMotionChanged:Connect(function(value)
	reducedMotion = value
	vfx:SetReducedMotion(value)
	hazards:SetReducedMotion(value)
end))
maid:Give(remote.SkillEvent.OnClientEvent:Connect(function(data)
	if type(data) == "table" and (data.kind == "SlipstreamOn" or data.kind == "SlipstreamOff") then
		vfx:SetSlipstream(player.UserId, data.kind == "SlipstreamOn")
	end
end))
local trickZones = layouts[ZONES.Race].TrickZones or {}

local function present(list)
	local out = {}
	for _, item in pairs(list) do
		if item then
			out[#out + 1] = item
		end
	end
	return out
end
local chute = hubRoot:FindFirstChild("PracticeChute")
local cameraIgnore = present({
	marblesFolder,
	course:FindFirstChild("Rails"), course:FindFirstChild("Decor"), course:FindFirstChild("Hazards"), course:FindFirstChild("Gates"),
	hubRoot:FindFirstChild("Rails"), hubRoot:FindFirstChild("Decor"),
	chute and chute:FindFirstChild("Rails"), chute and chute:FindFirstChild("Decor"),
	course:FindFirstChild("Features"),
})
local groundIgnore = { marblesFolder }
local boardPart = hubRoot:FindFirstChild("Decor") and hubRoot.Decor:FindFirstChild("NextRaceBoard")
local board = boardPart and boardPart:FindFirstChild("Board")

local function flatUnit(v, fallback)
	return Utility.safeUnit(Vector3.new(v.X, 0, v.Z), fallback)
end

---------------------------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------------------------
local uiState = "Title" -- "Title" | "Live"
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
	if uiState ~= "Live" or not currentBall or currentBall.Anchored or spectate.active then
		return false
	end
	if currentZone == ZONES.Hub then
		return true
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
	local state = roundState()
	return state == S.Racing or state == S.Results
end

local function refreshGates()
	input:SetSteeringEnabled(canSteer())
	input:SetRecoverEnabled(canRecover())
	touch:SetVisible(input.device == InputController.Devices.Touch and uiState == "Live" and not spectate.active)
	hud:SetHudVisible(uiState == "Live")
	raceHud:SetVisible(uiState == "Live")
	matchUi:SetVisible(uiState == "Live")
	local abilityMode = "Hidden"
	if uiState == "Live" and not spectate.active then
		local me = myEntry()
		if roundState() == S.Racing and me and not me.finished and currentZone == ZONES.Race then
			abilityMode = "Race"
		elseif not amRacing() then
			abilityMode = "Hub"
		end
	end
	if abilities then
		abilities:SetMode(abilityMode, input.device)
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

local function bindBall(ball)
	if currentBall == ball then
		return
	end
	currentBall = ball
	currentZone = ball:GetAttribute(BALL.Zone) or ZONES.Hub
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
maid:Give(remote.RoundSnapshot.OnClientEvent:Connect(function(snap)
	if type(snap) ~= "table" or snap.v ~= RoundProtocol.Version then
		return
	end
	snapshot = snap
	hazards:SetRound(snap.hazardSeed, snap.hazardEpoch)
	raceHud:ApplySnapshot(snap, player.UserId)
	matchUi:ApplySnapshot(snap, player.UserId)
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
	elseif matchUi:IsResultsOpen() then
		requestJoin(true)
		matchUi:DismissResults()
	end
end))
maid:Give(input.RecoverTriggered:Connect(requestRecover))
maid:Give(matchUi.JoinRequested:Connect(requestJoin))
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
end
maid:Give(input.CameraToggleRequested:Connect(toggleCamera))
maid:Give(hud.CameraPressed:Connect(toggleCamera))
maid:Give(input.PerfToggleRequested:Connect(function()
	hud:TogglePerf()
end))
maid:Give(input.DeviceChanged:Connect(function(device)
	hud:SetDevice(device)
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
local steerRequired = GameConfig.Tutorial.SteerSecondsRequired
local hitchThreshold = GameConfig.Debug.HitchThresholdSeconds
local clientStart = os.clock()
local boardTimer = 0
local lastAnchored = nil

-- Where the marble is, for the hitch log: zone + course piece under route segment i
-- (segment i runs from section i to i + 1).
local function whereLabel(zone, index)
	local zoneLayout = layouts[zone]
	local section = zoneLayout and (zoneLayout.Sections[index + 1] or zoneLayout.Sections[index])
	local piece = section and zoneLayout.Pieces[section.PieceIndex]
	return string.format("@%s/%s", tostring(zone), piece and piece.Name or "?")
end

RunService:BindToRenderStep(RENDER_STEP, Enum.RenderPriority.Camera.Value + 1, function(dt)
	hud:RecordFrame(dt)
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

		local route = layouts[currentZone].Route
		local target = RouteTracker.SmoothHorizontalTangentAtS(
			route,
			progressS + PhysicsConfig.Movement.SteerFrameLookAhead,
			PhysicsConfig.Movement.SteerFrameSmoothingStuds
		)
		if target then
			local turned = Utility.turnToward(steerForward, target, Utility.expAlpha(PhysicsConfig.Movement.SteerFrameResponse, dt))
			steerForward = flatUnit(turned, steerForward)
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
		})
		if currentZone == ZONES.Race then
			hazards:Step(ball)
		else
			hazards:Step(nil) -- keep the bumper's colours in sync while away
		end

		-- Stuck hint: racing, trying to move, slow, and no route progress for a while.
		local trying = input.steeringEnabled and (math.abs(input.steer.X) > 0.3 or input.steer.Y > 0.3) and not input.brake
		local racingNow = currentZone == ZONES.Race and state == S.Racing and me and not me.finished
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
	cameraController:SetFovTarget(reducedMotion and GameConfig.Camera.FieldOfView or GameConfig.Camera.FieldOfView + (multiplier - 1) * 40)
	cameraController:Step(dt, cameraS)
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
	local progressFraction = currentZone == ZONES.Race and progressS / layouts[ZONES.Race].Route.total or nil
	raceHud:Update({ now = now, device = input.device, queued = queued, spectatingName = spectatingName, stuck = stuck.shown, progress = progressFraction })
	matchUi:Update({ now = now, racing = amRacing(), raceRunning = raceRunning(), spectating = spectate.active })
	boardTimer = boardTimer + dt
	if boardTimer >= 0.25 then
		boardTimer = 0
		matchUi:UpdateBoard(board, { now = now })
	end
end)
maid:Give(function()
	RunService:UnbindFromRenderStep(RENDER_STEP)
end)

script.Destroying:Connect(function()
	maid:Cleanup()
end)

hud:ShowTitle()
refreshGates()
print("[TumbleCircuit] client ready (" .. GameConfig.Version .. ")")
