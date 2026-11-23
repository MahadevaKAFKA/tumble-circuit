-- Safety net for touch screens: if Roblox's default thumbstick or jump button
-- is missing (for example in an early Web Play build), show our own.
-- When the default touch controls are present this module stays hidden.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer

local TouchFallback = {}

local ZERO = Vector3.new(0, 0, 0)
local GRACE_SECONDS = 4 -- give the default controls time to appear first
local CHECK_EVERY = 1.5

local function defaultTouchControls(playerGui)
	local touchGui = playerGui:FindFirstChild("TouchGui")
	if not (touchGui and touchGui:IsA("ScreenGui") and touchGui.Enabled) then
		return false, false
	end
	local frame = touchGui:FindFirstChild("TouchControlFrame")
	if not (frame and frame:IsA("GuiObject") and frame.Visible) then
		return false, false
	end
	local stick = frame:FindFirstChild("DynamicThumbstickFrame") or frame:FindFirstChild("ThumbstickFrame")
	local jump = frame:FindFirstChild("JumpButton")
	local hasStick = stick ~= nil and stick:IsA("GuiObject") and stick.Visible
	local hasJump = jump ~= nil and jump:IsA("GuiObject") and jump.Visible
	return hasStick, hasJump
end

function TouchFallback.start(controller)
	if not UserInputService.TouchEnabled then
		return
	end
	local playerGui = player:WaitForChild("PlayerGui")

	local gui = Instance.new("ScreenGui")
	gui.Name = "TumbleTouchFallback"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	local base = Instance.new("Frame")
	base.Name = "Stick"
	base.AnchorPoint = Vector2.new(0, 1)
	base.Position = UDim2.new(0, 28, 1, -28)
	base.Size = UDim2.new(0, 150, 0, 150)
	base.BackgroundColor3 = Color3.fromRGB(20, 24, 34)
	base.BackgroundTransparency = 0.55
	base.BorderSizePixel = 0
	base.Active = true
	base.Visible = false
	base.Parent = gui
	local baseCorner = Instance.new("UICorner")
	baseCorner.CornerRadius = UDim.new(0.5, 0)
	baseCorner.Parent = base

	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.new(0.5, 0, 0.5, 0)
	knob.Size = UDim2.new(0, 64, 0, 64)
	knob.BackgroundColor3 = Color3.fromRGB(230, 235, 245)
	knob.BackgroundTransparency = 0.2
	knob.BorderSizePixel = 0
	knob.Parent = base
	local knobCorner = Instance.new("UICorner")
	knobCorner.CornerRadius = UDim.new(0.5, 0)
	knobCorner.Parent = knob

	local jumpButton = Instance.new("TextButton")
	jumpButton.Name = "Jump"
	jumpButton.AnchorPoint = Vector2.new(1, 1)
	jumpButton.Position = UDim2.new(1, -28, 1, -28)
	jumpButton.Size = UDim2.new(0, 100, 0, 100)
	jumpButton.BackgroundColor3 = Color3.fromRGB(40, 110, 200)
	jumpButton.BackgroundTransparency = 0.2
	jumpButton.BorderSizePixel = 0
	jumpButton.Font = Enum.Font.GothamBold
	jumpButton.Text = "JUMP"
	jumpButton.TextColor3 = Color3.fromRGB(255, 255, 255)
	jumpButton.TextSize = 24
	jumpButton.Visible = false
	jumpButton.Parent = gui
	local jumpCorner = Instance.new("UICorner")
	jumpCorner.CornerRadius = UDim.new(0.5, 0)
	jumpCorner.Parent = jumpButton

	gui.Parent = playerGui

	-- Offsets are measured from where the finger first landed, so the stick works
	-- the same whatever the screen inset is.
	local activeInput = nil
	local origin = nil

	local function release()
		activeInput = nil
		origin = nil
		knob.Position = UDim2.new(0.5, 0, 0.5, 0)
		controller.setVirtualMove(ZERO)
	end

	local function update(position)
		if not origin then
			return
		end
		local radius = math.max(base.AbsoluteSize.X * 0.5, 1)
		local offset = Vector2.new(position.X - origin.X, position.Y - origin.Y)
		if offset.Magnitude > radius then
			offset = offset.Unit * radius
		end
		knob.Position = UDim2.new(0.5, offset.X, 0.5, offset.Y)
		controller.setVirtualMove(Vector3.new(offset.X / radius, 0, offset.Y / radius))
	end

	base.InputBegan:Connect(function(input)
		if activeInput or input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		activeInput = input
		origin = Vector2.new(input.Position.X, input.Position.Y)
		update(input.Position)
	end)

	UserInputService.TouchMoved:Connect(function(input)
		if input == activeInput then
			update(input.Position)
		end
	end)

	UserInputService.TouchEnded:Connect(function(input)
		if input == activeInput then
			release()
		end
	end)

	jumpButton.Activated:Connect(function()
		controller.queueJump()
	end)

	task.spawn(function()
		local firstSeen = nil
		while gui.Parent do
			if controller.getMarble() then
				firstSeen = firstSeen or os.clock()
				if os.clock() - firstSeen >= GRACE_SECONDS then
					local hasStick, hasJump = defaultTouchControls(playerGui)
					base.Visible = not hasStick
					jumpButton.Visible = not hasJump
					if hasStick and activeInput then
						release()
					end
				end
			end
			task.wait(CHECK_EVERY)
		end
	end)
end

return TouchFallback
