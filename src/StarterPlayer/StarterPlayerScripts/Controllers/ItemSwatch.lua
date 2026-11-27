--[[
	ItemSwatch (design v2, owner feedback 2026-11-26) — a flat 2D picture of a catalog item in
	its REAL colours, for Garage tiles and Shop cards (cheap: frames only, no ViewportFrame per
	tile). Marble = a disc in its colour with its pattern; trail = a carrier disc with its trace
	in the trail's colours (Twin = two traces); burst = rays; emote = a bubble with its icon;
	launch = a ramp and an arc. Pack / season offers fall back to a neutral case.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Catalog = require(Shared:WaitForChild("Catalog"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local palette = UIKit.Palette
local ItemSwatch = {}

local function frame(parent, props)
	local f = UIKit.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), BorderSizePixel = 0 }, parent)
	for key, value in pairs(props) do
		f[key] = value
	end
	return f
end

local function disc(parent, color, size, x, y)
	local d = frame(parent, { Position = UDim2.fromScale(x or 0.5, y or 0.5), Size = UDim2.fromScale(size, size), BackgroundColor3 = color })
	UIKit.new("UIAspectRatioConstraint", {}, d)
	UIKit.corner(d, 0.5)
	return d
end

-- Draw `item` (catalog item table or id) into `parent` (fills it). Returns the holder frame.
function ItemSwatch.Draw(parent, item)
	if type(item) == "string" then
		item = Catalog.Get(item)
	end
	local holder = UIKit.new("Frame", { Name = "Swatch", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ClipsDescendants = true }, parent)
	if not item then
		UIKit.Icon(holder, "Case", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.6, 0.6) })
		return holder
	end
	local rarity = Catalog.RarityColors[item.Rarity] or palette.White
	if item.Kind == "Marble" and item.Look then
		local look = item.Look
		local d = disc(holder, look.color, 0.78)
		local accent, accent2 = look.accent or palette.White, look.accent2 or look.accent or palette.White
		local function band(rotation, color, w, h)
			frame(d, { Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(w, h), Rotation = rotation, BackgroundColor3 = color })
		end
		local p = look.pattern or "None"
		if p == "Stripes" then
			band(0, accent, 1, 0.14)
			band(90, accent2, 1, 0.14)
		elseif p == "Ring" or p == "Halo" then
			band(0, accent, p == "Halo" and 1.2 or 1, 0.12)
		elseif p == "Bands" then
			for k = -1, 1 do
				frame(d, { Position = UDim2.fromScale(0.5 + k * 0.28, 0.5), Size = UDim2.fromScale(0.1, 0.92 - math.abs(k) * 0.2), BackgroundColor3 = k == 0 and accent2 or accent })
			end
		elseif p == "Speckle" then
			for k = 0, 6 do
				local dot = frame(d, { Position = UDim2.fromScale(0.5 + 0.3 * math.cos(k * 0.9), 0.5 + 0.3 * math.sin(k * 1.7)), Size = UDim2.fromScale(0.13, 0.13), BackgroundColor3 = accent })
				UIKit.corner(dot, 0.5)
			end
		elseif p == "Core" then
			band(0, accent, 1, 0.1)
			band(90, accent, 1, 0.1)
		elseif p == "Orbit" then
			band(55, accent, 1.15, 0.08)
			band(-55, accent2, 1.15, 0.08)
		end
		if look.glow then
			UIKit.new("UIStroke", { Color = accent, Thickness = 2, Transparency = 0.2 }, d)
		end
	elseif item.Kind == "Trail" and item.Colors then
		local twin = item.Profile == "Twin"
		local h = ({ Ribbon = 0.16, Thin = 0.07, Wide = 0.28, Twin = 0.08 })[item.Profile or "Ribbon"] or 0.16
		local function trace(y)
			local t = frame(holder, { AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0.06, y), Size = UDim2.fromScale(0.6, h), BackgroundColor3 = palette.White })
			UIKit.new("UIGradient", { Color = ColorSequence.new(item.Colors[2], item.Colors[1]), Transparency = NumberSequence.new(0.85, 0) }, t)
			UIKit.corner(t, 0.5)
		end
		if twin then
			trace(0.4)
			trace(0.6)
		else
			trace(0.5)
		end
		disc(holder, Color3.fromRGB(70, 78, 100), 0.4, 0.72, 0.5)
	elseif item.Kind == "Burst" then
		for k = 0, 5 do
			frame(holder, { Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.08, 0.8), Rotation = k * 30, BackgroundColor3 = k % 2 == 0 and rarity or palette.White })
		end
		disc(holder, rarity, 0.26)
	elseif item.Kind == "Emote" then
		local b = frame(holder, { Position = UDim2.fromScale(0.5, 0.45), Size = UDim2.fromScale(0.86, 0.56), BackgroundColor3 = palette.White })
		UIKit.corner(b, 0.3)
		UIKit.label(b, { Size = UDim2.fromScale(1, 1), TextColor3 = palette.Ink, Font = Enum.Font.GothamBlack, Text = item.Name })
		frame(holder, { Position = UDim2.fromScale(0.3, 0.76), Size = UDim2.fromScale(0.12, 0.12), Rotation = 45, BackgroundColor3 = palette.White })
	elseif item.Kind == "Launch" then
		frame(holder, { Position = UDim2.fromScale(0.36, 0.66), Size = UDim2.fromScale(0.62, 0.09), Rotation = -26, BackgroundColor3 = UIKit.Colors.Muted })
		for k = 1, 4 do
			local u = k / 5
			local dot = frame(holder, { Position = UDim2.fromScale(0.6 + u * 0.3, 0.4 - math.sin(u * math.pi) * 0.22), Size = UDim2.fromScale(0.06, 0.06), BackgroundColor3 = rarity, BackgroundTransparency = 0.3 })
			UIKit.corner(dot, 0.5)
		end
		disc(holder, palette.White, 0.22, 0.6, 0.4)
	elseif item.Kind == "Plate" then
		-- shop brief: a results nameplate (Gridline adds its checkered corner)
		local pill = frame(holder, { Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromScale(0.86, 0.36), BackgroundColor3 = palette.NavyFloor })
		UIKit.corner(pill, 0.3)
		UIKit.label(pill, { Size = UDim2.fromScale(0.8, 0.7), Position = UDim2.fromScale(0.06, 0.15), Font = Enum.Font.GothamBlack, TextXAlignment = Enum.TextXAlignment.Left, Text = "DRIVER" })
		if item.Accent == "Checkered" then
			for cx = 0, 2 do
				for cy = 0, 1 do
					UIKit.new("Frame", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -4 - (2 - cx) * 6, 0, 4 + cy * 6), Size = UDim2.fromOffset(6, 6), BorderSizePixel = 0, BackgroundColor3 = ((cx + cy) % 2 == 0) and palette.White or palette.Ink }, pill)
				end
			end
		end
	elseif item.Kind == "Podium" then
		-- shop brief: a podium effect (Victory Pulse = a gold ring around the winning marble)
		frame(holder, { Position = UDim2.fromScale(0.5, 0.82), Size = UDim2.fromScale(0.5, 0.16), BackgroundColor3 = palette.NavyFloor })
		disc(holder, palette.White, 0.34, 0.5, 0.45)
		if item.Effect == "GoldRing" then
			local ring = disc(holder, palette.Yellow, 0.56, 0.5, 0.45)
			ring.BackgroundTransparency = 1
			UIKit.new("UIStroke", { Color = palette.Yellow, Thickness = 2 }, ring)
		end
	end
	return holder
end

return ItemSwatch
