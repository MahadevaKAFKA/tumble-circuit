--[[
	ShopController (D1) — the OPTIONAL cosmetic SHOP modal (MORE → SHOP, lobby only, never in a
	race). Direct choice only: pick one item, see Roblox's own price for you, then tap GET to open
	Roblox's purchase prompt. Nothing is granted here: the server grants after Roblox's receipt
	(or verified Game Pass ownership).
	- An offer with no configured id says "Not on sale yet" (no working button).
	- A failed price lookup says "Price unavailable" (no button) — never a guessed price.
	- Already owned → OWNED. Season premium says "Season 1 only".
	- No timers, no countdowns, no "last chance", no strike-through prices.
	2026-11-26 (brief section 4): two clearly labelled sections. ITEMS · ROBUX = guaranteed
	direct purchases (exactly the item shown; all off until product ids exist). CASES · COINS =
	the earned-Coin capsules: price in Coins and VIEW ODDS, which opens the Capsule Lab on that
	case with every item and its chance shown before anything is spent.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CapsuleOdds = require(Shared:WaitForChild("CapsuleOdds"))
local Catalog = require(Shared:WaitForChild("Catalog"))
local ShopConfig = require(Shared:WaitForChild("ShopConfig"))
local Utility = require(Shared:WaitForChild("Utility"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))
local ItemSwatch = require(script.Parent:WaitForChild("ItemSwatch"))

local palette = UIKit.Palette

local Shop = {}
Shop.__index = Shop

-- Pure: what an offer's button says. state = { id, owned }, price = number or nil, priceFailed
function Shop.ButtonText(state, price, priceFailed)
	if state.owned then
		return "OWNED", false
	end
	if not state.id then
		return "NOT ON SALE YET", false
	end
	if priceFailed then
		return "PRICE UNAVAILABLE", false
	end
	if not price then
		return "LOADING PRICE...", false
	end
	return string.format("GET  -  %d Robux", price), true
end

local function fetchPrice(id, kind)
	local infoType = kind == "GamePass" and Enum.InfoType.GamePass or Enum.InfoType.Product
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfoAsync(id, infoType)
	end)
	if not ok then
		ok, info = pcall(function()
			return MarketplaceService:GetProductInfo(id, infoType)
		end)
	end
	if ok and type(info) == "table" and type(info.PriceInRobux) == "number" and info.IsForSale ~= false then
		return info.PriceInRobux
	end
	return nil
end

function Shop.new(deps)
	local self = setmetatable({}, Shop)
	self.remotes = deps.remotes
	self.toast = deps.toast
	self.CloseRequested = Utility.Signal.new()
	self.CaseRequested = Utility.Signal.new() -- (boxId): open the Capsule Lab on this case
	self.state = nil
	self.prices = {} -- [sku] = number | false (failed)
	self.selected = ShopConfig.Offers[1].sku
	local gui, root, maid = UIKit.screen("TumbleShop", 23)
	self.gui, self.maid = gui, maid
	local panel = UIKit.panel(root, { Name = "Shop", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(860, 560), BackgroundTransparency = 0.04, Visible = false })
	UIKit.new("UIStroke", { Color = palette.Yellow, Thickness = 2 }, panel)
	self.panel = panel
	UIKit.Title(panel, { Position = UDim2.fromOffset(24, 16), Size = UDim2.fromOffset(300, 30), Text = "SHOP" })
	UIKit.label(panel, { Position = UDim2.fromOffset(24, 54), Size = UDim2.fromOffset(640, 18), Font = Enum.Font.Gotham, TextColor3 = UIKit.Colors.Muted, Text = "Looks only - nothing here changes speed, abilities, rewards or who you race.", TextXAlignment = Enum.TextXAlignment.Left })
	-- sections: guaranteed items (Robux) / cases (earned Coins)
	self.section = "Cases"
	self.sectionButtons = {}
	for i, sec in ipairs({ { "Cases", "CASES  ·  COINS" }, { "Items", "ITEMS  ·  ROBUX" } }) do
		local b = UIKit.button(panel, { Name = "ShopTab", Position = UDim2.fromOffset(380 + (i - 1) * 158, 14), Size = UDim2.fromOffset(150, 36), Text = sec[2] }, palette.White)
		maid:Give(b.Activated:Connect(function()
			self.section = sec[1]
			self:_renderSection()
		end))
		self.sectionButtons[sec[1]] = b
	end
	self.cases = UIKit.new("Frame", { Name = "Cases", Position = UDim2.fromOffset(16, 84), Size = UDim2.fromOffset(828, 460), BackgroundTransparency = 1, Visible = false }, panel)
	-- v2: four tall case cards side by side (art, tier, name, what it holds, price, VIEW ODDS)
	local caseColors = { Starter = Color3.fromRGB(110, 231, 186), Marble = Color3.fromRGB(39, 215, 245), Trail = Color3.fromRGB(160, 120, 255), Apex = Color3.fromRGB(255, 196, 96) }
	for i, box in ipairs(CapsuleOdds.Boxes) do
		local card = UIKit.panel(self.cases, { Position = UDim2.fromOffset(4 + (i - 1) * 206, 0), Size = UDim2.fromOffset(198, 452), BackgroundColor3 = palette.NavyFloor })
		local color = caseColors[box.Id] or palette.White
		UIKit.new("Frame", { Name = "CaseEdge", Size = UDim2.new(1, 0, 0, 4), BackgroundColor3 = color, BorderSizePixel = 0 }, card)
		local art = UIKit.Icon(card, "Case", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 30), Size = UDim2.fromOffset(110, 110) })
		for _, piece in ipairs(art:GetChildren()) do
			if piece:IsA("Frame") and piece.BackgroundColor3 ~= palette.Ink then
				piece.BackgroundColor3 = color
			end
		end
		UIKit.label(card, { Position = UDim2.fromOffset(14, 156), Size = UDim2.fromOffset(170, 14), Font = Enum.Font.GothamBold, TextColor3 = UIKit.Colors.Muted, TextXAlignment = Enum.TextXAlignment.Left, Text = box.Tier or "" })
		UIKit.label(card, { Position = UDim2.fromOffset(14, 174), Size = UDim2.fromOffset(170, 24), Font = Enum.Font.GothamBlack, TextXAlignment = Enum.TextXAlignment.Left, Text = box.Name })
		UIKit.label(card, { Position = UDim2.fromOffset(14, 206), Size = UDim2.fromOffset(170, 96), Font = Enum.Font.Gotham, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextScaled = false, TextSize = 15, TextColor3 = UIKit.Colors.Muted, TextXAlignment = Enum.TextXAlignment.Left, Text = (box.Mixed and ("Skins, trails, bursts and emotes - " .. (box.Rarities and box.Rarities.Epic and "Epic or better only." or "Common and Rare.")) or ("Every " .. (box.Kind == "Marble" and "marble skin" or string.lower(box.Kind)) .. ", any rarity.")) .. " Every chance is shown before you open. Duplicates become Shards." })
		UIKit.Title(card, { Position = UDim2.fromOffset(14, 318), Size = UDim2.fromOffset(170, 30), TextColor3 = palette.Yellow, Text = tostring(box.Cost) })
		UIKit.label(card, { Position = UDim2.fromOffset(14, 352), Size = UDim2.fromOffset(170, 14), Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Left, Text = "COINS (from quests)" })
		local view = UIKit.button(card, { Name = "ShopCase", Position = UDim2.fromOffset(14, 384), Size = UDim2.fromOffset(170, 50), Text = "VIEW ODDS" }, palette.White)
		maid:Give(view.Activated:Connect(function()
			self.CaseRequested:Fire(box.Id)
		end))
	end
	-- v2: guaranteed items as a grid of cards, each with the item in its real colours
	local cols = 3
	self.list = UIKit.new("ScrollingFrame", { Position = UDim2.fromOffset(16, 84), Size = UDim2.fromOffset(504, 460), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 6, CanvasSize = UDim2.fromOffset(0, math.ceil(#ShopConfig.Offers / cols) * 166 + 8) }, panel)
	self.rows = {}
	for i, offer in ipairs(ShopConfig.Offers) do
		local x, y = (i - 1) % cols, math.floor((i - 1) / cols)
		local b = UIKit.button(self.list, { Name = "ShopItem", Position = UDim2.fromOffset(4 + x * 164, 4 + y * 166), Size = UDim2.fromOffset(156, 158), Text = "" }, palette.White)
		local art = UIKit.new("Frame", { Position = UDim2.fromOffset(38, 8), Size = UDim2.fromOffset(80, 66), BackgroundTransparency = 1 }, b)
		ItemSwatch.Draw(art, offer.grants[1])
		local name = UIKit.label(b, { Position = UDim2.fromOffset(8, 80), Size = UDim2.fromOffset(140, 20), Font = Enum.Font.GothamBlack, Text = offer.label })
		local sub = UIKit.label(b, { Position = UDim2.fromOffset(8, 102), Size = UDim2.fromOffset(140, 14), Font = Enum.Font.Gotham, TextColor3 = UIKit.Colors.Muted, Text = string.upper(offer.category) .. "  ·  " .. offer.term })
		local status = UIKit.label(b, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -8), Size = UDim2.fromOffset(140, 22), Font = Enum.Font.GothamBold, TextColor3 = palette.Yellow, Text = "" })
		maid:Give(b.Activated:Connect(function()
			self.selected = offer.sku
			self:_render()
		end))
		self.rows[offer.sku] = { button = b, name = name, sub = sub, status = status }
	end
	local side = UIKit.panel(panel, { Position = UDim2.fromOffset(530, 84), Size = UDim2.fromOffset(314, 460), BackgroundColor3 = palette.NavyFloor, BackgroundTransparency = 0.1 })
	self.itemsSide = side
	self.detailArt = UIKit.new("Frame", { Name = "DetailArt", Position = UDim2.fromOffset(14, 12), Size = UDim2.fromOffset(286, 116), BackgroundTransparency = 1 }, side)
	self.detailName = UIKit.label(side, { Position = UDim2.fromOffset(14, 136), Size = UDim2.fromOffset(286, 30), Font = Enum.Font.GothamBlack, Text = "" })
	self.detailBody = UIKit.label(side, { Position = UDim2.fromOffset(14, 172), Size = UDim2.fromOffset(286, 118), Font = Enum.Font.Gotham, TextWrapped = true, TextScaled = false, TextSize = 16, TextYAlignment = Enum.TextYAlignment.Top, Text = "" })
	self.getButton = UIKit.button(side, { Name = "ShopGet", Position = UDim2.fromOffset(14, 300), Size = UDim2.fromOffset(286, 54), Text = "" }, palette.Yellow)
	maid:Give(self.getButton.Activated:Connect(function()
		self:_buy()
	end))
	self.premiumButton = UIKit.button(side, { Name = "LaneClaim", Position = UDim2.fromOffset(14, 362), Size = UDim2.fromOffset(286, 40), Text = "CLAIM PREMIUM LOOKS", Visible = false }, palette.Mint)
	maid:Give(self.premiumButton.Activated:Connect(function()
		for _, level in ipairs({ 10, 20, 30 }) do
			self.remotes.RequestPremiumClaim:FireServer(level)
		end
	end))
	UIKit.label(side, { Position = UDim2.fromOffset(14, 408), Size = UDim2.fromOffset(286, 46), Font = Enum.Font.Gotham, TextWrapped = true, TextTransparency = 0.25, Text = "Roblox shows the final price and asks you to confirm. Some accounts can't buy (parent settings)." })

	maid:Give(self.remotes.ShopState.OnClientEvent:Connect(function(data)
		if type(data) == "table" and type(data.offers) == "table" then
			self.state = {}
			for _, o in ipairs(data.offers) do
				self.state[o.sku] = o
			end
			self.premiumClaimed = data.premiumClaimed or {}
			self.seasonId = data.seasonId
			self:_fetchPrices()
			self:_render()
		end
	end))
	maid:Give(MarketplaceService.PromptProductPurchaseFinished:Connect(function(userId, _, purchased)
		if userId == Players.LocalPlayer.UserId then
			-- display only: the grant comes from the server's receipt handling
			self.toast(purchased and "Purchase received - it appears once Roblox confirms it" or "No purchase made", 2.5)
			self.remotes.RequestShopState:FireServer()
		end
	end))
	self:_renderSection()
	return self
end

function Shop:_renderSection()
	local items = self.section == "Items"
	self.list.Visible = items
	self.itemsSide.Visible = items
	self.cases.Visible = not items
	for name, b in pairs(self.sectionButtons) do
		b.BackgroundTransparency = name == self.section and 0 or 0.6
	end
end

function Shop:_fetchPrices()
	for _, offer in ipairs(ShopConfig.Offers) do
		local st = self.state and self.state[offer.sku]
		if st and st.id and self.prices[offer.sku] == nil then
			self.prices[offer.sku] = "pending"
			task.spawn(function()
				local price = fetchPrice(st.id, offer.kind)
				self.prices[offer.sku] = price or false
				self:_render()
			end)
		end
	end
end

function Shop:_stateFor(offer)
	return (self.state and self.state[offer.sku]) or { id = nil, owned = false }
end

function Shop:_render()
	for _, offer in ipairs(ShopConfig.Offers) do
		local row = self.rows[offer.sku]
		local st = self:_stateFor(offer)
		local price = self.prices[offer.sku]
		local text = Shop.ButtonText(st, type(price) == "number" and price or nil, price == false)
		row.status.Text = text
		row.button.BackgroundTransparency = offer.sku == self.selected and 0 or 0.4
		local stroke = row.button:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color, stroke.Transparency = palette.White, offer.sku == self.selected and 0 or 1
		end
	end
	local offer = ShopConfig.BySku[self.selected]
	if not offer then
		return
	end
	local st = self:_stateFor(offer)
	if self.detailFor ~= offer.sku then
		self.detailFor = offer.sku
		for _, child in ipairs(self.detailArt:GetChildren()) do
			child:Destroy()
		end
		ItemSwatch.Draw(self.detailArt, offer.grants[1])
	end
	self.detailName.Text = offer.label
	local lines = { offer.term .. " " .. string.lower(offer.category) }
	for _, id in ipairs(offer.grants) do
		local item = Catalog.Get(id)
		if item then
			lines[#lines + 1] = "- " .. item.Name .. " (" .. item.Kind .. ")"
		end
	end
	if offer.extra then
		lines[#lines + 1] = offer.extra
	end
	self.detailBody.Text = table.concat(lines, "\n")
	local price = self.prices[offer.sku]
	local text, active = Shop.ButtonText(st, type(price) == "number" and price or nil, price == false)
	self.getButton.Text = text
	self.getButton.AutoButtonColor = active
	self.getButton.BackgroundTransparency = active and 0 or 0.6
	self.premiumButton.Visible = offer.entitlement ~= nil and st.owned == true and self.seasonId ~= nil
end

function Shop:_buy()
	local offer = ShopConfig.BySku[self.selected]
	local st = offer and self:_stateFor(offer)
	local price = offer and self.prices[offer.sku]
	local _, active = Shop.ButtonText(st or {}, type(price) == "number" and price or nil, price == false)
	if not active then
		return
	end
	local player = Players.LocalPlayer
	local ok = pcall(function()
		if offer.kind == "GamePass" then
			MarketplaceService:PromptGamePassPurchase(player, st.id)
		else
			MarketplaceService:PromptProductPurchase(player, st.id)
		end
	end)
	if not ok then
		self.toast("Roblox couldn't open the purchase prompt right now", 2.5)
	end
end

function Shop:RegisterLayers(ui)
	ui:Register("Shop", function(visible)
		UIKit.Show(self.panel, visible, "Pop")
		if visible then
			self.remotes.RequestShopState:FireServer()
			self:_render()
		end
	end)
end

function Shop:Destroy()
	self.maid:Cleanup()
end

return Shop
