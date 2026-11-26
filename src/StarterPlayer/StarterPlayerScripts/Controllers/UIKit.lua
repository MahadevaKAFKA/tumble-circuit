--[[
	UIKit — tiny shared UI helpers for the A2+ controllers: instance builder, labels, buttons and
	a safe-area ScreenGui with a UIScale'd root (1280x720 reference, clamped like the A1 HUD).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local Utility = require(Shared:WaitForChild("Utility"))

local UIKit = {}
local palette = GameConfig.Palette
UIKit.Palette = palette

---------------------------------------------------------------------------------------------
-- UI overhaul (2026-11-26): one presentation style for every UIKit screen, driven by the
-- player's Settings (HUD size, panel opacity, accent, high contrast). Pure data + registries;
-- ApplyStyle updates everything already built, new widgets pick the current style up.
---------------------------------------------------------------------------------------------
UIKit.Accents = {
	Cyan = palette.Cyan,
	Amber = Color3.fromHex("#FFBD5D"),
	Violet = palette.Violet,
	Neutral = Color3.fromHex("#D8DEE9"),
}
-- FollowMap: each map's primary accent (MapRegistry ids); unknown maps use cyan
UIKit.MapAccents = {
	NeonFoundry_A4 = palette.Cyan,
	SkyCarnival_B1 = Color3.fromHex("#F08BAE"),
	VolcanoVault_B1 = Color3.fromHex("#FFBD5D"),
}
UIKit.Style = { scale = 1, opacity = 0.95, accent = palette.Cyan, contrast = false }
UIKit.DefaultOpacity = 0.95

-- Pure: transparency of a panel whose designed transparency is `base` at opacity `opacity`.
function UIKit.PanelTransparency(base, opacity)
	local designed = 1 - (base or 0.05)
	local t = 1 - designed * ((opacity or UIKit.DefaultOpacity) / UIKit.DefaultOpacity)
	return math.clamp(t, 0, 1)
end

-- Pure: settings table -> style (accent resolved for the map you are on)
function UIKit.StyleFromSettings(settings, mapId)
	settings = settings or {}
	local accent = UIKit.Accents[settings.uiAccent or ""]
	if not accent then
		accent = UIKit.MapAccents[mapId or ""] or palette.Cyan
	end
	return {
		scale = math.clamp(tonumber(settings.hudScale) or 1, 0.85, 1.25),
		opacity = math.clamp(tonumber(settings.panelOpacity) or UIKit.DefaultOpacity, 0.75, 1),
		accent = accent,
		contrast = settings.highContrast == true,
	}
end

local registry = { layouts = {}, panels = {}, accents = {}, labels = {} }
local function alive(inst)
	return inst ~= nil and inst.Parent ~= nil
end

local function styleLabel(label, base)
	label.TextStrokeTransparency = UIKit.Style.contrast and math.min(base, 0.25) or base
end

-- High contrast: darker, opaque-er panel + a thicker edge (the panel's own stroke if it has one,
-- otherwise a white one we add). One UIStroke per panel, never two.
local function stylePanel(frame, info)
	local contrast = UIKit.Style.contrast
	local t = UIKit.PanelTransparency(info.base, UIKit.Style.opacity)
	frame.BackgroundTransparency = contrast and math.min(t, 0.02) or t
	frame.BackgroundColor3 = contrast and palette.Ink or info.color
	local stroke = frame:FindFirstChildOfClass("UIStroke")
	if stroke and stroke.Name ~= "HighContrast" then
		if info.strokeBase == nil then
			info.strokeBase = tonumber(stroke.Thickness) or 2
		end
		stroke.Thickness = contrast and math.max(info.strokeBase, 3) or info.strokeBase
	elseif contrast and not stroke then
		UIKit.new("UIStroke", { Name = "HighContrast", Color = palette.White, Thickness = 1.5, Transparency = 0.1 }, frame)
	elseif not contrast and stroke then
		stroke:Destroy()
	end
end

function UIKit.ApplyStyle(style)
	for key, value in pairs(style or {}) do
		UIKit.Style[key] = value
	end
	for i = #registry.layouts, 1, -1 do
		local entry = registry.layouts[i]
		if alive(entry.gui) then
			entry.layout()
		else
			table.remove(registry.layouts, i)
		end
	end
	for frame, info in pairs(registry.panels) do
		if alive(frame) then
			stylePanel(frame, info)
		else
			registry.panels[frame] = nil
		end
	end
	for inst, prop in pairs(registry.accents) do
		if alive(inst) then
			inst[prop] = UIKit.Style.accent
		else
			registry.accents[inst] = nil
		end
	end
	for label, base in pairs(registry.labels) do
		if alive(label) then
			styleLabel(label, base)
		else
			registry.labels[label] = nil
		end
	end
end

-- Mark an instance property as "the accent" (recoloured when the accent changes).
function UIKit.TrackAccent(inst, prop)
	registry.accents[inst] = prop
	inst[prop] = UIKit.Style.accent
	return inst
end

function UIKit.new(className, props, parent)
	local inst = Instance.new(className)
	for key, value in pairs(props) do
		inst[key] = value
	end
	inst.Parent = parent
	return inst
end

function UIKit.corner(parent, scale)
	UIKit.new("UICorner", { CornerRadius = UDim.new(scale or 0.2, 0) }, parent)
end

function UIKit.label(parent, props)
	local base = { BackgroundTransparency = 1, TextColor3 = palette.White, Font = Enum.Font.GothamBold, TextScaled = true, Text = "" }
	for key, value in pairs(props) do
		base[key] = value
	end
	local accent = base.TextColor3 == palette.Cyan
	local label = UIKit.new("TextLabel", base, parent)
	registry.labels[label] = base.TextStrokeTransparency or 1
	styleLabel(label, registry.labels[label])
	if accent then
		UIKit.TrackAccent(label, "TextColor3")
	end
	return label
end

function UIKit.button(parent, props, accent)
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
	local b = UIKit.new("TextButton", base, parent)
	UIKit.corner(b, 0.25)
	local stroke = UIKit.new("UIStroke", { Color = accent, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, b)
	if accent == palette.Cyan then -- only the primary accent follows the setting; warnings keep their colour
		UIKit.TrackAccent(stroke, "Color")
		UIKit.TrackAccent(b, "TextColor3")
	end
	UIKit.new("UIPadding", { PaddingTop = UDim.new(0.18, 0), PaddingBottom = UDim.new(0.18, 0) }, b)
	-- A6 press feedback: 0.97 scale while held (instant, no tween: nothing to clean up)
	local press = UIKit.new("UIScale", { Name = "Press", Scale = 1 }, b)
	b.MouseButton1Down:Connect(function()
		press.Scale = 0.97
	end)
	local function release()
		press.Scale = 1
	end
	b.MouseButton1Up:Connect(release)
	b.MouseLeave:Connect(release)
	b.SelectionLost:Connect(release)
	return b
end

function UIKit.panel(parent, props)
	local base = { BackgroundColor3 = palette.Navy, BackgroundTransparency = 0.05 }
	for key, value in pairs(props) do
		base[key] = value
	end
	local frame = UIKit.new("Frame", base, parent)
	UIKit.corner(frame, 0.12)
	local info = { base = base.BackgroundTransparency, color = base.BackgroundColor3 }
	registry.panels[frame] = info
	stylePanel(frame, info)
	return frame
end

-- Returns gui, root, maid. Root is scaled from the reference resolution and kept in the safe area.
function UIKit.screen(name, displayOrder)
	local maid = Utility.Maid.new()
	local gui = UIKit.new("ScreenGui", {
		Name = name,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = displayOrder,
		Enabled = true,
	}, Players.LocalPlayer:WaitForChild("PlayerGui"))
	pcall(function()
		gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	end)
	maid:Give(gui)
	local root = UIKit.new("Frame", { Name = "Root", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, gui)
	local scale = UIKit.new("UIScale", {}, root)
	local function layout()
		local ui = GameConfig.UI
		local viewport = workspace.CurrentCamera.ViewportSize
		local s = Utility.clamp(math.min(viewport.X / ui.ReferenceWidth, viewport.Y / ui.ReferenceHeight), ui.MinScale, ui.MaxScale)
		s = s * UIKit.Style.scale -- player HUD size (85-125%)
		scale.Scale = s
		root.Size = UDim2.fromScale(1 / s, 1 / s)
	end
	maid:Give(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(layout))
	table.insert(registry.layouts, { gui = gui, layout = layout })
	layout()
	return gui, root, maid
end

---------------------------------------------------------------------------------------------
-- Motion (owner request 2026-11-26: "create animations for everything"). Entrances only:
-- hiding is always instant, so a closed menu never lingers on screen or swallows a tap. With
-- the Reduced motion setting nothing moves. Everything here is cosmetic and safe to call
-- repeatedly: a slide remembers the element's resting position while it plays, so a quick
-- open-close-open never leaves anything offset.
UIKit.Motion = { reduced = false }
local motionBase = setmetatable({}, { __mode = "k" })
local motionTween = setmetatable({}, { __mode = "k" })

function UIKit.SetReducedMotion(value)
	UIKit.Motion.reduced = value == true
end

-- TweenService:Create(...):Play(); if TweenService is unavailable (offline specs) the end
-- values are applied at once. style / direction: Enum items or their names ("Back", "Out").
function UIKit.Tween(inst, seconds, props, style, direction)
	local ok, ts = pcall(function()
		return game:GetService("TweenService")
	end)
	if not ok or not ts or not ts.Create then
		for key, value in pairs(props) do
			inst[key] = value
		end
		return nil
	end
	if type(style) ~= "userdata" then
		style = Enum.EasingStyle[style or "Quad"]
	end
	if type(direction) ~= "userdata" then
		direction = Enum.EasingDirection[direction or "Out"]
	end
	local t = ts:Create(inst, TweenInfo.new(seconds, style, direction), props)
	t:Play()
	return t
end

-- The "Pop" UIScale of an element (made on first use). Nil when the element already has a
-- different UIScale (buttons have "Press"): only one UIScale applies per object.
function UIKit.PopScale(inst)
	local s = inst:FindFirstChild("Pop")
	if s then
		return s
	end
	if inst:FindFirstChildOfClass("UIScale") then
		return nil
	end
	return UIKit.new("UIScale", { Name = "Pop", Scale = 1 }, inst)
end

UIKit.SlideOffsets = {
	FromLeft = { -70, 0 },
	FromRight = { 70, 0 },
	FromAbove = { 0, -48 },
	FromBelow = { 0, 48 },
}

-- Snap an element to its resting position (cancels a running slide).
function UIKit.Settle(inst)
	local t, base = motionTween[inst], motionBase[inst]
	motionTween[inst], motionBase[inst] = nil, nil
	if t then
		t:Cancel()
	end
	if base then
		inst.Position = base
	end
end

-- Entrance: "Pop" (scale 0.9 -> 1 with a little overshoot) or a slide (UIKit.SlideOffsets).
function UIKit.Enter(inst, kind, seconds)
	if UIKit.Motion.reduced or not inst then
		return
	end
	seconds = seconds or 0.24
	if kind == "Pop" then
		local s = UIKit.PopScale(inst)
		if s then
			s.Scale = 0.9
			UIKit.Tween(s, seconds, { Scale = 1 }, "Back", "Out")
			return
		end
		kind = "FromBelow"
	end
	local off = UIKit.SlideOffsets[kind]
	if not off then
		return
	end
	local base = motionBase[inst] or inst.Position
	local running = motionTween[inst]
	motionTween[inst] = nil
	if running then
		running:Cancel()
	end
	motionBase[inst] = base
	inst.Position = base + UDim2.fromOffset(off[1], off[2])
	local t = UIKit.Tween(inst, seconds, { Position = base }, "Quint", "Out")
	if not t then
		motionBase[inst] = nil
		return
	end
	motionTween[inst] = t
	t.Completed:Connect(function()
		if motionTween[inst] == t then
			motionTween[inst], motionBase[inst] = nil, nil
		end
	end)
end

-- inst.Visible = visible, with an entrance when it turns on (and an instant, settled hide).
function UIKit.Show(inst, visible, kind, seconds)
	local was = inst.Visible == true
	inst.Visible = visible
	if visible and not was then
		UIKit.Enter(inst, kind or "Pop", seconds)
	elseif not visible and was then
		UIKit.Settle(inst)
	end
end

-- A short scale punch (countdown numbers, rewards): `peak` -> 1.
function UIKit.Punch(inst, peak, seconds)
	if UIKit.Motion.reduced or not inst then
		return
	end
	local s = UIKit.PopScale(inst)
	if s then
		s.Scale = peak or 1.3
		UIKit.Tween(s, seconds or 0.3, { Scale = 1 }, "Back", "Out")
	end
end

-- Children appear one after another (lists, podium, grids): each slides in `step` s later.
function UIKit.Stagger(list, kind, step)
	if UIKit.Motion.reduced then
		return
	end
	for i, inst in ipairs(list) do
		if i == 1 then
			UIKit.Enter(inst, kind)
		else
			task.delay((i - 1) * (step or 0.05), function()
				UIKit.Enter(inst, kind)
			end)
		end
	end
end

function UIKit.ordinal(n)
	local suffix = "TH"
	local lastTwo = n % 100
	if lastTwo < 11 or lastTwo > 13 then
		local last = n % 10
		if last == 1 then
			suffix = "ST"
		elseif last == 2 then
			suffix = "ND"
		elseif last == 3 then
			suffix = "RD"
		end
	end
	return tostring(n) .. suffix
end

function UIKit.setText(label, text)
	if label.Text ~= text then
		label.Text = text
	end
end

return UIKit
