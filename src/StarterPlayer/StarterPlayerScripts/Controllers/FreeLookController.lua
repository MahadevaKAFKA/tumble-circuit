--[[
	FreeLookController — look around the marble (owner request, A4, 2026-11-25).

	  * Mouse   : hold the right button and move (the cursor stays put while held).
	  * Touch   : drag with a finger that starts outside the steering-stick area (lower left) and
	              not on a button. The stick keeps working at the same time with the other thumb.
	  * Gamepad : right stick.

	Looking is display only: steering follows the track, never the camera, so the marble goes
	where it went before. The camera eases back behind the marble
	GameConfig.Camera.FreeLook.ReturnDelaySeconds after the last look input (CameraController).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local Utility = require(Shared:WaitForChild("Utility"))

local FreeLook = {}
FreeLook.__index = FreeLook

-- camera: CameraController. isStickZone: function(screenPosition: Vector2) -> boolean
function FreeLook.new(camera, isStickZone)
	local self = setmetatable({}, FreeLook)
	self.camera = camera
	self.isStickZone = isStickZone
	self.maid = Utility.Maid.new()
	self.lookTouch = nil
	self.lastTouchPosition = nil
	self.mouseHeld = false
	self.stickHeld = false

	self.maid:Give(UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if input.UserInputType == Enum.UserInputType.MouseButton2 and not gameProcessed then
			self.mouseHeld = true
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
			self:_refreshHeld()
		end
	end))
	self.maid:Give(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton2 and self.mouseHeld then
			self.mouseHeld = false
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
			self:_refreshHeld()
		end
	end))
	self.maid:Give(UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseMovement and self.mouseHeld then
			local k = GameConfig.Camera.FreeLook.MouseDegPerPixel
			self.camera:AddLook(input.Delta.X * k, input.Delta.Y * k)
		end
	end))

	self.maid:Give(UserInputService.TouchStarted:Connect(function(touch, gameProcessed)
		if gameProcessed or self.lookTouch then
			return
		end
		if self.isStickZone and self.isStickZone(touch.Position) then
			return -- that finger steers
		end
		self.lookTouch = touch
		self.lastTouchPosition = Vector2.new(touch.Position.X, touch.Position.Y)
		self:_refreshHeld()
	end))
	self.maid:Give(UserInputService.TouchMoved:Connect(function(touch)
		if touch ~= self.lookTouch then
			return
		end
		local position = Vector2.new(touch.Position.X, touch.Position.Y)
		local delta = position - self.lastTouchPosition
		self.lastTouchPosition = position
		local camera = workspace.CurrentCamera
		local height = camera and camera.ViewportSize.Y or 720
		local k = GameConfig.Camera.FreeLook.TouchDegPerScreenHeight / math.max(height, 1)
		self.camera:AddLook(delta.X * k, delta.Y * k)
	end))
	self.maid:Give(UserInputService.TouchEnded:Connect(function(touch)
		if touch == self.lookTouch then
			self.lookTouch = nil
			self.lastTouchPosition = nil
			self:_refreshHeld()
		end
	end))
	return self
end

function FreeLook:_refreshHeld()
	self.camera:SetLookHeld(self.mouseHeld or self.lookTouch ~= nil or self.stickHeld)
end

-- Called every frame before CameraController:Step (gamepad right stick is polled).
function FreeLook:Update(dt)
	local look = GameConfig.Camera.FreeLook
	local stick = Vector2.new(0, 0)
	if UserInputService.GamepadEnabled then
		for _, state in ipairs(UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1)) do
			if state.KeyCode == Enum.KeyCode.Thumbstick2 then
				stick = Vector2.new(state.Position.X, state.Position.Y)
			end
		end
	end
	local held = stick.Magnitude > look.GamepadDeadzone
	if held then
		-- stick up = look up (camera lower), like most games
		self.camera:AddLook(stick.X * look.GamepadDegPerSecond * dt, -stick.Y * look.GamepadDegPerSecond * dt)
	end
	if held ~= self.stickHeld then
		self.stickHeld = held
		self:_refreshHeld()
	end
end

function FreeLook:Destroy()
	if self.mouseHeld then
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	end
	self.maid:Cleanup()
end

return FreeLook
