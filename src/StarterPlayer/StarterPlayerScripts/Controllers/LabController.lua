--[[
	LabController (C) — the CAPSULE LAB modal: tabs CAPSULE, SHARD SHOP, SEASON.
	Everything is earned: capsules cost earned Coins, Shards come from duplicates and the season,
	the season track is free. Nothing here costs Robux and there is no paid button.
	- CAPSULE: full odds before opening (tier and EVERY item, from CapsuleOdds with the server's
	  own pity counters), "Epic+ within N" / "Legendary+ within N", duplicate terms, Coins, the
	  last 20 openings. OPEN sends a fresh request id plus the counters you were shown; if the
	  server's differ it refuses and the panel refreshes. Reveal: 1.5 s, SKIP any time, instant
	  with reduced motion; no spinning reel, no near-miss.
	- SHARD SHOP: choose exactly the item you want; owned ones are marked and can't be bought.
	- SEASON: the configured season's name and end date (UTC), 30 free levels, CLAIM.
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CapsuleOdds = require(Shared:WaitForChild("CapsuleOdds"))
local Catalog = require(Shared:WaitForChild("Catalog"))
local SeasonConfig = require(Shared:WaitForChild("SeasonConfig"))
local Utility = require(Shared:WaitForChild("Utility"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local palette = UIKit.Palette

local Lab = {}
Lab.__index = Lab

Lab.RevealSeconds = 1.5

local function pools()
	local out = {}
	for _, tier in ipairs(CapsuleOdds.Tiers) do
		out[tier] = Catalog.MarblesOfRarity(tier)
	end
	return out
end

-- Pure: the odds lines the panel shows for these counters (tier lines + item lines)
function Lab.OddsLines(epicMisses, legendaryMisses)
	local tiers, branch = CapsuleOdds.TierTable(epicMisses, legendaryMisses)
	local p = pools()
	local tierLines = {}
	for _, tier in ipairs(CapsuleOdds.Tiers) do
		local n = #p[tier]
		tierLines[#tierLines + 1] = string.format("%s  %s  (each of %d: %s)", string.upper(tier), CapsuleOdds.Percent(tiers[tier]), n, CapsuleOdds.Percent(n > 0 and tiers[tier] / n or 0))
	end
	local itemLines = {}
	for _, entry in ipairs(CapsuleOdds.ItemOdds(p, epicMisses, legendaryMisses)) do
		itemLines[#itemLines + 1] = string.format("%s - %s - %s", Catalog.Get(entry.id).Name, entry.tier, CapsuleOdds.Percent(entry.p))
	end
	return tierLines, itemLines, branch
end

local function utcDate(epoch)
	local ok, text = pcall(function()
		return os.date("!%d %b %Y %H:%M UTC", epoch)
	end)
	return ok and text or tostring(epoch)
end

function Lab.new(deps)
	local self = setmetatable({}, Lab)
	self.remotes = deps.remotes
	self.toast = deps.toast
	self.reducedMotion = false
	self.CloseRequested = Utility.Signal.new()
	self.state = nil
	self.season = nil
	self.owned = {}
	self.tab = "Capsule"
	local gui, root, maid = UIKit.screen("TumbleLab", 22)
	self.gui, self.maid = gui, maid
	local panel = UIKit.panel(root, { Name = "Lab", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(900, 580), BackgroundTransparency = 0.04, Visible = false })
	UIKit.new("UIStroke", { Color = palette.Mint, Thickness = 2 }, panel)
	self.panel = panel
	UIKit.label(panel, { Position = UDim2.fromOffset(24, 12), Size = UDim2.fromOffset(330, 40), Font = Enum.Font.GothamBlack, TextColor3 = palette.Mint, Text = "CAPSULE LAB", TextXAlignment = Enum.TextXAlignment.Left })
	local close = UIKit.button(panel, { Name = "Close", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -16, 0, 12), Size = UDim2.fromOffset(130, 46), Text = "DONE" }, palette.Mint)
	maid:Give(close.Activated:Connect(function()
		self:_finishReveal()
		self.CloseRequested:Fire()
	end))
	self.tabButtons = {}
	for i, tab in ipairs({ "Capsule", "Shards", "Season" }) do
		local b = UIKit.button(panel, { Name = "LabTab", Position = UDim2.fromOffset(330 + (i - 1) * 138, 14), Size = UDim2.fromOffset(130, 42), Text = tab == "Shards" and "SHARD SHOP" or string.upper(tab) }, palette.Cyan)
		maid:Give(b.Activated:Connect(function()
			self:ShowTab(tab)
		end))
		self.tabButtons[tab] = b
	end
	self.pages = {}
	self:_buildCapsule(panel)
	self:_buildShards(panel)
	self:_buildSeason(panel)

	maid:Give(self.remotes.CapsuleState.OnClientEvent:Connect(function(data)
		if type(data) == "table" and type(data.epicMisses) == "number" then
			self.state = data
			self:_renderCapsule()
			self:_renderShards()
		end
	end))
	maid:Give(self.remotes.CapsuleResult.OnClientEvent:Connect(function(data)
		self:_onResult(data)
	end))
	maid:Give(self.remotes.SeasonState.OnClientEvent:Connect(function(data)
		if type(data) == "table" then
			self.season = data
			self:_renderSeason()
		end
	end))
	return self
end

function Lab:SetOwned(list)
	self.owned = {}
	for _, id in ipairs(list or {}) do
		self.owned[id] = true
	end
	self:_renderShards()
end

function Lab:SetReducedMotion(on)
	self.reducedMotion = on == true
end

function Lab:ShowTab(tab)
	self.tab = tab
	for name, page in pairs(self.pages) do
		page.Visible = name == tab
	end
	for name, b in pairs(self.tabButtons) do
		b.TextColor3 = name == tab and palette.Mint or palette.White
	end
end

---------------------------------------------------------------------------------------------
function Lab:_buildCapsule(panel)
	local page = UIKit.new("Frame", { Name = "CapsulePage", Position = UDim2.fromOffset(0, 64), Size = UDim2.new(1, 0, 1, -64), BackgroundTransparency = 1 }, panel)
	self.pages.Capsule = page
	UIKit.label(page, { Position = UDim2.fromOffset(24, 0), Size = UDim2.fromOffset(420, 24), Font = Enum.Font.GothamBlack, TextColor3 = palette.Yellow, Text = "FULL ODDS (THIS OPEN)", TextXAlignment = Enum.TextXAlignment.Left })
	self.tierLabels = {}
	for i = 1, 5 do
		self.tierLabels[i] = UIKit.label(page, { Position = UDim2.fromOffset(24, 26 + (i - 1) * 24), Size = UDim2.fromOffset(440, 22), Font = Enum.Font.GothamBold, TextColor3 = Catalog.RarityColors[CapsuleOdds.Tiers[i]], Text = "", TextXAlignment = Enum.TextXAlignment.Left })
	end
	self.branchLabel = UIKit.label(page, { Position = UDim2.fromOffset(24, 148), Size = UDim2.fromOffset(440, 22), Font = Enum.Font.Gotham, TextColor3 = palette.Mint, Text = "", TextXAlignment = Enum.TextXAlignment.Left })
	self.itemList = UIKit.new("ScrollingFrame", { Name = "ItemOdds", Position = UDim2.fromOffset(24, 174), Size = UDim2.fromOffset(440, 250), BackgroundColor3 = palette.NavyFloor, BackgroundTransparency = 0.2, BorderSizePixel = 0, ScrollBarThickness = 8, CanvasSize = UDim2.fromOffset(0, 35 * 20 + 8) }, page)
	self.itemLabels = {}
	for i = 1, 35 do
		self.itemLabels[i] = UIKit.label(self.itemList, { Position = UDim2.fromOffset(8, 4 + (i - 1) * 20), Size = UDim2.fromOffset(410, 18), Font = Enum.Font.Gotham, Text = "", TextXAlignment = Enum.TextXAlignment.Left })
	end
	UIKit.label(page, { Position = UDim2.fromOffset(24, 430), Size = UDim2.fromOffset(440, 80), Font = Enum.Font.Gotham, TextWrapped = true, TextTransparency = 0.1, TextXAlignment = Enum.TextXAlignment.Left, Text = "Every marble in a rarity is equally likely, including ones you own. Duplicate = Shards: Common 5, Rare 20, Epic 65, Legendary 200, Mythic 600. Free capsules use earned Coins only - nothing here costs Robux." })

	local right = UIKit.panel(page, { Position = UDim2.fromOffset(484, 0), Size = UDim2.fromOffset(392, 500), BackgroundColor3 = palette.NavyFloor, BackgroundTransparency = 0.1 })
	self.pityLabel = UIKit.label(right, { Position = UDim2.fromOffset(14, 8), Size = UDim2.fromOffset(364, 48), Font = Enum.Font.GothamBold, TextWrapped = true, TextColor3 = palette.Yellow, Text = "" })
	self.walletLabel = UIKit.label(right, { Position = UDim2.fromOffset(14, 58), Size = UDim2.fromOffset(364, 24), Font = Enum.Font.GothamBold, Text = "" })
	self.openButton = UIKit.button(right, { Name = "OpenCapsule", Position = UDim2.fromOffset(14, 88), Size = UDim2.fromOffset(364, 52), Text = "OPEN FREE CAPSULE" }, palette.Mint)
	self.maid:Give(self.openButton.Activated:Connect(function()
		self:Open()
	end))
	self.statusLabel = UIKit.label(right, { Position = UDim2.fromOffset(14, 144), Size = UDim2.fromOffset(364, 22), Font = Enum.Font.Gotham, TextColor3 = palette.Mint, Text = "" })
	-- reveal
	self.reveal = UIKit.panel(right, { Name = "Reveal", Position = UDim2.fromOffset(14, 170), Size = UDim2.fromOffset(364, 110), BackgroundColor3 = palette.Navy, Visible = false })
	self.revealStroke = UIKit.new("UIStroke", { Color = palette.White, Thickness = 3 }, self.reveal)
	self.revealText = UIKit.label(self.reveal, { Position = UDim2.fromOffset(10, 8), Size = UDim2.new(1, -110, 1, -16), Font = Enum.Font.GothamBlack, TextScaled = true, TextWrapped = true, Text = "" })
	self.skipButton = UIKit.button(self.reveal, { Name = "SkipReveal", AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -8, 0.5, 0), Size = UDim2.fromOffset(90, 44), Text = "SKIP" }, palette.White)
	self.maid:Give(self.skipButton.Activated:Connect(function()
		self:_finishReveal()
	end))
	UIKit.label(right, { Position = UDim2.fromOffset(14, 286), Size = UDim2.fromOffset(364, 22), Font = Enum.Font.GothamBlack, TextColor3 = palette.Cyan, Text = "LAST 20 OPENED", TextXAlignment = Enum.TextXAlignment.Left })
	self.historyList = UIKit.new("ScrollingFrame", { Position = UDim2.fromOffset(14, 310), Size = UDim2.fromOffset(364, 180), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 6, CanvasSize = UDim2.fromOffset(0, 20 * 20 + 4) }, right)
	self.historyLabels = {}
	for i = 1, 20 do
		self.historyLabels[i] = UIKit.label(self.historyList, { Position = UDim2.fromOffset(4, (i - 1) * 20), Size = UDim2.fromOffset(340, 18), Font = Enum.Font.Gotham, Text = "", TextXAlignment = Enum.TextXAlignment.Left })
	end
end

function Lab:_renderCapsule()
	local st = self.state
	if not st then
		self.pityLabel.Text = "Loading your capsule data..."
		self.openButton.AutoButtonColor = false
		return
	end
	local tierLines, itemLines, branch = Lab.OddsLines(st.epicMisses, st.legendaryMisses)
	for i, label in ipairs(self.tierLabels) do
		label.Text = tierLines[i] or ""
	end
	for i, label in ipairs(self.itemLabels) do
		label.Text = itemLines[i] or ""
	end
	self.branchLabel.Text = branch == "LegendaryPity" and "Legendary+ guaranteed on this open" or branch == "EpicPity" and "Epic+ guaranteed on this open" or "Standard odds"
	local epicIn, legIn = CapsuleOdds.Within(st.epicMisses, st.legendaryMisses)
	self.pityLabel.Text = string.format("Epic+ within %d open%s  -  Legendary+ within %d open%s  (no Mythic guarantee)", epicIn, epicIn == 1 and "" or "s", legIn, legIn == 1 and "" or "s")
	self.walletLabel.Text = string.format("COINS %d   -   SHARDS %d   -   cost %d Coins", st.coins, st.shards, st.cost)
	local can = st.coins >= st.cost and st.canSave and not self.pending
	self.openButton.AutoButtonColor = can
	self.openButton.BackgroundTransparency = can and 0 or 0.6
	self.openButton.Text = st.canSave and string.format("OPEN FREE CAPSULE  (%d COINS)", st.cost) or "SAVING UNAVAILABLE - PAUSED"
	for i, label in ipairs(self.historyLabels) do
		local h = st.history[i]
		local item = h and Catalog.Get(h.id)
		label.Text = item and string.format("%s - %s%s", item.Name, h.tier, h.dup and string.format(" (dup +%d Shards)", h.shards) or "") or (i == 1 and "Nothing opened yet" or "")
		label.TextColor3 = h and Catalog.RarityColors[h.tier] or palette.White
	end
end

function Lab:Open()
	local st = self.state
	if not st then
		self.toast("Capsule data not loaded yet - nothing was spent", 2)
		self.remotes.RequestCapsuleState:FireServer()
		return
	end
	if self.pending then
		return
	end
	if st.coins < st.cost then
		self.toast(string.format("You need %d Coins (earned by racing)", st.cost), 2)
		return
	end
	local requestId = HttpService:GenerateGUID(false)
	self.pending = { id = requestId, at = os.clock() }
	self.statusLabel.Text = "Opening..."
	self:_renderCapsule()
	self.remotes.RequestOpenCapsule:FireServer(requestId, st.version, st.epicMisses, st.legendaryMisses)
	task.delay(8, function()
		if self.pending and self.pending.id == requestId then
			self.pending = nil
			self.statusLabel.Text = "No answer from the server. If it went through, it's in your history."
			self.remotes.RequestCapsuleState:FireServer()
		end
	end)
end

function Lab:_onResult(data)
	if type(data) ~= "table" or not self.pending or data.requestId ~= self.pending.id then
		return -- a duplicate or late response
	end
	self.pending = nil
	if not data.ok then
		self.statusLabel.Text = tostring(data.reason or "Not opened")
		self.remotes.RequestCapsuleState:FireServer()
		return
	end
	local item = Catalog.Get(data.id)
	if not item then
		self.statusLabel.Text = "Opened - see your history"
		return
	end
	self.revealResult = string.format("%s\n%s%s", string.upper(item.Name), string.upper(data.tier), data.dup and string.format("  (duplicate: +%d SHARDS)", data.shards) or "  NEW!")
	self.revealColor = Catalog.RarityColors[data.tier]
	self.reveal.Visible = true
	self.statusLabel.Text = ""
	if self.reducedMotion then
		self:_finishReveal()
		return
	end
	self.revealText.Text = "..."
	self.revealStroke.Color = palette.White
	local token = {}
	self.revealToken = token
	task.delay(Lab.RevealSeconds, function()
		if self.revealToken == token then
			self:_finishReveal()
		end
	end)
end

function Lab:_finishReveal()
	if self.revealResult then
		self.revealText.Text = self.revealResult
		self.revealText.TextColor3 = self.revealColor or palette.White
		self.revealStroke.Color = self.revealColor or palette.White
		self.revealResult = nil
	end
	self.revealToken = nil
end

---------------------------------------------------------------------------------------------
function Lab:_buildShards(panel)
	local page = UIKit.new("Frame", { Name = "ShardsPage", Position = UDim2.fromOffset(0, 64), Size = UDim2.new(1, 0, 1, -64), BackgroundTransparency = 1, Visible = false }, panel)
	self.pages.Shards = page
	self.shardWallet = UIKit.label(page, { Position = UDim2.fromOffset(24, 0), Size = UDim2.fromOffset(850, 26), Font = Enum.Font.GothamBlack, TextColor3 = palette.Violet, Text = "", TextXAlignment = Enum.TextXAlignment.Left })
	self.shardGrid = UIKit.new("ScrollingFrame", { Position = UDim2.fromOffset(16, 32), Size = UDim2.fromOffset(868, 470), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 8 }, page)
	self.shardTiles = {}
end

function Lab:_renderShards()
	if not self.shardGrid then
		return
	end
	local st = self.state
	local shards = st and st.shards or 0
	self.shardWallet.Text = string.format("SHARDS %d  -  pick exactly the item you want. Prices: Common 60, Rare 180, Epic 600, Legendary 1900, Mythic 6000. Shards are earned only.", shards)
	for _, tile in ipairs(self.shardTiles) do
		tile:Destroy()
	end
	self.shardTiles = {}
	local i = 0
	for _, kind in ipairs({ "Marble", "Trail", "Burst", "Emote" }) do
		for _, item in ipairs(Catalog.ByKind[kind]) do
			if not item.Exclusive then -- D: Founder / season-premium items are not in the Shard Shop
			i = i + 1
			local owned = self.owned[item.Id]
			local price = CapsuleOdds.ShardPrice[item.Rarity]
			local x, y = (i - 1) % 6, math.floor((i - 1) / 6)
			local tile = UIKit.button(self.shardGrid, { Name = "ShardItem", Position = UDim2.fromOffset(4 + x * 142, 4 + y * 74), Size = UDim2.fromOffset(136, 68), Text = "" }, Catalog.RarityColors[item.Rarity])
			tile.BackgroundTransparency = owned and 0.6 or 0
			UIKit.label(tile, { Position = UDim2.fromScale(0.05, 0.05), Size = UDim2.fromScale(0.9, 0.5), Font = Enum.Font.GothamBlack, TextScaled = true, Text = item.Name })
			UIKit.label(tile, { Position = UDim2.fromScale(0.05, 0.58), Size = UDim2.fromScale(0.9, 0.36), Font = Enum.Font.GothamBold, TextScaled = true, TextColor3 = Catalog.RarityColors[item.Rarity], Text = owned and "OWNED" or string.format("%s - %d SHARDS", string.upper(kind), price) })
			self.maid:Give(tile.Activated:Connect(function()
				if owned then
					self.toast("You already own " .. item.Name, 1.5)
				elseif shards < price then
					self.toast(string.format("You need %d Shards (you have %d)", price, shards), 2)
				else
					self.remotes.RequestShardBuy:FireServer(item.Id)
				end
			end))
			self.shardTiles[#self.shardTiles + 1] = tile
			end
		end
	end
	self.shardGrid.CanvasSize = UDim2.fromOffset(0, math.ceil(i / 6) * 74 + 8)
end

---------------------------------------------------------------------------------------------
function Lab:_buildSeason(panel)
	local page = UIKit.new("Frame", { Name = "SeasonPage", Position = UDim2.fromOffset(0, 64), Size = UDim2.new(1, 0, 1, -64), BackgroundTransparency = 1, Visible = false }, panel)
	self.pages.Season = page
	self.seasonTitle = UIKit.label(page, { Position = UDim2.fromOffset(24, 0), Size = UDim2.fromOffset(850, 28), Font = Enum.Font.GothamBlack, TextColor3 = palette.Yellow, Text = "", TextXAlignment = Enum.TextXAlignment.Left })
	self.seasonSub = UIKit.label(page, { Position = UDim2.fromOffset(24, 30), Size = UDim2.fromOffset(850, 22), Font = Enum.Font.Gotham, Text = "", TextXAlignment = Enum.TextXAlignment.Left })
	self.seasonGrid = UIKit.new("Frame", { Position = UDim2.fromOffset(16, 60), Size = UDim2.fromOffset(868, 440), BackgroundTransparency = 1 }, page)
	self.seasonTiles = {}
	for level = 1, SeasonConfig.Levels do
		local x, y = (level - 1) % 6, math.floor((level - 1) / 6)
		local tile = UIKit.button(self.seasonGrid, { Name = "SeasonClaim", Position = UDim2.fromOffset(4 + x * 142, 4 + y * 86), Size = UDim2.fromOffset(136, 80), Text = "" }, palette.Yellow)
		local title = UIKit.label(tile, { Position = UDim2.fromScale(0.05, 0.04), Size = UDim2.fromScale(0.9, 0.3), Font = Enum.Font.GothamBlack, TextScaled = true, Text = "LV " .. level })
		local reward = UIKit.label(tile, { Position = UDim2.fromScale(0.05, 0.36), Size = UDim2.fromScale(0.9, 0.3), Font = Enum.Font.GothamBold, TextScaled = true, Text = "" })
		local state = UIKit.label(tile, { Position = UDim2.fromScale(0.05, 0.68), Size = UDim2.fromScale(0.9, 0.28), Font = Enum.Font.Gotham, TextScaled = true, Text = "" })
		self.maid:Give(tile.Activated:Connect(function()
			self.remotes.RequestSeasonClaim:FireServer(level)
		end))
		self.seasonTiles[level] = { tile = tile, title = title, reward = reward, state = state }
	end
end

function Lab.RewardText(reward)
	if reward.kind == "Coins" then
		return string.format("%d COINS", reward.amount)
	elseif reward.kind == "Shards" then
		return string.format("%d SHARDS", reward.amount)
	end
	local item = Catalog.Get(reward.id)
	return item and item.Name or reward.id
end

function Lab:_renderSeason()
	local data = self.season
	if not data or not data.season then
		self.seasonTitle.Text = "NO SEASON RUNNING RIGHT NOW"
		self.seasonSub.Text = "The free season track appears here when a season is on."
		self.seasonGrid.Visible = false
		return
	end
	self.seasonGrid.Visible = true
	local level = SeasonConfig.LevelForXp(data.xp)
	self.seasonTitle.Text = string.upper(data.season.name)
	self.seasonSub.Text = string.format("Free track - season level %d/%d (%d XP, %d per level) - ends %s. Race and claim quests to level up.", level, SeasonConfig.Levels, data.xp, SeasonConfig.XpPerLevel, utcDate(data.season.endsAt))
	local claimed = {}
	for _, l in ipairs(data.claimed or {}) do
		claimed[l] = true
	end
	for l, t in ipairs(self.seasonTiles) do
		t.reward.Text = Lab.RewardText(SeasonConfig.Reward(l))
		t.state.Text = claimed[l] and "CLAIMED" or l <= level and "CLAIM" or "LOCKED"
		t.tile.BackgroundTransparency = (claimed[l] or l > level) and 0.6 or 0
	end
end

function Lab:RegisterLayers(ui)
	ui:Register("Lab", function(visible)
		self.panel.Visible = visible
		if visible then
			self:ShowTab(self.tab)
			self.remotes.RequestCapsuleState:FireServer()
			self:_renderCapsule()
			self:_renderSeason()
		end
	end)
end

function Lab:Destroy()
	self.maid:Cleanup()
end

return Lab
