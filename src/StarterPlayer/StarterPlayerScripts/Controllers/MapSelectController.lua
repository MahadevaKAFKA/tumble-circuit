--[[
	MapSelectController (promo pack prompt 03) — the Map Selection modal: one card per map the
	server built, each with three actions:
	  VISIT HUB  -> RequestDestination(hubIndex, 1)   your own choice; the race is unchanged
	  PRACTICE   -> RequestDestination(hubIndex, 2)   roll that hub's practice lane
	  VOTE       -> RequestBallot(mapIndex, epoch, seq) for the NEXT race (change it any time
	                before the grid forms; the server counts one ballot per queued player)
	Card text comes from MapRegistry.Card (name, difficulty, one-line description, skill). No
	preview images until real captures exist (prompt 24): a palette swatch stands in.
	Disabled states say why (hub in testing, already there, voting closed, race running).
	Display and requests only; the server owns ballots, hubs and the race map.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local MapRegistry = require(Shared:WaitForChild("MapRegistry"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local Utility = require(Shared:WaitForChild("Utility"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local palette = GameConfig.Palette

local MapSelect = {}
MapSelect.__index = MapSelect

MapSelect.MaxCards = 3 -- visible at once; more maps page with < >

local REASONS = {
	unavailable = "That hub isn't available on this server right now.",
	gated = "That hub is still in testing.",
	too_fast = "One moment - you just moved.",
	after_race = "You'll go there after this race.",
	left_trial = "Time Trial ended.",
	bad_mode = "Not now.",
}

local function features(player)
	local out = {}
	local text = player:GetAttribute(Protocol.PlayerAttributes.Features)
	if type(text) == "string" then
		for name in string.gmatch(text, "[^,]+") do
			out[name] = true
		end
	end
	return out
end

local function hubIndexOf(hubId)
	for i, entry in ipairs(MapRegistry.Hubs) do
		if entry.Id == hubId then
			return i
		end
	end
	return nil
end

local function color(hex)
	return Color3.fromRGB(math.floor(hex / 65536) % 256, math.floor(hex / 256) % 256, hex % 256)
end

-- Pure: what a card shows. ctx = { snap, myUserId, myHub, features, racing }
function MapSelect.CardState(map, ctx)
	local card = MapRegistry.Card(map)
	local hub, fellBack = MapRegistry.HubForMap(map.Id, ctx.features)
	local ownHub = MapRegistry.RawHub(map.Hub)
	local ballot = ctx.snap and ctx.snap.ballot
	local mapIndex = nil
	for i, id in ipairs(ballot and ballot.maps or {}) do
		if id == map.Id then
			mapIndex = i
		end
	end
	local mine = ballot and ballot.choices and ballot.choices[tostring(ctx.myUserId)]
	local state = {
		card = card,
		hubId = hub and hub.Id,
		hubName = hub and hub.Meta.DisplayName or "?",
		mapIndex = mapIndex,
		votes = mapIndex and ballot.counts and ballot.counts[mapIndex] or 0,
		voted = mine ~= nil and mine == mapIndex,
		visitText = "VISIT HUB",
		visitEnabled = true,
		practiceEnabled = true,
		voteEnabled = mapIndex ~= nil,
		note = nil,
	}
	if fellBack and ownHub and ownHub.Id ~= MapRegistry.DefaultHubId then
		state.note = ownHub.Meta.DisplayName .. " is still in testing - its practice is in " .. state.hubName
	end
	if ctx.myHub == state.hubId then
		state.visitText = "YOU'RE HERE"
		state.visitEnabled = false
	end
	if ctx.racing then
		state.visitText = "AFTER RACE"
		state.practiceEnabled = false
	end
	if not mapIndex then
		state.note = "Not racing on this server right now"
	end
	return state
end

function MapSelect.new(deps)
	local self = setmetatable({}, MapSelect)
	self.remotes = deps.remotes
	self.toast = deps.toast
	self.player = Players.LocalPlayer
	self.snap = nil
	self.page = 1
	self.seq = 0
	self.racing = false
	self.CloseRequested = Utility.Signal.new()
	local gui, root, maid = UIKit.screen("TumbleMapSelect", 22)
	self.gui, self.root, self.maid = gui, root, maid

	local panel = UIKit.panel(root, { Name = "MapSelect", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(940, 470), BackgroundTransparency = 0.04, Visible = false })
	UIKit.new("UIStroke", { Color = palette.Cyan, Thickness = 2 }, panel)
	self.panel = panel
	UIKit.label(panel, { Position = UDim2.fromOffset(24, 10), Size = UDim2.new(1, -330, 0, 40), Font = Enum.Font.GothamBlack, TextColor3 = palette.Cyan, Text = "MAP SELECTION", TextXAlignment = Enum.TextXAlignment.Left })
	self.subtitle = UIKit.label(panel, { Position = UDim2.fromOffset(24, 50), Size = UDim2.new(1, -48, 0, 22), Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left, Text = "" })
	local close = UIKit.button(panel, { Name = "Close", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -16, 0, 12), Size = UDim2.fromOffset(130, 46), Text = "DONE" }, palette.Mint)
	maid:Give(close.Activated:Connect(function()
		self.CloseRequested:Fire()
	end))
	self.prev = UIKit.button(panel, { Name = "MapPage", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -220, 0, 12), Size = UDim2.fromOffset(56, 46), Text = "<", Visible = false }, palette.Cyan)
	self.next = UIKit.button(panel, { Name = "MapPage", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -156, 0, 12), Size = UDim2.fromOffset(56, 46), Text = ">", Visible = false }, palette.Cyan)
	maid:Give(self.prev.Activated:Connect(function()
		self.page = math.max(1, self.page - 1)
		self:Render()
	end))
	maid:Give(self.next.Activated:Connect(function()
		self.page = self.page + 1
		self:Render()
	end))

	self.cards = {}
	for i = 1, MapSelect.MaxCards do
		local x = 24 + (i - 1) * 300
		local c = UIKit.panel(panel, { Name = "Card" .. i, Position = UDim2.fromOffset(x, 82), Size = UDim2.fromOffset(292, 372), BackgroundColor3 = palette.Ink, BackgroundTransparency = 0.1 })
		local swatch = UIKit.new("Frame", { Name = "Swatch", Position = UDim2.fromOffset(10, 10), Size = UDim2.new(1, -20, 0, 54), BackgroundTransparency = 1 }, c)
		local bars = {}
		for k = 1, 4 do
			bars[k] = UIKit.new("Frame", { Position = UDim2.fromScale((k - 1) / 4, 0), Size = UDim2.fromScale(0.25, 1), BorderSizePixel = 0, BackgroundColor3 = palette.Navy }, swatch)
		end
		UIKit.corner(swatch, 0.2)
		local name = UIKit.label(c, { Position = UDim2.fromOffset(12, 70), Size = UDim2.new(1, -24, 0, 30), Font = Enum.Font.GothamBlack, TextXAlignment = Enum.TextXAlignment.Left, Text = "" })
		local meta = UIKit.label(c, { Position = UDim2.fromOffset(12, 100), Size = UDim2.new(1, -24, 0, 20), Font = Enum.Font.GothamBold, TextColor3 = palette.Yellow, TextXAlignment = Enum.TextXAlignment.Left, Text = "" })
		local blurb = UIKit.label(c, { Position = UDim2.fromOffset(12, 122), Size = UDim2.new(1, -24, 0, 54), Font = Enum.Font.Gotham, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Text = "" })
		local hub = UIKit.label(c, { Position = UDim2.fromOffset(12, 178), Size = UDim2.new(1, -24, 0, 34), Font = Enum.Font.Gotham, TextWrapped = true, TextColor3 = palette.Mint, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Text = "" })
		local visit = UIKit.button(c, { Name = "MapVisit", Position = UDim2.fromOffset(10, 216), Size = UDim2.new(0.5, -14, 0, 46), Text = "VISIT HUB" }, palette.Cyan)
		local practice = UIKit.button(c, { Name = "MapPractice", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -10, 0, 216), Size = UDim2.new(0.5, -14, 0, 46), Text = "PRACTICE" }, palette.Mint)
		local vote = UIKit.button(c, { Name = "MapBallot", Position = UDim2.fromOffset(10, 270), Size = UDim2.new(1, -20, 0, 54), Text = "VOTE NEXT RACE" }, palette.Violet)
		local votes = UIKit.label(c, { Position = UDim2.fromOffset(12, 330), Size = UDim2.new(1, -24, 0, 30), Font = Enum.Font.GothamBold, Text = "" })
		local entry = { frame = c, bars = bars, name = name, meta = meta, blurb = blurb, hub = hub, visit = visit, practice = practice, vote = vote, votes = votes }
		self.cards[i] = entry
		maid:Give(visit.Activated:Connect(function()
			self:_destination(entry, 1)
		end))
		maid:Give(practice.Activated:Connect(function()
			self:_destination(entry, 2)
		end))
		maid:Give(vote.Activated:Connect(function()
			self:_vote(entry)
		end))
	end

	maid:Give(self.remotes.DestinationResult.OnClientEvent:Connect(function(result)
		if type(result) == "table" then
			local text = REASONS[result.reason]
			if text and self.toast then
				self.toast(text, 2)
			end
			if result.ok and result.reason ~= "after_race" then
				self.CloseRequested:Fire() -- you're on your way: get the menu out of the view
			end
		end
	end))
	maid:Give(self.player:GetAttributeChangedSignal(Protocol.PlayerAttributes.Hub):Connect(function()
		self:Render()
	end))
	return self
end

function MapSelect:RegisterLayers(ui)
	ui:Register("MapSelect", function(visible)
		UIKit.Show(self.panel, visible, "Pop")
		if visible then
			self:Render()
		end
	end)
end

function MapSelect:SetRacing(racing)
	if self.racing ~= racing then
		self.racing = racing
		self:Render()
	end
end

function MapSelect:ApplySnapshot(snap)
	self.snap = snap
	if self.panel.Visible then
		self:Render()
	end
end

function MapSelect:_ctx()
	return {
		snap = self.snap,
		myUserId = self.player.UserId,
		myHub = self.player:GetAttribute(Protocol.PlayerAttributes.Hub) or MapRegistry.DefaultHubId,
		features = features(self.player),
		racing = self.racing,
	}
end

function MapSelect:_maps()
	local out = {}
	local ballot = self.snap and self.snap.ballot
	local listed = {}
	for _, id in ipairs(ballot and ballot.maps or {}) do
		listed[id] = true
	end
	for _, map in ipairs(MapRegistry.EnabledMaps(features(self.player))) do
		if listed[map.Id] or not ballot then
			out[#out + 1] = map
		end
	end
	return out
end

function MapSelect:Render()
	if not self.panel then
		return
	end
	local maps = self:_maps()
	local pages = math.max(1, math.ceil(#maps / MapSelect.MaxCards))
	self.page = math.min(self.page, pages)
	self.prev.Visible = pages > 1
	self.next.Visible = pages > 1
	local ctx = self:_ctx()
	local hub = MapRegistry.Hub(ctx.myHub, ctx.features)
	local ballot = self.snap and self.snap.ballot
	local lead = self.snap and self.snap.nextWorldId and MapRegistry.RawMap(self.snap.nextWorldId)
	self.subtitle.Text = string.format("You're in %s.  Next race: %s%s", hub.Meta.DisplayName, lead and lead.Meta.DisplayName or "?", ballot and ballot.counted and ballot.counted > 0 and string.format(" (%d vote%s)", ballot.counted, ballot.counted == 1 and "" or "s") or "")
	for i, entry in ipairs(self.cards) do
		local map = maps[(self.page - 1) * MapSelect.MaxCards + i]
		entry.frame.Visible = map ~= nil
		entry.map = map
		if map then
			local st = MapSelect.CardState(map, ctx)
			entry.state = st
			for k, bar in ipairs(entry.bars) do
				local hex = st.card.swatch and st.card.swatch[k]
				bar.BackgroundColor3 = hex and color(hex) or palette.Navy
			end
			entry.name.Text = string.upper(st.card.name)
			entry.meta.Text = string.format("%s  -  %s", string.upper(st.card.difficulty), st.card.skill)
			entry.blurb.Text = st.card.blurb
			entry.hub.Text = st.note or ("Hub: " .. st.hubName)
			entry.visit.Text = st.visitText
			entry.visit.AutoButtonColor = st.visitEnabled
			entry.visit.BackgroundTransparency = st.visitEnabled and 0 or 0.55
			entry.practice.Text = st.practiceEnabled and "PRACTICE" or "AFTER RACE"
			entry.practice.AutoButtonColor = st.practiceEnabled
			entry.practice.BackgroundTransparency = st.practiceEnabled and 0 or 0.55
			entry.vote.Text = st.voted and "YOUR VOTE" or (st.voteEnabled and "VOTE NEXT RACE" or "NOT IN ROTATION")
			entry.vote.AutoButtonColor = st.voteEnabled and not st.voted
			entry.vote.BackgroundTransparency = st.voteEnabled and 0 or 0.55
			entry.votes.Text = st.voteEnabled and string.format("%d vote%s", st.votes, st.votes == 1 and "" or "s") or ""
		end
	end
end

function MapSelect:_destination(entry, mode)
	local st = entry.state
	if not st then
		return
	end
	if mode == 1 and not st.visitEnabled then
		if self.toast then
			self.toast(self.racing and "You'll go there after this race." or "You're already here.", 1.6)
		end
		if not self.racing then
			return
		end
	end
	if mode == 2 and not st.practiceEnabled then
		if self.toast then
			self.toast("Practice after this race.", 1.6)
		end
		return
	end
	local index = hubIndexOf(st.hubId)
	if index then
		self.remotes.RequestDestination:FireServer(index, mode)
	end
end

function MapSelect:_vote(entry)
	local st = entry.state
	local ballot = self.snap and self.snap.ballot
	if not (st and st.voteEnabled and ballot) then
		if self.toast then
			self.toast("This map isn't in the race rotation here.", 1.8)
		end
		return
	end
	if st.voted then
		return
	end
	self.seq = self.seq + 1
	self.remotes.RequestBallot:FireServer(st.mapIndex, ballot.epoch, self.seq)
end

-- the lobby's ballot strip uses the same request (one sequence per client)
function MapSelect:CastBallot(mapIndex)
	local ballot = self.snap and self.snap.ballot
	if not ballot or not ballot.maps[mapIndex] then
		return false
	end
	self.seq = self.seq + 1
	self.remotes.RequestBallot:FireServer(mapIndex, ballot.epoch, self.seq)
	return true
end

function MapSelect:Destroy()
	self.maid:Cleanup()
	self.gui:Destroy()
end

return MapSelect
