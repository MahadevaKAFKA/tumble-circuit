--[[
	BotFactory (A4) — creates bot marbles (identical body to human marbles: one radius-2 Ball,
	same physical properties, massless non-colliding stripes) and nameplates for every marble.
	Bot marbles are named Marble_<negative id> and carry IsBot = true.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local PhysicsConfig = require(Shared:WaitForChild("PhysicsConfig"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local RaceConfig = require(Shared:WaitForChild("RaceConfig"))

local BotFactory = {}

-- Name tag (players and bots). v2 (owner feedback 2026-11-26: tags covered "GO!" and each
-- other): a small dark chip sized in STUDS, so far tags shrink instead of stacking; only within
-- 60 studs; bots keep an honest grey "BOT" prefix instead of a red "[BOT]".
function BotFactory.AddNameplate(ball, text, color)
	-- 2026-11-26 three-lap brief: a small FIXED-PIXEL tag (it never grows to cover the road as a
	-- marble gets close); clients declutter them (NameplateController: hidden on the grid, up
	-- close, overlapping, or beyond the nearest few). Bots stay identified: "BOT" in the tag,
	-- the standings and the results.
	local gui = Instance.new("BillboardGui")
	gui.Name = "Nameplate"
	gui.Size = UDim2.fromOffset(104, 20)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 3.4, 0)
	gui.MaxDistance = 75
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	local isBot = string.sub(text, 1, 6) == "[BOT] "
	gui:SetAttribute("TC_Bot", isBot)
	local chip = Instance.new("Frame")
	chip.Name = "Chip"
	chip.AnchorPoint = Vector2.new(0.5, 0.5)
	chip.Position = UDim2.fromScale(0.5, 0.5)
	chip.Size = UDim2.fromScale(1, 1)
	chip.BackgroundColor3 = Color3.fromHex("#0B1020")
	chip.BackgroundTransparency = 0.45
	chip.Parent = gui
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = chip
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.RichText = true
	local name = isBot and string.sub(text, 7) or text
	name = string.gsub(name, "[<>&]", "") -- display names never break the rich text
	label.Text = isBot and ('<font color="#9AA4BF">BOT</font> ' .. name) or name
	label.TextScaled = true
	local ok, font = pcall(function()
		return Enum.Font.BuilderSansBold
	end)
	label.Font = ok and font or Enum.Font.GothamBold
	label.TextColor3 = isBot and Color3.fromHex("#E6EBF7") or color
	label.Parent = chip
	local pad = Instance.new("UIPadding")
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 2), UDim.new(0, 2)
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 4), UDim.new(0, 4)
	pad.Parent = label
	gui.Parent = ball
	return gui
end

function BotFactory.CreateBall(bot, cframe, frozen)
	local cfg = PhysicsConfig.Ball
	local palette = GameConfig.Palette
	local d = cfg.Radius * 2
	local ball = Instance.new("Part")
	ball.Name = Protocol.MarbleName(bot.UserId)
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.new(d, d, d)
	ball.Material = Enum.Material.SmoothPlastic
	ball.Color = palette.Coral:Lerp(palette.Navy, 0.15)
	ball.Reflectance = 0.2
	ball.CustomPhysicalProperties = PhysicalProperties.new(cfg.Density, cfg.Friction, cfg.Elasticity, cfg.FrictionWeight, cfg.ElasticityWeight)
	ball.CanTouch = false
	ball.RootPriority = 10
	ball.Anchored = frozen
	ball.CollisionGroup = RaceConfig.Collisions.ProtectedGroup
	ball.Transparency = 0.35
	ball.CFrame = cframe
	ball:SetAttribute(Protocol.BallAttributes.OwnerUserId, bot.UserId)
	ball:SetAttribute(Protocol.BallAttributes.Zone, Protocol.Zones.Race)
	ball:SetAttribute(Protocol.BallAttributes.Protected, true)
	ball:SetAttribute(Protocol.BallAttributes.Frozen, frozen)
	ball:SetAttribute("IsBot", true)
	ball:SetAttribute("BallRoot", true)
	for i, turn in ipairs({ CFrame.new(), CFrame.Angles(0, math.pi / 2, 0) }) do
		local stripe = Instance.new("Part")
		stripe.Name = "Stripe" .. i
		stripe.Shape = Enum.PartType.Cylinder
		stripe.Size = Vector3.new(0.55, d + 0.08, d + 0.08)
		stripe.Material = Enum.Material.Neon
		stripe.Color = i == 1 and palette.Yellow or palette.White
		stripe.CanCollide, stripe.CanQuery, stripe.CanTouch, stripe.Massless, stripe.CastShadow = false, false, false, true, false
		stripe.CFrame = cframe * turn
		local weld = Instance.new("WeldConstraint")
		weld.Part0, weld.Part1 = ball, stripe
		weld.Parent = stripe
		stripe.Parent = ball
	end
	BotFactory.AddNameplate(ball, "[BOT] " .. bot.DisplayName, palette.Coral)
	return ball
end

return BotFactory
