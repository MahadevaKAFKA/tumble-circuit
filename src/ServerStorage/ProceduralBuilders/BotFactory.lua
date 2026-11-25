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

function BotFactory.AddNameplate(ball, text, color)
	local gui = Instance.new("BillboardGui")
	gui.Name = "Nameplate"
	gui.Size = UDim2.fromOffset(180, 28)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 3.6, 0)
	gui.MaxDistance = 90
	gui.LightInfluence = 0
	gui.AlwaysOnTop = false
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.3
	label.Parent = gui
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
