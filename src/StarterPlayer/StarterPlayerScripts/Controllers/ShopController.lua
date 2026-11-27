--[[
	ShopController — the SHOP modal (hub only, never in a race). Display + requests only: the
	server checks every purchase and grants; Roblox's own prompt confirms real ones.

	D1 (kept): guaranteed direct items, Roblox's localized price or "Price unavailable", no
	timers / countdowns / strike-through prices; CASES · COINS stays a separate, visibly distinct
	tab (earned-Coin cases with VIEW ODDS).

	2026-11-27 shop brief (docs/SHOP.md):
	- Sections FEATURED / MARBLE / TRAILS / CELEBRATIONS / DRIVER PROFILE + an OWNED filter; the
	  map's accent colour frames the panel.
	- Detail: what it grants (each item, owned ticks), the price (live for you once on sale;
	  until then "PREVIEW · proposed N Robux"), ownership and equip state, and a preview:
	  marble = 3D, drag to rotate; trail = a short loop with SLOW / FAST; podium effect = the
	  gold ring on a neutral backdrop; nameplate = the plate. MOTION OFF = still previews.
	- Bundles: what's inside and what you already own; with partial ownership the combined
	  price of the missing standalone items when known, and "cheaper separately" made
	  prominent when it is; no buy button when you own everything. Savings only from prices
	  shown to you now.
	- Checkout states: Loading, Price unavailable (checkout disabled), Verifying (pending),
	  Owned / Equip / Equipped, Not on sale yet, Preview (owner only, no Robux).
	- After a confirmed grant: a small receipt with EQUIP. Dismissing, races and respawns never
	  reopen a prompt (the server only prompts on a button press).
]]

local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CapsuleOdds = require(Shared:WaitForChild("CapsuleOdds"))
local Catalog = require(Shared:WaitForChild("Catalog"))
local MarbleLook = require(Shared:WaitForChild("MarbleLook"))
local ShopConfig = require(Shared:WaitForChild("ShopConfig"))
local Utility = require(Shared:WaitForChild("Utility"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))
local ItemSwatch = require(script.Parent:WaitForChild("ItemSwatch"))

local palette = UIKit.Palette

local Shop = {}
Shop.__index = Shop

-- Pure (D1, kept for the commerce spec): what an offer's button says.
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

-- Pure: the main button text for a ShopConfig.Checkout state
function Shop.CheckoutText(state, price, equipState)
	if state == "Owned" then
		if equipState == "Equipped" then
			return "EQUIPPED"
		elseif equipState == "Equip" then
			return "EQUIP"
		end
		return "OWNED"
	end
	local text = {
		Pending = "VERIFYING PURCHASE...",
		Unlisted = "UNAVAILABLE",
		Buy = type(price) == "number" and string.format("BUY  ·  %d Robux", price) or "BUY",
		Preview = "PREVIEW BUY  ·  NO ROBUX",
		Loading = "LOADING PRICE...",
		PriceUnavailable = "PRICE UNAVAILABLE",
		NotOnSale = "NOT ON SALE YET",
	}
	return text[state] or "NOT ON SALE YET"
end

-- Pure: the price line under the name
function Shop.PriceLine(offer, ctx)
	if ctx.paid and ctx.id then
		if type(ctx.price) == "number" then
			return string.format("%d Robux", ctx.price), false
		elseif ctx.price == false then
			return "Price unavailable", false
		end
		return "Loading price...", false
	end
	local proposed = ShopConfig.PreviewTestData[offer.sku]
	if proposed then
		return string.format("PREVIEW  ·  proposed %d Robux  ·  not on sale", proposed), true
	end
	return "Not on sale yet", false
end

-- Pure: the 2D trail preview loop: marble position and n trail points at time t on an oval
-- (w x h). fast = longer trail (trail length reacts to speed; speed never changes).
function Shop.TrailLoop(t, fast, w, h)
	local speed = fast and 2.4 or 1.0
	local n = fast and 14 or 6
	local function at(u)
		return w / 2 + math.cos(u) * (w / 2 - 14), h / 2 + math.sin(u) * (h / 2 - 12)
	end
	local u = t * speed
	local x, y = at(u)
	local pts = {}
	for i = 1, n do
		local px, py = at(u - i * 0.09)
		pts[i] = { x = px, y = py, alpha = i / (n + 1) }
	end
	return x, y, pts
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
	self.server = {} -- flags from the server (paid, preview, previewItems)
	self.prices = {} -- [sku] = number | false (failed) | "pending"
	self.section = "Featured"
	self.ownedOnly = false
	self.reduced = false
	self.trailFast = false
	self.equipped = {}
	self.ownedSet = {}
	self.selected = ShopConfig.InSection("Featured", os.time())[1] and ShopConfig.InSection("Featured", os.time())[1].sku or ShopConfig.Offers[1].sku
	local gui, root, maid = UIKit.screen("TumbleShop", 23)
	self.gui, self.maid = gui, maid
	local panel = UIKit.panel(root, { Name = "Shop", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(880, 570), BackgroundTransparency = 0.04, Visible = false })
	self.frameStroke = UIKit.new("UIStroke", { Color = palette.Yellow, Thickness = 2 }, panel)
	UIKit.TrackAccent(self.frameStroke, "Color") -- the map / theme accent frames the shop
	self.panel = panel
	UIKit.Title(panel, { Position = UDim2.fromOffset(24, 14), Size = UDim2.fromOffset(160, 30), Text = "SHOP" })
	UIKit.label(panel, { Position = UDim2.fromOffset(24, 46), Size = UDim2.fromOffset(560, 16), Font = Enum.Font.Gotham, TextScaled = false, TextSize = 13, TextColor3 = UIKit.Colors.Muted, Text = "Looks only - nothing here changes speed, abilities, rewards, rank or who you race.", TextXAlignment = Enum.TextXAlignment.Left })
	local close = UIKit.button(panel, { Name = "ShopClose", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 12), Size = UDim2.fromOffset(44, 36), Text = "X" }, palette.White)
	maid:Give(close.Activated:Connect(function()
		self.CloseRequested:Fire()
	end))

	-- tab row: five storefront sections, then CASES (distinct: yellow, earned Coins), OWNED
	self.sectionButtons = {}
	local x = 16
	for _, sec in ipairs(ShopConfig.Sections) do
		local label = ShopConfig.SectionLabels[sec]
		local w = math.max(84, #label * 9 + 18)
		local b = UIKit.button(panel, { Name = "ShopTab", Position = UDim2.fromOffset(x, 68), Size = UDim2.fromOffset(w, 34), Text = label, TextScaled = false, TextSize = 13 }, palette.White)
		maid:Give(b.Activated:Connect(function()
			self.section = sec
			self:_renderSection()
		end))
		self.sectionButtons[sec] = b
		x = x + w + 6
	end
	local cases = UIKit.button(panel, { Name = "ShopTab", Position = UDim2.fromOffset(x + 10, 68), Size = UDim2.fromOffset(150, 34), Text = "CASES  ·  COINS", TextScaled = false, TextSize = 13, TextColor3 = palette.Yellow }, palette.Yellow)
	local casesStroke = cases:FindFirstChildOfClass("UIStroke")
	if casesStroke then
		casesStroke.Transparency = 0.2
	end
	maid:Give(cases.Activated:Connect(function()
		self.section = "Cases"
		self:_renderSection()
	end))
	self.sectionButtons.Cases = cases
	self.ownedChip = UIKit.button(panel, { Name = "ShopOwned", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 68), Size = UDim2.fromOffset(96, 34), Text = "OWNED: OFF", TextScaled = false, TextSize = 12 }, palette.Mint)
	maid:Give(self.ownedChip.Activated:Connect(function()
		self.ownedOnly = not self.ownedOnly
		self:_renderGrid()
	end))

	-- CASES (unchanged D1 cards, earned Coins only)
	self.cases = UIKit.new("Frame", { Name = "Cases", Position = UDim2.fromOffset(16, 112), Size = UDim2.fromOffset(848, 446), BackgroundTransparency = 1, Visible = false }, panel)
	local caseColors = { Starter = Color3.fromRGB(110, 231, 186), Marble = Color3.fromRGB(39, 215, 245), Trail = Color3.fromRGB(160, 120, 255), Apex = Color3.fromRGB(255, 196, 96) }
	for i, box in ipairs(CapsuleOdds.Boxes) do
		local card = UIKit.panel(self.cases, { Position = UDim2.fromOffset(4 + (i - 1) * 211, 0), Size = UDim2.fromOffset(203, 440), BackgroundColor3 = palette.NavyFloor })
		local color = caseColors[box.Id] or palette.White
		UIKit.new("Frame", { Name = "CaseEdge", Size = UDim2.new(1, 0, 0, 4), BackgroundColor3 = color, BorderSizePixel = 0 }, card)
		local art = UIKit.Icon(card, "Case", { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 24), Size = UDim2.fromOffset(104, 104) })
		for _, piece in ipairs(art:GetChildren()) do
			if piece:IsA("Frame") and piece.BackgroundColor3 ~= palette.Ink then
				piece.BackgroundColor3 = color
			end
		end
		UIKit.label(card, { Position = UDim2.fromOffset(14, 140), Size = UDim2.fromOffset(175, 14), Font = Enum.Font.GothamBold, TextColor3 = UIKit.Colors.Muted, TextXAlignment = Enum.TextXAlignment.Left, Text = box.Tier or "" })
		UIKit.label(card, { Position = UDim2.fromOffset(14, 158), Size = UDim2.fromOffset(175, 24), Font = Enum.Font.GothamBlack, TextXAlignment = Enum.TextXAlignment.Left, Text = box.Name })
		UIKit.label(card, { Position = UDim2.fromOffset(14, 190), Size = UDim2.fromOffset(175, 96), Font = Enum.Font.Gotham, TextWrapped = true, TextYAlignment = Enum.TextYAlignment.Top, TextScaled = false, TextSize = 14, TextColor3 = UIKit.Colors.Muted, TextXAlignment = Enum.TextXAlignment.Left, Text = (box.Mixed and ("Skins, trails, bursts and emotes - " .. (box.Rarities and box.Rarities.Epic and "Epic or better only." or "Common and Rare.")) or ("Every " .. (box.Kind == "Marble" and "marble skin" or string.lower(box.Kind)) .. ", any rarity.")) .. " Every chance is shown before you open. Duplicates become Shards." })
		UIKit.Title(card, { Position = UDim2.fromOffset(14, 300), Size = UDim2.fromOffset(175, 30), TextColor3 = palette.Yellow, Text = tostring(box.Cost) })
		UIKit.label(card, { Position = UDim2.fromOffset(14, 334), Size = UDim2.fromOffset(175, 14), Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Left, Text = "COINS (from quests)" })
		local view = UIKit.button(card, { Name = "ShopCase", Position = UDim2.fromOffset(14, 370), Size = UDim2.fromOffset(175, 50), Text = "VIEW ODDS" }, palette.White)
		maid:Give(view.Activated:Connect(function()
			self.CaseRequested:Fire(box.Id)
		end))
	end

	-- offer grid (left)
	self.list = UIKit.new("ScrollingFrame", { Name = "Offers", Position = UDim2.fromOffset(16, 112), Size = UDim2.fromOffset(508, 446), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 6, CanvasSize = UDim2.fromOffset(0, 0) }, panel)
	self.cards = {}
	self.empty = UIKit.label(self.list, { Position = UDim2.fromOffset(8, 8), Size = UDim2.fromOffset(480, 40), Font = Enum.Font.Gotham, TextColor3 = UIKit.Colors.Muted, TextXAlignment = Enum.TextXAlignment.Left, Text = "", Visible = false })

	-- detail (right)
	local side = UIKit.panel(panel, { Name = "Detail", Position = UDim2.fromOffset(532, 112), Size = UDim2.fromOffset(332, 446), BackgroundColor3 = palette.NavyFloor, BackgroundTransparency = 0.1 })
	self.side = side
	self.previewBox = UIKit.new("Frame", { Name = "Preview", Position = UDim2.fromOffset(12, 10), Size = UDim2.fromOffset(308, 128), BackgroundColor3 = Color3.fromRGB(28, 32, 44), BackgroundTransparency = 0, ClipsDescendants = true }, side)
	UIKit.corner(self.previewBox, 0.1)
	self.viewport = UIKit.new("ViewportFrame", { Name = "Marble3D", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, Visible = false }, self.previewBox)
	local camera = Instance.new("Camera")
	camera.FieldOfView = 40
	camera.CFrame = CFrame.lookAt(Vector3.new(0, 1.2, 10), Vector3.new(0, 0, 0))
	camera.Parent = self.viewport
	self.viewport.CurrentCamera = camera
	self.flat = UIKit.new("Frame", { Name = "Flat", Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1 }, self.previewBox)
	self.motionChip = UIKit.button(side, { Name = "ShopMotion", Position = UDim2.fromOffset(12, 142), Size = UDim2.fromOffset(110, 26), Text = "MOTION: ON", TextScaled = false, TextSize = 11 }, palette.White)
	maid:Give(self.motionChip.Activated:Connect(function()
		self.reduced = not self.reduced
		self.motionChip.Text = self.reduced and "MOTION: OFF" or "MOTION: ON"
		self.previewFor = nil
		self:_renderDetail()
	end))
	self.speedChip = UIKit.button(side, { Name = "ShopTrailSpeed", Position = UDim2.fromOffset(128, 142), Size = UDim2.fromOffset(110, 26), Text = "SPEED: SLOW", TextScaled = false, TextSize = 11, Visible = false }, palette.Mint)
	maid:Give(self.speedChip.Activated:Connect(function()
		self.trailFast = not self.trailFast
		self.speedChip.Text = self.trailFast and "SPEED: FAST" or "SPEED: SLOW"
	end))
	self.dName = UIKit.label(side, { Position = UDim2.fromOffset(12, 174), Size = UDim2.fromOffset(308, 26), Font = Enum.Font.GothamBlack, TextXAlignment = Enum.TextXAlignment.Left, Text = "" })
	self.dPrice = UIKit.label(side, { Position = UDim2.fromOffset(12, 200), Size = UDim2.fromOffset(308, 18), Font = Enum.Font.GothamBold, TextScaled = false, TextSize = 14, TextColor3 = palette.Yellow, TextXAlignment = Enum.TextXAlignment.Left, Text = "" })
	self.dBody = UIKit.label(side, { Position = UDim2.fromOffset(12, 222), Size = UDim2.fromOffset(308, 104), Font = Enum.Font.Gotham, TextWrapped = true, TextScaled = false, TextSize = 13, TextYAlignment = Enum.TextYAlignment.Top, TextXAlignment = Enum.TextXAlignment.Left, Text = "" })
	self.altButton = UIKit.button(side, { Name = "ShopSeparately", Position = UDim2.fromOffset(12, 328), Size = UDim2.fromOffset(308, 34), Text = "", TextScaled = false, TextSize = 13, Visible = false }, palette.Mint)
	maid:Give(self.altButton.Activated:Connect(function()
		if self.altSku then
			self.selected = self.altSku
			self:_render()
		end
	end))
	self.getButton = UIKit.Primary(UIKit.button(side, { Name = "ShopGet", Position = UDim2.fromOffset(12, 368), Size = UDim2.fromOffset(308, 50), Text = "" }, palette.Yellow))
	maid:Give(self.getButton.Activated:Connect(function()
		self:_primary()
	end))
	self.note = UIKit.label(side, { Position = UDim2.fromOffset(12, 422), Size = UDim2.fromOffset(308, 20), Font = Enum.Font.Gotham, TextScaled = false, TextSize = 11, TextWrapped = true, TextColor3 = UIKit.Colors.Muted, Text = "Roblox shows the final price and asks you to confirm." })
	self.premiumButton = UIKit.button(side, { Name = "LaneClaim", Position = UDim2.fromOffset(12, 328), Size = UDim2.fromOffset(308, 34), Text = "CLAIM PREMIUM LOOKS", Visible = false }, palette.Mint)
	maid:Give(self.premiumButton.Activated:Connect(function()
		for _, level in ipairs({ 10, 20, 30 }) do
			self.remotes.RequestPremiumClaim:FireServer(level)
		end
	end))
	-- owner preview tools (visible only when the server says preview purchases are allowed)
	self.resetPreview = UIKit.button(panel, { Name = "ShopPreviewReset", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -66, 0, 14), Size = UDim2.fromOffset(150, 30), Text = "RESET PREVIEW BUYS", TextScaled = false, TextSize = 11, Visible = false }, palette.Coral)
	maid:Give(self.resetPreview.Activated:Connect(function()
		self.remotes.RequestShopPreviewReset:FireServer()
	end))

	-- receipt (after a verified grant): what you got + EQUIP
	local receipt = UIKit.panel(panel, { Name = "ShopReceipt", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(420, 190), Visible = false })
	UIKit.new("UIStroke", { Color = palette.Mint, Thickness = 2 }, receipt)
	self.receiptPanel = receipt
	self.rTitle = UIKit.Title(receipt, { Position = UDim2.fromOffset(18, 14), Size = UDim2.fromOffset(384, 30), Text = "UNLOCKED" })
	self.rBody = UIKit.label(receipt, { Position = UDim2.fromOffset(18, 50), Size = UDim2.fromOffset(384, 66), Font = Enum.Font.Gotham, TextWrapped = true, TextScaled = false, TextSize = 14, TextYAlignment = Enum.TextYAlignment.Top, TextXAlignment = Enum.TextXAlignment.Left, Text = "" })
	self.rEquip = UIKit.Primary(UIKit.button(receipt, { Name = "ShopReceiptEquip", Position = UDim2.fromOffset(18, 126), Size = UDim2.fromOffset(240, 48), Text = "EQUIP" }, palette.Mint))
	maid:Give(self.rEquip.Activated:Connect(function()
		self:_equipItems(self.receiptItems or {})
		receipt.Visible = false
	end))
	local later = UIKit.button(receipt, { Name = "ShopReceiptLater", Position = UDim2.fromOffset(268, 126), Size = UDim2.fromOffset(134, 48), Text = "LATER" }, palette.White)
	maid:Give(later.Activated:Connect(function()
		receipt.Visible = false
	end))

	-- marble preview: drag to rotate (touch / mouse), else a slow spin (MOTION OFF = still)
	self.angle, self.dragging = 0, false
	maid:Give(self.previewBox.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			self.dragging, self.lastX = true, input.Position.X
		end
	end))
	maid:Give(UserInputService.InputChanged:Connect(function(input)
		if self.dragging and (input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseMovement) then
			self.angle = self.angle + (input.Position.X - (self.lastX or input.Position.X)) * 0.02
			self.lastX = input.Position.X
		end
	end))
	maid:Give(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			self.dragging = false
		end
	end))
	maid:Give(RunService.RenderStepped:Connect(function(dt)
		if self.panel.Visible then
			self:_stepPreview(dt)
		end
	end))

	maid:Give(self.remotes.ShopState.OnClientEvent:Connect(function(data)
		if type(data) == "table" and type(data.offers) == "table" then
			self.state = {}
			for _, o in ipairs(data.offers) do
				self.state[o.sku] = o
			end
			self.server = { paid = data.paid == true, preview = data.preview == true, previewItems = data.previewItems or {}, storefront = data.storefront ~= false }
			self.premiumClaimed = data.premiumClaimed or {}
			self.seasonId = data.seasonId
			self:_fetchPrices()
			self:_render()
			if type(data.receipt) == "table" then
				self:_showReceipt(data.receipt)
			end
			if data.cancelled and self.toast then
				self.toast("No purchase made", 2)
			end
		end
	end))
	maid:Give(self.remotes.CosmeticState.OnClientEvent:Connect(function(data)
		if type(data) == "table" and type(data.owned) == "table" and type(data.equipped) == "table" then
			self.ownedSet = {}
			for _, id in ipairs(data.owned) do
				self.ownedSet[id] = true
			end
			self.equipped = data.equipped
			self:_render()
		end
	end))
	self:_renderSection()
	return self
end

function Shop:_renderSection()
	local cases = self.section == "Cases"
	self.list.Visible = not cases
	self.side.Visible = not cases
	self.cases.Visible = cases
	self.ownedChip.Visible = not cases
	for name, b in pairs(self.sectionButtons) do
		b.BackgroundTransparency = name == self.section and 0 or 0.6
	end
	if not cases then
		local list = self:_offersShown()
		if #list > 0 and not self:_isShown(self.selected, list) then
			self.selected = list[1].sku
		end
	end
	self:_render()
end

function Shop:_isShown(sku, list)
	for _, offer in ipairs(list) do
		if offer.sku == sku then
			return true
		end
	end
	return false
end

function Shop:_ownership(offer)
	return ShopConfig.Ownership(offer, self.ownedSet, nil)
end

function Shop:_offersShown()
	local out = {}
	for _, offer in ipairs(ShopConfig.InSection(self.section, os.time())) do
		local st = self:_stateFor(offer)
		if not self.ownedOnly or st.owned then
			out[#out + 1] = offer
		end
	end
	return out
end

function Shop:_fetchPrices()
	if not self.server.paid then
		return -- paid offers are off: no live prices to show (PREVIEW labels instead)
	end
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
	return (self.state and self.state[offer.sku]) or { id = nil, owned = false, listed = true }
end

function Shop:_priceOf(sku)
	local p = self.prices[sku]
	return type(p) == "number" and p or nil
end

-- equip state of an owned single-item offer: "Equipped" / "Equip" / nil (packs, emotes...)
function Shop:_equipState(offer)
	if #offer.grants ~= 1 then
		return nil
	end
	local item = Catalog.Get(offer.grants[1])
	local key = item and Catalog.EquipKey[item.Kind]
	if not key or key == "emotes" then
		return nil
	end
	return self.equipped[key] == item.Id and "Equipped" or "Equip"
end

function Shop:_ctx(offer)
	local st = self:_stateFor(offer)
	local price = self.prices[offer.sku]
	return {
		owned = st.owned == true,
		pending = st.pending == true,
		listed = st.listed ~= false,
		id = st.id,
		price = price == "pending" and nil or price,
		paid = self.server.paid == true,
		preview = self.server.preview == true,
	}
end

function Shop:_renderGrid()
	self.ownedChip.Text = self.ownedOnly and "OWNED: ON" or "OWNED: OFF"
	for _, card in ipairs(self.cards) do
		card:Destroy()
	end
	self.cards = {}
	local list = self:_offersShown()
	self.empty.Visible = #list == 0
	self.empty.Text = self.ownedOnly and "Nothing owned in this section yet." or "Nothing listed here yet."
	local cols = 3
	for i, offer in ipairs(list) do
		local x, y = (i - 1) % cols, math.floor((i - 1) / cols)
		local b = UIKit.button(self.list, { Name = "ShopItem", Position = UDim2.fromOffset(4 + x * 166, 4 + y * 168), Size = UDim2.fromOffset(158, 160), Text = "" }, palette.White)
		local art = UIKit.new("Frame", { Position = UDim2.fromOffset(39, 8), Size = UDim2.fromOffset(80, 66), BackgroundTransparency = 1 }, b)
		ItemSwatch.Draw(art, offer.grants[1])
		UIKit.label(b, { Position = UDim2.fromOffset(8, 80), Size = UDim2.fromOffset(142, 20), Font = Enum.Font.GothamBlack, Text = offer.label })
		local own = self:_ownership(offer)
		local sub = offer.contains and string.format("PACK  ·  %d ITEMS", #offer.grants) or (string.upper(offer.category) .. "  ·  " .. string.upper(offer.term))
		UIKit.label(b, { Position = UDim2.fromOffset(8, 102), Size = UDim2.fromOffset(142, 14), Font = Enum.Font.Gotham, TextColor3 = UIKit.Colors.Muted, Text = sub })
		local ctx = self:_ctx(offer)
		local state = ShopConfig.Checkout(ctx)
		local status
		if state == "Owned" then
			status = self:_equipState(offer) == "Equipped" and "EQUIPPED" or "OWNED"
		elseif offer.contains and own.owned > 0 then
			status = string.format("YOU OWN %d / %d", own.owned, own.total)
		elseif state == "Buy" then
			status = string.format("%d Robux", ctx.price)
		elseif state == "Preview" or (not ctx.paid and ShopConfig.PreviewTestData[offer.sku]) then
			status = "PREVIEW"
		else
			status = Shop.CheckoutText(state, ctx.price)
		end
		UIKit.label(b, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -8), Size = UDim2.fromOffset(142, 22), Font = Enum.Font.GothamBold, TextColor3 = state == "Owned" and palette.Mint or palette.Yellow, Text = status })
		b.BackgroundTransparency = offer.sku == self.selected and 0 or 0.4
		local stroke = b:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color, stroke.Transparency = palette.White, offer.sku == self.selected and 0 or 1
		end
		self.maid:Give(b.Activated:Connect(function()
			self.selected = offer.sku
			self:_render()
		end))
		self.cards[#self.cards + 1] = b
	end
	self.list.CanvasSize = UDim2.fromOffset(0, math.ceil(#list / cols) * 168 + 8)
end

function Shop:_render()
	if self.section == "Cases" then
		return
	end
	self:_renderGrid()
	self:_renderDetail()
	self.resetPreview.Visible = self.server.preview == true and #(self.server.previewItems or {}) > 0
end

function Shop:_renderDetail()
	local offer = ShopConfig.BySku[self.selected]
	if not offer then
		return
	end
	local ctx = self:_ctx(offer)
	local state, enabled = ShopConfig.Checkout(ctx)
	local equipState = state == "Owned" and self:_equipState(offer) or nil
	self.dName.Text = offer.label
	local priceText, isPreview = Shop.PriceLine(offer, ctx)
	self.dPrice.Text = state == "Owned" and "OWNED" or priceText
	self.dPrice.TextColor3 = state == "Owned" and palette.Mint or (isPreview and palette.Violet or palette.Yellow)
	local lines = {}
	if offer.blurb then
		lines[#lines + 1] = offer.blurb
	end
	lines[#lines + 1] = string.format("%s  ·  %s", offer.term, offer.kind == "GamePass" and "one-time pass" or "one-time purchase")
	for _, id in ipairs(offer.grants) do
		local item = Catalog.Get(id)
		if item then
			lines[#lines + 1] = string.format("%s %s (%s)", self.ownedSet[id] and "[OWNED]" or "  +", item.Name, item.Kind == "Plate" and "Nameplate" or item.Kind == "Podium" and "Podium effect" or item.Kind)
		end
	end
	if offer.extra then
		lines[#lines + 1] = offer.extra
	end
	-- bundles: partial ownership, the standalone route and honest savings
	self.altSku = nil
	self.altButton.Visible = false
	if offer.contains then
		local view = ShopConfig.BundleView(offer, self.ownedSet, function(sku)
			return self:_priceOf(sku)
		end, os.time())
		if view.allOwned then
			lines[#lines + 1] = "You own every item in this pack."
		elseif view.missing < #offer.grants then
			lines[#lines + 1] = string.format("You already own %d of %d - you'd get %d new.", #offer.grants - view.missing, #offer.grants, view.missing)
			if view.missingTotal then
				lines[#lines + 1] = string.format("The missing items separately: %d Robux.", view.missingTotal)
			end
			for _, it in ipairs(view.items) do
				if not it.owned and it.sku and (view.standaloneCheaper or not view.missingTotal) then
					self.altSku = it.sku
					break
				end
			end
		end
		if view.savings and not view.allOwned then
			lines[#lines + 1] = string.format("Pack price is %d Robux less than the missing items separately.", view.savings)
		end
		if self.altSku then
			self.altButton.Visible = true
			self.altButton.Text = view.standaloneCheaper and "CHEAPER SEPARATELY - SEE MISSING ITEMS" or "BUY MISSING ITEMS SEPARATELY"
			self.altButton.TextColor3 = view.standaloneCheaper and palette.Ink or palette.White
			self.altButton.BackgroundColor3 = view.standaloneCheaper and palette.Mint or UIKit.Colors.Raised
		end
	end
	self.dBody.Text = table.concat(lines, "\n")
	local text = Shop.CheckoutText(state, ctx.price, equipState)
	self.getButton.Text = text
	local active = enabled or equipState == "Equip"
	self.getButton.AutoButtonColor = active
	self.getButton.BackgroundTransparency = active and 0 or 0.6
	-- hide the purchase action when everything is owned and there's nothing to equip
	self.getButton.Visible = not (state == "Owned" and equipState == nil)
	self.premiumButton.Visible = offer.entitlement ~= nil and ctx.owned and self.seasonId ~= nil
	if self.premiumButton.Visible then
		self.altButton.Visible = false
	end
	self.note.Text = (state == "Preview") and "Owner preview: no Robux, nothing is charged. RESET PREVIEW BUYS takes it back." or "Roblox shows the final price and asks you to confirm."
	if self.previewFor ~= offer.sku then
		self.previewFor = offer.sku
		self:_buildPreview(offer)
	end
end

function Shop:_primary()
	local offer = ShopConfig.BySku[self.selected]
	if not offer then
		return
	end
	local ctx = self:_ctx(offer)
	local state, enabled = ShopConfig.Checkout(ctx)
	if state == "Owned" then
		if self:_equipState(offer) == "Equip" then
			self:_equipItems(offer.grants)
		end
		return
	end
	if not enabled then
		return
	end
	-- the client only ASKS; the server re-checks everything and opens Roblox's prompt
	self.remotes.RequestShopPurchase:FireServer(offer.sku)
	self.getButton.Text = state == "Preview" and "PREVIEWING..." or "OPENING ROBLOX..."
end

function Shop:_equipItems(items)
	for _, id in ipairs(items) do
		local item = Catalog.Get(id)
		if item and item.Kind ~= "Emote" then
			self.remotes.RequestEquipCosmetic:FireServer(item.Kind, item.Id, 0)
		end
	end
end

function Shop:_showReceipt(receipt)
	local offer = ShopConfig.BySku[receipt.sku]
	if not offer then
		return
	end
	local names = {}
	self.receiptItems = {}
	for _, id in ipairs(receipt.items or offer.grants) do
		local item = Catalog.Get(id)
		if item then
			names[#names + 1] = item.Name
			self.receiptItems[#self.receiptItems + 1] = id
		end
	end
	self.rTitle.Text = (receipt.preview and "PREVIEW  ·  " or "UNLOCKED  ·  ") .. string.upper(offer.label)
	self.rBody.Text = "Yours: " .. table.concat(names, ", ") .. (receipt.preview and "\nOwner preview - no Robux was charged." or "\nThanks for supporting Tumble Circuit.")
	self.rEquip.Text = #self.receiptItems > 1 and "EQUIP ALL" or "EQUIP"
	self.receiptPanel.Visible = true
	UIKit.Enter(self.receiptPanel, "Pop", 0.2)
end

-- previews --------------------------------------------------------------------------------------
function Shop:_clearPreview()
	for _, child in ipairs(self.flat:GetChildren()) do
		child:Destroy()
	end
	if self.model then
		self.model:Destroy()
		self.model = nil
	end
	self.trailParts, self.trailDot, self.ring = nil, nil, nil
	self.viewport.Visible = false
	self.speedChip.Visible = false
end

function Shop:_buildPreview(offer)
	self:_clearPreview()
	local item = Catalog.Get(offer.grants[1])
	if not item then
		ItemSwatch.Draw(self.flat, nil)
		return
	end
	if item.Kind == "Marble" then
		local model = Instance.new("Model")
		local ball = Instance.new("Part")
		ball.Shape = Enum.PartType.Ball
		ball.Size = Vector3.new(4, 4, 4)
		ball.Anchored = true
		ball.CFrame = CFrame.new()
		ball.Parent = model
		model.PrimaryPart = ball
		MarbleLook.Apply(ball, item, function(_, part)
			part.Anchored = true
			part.Parent = model
		end, nil)
		model.Parent = self.viewport
		self.model = model
		self.viewport.Visible = true
		UIKit.label(self.flat, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -4), Size = UDim2.fromOffset(200, 14), Font = Enum.Font.Gotham, TextScaled = false, TextSize = 11, TextColor3 = UIKit.Colors.Muted, Text = "drag to rotate" })
	elseif item.Kind == "Trail" then
		-- a short track loop drawn flat: the marble laps, the trail follows (SLOW / FAST)
		local track = UIKit.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.new(1, -16, 1, -16), BackgroundTransparency = 1 }, self.flat)
		UIKit.corner(track, 0.5)
		UIKit.new("UIStroke", { Color = UIKit.Colors.Muted, Thickness = 1, Transparency = 0.6 }, track)
		self.trailParts = {}
		for i = 1, 14 do
			local twin = item.Profile == "Twin"
			local bit = UIKit.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(twin and 5 or 8, twin and 5 or 8), BorderSizePixel = 0, BackgroundColor3 = item.Colors[1]:Lerp(item.Colors[2], i / 14), Visible = false }, self.flat)
			UIKit.corner(bit, 0.5)
			self.trailParts[i] = bit
		end
		self.trailDot = UIKit.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Size = UDim2.fromOffset(14, 14), BorderSizePixel = 0, BackgroundColor3 = palette.White }, self.flat)
		UIKit.corner(self.trailDot, 0.5)
		self.trailItem = item
		self.speedChip.Visible = true
	elseif item.Kind == "Podium" then
		UIKit.new("Frame", { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -10), Size = UDim2.fromOffset(120, 22), BackgroundColor3 = palette.NavyFloor, BorderSizePixel = 0 }, self.flat)
		local marble = UIKit.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.45), Size = UDim2.fromOffset(52, 52), BackgroundColor3 = palette.Mint, BorderSizePixel = 0 }, self.flat)
		UIKit.corner(marble, 0.5)
		if item.Effect == "GoldRing" then
			self.ring = UIKit.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(52, 52), BackgroundTransparency = 1 }, marble)
			UIKit.corner(self.ring, 0.5)
			self.ringStroke = UIKit.new("UIStroke", { Color = palette.Yellow, Thickness = 3 }, self.ring)
			self.ringT0 = os.clock()
		end
	else
		ItemSwatch.Draw(self.flat, item)
	end
end

function Shop:_stepPreview(dt)
	if self.model and self.model.PrimaryPart then
		if not self.dragging and not self.reduced then
			self.angle = self.angle + dt * 0.8
		end
		self.model:PivotTo(CFrame.Angles(0.3, self.angle, 0))
	end
	if self.trailDot and self.trailItem then
		local size = self.flat.AbsoluteSize
		local t = self.reduced and 0.6 or os.clock()
		local x, y, pts = Shop.TrailLoop(t, self.trailFast, size.X, size.Y)
		self.trailDot.Position = UDim2.fromOffset(x, y)
		for i, bit in ipairs(self.trailParts) do
			local p = pts[i]
			bit.Visible = p ~= nil
			if p then
				bit.Position = UDim2.fromOffset(p.x, p.y)
				bit.BackgroundTransparency = 0.1 + p.alpha * 0.85
			end
		end
	end
	if self.ring and self.ringStroke then
		local t = (os.clock() - self.ringT0) % 2.4
		if self.reduced then
			self.ring.Size = UDim2.fromOffset(76, 76)
			self.ringStroke.Transparency = 0.15
		else
			local phase = math.clamp(t / 0.8, 0, 1)
			self.ring.Size = UDim2.fromOffset(52 + 40 * phase, 52 + 40 * phase)
			self.ringStroke.Transparency = t < 0.8 and phase or 1
		end
	end
end

function Shop:RegisterLayers(ui)
	ui:Register("Shop", function(visible)
		UIKit.Show(self.panel, visible, "Pop")
		if visible then
			self.remotes.RequestShopState:FireServer()
			self:_renderSection()
		else
			self.receiptPanel.Visible = false -- dismissing never reopens anything later
		end
	end)
end

-- Garage > SHOP opens the same storefront on the section that sells that kind
function Shop:FocusKind(kind)
	local map = { Marble = "Marble", Launch = "Marble", Trail = "Trails", Burst = "Celebrations", Emote = "Celebrations", Podium = "Celebrations", Plate = "Profile" }
	self.section = map[kind] or "Featured"
	self:_renderSection()
end

function Shop:Destroy()
	self:_clearPreview()
	self.maid:Cleanup()
end

return Shop
