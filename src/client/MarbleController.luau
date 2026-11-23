-- Drives the local player's marble.
-- Input comes from Roblox's default PlayerModule controls, so the touch
-- thumbstick + jump button (phone / Web Play), WASD + Space and gamepads all
-- work with no extra UI. TouchFallback feeds in a virtual stick only if the
-- default touch controls are missing.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local StarterGui = game:GetService("StarterGui")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local CourseData = require(Shared:WaitForChild("CourseData"))
local RestartRun = ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("RestartRun")

local M = Config.Movement
local ZERO = Vector3.new(0, 0, 0)
local UP = Vector3.new(0, 1, 0)

local player = Players.LocalPlayer

local MarbleController = {}

local controls = nil
local controlsResolved = false
local virtualMove = ZERO

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

-- { character, humanoid, root, ball, force, upright } for the live marble
local current = nil
local lastGroundedAt = -math.huge
local lastJumpAt = -math.huge
local jumpQueuedAt = -math.huge
local prevJumpHeld = false
local fallLockUntil = 0
local started = false

MarbleController.grounded = false

local function resolveControls()
	local ok, result = pcall(function()
		local playerScripts = player:WaitForChild("PlayerScripts", 20)
		local playerModule = playerScripts and playerScripts:WaitForChild("PlayerModule", 20)
		if not playerModule then
			return nil
		end
		return require(playerModule):GetControls()
	end)
	if ok and result then
		controls = result
	else
		warn("[TumbleCircuit] default controls unavailable, using keyboard fallback: " .. tostring(result))
	end
	controlsResolved = true
end

local function keyboardMoveVector()
	local x, z = 0, 0
	if UserInputService:IsKeyDown(Enum.KeyCode.W) or UserInputService:IsKeyDown(Enum.KeyCode.Up) then
		z -= 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.S) or UserInputService:IsKeyDown(Enum.KeyCode.Down) then
		z += 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.A) or UserInputService:IsKeyDown(Enum.KeyCode.Left) then
		x -= 1
	end
	if UserInputService:IsKeyDown(Enum.KeyCode.D) or UserInputService:IsKeyDown(Enum.KeyCode.Right) then
		x += 1
	end
	return Vector3.new(x, 0, z)
end

-- Move input. Returns (vector, isWorldSpace).
-- Camera-space vectors use the default ControlModule convention: X = right,
-- Z = backward. Humanoid.MoveDirection is already in world space.
local function readMoveInput(humanoid)
	if virtualMove.Magnitude > M.InputDeadzone then
		return virtualMove, false
	end
	if controls then
		local ok, value = pcall(controls.GetMoveVector, controls)
		if ok and typeof(value) == "Vector3" then
			return value, false
		end
	end
	-- Fallbacks in case the control module is missing or its API changes.
	local moveDirection = humanoid.MoveDirection
	if moveDirection.Magnitude > M.InputDeadzone then
		return moveDirection, true
	end
	if controlsResolved and not controls then
		return keyboardMoveVector(), false
	end
	return ZERO, false
end

-- Convert camera-space input to a flat world direction (length 0..1).
local function worldDirection(raw)
	if raw.Magnitude < M.InputDeadzone then
		return ZERO
	end
	local camera = Workspace.CurrentCamera
	if not camera then
		return ZERO
	end
	local look = camera.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-3 then
		local up = camera.CFrame.UpVector
		flat = Vector3.new(up.X, 0, up.Z)
		if flat.Magnitude < 1e-3 then
			flat = Vector3.new(0, 0, -1)
		end
	end
	flat = flat.Unit
	local right = flat:Cross(UP)
	local direction = right * raw.X + flat * -raw.Z
	if direction.Magnitude > 1 then
		direction = direction.Unit
	end
	return direction
end

local function step()
	local live = current
	if not live then
		return
	end
	local ball = live.ball
	if not ball.Parent then
		current = nil
		return
	end
	local humanoid = live.humanoid
	if humanoid.Parent and not humanoid.PlatformStand then
		humanoid.PlatformStand = true
	end

	local now = os.clock()
	local radius = ball.Size.X * 0.5
	local origin = ball.Position

	local grounded = false
	local groundNormal = UP
	local hit = Workspace:Raycast(origin, Vector3.new(0, -(radius + M.GroundProbeExtra), 0), rayParams)
	if hit then
		grounded = true
		groundNormal = hit.Normal
		lastGroundedAt = now
	end
	MarbleController.grounded = grounded

	-- The default controls set Humanoid.Jump while the jump input is held.
	local held = humanoid.Jump
	if held and not prevJumpHeld then
		jumpQueuedAt = now
	end
	prevJumpHeld = held

	local mass = ball.AssemblyMass
	local velocity = ball.AssemblyLinearVelocity
	local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
	local input, isWorldSpace = readMoveInput(humanoid)
	local direction
	if isWorldSpace then
		direction = Vector3.new(input.X, 0, input.Z)
		if direction.Magnitude > 1 then
			direction = direction.Unit
		end
	else
		direction = worldDirection(input)
	end
	local magnitude = direction.Magnitude
	local force = ZERO

	if magnitude > M.InputDeadzone then
		local unit = direction / magnitude
		local along = horizontal:Dot(unit)
		local cap = 1
		if along >= M.MaxSpeed then
			cap = 0
		elseif along > M.MaxSpeed * 0.8 then
			cap = (M.MaxSpeed - along) / (M.MaxSpeed * 0.2)
		end

		local push = direction
		local acceleration = M.AirAcceleration
		if grounded then
			acceleration = M.GroundAcceleration
			-- Follow the slope so we neither dig into it nor lift off it.
			local tangent = direction - groundNormal * direction:Dot(groundNormal)
			if tangent.Magnitude > 1e-3 then
				push = tangent.Unit * magnitude
			end
		end
		force = push * (acceleration * mass * cap)

		if grounded then
			local lateral = horizontal - unit * along
			force -= lateral * (M.TurnAssist * mass)
			if along < 0 then
				force -= unit * (along * M.ReverseBrake * mass)
			end
		end
	elseif grounded then
		force = horizontal * (-M.CoastDamping * mass)
	end
	live.force.Force = force

	local wantsJump = now - jumpQueuedAt <= M.JumpBuffer
	local canJump = now - lastGroundedAt <= M.CoyoteTime and now - lastJumpAt >= M.JumpCooldown
	if wantsJump and canJump then
		jumpQueuedAt = -math.huge
		lastJumpAt = now
		lastGroundedAt = -math.huge
		local v = ball.AssemblyLinearVelocity
		ball.AssemblyLinearVelocity = Vector3.new(v.X, math.max(v.Y, 0) + M.JumpVelocity, v.Z)
	end

	if origin.Y < CourseData.KillY and now >= fallLockUntil then
		MarbleController.resetToCheckpoint()
	end
end

local function teleportTo(index)
	local live = current
	if not live or not live.ball.Parent then
		return
	end
	local ball = live.ball
	local spawnCFrame = CourseData.getSpawnCFrame(index, ball.Size.X * 0.5)

	live.force.Force = ZERO
	ball.AssemblyLinearVelocity = ZERO
	ball.AssemblyAngularVelocity = ZERO
	ball.CFrame = CFrame.new(spawnCFrame.Position)
	ball.AssemblyLinearVelocity = ZERO
	ball.AssemblyAngularVelocity = ZERO
	if live.root.Parent then
		live.root.CFrame = spawnCFrame
	end
	if live.upright then
		live.upright.CFrame = spawnCFrame - spawnCFrame.Position
	end
	fallLockUntil = os.clock() + Config.Respawn.FallLockTime
	jumpQueuedAt = -math.huge

	-- Swing the camera behind the marble, looking down the course.
	local camera = Workspace.CurrentCamera
	if camera then
		local focus = spawnCFrame.Position
		local eye = focus - spawnCFrame.LookVector * 16 + UP * 7
		camera.CFrame = CourseData.lookAt(eye, focus)
	end
end

local function currentCheckpoint()
	local index = player:GetAttribute("Checkpoint")
	if type(index) ~= "number" or not CourseData.Checkpoints[index] then
		return 1
	end
	return index
end

function MarbleController.resetToCheckpoint()
	teleportTo(currentCheckpoint())
end

function MarbleController.restartRun()
	RestartRun:FireServer()
	teleportTo(1)
end

function MarbleController.queueJump()
	jumpQueuedAt = os.clock()
end

function MarbleController.setVirtualMove(vector)
	if typeof(vector) == "Vector3" then
		virtualMove = vector
	else
		virtualMove = ZERO
	end
end

function MarbleController.getMarble()
	if current then
		return current.ball
	end
	return nil
end

local function attach(character)
	current = nil
	local humanoid = character:WaitForChild("Humanoid", 15)
	local root = character:WaitForChild("HumanoidRootPart", 15)
	local ref = character:WaitForChild("MarbleRef", 15)
	if not (humanoid and root and ref) then
		warn("[TumbleCircuit] marble did not arrive for this character")
		return
	end

	local ball = ref.Value
	local deadline = os.clock() + 10
	while not (ball and ball:IsA("BasePart") and ball.Parent) do
		if os.clock() > deadline or player.Character ~= character then
			return
		end
		task.wait()
		ball = ref.Value
	end

	local force = ball:WaitForChild("DriveForce", 10)
	local upright = root:WaitForChild("MarbleUpright", 5)
	if not force or player.Character ~= character then
		return
	end

	humanoid.PlatformStand = true
	rayParams.FilterDescendantsInstances = { character }
	prevJumpHeld = false
	fallLockUntil = os.clock() + Config.Respawn.FallLockTime
	current = {
		character = character,
		humanoid = humanoid,
		root = root,
		ball = ball,
		force = force,
		upright = upright,
	}
end

local function bindResetButton()
	local bindable = Instance.new("BindableEvent")
	bindable.Event:Connect(function()
		MarbleController.resetToCheckpoint()
	end)
	for _ = 1, 20 do
		local ok = pcall(function()
			StarterGui:SetCore("ResetButtonCallback", bindable)
		end)
		if ok then
			return
		end
		task.wait(1)
	end
end

function MarbleController.start()
	if started then
		return
	end
	started = true

	task.spawn(resolveControls)

	UserInputService.JumpRequest:Connect(function()
		jumpQueuedAt = os.clock()
	end)

	player.CharacterAdded:Connect(function(character)
		task.spawn(attach, character)
	end)
	if player.Character then
		task.spawn(attach, player.Character)
	end

	local hasPreSimulation, preSimulation = pcall(function()
		return RunService.PreSimulation
	end)
	if hasPreSimulation and preSimulation then
		preSimulation:Connect(step)
	else
		RunService.Stepped:Connect(step)
	end

	ContextActionService:BindAction("TumbleResetToCheckpoint", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			MarbleController.resetToCheckpoint()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.R, Enum.KeyCode.ButtonY)

	ContextActionService:BindAction("TumbleRestartRun", function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			MarbleController.restartRun()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.T, Enum.KeyCode.ButtonSelect)

	task.spawn(bindResetButton)
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
	end)
end

return MarbleController
