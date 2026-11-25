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
	return UIKit.new("TextLabel", base, parent)
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
	UIKit.new("UIStroke", { Color = accent, Thickness = 3, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, b)
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
	local base = { BackgroundColor3 = palette.Navy, BackgroundTransparency = 0.15 }
	for key, value in pairs(props) do
		base[key] = value
	end
	local frame = UIKit.new("Frame", base, parent)
	UIKit.corner(frame, 0.12)
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
		scale.Scale = s
		root.Size = UDim2.fromScale(1 / s, 1 / s)
	end
	maid:Give(workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(layout))
	layout()
	return gui, root, maid
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
