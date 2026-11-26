--[[
	SettingsController (A5) — the Settings modal. Every row is a real, working setting saved in the
	profile (PlayerDataSchema.Settings) through RequestSettings(key, value); the server sanitizes it.
	  Reduced Motion   no FOV pulse, no spin/stars, no fan-disc spin, no flashing colour ramps
	  Camera           Chase / Wide
	  Music / SFX      0-100% (the game ships silent until licensed audio exists; levels are kept)
	  Sensitivity      50-150% steering strength
	  Graphics         Auto / Low (no bloom, fewer effects) / High
	Applied locally at once; the server echo (ProfileState) is the source of truth after a rejoin.
	UI overhaul (2026-11-26): a second DISPLAY tab - HUD size, panel opacity, HUD density, UI
	accent, high contrast, control layout, scenery detail (+ the frame-time overlay for
	developers only) - and RESET DISPLAY, which previews the defaults live with KEEP / UNDO.
	Closing Settings during a preview undoes it (nothing is saved until KEEP).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local PlayerDataSchema = require(Shared:WaitForChild("PlayerDataSchema"))
local Utility = require(Shared:WaitForChild("Utility"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local SettingsController = {}
SettingsController.__index = SettingsController

local palette = UIKit.Palette
local LABELS = {
	reducedMotion = "REDUCED MOTION",
	cameraMode = "CAMERA",
	music = "MUSIC",
	sfx = "SOUND EFFECTS",
	sensitivity = "STEERING SENSITIVITY",
	graphicsMode = "GRAPHICS",
	muteEmotes = "MUTE QUICK EMOTES",
	hudScale = "HUD SIZE",
	panelOpacity = "PANEL OPACITY",
	hudDensity = "HUD DENSITY",
	uiAccent = "UI ACCENT",
	highContrast = "HIGH CONTRAST",
	controlLayout = "CONTROL LAYOUT",
	sceneryDetail = "SCENERY DETAIL",
	perfOverlay = "FRAME-TIME OVERLAY (DEV)",
}
local VALUE_TEXT = { FollowMap = "FOLLOW MAP", LeftHanded = "LEFT-HANDED" }

local function describe(key, value)
	local spec = PlayerDataSchema.Settings[key]
	if spec.kind == "boolean" then
		return value and "ON" or "OFF"
	elseif spec.kind == "enum" then
		return VALUE_TEXT[value] or string.upper(tostring(value))
	end
	return string.format("%d%%", math.floor(value * 100 + 0.5))
end

-- Pure: the next value when a row's - / + (or toggle) is pressed.
function SettingsController.Step(key, value, direction)
	local spec = PlayerDataSchema.Settings[key]
	if spec.kind == "boolean" then
		return not value
	elseif spec.kind == "enum" then
		local index = 1
		for i, v in ipairs(spec.values) do
			if v == value then
				index = i
			end
		end
		return spec.values[(index - 1 + direction) % #spec.values + 1]
	end
	return PlayerDataSchema.SanitizeSetting(key, value + spec.step * direction)
end

function SettingsController.new(deps)
	local self = setmetatable({}, SettingsController)
	self.remotes = deps.remotes
	self.settings = PlayerDataSchema.DefaultSettings()
	self.pending = {} -- key -> true while a local change waits to be sent (latest value wins)
	self.queue = {}
	self.lastSent = {} -- key -> os.clock() of the last send (ignore stale echoes briefly)
	self.Changed = Utility.Signal.new() -- (settings)
	self.CloseRequested = Utility.Signal.new()
	local gui, root, maid = UIKit.screen("TumbleSettings", 20)
	self.gui, self.maid = gui, maid
	gui.Enabled = false
	local panel = UIKit.panel(root, { Name = "Settings", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(680, 580), BackgroundTransparency = 0.04 })
	UIKit.new("UIStroke", { Color = palette.Cyan, Thickness = 2 }, panel)
	UIKit.label(panel, { Position = UDim2.fromOffset(24, 14), Size = UDim2.new(1, -150, 0, 44), Font = Enum.Font.GothamBlack, TextColor3 = palette.Cyan, Text = "SETTINGS", TextXAlignment = Enum.TextXAlignment.Left })
	local close = UIKit.button(panel, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -16, 0, 14), Size = UDim2.fromOffset(110, 48), Text = "CLOSE" }, palette.White)
	maid:Give(close.Activated:Connect(function()
		self.CloseRequested:Fire()
	end))
	self.rows = {}
	self.tabs = {}
	self.showDev = deps.showDev == true
	-- tabs: GAME (A5 rows) and DISPLAY (UI overhaul rows)
	local function tabButton(name, x, text)
		local b = UIKit.button(panel, { Name = "SettingsTab", Position = UDim2.fromOffset(x, 66), Size = UDim2.fromOffset(150, 42), Text = text }, palette.Cyan)
		maid:Give(b.Activated:Connect(function()
			self:ShowTab(name)
		end))
		return b
	end
	self.tabButtons = { Game = tabButton("Game", 24, "GAME"), Display = tabButton("Display", 184, "DISPLAY") }
	local function buildTab(name, order)
		local page = UIKit.new("Frame", { Name = name, BackgroundTransparency = 1, Position = UDim2.fromOffset(0, 116), Size = UDim2.new(1, 0, 1, -170) }, panel)
		self.tabs[name] = page
		local y = 0
		for _, key in ipairs(order) do
			if key ~= "perfOverlay" or self.showDev then
				self:_row(page, key, y)
				y = y + 50
			end
		end
	end
	buildTab("Game", PlayerDataSchema.SettingOrder)
	buildTab("Display", PlayerDataSchema.DisplaySettingOrder)
	-- RESET DISPLAY -> live preview of the defaults, then KEEP / UNDO
	self.resetButton = UIKit.button(panel, { Name = "SettingsReset", Position = UDim2.new(0, 24, 1, -52), Size = UDim2.fromOffset(240, 42), Text = "RESET DISPLAY" }, palette.Yellow)
	self.keepButton = UIKit.button(panel, { Name = "SettingsReset", Position = UDim2.new(0, 24, 1, -52), Size = UDim2.fromOffset(200, 42), Text = "KEEP DEFAULTS", Visible = false }, palette.Mint)
	self.undoButton = UIKit.button(panel, { Name = "SettingsReset", Position = UDim2.new(0, 234, 1, -52), Size = UDim2.fromOffset(130, 42), Text = "UNDO", Visible = false }, palette.Coral)
	maid:Give(self.resetButton.Activated:Connect(function()
		self:PreviewReset()
	end))
	maid:Give(self.keepButton.Activated:Connect(function()
		self:KeepReset()
	end))
	maid:Give(self.undoButton.Activated:Connect(function()
		self:UndoReset()
	end))
	self.note = UIKit.label(panel, { Position = UDim2.new(0, 380, 1, -50), Size = UDim2.new(1, -400, 0, 38), Font = Enum.Font.Gotham, TextColor3 = palette.White, TextTransparency = 0.25, TextWrapped = true, Text = "" })
	self:ShowTab("Game")
	self:_render()
	return self
end

function SettingsController:_row(page, key, y)
	local maid = self.maid
	UIKit.label(page, { Position = UDim2.fromOffset(24, y + 6), Size = UDim2.fromOffset(330, 34), Text = LABELS[key] or key, TextXAlignment = Enum.TextXAlignment.Left })
	local spec = PlayerDataSchema.Settings[key]
	local value = UIKit.label(page, { Position = UDim2.fromOffset(430, y + 6), Size = UDim2.fromOffset(120, 34), Font = Enum.Font.GothamBlack, TextColor3 = palette.Yellow })
	local function press(direction)
		local nextValue = SettingsController.Step(key, self.settings[key], direction)
		self:_set(key, nextValue, true)
	end
	if spec.kind == "number" then
		local minus = UIKit.button(page, { Name = "SettingToggle", Position = UDim2.fromOffset(360, y), Size = UDim2.fromOffset(60, 46), Text = "-" }, palette.Cyan)
		local plus = UIKit.button(page, { Name = "SettingToggle", Position = UDim2.fromOffset(560, y), Size = UDim2.fromOffset(60, 46), Text = "+" }, palette.Cyan)
		self.firstButton = self.firstButton or minus
		maid:Give(minus.Activated:Connect(function()
			press(-1)
		end))
		maid:Give(plus.Activated:Connect(function()
			press(1)
		end))
	else
		local toggle = UIKit.button(page, { Name = "SettingToggle", Position = UDim2.fromOffset(360, y), Size = UDim2.fromOffset(260, 46), Text = "" }, palette.Cyan)
		self.firstButton = self.firstButton or toggle
		value.Parent = toggle
		value.Position = UDim2.fromScale(0, 0)
		value.Size = UDim2.fromScale(1, 1)
		maid:Give(toggle.Activated:Connect(function()
			press(1)
		end))
	end
	self.rows[key] = value
end

function SettingsController:ShowTab(name)
	self.tab = name
	for tabName, page in pairs(self.tabs) do
		page.Visible = tabName == name
	end
	for tabName, button in pairs(self.tabButtons) do
		button.BackgroundTransparency = tabName == name and 0 or 0.6
	end
	self.resetButton.Visible = name == "Display" and self.preview == nil
	self.note.Text = name == "Game" and "No music or sound files yet - your levels are saved for when they arrive." or "Display settings change only your screen. They are saved to your profile."
end

-- Pure: which display keys a reset changes (current values that differ from the defaults)
function SettingsController.ResetPlan(settings)
	local plan = {}
	for _, key in ipairs(PlayerDataSchema.DisplaySettingOrder) do
		local default = PlayerDataSchema.Settings[key].default
		if settings[key] ~= default then
			plan[key] = default
		end
	end
	return plan
end

function SettingsController:PreviewReset()
	if self.preview then
		return
	end
	local plan = SettingsController.ResetPlan(self.settings)
	if next(plan) == nil then
		self.note.Text = "Display settings are already at their defaults."
		return
	end
	local before = {}
	for key, value in pairs(plan) do
		before[key] = self.settings[key]
		self.settings[key] = value -- local preview only: nothing is sent yet
	end
	self.preview = before
	self:_render()
	self.Changed:Fire(self.settings)
	self.resetButton.Visible = false
	self.keepButton.Visible = true
	self.undoButton.Visible = true
	self.note.Text = "Previewing the default layout. KEEP saves it, UNDO restores yours."
end

function SettingsController:KeepReset()
	local before = self.preview
	if not before then
		return
	end
	self.preview = nil
	for key in pairs(before) do
		self:_queueSend(key)
	end
	self.keepButton.Visible, self.undoButton.Visible = false, false
	self:ShowTab(self.tab or "Display")
end

function SettingsController:UndoReset()
	local before = self.preview
	if not before then
		return
	end
	self.preview = nil
	for key, value in pairs(before) do
		self.settings[key] = value
	end
	self:_render()
	self.Changed:Fire(self.settings)
	self.keepButton.Visible, self.undoButton.Visible = false, false
	self:ShowTab(self.tab or "Display")
end

function SettingsController:GetFirstButton()
	return self.firstButton
end

function SettingsController:SetVisible(visible)
	if not visible and self.preview then
		self:UndoReset() -- closing during a reset preview keeps the player's own settings
	end
	self.gui.Enabled = visible
end

function SettingsController:_set(key, value, send)
	self.settings[key] = value
	self:_render()
	self.Changed:Fire(self.settings)
	if send then
		self:_queueSend(key)
	end
end

-- Changes are sent one key at a time, at most every 0.25 s (the server rate-limits to 0.15 s),
-- always with the LATEST value, so fast tapping never loses the final choice.
function SettingsController:_queueSend(key)
	if not self.pending[key] then
		self.pending[key] = true
		table.insert(self.queue, key)
	end
	if self.sending then
		return
	end
	self.sending = true
	task.spawn(function()
		task.wait(0.25)
		while #self.queue > 0 do
			local nextKey = table.remove(self.queue, 1)
			self.pending[nextKey] = nil -- a change from now on queues a fresh send
			self.lastSent[nextKey] = os.clock()
			local value = self.settings[nextKey]
			local wire = type(value) == "boolean" and tostring(value) or (type(value) == "number" and string.format("%.2f", value) or tostring(value))
			self.remotes.RequestSettings:FireServer(nextKey, wire)
			task.wait(0.25)
		end
		self.sending = false
	end)
end

-- A setting changed elsewhere (e.g. the CAM button): apply locally and save it.
function SettingsController:SetLocal(key, value)
	local clean = PlayerDataSchema.SanitizeSetting(key, value)
	if clean ~= nil and clean ~= self.settings[key] then
		self:_set(key, clean, true)
	end
end

-- From ProfileState (server truth) - applies without echoing back.
function SettingsController:ApplyServer(settings)
	if type(settings) ~= "table" then
		return
	end
	local changed = false
	for key in pairs(PlayerDataSchema.Settings) do
		local clean = PlayerDataSchema.SanitizeSetting(key, settings[key])
		local recent = self.lastSent[key] and os.clock() - self.lastSent[key] < 0.6
		local previewing = self.preview ~= nil and self.preview[key] ~= nil
		if clean ~= nil and clean ~= self.settings[key] and not self.pending[key] and not recent and not previewing then
			self.settings[key] = clean
			changed = true
		end
	end
	if changed then
		self:_render()
		self.Changed:Fire(self.settings)
	end
end

function SettingsController:Get()
	return self.settings
end

function SettingsController:_render()
	for key, label in pairs(self.rows) do
		UIKit.setText(label, describe(key, self.settings[key]))
	end
end

function SettingsController:Destroy()
	self.maid:Cleanup()
end

return SettingsController
