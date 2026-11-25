--[[
	StarterLoadoutController (A5) — the starter ability modal: Boost, Shield and Pulse are all
	owned; pick exactly two (slot 1 = Q / LB, slot 2 = E / RB). Changes apply from the NEXT race:
	the server refuses equips while you race (the modal can't even open on the race screen).
	Shows real numbers from AbilityConfig. No unlock / buy buttons exist.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local AbilityConfig = require(Shared:WaitForChild("AbilityConfig"))
local PlayerDataSchema = require(Shared:WaitForChild("PlayerDataSchema"))
local Utility = require(Shared:WaitForChild("Utility"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local Loadout = {}
Loadout.__index = Loadout

local palette = UIKit.Palette

local function stats(id)
	local def = AbilityConfig.Abilities[id]
	if id == "Boost" then
		return string.format("+%d%% speed for %.1f s  ·  cooldown %d s", math.floor((def.SpeedMultiplier - 1) * 100 + 0.5), def.Duration, def.Cooldown)
	elseif id == "Shield" then
		return string.format("Blocks the next hit for %.1f s  ·  cooldown %d s", def.Duration, def.Cooldown)
	elseif id == "Pulse" then
		return string.format("Nudges racers within %d studs  ·  cooldown %d s", def.Radius, def.Cooldown)
	end
	return ""
end

function Loadout.new(deps)
	local self = setmetatable({}, Loadout)
	self.remotes = deps.remotes
	self.loadout = { PlayerDataSchema.DefaultLoadout[1], PlayerDataSchema.DefaultLoadout[2] }
	self.CloseRequested = Utility.Signal.new()
	local gui, root, maid = UIKit.screen("TumbleLoadout", 20)
	self.gui, self.maid = gui, maid
	gui.Enabled = false
	local panel = UIKit.panel(root, { Name = "Loadout", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(760, 500), BackgroundTransparency = 0.04 })
	UIKit.new("UIStroke", { Color = palette.Violet, Thickness = 2 }, panel)
	UIKit.label(panel, { Position = UDim2.fromOffset(24, 14), Size = UDim2.new(1, -170, 0, 44), Font = Enum.Font.GothamBlack, TextColor3 = palette.Violet, Text = "STARTER ABILITIES", TextXAlignment = Enum.TextXAlignment.Left })
	UIKit.label(panel, { Position = UDim2.fromOffset(24, 58), Size = UDim2.new(1, -48, 0, 26), Font = Enum.Font.Gotham, Text = "Equip two. Changes apply from your next race - you can't switch mid-race.", TextXAlignment = Enum.TextXAlignment.Left })
	local close = UIKit.button(panel, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -16, 0, 14), Size = UDim2.fromOffset(130, 48), Text = "DONE" }, palette.Mint)
	maid:Give(close.Activated:Connect(function()
		self.CloseRequested:Fire()
	end))
	self.cards = {}
	for i, id in ipairs(PlayerDataSchema.StarterAbilities) do
		local def = AbilityConfig.Abilities[id]
		local y = 100 + (i - 1) * 124
		local card = UIKit.panel(panel, { Position = UDim2.fromOffset(24, y), Size = UDim2.new(1, -48, 0, 112), BackgroundColor3 = palette.NavyFloor, BackgroundTransparency = 0.1 })
		local stroke = UIKit.new("UIStroke", { Color = palette[def.Color] or palette.Cyan, Thickness = 2 }, card)
		UIKit.label(card, { Position = UDim2.fromOffset(16, 10), Size = UDim2.fromOffset(300, 38), Font = Enum.Font.GothamBlack, TextColor3 = palette[def.Color] or palette.Cyan, Text = string.upper(def.DisplayName), TextXAlignment = Enum.TextXAlignment.Left })
		UIKit.label(card, { Position = UDim2.fromOffset(16, 50), Size = UDim2.fromOffset(420, 24), Font = Enum.Font.Gotham, Text = def.Description or "", TextXAlignment = Enum.TextXAlignment.Left })
		UIKit.label(card, { Position = UDim2.fromOffset(16, 76), Size = UDim2.fromOffset(420, 24), Font = Enum.Font.Gotham, TextColor3 = palette.Yellow, Text = stats(id), TextXAlignment = Enum.TextXAlignment.Left })
		local slotButtons = {}
		for slot = 1, 2 do
			local b = UIKit.button(card, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -16 - (2 - slot) * 120, 0.5, 0), Size = UDim2.fromOffset(110, 64), Text = "" }, palette.White)
			maid:Give(b.Activated:Connect(function()
				self:Equip(slot, id)
			end))
			slotButtons[slot] = b
		end
		self.cards[id] = { buttons = slotButtons, stroke = stroke }
	end
	self.status = UIKit.label(panel, { Position = UDim2.fromOffset(24, 466), Size = UDim2.new(1, -48, 0, 26), Font = Enum.Font.Gotham, TextColor3 = palette.Mint, Text = "" })
	self:_render()
	return self
end

function Loadout:GetFirstButton()
	local card = self.cards[PlayerDataSchema.StarterAbilities[1]]
	return card and card.buttons[1]
end

function Loadout:SetVisible(visible)
	self.gui.Enabled = visible
end

-- Pure: the loadout after choosing `id` for `slot` (choosing the other slot's ability swaps).
function Loadout.Choose(loadout, slot, id)
	local out = { loadout[1], loadout[2] }
	local other = slot == 1 and 2 or 1
	if out[other] == id then
		out[other] = out[slot]
	end
	out[slot] = id
	return out
end

function Loadout:Equip(slot, id)
	if self.loadout[slot] == id then
		return
	end
	self.remotes.RequestEquip:FireServer(slot, id)
	UIKit.setText(self.status, "Saving...")
end

-- From AbilityState (server truth).
function Loadout:ApplyServer(loadout)
	if PlayerDataSchema.ValidLoadout(loadout) then
		local changed = loadout[1] ~= self.loadout[1] or loadout[2] ~= self.loadout[2]
		self.loadout = { loadout[1], loadout[2] }
		self:_render()
		if changed then
			UIKit.setText(self.status, "Equipped - ready for your next race")
		end
	end
end

function Loadout:_render()
	for id, card in pairs(self.cards) do
		for slot = 1, 2 do
			local equipped = self.loadout[slot] == id
			local b = card.buttons[slot]
			b.Text = equipped and ("SLOT " .. slot .. " - ON") or ("SLOT " .. slot)
			b.TextColor3 = equipped and palette.Mint or palette.White
		end
		card.stroke.Thickness = (self.loadout[1] == id or self.loadout[2] == id) and 4 or 1
	end
end

function Loadout:Destroy()
	self.maid:Cleanup()
end

return Loadout
