--[[
	ClientBootstrap — wires the A1 client together.

	Flow: Loading -> Title ("PLAY PRACTICE") -> Playing (+ one skippable steering tutorial)
	      -> Finished ("TRY AGAIN") -> Playing ...
	Gameplay steering is only enabled while Playing with a bound marble and not Finished.
	Hold-to-reset works while Playing or Finished. Every reset is a server request with no payload.

	Per frame (one BindToRenderStep, after the default camera priority):
	  input -> route progress -> steering frame -> motor forces -> hazard -> camera -> HUD
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
local RouteTracker = require(Shared:WaitForChild("RouteTracker"))
local TrackDefinitions = require(Shared:WaitForChild("TrackDefinitions"))
local Utility = require(Shared:WaitForChild("Utility"))
local PlaceholderIds = require(Shared:WaitForChild("PlaceholderIds"))

local InputController = require(Controllers:WaitForChild("InputController"))
local TouchControls = require(Controllers:WaitForChild("TouchControls"))
local MarbleMotorController = require(Controllers:WaitForChild("MarbleMotorController"))
local CameraController = require(Controllers:WaitForChild("CameraController"))
local HazardController = require(Controllers:WaitForChild("HazardController"))
local HUD = require(Controllers:WaitForChild("PrototypeHUDController"))
local SoundController = require(Controllers:WaitForChild("SoundController"))

local ATTR = Protocol.PlayerAttributes
local STATES = Protocol.RunStates
local MODES = MarbleMotorController.Modes

---------------------------------------------------------------------------------------------
-- Default Roblox controls off: no Humanoid to drive, and exactly one touch thumbstick (ours).
---------------------------------------------------------------------------------------------
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
local input = InputController.new()
local hud = HUD.new(input)
local touch = TouchControls.new(input)
local sound = SoundController.new(PlaceholderIds)
local motor = MarbleMotorController.new()
local cameraController = CameraController.new()
maid:Give(input)
maid:Give(hud)
maid:Give(touch)
maid:Give(sound)
maid:Give(motor)
maid:Give(cameraController)

hud:ShowMessage("Building the practice course...")

---------------------------------------------------------------------------------------------
-- Wait (bounded) for the server: remotes, course, marbles folder
---------------------------------------------------------------------------------------------
local timeout = GameConfig.Spawn.ClientWaitTimeoutSeconds
local remotes = ReplicatedStorage:WaitForChild(Protocol.RemotesFolderName, timeout)
local resetRemote = remotes and remotes:WaitForChild(Protocol.Remotes.RequestReset, 5)

local function waitForCourse()
	local deadline = os.clock() + timeout
	while os.clock() < deadline do
		if workspace:GetAttribute(Protocol.WorkspaceAttributes.CourseReady) then
			local course = workspace:FindFirstChild(Protocol.CourseModelName)
			if course then
				return course
			end
		elseif workspace:GetAttribute(Protocol.WorkspaceAttributes.CourseError) then
			return nil, workspace:GetAttribute(Protocol.WorkspaceAttributes.CourseError)
		end
		task.wait(0.1)
	end
	return nil, "timed out waiting for the server to build the course"
end

local course, courseError = waitForCourse()
local marblesFolder = course and workspace:WaitForChild(Protocol.MarblesFolderName, timeout)
if not resetRemote or not course or not marblesFolder then
	hud:ShowMessage("Could not start practice: " .. tostring(courseError or "server remotes missing") .. "\nCheck the Output window for [TumbleCircuit] errors, then press Stop and Play again.", true)
	return
end
course:WaitForChild("Hazards", 5)

local layout = TrackDefinitions.Generate(TrackDefinitions.Training, PhysicsConfig.Ball.Radius)
local tracker = RouteTracker.new(layout.Route)
local hazards = HazardController.new(course, motor, sound)

local function present(list)
	local out = {}
	for _, item in ipairs(list) do
		if item then
			out[#out + 1] = item
		end
	end
	return out
end
local cameraIgnore = present({ marblesFolder, course:FindFirstChild("Rails"), course:FindFirstChild("Decor"), course:FindFirstChild("Hazards") })
local groundIgnore = { marblesFolder }

local function flatUnit(v, fallback)
	return Utility.safeUnit(Vector3.new(v.X, 0, v.Z), fallback)
end
local spawnForward = flatUnit(layout.SpawnFrame.Forward, Vector3.new(0, 0, -1))

---------------------------------------------------------------------------------------------
-- State
---------------------------------------------------------------------------------------------
local uiState = "Title" -- "Title" | "Playing" | "Finished"
local currentBall = nil
local steerForward = spawnForward
local tutorial = { active = false, done = false, left = 0, right = 0 }

local function runState()
	return player:GetAttribute(ATTR.RunState) or STATES.Ready
end

local function refreshGates()
	local rs = runState()
	input:SetSteeringEnabled(uiState == "Playing" and currentBall ~= nil and rs ~= STATES.Finished)
	input:SetRecoverEnabled(uiState ~= "Title")
	touch:SetVisible(input.device == InputController.Devices.Touch and uiState == "Playing")
	hud:SetHudVisible(uiState ~= "Title")
end

local resetLimiter = Utility.RateLimiter.new(GameConfig.Spawn.ClientResetThrottleSeconds)
local function requestReset()
	if resetLimiter:Try("reset") then
		resetRemote:FireServer()
	end
end

---------------------------------------------------------------------------------------------
-- Marble binding (every spawn is a new Part; see MarbleCharacterService)
---------------------------------------------------------------------------------------------
local myMarbleName = Protocol.MarbleName(player.UserId)

local function bindBall(ball)
	if currentBall == ball then
		return
	end
	currentBall = ball
	tracker:Reset()
	input:ResetState()
	motor:Bind(ball, groundIgnore)
	cameraController:Bind(ball, layout.Route, cameraIgnore)
	steerForward = spawnForward
	refreshGates()
end

local function unbindBall(ball)
	if currentBall == ball then
		currentBall = nil
		motor:Unbind()
		cameraController:Unbind()
		refreshGates()
	end
end

maid:Give(marblesFolder.ChildAdded:Connect(function(child)
	if child.Name == myMarbleName and child:IsA("BasePart") then
		bindBall(child)
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
	if reason == Protocol.SpawnReasons.Fell or reason == Protocol.SpawnReasons.Lost then
		hud:Toast("Fell off - back to the start pad", 2)
		sound:Play("Respawn")
	elseif reason == Protocol.SpawnReasons.Reset and uiState == "Playing" then
		hud:Toast("Reset to start", 1)
		sound:Play("Respawn")
	end
end))

---------------------------------------------------------------------------------------------
-- UI flow
---------------------------------------------------------------------------------------------
local function startPlaying()
	if uiState ~= "Title" then
		return
	end
	sound:Play("UIClick")
	uiState = "Playing"
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

local function showFinish()
	hud:ShowFinish(player:GetAttribute(ATTR.LastRunSeconds), player:GetAttribute(ATTR.BestSeconds), player:GetAttribute(ATTR.LastRunWasBest) == true)
end

local function onRunStateChanged()
	local rs = runState()
	if rs == STATES.Finished and uiState ~= "Title" then
		uiState = "Finished"
		showFinish()
		sound:Play("Finish")
	elseif rs == STATES.Running then
		sound:Play("RunStart")
	elseif rs == STATES.Ready and uiState == "Finished" then
		uiState = "Playing"
		hud:HideOverlay()
	end
	refreshGates()
end

maid:Give(player:GetAttributeChangedSignal(ATTR.RunState):Connect(onRunStateChanged))
for _, name in ipairs({ ATTR.LastRunSeconds, ATTR.BestSeconds, ATTR.LastRunWasBest }) do
	maid:Give(player:GetAttributeChangedSignal(name):Connect(function()
		if uiState == "Finished" then
			showFinish() -- attributes can arrive in any order; re-render with the latest values
		end
	end))
end

maid:Give(hud.PlayPressed:Connect(startPlaying))
maid:Give(hud.TryAgainPressed:Connect(requestReset))
maid:Give(hud.TutorialSkipped:Connect(function()
	finishTutorial(nil)
end))
maid:Give(input.PrimaryActionRequested:Connect(function()
	local overlay = hud:GetOverlay()
	if overlay == "Title" then
		startPlaying()
	elseif overlay == "Finish" then
		requestReset()
	end
end))
maid:Give(input.RecoverTriggered:Connect(requestReset))

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

-- Roblox menu "Reset Character" -> our marble reset (SetCore can fail until CoreScripts load).
task.spawn(function()
	local bindable = Instance.new("BindableEvent")
	maid:Give(bindable)
	maid:Give(bindable.Event:Connect(requestReset))
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

RunService:BindToRenderStep(RENDER_STEP, Enum.RenderPriority.Camera.Value + 1, function(dt)
	hud:RecordFrame(dt)
	input:Update(dt)

	local ball = currentBall
	local progressS = 0
	local speed = 0
	local rs = runState()
	if ball and ball.Parent then
		local info = tracker:Update(ball.Position)
		progressS = info.s
		speed = ball.AssemblyLinearVelocity.Magnitude

		local target = RouteTracker.HorizontalTangentAtS(layout.Route, progressS + PhysicsConfig.Movement.SteerFrameLookAhead)
		if target then
			local turned = Utility.turnToward(steerForward, target, Utility.expAlpha(PhysicsConfig.Movement.SteerFrameResponse, dt))
			steerForward = flatUnit(turned, steerForward)
		end

		local mode = MODES.Idle
		if rs == STATES.Finished then
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
		hazards:Step(ball)

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

	cameraController:Step(dt, progressS)
	touch:SetRecoverProgress(input.recoverProgress)
	hud:Update({
		speed = speed,
		runState = rs,
		runStartServerTime = player:GetAttribute(ATTR.RunStartServerTime),
		bestSeconds = player:GetAttribute(ATTR.BestSeconds),
		lastRunSeconds = player:GetAttribute(ATTR.LastRunSeconds),
		recoverProgress = input.recoverProgress,
	})
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
