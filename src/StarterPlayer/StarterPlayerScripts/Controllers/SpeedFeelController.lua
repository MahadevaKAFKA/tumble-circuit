--[[
	SpeedFeelController (owner brief 2026-11-26: "make the racing feel fast") — client only,
	presentation only. Owns:

	* The free speed trail on every rendered marble (players and bots), the same curve for
	  everyone (MotionFeel.StepTrail). An equipped trail only restyles it (colours + profile:
	  Ribbon / Thin / Wide / Twin). One pooled record per marble: 1-2 Trails whose attachments
	  live in Terrain and follow the marble's position each frame (never its spin), so the
	  ribbon is stable on a rolling sphere. FaceCamera keeps it readable from the chase view.
	  History is cleared on teleport / respawn / grid snap (MotionFeel detects the jump), when
	  a marble is frozen or finishes, when its trail changes, and when the camera target
	  changes (ClearAll). The server's old per-ball Trail, if any, is switched off here.
	* Budget by graphics: High = rivals within 220 studs (12 at most), Auto/Standard = within
	  140 (6), Low = your own marble only with a short trail. "Trail visibility" setting:
	  All / Mine / Off. Nothing here is sent over the network.
	* Speed streaks: faint lines at the screen edges near top speed (never over the centre),
	  off on Low, with "Speed effects" off, or under Reduced Motion.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Catalog = require(Shared:WaitForChild("Catalog"))
local MotionFeel = require(Shared:WaitForChild("MotionFeel"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local SpeedFeel = {}
SpeedFeel.__index = SpeedFeel

SpeedFeel.Budgets = {
	High = { distance = 220, rivals = 12 },
	Standard = { distance = 140, rivals = 6 },
	Low = { distance = 0, rivals = 0 },
}
SpeedFeel.DefaultColors = { Color3.fromRGB(235, 245, 255), Color3.fromRGB(39, 215, 245) }

-- Pure: which marbles get a trail. entries = { {id, distance, isMine} }, budget, visibility.
-- Returns a set of ids (your own first, then the nearest rivals).
function SpeedFeel.Select(entries, budget, visibility)
	local chosen = {}
	if visibility == "Off" then
		return chosen
	end
	local rivals = {}
	for _, e in ipairs(entries) do
		if e.isMine then
			chosen[e.id] = true
		elseif visibility ~= "Mine" and e.distance <= budget.distance then
			rivals[#rivals + 1] = e
		end
	end
	table.sort(rivals, function(a, b)
		return a.distance < b.distance
	end)
	for i = 1, math.min(#rivals, budget.rivals) do
		chosen[rivals[i].id] = true
	end
	return chosen
end

-- Pure: a trail item's style (default = the free speed trail look)
function SpeedFeel.StyleFor(trailId)
	local item = trailId and Catalog.Get(trailId)
	if item and item.Kind == "Trail" and item.Colors then
		return { colors = item.Colors, profile = item.Profile or "Ribbon", id = item.Id }
	end
	return { colors = SpeedFeel.DefaultColors, profile = "Ribbon", id = "default" }
end

function SpeedFeel.new(deps)
	local self = setmetatable({}, SpeedFeel)
	self.folder = deps.marblesFolder
	self.myName = Protocol.MarbleName(Players.LocalPlayer.UserId)
	self.records = {} -- ball -> record
	self.pool = {}
	self.quality = "Standard"
	self.visibility = "All"
	self.reducedMotion = false
	self.speedEffects = true
	self.selectTimer = 0
	self.chosen = {}
	self:_buildStreaks()
	return self
end

function SpeedFeel:SetQuality(mode)
	self.quality = (mode == "Low" and "Low") or (mode == "High" and "High") or "Standard"
end

function SpeedFeel:SetVisibility(value)
	self.visibility = value or "All"
end

function SpeedFeel:SetReducedMotion(value)
	self.reducedMotion = value == true
end

function SpeedFeel:SetSpeedEffects(on)
	self.speedEffects = on ~= false
end

local function newTrail(parent)
	local a0 = Instance.new("Attachment")
	a0.Name = "TC_SpeedA"
	a0.Parent = parent
	local a1 = Instance.new("Attachment")
	a1.Name = "TC_SpeedB"
	a1.Parent = parent
	local trail = Instance.new("Trail")
	trail.Name = "TC_SpeedTrail"
	trail.Attachment0, trail.Attachment1 = a0, a1
	trail.FaceCamera = true
	trail.LightEmission = 0.55
	trail.LightInfluence = 0.3
	trail.MinLength = 0.15
	trail.Lifetime = 0.02
	trail.WidthScale = NumberSequence.new(1, 0.25)
	trail.Enabled = false
	trail.Parent = parent
	return { trail = trail, a0 = a0, a1 = a1 }
end

function SpeedFeel:_acquire()
	local rec = table.remove(self.pool)
	if rec then
		return rec
	end
	local terrain = workspace.Terrain
	return { ribbons = { newTrail(terrain), newTrail(terrain) }, state = MotionFeel.NewTrailState() }
end

local function clearRibbons(rec)
	for _, r in ipairs(rec.ribbons) do
		r.trail.Enabled = false
		r.trail:Clear()
	end
	rec.state = MotionFeel.NewTrailState()
	rec.opacity = nil
end

function SpeedFeel:_release(ball)
	local rec = self.records[ball]
	if rec then
		self.records[ball] = nil
		clearRibbons(rec)
		self.pool[#self.pool + 1] = rec
	end
end

function SpeedFeel:_style(rec, ball)
	local trailId = ball:GetAttribute("TC_Trail")
	if rec.styleId == (trailId or "") then
		return
	end
	rec.styleId = trailId or ""
	local style = SpeedFeel.StyleFor(trailId)
	rec.style = style
	local seq = ColorSequence.new(style.colors[1], style.colors[2])
	for _, r in ipairs(rec.ribbons) do
		r.trail.Color = seq
	end
	clearRibbons(rec) -- unequip / change: no ribbon from the old look
	-- the server's old fixed trail (pre-2026-11-26 builds) never shows next to this one
	local old = ball:FindFirstChild("TC_Trail")
	if old and old:IsA("Trail") then
		old.Enabled = false
	end
end

-- Wipe every trail (camera target changed, intro cut, results)
function SpeedFeel:ClearAll()
	for _, rec in pairs(self.records) do
		clearRibbons(rec)
	end
end

local function opacitySequence(opacity)
	local base = 1 - 0.75 * opacity
	return NumberSequence.new({ NumberSequenceKeypoint.new(0, base), NumberSequenceKeypoint.new(1, 1) })
end

-- Called every frame. ctx = { camera = Camera, braking = bool (your marble), finished = set of
-- marble names that have finished, myBall = BasePart? }
function SpeedFeel:Step(dt, ctx)
	local folder = self.folder
	if not folder then
		return
	end
	local camPos = ctx.camera and ctx.camera.CFrame.Position or Vector3.zero
	local budget = SpeedFeel.Budgets[self.quality]
	self.selectTimer = self.selectTimer - dt
	if self.selectTimer <= 0 then
		self.selectTimer = 0.5
		local entries = {}
		for _, ball in ipairs(folder:GetChildren()) do
			if ball:IsA("BasePart") then
				entries[#entries + 1] = { id = ball, distance = (ball.Position - camPos).Magnitude, isMine = ball.Name == self.myName }
			end
		end
		self.chosen = SpeedFeel.Select(entries, budget, self.visibility)
		for ball in pairs(self.records) do
			if not self.chosen[ball] or not ball.Parent then
				self:_release(ball)
			end
		end
	end
	local maxLength = self.quality == "Low" and MotionFeel.Trail.LowMaxLength or MotionFeel.Trail.MaxLength
	local widths = MotionFeel.Trail.Widths
	local fastest = 0
	for ball in pairs(self.chosen) do
		if ball.Parent then
			local rec = self.records[ball]
			if not rec then
				rec = self:_acquire()
				self.records[ball] = rec
				rec.styleId = nil
			end
			self:_style(rec, ball)
			local mine = ball.Name == self.myName
			local frozen = ball.Anchored or ball:GetAttribute(Protocol.BallAttributes.Frozen) == true
			local hidden = ball.LocalTransparencyModifier > 0.5 -- the race intro hides it
			local position = ball.Position
			local length, opacity, cleared
			if frozen or hidden or (ctx.finished and ctx.finished[ball.Name]) then
				rec.state = MotionFeel.NewTrailState()
				length, opacity, cleared = 0, 0, true
			else
				length, opacity, cleared = MotionFeel.StepTrail(rec.state, dt, position, mine and ctx.braking, maxLength)
			end
			if mine then
				fastest = rec.state.speed / MotionFeel.ReferenceSpeed
			end
			local style = rec.style
			local twin = style.profile == "Twin"
			local width = widths[style.profile] or widths.Ribbon
			local lifetime = MotionFeel.TrailLifetime(length, rec.state.speed)
			local seq = (rec.opacity == nil or math.abs(rec.opacity - opacity) > 0.04) and opacitySequence(opacity) or nil
			if seq then
				rec.opacity = opacity
			end
			local right = Vector3.new(0, 1, 0)
			local velocity = rec.state.last and ball.AssemblyLinearVelocity or Vector3.zero
			local flat = Vector3.new(velocity.X, 0, velocity.Z)
			if flat.Magnitude > 2 then
				right = flat.Unit:Cross(Vector3.new(0, 1, 0))
				rec.lastRight = right
			elseif rec.lastRight then
				right = rec.lastRight -- tiny velocities keep the last valid direction
			end
			local base = position - Vector3.new(0, 0.6, 0)
			for i, r in ipairs(rec.ribbons) do
				local used = i == 1 or twin
				if cleared then
					r.trail:Clear()
				end
				local on = used and length > 0.2
				if r.trail.Enabled ~= on then
					r.trail.Enabled = on
				end
				if used then
					local offset = twin and right * ((i == 1 and -1 or 1) * MotionFeel.Trail.TwinGap) or Vector3.zero
					local centre = base + offset
					r.a0.WorldPosition = centre + Vector3.new(0, width / 2, 0)
					r.a1.WorldPosition = centre - Vector3.new(0, width / 2, 0)
					r.trail.Lifetime = lifetime
					if seq then
						r.trail.Transparency = seq
					end
				end
			end
		end
	end
	self:_stepStreaks(dt, fastest)
	return fastest
end

---------------------------------------------------------------------------------------------
-- Speed streaks (screen edges only)
function SpeedFeel:_buildStreaks()
	local ok = pcall(function()
		local gui, root = UIKit.screen("TumbleSpeedStreaks", 2)
		gui.ScreenInsets = Enum.ScreenInsets.None -- edge to edge, under every other layer
		gui.Enabled = false
		self.streakGui = gui
		self.streaks = {}
		local rng = Random.new(7)
		for i = 1, 14 do
			local left = i % 2 == 0
			local y = rng:NextNumber(0.08, 0.92)
			local line = UIKit.new("Frame", {
				Name = "Streak",
				AnchorPoint = Vector2.new(left and 0 or 1, 0.5),
				Position = UDim2.fromScale(left and 0 or 1, y),
				Size = UDim2.new(rng:NextNumber(0.06, 0.13), 0, 0, 2),
				BackgroundColor3 = Color3.fromRGB(235, 245, 255),
				BackgroundTransparency = 1,
				BorderSizePixel = 0,
			}, root)
			self.streaks[i] = { frame = line, left = left, phase = rng:NextNumber(0, 1), y = y }
		end
	end)
	return ok
end

function SpeedFeel:_stepStreaks(dt, fraction)
	if not self.streaks then
		return
	end
	local allowed = self.speedEffects and not self.reducedMotion and self.quality ~= "Low"
	local alpha = allowed and MotionFeel.StreakAlpha(fraction) or 0
	self.streakGui.Enabled = alpha > 0.01
	if alpha <= 0.01 then
		return
	end
	for _, s in ipairs(self.streaks) do
		s.phase = (s.phase + dt * 2.2) % 1
		local p = s.phase
		local x = p * 0.1 -- slides outward along the edge
		s.frame.Position = UDim2.fromScale(s.left and (0.1 - x) or (0.9 + x), s.y)
		s.frame.BackgroundTransparency = 1 - alpha * math.sin(math.pi * p)
	end
end

function SpeedFeel:Destroy()
	for ball in pairs(self.records) do
		self:_release(ball)
	end
	for _, rec in ipairs(self.pool) do
		for _, r in ipairs(rec.ribbons) do
			r.trail:Destroy()
			r.a0:Destroy()
			r.a1:Destroy()
		end
	end
	self.pool = {}
	if self.streakGui then
		self.streakGui:Destroy()
	end
end

return SpeedFeel
