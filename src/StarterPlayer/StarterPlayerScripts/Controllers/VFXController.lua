--[[
	VFXController — brief, low-cost A3 effects from native parts only (no asset ids). Purely
	visual and local: nothing here touches physics or the BallRoot orientation.
	  Boost      : cyan Trail on the boosting marble for the effect duration
	  Shield     : translucent ForceField shell following the shielded marble
	  Pulse      : coral ring expanding to the 12-stud radius over 0.35 s
	  Trick      : a spinning shell + stars around your marble (glow only under Reduced Motion)
	  Slipstream : faint cyan streaks behind your marble while drafting
	All effects are anchored local parts updated each frame and removed on expiry.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local AbilityConfig = require(Shared:WaitForChild("AbilityConfig"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local Protocol = require(Shared:WaitForChild("Protocol"))

local VFXController = {}
VFXController.__index = VFXController

local palette = GameConfig.Palette

local function effectPart(props)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	for key, value in pairs(props) do
		part[key] = value
	end
	part.Parent = workspace.CurrentCamera -- local-only container, never replicated
	return part
end

function VFXController.new(marblesFolder)
	local self = setmetatable({}, VFXController)
	self.marbles = marblesFolder
	self.effects = {}
	self.reducedMotion = false
	return self
end

function VFXController:SetReducedMotion(value)
	self.reducedMotion = value
end

-- A5 graphics preset: "Low" skips decorative extras (trails, streaks, stars, gate shells).
function VFXController:SetQuality(mode)
	self.low = mode == "Low"
end

local function ballFor(self, userId)
	return self.marbles:FindFirstChild(Protocol.MarbleName(userId))
end

function VFXController:_add(effect)
	table.insert(self.effects, effect)
end

function VFXController:OnOutcome(outcome)
	local t = workspace:GetServerTimeNow()
	if outcome.abilityId == "Boost" then
		local ball = not self.low and ballFor(self, outcome.userId)
		if ball then
			local a0 = Instance.new("Attachment")
			a0.Position = Vector3.new(0, 1.2, 0)
			local a1 = Instance.new("Attachment")
			a1.Position = Vector3.new(0, -1.2, 0)
			local trail = Instance.new("Trail")
			trail.Attachment0, trail.Attachment1 = a0, a1
			trail.Color = ColorSequence.new(palette.Cyan)
			trail.Transparency = NumberSequence.new(0.2, 1)
			trail.Lifetime = 0.35
			trail.LightEmission = 1
			a0.Parent, a1.Parent, trail.Parent = ball, ball, ball
			self:_add({ endsAt = outcome.endsAt or (t + 1.6), cleanup = { a0, a1, trail } })
		end
	elseif outcome.abilityId == "Shield" then
		local shell = effectPart({ Shape = Enum.PartType.Ball, Size = Vector3.new(5.6, 5.6, 5.6), Color = palette.Violet, Material = Enum.Material.ForceField, Transparency = 0.2 })
		self:_add({ endsAt = outcome.endsAt or (t + 2.5), follow = outcome.userId, part = shell, cleanup = { shell }, shield = true })
	elseif outcome.abilityId == "Pulse" then
		local ring = effectPart({ Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.3, 2, 2), Color = palette.Coral, Transparency = 0.3 })
		ring.CFrame = CFrame.fromMatrix(outcome.position, Vector3.new(0, 1, 0), Vector3.new(1, 0, 0))
		self:_add({ startedAt = t, endsAt = t + 0.35, part = ring, cleanup = { ring }, grow = AbilityConfig.Abilities.Pulse.Radius * 2, origin = outcome.position })
	end
	-- B2 abilities: brief, low-cost native-part visuals; a coloured aura for self effects
	local B2_AURA = { Phase = palette.Mint, GravityGlide = palette.Violet, Anchor = palette.Cyan, BounceBurst = palette.Mint, Magnet = palette.Violet }
	local aura = B2_AURA[outcome.abilityId]
	if aura then
		local shell = effectPart({ Shape = Enum.PartType.Ball, Size = Vector3.new(5.2, 5.2, 5.2), Color = aura, Material = Enum.Material.ForceField, Transparency = outcome.abilityId == "Anchor" and 0.1 or 0.35 })
		self:_add({ endsAt = outcome.endsAt or (t + 1.5), follow = outcome.userId, part = shell, cleanup = { shell } })
	elseif outcome.abilityId == "FrostWake" and type(outcome.lane) == "table" then
		local parts = {}
		local width = type(outcome.laneWidth) == "number" and outcome.laneWidth or 10
		for i = 1, #outcome.lane - 1 do
			local a, b = outcome.lane[i], outcome.lane[i + 1]
			if typeof(a) == "Vector3" and typeof(b) == "Vector3" and (b - a).Magnitude > 0.1 then
				local strip = effectPart({ Size = Vector3.new(width, 0.15, (b - a).Magnitude + 0.2), Color = Color3.fromRGB(190, 240, 255), Material = Enum.Material.Ice, Transparency = 0.35 })
				strip.CFrame = CFrame.lookAt((a + b) / 2 + Vector3.new(0, 0.1, 0), b + Vector3.new(0, 0.1, 0))
				parts[#parts + 1] = strip
			end
		end
		self:_add({ endsAt = outcome.endsAt or (t + 2.2), cleanup = parts })
	elseif outcome.abilityId == "GrappleSpark" and typeof(outcome.anchor) == "Vector3" then
		local ball = ballFor(self, outcome.userId)
		if ball then
			local a0 = Instance.new("Attachment")
			local target = effectPart({ Size = Vector3.new(0.4, 0.4, 0.4), Transparency = 1 })
			target.CFrame = CFrame.new(outcome.anchor)
			local a1 = Instance.new("Attachment")
			a1.Parent = target
			local beam = Instance.new("Beam")
			beam.Attachment0, beam.Attachment1 = a0, a1
			beam.Color = ColorSequence.new(palette.Yellow)
			beam.Width0, beam.Width1 = 0.4, 0.4
			beam.LightEmission = 1
			beam.FaceCamera = true
			a0.Parent = ball
			beam.Parent = ball
			self:_add({ endsAt = outcome.endsAt or (t + 0.4), cleanup = { a0, beam, target } })
		end
	end
	for _, blockedId in ipairs(outcome.blocked or {}) do
		self:EndShield(blockedId)
	end
end

function VFXController:EndShield(userId)
	for _, effect in ipairs(self.effects) do
		if effect.shield and effect.follow == userId then
			effect.endsAt = 0
		end
	end
end

function VFXController:Trick(localUserId)
	local t = workspace:GetServerTimeNow()
	local shell = effectPart({ Shape = Enum.PartType.Ball, Size = Vector3.new(4.6, 4.6, 4.6), Color = palette.Mint, Material = Enum.Material.ForceField, Transparency = 0.1 })
	local band = effectPart({ Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.4, 4.9, 4.9), Color = palette.Yellow })
	self:_add({ startedAt = t, endsAt = t + 0.45, follow = localUserId, part = shell, spin = band, cleanup = { shell, band } })
	if not self.reducedMotion and not self.low then
		for i = 1, 5 do
			local star = effectPart({ Size = Vector3.new(0.5, 0.5, 0.5), Color = palette.Yellow })
			local angle = i / 5 * math.pi * 2
			self:_add({ startedAt = t, endsAt = t + 0.5, follow = localUserId, part = star, orbit = angle, cleanup = { star } })
		end
	end
end

-- A4 Chaos Gate surge: a short coloured shell on whoever collected it (any racer, bots too).
function VFXController:ChaosSurge(userId, tier)
	if self.low or type(userId) ~= "number" or not ballFor(self, userId) then
		return
	end
	local t = workspace:GetServerTimeNow()
	local color = tier == "Bottom" and palette.Mint or tier == "Top" and palette.Yellow or palette.Violet
	local shell = effectPart({ Shape = Enum.PartType.Ball, Size = Vector3.new(5, 5, 5), Color = color, Material = Enum.Material.ForceField, Transparency = 0.15 })
	self:_add({ startedAt = t, endsAt = t + (tier == "Bottom" and 2 or tier == "Middle" and 1.5 or 1), follow = userId, part = shell, cleanup = { shell } })
end

-- A6 finish celebration: a short, cheap confetti burst (18 anchored bits moved by Step).
-- Skipped with Reduced Motion or the Low graphics preset.
-- B3 finish bursts (catalog ids): colours, piece shape, count, launch speed
VFXController.Bursts = {
	burst_confetti = { colors = { palette.Cyan, palette.Coral, palette.Yellow, palette.Violet, palette.Mint }, count = 18, up = 18, out = 6 },
	burst_stars = { colors = { palette.Yellow, palette.White }, count = 16, up = 20, out = 7, ball = true },
	burst_bubbles = { colors = { Color3.fromRGB(200, 240, 255), Color3.fromRGB(255, 200, 240) }, count = 12, up = 10, out = 4, ball = true, glass = true },
	burst_sparks = { colors = { palette.Yellow, palette.Coral }, count = 22, up = 24, out = 10, thin = true },
	burst_snowflakes = { colors = { palette.White, Color3.fromRGB(190, 240, 255) }, count = 18, up = 12, out = 5 },
	burst_fireworks = { colors = { palette.Coral, palette.Mint, palette.Violet, palette.Yellow }, count = 26, up = 28, out = 9, ball = true },
	burst_lightning = { colors = { palette.Yellow, palette.Violet }, count = 14, up = 32, out = 3, thin = true },
	burst_s1_launch = { colors = { palette.Cyan, palette.Yellow }, count = 24, up = 26, out = 8, thin = true }, -- D: Season 1 premium lane
	burst_supernova = { colors = { palette.Cyan, palette.Coral, palette.Yellow, palette.Violet, palette.Mint, palette.White }, count = 32, up = 24, out = 12, ball = true },
}

function VFXController:Confetti(position, burstId)
	if self.reducedMotion or self.low or typeof(position) ~= "Vector3" then
		return
	end
	local t = workspace:GetServerTimeNow()
	local style = VFXController.Bursts[burstId] or VFXController.Bursts.burst_confetti
	local colors = style.colors
	local n = style.count
	for i = 1, n do
		local size = style.ball and Vector3.new(0.45, 0.45, 0.45) or style.thin and Vector3.new(0.12, 0.12, 0.9) or Vector3.new(0.5, 0.12, 0.35)
		local bit = effectPart({ Size = size, Shape = style.ball and Enum.PartType.Ball or Enum.PartType.Block, Color = colors[(i - 1) % #colors + 1], Material = style.glass and Enum.Material.Glass or Enum.Material.Neon, Transparency = style.glass and 0.4 or 0 })
		local angle = i / n * math.pi * 2
		local velocity = Vector3.new(math.cos(angle) * (style.out + (i % 4)), style.up + (i % 5) * 2, math.sin(angle) * (style.out + (i % 3)))
		bit.CFrame = CFrame.new(position)
		self:_add({ startedAt = t, endsAt = t + 1.6, part = bit, cleanup = { bit }, confetti = { origin = position, velocity = velocity, spin = i } })
	end
end

function VFXController:SetSlipstream(localUserId, active)
	if active and not self.slipstream and not self.low then
		local streaks = {}
		for i = 1, 3 do
			streaks[i] = effectPart({ Size = Vector3.new(0.15, 0.15, 6), Color = palette.Cyan, Transparency = 0.5 })
		end
		self.slipstream = { follow = localUserId, parts = streaks }
	elseif not active and self.slipstream then
		for _, part in ipairs(self.slipstream.parts) do
			part:Destroy()
		end
		self.slipstream = nil
	end
end

-- B3: equipped trails are server Trails on each marble; Low graphics / reduced motion turn them
-- off on this device only (checked every 2 s, cheap)
function VFXController:_trailsLocal(now)
	if now < (self.nextTrailCheck or 0) then
		return
	end
	self.nextTrailCheck = now + 2
	local folder = self.marbles
	if not folder then
		return
	end
	local on = false -- SpeedFeelController owns trails; an old server trail stays off
	for _, ball in ipairs(folder:GetChildren()) do
		local trail = ball:FindFirstChild("TC_Trail")
		if trail and trail.Enabled ~= on then
			trail.Enabled = on
		end
	end
end

function VFXController:Step()
	-- (2026-11-26) equipped trails are drawn by SpeedFeelController; this only keeps any old
	-- server-built trail switched off
	self:_trailsLocal(os.clock())
	local t = workspace:GetServerTimeNow()
	for i = #self.effects, 1, -1 do
		local e = self.effects[i]
		local ball = e.follow and ballFor(self, e.follow)
		if t >= e.endsAt or (e.follow and not ball) then
			for _, inst in ipairs(e.cleanup) do
				inst:Destroy()
			end
			table.remove(self.effects, i)
		else
			local progress = e.startedAt and math.clamp((t - e.startedAt) / (e.endsAt - e.startedAt), 0, 1) or 0
			if e.confetti and e.part then
				local c = e.confetti
				local age = t - e.startedAt
				local p = c.origin + c.velocity * age + Vector3.new(0, -24 * age * age, 0)
				e.part.CFrame = CFrame.new(p) * CFrame.Angles(age * c.spin, age * 3, 0)
				e.part.Transparency = math.clamp((progress - 0.6) / 0.4, 0, 1)
			elseif e.grow and e.part then
				local d = 2 + (e.grow - 2) * progress
				e.part.Size = Vector3.new(0.3, d, d)
				e.part.Transparency = 0.3 + 0.7 * progress
			elseif ball and e.part then
				local base = CFrame.new(ball.Position)
				if e.orbit then
					local a = e.orbit + progress * math.pi * 2
					e.part.CFrame = base * CFrame.new(math.cos(a) * 3.2, 1 + progress * 2, math.sin(a) * 3.2)
				else
					e.part.CFrame = base
				end
				if e.spin then
					local angle = self.reducedMotion and 0 or progress * math.pi * 2
					e.spin.CFrame = base * CFrame.Angles(angle, 0, math.pi / 2)
				end
			end
		end
	end
	if self.slipstream then
		local ball = ballFor(self, self.slipstream.follow)
		if ball then
			local v = ball.AssemblyLinearVelocity
			local dir = v.Magnitude > 1 and v.Unit or Vector3.new(0, 0, -1)
			for i, part in ipairs(self.slipstream.parts) do
				local side = (i - 2) * 1.6
				local right = dir:Cross(Vector3.new(0, 1, 0))
				local p = ball.Position - dir * 5 + right * side
				part.CFrame = CFrame.lookAt(p, p + dir)
			end
		end
	end
end

function VFXController:Destroy()
	for _, e in ipairs(self.effects) do
		for _, inst in ipairs(e.cleanup) do
			inst:Destroy()
		end
	end
	self.effects = {}
	self:SetSlipstream(nil, false)
end

return VFXController
