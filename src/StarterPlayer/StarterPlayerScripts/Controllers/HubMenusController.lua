--[[
	HubMenusController (B3) — three hub modals: GARAGE, QUESTS and BOARDS (leaderboards).
	Display + requests only; the server owns inventory, quests and boards.
	- GARAGE (reworked 2026-11-26): a category rail with icons + labels (Skins, Trails, Launch,
	  Bursts, Emotes), a search box, filter chips (All / Owned / Favorites / a rarity) that are
	  saved to your profile, equipped-first order (then owned, rarest first), an explicit
	  EQUIPPED badge, a 3D preview in context (Launch previews loop the real animation), EQUIP
	  (emotes: SLOT 1-3), FAVORITE. Locked items say how they're earned. There is no buy button.
	- QUESTS: 3 daily + 4 weekly with progress and CLAIM; reset timers; the bot-practice note.
	- BOARDS: world + variation, best times or weekly wins, your best, friends in this server.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Catalog = require(Shared:WaitForChild("Catalog"))
local MarbleLook = require(Shared:WaitForChild("MarbleLook"))
local MotionFeel = require(Shared:WaitForChild("MotionFeel"))
local QuestConfig = require(Shared:WaitForChild("QuestConfig"))
local TrackDefinitions = require(Shared:WaitForChild("TrackDefinitions"))
local Utility = require(Shared:WaitForChild("Utility"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local palette = UIKit.Palette

local HubMenus = {}
HubMenus.__index = HubMenus

HubMenus.Tabs = { "Marble", "Trail", "Launch", "Burst", "Emote" }
HubMenus.TabLabels = { Marble = "SKINS", Trail = "TRAILS", Burst = "BURSTS", Emote = "EMOTES", Launch = "LAUNCH" }
HubMenus.Filters = { "All", "Owned", "Favorites", "Common", "Rare", "Epic", "Legendary", "Mythic" }

-- Pure: items for a tab + filter (+ optional search text), catalog order.
-- state = { owned = set, favorites = set }
function HubMenus.FilterItems(kind, filter, state, query)
	local out = {}
	local q = query and string.lower(query) or ""
	for _, item in ipairs(Catalog.ByKind[kind] or {}) do
		local keep = filter == "All"
			or (filter == "Owned" and state.owned[item.Id])
			or (filter == "Favorites" and state.favorites[item.Id])
			or item.Rarity == filter
		if keep and q ~= "" then
			keep = string.find(string.lower(item.Name), q, 1, true) ~= nil or string.find(string.lower(item.Rarity), q, 1, true) ~= nil
		end
		if keep then
			out[#out + 1] = item
		end
	end
	return out
end

local RARITY_RANK = { Common = 1, Rare = 2, Epic = 3, Legendary = 4, Mythic = 5 }

-- Pure: equipped first, then owned, then rarest first, then catalog order (stable).
function HubMenus.SortItems(items, isEquipped, state)
	local index = {}
	for i, item in ipairs(items) do
		index[item.Id] = i
	end
	local sorted = table.clone and table.clone(items) or { table.unpack(items) }
	table.sort(sorted, function(a, b)
		local ea, eb = isEquipped(a) and 1 or 0, isEquipped(b) and 1 or 0
		if ea ~= eb then
			return ea > eb
		end
		local oa, ob = state.owned[a.Id] and 1 or 0, state.owned[b.Id] and 1 or 0
		if oa ~= ob then
			return oa > ob
		end
		local ra, rb = RARITY_RANK[a.Rarity] or 0, RARITY_RANK[b.Rarity] or 0
		if ra ~= rb then
			return ra > rb
		end
		return index[a.Id] < index[b.Id]
	end)
	return sorted
end

local function toSet(list)
	local set = {}
	for _, id in ipairs(list or {}) do
		set[id] = true
	end
	return set
end

local function duration(seconds)
	seconds = math.max(0, math.floor(seconds or 0))
	local d, h, m = math.floor(seconds / 86400), math.floor(seconds % 86400 / 3600), math.floor(seconds % 3600 / 60)
	if d > 0 then
		return string.format("%dd %dh", d, h)
	end
	return string.format("%dh %dm", h, m)
end
HubMenus.Duration = duration

local function modalPanel(root, name, size, accent, title)
	local panel = UIKit.panel(root, { Name = name, AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(size.X, size.Y), BackgroundTransparency = 0.04, Visible = false })
	UIKit.new("UIStroke", { Color = accent, Thickness = 2 }, panel)
	UIKit.label(panel, { Position = UDim2.fromOffset(24, 12), Size = UDim2.new(1, -190, 0, 40), Font = Enum.Font.GothamBlack, TextColor3 = accent, Text = title, TextXAlignment = Enum.TextXAlignment.Left })
	local close = UIKit.button(panel, { Name = "Close", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -16, 0, 12), Size = UDim2.fromOffset(130, 46), Text = "DONE" }, palette.Mint)
	return panel, close
end

function HubMenus.new(deps)
	local self = setmetatable({}, HubMenus)
	self.remotes = deps.remotes
	self.toast = deps.toast
	self.CloseRequested = Utility.Signal.new()
	self.cosmetics = { owned = {}, favorites = {}, equipped = { emotes = {} } }
	self.FilterChanged = Utility.Signal.new() -- (filter) saved to the profile by the bootstrap
	self.quests = nil
	self.tab, self.filter, self.selected = "Marble", "All", Catalog.Defaults.marble
	self.boardWorld, self.boardSeed, self.boardKind = TrackDefinitions.Worlds[1].Id, 0, "Best"
	local gui, root, maid = UIKit.screen("TumbleHubMenus", 21)
	self.gui, self.root, self.maid = gui, root, maid

	self:_buildGarage(root)
	self:_buildQuests(root)
	self:_buildBoards(root)

	maid:Give(self.remotes.CosmeticState.OnClientEvent:Connect(function(data)
		if type(data) == "table" and type(data.owned) == "table" and type(data.equipped) == "table" then
			self.cosmetics = { ownedList = data.owned, owned = toSet(data.owned), favorites = toSet(data.favorites), equipped = data.equipped }
			self:_renderGarage()
			if self.EquippedChanged then
				self.EquippedChanged:Fire(data.equipped)
			end
		end
	end))
	maid:Give(self.remotes.QuestState.OnClientEvent:Connect(function(data)
		if type(data) == "table" and type(data.daily) == "table" then
			self.quests = data
			self.questsReceivedAt = os.clock()
			self:_renderQuests()
		end
	end))
	maid:Give(self.remotes.LeaderboardData.OnClientEvent:Connect(function(data)
		if type(data) == "table" then
			self:_renderBoard(data)
		end
	end))
	maid:Give(self.remotes.ProgressionNotice.OnClientEvent:Connect(function(data)
		if type(data) == "table" and type(data.text) == "string" then
			self.toast(data.text, data.kind == "LevelReward" and 4 or 2.5)
		end
	end))
	self.EquippedChanged = Utility.Signal.new()
	maid:Give(RunService.RenderStepped:Connect(function(dt)
		if self.previewLaunch and self.garage.Visible then
			self:_stepLaunchPreview()
		elseif self.previewModel and self.garage.Visible then
			self.previewAngle = (self.previewAngle or 0) + dt * 0.9
			self.previewModel:PivotTo(CFrame.Angles(0.35, self.previewAngle, 0))
		end
	end))
	return self
end

---------------------------------------------------------------------------------------------
-- Garage
---------------------------------------------------------------------------------------------
function HubMenus:_buildGarage(root)
	local panel, close = modalPanel(root, "Garage", Vector2.new(880, 580), palette.Cyan, "GARAGE")
	self.garage = panel
	self.maid:Give(close.Activated:Connect(function()
		self.CloseRequested:Fire()
	end))
	-- category rail (icon + label)
	self.tabButtons = {}
	for i, kind in ipairs(HubMenus.Tabs) do
		local b = UIKit.button(panel, { Name = "GarageTab", Position = UDim2.fromOffset(16, 60 + (i - 1) * 100), Size = UDim2.fromOffset(120, 92), Text = "" }, palette.White)
		UIKit.Icon(b, kind, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 4), Size = UDim2.fromOffset(30, 30) })
		UIKit.label(b, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, 0), Size = UDim2.new(1, -8, 0, 22), Font = Enum.Font.GothamBold, Text = HubMenus.TabLabels[kind] })
		self.maid:Give(b.Activated:Connect(function()
			self.tab = kind
			local first = Catalog.ByKind[kind][1]
			local eq = self.cosmetics.equipped
			self.selected = (kind == "Marble" and eq.marble) or (kind == "Trail" and eq.trail) or (kind == "Burst" and eq.burst) or (kind == "Launch" and eq.launch) or (first and first.Id)
			self:_renderGarage()
		end))
		self.tabButtons[kind] = b
	end
	-- search + filter chips (the filter is saved to your profile)
	self.search = UIKit.new("TextBox", { Name = "GarageSearch", Position = UDim2.fromOffset(148, 60), Size = UDim2.fromOffset(416, 34), BackgroundColor3 = palette.NavyFloor, BackgroundTransparency = 0.1, TextColor3 = palette.White, PlaceholderText = "Search by name or rarity", PlaceholderColor3 = Color3.fromRGB(150, 160, 180), Font = Enum.Font.GothamMedium, TextScaled = true, ClearTextOnFocus = false, Text = "" }, panel)
	UIKit.corner(self.search, 0.25)
	UIKit.new("UIPadding", { PaddingLeft = UDim.new(0, 10), PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6) }, self.search)
	self.maid:Give(self.search:GetPropertyChangedSignal("Text"):Connect(function()
		self:_renderGarage()
	end))
	self.filterButtons = {}
	for i, filter in ipairs(HubMenus.Filters) do
		local label = filter == "Favorites" and "FAV" or filter == "Legendary" and "LEG" or string.upper(filter)
		local b = UIKit.button(panel, { Name = "GarageFilter", Position = UDim2.fromOffset(148 + (i - 1) * 52, 100), Size = UDim2.fromOffset(48, 30), Text = label, TextScaled = true }, Catalog.RarityColors[filter] or palette.White)
		self.maid:Give(b.Activated:Connect(function()
			self.filter = filter
			self.FilterChanged:Fire(filter)
			self:_renderGarage()
		end))
		self.filterButtons[filter] = b
	end
	self.grid = UIKit.new("ScrollingFrame", { Name = "Grid", Position = UDim2.fromOffset(144, 138), Size = UDim2.fromOffset(424, 424), BackgroundTransparency = 1, BorderSizePixel = 0, ScrollBarThickness = 8, ScrollingDirection = Enum.ScrollingDirection.Y }, panel)
	self.tiles = {}
	-- detail side
	local side = UIKit.panel(panel, { Position = UDim2.fromOffset(576, 64), Size = UDim2.fromOffset(288, 498), BackgroundColor3 = palette.NavyFloor, BackgroundTransparency = 0.1 })
	self.viewport = UIKit.new("ViewportFrame", { Position = UDim2.fromOffset(14, 10), Size = UDim2.fromOffset(260, 200), BackgroundTransparency = 1, Ambient = Color3.fromRGB(170, 170, 190), LightColor = Color3.new(1, 1, 1) }, side)
	local camera = Instance.new("Camera")
	camera.FieldOfView = 40
	camera.CFrame = CFrame.lookAt(Vector3.new(0, 1.4, 11), Vector3.new(0, 0, 0))
	camera.Parent = self.viewport
	self.viewport.CurrentCamera = camera
	self.previewText = UIKit.label(side, { Position = UDim2.fromOffset(14, 80), Size = UDim2.fromOffset(260, 60), Font = Enum.Font.GothamBlack, TextScaled = true, Text = "", Visible = false })
	self.detailName = UIKit.label(side, { Position = UDim2.fromOffset(14, 216), Size = UDim2.fromOffset(260, 32), Font = Enum.Font.GothamBlack, Text = "" })
	self.detailRarity = UIKit.label(side, { Position = UDim2.fromOffset(14, 248), Size = UDim2.fromOffset(260, 22), Font = Enum.Font.GothamBold, Text = "" })
	self.detailStatus = UIKit.label(side, { Position = UDim2.fromOffset(14, 274), Size = UDim2.fromOffset(260, 44), Font = Enum.Font.Gotham, TextWrapped = true, Text = "" })
	self.equipButton = UIKit.Primary(UIKit.button(side, { Name = "Equip", Position = UDim2.fromOffset(14, 326), Size = UDim2.fromOffset(260, 46), Text = "EQUIP" }, palette.Mint))
	self.maid:Give(self.equipButton.Activated:Connect(function()
		self:_equip(0)
	end))
	self.slotButtons = {}
	for slot = 1, 3 do
		local b = UIKit.button(side, { Name = "Equip", Position = UDim2.fromOffset(14 + (slot - 1) * 88, 326), Size = UDim2.fromOffset(84, 46), Text = "SLOT " .. slot, Visible = false }, palette.Mint)
		self.maid:Give(b.Activated:Connect(function()
			self:_equip(slot)
		end))
		self.slotButtons[slot] = b
	end
	self.favButton = UIKit.button(side, { Name = "Favorite", Position = UDim2.fromOffset(14, 382), Size = UDim2.fromOffset(260, 40), Text = "FAVORITE" }, palette.Yellow)
	self.maid:Give(self.favButton.Activated:Connect(function()
		if self.selected then
			self.remotes.RequestFavorite:FireServer(self.selected, not self.cosmetics.favorites[self.selected])
		end
	end))
	UIKit.label(side, { Position = UDim2.fromOffset(14, 430), Size = UDim2.fromOffset(260, 60), Font = Enum.Font.Gotham, TextWrapped = true, TextTransparency = 0.25, Text = "Looks only - every marble rolls exactly the same." })
end

-- the saved Garage filter (Settings key garageFilter)
function HubMenus:SetFilter(filter)
	for _, f in ipairs(HubMenus.Filters) do
		if f == filter and self.filter ~= filter then
			self.filter = filter
			self:_renderGarage()
		end
	end
end

function HubMenus:_equip(slot)
	local item = self.selected and Catalog.Get(self.selected)
	if not item then
		return
	end
	if not self.cosmetics.owned[item.Id] then
		self.toast(Catalog.HowToEarn(item.Id), 2.5)
		return
	end
	self.remotes.RequestEquipCosmetic:FireServer(item.Kind, item.Id, slot)
end

function HubMenus:_isEquipped(item)
	local eq = self.cosmetics.equipped
	if item.Kind == "Emote" then
		for _, id in ipairs(eq.emotes or {}) do
			if id == item.Id then
				return true
			end
		end
		return false
	end
	return eq[string.lower(item.Kind)] == item.Id
end

-- Launch Animations preview: your equipped marble does the real launch pose (MotionFeel) on a
-- little ramp, looping. Same maths as the race intro, so what you see is what you get (the
-- Comet Arc's ember streak is drawn only in the race: trails don't render in a viewport).
HubMenus.PreviewPath = { start = Vector3.new(-24, 12, 0), lip = Vector3.new(-6, 4.5, 0), slot = Vector3.new(14, 0, 0), delay = 0 }
HubMenus.PreviewCamera = CFrame.lookAt(Vector3.new(-2, 7, 64), Vector3.new(-2, 4, 0))

function HubMenus:_previewLaunchItem(item)
	local model = Instance.new("Model")
	local path = HubMenus.PreviewPath
	local function part(props)
		local p = Instance.new("Part")
		p.Anchored = true
		for k, v in pairs(props) do
			p[k] = v
		end
		p.Parent = model
		return p
	end
	local deckLen = (path.lip - path.start).Magnitude + 6
	local mid = (path.start + path.lip) / 2 - Vector3.new(0, 2.5, 0)
	part({ Size = Vector3.new(deckLen, 1, 10), CFrame = CFrame.lookAt(mid, mid + (path.lip - path.start), Vector3.new(0, 1, 0)) * CFrame.Angles(0, math.pi / 2, 0), Color = palette.NavyFloor, Material = Enum.Material.SmoothPlastic })
	part({ Size = Vector3.new(26, 1, 10), CFrame = CFrame.new(path.slot - Vector3.new(0, 2.5, 0)), Color = palette.Navy, Material = Enum.Material.SmoothPlastic })
	local function marble(transparency)
		local ball = part({ Shape = Enum.PartType.Ball, Size = Vector3.new(4, 4, 4), CFrame = CFrame.new(path.start) })
		local holder = Instance.new("Model")
		holder.Parent = model
		ball.Parent = holder
		holder.PrimaryPart = ball
		MarbleLook.Apply(ball, Catalog.Get(self.cosmetics.equipped.marble or Catalog.Defaults.marble), function(_, shellPart)
			shellPart.Anchored = true
			shellPart.Parent = holder
		end, nil)
		if transparency then
			for _, d in ipairs(holder:GetDescendants()) do
				if d:IsA("BasePart") then
					d.Transparency = math.max(d.Transparency, transparency)
				end
			end
		end
		return holder
	end
	local style = MotionFeel.LaunchStyle(item.Id)
	local echoes = {}
	for i, lag in ipairs(style.echoes or {}) do
		echoes[i] = { model = marble(i == 1 and 0.55 or 0.75), lag = lag }
	end
	self.previewLaunch = { model = model, ball = marble(nil), echoes = echoes, id = item.Id, t0 = os.clock() }
	self.viewport.CurrentCamera.CFrame = HubMenus.PreviewCamera
	self.viewport.CurrentCamera.FieldOfView = 40
	model.Parent = self.viewport
	self.previewModel = model
end

function HubMenus:_stepLaunchPreview()
	local p = self.previewLaunch
	local loop = MotionFeel.LaunchEnd(1) + 0.9
	local t = (os.clock() - p.t0) % loop
	local function place(holder, tt)
		local pos, roll = MotionFeel.LaunchPose(HubMenus.PreviewPath, math.max(0, tt), p.id)
		holder:PivotTo(CFrame.new(pos) * CFrame.Angles(0, 0, -roll))
	end
	place(p.ball, t)
	for _, e in ipairs(p.echoes) do
		place(e.model, t - e.lag)
	end
end

function HubMenus:_preview(item)
	if self.previewModel then
		self.previewModel:Destroy()
		self.previewModel = nil
	end
	if self.previewLaunch then
		self.previewLaunch = nil
		self.viewport.CurrentCamera.CFrame = CFrame.lookAt(Vector3.new(0, 1.4, 11), Vector3.new(0, 0, 0))
	end
	self.previewText.Visible = false
	if not item then
		return
	end
	if item.Kind == "Launch" then
		self:_previewLaunchItem(item)
	elseif item.Kind == "Marble" or item.Kind == "Trail" then
		local model = Instance.new("Model")
		local ball = Instance.new("Part")
		ball.Shape = Enum.PartType.Ball
		ball.Size = Vector3.new(4, 4, 4)
		ball.Anchored = true
		ball.CFrame = CFrame.new()
		ball.Parent = model
		model.PrimaryPart = ball
		local marble = item.Kind == "Marble" and item or Catalog.Get(self.cosmetics.equipped.marble or Catalog.Defaults.marble)
		MarbleLook.Apply(ball, marble, function(_, part)
			part.Anchored = true
			part.Parent = model
		end, nil)
		if item.Kind == "Trail" then
			for i = 1, 6 do
				local bit = Instance.new("Part")
				bit.Anchored = true
				bit.Size = Vector3.new(0.6, 1.6 - i * 0.2, 1)
				bit.Material = Enum.Material.Neon
				bit.Color = item.Colors[1]:Lerp(item.Colors[2], i / 6)
				bit.Transparency = i / 8
				bit.CFrame = CFrame.new(0, 0, i * 1.1 + 1.6)
				bit.Parent = model
			end
		end
		model.Parent = self.viewport
		self.previewModel = model
	else
		self.previewText.Visible = true
		self.previewText.Text = item.Kind == "Emote" and ((item.Icon or "") .. " " .. item.Name) or ("* " .. string.upper(item.Name) .. " *")
		self.previewText.TextColor3 = Catalog.RarityColors[item.Rarity]
	end
end

function HubMenus:_renderGarage()
	if not self.garage then
		return
	end
	for kind, b in pairs(self.tabButtons) do
		b.BackgroundTransparency = kind == self.tab and 0 or 0.6
		local stroke = b:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Transparency = kind == self.tab and 0 or 0.6
		end
	end
	for filter, b in pairs(self.filterButtons) do
		b.TextColor3 = filter == self.filter and palette.Mint or palette.White
	end
	local items = HubMenus.FilterItems(self.tab, self.filter, self.cosmetics, self.search and self.search.Text or "")
	items = HubMenus.SortItems(items, function(it)
		return self:_isEquipped(it)
	end, self.cosmetics)
	for _, tile in ipairs(self.tiles) do
		tile:Destroy()
	end
	self.tiles = {}
	local cols = 3
	for i, item in ipairs(items) do
		local owned = self.cosmetics.owned[item.Id]
		local x, y = (i - 1) % cols, math.floor((i - 1) / cols)
		local tile = UIKit.button(self.grid, { Name = "GarageItem", Position = UDim2.fromOffset(4 + x * 132, 4 + y * 100), Size = UDim2.fromOffset(124, 92), Text = "" }, Catalog.RarityColors[item.Rarity])
		tile.BackgroundTransparency = owned and 0 or 0.55
		UIKit.label(tile, { Position = UDim2.fromScale(0.05, 0.06), Size = UDim2.fromScale(0.9, 0.48), Font = Enum.Font.GothamBlack, TextScaled = true, TextWrapped = true, Text = item.Name })
		local equipped = self:_isEquipped(item)
		local tag = equipped and "EQUIPPED" or owned and (self.cosmetics.favorites[item.Id] and "OWNED  *" or "OWNED") or "LOCKED"
		if equipped then
			local badge = UIKit.new("Frame", { Name = "EquippedBadge", Position = UDim2.fromOffset(0, 0), Size = UDim2.new(1, 0, 0, 5), BorderSizePixel = 0 }, tile)
			UIKit.TrackAccent(badge, "BackgroundColor3")
		end
		UIKit.label(tile, { Position = UDim2.fromScale(0.05, 0.6), Size = UDim2.fromScale(0.9, 0.32), Font = Enum.Font.GothamBold, TextScaled = true, TextColor3 = Catalog.RarityColors[item.Rarity], Text = string.upper(item.Rarity) .. " - " .. tag })
		if item.Id == self.selected then
			UIKit.new("UIStroke", { Color = palette.Mint, Thickness = 3 }, tile)
		end
		self.maid:Give(tile.Activated:Connect(function()
			self.selected = item.Id
			self:_renderGarage()
		end))
		self.tiles[#self.tiles + 1] = tile
	end
	self.grid.CanvasSize = UDim2.fromOffset(0, math.ceil(#items / cols) * 100 + 8)
	if #items == 0 then
		self.detailName.Text = ""
	end
	local item = self.selected and Catalog.Get(self.selected)
	if item and item.Kind ~= self.tab then
		item = items[1]
		self.selected = item and item.Id or nil
	end
	self:_preview(item)
	if item then
		local owned = self.cosmetics.owned[item.Id]
		self.detailName.Text = item.Name
		self.detailRarity.Text = string.upper(item.Rarity)
		self.detailRarity.TextColor3 = Catalog.RarityColors[item.Rarity]
		local status = self:_isEquipped(item) and "Equipped" or owned and "Owned" or ("How to get it: " .. Catalog.HowToEarn(item.Id))
		self.detailStatus.Text = item.Blurb and (item.Blurb .. " " .. status) or status
		local emote = item.Kind == "Emote"
		self.equipButton.Visible = not emote
		self.equipButton.Text = self:_isEquipped(item) and "EQUIPPED" or owned and "EQUIP" or "LOCKED"
		for slot, b in ipairs(self.slotButtons) do
			b.Visible = emote
			b.Text = (self.cosmetics.equipped.emotes or {})[slot] == item.Id and ("SLOT " .. slot .. " ON") or ("SLOT " .. slot)
		end
		self.favButton.Text = self.cosmetics.favorites[item.Id] and "UNFAVORITE" or "FAVORITE"
	end
end

---------------------------------------------------------------------------------------------
-- Quests
---------------------------------------------------------------------------------------------
function HubMenus:_buildQuests(root)
	local panel, close = modalPanel(root, "Quests", Vector2.new(720, 560), palette.Yellow, "QUESTS")
	self.questPanel = panel
	self.maid:Give(close.Activated:Connect(function()
		self.CloseRequested:Fire()
	end))
	self.questRows = {}
	local function row(scope, index, y)
		local frame = UIKit.panel(panel, { Position = UDim2.fromOffset(24, y), Size = UDim2.fromOffset(672, 48), BackgroundColor3 = palette.NavyFloor, BackgroundTransparency = 0.1 })
		local text = UIKit.label(frame, { Position = UDim2.fromOffset(12, 4), Size = UDim2.fromOffset(420, 22), Font = Enum.Font.GothamBold, Text = "", TextXAlignment = Enum.TextXAlignment.Left })
		local barBack = UIKit.new("Frame", { Position = UDim2.fromOffset(12, 30), Size = UDim2.fromOffset(420, 10), BackgroundColor3 = palette.Navy, BorderSizePixel = 0 }, frame)
		local bar = UIKit.new("Frame", { Size = UDim2.fromScale(0, 1), BackgroundColor3 = palette.Yellow, BorderSizePixel = 0 }, barBack)
		local count = UIKit.label(frame, { Position = UDim2.fromOffset(440, 8), Size = UDim2.fromOffset(80, 32), Font = Enum.Font.GothamBlack, Text = "" })
		local claim = UIKit.button(frame, { Name = "QuestClaim", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -8, 0, 4), Size = UDim2.fromOffset(130, 40), Text = "CLAIM" }, palette.Yellow)
		self.maid:Give(claim.Activated:Connect(function()
			self.remotes.RequestQuestClaim:FireServer(scope, index)
		end))
		self.questRows[scope .. index] = { frame = frame, text = text, bar = bar, count = count, claim = claim }
	end
	UIKit.label(panel, { Position = UDim2.fromOffset(24, 60), Size = UDim2.fromOffset(400, 24), Font = Enum.Font.GothamBlack, TextColor3 = palette.Yellow, Text = "DAILY", TextXAlignment = Enum.TextXAlignment.Left })
	self.dailyReset = UIKit.label(panel, { Position = UDim2.fromOffset(300, 60), Size = UDim2.fromOffset(396, 24), Font = Enum.Font.Gotham, Text = "", TextXAlignment = Enum.TextXAlignment.Right })
	for i = 1, QuestConfig.DailyCount do
		row("Daily", i, 88 + (i - 1) * 54)
	end
	UIKit.label(panel, { Position = UDim2.fromOffset(24, 256), Size = UDim2.fromOffset(400, 24), Font = Enum.Font.GothamBlack, TextColor3 = palette.Yellow, Text = "WEEKLY", TextXAlignment = Enum.TextXAlignment.Left })
	self.weeklyReset = UIKit.label(panel, { Position = UDim2.fromOffset(300, 256), Size = UDim2.fromOffset(396, 24), Font = Enum.Font.Gotham, Text = "", TextXAlignment = Enum.TextXAlignment.Right })
	for i = 1, #QuestConfig.Weekly do
		row("Weekly", i, 284 + (i - 1) * 54)
	end
	self.questNote = UIKit.label(panel, { Position = UDim2.fromOffset(24, 504), Size = UDim2.fromOffset(672, 44), Font = Enum.Font.Gotham, TextWrapped = true, TextTransparency = 0.15, Text = "" })
end

function HubMenus:_renderQuests()
	local q = self.quests
	if not q or not self.questPanel then
		return
	end
	local elapsed = os.clock() - (self.questsReceivedAt or os.clock())
	self.dailyReset.Text = "new quests in " .. duration((q.resetsDailyIn or 0) - elapsed)
	self.weeklyReset.Text = "new quests in " .. duration((q.resetsWeeklyIn or 0) - elapsed)
	for _, scope in ipairs({ "Daily", "Weekly" }) do
		local list = scope == "Daily" and q.daily or q.weekly
		local reward = q.rewards and q.rewards[scope] or QuestConfig.Rewards[scope]
		local count = scope == "Daily" and QuestConfig.DailyCount or #QuestConfig.Weekly
		for i = 1, count do
			local row = self.questRows[scope .. i]
			local entry = list[i]
			local def = entry and QuestConfig.Def(scope, entry.id)
			row.frame.Visible = def ~= nil
			if def then
				row.text.Text = string.format("%s   (+%d Coins, +%d XP)", def.text, reward.coins, reward.xp)
				row.bar.Size = UDim2.fromScale(math.clamp(entry.progress / def.target, 0, 1), 1)
				row.count.Text = string.format("%d/%d", entry.progress, def.target)
				local ready = entry.progress >= def.target and not entry.claimed
				row.claim.Text = entry.claimed and "CLAIMED" or ready and "CLAIM" or "..."
				row.claim.AutoButtonColor = ready
				row.claim.BackgroundTransparency = ready and 0 or 0.6
			end
		end
	end
	self.questNote.Text = string.format("Bot races counted for quests today: %d/%d. After that, bot races still pay Coins but don't count for quests. Quests reset at 00:00 UTC (weekly: Monday).", math.min(q.botRaces or 0, q.botLimit or 3), q.botLimit or 3)
end

---------------------------------------------------------------------------------------------
-- Boards
---------------------------------------------------------------------------------------------
function HubMenus:_buildBoards(root)
	local panel, close = modalPanel(root, "Boards", Vector2.new(720, 560), palette.Violet, "LEADERBOARDS")
	self.boardPanel = panel
	self.maid:Give(close.Activated:Connect(function()
		self.CloseRequested:Fire()
	end))
	self.worldButtons = {}
	for i, def in ipairs(TrackDefinitions.Worlds) do
		local b = UIKit.button(panel, { Name = "BoardWorld", Position = UDim2.fromOffset(24 + (i - 1) * 172, 60), Size = UDim2.fromOffset(164, 38), Text = string.upper(def.DisplayName) }, palette.Violet)
		self.maid:Give(b.Activated:Connect(function()
			self.boardWorld = def.Id
			self:RequestBoard()
		end))
		self.worldButtons[def.Id] = b
	end
	self.seedButtons = {}
	for seed = 0, 2 do
		local b = UIKit.button(panel, { Name = "BoardWorld", Position = UDim2.fromOffset(24 + seed * 76, 106), Size = UDim2.fromOffset(70, 32), Text = "V" .. (seed + 1) }, palette.Cyan)
		self.maid:Give(b.Activated:Connect(function()
			self.boardSeed = seed
			self:RequestBoard()
		end))
		self.seedButtons[seed] = b
	end
	self.kindButtons = {}
	for i, kind in ipairs({ "Best", "Wins" }) do
		local b = UIKit.button(panel, { Name = "BoardKind", Position = UDim2.fromOffset(300 + (i - 1) * 200, 106), Size = UDim2.fromOffset(192, 32), Text = kind == "Best" and "BEST TIMES" or "WEEKLY WINS" }, palette.Yellow)
		self.maid:Give(b.Activated:Connect(function()
			self.boardKind = kind
			self:RequestBoard()
		end))
		self.kindButtons[kind] = b
	end
	self.boardRows = {}
	for i = 1, 10 do
		self.boardRows[i] = UIKit.label(panel, { Position = UDim2.fromOffset(24, 148 + (i - 1) * 28), Size = UDim2.fromOffset(400, 26), Font = Enum.Font.GothamBold, Text = "", TextXAlignment = Enum.TextXAlignment.Left })
	end
	UIKit.label(panel, { Position = UDim2.fromOffset(440, 148), Size = UDim2.fromOffset(256, 24), Font = Enum.Font.GothamBlack, TextColor3 = palette.Mint, Text = "FRIENDS HERE", TextXAlignment = Enum.TextXAlignment.Left })
	self.friendRows = {}
	for i = 1, 8 do
		self.friendRows[i] = UIKit.label(panel, { Position = UDim2.fromOffset(440, 176 + (i - 1) * 26), Size = UDim2.fromOffset(256, 24), Font = Enum.Font.Gotham, Text = "", TextXAlignment = Enum.TextXAlignment.Left })
	end
	self.boardMine = UIKit.label(panel, { Position = UDim2.fromOffset(24, 440), Size = UDim2.fromOffset(672, 26), Font = Enum.Font.GothamBlack, TextColor3 = palette.Yellow, Text = "", TextXAlignment = Enum.TextXAlignment.Left })
	self.boardNote = UIKit.label(panel, { Position = UDim2.fromOffset(24, 470), Size = UDim2.fromOffset(672, 70), Font = Enum.Font.Gotham, TextWrapped = true, TextTransparency = 0.15, Text = "", TextXAlignment = Enum.TextXAlignment.Left })
end

function HubMenus:RequestBoard()
	for id, b in pairs(self.worldButtons) do
		b.TextColor3 = id == self.boardWorld and palette.Mint or palette.White
	end
	for seed, b in pairs(self.seedButtons) do
		b.TextColor3 = seed == self.boardSeed and palette.Mint or palette.White
	end
	for kind, b in pairs(self.kindButtons) do
		b.TextColor3 = kind == self.boardKind and palette.Mint or palette.White
	end
	self.boardNote.Text = "Loading..."
	self.remotes.RequestLeaderboard:FireServer(self.boardKind, self.boardWorld, self.boardSeed)
end

function HubMenus:_renderBoard(data)
	local rows = type(data.rows) == "table" and data.rows or {}
	for i, label in ipairs(self.boardRows) do
		local row = rows[i]
		if row then
			local value = data.kind == "Wins" and string.format("%d wins", row.value or 0) or (row.seconds and Utility.formatTime(row.seconds) or "--")
			label.Text = string.format("%2d. %s  -  %s", row.rank or i, tostring(row.name or "Racer"), value)
		else
			label.Text = i == 1 and "No times yet" or ""
		end
	end
	local friends = type(data.friends) == "table" and data.friends or {}
	for i, label in ipairs(self.friendRows) do
		local f = friends[i]
		label.Text = f and string.format("%s  %s", tostring(f.name), f.seconds and Utility.formatTime(f.seconds) or "--") or (i == 1 and "No friends in this server" or "")
	end
	self.boardMine.Text = data.kind == "Wins" and "Wins count only in races with 2+ people." or ("YOUR BEST: " .. (type(data.mine) == "number" and Utility.formatTime(data.mine) or "--"))
	self.boardNote.Text = (data.error and (data.error .. ". ") or "") .. "Real players only (no bots). Times are per world and variation (V1-V3 = hazard patterns)."
end

---------------------------------------------------------------------------------------------
function HubMenus:RegisterLayers(ui)
	ui:Register("Garage", function(visible)
		UIKit.Show(self.garage, visible, "Pop")
		if visible then
			self:_renderGarage()
		end
	end)
	ui:Register("Quests", function(visible)
		UIKit.Show(self.questPanel, visible, "Pop")
		if visible then
			self:_renderQuests()
		end
	end)
	ui:Register("Boards", function(visible)
		UIKit.Show(self.boardPanel, visible, "Pop")
		if visible then
			self:RequestBoard()
		end
	end)
end

function HubMenus:Destroy()
	if self.previewModel then
		self.previewModel:Destroy()
	end
	self.maid:Cleanup()
end

return HubMenus
