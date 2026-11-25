--[[
	InputController — one place that turns devices into gameplay intent:
	  steer  : Vector2 (X = right, Y = forward), deadzoned, clamped to [-1, 1]
	  brake  : bool, brakePressed: true on the frame brake goes down
	  recover: hold-to-reset progress (1 s), fires RecoverTriggered once per hold

	PC:        A/D (or arrows) steer, W/S forward/back bias, Shift brake, hold R reset, V camera,
	           Tab standings, Q/E cycle spectated racer (A2)
	Gamepad:   left stick steer/bias, LT brake, hold Y reset, R3 camera
	Touch:     TouchControls feeds virtual steer + Brake/Recover buttons (one explicit stick only;
	           the default Roblox touch controls are disabled by ClientBootstrap)

	Polling (UserInputService) was chosen over the Input Action System for A1 because nothing here
	could be verified in Studio; see README. Typing in a TextBox (chat) never steers.
	Gameplay steering is only live while SetSteeringEnabled(true).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local PhysicsConfig = require(Shared:WaitForChild("PhysicsConfig"))
local Utility = require(Shared:WaitForChild("Utility"))

local InputController = {}
InputController.__index = InputController

local DEVICES = { KeyboardMouse = "KeyboardMouse", Gamepad = "Gamepad", Touch = "Touch" }
InputController.Devices = DEVICES

local KEY = Enum.KeyCode
local PAD = Enum.UserInputType.Gamepad1

local function deviceFromInputType(inputType)
	if inputType == Enum.UserInputType.Touch then
		return DEVICES.Touch
	end
	if string.sub(inputType.Name, 1, 7) == "Gamepad" then
		return DEVICES.Gamepad
	end
	if inputType == Enum.UserInputType.Keyboard
		or inputType == Enum.UserInputType.MouseMovement
		or inputType == Enum.UserInputType.MouseButton1
		or inputType == Enum.UserInputType.MouseButton2
		or inputType == Enum.UserInputType.MouseWheel then
		return DEVICES.KeyboardMouse
	end
	return nil
end

-- UserInputService.PreferredInput is the documented, thrash-resistant signal when it exists.
local function readPreferredInput()
	local ok, value = pcall(function()
		return UserInputService.PreferredInput
	end)
	if not ok or value == nil then
		return nil
	end
	local name = tostring(value)
	if string.find(name, "Touch") then
		return DEVICES.Touch
	elseif string.find(name, "Gamepad") then
		return DEVICES.Gamepad
	end
	return DEVICES.KeyboardMouse
end

local function initialDevice()
	local preferred = readPreferredInput()
	if preferred then
		return preferred
	end
	local fromLast = deviceFromInputType(UserInputService:GetLastInputType())
	if fromLast then
		return fromLast
	end
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return DEVICES.Touch
	end
	return DEVICES.KeyboardMouse
end

function InputController.new()
	local self = setmetatable({}, InputController)
	self.maid = Utility.Maid.new()
	self.steer = Vector2.new(0, 0)
	self.brake = false
	self.brakePressed = false
	self.recoverProgress = 0
	self.steeringEnabled = false
	self.recoverEnabled = false
	self.virtual = {}
	self.virtualSteer = Vector2.new(0, 0)
	self.device = initialDevice()
	self.usesPreferredInput = readPreferredInput() ~= nil
	self._brakeWasDown = false
	self._recoverHeld = 0
	self._recoverLatched = false

	self.DeviceChanged = Utility.Signal.new()
	self.RecoverTriggered = Utility.Signal.new()
	self.CameraToggleRequested = Utility.Signal.new()
	self.PerfToggleRequested = Utility.Signal.new()
	self.PrimaryActionRequested = Utility.Signal.new()
	self.SpectateCycleRequested = Utility.Signal.new() -- (direction -1 | 1), Q/E or LB/RB
	self.AbilityRequested = Utility.Signal.new() -- (slot 1 | 2), Q/E or LB/RB (A3; consumer checks state)
	self.TrickRequested = Utility.Signal.new() -- Space / A (A3)
	self.ScoreboardToggleRequested = Utility.Signal.new() -- Tab / D-pad up

	local function setDevice(device)
		if device and device ~= self.device then
			self.device = device
			self.DeviceChanged:Fire(device)
		end
	end
	if self.usesPreferredInput then
		local ok, signal = pcall(function()
			return UserInputService:GetPropertyChangedSignal("PreferredInput")
		end)
		if ok and signal then
			self.maid:Give(signal:Connect(function()
				setDevice(readPreferredInput())
			end))
		else
			self.usesPreferredInput = false
		end
	end
	if not self.usesPreferredInput then
		self.maid:Give(UserInputService.LastInputTypeChanged:Connect(function(inputType)
			setDevice(deviceFromInputType(inputType))
		end))
	end
	-- A real finger on the screen always means touch controls, even if PreferredInput reports
	-- something else (e.g. an early Web Play build on a phone). Without this the stick would never
	-- appear and the marble could not be steered. Connected before TouchControls, so the touch that
	-- switches the device can also grab the stick.
	self.maid:Give(UserInputService.TouchStarted:Connect(function()
		setDevice(DEVICES.Touch)
	end))

	self.maid:Give(UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then
			return
		end
		local code = input.KeyCode
		if code == KEY.V or code == KEY.ButtonR3 then
			self.CameraToggleRequested:Fire()
		elseif code == KEY.F2 then
			self.PerfToggleRequested:Fire()
		elseif code == KEY.Return or code == KEY.KeypadEnter or code == KEY.Space or code == KEY.ButtonA then
			self.PrimaryActionRequested:Fire()
			if code == KEY.Space or code == KEY.ButtonA then
				self.TrickRequested:Fire()
			end
		elseif code == KEY.Q or code == KEY.ButtonL1 then
			self.AbilityRequested:Fire(1)
			self.SpectateCycleRequested:Fire(-1)
		elseif code == KEY.E or code == KEY.ButtonR1 then
			self.AbilityRequested:Fire(2)
			self.SpectateCycleRequested:Fire(1)
		elseif code == KEY.Tab or code == KEY.DPadUp then
			self.ScoreboardToggleRequested:Fire()
		end
	end))

	-- Never leave a stuck key/button when focus or the device goes away.
	self.maid:Give(UserInputService.WindowFocusReleased:Connect(function()
		self:ResetState()
	end))
	self.maid:Give(UserInputService.GamepadDisconnected:Connect(function()
		self:ResetState()
	end))
	self.maid:Give(UserInputService.TextBoxFocused:Connect(function()
		self:ResetState()
	end))
	return self
end

-- A5 setting: 0.5-1.5 scales steering strength (keyboard, stick and touch alike).
function InputController:SetSensitivity(value)
	self.sensitivity = Utility.clamp(tonumber(value) or 1, 0.5, 1.5)
end

function InputController:SetSteeringEnabled(enabled)
	self.steeringEnabled = enabled
	if not enabled then
		self.steer = Vector2.new(0, 0)
		self.brake = false
		self.brakePressed = false
	end
end

function InputController:SetRecoverEnabled(enabled)
	self.recoverEnabled = enabled
	if not enabled then
		self._recoverHeld = 0
		self.recoverProgress = 0
	end
end

function InputController:SetVirtual(name, isDown)
	self.virtual[name] = isDown and true or nil
end

function InputController:SetVirtualSteer(vector)
	self.virtualSteer = vector
end

-- Called on respawn, focus loss, gamepad loss, UI focus.
function InputController:ResetState()
	self.steer = Vector2.new(0, 0)
	self.brake = false
	self.brakePressed = false
	self._brakeWasDown = false
	self._recoverHeld = 0
	self.recoverProgress = 0
	-- _recoverLatched is kept on purpose: holding R through a respawn must not reset again.
	self.virtual = {}
	self.virtualSteer = Vector2.new(0, 0)
end

function InputController:_readKeyboard()
	if UserInputService:GetFocusedTextBox() ~= nil or not UserInputService.KeyboardEnabled then
		return 0, 0, false, false
	end
	local function down(a, b)
		return UserInputService:IsKeyDown(a) or (b ~= nil and UserInputService:IsKeyDown(b))
	end
	local x, y = 0, 0
	if down(KEY.A, KEY.Left) then
		x = x - 1
	end
	if down(KEY.D, KEY.Right) then
		x = x + 1
	end
	if down(KEY.W, KEY.Up) then
		y = y + 1
	end
	if down(KEY.S, KEY.Down) then
		y = y - 1
	end
	return x, y, down(KEY.LeftShift, KEY.RightShift), down(KEY.R)
end

function InputController:_readGamepad()
	if not UserInputService.GamepadEnabled then
		return 0, 0, false, false
	end
	local ok, states = pcall(function()
		return UserInputService:GetGamepadState(PAD)
	end)
	if not ok or type(states) ~= "table" then
		return 0, 0, false, false
	end
	local sx, sy, trigger = 0, 0, 0
	for _, state in ipairs(states) do
		if state.KeyCode == KEY.Thumbstick1 then
			sx, sy = state.Position.X, state.Position.Y
		elseif state.KeyCode == KEY.ButtonL2 then
			trigger = state.Position.Z
		end
	end
	sx, sy = Utility.radialDeadzone(sx, sy, PhysicsConfig.Movement.SteerDeadzone)
	local brake = trigger >= GameConfig.Input.TriggerBrakeThreshold or UserInputService:IsGamepadButtonDown(PAD, KEY.ButtonL2)
	local recover = UserInputService:IsGamepadButtonDown(PAD, KEY.ButtonY)
	return sx, sy, brake, recover
end

function InputController:Update(dt)
	local kx, ky, kBrake, kRecover = self:_readKeyboard()
	local gx, gy, gBrake, gRecover = self:_readGamepad()
	local x = Utility.clamp((kx + gx + self.virtualSteer.X) * (self.sensitivity or 1), -1, 1) -- A5 setting
	local y = Utility.clamp(ky + gy + self.virtualSteer.Y, -1, 1)
	local brake = kBrake or gBrake or self.virtual.Brake == true
	local recover = kRecover or gRecover or self.virtual.Recover == true or self.virtual.RecoverMouse == true

	if not self.steeringEnabled then
		x, y, brake = 0, 0, false
	end
	self.steer = Vector2.new(x, y)
	self.brakePressed = brake and not self._brakeWasDown
	self._brakeWasDown = brake
	self.brake = brake

	local hold = GameConfig.Input.RecoverHoldSeconds
	if self.recoverEnabled and recover and not self._recoverLatched then
		self._recoverHeld = self._recoverHeld + dt
		if self._recoverHeld >= hold then
			self._recoverLatched = true
			self._recoverHeld = 0
			self.RecoverTriggered:Fire()
		end
	elseif not recover then
		self._recoverHeld = 0
		self._recoverLatched = false
	end
	self.recoverProgress = math.min(1, self._recoverHeld / hold)
end

function InputController:Destroy()
	self.maid:Cleanup()
end

return InputController
