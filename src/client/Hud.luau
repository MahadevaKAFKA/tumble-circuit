-- On-screen HUD: run timer, checkpoint progress, finish banner and the
-- RESPAWN / RESTART buttons. Sized for phones (large touch targets, scales
-- with the screen) and kept clear of the default thumbstick (bottom-left) and
-- jump button (bottom-right).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CourseData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CourseData"))

local player = Players.LocalPlayer

local Hud = {}

local PANEL = Color3.fromRGB(20, 24, 34)
local WHITE = Color3.fromRGB(255, 255, 255)
local SOFT = Color3.fromRGB(200, 210, 225)
local GREEN = Color3.fromRGB(60, 220, 130)
local GOLD = Color3.fromRGB(255, 205, 60)
local STRIP_IDLE = Color3.fromRGB(150, 160, 175)
local STRIP_REACHED = Color3.fromRGB(0, 255, 140)

local function create(className, properties, parent)
	local instance = Instance.new(className)
	for key, value in pairs(properties) do
		instance[key] = value
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

local function rounded(parent, radius)
	create("UICorner", { CornerRadius = UDim.new(0, radius) }, parent)
end

function Hud.formatTime(seconds)
	if type(seconds) ~= "number" or seconds ~= seconds or seconds < 0 then
		seconds = 0
	end
	local minutes = math.floor(seconds / 60)
	local rest = seconds - minutes * 60
	return string.format("%d:%05.2f", minutes, rest)
end

local function recolorStrips(reached)
	local course = Workspace:FindFirstChild("Course")
	local markers = course and course:FindFirstChild("Markers")
	if not markers then
		return
	end
	for _, part in ipairs(markers:GetChildren()) do
		local index = part:GetAttribute("CheckpointIndex")
		if type(index) == "number" and part:IsA("BasePart") then
			if index <= reached then
				part.Color = STRIP_REACHED
			else
				part.Color = STRIP_IDLE
			end
		end
	end
end

function Hud.start(callbacks)
	local playerGui = player:WaitForChild("PlayerGui")
	local touch = UserInputService.TouchEnabled
	local keyboard = UserInputService.KeyboardEnabled

	local gui = create("ScreenGui", {
		Name = "TumbleHud",
		ResetOnSpawn = false,
		IgnoreGuiInset = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})

	-- Timer panel (top centre)
	local top = create("Frame", {
		Name = "TopPanel",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 6),
		Size = UDim2.new(0, 300, 0, 74),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.3,
		BorderSizePixel = 0,
	}, gui)
	rounded(top, 12)
	local topScale = create("UIScale", { Scale = 1 }, top)

	local timer = create("TextLabel", {
		Name = "Timer",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 10, 0, 4),
		Size = UDim2.new(1, -20, 0, 42),
		Font = Enum.Font.GothamBold,
		Text = "0:00.00",
		TextColor3 = WHITE,
		TextScaled = true,
	}, top)

	local status = create("TextLabel", {
		Name = "Status",
		BackgroundTransparency = 1,
		Position = UDim2.new(0, 10, 0, 48),
		Size = UDim2.new(1, -20, 0, 20),
		Font = Enum.Font.Gotham,
		Text = "",
		TextColor3 = SOFT,
		TextScaled = true,
	}, top)

	-- Banner under the timer for checkpoint / finish messages
	local banner = create("TextLabel", {
		Name = "Banner",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, 88),
		Size = UDim2.new(0, 340, 0, 40),
		BackgroundColor3 = PANEL,
		BackgroundTransparency = 0.25,
		BorderSizePixel = 0,
		Font = Enum.Font.GothamBold,
		Text = "",
		TextColor3 = GREEN,
		TextScaled = true,
		Visible = false,
	}, gui)
	rounded(banner, 10)
	create("UIPadding", {
		PaddingLeft = UDim.new(0, 10),
		PaddingRight = UDim.new(0, 10),
		PaddingTop = UDim.new(0, 4),
		PaddingBottom = UDim.new(0, 4),
	}, banner)
	local bannerScale = create("UIScale", { Scale = 1 }, banner)

	-- Buttons (right edge, upper half: away from the jump button)
	local buttons = create("Frame", {
		Name = "Buttons",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -10, 0.2, 0),
		Size = UDim2.new(0, 136, 0, 114),
		BackgroundTransparency = 1,
	}, gui)
	create("UIListLayout", {
		Padding = UDim.new(0, 10),
		SortOrder = Enum.SortOrder.LayoutOrder,
		HorizontalAlignment = Enum.HorizontalAlignment.Right,
	}, buttons)
	local buttonScale = create("UIScale", { Scale = 1 }, buttons)

	local function makeButton(name, text, order, color)
		local button = create("TextButton", {
			Name = name,
			LayoutOrder = order,
			Size = UDim2.new(1, 0, 0, 52),
			BackgroundColor3 = color,
			BackgroundTransparency = 0.15,
			BorderSizePixel = 0,
			AutoButtonColor = true,
			Font = Enum.Font.GothamBold,
			Text = text,
			TextColor3 = WHITE,
			TextScaled = true,
		}, buttons)
		rounded(button, 12)
		create("UIPadding", {
			PaddingLeft = UDim.new(0, 8),
			PaddingRight = UDim.new(0, 8),
			PaddingTop = UDim.new(0, 10),
			PaddingBottom = UDim.new(0, 10),
		}, button)
		return button
	end

	local respawnButton = makeButton("Respawn", "RESPAWN", 1, Color3.fromRGB(40, 110, 200))
	local restartButton = makeButton("Restart", "RESTART", 2, Color3.fromRGB(200, 70, 60))

	local lastPress = 0
	local function guarded(callback)
		return function()
			local now = os.clock()
			if now - lastPress < 0.3 then
				return
			end
			lastPress = now
			if callback then
				callback()
			end
		end
	end
	respawnButton.Activated:Connect(guarded(callbacks and callbacks.onReset))
	restartButton.Activated:Connect(guarded(callbacks and callbacks.onRestart))

	-- Keyboard hint (only when there is a keyboard and no touch screen)
	create("TextLabel", {
		Name = "KeyboardHint",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -8),
		Size = UDim2.new(0, 560, 0, 22),
		BackgroundTransparency = 1,
		Font = Enum.Font.Gotham,
		Text = "WASD roll  |  Space jump  |  R respawn  |  T restart  |  drag right mouse to look",
		TextColor3 = SOFT,
		TextStrokeTransparency = 0.5,
		TextScaled = true,
		Visible = keyboard and not touch,
	}, gui)

	gui.Parent = playerGui

	-- Scale panels with the screen so they stay readable on phones and tablets.
	local function rescale()
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end
		local size = camera.ViewportSize
		local shortest = math.min(size.X, size.Y)
		if shortest <= 0 then
			return
		end
		local scale = math.clamp(shortest / 400, 0.8, 1.5)
		topScale.Scale = scale
		bannerScale.Scale = scale
		buttonScale.Scale = scale
		-- Keep the banner just below the (scaled) timer panel.
		banner.Position = UDim2.new(0.5, 0, 0, math.floor(6 + 74 * scale + 8))
	end
	rescale()
	local function watchCamera()
		local camera = Workspace.CurrentCamera
		if camera then
			camera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
		end
		rescale()
	end
	watchCamera()
	Workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)

	local bannerToken = 0
	local function showBanner(text, color, seconds)
		bannerToken += 1
		local token = bannerToken
		banner.Text = text
		banner.TextColor3 = color
		banner.Visible = true
		if seconds then
			task.delay(seconds, function()
				if bannerToken == token then
					banner.Visible = false
				end
			end)
		end
	end

	local lastCheckpoint = player:GetAttribute("Checkpoint") or 1
	recolorStrips(lastCheckpoint)
	player:GetAttributeChangedSignal("Checkpoint"):Connect(function()
		local index = player:GetAttribute("Checkpoint") or 1
		if index > lastCheckpoint then
			local checkpoint = CourseData.Checkpoints[index]
			local name = (checkpoint and checkpoint.Name) or ("#" .. tostring(index))
			showBanner("Checkpoint: " .. name, GREEN, 1.6)
		end
		lastCheckpoint = index
		recolorStrips(index)
	end)

	player:GetAttributeChangedSignal("RunState"):Connect(function()
		local runState = player:GetAttribute("RunState")
		if runState == "Finished" then
			local text = "FINISH!  " .. Hud.formatTime(player:GetAttribute("LastTime"))
			local best = player:GetAttribute("BestTime")
			if type(best) == "number" and best > 0 and best >= (player:GetAttribute("LastTime") or 0) then
				text = text .. "  (best)"
			end
			showBanner(text, GOLD, nil)
		else
			bannerToken += 1
			banner.Visible = false
		end
	end)

	local restartHint = "Tap RESTART to go again"
	if keyboard and not touch then
		restartHint = "Press T to go again"
	end

	RunService.RenderStepped:Connect(function()
		local runState = player:GetAttribute("RunState") or "Ready"
		local checkpoint = player:GetAttribute("Checkpoint") or 1
		local count = player:GetAttribute("CheckpointCount") or #CourseData.Checkpoints
		local best = player:GetAttribute("BestTime")
		local line
		if runState == "Running" then
			local startedAt = player:GetAttribute("RunStartTime") or 0
			timer.Text = Hud.formatTime(Workspace:GetServerTimeNow() - startedAt)
			line = string.format("Checkpoint %d/%d", checkpoint, count)
		elseif runState == "Finished" then
			timer.Text = Hud.formatTime(player:GetAttribute("LastTime"))
			line = restartHint
		else
			timer.Text = Hud.formatTime(0)
			line = "Roll off the start pad to begin"
		end
		if type(best) == "number" and best > 0 then
			line = line .. "  |  Best " .. Hud.formatTime(best)
		end
		status.Text = line
	end)

	return gui
end

return Hud
