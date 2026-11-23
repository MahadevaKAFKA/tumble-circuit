--[[
	PrototypeHUDController — the A1 overlay. Every visible button does something.

	HUD (safe-area, scaled from a 1280x720 reference):
	  top centre   timer + best / state hint
	  bottom centre speed (studs/s)
	  top right    CAM toggle and hold-to-RESET (mouse/keyboard layout only; touch has its own)
	  bottom left  device-specific control hint (keyboard / gamepad)
	  centre       toast messages, one skippable steering tutorial card
	  top left     F2 frame-time overlay (avg + 95th percentile), off by default
	Overlay (full screen, above everything): title / Play Practice, Finish! / Try Again,
	loading and fatal-error messages.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local Utility = require(Shared:WaitForChild("Utility"))

local HUD = {}
HUD.__index = HUD

local STATES = Protocol.RunStates
local palette = GameConfig.Palette

local HINTS = {
	KeyboardMouse = "A / D  steer     W  faster     S  hold back     SHIFT  brake     hold R  reset     V  camera",
	Gamepad = "Left stick  steer     LT  brake     hold Y  reset     R3  camera",
	Touch = "",
}
local TUTORIAL_TEXT = {
	KeyboardMouse = "Tap A and D to steer left and right.  Hold W to roll faster, SHIFT to brake.",
	Gamepad = "Push the left stick left and right to steer.  Hold LT to brake.",
	Touch = "Drag on the left side of the screen to steer.  Hold BRAKE to slow down.",
}
local PRIMARY_HINT = {
	KeyboardMouse = "or press Enter",
	Gamepad = "or press (A)",
	Touch = "",
}

local function new(className, props, parent)
	local inst = Instance.new(className)
	for key, value in pairs(props) do
		inst[key] = value
	end
	inst.Parent = parent
	return inst
end

local function corner(parent, scale)
	new("UICorner", { CornerRadius = UDim.new(scale or 0.2, 0) }, parent)
end

local function label(parent, props)
	local base = {
		BackgroundTransparency = 1,
		TextColor3 = palette.White,
		Font = Enum.Font.GothamBold,
		TextScaled = true,
		Text = "",
	}
	for key, value in pairs(props) do
		base[key] = value
	end
	return new("TextLabel", base, parent)
end

local function button(parent, props, accent)
	local base = {
		BackgroundColor3 = palette.Navy,
		BackgroundTransparency = 0.1,
		TextColor3 = accent,
		Font = Enum.Font.GothamBlack,
		TextScaled = true,
		AutoButtonColor = true,
	}
	for key, value in pairs(props) do
		base[key] = value
	end
	local b = new("TextButton", base, parent)
	corner(b, 0.25)
	new("UIStroke", { Color = accent, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, b)
	new("UIPadding", { PaddingTop = UDim.new(0.18, 0), PaddingBottom = UDim.new(0.18, 0) }, b)
	return b
end

function HUD.new(input)
	local self = setmetatable({}, HUD)
	self.input = input
	self.maid = Utility.Maid.new()
	self.device = input.device
	self.overlay = nil
	self.toastUntil = 0
	self.perfVisible = GameConfig.Debug.PerfOverlayDefault
	self.frameTimes = {}
	self.frameIndex = 0
	self.perfTimer = 0
	self.lastTimerText = nil
	self.lastSpeedText = nil
	self.PlayPressed = Utility.Signal.new()
	self.TryAgainPressed = Utility.Signal.new()
	self.TutorialSkipped = Utility.Signal.new()
	self.CameraPressed = Utility.Signal.new()

	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

	------------------------------------------------------------------ HUD layer
	local hudGui = new("ScreenGui", {
		Name = "TumbleHUD",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 4,
		Enabled = false,
	}, playerGui)
	pcall(function()
		hudGui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	end)
	self.hudGui = hudGui
	self.maid:Give(hudGui)
	local root = new("Frame", { Name = "Root", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, hudGui)
	self.hudRoot = root
	self.hudScale = new("UIScale", {}, root)

	self.timer = label(root, {
		Name = "Timer",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 6),
		Size = UDim2.fromOffset(280, 62),
		Font = Enum.Font.GothamBlack,
		Text = "0.00",
		TextStrokeTransparency = 0.4,
	})
	self.timerSub = label(root, {
		Name = "TimerSub",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 70),
		Size = UDim2.fromOffset(460, 26),
		TextColor3 = palette.Cyan,
		Text = "",
		TextStrokeTransparency = 0.5,
	})

	local speedFrame = new("Frame", {
		Name = "Speed",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.fromOffset(170, 66),
		BackgroundColor3 = palette.Navy,
		BackgroundTransparency = 0.25,
	}, root)
	corner(speedFrame, 0.3)
	self.speedValue = label(speedFrame, {
		Size = UDim2.new(1, 0, 0.66, 0),
		Font = Enum.Font.GothamBlack,
		Text = "0",
	})
	label(speedFrame, {
		Position = UDim2.fromScale(0, 0.64),
		Size = UDim2.new(1, 0, 0.3, 0),
		TextColor3 = palette.Cyan,
		Font = Enum.Font.Gotham,
		Text = "studs/s",
	})

	self.hint = label(root, {
		Name = "Hint",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.new(0, 14, 1, -14),
		Size = UDim2.fromOffset(470, 22),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextColor3 = palette.White,
		TextTransparency = 0.15,
		Font = Enum.Font.Gotham,
		TextStrokeTransparency = 0.6,
	})

	self.camButton = button(root, {
		Name = "CameraButton",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 8),
		Size = UDim2.fromOffset(150, 44),
		Text = "CAM: CHASE",
	}, palette.Cyan)
	self.maid:Give(self.camButton.Activated:Connect(function()
		self.CameraPressed:Fire()
	end))

	self.resetButton = button(root, {
		Name = "ResetButton",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 60),
		Size = UDim2.fromOffset(150, 44),
		Text = "HOLD: RESET",
		ClipsDescendants = true,
	}, palette.Yellow)
	self.resetFill = new("Frame", {
		Name = "Fill",
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(0, 0.14),
		BackgroundColor3 = palette.Yellow,
		BorderSizePixel = 0,
	}, self.resetButton)
	-- mouse press-and-hold feeds the same 1 s hold as R / Y / touch RESET
	local held = {}
	self.maid:Give(self.resetButton.InputBegan:Connect(function(io)
		if io.UserInputType == Enum.UserInputType.MouseButton1 or io.UserInputType == Enum.UserInputType.Touch then
			held[io] = true
			self.input:SetVirtual("RecoverMouse", true)
		end
	end))
	local function release(io)
		if held[io] then
			held[io] = nil
			if next(held) == nil then
				self.input:SetVirtual("RecoverMouse", false)
			end
		end
	end
	self.maid:Give(self.resetButton.InputEnded:Connect(release))
	self.maid:Give(UserInputService.InputEnded:Connect(release))

	self.toast = label(root, {
		Name = "Toast",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.3),
		Size = UDim2.fromOffset(620, 46),
		TextColor3 = palette.Yellow,
		Font = Enum.Font.GothamBlack,
		TextStrokeTransparency = 0.3,
		Visible = false,
	})

	-- Tutorial card
	local card = new("Frame", {
		Name = "Tutorial",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -100),
		Size = UDim2.fromOffset(600, 156),
		BackgroundColor3 = palette.Navy,
		BackgroundTransparency = 0.1,
		Visible = false,
	}, root)
	corner(card, 0.12)
	new("UIStroke", { Color = palette.Cyan, Thickness = 2 }, card)
	label(card, {
		Position = UDim2.fromOffset(20, 12),
		Size = UDim2.new(1, -150, 0, 34),
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = Enum.Font.GothamBlack,
		TextColor3 = palette.Cyan,
		Text = "STEER THE MARBLE",
	})
	self.tutorialBody = label(card, {
		Position = UDim2.fromOffset(20, 52),
		Size = UDim2.new(1, -40, 0, 48),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextWrapped = true,
		Font = Enum.Font.Gotham,
	})
	self.tutorialLeft = label(card, {
		Position = UDim2.fromOffset(20, 110),
		Size = UDim2.fromOffset(150, 30),
		Font = Enum.Font.GothamBlack,
		TextColor3 = palette.White,
		TextTransparency = 0.5,
		Text = "< LEFT",
	})
	self.tutorialRight = label(card, {
		Position = UDim2.fromOffset(190, 110),
		Size = UDim2.fromOffset(150, 30),
		Font = Enum.Font.GothamBlack,
		TextColor3 = palette.White,
		TextTransparency = 0.5,
		Text = "RIGHT >",
	})
	local skip = button(card, {
		Name = "Skip",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -14, 0, 12),
		Size = UDim2.fromOffset(110, 40),
		Text = "SKIP",
	}, palette.White)
	self.maid:Give(skip.Activated:Connect(function()
		self.TutorialSkipped:Fire()
	end))
	self.tutorial = card

	self.perfLabel = label(root, {
		Name = "Perf",
		Position = UDim2.fromOffset(14, 8),
		Size = UDim2.fromOffset(360, 20),
		TextXAlignment = Enum.TextXAlignment.Left,
		Font = Enum.Font.Code,
		TextColor3 = palette.Mint,
		Text = "measuring...",
		Visible = self.perfVisible,
	})

	------------------------------------------------------------------ Overlay layer
	local overlayGui = new("ScreenGui", {
		Name = "TumbleOverlay",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 10,
		Enabled = true,
	}, playerGui)
	self.overlayGui = overlayGui
	self.maid:Give(overlayGui)
	local dim = new("Frame", {
		Name = "Dim",
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = palette.Ink,
		BackgroundTransparency = 0.25,
		Visible = true,
	}, overlayGui)
	self.dim = dim
	local overlayRoot = new("Frame", { Name = "Root", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, overlayGui)
	self.overlayRoot = overlayRoot
	self.overlayScale = new("UIScale", {}, overlayRoot)

	local function panel(name, height)
		local p = new("Frame", {
			Name = name,
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.5),
			Size = UDim2.fromOffset(720, height),
			BackgroundTransparency = 1,
			Visible = false,
		}, overlayRoot)
		return p
	end

	-- Title
	local title = panel("Title", 420)
	label(title, { Size = UDim2.new(1, 0, 0, 104), Font = Enum.Font.GothamBlack, Text = "TUMBLE CIRCUIT", TextColor3 = palette.Cyan })
	label(title, { Position = UDim2.fromOffset(0, 104), Size = UDim2.new(1, 0, 0, 52), Font = Enum.Font.GothamBlack, Text = "CHAOS DROP", TextColor3 = palette.Violet })
	label(title, { Position = UDim2.fromOffset(0, 168), Size = UDim2.new(1, 0, 0, 28), Font = Enum.Font.Gotham, Text = "Training Chute  -  " .. GameConfig.BuildLabel })
	local play = button(title, {
		Name = "Play",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 232),
		Size = UDim2.fromOffset(340, 84),
		Text = "PLAY PRACTICE",
	}, palette.Mint)
	self.maid:Give(play.Activated:Connect(function()
		self.PlayPressed:Fire()
	end))
	self.titleHint = label(title, { Position = UDim2.fromOffset(0, 330), Size = UDim2.new(1, 0, 0, 24), Font = Enum.Font.Gotham, TextTransparency = 0.3 })
	self.titlePanel = title

	-- Finish
	local finish = panel("Finish", 420)
	label(finish, { Size = UDim2.new(1, 0, 0, 96), Font = Enum.Font.GothamBlack, Text = "FINISH!", TextColor3 = palette.Mint })
	self.finishTime = label(finish, { Position = UDim2.fromOffset(0, 100), Size = UDim2.new(1, 0, 0, 74), Font = Enum.Font.GothamBlack, Text = "0.00" })
	self.finishBest = label(finish, { Position = UDim2.fromOffset(0, 180), Size = UDim2.new(1, 0, 0, 32), Text = "", TextColor3 = palette.Yellow })
	local again = button(finish, {
		Name = "TryAgain",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 240),
		Size = UDim2.fromOffset(320, 80),
		Text = "TRY AGAIN",
	}, palette.Cyan)
	self.maid:Give(again.Activated:Connect(function()
		self.TryAgainPressed:Fire()
	end))
	self.finishHint = label(finish, { Position = UDim2.fromOffset(0, 334), Size = UDim2.new(1, 0, 0, 24), Font = Enum.Font.Gotham, TextTransparency = 0.3 })
	self.finishPanel = finish

	-- Loading / error
	self.message = label(overlayRoot, {
		Name = "Message",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(900, 120),
		TextWrapped = true,
		Font = Enum.Font.GothamBold,
		Visible = false,
	})

	self.maid:Give(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		self:_layout()
	end))
	self:_layout()
	self:SetDevice(self.device)
	return self
end

function HUD:_layout()
	local ui = GameConfig.UI
	local viewport = workspace.CurrentCamera.ViewportSize
	local scale = Utility.clamp(math.min(viewport.X / ui.ReferenceWidth, viewport.Y / ui.ReferenceHeight), ui.MinScale, ui.MaxScale)
	for _, pair in ipairs({ { self.hudRoot, self.hudScale }, { self.overlayRoot, self.overlayScale } }) do
		pair[2].Scale = scale
		pair[1].Size = UDim2.fromScale(1 / scale, 1 / scale)
	end
end

function HUD:SetDevice(device)
	self.device = device
	self.hint.Text = HINTS[device] or ""
	local mouseLayout = device == "KeyboardMouse"
	self.resetButton.Visible = mouseLayout
	self.camButton.Visible = mouseLayout
	self.titleHint.Text = PRIMARY_HINT[device] or ""
	local finishHint = PRIMARY_HINT[device] or ""
	self.finishHint.Text = finishHint
	self.tutorialBody.Text = TUTORIAL_TEXT[device] or TUTORIAL_TEXT.KeyboardMouse
end

function HUD:SetHudVisible(visible)
	self.hudGui.Enabled = visible
end

function HUD:_setOverlay(which)
	self.overlay = which
	self.titlePanel.Visible = which == "Title"
	self.finishPanel.Visible = which == "Finish"
	self.message.Visible = which == "Message"
	self.dim.Visible = which ~= nil
	self.overlayGui.Enabled = which ~= nil
end

function HUD:GetOverlay()
	return self.overlay
end

function HUD:ShowMessage(text, isError)
	self.message.Text = text
	self.message.TextColor3 = isError and palette.Coral or palette.White
	self:_setOverlay("Message")
end

function HUD:ShowTitle()
	self:_setOverlay("Title")
end

function HUD:ShowFinish(seconds, best, isBest)
	self.finishTime.Text = Utility.formatTime(seconds)
	if isBest then
		self.finishBest.Text = "NEW SESSION BEST!"
	elseif best then
		self.finishBest.Text = "Session best  " .. Utility.formatTime(best)
	else
		self.finishBest.Text = ""
	end
	self:_setOverlay("Finish")
end

function HUD:HideOverlay()
	self:_setOverlay(nil)
end

function HUD:ShowTutorial()
	self.tutorialLeft.TextTransparency = 0.5
	self.tutorialRight.TextTransparency = 0.5
	self.tutorialLeft.TextColor3 = palette.White
	self.tutorialRight.TextColor3 = palette.White
	self.tutorial.Visible = true
end

function HUD:UpdateTutorial(leftDone, rightDone)
	self.tutorialLeft.TextTransparency = leftDone and 0 or 0.5
	self.tutorialLeft.TextColor3 = leftDone and palette.Mint or palette.White
	self.tutorialRight.TextTransparency = rightDone and 0 or 0.5
	self.tutorialRight.TextColor3 = rightDone and palette.Mint or palette.White
end

function HUD:HideTutorial()
	self.tutorial.Visible = false
end

function HUD:Toast(text, seconds)
	self.toast.Text = text
	self.toast.Visible = true
	self.toastUntil = os.clock() + (seconds or 2)
end

function HUD:SetCameraMode(mode)
	self.camButton.Text = "CAM: " .. string.upper(mode)
end

function HUD:TogglePerf()
	self.perfVisible = not self.perfVisible
	self.perfLabel.Visible = self.perfVisible
end

-- Frame-time sampling for the F2 overlay (last 240 frames).
function HUD:RecordFrame(dt)
	self.frameIndex = self.frameIndex % 240 + 1
	self.frameTimes[self.frameIndex] = dt
	if not self.perfVisible then
		return
	end
	self.perfTimer = self.perfTimer + dt
	if self.perfTimer < 0.5 then
		return
	end
	self.perfTimer = 0
	local samples = {}
	local total = 0
	for _, t in ipairs(self.frameTimes) do
		samples[#samples + 1] = t
		total = total + t
	end
	if #samples == 0 then
		return
	end
	table.sort(samples)
	local avg = total / #samples
	local p95 = samples[math.max(1, math.ceil(#samples * 0.95))]
	self.perfLabel.Text = string.format("FPS %.0f  avg %.1f ms  p95 %.1f ms  (%d frames)", 1 / avg, avg * 1000, p95 * 1000, #samples)
end

-- state = { speed, runState, runStartServerTime, bestSeconds, lastRunSeconds, recoverProgress }
function HUD:Update(state)
	local timerText
	if state.runState == STATES.Running and state.runStartServerTime and state.runStartServerTime > 0 then
		timerText = Utility.formatTime(workspace:GetServerTimeNow() - state.runStartServerTime)
	elseif state.runState == STATES.Finished and state.lastRunSeconds then
		timerText = Utility.formatTime(state.lastRunSeconds)
	else
		timerText = "0.00"
	end
	if timerText ~= self.lastTimerText then
		self.lastTimerText = timerText
		self.timer.Text = timerText
	end

	local sub
	if state.runState == STATES.Ready then
		sub = "Roll through START to begin the timer"
	elseif state.bestSeconds then
		sub = "Session best  " .. Utility.formatTime(state.bestSeconds)
	else
		sub = ""
	end
	if sub ~= self.lastSubText then
		self.lastSubText = sub
		self.timerSub.Text = sub
	end

	local speedText = tostring(math.floor((state.speed or 0) + 0.5))
	if speedText ~= self.lastSpeedText then
		self.lastSpeedText = speedText
		self.speedValue.Text = speedText
	end

	self.resetFill.Size = UDim2.fromScale(state.recoverProgress or 0, 0.14)

	if self.toast.Visible and os.clock() > self.toastUntil then
		self.toast.Visible = false
	end
end

function HUD:Destroy()
	self.maid:Cleanup()
end

return HUD
