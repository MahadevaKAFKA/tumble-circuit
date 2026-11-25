--[[
	TouchControls — mobile-landscape controls (ADR-18). Exactly ONE thumbstick: this explicit
	floating stick on the left half. The default Roblox touch thumbstick is disabled by
	ClientBootstrap, so the two can never overlap.

	Right side: BRAKE (hold, large), RESET (hold 1 s, smaller, with fill bar), CAM (tap),
	LIST (tap: race standings, A2).
	Buttons sit inside a UIScale'd frame (>= ~44 px at MinScale). The stick lives in an unscaled
	frame so touch positions map 1:1 (input positions and AbsolutePosition share one space).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local PhysicsConfig = require(Shared:WaitForChild("PhysicsConfig"))
local Utility = require(Shared:WaitForChild("Utility"))

local TouchControls = {}
TouchControls.__index = TouchControls

local STICK_ZONE_MAX_X = 0.45 -- touches starting in the left 45% of the screen...
local STICK_ZONE_MIN_Y = 0.3 -- ...and below the top 30% grab the stick

local function new(className, props, parent)
	local inst = Instance.new(className)
	for key, value in pairs(props) do
		inst[key] = value
	end
	inst.Parent = parent
	return inst
end

local function round(inst, radius)
	new("UICorner", { CornerRadius = radius or UDim.new(0.5, 0) }, inst)
end

function TouchControls.new(input)
	local self = setmetatable({}, TouchControls)
	self.input = input
	self.maid = Utility.Maid.new()
	self.visible = false
	self.scale = 1
	self.stickTouch = nil
	self.buttonInputs = {}
	local palette = GameConfig.Palette
	local ui = GameConfig.UI

	local gui = new("ScreenGui", {
		Name = "TumbleTouchControls",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 5,
		Enabled = false,
	}, Players.LocalPlayer:WaitForChild("PlayerGui"))
	pcall(function()
		gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	end)
	self.gui = gui
	self.maid:Give(gui)

	-- Unscaled stick layer
	local stickLayer = new("Frame", { Name = "StickLayer", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, gui)
	self.stickLayer = stickLayer
	local base = new("Frame", {
		Name = "StickBase",
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = palette.Navy,
		BackgroundTransparency = 0.35,
	}, stickLayer)
	round(base)
	new("UIStroke", { Color = palette.Cyan, Thickness = 2, Transparency = 0.2 }, base)
	local knob = new("Frame", {
		Name = "Knob",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		BackgroundColor3 = palette.Cyan,
		BackgroundTransparency = 0.15,
	}, base)
	round(knob)
	self.base, self.knob = base, knob

	-- Scaled button layer (root sized 1/scale so UIScale maps it back to full screen)
	local buttonRoot = new("Frame", { Name = "Buttons", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, gui)
	self.uiScale = new("UIScale", { Scale = 1 }, buttonRoot)
	self.buttonRoot = buttonRoot

	local function holdButton(name, text, size, position, color)
		local button = new("TextButton", {
			Name = name,
			AnchorPoint = Vector2.new(1, 1),
			Size = UDim2.fromOffset(size, size),
			Position = position,
			BackgroundColor3 = palette.Navy,
			BackgroundTransparency = 0.2,
			Text = "",
			AutoButtonColor = false,
			ClipsDescendants = true,
		}, buttonRoot)
		round(button)
		new("UIStroke", { Color = color, Thickness = 3 }, button)
		new("TextLabel", {
			Name = "Label",
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromScale(0.66, 0.36),
			BackgroundTransparency = 1,
			Text = text,
			TextColor3 = color,
			Font = Enum.Font.GothamBlack,
			TextScaled = true,
		}, button)
		local active = {}
		self.buttonInputs[name] = active
		local function refresh()
			local isDown = next(active) ~= nil
			self.input:SetVirtual(name, isDown)
			button.BackgroundTransparency = isDown and 0 or 0.2
		end
		self.maid:Give(button.InputBegan:Connect(function(io)
			if io.UserInputType == Enum.UserInputType.Touch or io.UserInputType == Enum.UserInputType.MouseButton1 then
				active[io] = true
				refresh()
			end
		end))
		self.maid:Give(button.InputEnded:Connect(function(io)
			if active[io] then
				active[io] = nil
				refresh()
			end
		end))
		self["refresh" .. name] = refresh
		return button
	end

	local big, small = ui.TouchButtonSize, ui.TouchSmallButtonSize
	self.brakeButton = holdButton("Brake", "BRAKE", big, UDim2.new(1, -24, 1, -24), palette.Coral)
	self.recoverButton = holdButton("Recover", "RESET", small, UDim2.new(1, -24 - big - 20, 1, -24), palette.Yellow)
	local fill = new("Frame", {
		Name = "HoldFill",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 0, 1, 0),
		Size = UDim2.fromScale(0, 0.12),
		BackgroundColor3 = palette.Yellow,
		BorderSizePixel = 0,
		ZIndex = 2,
	}, self.recoverButton)
	self.recoverFill = fill

	local cam = new("TextButton", {
		Name = "Camera",
		AnchorPoint = Vector2.new(1, 1),
		Size = UDim2.fromOffset(small, small * 0.6),
		Position = UDim2.new(1, -24, 1, -24 - big - 20),
		BackgroundColor3 = palette.Navy,
		BackgroundTransparency = 0.2,
		Text = "CAM",
		TextColor3 = palette.Cyan,
		Font = Enum.Font.GothamBold,
		TextScaled = true,
	}, buttonRoot)
	round(cam, UDim.new(0.3, 0))
	new("UIStroke", { Color = palette.Cyan, Thickness = 2 }, cam)
	self.maid:Give(cam.Activated:Connect(function()
		self.input.CameraToggleRequested:Fire()
	end))

	-- Standings (Tab / D-pad up on other devices; phones have no key for it). Sits above RESET.
	local list = new("TextButton", {
		Name = "Standings",
		AnchorPoint = Vector2.new(1, 1),
		Size = UDim2.fromOffset(small, small * 0.6),
		Position = UDim2.new(1, -24 - big - 20, 1, -24 - small - 20),
		BackgroundColor3 = palette.Navy,
		BackgroundTransparency = 0.2,
		Text = "LIST",
		TextColor3 = palette.Cyan,
		Font = Enum.Font.GothamBold,
		TextScaled = true,
	}, buttonRoot)
	round(list, UDim.new(0.3, 0))
	new("UIStroke", { Color = palette.Cyan, Thickness = 2 }, list)
	self.maid:Give(list.Activated:Connect(function()
		self.input.ScoreboardToggleRequested:Fire()
	end))

	-- Global touch tracking for the stick and as a release fallback for held buttons
	self.maid:Give(UserInputService.TouchStarted:Connect(function(touch, gameProcessed)
		self:_onTouchStarted(touch, gameProcessed)
	end))
	self.maid:Give(UserInputService.TouchMoved:Connect(function(touch)
		if touch == self.stickTouch then
			self:_updateStick(touch)
		end
	end))
	self.maid:Give(UserInputService.TouchEnded:Connect(function(touch)
		if touch == self.stickTouch then
			self:_releaseStick()
		end
		self:_releaseButtonInput(touch)
	end))
	self.maid:Give(UserInputService.InputEnded:Connect(function(io)
		self:_releaseButtonInput(io)
	end))

	local camera = workspace.CurrentCamera
	self.maid:Give(camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		self:_layout()
	end))
	self:_layout()
	return self
end

function TouchControls:_releaseButtonInput(io)
	for name, active in pairs(self.buttonInputs) do
		if active[io] then
			active[io] = nil
			self["refresh" .. name]()
		end
	end
end

function TouchControls:_layout()
	local ui = GameConfig.UI
	local viewport = workspace.CurrentCamera.ViewportSize
	local scale = math.min(viewport.X / ui.ReferenceWidth, viewport.Y / ui.ReferenceHeight)
	scale = Utility.clamp(scale, ui.MinScale, ui.MaxScale)
	self.scale = scale
	self.uiScale.Scale = scale
	self.buttonRoot.Size = UDim2.fromScale(1 / scale, 1 / scale)
	local r = ui.TouchStickRadius * scale
	self.radius = r
	self.base.Size = UDim2.fromOffset(r * 2, r * 2)
	self.knob.Size = UDim2.fromOffset(r * 0.9, r * 0.9)
	if not self.stickTouch then
		self:_restStick()
	end
end

function TouchControls:_restStick()
	local r = self.radius or 70
	self.base.Position = UDim2.new(0, r * 1.7, 1, -r * 1.7)
	self.knob.Position = UDim2.fromScale(0.5, 0.5)
	self.base.BackgroundTransparency = 0.55
end

function TouchControls:_toLocal(position)
	local origin = self.stickLayer.AbsolutePosition
	return Vector2.new(position.X - origin.X, position.Y - origin.Y)
end

-- True for a screen position where a new touch grabs the steering stick (lower-left area).
-- FreeLookController uses the rest of the screen for looking around.
function TouchControls:IsStickZone(position)
	if not self.visible then
		return false
	end
	local size = self.stickLayer.AbsoluteSize
	local p = self:_toLocal(position)
	return p.X <= size.X * STICK_ZONE_MAX_X and p.Y >= size.Y * STICK_ZONE_MIN_Y
end

function TouchControls:_onTouchStarted(touch, gameProcessed)
	if not self.visible or gameProcessed or self.stickTouch then
		return
	end
	if not self:IsStickZone(touch.Position) then
		return
	end
	local p = self:_toLocal(touch.Position)
	self.stickTouch = touch
	self.stickCenter = p
	self.base.Position = UDim2.fromOffset(p.X, p.Y)
	self.base.BackgroundTransparency = 0.3
	self:_updateStick(touch)
end

function TouchControls:_updateStick(touch)
	local p = self:_toLocal(touch.Position)
	local delta = p - self.stickCenter
	local r = self.radius
	local m = delta.Magnitude
	if m > r then
		delta = delta * (r / m)
	end
	self.knob.Position = UDim2.new(0.5, delta.X, 0.5, delta.Y)
	local x, y = Utility.radialDeadzone(delta.X / r, delta.Y / r, PhysicsConfig.Movement.SteerDeadzone)
	self.input:SetVirtualSteer(Vector2.new(x, -y)) -- screen Y grows downward; forward is up
end

function TouchControls:_releaseStick()
	self.stickTouch = nil
	self.input:SetVirtualSteer(Vector2.new(0, 0))
	self:_restStick()
end

function TouchControls:SetVisible(visible)
	if self.visible == visible then
		return
	end
	self.visible = visible
	self.gui.Enabled = visible
	if not visible then
		self:_releaseStick()
		for name, active in pairs(self.buttonInputs) do
			for io in pairs(active) do
				active[io] = nil
			end
			self["refresh" .. name]()
		end
	end
end

function TouchControls:SetRecoverProgress(progress)
	self.recoverFill.Size = UDim2.fromScale(progress, 0.12)
end

function TouchControls:Destroy()
	self:SetVisible(false)
	self.maid:Cleanup()
end

return TouchControls
