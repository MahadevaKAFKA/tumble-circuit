--[[
	DevPanelController (A5) — F8 toggles a small test panel, but ONLY if the server created the
	DevCommand remote (Studio, or an account in GameConfig.Dev.AuthorizedUserIds). On a normal
	live server the remote does not exist and this controller builds nothing. The server
	re-checks every command; Coin grants / resets only touch Studio MOCK profiles.
]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Utility = require(Shared:WaitForChild("Utility"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local DevPanel = {}
DevPanel.__index = DevPanel

local palette = UIKit.Palette

function DevPanel.new(remotesFolder)
	local self = setmetatable({}, DevPanel)
	self.maid = Utility.Maid.new()
	local command = remotesFolder:FindFirstChild("DevCommand")
	local result = remotesFolder:FindFirstChild("DevResult")
	if not command or not result then
		self.enabled = false
		return self
	end
	self.enabled = true
	local gui, root, maid = UIKit.screen("TumbleDevPanel", 50)
	self.maid:Give(maid)
	gui.Enabled = false
	local panel = UIKit.panel(root, { Name = "Dev", Position = UDim2.fromOffset(14, 150), Size = UDim2.fromOffset(330, 420) })
	UIKit.new("UIStroke", { Color = palette.Coral, Thickness = 2 }, panel)
	UIKit.label(panel, { Position = UDim2.fromOffset(12, 8), Size = UDim2.new(1, -24, 0, 26), Font = Enum.Font.GothamBlack, TextColor3 = palette.Coral, Text = "DEV PANEL (F8) - test only" })
	local buttons = {
		{ "START NOW", "StartNow", 0 },
		{ "END RACE", "EndRace", 0 },
		{ "BOTS 0", "Bots", 0 },
		{ "BOTS 3", "Bots", 3 },
		{ "BOTS 7 (8 racers)", "Bots", 7 },
		{ "BOTS AUTO", "Bots", -1 },
		{ "+500 MOCK COINS", "MockCoins", 500 },
		{ "RESET MOCK PROFILE", "ResetMock", 0 },
		{ "DIAGNOSTICS", "Diag", 0 },
	}
	for i, spec in ipairs(buttons) do
		local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
		local b = UIKit.button(panel, { Position = UDim2.fromOffset(12 + col * 156, 40 + row * 52), Size = UDim2.fromOffset(148, 44), Text = spec[1] }, palette.White)
		maid:Give(b.Activated:Connect(function()
			command:FireServer(spec[2], spec[3])
		end))
	end
	self.output = UIKit.label(panel, { Position = UDim2.fromOffset(12, 310), Size = UDim2.new(1, -24, 0, 100), Font = Enum.Font.Code, TextWrapped = true, TextScaled = false, TextSize = 14, TextYAlignment = Enum.TextYAlignment.Top, Text = "" })
	maid:Give(result.OnClientEvent:Connect(function(data)
		if type(data) == "table" then
			self.output.Text = tostring(data.text)
		end
	end))
	maid:Give(UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == Enum.KeyCode.F8 then
			gui.Enabled = not gui.Enabled
		end
	end))
	return self
end

function DevPanel:Destroy()
	self.maid:Cleanup()
end

return DevPanel
