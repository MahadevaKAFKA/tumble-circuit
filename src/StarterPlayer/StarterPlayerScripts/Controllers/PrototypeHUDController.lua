--[[
	PrototypeHUDController — the A1 overlay. Every visible button does something.

	HUD (safe-area, scaled from a 1280x720 reference):
	  bottom centre speed (studs/s)
	  top right    CAM toggle and hold-to-RESET (mouse/keyboard layout only; touch has its own)
	  bottom left  device-specific control hint (keyboard / gamepad)
	  centre       toast messages, one skippable steering tutorial card
	  top left     frame-time overlay (FPS, p95, worst frame, memory, ping) + the last hitches
	               (frames longer than GameConfig.Debug.HitchThresholdSeconds, with where they
	               happened); F2 toggles it, GameConfig.Debug.PerfOverlayDefault sets the default
	Overlay (full screen, above everything): title / Play, loading and fatal-error messages.
	Race timer, placement, countdown and results live in RaceHUDController / MatchUIController (A2).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Stats = game:GetService("Stats")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local Utility = require(Shared:WaitForChild("Utility"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local HUD = {}
HUD.__index = HUD

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
	self.hitches = {}
	self.lastSpeedText = nil
	self.PlayPressed = Utility.Signal.new()
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

	local speedFrame
	speedFrame = new("Frame", {
		Name = "Speed",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -14),
		Size = UDim2.fromOffset(150, 58),
		BackgroundColor3 = UIKit.Colors.Surface,
		BackgroundTransparency = 0.4,
	}, root)
	self.speedFrame = speedFrame
	new("UICorner", { CornerRadius = UDim.new(0, 6) }, speedFrame)
	-- v2: the speed in the display face, unit small and muted
	self.speedValue = label(speedFrame, {
		Position = UDim2.fromScale(0, 0.08),
		Size = UDim2.new(1, 0, 0.56, 0),
		Font = UIKit.Fonts.Display or Enum.Font.GothamBlack,
		Text = "0",
	})
	label(speedFrame, {
		Position = UDim2.fromScale(0, 0.66),
		Size = UDim2.new(1, 0, 0.24, 0),
		TextColor3 = UIKit.Colors.Muted,
		Font = UIKit.Fonts.Bold or Enum.Font.GothamBold,
		Text = "STUDS/S", -- the raw Roblox unit until a km/h conversion is measured (brief 3)
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
	UIKit.LaneJoin(self.toast, 1)

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
		Size = UDim2.fromOffset(560, 60),
		AutomaticSize = Enum.AutomaticSize.Y,
		TextScaled = false,
		TextSize = 15,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Font = Enum.Font.Code,
		TextColor3 = palette.Mint,
		BackgroundColor3 = palette.Ink,
		BackgroundTransparency = 0.45,
		Text = "measuring...",
		Visible = self.perfVisible,
	})
	new("UIPadding", { PaddingLeft = UDim.new(0, 6), PaddingTop = UDim.new(0, 3) }, self.perfLabel)

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
	label(title, { Position = UDim2.fromOffset(0, 168), Size = UDim2.new(1, 0, 0, 28), Font = Enum.Font.Gotham, Text = "Orbital Garage  -  " .. GameConfig.BuildLabel })
	local play = button(title, {
		Name = "Play",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 232),
		Size = UDim2.fromOffset(340, 84),
		Text = "PLAY",
	}, palette.Mint)
	self.maid:Give(play.Activated:Connect(function()
		self.PlayPressed:Fire()
	end))
	self.titleHint = label(title, { Position = UDim2.fromOffset(0, 330), Size = UDim2.new(1, 0, 0, 24), Font = Enum.Font.Gotham, TextTransparency = 0.3 })
	self.titlePanel = title

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
	self.tutorialBody.Text = TUTORIAL_TEXT[device] or TUTORIAL_TEXT.KeyboardMouse
end

function HUD:SetHudVisible(visible)
	self.hudGui.Enabled = visible
end

function HUD:_setOverlay(which)
	self.overlay = which
	self.titlePanel.Visible = which == "Title"
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
	if not self.toast.Visible then
		self.toast.Visible = true
		if not UIKit.LaneClaim(self.toast) then
			return
		end
		UIKit.Enter(self.toast, "FromBelow", 0.2)
	else
		UIKit.Punch(self.toast, 1.08, 0.18) -- a new message while one is showing
	end
	self.toastUntil = os.clock() + (seconds or 2)
end

function HUD:SetCameraMode(mode)
	self.camButton.Text = "CAM: " .. string.upper(mode)
end

function HUD:TogglePerf()
	self.perfVisible = not self.perfVisible
	self.perfLabel.Visible = self.perfVisible
end

-- UI overhaul: the developer frame-time overlay (Settings, developers only) and HUD density
function HUD:SetPerfVisible(visible)
	self.perfVisible = visible == true
	self.perfLabel.Visible = self.perfVisible
end

-- v2: the speed readout only where speed matters (the race zone)
function HUD:SetSpeedAllowed(allowed)
	if self.speedAllowed ~= allowed then
		self.speedAllowed = allowed
		if self.speedFrame then
			self.speedFrame.Visible = self.density ~= "Compact" and allowed ~= false
		end
	end
end

function HUD:SetDensity(density)
	self.density = density
	if self.speedFrame then
		self.speedFrame.Visible = density ~= "Compact" and self.speedAllowed ~= false
	end
end

-- A frame longer than GameConfig.Debug.HitchThresholdSeconds. `where` says where the marble was.
-- The newest three are shown on the overlay's second line.
function HUD:RecordHitch(seconds, where)
	table.insert(self.hitches, 1, string.format("%.2fs %s", seconds, where))
	if #self.hitches > 3 then
		table.remove(self.hitches)
	end
	self.perfTimer = math.huge -- refresh the overlay on this frame
end

-- Frame-time sampling for the overlay (last 240 frames).
-- Baseline audit (2026-11-26): seconds from losing your marble to controlling the next one,
-- shown on the overlay so a phone screenshot carries it. Presentation only.
function HUD:NoteRespawn(seconds)
	if type(seconds) == "number" and seconds >= 0 and seconds < 60 then
		self.lastRespawnSeconds = seconds
	end
end

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
	local worst = samples[#samples]
	local okMem, memMb = pcall(function()
		return Stats:GetTotalMemoryUsageMb()
	end)
	local okPing, ping = pcall(function()
		return Players.LocalPlayer:GetNetworkPing()
	end)
	local function attr(name)
		local value = workspace:GetAttribute(name)
		return type(value) == "number" and value or -1
	end
	local okInst, instances = pcall(function()
		return Stats.InstanceCount
	end)
	local line1 = string.format(
		"FPS %.0f  p95 %.0f ms  worst %.0f ms  mem %s  ping %s  inst %s  respawn %s",
		1 / avg,
		p95 * 1000,
		worst * 1000,
		okMem and string.format("%.0f MB", memMb) or "?",
		okPing and string.format("%.0f ms", ping * 1000) or "?",
		okInst and tostring(instances) or "?",
		self.lastRespawnSeconds and string.format("%.1f s", self.lastRespawnSeconds) or "-"
	)
	-- A4 PerfService publishes the server's numbers as workspace attributes every 2 s.
	local line2 = string.format(
		"SERVER %.0f/%.0f ms  phys %.1f ms  moving %d  marbles %d (bots %d)  inst %d",
		attr("Perf_ServerFrameAvgMs"),
		attr("Perf_ServerFrameP95Ms"),
		attr("Perf_PhysicsStepMs"),
		attr("Perf_MovingParts"),
		attr("Perf_Marbles"),
		attr("Perf_Bots"),
		attr("Perf_Instances")
	)
	local line3 = #self.hitches > 0 and ("hitches: " .. table.concat(self.hitches, " | ")) or "hitches: none"
	local text = line1 .. "\n" .. line2 .. "\n" .. line3
	-- bot diagnostics from BotService (owner report 2026-11-25: bots vanished at GO)
	local bots = workspace:GetAttribute("Bots_Status")
	if type(bots) == "string" and bots ~= "" then
		text = text .. "\nBOTS " .. bots
		local botError = workspace:GetAttribute("Bots_LastError")
		if type(botError) == "string" and botError ~= "" then
			text = text .. "\nBOT ERROR " .. botError
		end
	end
	self.perfLabel.Text = text
end

-- state = { speed, recoverProgress }
function HUD:Update(state)
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
