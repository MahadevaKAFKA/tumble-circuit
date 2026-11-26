--[[
	ShopController (D1) — the OPTIONAL cosmetic SHOP modal (MORE → SHOP, lobby only, never in a
	race). Direct choice only: pick one item, see Roblox's own price for you, then tap GET to open
	Roblox's purchase prompt. Nothing is granted here: the server grants after Roblox's receipt
	(or verified Game Pass ownership).
	- An offer with no configured id says "Not on sale yet" (no working button).
	- A failed price lookup says "Price unavailable" (no button) — never a guessed price.
	- Already owned → OWNED. Season premium says "Season 1 only".
	- No timers, no countdowns, no "last chance", no strike-through prices.
]]

local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Catalog = require(Shared:WaitForChild("Catalog"))
local ShopConfig = require(Shared:WaitForChild("ShopConfig"))
local Utility = require(Shared:WaitForChild("Utility"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

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
	self.state = nil
	self.prices = {} -- [sku] = number | false (failed)
	self.selected = ShopConfig.Offers[1].sku
	local gui, root, maid = UIKit.screen("TumbleShop", 23)
	self.gui, self.maid = gui, maid
	local panel = UIKit.panel(root, { Name = "Shop", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(860, 560), BackgroundTransparency = 0.04, Visible = false })
	UIKit.new("UIStroke", { Color = palette.Yellow, Thickness = 2 }, panel)
	self.panel = panel
	UIKit.label(panel, { Position = UDim2.fromOffset(24, 12), Size = UDim2.fromOffset(500, 40), Font = Enum.Font.GothamBlack, TextColor3 = palette.Yellow, Text = "SHOP (OPTIONAL)", TextXAlignment = Enum.TextXAlignment.Left })
	UIKit.label(panel, { Position = UDim2.fromOffset(24, 52), Size = UDim2.fromOffset(640, 22), Font = Enum.Font.Gotham, Text = "Looks only - nothing here changes speed, abilities, rewards or who you race.", TextXAlignment = Enum.TextXAlignment.Left })
	local close = UIKit.button(panel, { Name = "Close", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -16, 0, 12), Size = UDim2.fromOffset(130, 46), Text = "DONE" }, palette.Mint)
	maid:Give(close.Activated:Connect(function()
		self.CloseRequested:Fire()
	end))
	self.list = UIKit.new("ScrollingFrame", { Position = UDim2.fromOffset(16, 84), Size = UDim2.fromOffset(500, 460), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 8, CanvasSize = UDim2.fromOffset(0, #ShopConfig.Offers * 64 + 8) }, panel)
	self.rows = {}
	for i, offer in ipairs(ShopConfig.Offers) do
		local b = UIKit.button(self.list, { Name = "ShopItem", Position = UDim2.fromOffset(4, 4 + (i - 1) * 64), Size = UDim2.fromOffset(470, 58), Text = "" }, palette.White)
		local name = UIKit.label(b, { Position = UDim2.fromOffset(12, 4), Size = UDim2.fromOffset(300, 28), Font = Enum.Font.GothamBlack, Text = offer.label, TextXAlignment = Enum.TextXAlignment.Left })
		local sub = UIKit.label(b, { Position = UDim2.fromOffset(12, 32), Size = UDim2.fromOffset(440, 20), Font = Enum.Font.Gotham, Text = string.upper(offer.category) .. " - " .. offer.term, TextXAlignment = Enum.TextXAlignment.Left })
		local status = UIKit.label(b, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 6), Size = UDim2.fromOffset(150, 24), Font = Enum.Font.GothamBold, TextColor3 = palette.Yellow, Text = "" })
		maid:Give(b.Activated:Connect(function()
			self.selected = offer.sku
			self:_render()
		end))
		self.rows[offer.sku] = { button = b, name = name, sub = sub, status = status }
	end
	local side = UIKit.panel(panel, { Position = UDim2.fromOffset(530, 84), Size = UDim2.fromOffset(314, 460), BackgroundColor3 = palette.NavyFloor, BackgroundTransparency = 0.1 })
	self.detailName = UIKit.label(side, { Position = UDim2.fromOffset(14, 10), Size = UDim2.fromOffset(286, 34), Font = Enum.Font.GothamBlack, Text = "" })
	self.detailBody = UIKit.label(side, { Position = UDim2.fromOffset(14, 50), Size = UDim2.fromOffset(286, 200), Font = Enum.Font.Gotham, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, Text = "" })
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
	return self
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
	end
	local offer = ShopConfig.BySku[self.selected]
	if not offer then
		return
	end
	local st = self:_stateFor(offer)
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
