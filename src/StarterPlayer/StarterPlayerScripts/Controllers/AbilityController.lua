--[[
	AbilityController — A3 client side of abilities and micro-skills. Display + requests only:
	  * two ability buttons (bottom right) with cooldown fill, seconds, key labels (Q/E, LB/RB);
	    on touch they sit above the BRAKE cluster and a big TRICK button appears
	  * hub loadout summary (A5): shows the two equipped abilities; tapping opens the Loadout
	    modal (StarterLoadoutController). Reduced Motion moved to the Settings modal.
	  * quiet feedback ("Cooling down", "Can't trick here", "Shield blocked") as small toasts
	  * three skippable contextual hints: steer (A1 card), trick (near the ramp), abilities (first GO)
	Server messages: AbilityState, EffectState, ApplyImpulse (-> motor), SkillEvent, AbilityOutcome (-> VFX).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local AbilityConfig = require(Shared:WaitForChild("AbilityConfig"))
local Utility = require(Shared:WaitForChild("Utility"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local AbilityController = {}
AbilityController.__index = AbilityController

local palette = UIKit.Palette
local KEYS = {
	KeyboardMouse = { "Q", "E", "SPACE" },
	Gamepad = { "LB", "RB", "A" },
	Touch = { "", "", "" },
}
local FEEDBACK = {
	ShieldBlocked = "Shield blocked it!",
	TrickSuccess = "TRICK! +15% speed",
	TrickArmed = "Trick!",
	NearMiss = "NEAR MISS!",
	PerfectDodge = "PERFECT DODGE!",
	SlipstreamOn = "SLIPSTREAM +12%",
	Charge = "Cooldowns -1.5 s",
	Chilled = "CHILLED! Steering -25%", -- B2 Frost Wake
}

function AbilityController.new(deps)
	local self = setmetatable({}, AbilityController)
	self.remotes = deps.remotes
	self.motor = deps.motor
	self.input = deps.input
	self.toast = deps.toast -- function(text, seconds)
	self.flash = deps.flash -- function(text, color, seconds)
	self.state = nil
	self.effects = nil
	self.visibleMode = "Hidden" -- "Hidden" | "Race" | "Hub"
	self.reducedMotion = false
	self.hintsShown = {}
	self.maid = Utility.Maid.new()
	self.TrickPressed = Utility.Signal.new()
	self.OutcomeReceived = Utility.Signal.new()
	self.ReducedMotionChanged = Utility.Signal.new()
	self.LoadoutRequested = Utility.Signal.new()
	self.StateReceived = Utility.Signal.new() -- (abilityState) for the Loadout modal

	local gui, root, maid = UIKit.screen("TumbleAbilities", 7)
	self.gui, self.root = gui, root
	self.maid:Give(maid)

	self.slots = {}
	for slot = 1, 2 do
		local b = UIKit.button(root, {
			Name = "Ability" .. slot,
			AnchorPoint = Vector2.new(1, 1),
			Size = UDim2.fromOffset(104, 104),
			Text = "",
			ClipsDescendants = true,
		}, palette.Cyan)
		local fill = UIKit.new("Frame", { Name = "Cooldown", AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.fromScale(1, 0), BackgroundColor3 = palette.Ink, BackgroundTransparency = 0.25, BorderSizePixel = 0, ZIndex = 2 }, b)
		local name = UIKit.label(b, { Position = UDim2.fromScale(0.05, 0.12), Size = UDim2.fromScale(0.9, 0.3), Font = Enum.Font.GothamBlack, ZIndex = 3 })
		local timer = UIKit.label(b, { Position = UDim2.fromScale(0.1, 0.42), Size = UDim2.fromScale(0.8, 0.3), Font = Enum.Font.GothamBlack, TextColor3 = palette.White, ZIndex = 3 })
		local key = UIKit.label(b, { Position = UDim2.fromScale(0.1, 0.72), Size = UDim2.fromScale(0.8, 0.2), Font = Enum.Font.Gotham, TextColor3 = palette.White, ZIndex = 3 })
		self.maid:Give(b.Activated:Connect(function()
			self:RequestAbility(slot)
		end))
		self.slots[slot] = { button = b, fill = fill, name = name, timer = timer, key = key }
	end
	self.trickButton = UIKit.button(root, { Name = "Trick", AnchorPoint = Vector2.new(1, 1), Size = UDim2.fromOffset(110, 110), Text = "TRICK" }, palette.Mint)
	self.maid:Give(self.trickButton.Activated:Connect(function()
		self:RequestTrick()
	end))

	-- Hub loadout panel
	local panel = UIKit.panel(root, { Name = "Loadout", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 352), Size = UDim2.fromOffset(250, 118), Visible = false })
	UIKit.label(panel, { Position = UDim2.fromOffset(10, 6), Size = UDim2.new(1, -20, 0, 24), Font = Enum.Font.GothamBlack, TextColor3 = palette.Cyan, Text = "NEXT RACE ABILITIES" })
	self.loadoutButtons = {}
	for slot = 1, 2 do
		local b = UIKit.button(panel, { Position = UDim2.fromOffset(10, 34 + (slot - 1) * 40), Size = UDim2.new(1, -20, 0, 36), Text = "" }, palette.White)
		self.maid:Give(b.Activated:Connect(function()
			self.LoadoutRequested:Fire()
		end))
		self.loadoutButtons[slot] = b
	end
	self.panel = panel

	-- Skippable hint card
	local hint = UIKit.panel(root, { Name = "Hint", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 100), Size = UDim2.fromOffset(560, 70), Visible = false })
	UIKit.new("UIStroke", { Color = palette.Mint, Thickness = 2 }, hint)
	self.hintText = UIKit.label(hint, { Position = UDim2.fromOffset(14, 8), Size = UDim2.new(1, -120, 1, -16), TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.GothamBold })
	local ok = UIKit.button(hint, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10, 0.5, 0), Size = UDim2.fromOffset(90, 44), Text = "OK" }, palette.Mint)
	self.maid:Give(ok.Activated:Connect(function()
		hint.Visible = false
	end))
	self.hint = hint

	-- Server messages
	local function on(name, fn)
		self.maid:Give(self.remotes[name].OnClientEvent:Connect(function(data)
			if type(data) == "table" then
				fn(data)
			end
		end))
	end
	on("AbilityState", function(data)
		self.state = data
		self:_renderLoadout()
		self.StateReceived:Fire(data)
	end)
	on("EffectState", function(data)
		self.effects = data
		self.motor:SetEffects(data)
	end)
	on("ApplyImpulse", function(data)
		if typeof(data.direction) == "Vector3" and type(data.deltaV) == "number" then
			-- B2: the server names the source and its cap (never above 24 studs/s here)
			local cap = math.min(type(data.cap) == "number" and data.cap or AbilityConfig.Abilities.Pulse.MaxDeltaV, 24)
			self.motor:ApplyExternalImpulse(data.direction, data.deltaV, cap)
			if data.source == "Magnet" then
				self.flash("MAGNET!", palette.Violet, 0.6)
			elseif data.source == nil or data.source == "Pulse" then
				self.flash("PULSED!", palette.Coral, 0.8)
			end
		end
	end)
	on("SkillEvent", function(data)
		local text = FEEDBACK[data.kind]
		if data.kind == "Unlocked" then
			self.flash(tostring(data.detail or "Unlocked"), palette.Yellow, 2) -- B2
		elseif data.kind == "Denied" or data.kind == "TrickFail" then
			self.toast(tostring(data.detail or "Not now"), 1.4)
		elseif text then
			self.flash(text, (data.kind == "NearMiss" or data.kind == "PerfectDodge") and palette.Yellow or palette.Mint, 1)
		end
	end)
	on("AbilityOutcome", function(data)
		self.OutcomeReceived:Fire(data)
	end)
	self:SetMode("Hidden", "KeyboardMouse")
	return self
end

function AbilityController:HasPractice()
	return self.state ~= nil and self.state.practice ~= nil
end

-- the two abilities on the buttons right now (B2: practice set in the hub)
function AbilityController:_current()
	if self.practiceMode and self.state and self.state.practice then
		return self.state.practice
	end
	return self.state and self.state.loadout or {}
end

function AbilityController:RequestAbility(slot)
	if self.visibleMode ~= "Race" then
		return
	end
	local cooldownEnd = self.state and self.state.cooldowns and self.state.cooldowns[slot] or 0
	if workspace:GetServerTimeNow() < cooldownEnd then
		self.toast("Cooling down", 0.8) -- local hint only; the server re-checks anyway
		return
	end
	self.remotes.RequestAbility:FireServer(slot)
end

function AbilityController:RequestTrick()
	if self.visibleMode ~= "Race" then
		return
	end
	self.remotes.RequestTrick:FireServer()
	self.TrickPressed:Fire()
end

function AbilityController:SetReducedMotion(value)
	if self.reducedMotion ~= value then
		self.reducedMotion = value
		self.ReducedMotionChanged:Fire(value)
	end
end

function AbilityController:IsShielded()
	return self.effects ~= nil and (self.effects.shieldUntil or 0) > workspace:GetServerTimeNow()
end

function AbilityController:ShowHint(key, text)
	if self.hintsShown[key] then
		return
	end
	self.hintsShown[key] = true
	self.hintText.Text = text
	self.hint.Visible = true
	task.delay(8, function()
		if self.hintText.Text == text then
			self.hint.Visible = false
		end
	end)
end

function AbilityController:_renderLoadout()
	if not self.state then
		return
	end
	for slot = 1, 2 do
		local id = self:_current()[slot]
		local def = AbilityConfig.Abilities[id]
		local keys = KEYS[self.device or "KeyboardMouse"] or KEYS.KeyboardMouse
		self.loadoutButtons[slot].Text = string.format("%s%s  (change)", keys[slot] ~= "" and (keys[slot] .. ": ") or ("SLOT " .. slot .. ": "), def and def.DisplayName or "?")
		self.slots[slot].name.Text = def and def.DisplayName or "?"
		local color = def and palette[def.Color] or palette.Cyan
		self.slots[slot].name.TextColor3 = color
		local stroke = self.slots[slot].button:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = color
		end
	end
end

-- mode: "Hidden" | "Race" | "Hub"
function AbilityController:SetMode(mode, device, practice)
	self.visibleMode = mode
	self.device = device
	self.practiceMode = practice == true -- B2: hub try-it buttons
	local touch = device == "Touch"
	local race = mode == "Race"
	for slot = 1, 2 do
		local b = self.slots[slot].button
		b.Visible = race
		local y = touch and -260 or -24
		b.Position = UDim2.new(1, -24 - (2 - slot) * 116, 1, y)
		self.slots[slot].key.Text = (KEYS[device] or KEYS.KeyboardMouse)[slot]
	end
	self.trickButton.Visible = race and touch
	self.trickButton.Position = UDim2.new(1, -24 - 120 - 20 - 84 - 20, 1, -24)
	-- A5 moved this panel to the right column (clear of the stick), so no phone override is needed.
	self.panel.Visible = mode == "Hub"
	self:_renderLoadout()
end

function AbilityController:Update()
	if not self.state or self.visibleMode ~= "Race" then
		return
	end
	local now = workspace:GetServerTimeNow()
	for slot = 1, 2 do
		local finish = self.state.cooldowns[slot] or 0
		local def = AbilityConfig.Abilities[self:_current()[slot]]
		local left = math.max(0, finish - now)
		local fraction = def and math.clamp(left / def.Cooldown, 0, 1) or 0
		self.slots[slot].fill.Size = UDim2.fromScale(1, fraction)
		UIKit.setText(self.slots[slot].timer, left > 0 and string.format("%d", math.ceil(left)) or "READY")
	end
end

function AbilityController:Destroy()
	self.maid:Cleanup()
end

return AbilityController
