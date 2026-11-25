--[[
	SettingsController (A5) — the Settings modal. Every row is a real, working setting saved in the
	profile (PlayerDataSchema.Settings) through RequestSettings(key, value); the server sanitizes it.
	  Reduced Motion   no FOV pulse, no spin/stars, no fan-disc spin, no flashing colour ramps
	  Camera           Chase / Wide
	  Music / SFX      0-100% (the game ships silent until licensed audio exists; levels are kept)
	  Sensitivity      50-150% steering strength
	  Graphics         Auto / Low (no bloom, fewer effects) / High
	Applied locally at once; the server echo (ProfileState) is the source of truth after a rejoin.
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
}

local function describe(key, value)
	local spec = PlayerDataSchema.Settings[key]
	if spec.kind == "boolean" then
		return value and "ON" or "OFF"
	elseif spec.kind == "enum" then
		return string.upper(tostring(value))
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
	local panel = UIKit.panel(root, { Name = "Settings", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(640, 520), BackgroundTransparency = 0.04 })
	UIKit.new("UIStroke", { Color = palette.Cyan, Thickness = 2 }, panel)
	UIKit.label(panel, { Position = UDim2.fromOffset(24, 14), Size = UDim2.new(1, -150, 0, 44), Font = Enum.Font.GothamBlack, TextColor3 = palette.Cyan, Text = "SETTINGS", TextXAlignment = Enum.TextXAlignment.Left })
	local close = UIKit.button(panel, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -16, 0, 14), Size = UDim2.fromOffset(110, 48), Text = "CLOSE" }, palette.White)
	maid:Give(close.Activated:Connect(function()
		self.CloseRequested:Fire()
	end))
	self.rows = {}
	for i, key in ipairs(PlayerDataSchema.SettingOrder) do
		local y = 72 + (i - 1) * 66
		UIKit.label(panel, { Position = UDim2.fromOffset(24, y + 8), Size = UDim2.fromOffset(300, 40), Text = LABELS[key], TextXAlignment = Enum.TextXAlignment.Left })
		local spec = PlayerDataSchema.Settings[key]
		local value = UIKit.label(panel, { Position = UDim2.fromOffset(410, y + 8), Size = UDim2.fromOffset(120, 40), Font = Enum.Font.GothamBlack, TextColor3 = palette.Yellow })
		local function press(direction)
			local nextValue = SettingsController.Step(key, self.settings[key], direction)
			self:_set(key, nextValue, true)
		end
		if spec.kind == "number" then
			local minus = UIKit.button(panel, { Position = UDim2.fromOffset(340, y), Size = UDim2.fromOffset(60, 56), Text = "-" }, palette.Cyan)
			local plus = UIKit.button(panel, { Position = UDim2.fromOffset(540, y), Size = UDim2.fromOffset(60, 56), Text = "+" }, palette.Cyan)
			maid:Give(minus.Activated:Connect(function()
				press(-1)
			end))
			maid:Give(plus.Activated:Connect(function()
				press(1)
			end))
		else
			local toggle = UIKit.button(panel, { Position = UDim2.fromOffset(340, y), Size = UDim2.fromOffset(260, 56), Text = "" }, palette.Cyan)
			value.Parent = toggle
			value.Position = UDim2.fromScale(0, 0)
			value.Size = UDim2.fromScale(1, 1)
			maid:Give(toggle.Activated:Connect(function()
				press(1)
			end))
		end
		self.rows[key] = value
	end
	self.note = UIKit.label(panel, { Position = UDim2.fromOffset(24, 470), Size = UDim2.new(1, -48, 0, 30), Font = Enum.Font.Gotham, TextColor3 = palette.White, TextTransparency = 0.25, Text = "This build has no music or sound files yet - your levels are saved for when it does." })
	self:_render()
	return self
end

function SettingsController:SetVisible(visible)
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
		if clean ~= nil and clean ~= self.settings[key] and not self.pending[key] and not recent then
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
