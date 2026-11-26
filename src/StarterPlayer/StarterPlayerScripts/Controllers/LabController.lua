--[[
	LabController (C) — the CAPSULE LAB modal: tabs CAPSULE, SHARD SHOP, SEASON.
	Everything is earned: capsules cost earned Coins, Shards come from duplicates and the season,
	the season track is free. Nothing here costs Robux and there is no paid button.
	- CAPSULE (owner request 2026-11-26): four capsules, one per kind (Marble / Trail / Burst /
	  Emote), each with its full contents and exact odds for THIS open (tiers and every item,
	  from CapsuleOdds with the server's own pity counters). OPEN sends a fresh request id, the
	  counters you were shown and the capsule id. The server decides and saves the result
	  first; only then does the "racing spool" reveal play (CapsuleRevealController: masked
	  silhouettes, the winner crosses the line, only it is unmasked). A slow answer shows a
	  syncing screen, never a fake animation. A result you haven't seen (closed the game
	  mid-reveal, lost connection) waits in your history and plays the next time you open the
	  Lab; the reveal tells the server you've seen it (RequestCapsuleSeen, display only).
	- SHARD SHOP: choose exactly the item you want; owned ones are marked and can't be bought.
	- SEASON: the configured season's name and end date (UTC), 30 free levels, CLAIM.
]]

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CapsuleOdds = require(Shared:WaitForChild("CapsuleOdds"))
local QuestConfig = require(Shared:WaitForChild("QuestConfig"))
local Catalog = require(Shared:WaitForChild("Catalog"))
local SeasonConfig = require(Shared:WaitForChild("SeasonConfig"))
local Utility = require(Shared:WaitForChild("Utility"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))
local CapsuleReveal = require(script.Parent:WaitForChild("CapsuleRevealController"))
local ItemSwatch = require(script.Parent:WaitForChild("ItemSwatch"))

local palette = UIKit.Palette

local Lab = {}
Lab.__index = Lab

local function pools(boxId)
	return CapsuleOdds.PoolsFor(CapsuleOdds.Box(boxId), Catalog.ItemsOfRarity)
end
Lab.Pools = pools

Lab.BoxColors = {
	Starter = Color3.fromRGB(110, 231, 186),
	Marble = Color3.fromRGB(39, 215, 245),
	Trail = Color3.fromRGB(160, 120, 255),
	Apex = Color3.fromRGB(255, 196, 96),
}

-- Pure: how far a case is in quests (brief: "show the exact cost, balance and a reachable
-- quest plan"). One daily quest = QuestConfig.Rewards.Daily.coins.
function Lab.QuestPlan(balance, cost, dailyCoins, weeklyCoins)
	local missing = cost - (balance or 0)
	if missing <= 0 then
		return string.format("You have %d Coins - enough for this case.", balance)
	end
	local dailies = math.ceil(missing / dailyCoins)
	return string.format("%d more Coins needed: about %d daily quest%s (%d Coins each) or %d weekly (%d each).", missing, dailies, dailies == 1 and "" or "s", dailyCoins, math.ceil(missing / weeklyCoins), weeklyCoins)
end

-- Pure: one filler entrant for the reveal, an independent draw from the capsule's shown odds
-- (rng() in [0,1)). Display only: the reward was decided by the server before this runs.
function Lab.Filler(boxId, epicMisses, legendaryMisses, rng)
	local p = pools(boxId)
	local u, acc = rng(), 0
	local entries = CapsuleOdds.ItemOdds(p, epicMisses, legendaryMisses)
	for _, entry in ipairs(entries) do
		acc = acc + entry.p
		if u < acc then
			return entry.id
		end
	end
	return entries[#entries] and entries[#entries].id
end

-- Pure: the newest saved result the player hasn't seen yet (history is newest first)
function Lab.Unseen(history)
	for _, h in ipairs(history or {}) do
		if h.seen == false then
			return h
		end
	end
	return nil
end

-- Pure: the odds lines the panel shows for these counters (tier lines + item lines)
function Lab.OddsLines(epicMisses, legendaryMisses, boxId)
	local p = pools(boxId)
	local tiers, branch = CapsuleOdds.EffectiveTiers(p, epicMisses, legendaryMisses)
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
		self.CloseRequested:Fire()
	end))
	self.reveal = maid:Give(CapsuleReveal.new({ sound = deps.sound, remotes = self.remotes }))
	maid:Give(self.reveal.Finished:Connect(function(action, result)
		self:_revealFinished(action, result)
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
			self:_checkUnseen()
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
	self.reveal:SetReducedMotion(self.reducedMotion)
end

-- Open the capsule page on one case (Shop > CASES > VIEW ODDS)
function Lab:SelectBox(boxId)
	if CapsuleOdds.BoxById[boxId or ""] then
		self.boxId = boxId
		self.tab = "Capsule"
		self:ShowTab("Capsule")
		self:_renderCapsule()
	end
end

function Lab:SetQuality(low)
	self.reveal:SetQuality(low)
end

function Lab:ShowTab(tab)
	self.tab = tab
	for name, page in pairs(self.pages) do
		UIKit.Show(page, name == tab, "FromRight", 0.2)
	end
	for name, b in pairs(self.tabButtons) do
		b.TextColor3 = name == tab and palette.Mint or palette.White
	end
end

---------------------------------------------------------------------------------------------
function Lab:_buildCapsule(panel)
	local page = UIKit.new("Frame", { Name = "CapsulePage", Position = UDim2.fromOffset(0, 64), Size = UDim2.new(1, 0, 1, -64), BackgroundTransparency = 1 }, panel)
	self.pages.Capsule = page
	self.boxId = "Marble"
	-- capsule list (left)
	self.boxTiles = {}
	for i, box in ipairs(CapsuleOdds.Boxes) do
		local tile = UIKit.button(page, { Name = "CapsuleBox", Position = UDim2.fromOffset(24, (i - 1) * 118), Size = UDim2.fromOffset(200, 108), Text = "" }, palette.White)
		local crate = UIKit.new("Frame", { Name = "Crate", Position = UDim2.fromOffset(10, 18), Size = UDim2.fromOffset(60, 60), BackgroundColor3 = Lab.BoxColors[box.Id], BorderSizePixel = 0 }, tile)
		UIKit.corner(crate, 0.15)
		UIKit.new("Frame", { Position = UDim2.fromScale(0, 0.42), Size = UDim2.fromScale(1, 0.16), BackgroundColor3 = palette.Ink, BorderSizePixel = 0 }, crate)
		UIKit.label(tile, { Position = UDim2.fromOffset(78, 10), Size = UDim2.fromOffset(116, 16), Font = Enum.Font.GothamBold, TextTransparency = 0.25, TextXAlignment = Enum.TextXAlignment.Left, Text = box.Tier or "" })
		UIKit.label(tile, { Position = UDim2.fromOffset(78, 28), Size = UDim2.fromOffset(116, 34), TextWrapped = true, Font = Enum.Font.GothamBlack, TextXAlignment = Enum.TextXAlignment.Left, Text = box.Name })
		UIKit.label(tile, { Position = UDim2.fromOffset(78, 66), Size = UDim2.fromOffset(116, 22), Font = Enum.Font.GothamBold, TextColor3 = palette.Yellow, TextXAlignment = Enum.TextXAlignment.Left, Text = box.Cost .. " COINS" })
		self.boxTiles[box.Id] = tile
		self.maid:Give(tile.Activated:Connect(function()
			if not self.pending then
				self.boxId = box.Id
				self:_renderCapsule()
			end
		end))
	end
	-- selected capsule (right)
	local right = UIKit.panel(page, { Position = UDim2.fromOffset(240, 0), Size = UDim2.fromOffset(636, 500), BackgroundColor3 = palette.NavyFloor, BackgroundTransparency = 0.1 })
	self.boxTitle = UIKit.label(right, { Position = UDim2.fromOffset(16, 8), Size = UDim2.fromOffset(330, 32), Font = Enum.Font.GothamBlack, TextXAlignment = Enum.TextXAlignment.Left, Text = "" })
	self.walletLabel = UIKit.label(right, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -16, 0, 12), Size = UDim2.fromOffset(280, 24), Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Right, Text = "" })
	self.pityLabel = UIKit.label(right, { Position = UDim2.fromOffset(16, 42), Size = UDim2.fromOffset(604, 20), Font = Enum.Font.Gotham, TextColor3 = palette.Yellow, TextXAlignment = Enum.TextXAlignment.Left, Text = "" })
	self.tierLine = UIKit.label(right, { Position = UDim2.fromOffset(16, 64), Size = UDim2.fromOffset(604, 20), Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Left, Text = "" })
	self.branchLabel = UIKit.label(right, { Position = UDim2.fromOffset(16, 86), Size = UDim2.fromOffset(604, 18), Font = Enum.Font.Gotham, TextColor3 = palette.Mint, TextXAlignment = Enum.TextXAlignment.Left, Text = "" })
	UIKit.label(right, { Position = UDim2.fromOffset(16, 108), Size = UDim2.fromOffset(604, 18), Font = Enum.Font.GothamBlack, TextColor3 = palette.Cyan, TextXAlignment = Enum.TextXAlignment.Left, Text = "CONTENTS - EVERY ITEM AND ITS CHANCE ON THIS OPEN" })
	self.contents = UIKit.new("ScrollingFrame", { Name = "Contents", Position = UDim2.fromOffset(16, 130), Size = UDim2.fromOffset(604, 222), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 6, CanvasSize = UDim2.fromOffset(0, 0) }, right)
	self.contentTiles = {}
	for i = 1, 40 do
		local col, row = (i - 1) % 5, math.floor((i - 1) / 5)
		local tile = UIKit.new("Frame", { Position = UDim2.fromOffset(col * 118, row * 72), Size = UDim2.fromOffset(112, 66), BackgroundColor3 = palette.Navy, BorderSizePixel = 0, Visible = false }, self.contents)
		UIKit.corner(tile, 0.12)
		local bar = UIKit.new("Frame", { AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 6), BorderSizePixel = 0 }, tile)
		local art = UIKit.new("Frame", { Name = "Art", Position = UDim2.fromOffset(4, 8), Size = UDim2.fromOffset(34, 34), BackgroundTransparency = 1 }, tile)
		local name = UIKit.label(tile, { Position = UDim2.fromOffset(42, 4), Size = UDim2.fromOffset(66, 38), TextWrapped = true, Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Left, Text = "" })
		local odds = UIKit.label(tile, { Position = UDim2.fromOffset(4, 44), Size = UDim2.new(1, -8, 0, 14), Font = Enum.Font.Gotham, Text = "" })
		self.contentTiles[i] = { frame = tile, bar = bar, name = name, odds = odds, art = art }
	end
	self.openButton = UIKit.Primary(UIKit.button(right, { Name = "OpenCapsule", Position = UDim2.fromOffset(16, 362), Size = UDim2.fromOffset(300, 52), Text = "OPEN" }, palette.Mint))
	self.maid:Give(self.openButton.Activated:Connect(function()
		self:Open()
	end))
	self.statusLabel = UIKit.label(right, { Position = UDim2.fromOffset(326, 362), Size = UDim2.fromOffset(294, 52), Font = Enum.Font.Gotham, TextWrapped = true, TextColor3 = palette.Mint, TextXAlignment = Enum.TextXAlignment.Left, Text = "" })
	UIKit.label(right, { Position = UDim2.fromOffset(16, 420), Size = UDim2.fromOffset(604, 18), Font = Enum.Font.GothamBlack, TextColor3 = palette.Cyan, TextXAlignment = Enum.TextXAlignment.Left, Text = "LAST 20 OPENED (ALL CAPSULES)" })
	local history = UIKit.new("ScrollingFrame", { Name = "History", Position = UDim2.fromOffset(16, 440), Size = UDim2.fromOffset(604, 42), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 5, CanvasSize = UDim2.fromOffset(0, CapsuleOdds.HistorySize * 20) }, right)
	self.historyLabels = {}
	for i = 1, CapsuleOdds.HistorySize do
		self.historyLabels[i] = UIKit.label(history, { Position = UDim2.fromOffset(0, (i - 1) * 20), Size = UDim2.fromOffset(590, 18), Font = Enum.Font.Gotham, Text = "", TextXAlignment = Enum.TextXAlignment.Left })
	end
	UIKit.label(right, { Position = UDim2.fromOffset(16, 484), Size = UDim2.fromOffset(604, 14), Font = Enum.Font.Gotham, TextTransparency = 0.3, TextXAlignment = Enum.TextXAlignment.Left, Text = "Coins come only from QUESTS - never Robux. Duplicates become Shards for the Shard Shop." })

end

function Lab:_renderCapsule()
	local st = self.state
	local box = CapsuleOdds.Box(self.boxId)
	for id, tile in pairs(self.boxTiles) do
		tile.BackgroundTransparency = id == box.Id and 0 or 0.55
		local stroke = tile:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = id == box.Id and Lab.BoxColors[id] or palette.White
			stroke.Transparency, stroke.Thickness = id == box.Id and 0 or 1, 2
		end
	end
	self.boxTitle.Text = box.Name
	self.boxTitle.TextColor3 = Lab.BoxColors[box.Id]
	if not st then
		self.pityLabel.Text = "Loading your capsule data..."
		self.openButton.AutoButtonColor = false
		return
	end
	local p = pools(box.Id)
	local epic, legendary = self:_counters(box.Id)
	local tiers, branch = CapsuleOdds.EffectiveTiers(p, epic, legendary)
	local parts = {}
	for _, tier in ipairs(CapsuleOdds.Tiers) do
		parts[#parts + 1] = string.upper(tier) .. " " .. CapsuleOdds.Percent(tiers[tier] or 0)
	end
	self.tierLine.Text = table.concat(parts, "   ")
	self.branchLabel.Text = branch == "LegendaryPity" and "Legendary+ guaranteed on this open (or this case's best tier)" or branch == "EpicPity" and "Epic+ guaranteed on this open (or this case's best tier)" or "Standard odds"
	local epicIn, legIn = CapsuleOdds.Within(epic, legendary)
	self.pityLabel.Text = string.format("Epic+ within %d open%s  -  Legendary+ within %d open%s  (this case's own counter; no Mythic guarantee)", epicIn, epicIn == 1 and "" or "s", legIn, legIn == 1 and "" or "s")
	self.walletLabel.Text = string.format("COINS %d  -  SHARDS %d", st.coins, st.shards)
	local items = CapsuleOdds.ItemOdds(p, epic, legendary)
	table.sort(items, function(a, b)
		local ra, rb = CapsuleOdds.Rank[a.tier], CapsuleOdds.Rank[b.tier]
		if ra ~= rb then
			return ra > rb
		end
		return a.id < b.id
	end)
	for i, tile in ipairs(self.contentTiles) do
		local entry = items[i]
		tile.frame.Visible = entry ~= nil
		if entry then
			local item = Catalog.Get(entry.id)
			tile.name.Text = item and ((box.Mixed and (string.upper(item.Kind == "Marble" and "Skin" or item.Kind) .. ": ") or "") .. item.Name) or entry.id
			tile.odds.Text = CapsuleOdds.Percent(entry.p) .. (self.owned[entry.id] and "  OWNED" or "")
			tile.bar.BackgroundColor3 = Catalog.RarityColors[entry.tier] or palette.White
			if tile.artFor ~= entry.id then
				tile.artFor = entry.id
				for _, child in ipairs(tile.art:GetChildren()) do
					child:Destroy()
				end
				ItemSwatch.Draw(tile.art, item or entry.id)
			end
		end
	end
	self.contents.CanvasSize = UDim2.fromOffset(0, math.ceil(#items / 5) * 72)
	local can = st.coins >= box.Cost and st.canSave and not self.pending and not self.reveal:IsOpen()
	self.openButton.AutoButtonColor = can
	self.openButton.BackgroundTransparency = can and 0 or 0.6
	self.openButton.Text = st.canSave and string.format("OPEN  (%d COINS)", box.Cost) or "SAVING UNAVAILABLE - PAUSED"
	if not self.pending then
		self.statusLabel.Text = Lab.QuestPlan(st.coins, box.Cost, QuestConfig.Rewards.Daily.coins, QuestConfig.Rewards.Weekly.coins)
	end
	for i, label in ipairs(self.historyLabels) do
		local h = st.history[i]
		local item = h and Catalog.Get(h.id)
		local boxName = h and CapsuleOdds.BoxName(h.box) or ""
		label.Text = item and string.format("%s - %s - %s%s", boxName, item.Name, h.tier, h.dup and string.format(" (dup +%d Shards)", h.shards) or "") or (i == 1 and "Nothing opened yet" or "")
		label.TextColor3 = h and Catalog.RarityColors[h.tier] or palette.White
	end
end

function Lab:Open()
	local st = self.state
	local box = CapsuleOdds.Box(self.boxId)
	if not st then
		self.toast("Capsule data not loaded yet - nothing was spent", 2)
		self.remotes.RequestCapsuleState:FireServer()
		return
	end
	if self.pending or self.reveal:IsOpen() then
		return -- one open at a time; repeated taps are ignored
	end
	if st.coins < box.Cost then
		self.toast(string.format("You need %d Coins", box.Cost), 2)
		return
	end
	local requestId = HttpService:GenerateGUID(false)
	local epic, legendary = self:_counters(box.Id)
	self.pending = { id = requestId, at = os.clock(), box = box.Id, epic = epic, legendary = legendary }
	self.statusLabel.Text = "Opening..."
	self:_renderCapsule()
	local priceSeen = (st.prices and st.prices[box.Id]) or box.Cost
	self.remotes.RequestOpenCapsule:FireServer(requestId, st.version, epic, legendary, box.Id, priceSeen)
	task.delay(0.6, function()
		if self.pending and self.pending.id == requestId then
			self.reveal:ShowSyncing() -- a slow answer: say so, never a fake animation
		end
	end)
	task.delay(8, function()
		if self.pending and self.pending.id == requestId then
			self.pending.lost = true
			self.reveal:ShowSyncing("Still syncing. If the open went through, its result is saved on the server and will play here as soon as it arrives (nothing is charged twice).")
			self.remotes.RequestCapsuleState:FireServer()
			task.delay(4, function()
				if self.pending and self.pending.id == requestId then
					self.pending = nil
					self.reveal:Close()
					self.statusLabel.Text = "No answer from the server. Check LAST 20 OPENED."
				end
			end)
		end
	end)
end

-- a case's guarantee counters from the server's state (per case since 2026-11-26)
function Lab:_counters(boxId)
	local st = self.state
	local p = st and st.pity and st.pity[boxId]
	if p then
		return p.e or 0, p.l or 0
	end
	return st and st.epicMisses or 0, st and st.legendaryMisses or 0
end

function Lab:_play(result, epic, legendary)
	local box = CapsuleOdds.Box(result.box)
	result.boxName = box.Name
	local rng = Random.new()
	local mixed = box.Mixed == true -- Starter / Apex: the masks show each entrant's category
	self.revealing = result.req or result.requestId
	self.reveal:Play(result, function()
		return Lab.Filler(box.Id, epic or 0, legendary or 0, function()
			return rng:NextNumber()
		end)
	end, mixed)
end

function Lab:_onResult(data)
	if type(data) ~= "table" or not self.pending or data.requestId ~= self.pending.id then
		return -- a duplicate or late response
	end
	local pending = self.pending
	self.pending = nil
	if not data.ok then
		self.reveal:Close()
		self.statusLabel.Text = tostring(data.reason or "Not opened")
		self.remotes.RequestCapsuleState:FireServer()
		return
	end
	self.statusLabel.Text = ""
	self:_play({ id = data.id, tier = data.tier, dup = data.dup, shards = data.shards, box = data.box or pending.box, req = data.requestId }, pending.epic, pending.legendary)
end

-- A saved result the player never saw (left mid-reveal, lost connection): play it, free.
function Lab:_checkUnseen()
	local h = self.state and Lab.Unseen(self.state.history)
	if not h or self.pending or self.reveal:IsOpen() or self.revealing == h.req then
		return
	end
	if not self.panel.Visible then
		if not self.unseenToastShown then
			self.unseenToastShown = true
			self.toast("A capsule result is waiting for you in the CAPSULE LAB", 3)
		end
		return
	end
	local e, l = self:_counters(h.box)
	self:_play({ id = h.id, tier = h.tier, dup = h.dup, shards = h.shards, box = h.box, req = h.req }, e, l)
end

function Lab:_revealFinished(action, result)
	self.revealing = nil
	if result and result.req and self.remotes.RequestCapsuleSeen then
		self.remotes.RequestCapsuleSeen:FireServer(result.req)
	end
	local item = result and Catalog.Get(result.id)
	if action == "Equip" and item and not result.dup then
		self.remotes.RequestEquipCosmetic:FireServer(item.Kind, item.Id, 0)
	end
	self:_renderCapsule()
	if self.openButton then
		pcall(function()
			game:GetService("GuiService").SelectedObject = self.openButton -- focus back on the Lab
		end)
	end
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
	for _, kind in ipairs(Catalog.Kinds) do
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
		UIKit.Show(self.panel, visible, "Pop")
		if visible then
			self:ShowTab(self.tab)
			self.remotes.RequestCapsuleState:FireServer() -- an unseen result plays when it arrives
			self:_renderCapsule()
			self:_renderSeason()
		end
	end)
end

function Lab:Destroy()
	self.maid:Cleanup()
end

return Lab
