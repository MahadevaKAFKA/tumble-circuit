--[[
	StarterLoadoutController — the ABILITIES modal (A5 starters, B2 all twelve).
	- Owned abilities: SLOT 1 / SLOT 2 equip for your next race (the server refuses mid-race).
	- Locked abilities show how to earn them: reach the level (free) or spend earned Coins
	  (800 / 1200 / 1600). UNLOCK asks the server, which checks level/Coins and debits atomically.
	  Never Robux.
	- TRY 1 / TRY 2 put a locked ability on your buttons for hub practice only (you can use it on
	  yourself on the platform and practice chute); a race always uses your owned loadout.
	Real numbers come from AbilityConfig. Display/requests only: the server owns everything.
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
	return string.format("Cooldown %d s", def.Cooldown)
end
Loadout.Stats = stats

function Loadout.new(deps)
	local self = setmetatable({}, Loadout)
	self.remotes = deps.remotes
	self.loadout = { PlayerDataSchema.DefaultLoadout[1], PlayerDataSchema.DefaultLoadout[2] }
	self.practice = nil
	self.owned = {}
	for _, id in ipairs(AbilityConfig.StarterOwned) do
		self.owned[id] = true
	end
	self.level, self.coins = 1, 0
	self.CloseRequested = Utility.Signal.new()
	local gui, root, maid = UIKit.screen("TumbleLoadout", 20)
	self.gui, self.maid = gui, maid
	gui.Enabled = false
	local panel = UIKit.panel(root, { Name = "Loadout", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(820, 560), BackgroundTransparency = 0.04 })
	self.panel = panel
	UIKit.new("UIStroke", { Color = palette.Violet, Thickness = 2 }, panel)
	UIKit.label(panel, { Position = UDim2.fromOffset(24, 12), Size = UDim2.new(1, -190, 0, 40), Font = Enum.Font.GothamBlack, TextColor3 = palette.Violet, Text = "ABILITIES", TextXAlignment = Enum.TextXAlignment.Left })
	UIKit.label(panel, { Position = UDim2.fromOffset(24, 54), Size = UDim2.new(1, -48, 0, 22), Font = Enum.Font.Gotham, Text = "Equip two for your next race. Locked: earn by level or Coins - TRY them in the hub first.", TextXAlignment = Enum.TextXAlignment.Left })
	local close = UIKit.button(panel, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -16, 0, 12), Size = UDim2.fromOffset(130, 46), Text = "DONE" }, palette.Mint)
	maid:Give(close.Activated:Connect(function()
		self.CloseRequested:Fire()
	end))
	local list = UIKit.new("ScrollingFrame", {
		Name = "List",
		Position = UDim2.fromOffset(16, 84),
		Size = UDim2.new(1, -32, 0, 432),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 8,
		CanvasSize = UDim2.fromOffset(0, #AbilityConfig.Order * 104),
		ScrollingDirection = Enum.ScrollingDirection.Y,
	}, panel)
	self.cards = {}
	for i, id in ipairs(AbilityConfig.Order) do
		local def = AbilityConfig.Abilities[id]
		local color = palette[def.Color] or palette.Cyan
		local card = UIKit.panel(list, { Position = UDim2.fromOffset(4, (i - 1) * 104 + 4), Size = UDim2.new(1, -20, 0, 96), BackgroundColor3 = palette.NavyFloor, BackgroundTransparency = 0.1 })
		local stroke = UIKit.new("UIStroke", { Color = color, Thickness = 2 }, card)
		UIKit.label(card, { Position = UDim2.fromOffset(14, 6), Size = UDim2.fromOffset(250, 32), Font = Enum.Font.GothamBlack, TextColor3 = color, Text = def.DisplayName, TextXAlignment = Enum.TextXAlignment.Left })
		local lock = UIKit.label(card, { Position = UDim2.fromOffset(270, 10), Size = UDim2.fromOffset(170, 24), Font = Enum.Font.GothamBold, TextColor3 = palette.Yellow, Text = "", TextXAlignment = Enum.TextXAlignment.Left })
		UIKit.label(card, { Position = UDim2.fromOffset(14, 40), Size = UDim2.fromOffset(430, 24), Font = Enum.Font.Gotham, Text = def.Description or "", TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true })
		UIKit.label(card, { Position = UDim2.fromOffset(14, 66), Size = UDim2.fromOffset(430, 22), Font = Enum.Font.Gotham, TextColor3 = palette.Yellow, Text = stats(id), TextXAlignment = Enum.TextXAlignment.Left })
		local slotButtons = {}
		for slot = 1, 2 do
			local b = UIKit.button(card, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12 - (2 - slot) * 106, 0, 8), Size = UDim2.fromOffset(98, 38), Text = "" }, palette.White)
			maid:Give(b.Activated:Connect(function()
				self:Equip(slot, id)
			end))
			slotButtons[slot] = b
		end
		local unlock = UIKit.button(card, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 52), Size = UDim2.fromOffset(204, 36), Text = "UNLOCK", Visible = false }, palette.Yellow)
		maid:Give(unlock.Activated:Connect(function()
			self.remotes.RequestUnlockAbility:FireServer(id)
			UIKit.setText(self.status, "Unlocking...")
		end))
		self.cards[id] = { buttons = slotButtons, stroke = stroke, lock = lock, unlock = unlock }
	end
	self.status = UIKit.label(panel, { Position = UDim2.fromOffset(24, 524), Size = UDim2.new(1, -48, 0, 26), Font = Enum.Font.Gotham, TextColor3 = palette.Mint, Text = "" })
	self:_render()
	return self
end

function Loadout:GetFirstButton()
	local card = self.cards[AbilityConfig.Order[1]]
	return card and card.buttons[1]
end

function Loadout:SetVisible(visible)
	if visible and not self.gui.Enabled then
		UIKit.Enter(self.panel, "Pop")
	end
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

-- Pure: what a card shows. Returns owned:boolean, lockText, unlockLabel or nil (button hidden)
function Loadout.CardState(id, ownedSet, level, coins)
	local ok, how, detail = AbilityConfig.UnlockState(id, ownedSet, level, coins)
	if how == "Owned" then
		return true, "", nil
	end
	local unlock = AbilityConfig.Abilities[id].Unlock
	local lockText = string.format("LOCKED - LV %d", unlock.Level)
	if ok and how == "Level" then
		return false, lockText, "UNLOCK (FREE)"
	elseif ok and how == "Coins" then
		return false, lockText, string.format("UNLOCK  %d COINS", detail)
	end
	return false, lockText, string.format("LV %d or %d COINS", unlock.Level, unlock.Coins)
end

function Loadout:Equip(slot, id)
	local current = (self.practice and not self.owned[id]) and self.practice or self.loadout
	if current[slot] == id then
		return
	end
	self.remotes.RequestEquip:FireServer(slot, id)
	UIKit.setText(self.status, self.owned[id] and "Saving..." or "Trying it out (hub only)...")
end

function Loadout:SetProfile(level, coins)
	self.level, self.coins = level or 1, coins or 0
	self:_render()
end

-- From AbilityState (server truth): loadout, owned list, practice set.
function Loadout:ApplyServer(loadout, state)
	if state and type(state.owned) == "table" then
		self.owned = {}
		for _, id in ipairs(state.owned) do
			self.owned[id] = true
		end
		self.practice = state.practice
	end
	if PlayerDataSchema.ValidLoadout(loadout) then
		local changed = loadout[1] ~= self.loadout[1] or loadout[2] ~= self.loadout[2]
		self.loadout = { loadout[1], loadout[2] }
		if changed then
			UIKit.setText(self.status, "Equipped - ready for your next race")
		end
	end
	if self.practice then
		UIKit.setText(self.status, "Trying in the hub: use your ability buttons on the platform or practice chute")
	end
	self:_render()
end

function Loadout:_render()
	for id, card in pairs(self.cards) do
		local owned, lockText, unlockLabel = Loadout.CardState(id, self.owned, self.level, self.coins)
		card.lock.Text = lockText
		card.unlock.Visible = unlockLabel ~= nil
		if unlockLabel then
			card.unlock.Text = unlockLabel
			card.unlock.AutoButtonColor = string.sub(unlockLabel, 1, 6) == "UNLOCK"
		end
		local set = owned and self.loadout or (self.practice or {})
		for slot = 1, 2 do
			local on = set[slot] == id
			local b = card.buttons[slot]
			if owned then
				b.Text = on and ("SLOT " .. slot .. " ON") or ("SLOT " .. slot)
			else
				b.Text = on and ("TRYING " .. slot) or ("TRY " .. slot)
			end
			b.TextColor3 = on and palette.Mint or palette.White
		end
		card.stroke.Thickness = (self.loadout[1] == id or self.loadout[2] == id) and 4 or 1
	end
end

function Loadout:Destroy()
	self.maid:Cleanup()
end

return Loadout
