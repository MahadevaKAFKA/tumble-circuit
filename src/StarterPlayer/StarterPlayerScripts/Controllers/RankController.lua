--[[
	RankController (brief 3 E, 2026-11-26) — the opt-in Ranked TEST card. Display + requests only;
	the server seals rounds and applies ratings. Shows: tier (or placement progress), rating, the
	tier bar, what counts, the last result (or "pending"), and an honest wait note when there are
	not enough ranked players ("Casual races continue"). Opened from MORE > RANKED.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local RankRules = require(Shared:WaitForChild("RankRules"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local palette = UIKit.Palette

local Rank = {}
Rank.__index = Rank

-- Pure: the card's lines for a RankState payload
function Rank.Lines(state)
	if type(state) ~= "table" or not state.enabled then
		return { title = "RANKED", status = "The Ranked test is off.", detail = "", button = nil }
	end
	local title
	if state.tier == "Provisional" then
		title = string.format("PLACEMENT  %d / %d", state.placements or 0, state.placementRaces or RankRules.PlacementRaces)
	else
		title = string.format("%s  ·  %d", string.upper(state.tier or "?"), state.rating or 0)
	end
	local last = ""
	if type(state.last) == "table" then
		if state.last.pending then
			last = "Last race: result pending (saving) - nothing is lost."
		elseif type(state.last.delta) == "number" then
			last = string.format("Last race: %s%d rating", state.last.delta >= 0 and "+" or "", state.last.delta)
		end
	end
	local status = state.optIn and ("You're in the Ranked test. " .. (state.waitNote or "Your next race with enough ranked players counts.")) or "Ranked is a separate, opt-in test. Casual races are unchanged."
	return {
		title = title,
		status = status,
		detail = string.format("Counts: your finishing order against the other ranked players (no bots, no abilities, no comeback boosts). Needs %d ranked players in the race. Level, quests and cosmetics are separate.", state.minHumans or RankRules.MinHumans),
		last = last,
		button = state.optIn and "LEAVE RANKED TEST" or "JOIN RANKED TEST",
	}
end

function Rank.new(deps)
	local self = setmetatable({}, Rank)
	self.remotes = deps.remotes
	self.toast = deps.toast
	local gui, root, maid = UIKit.screen("TumbleRank", 24)
	self.gui, self.maid = gui, maid
	local panel = UIKit.panel(root, { Name = "Ranked", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(520, 330), Visible = false })
	self.panel = panel
	self.title = UIKit.Title(panel, { Position = UDim2.fromOffset(20, 16), Size = UDim2.fromOffset(420, 32), Text = "RANKED" })
	local close = UIKit.button(panel, { Name = "Close", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 14), Size = UDim2.fromOffset(44, 36), Text = "X" }, palette.White)
	maid:Give(close.Activated:Connect(function()
		self:Close()
	end))
	local barBack = UIKit.new("Frame", { Position = UDim2.fromOffset(20, 58), Size = UDim2.fromOffset(480, 8), BackgroundColor3 = palette.White, BackgroundTransparency = 0.8, BorderSizePixel = 0 }, panel)
	self.bar = UIKit.new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = palette.Mint, BorderSizePixel = 0 }, barBack)
	self.status = UIKit.label(panel, { Position = UDim2.fromOffset(20, 76), Size = UDim2.fromOffset(480, 44), TextWrapped = true, TextScaled = false, TextSize = 17, Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top })
	self.last = UIKit.label(panel, { Position = UDim2.fromOffset(20, 124), Size = UDim2.fromOffset(480, 22), TextScaled = false, TextSize = 16, Font = Enum.Font.GothamBold, TextColor3 = palette.Yellow, TextXAlignment = Enum.TextXAlignment.Left })
	self.detail = UIKit.label(panel, { Position = UDim2.fromOffset(20, 152), Size = UDim2.fromOffset(480, 86), TextWrapped = true, TextScaled = false, TextSize = 15, Font = Enum.Font.Gotham, TextColor3 = UIKit.Colors.Muted, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top })
	self.toggle = UIKit.Primary(UIKit.button(panel, { Name = "RankedToggle", Position = UDim2.fromOffset(20, 256), Size = UDim2.fromOffset(300, 54), Text = "JOIN RANKED TEST" }, palette.Mint))
	maid:Give(self.toggle.Activated:Connect(function()
		local want = not (self.state and self.state.optIn)
		self.remotes.RequestRankedOptIn:FireServer(want)
	end))
	-- the MORE-drawer entry (MatchUI adopts it)
	self.openButton = UIKit.button(root, { Name = "Ranked", Size = UDim2.fromOffset(121, 44), Text = "RANKED", Visible = false }, palette.Violet)
	maid:Give(self.openButton.Activated:Connect(function()
		self:Open()
	end))
	maid:Give(self.remotes.RankState.OnClientEvent:Connect(function(state)
		self:_apply(state)
	end))
	return self
end

function Rank:_apply(state)
	if type(state) ~= "table" then
		return
	end
	local previous = self.state
	self.state = state
	local lines = Rank.Lines(state)
	self.title.Text = lines.title
	self.status.Text = lines.status
	self.detail.Text = lines.detail
	self.last.Text = lines.last or ""
	self.bar.Size = UDim2.fromScale(state.tier == "Provisional" and math.clamp((state.placements or 0) / (state.placementRaces or 5), 0, 1) or (state.progress or 0), 1)
	self.toggle.Visible = lines.button ~= nil
	self.toggle.Text = lines.button or ""
	self.openButton.Text = state.optIn and "RANKED  ON" or "RANKED"
	-- a new result after a race: one short toast, never during driving
	if previous and type(state.last) == "table" and type(previous.last) == "table" and state.last.rating ~= previous.last.rating and not state.last.pending and self.toast then
		self.toast(string.format("RANKED  %s%d  ·  %s", state.last.delta >= 0 and "+" or "", state.last.delta or 0, lines.title), 3)
	end
end

function Rank:Open()
	self.panel.Visible = true
	UIKit.Enter(self.panel, "FromBelow", 0.2)
	self.remotes.RequestRankedOptIn:FireServer(self.state and self.state.optIn == true or false) -- refresh
end

function Rank:Close()
	self.panel.Visible = false
end

function Rank:Destroy()
	self.maid:Cleanup()
end

return Rank
