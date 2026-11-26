--[[
	RaceIntroController — the race-start launch ramp (owner brief 2026-11-26, replaces the v31
	drop-in). Client only, purely visual; timing comes from MotionFeel.Launch.

	When a round enters Preparing and you are on the grid, a map-themed ramp is built locally
	behind the start pad. Stand-ins of every marble on the grid (cloned from the real, anchored
	grid marbles, so they wear their owners' equipped looks) sit at the top in formation; a
	wide shot shows the field, they burst forward down the ramp, a low side camera catches the
	jump, and each one arcs onto its own real grid slot while the camera hands off to your
	chase view. Then the normal shared countdown runs.

	Authority: nothing here moves a real marble, opens control or touches timing. The server
	keeps the grid anchored until GO and owns the start time. The intro clock is the server's
	Preparing timestamp, so a slow or late client joins it mid-way or skips it; a stand-in has
	no collision, query or touch. Each real marble is hidden locally until its stand-in lands
	exactly on it, then shown again (a failsafe shows everything when Preparing ends).
	SKIP INTRO (button), the "Skip race intro" setting and Reduced Motion all go straight to the
	grid view. Launch Animations (equipped, TC_Launch) change only the arc height and landing
	flourish (Comet Arc streak, Spring Snap rebound, Afterimage echoes).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MotionFeel = require(Shared:WaitForChild("MotionFeel"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local RoundProtocol = require(Shared:WaitForChild("RoundProtocol"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local RaceIntro = {}
RaceIntro.__index = RaceIntro

local UP = Vector3.new(0, 1, 0)
local L = MotionFeel.Launch

-- deck / rail / accent per map (native materials only)
RaceIntro.Themes = {
	NeonFoundry = { deck = Color3.fromRGB(38, 44, 66), material = "DiamondPlate", rail = Color3.fromRGB(39, 215, 245), accent = Color3.fromRGB(255, 212, 90) },
	SkyCarnival = { deck = Color3.fromRGB(246, 236, 224), material = "SmoothPlastic", rail = Color3.fromRGB(255, 140, 120), accent = Color3.fromRGB(110, 190, 255) },
	VolcanoVault = { deck = Color3.fromRGB(52, 44, 42), material = "Basalt", rail = Color3.fromRGB(255, 120, 50), accent = Color3.fromRGB(255, 212, 90) },
}

function RaceIntro.ThemeFor(mapId)
	for key, theme in pairs(RaceIntro.Themes) do
		if string.find(mapId or "", key, 1, true) == 1 then
			return theme
		end
	end
	return RaceIntro.Themes.NeonFoundry
end

-- Pure: back-row centre and forward of a race layout's grid (slots are front row first)
function RaceIntro.GridFrame(gridSlots, radius)
	local n = #gridSlots
	if n == 0 then
		return nil
	end
	local last = gridSlots[n].Frame
	local sum, count = Vector3.new(0, 0, 0), 0
	for i = n, 1, -1 do
		local f = gridSlots[i].Frame
		if (f.Position - last.Position).Magnitude < 0.5 then
			sum = sum + f.Position + f.Up * (radius or 2)
			count = count + 1
		end
	end
	return sum / count, last.Forward
end

-- Pure: the grid row (1 = front) and lateral offset of the slot nearest `position`
function RaceIntro.SlotInfo(gridSlots, position)
	local best, bestD = nil, math.huge
	for i, slot in ipairs(gridSlots) do
		local p = slot.Frame.Position + slot.Frame.Right * slot.Offset
		local d = (Vector3.new(p.X, 0, p.Z) - Vector3.new(position.X, 0, position.Z)).Magnitude
		if d < bestD then
			best, bestD = i, d
		end
	end
	if not best then
		return 1, 0
	end
	local row, previous = 0, nil
	for i = 1, best do
		local f = gridSlots[i].Frame
		if not previous or (f.Position - previous.Position).Magnitude >= 0.5 then
			row = row + 1
			previous = f
		end
	end
	return row, gridSlots[best].Offset
end

-- Pure: scale a roll so the stand-in ends in exactly the real marble's orientation
function RaceIntro.RollScale(totalRoll)
	if totalRoll <= 0 then
		return 1
	end
	local turns = math.max(1, math.floor(totalRoll / (2 * math.pi) + 0.5))
	return turns * 2 * math.pi / totalRoll
end

function RaceIntro.new(deps)
	local self = setmetatable({}, RaceIntro)
	self.folder = deps.marblesFolder
	self.camera = deps.cameraController
	self.getLayout = deps.getLayout -- function() -> race layout (GridSlots)
	self.getMapId = deps.getMapId -- function() -> active world id
	self.speedFeel = deps.speedFeel
	self.myUserId = Players.LocalPlayer.UserId
	self.reducedMotion = false
	self.skipSetting = false
	self.roundId = nil
	self.active = nil
	self:_buildSkip()
	return self
end

function RaceIntro:SetReducedMotion(value)
	self.reducedMotion = value == true
	if self.reducedMotion then
		self:Finish()
	end
end

function RaceIntro:SetSkip(value)
	self.skipSetting = value == true
end

function RaceIntro:IsPlaying()
	return self.active ~= nil
end

function RaceIntro:_buildSkip()
	pcall(function()
		local gui, root, maid = UIKit.screen("TumbleIntroSkip", 30)
		gui.Enabled = false
		self.skipGui, self.skipMaid = gui, maid
		local b = UIKit.button(root, { Name = "SkipIntro", AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -24, 1, -24), Size = UDim2.fromOffset(190, 52), Text = "SKIP INTRO" }, UIKit.Palette.White)
		maid:Give(b.Activated:Connect(function()
			self:Finish()
		end))
	end)
end

local function isGridBall(ball)
	return ball:IsA("BasePart") and ball:GetAttribute(Protocol.BallAttributes.Zone) == Protocol.Zones.Race and ball:GetAttribute(Protocol.BallAttributes.Frozen) == true
end

function RaceIntro:OnSnapshot(snap)
	local S = RoundProtocol.States
	if snap.state == S.Preparing and snap.roundId ~= self.roundId then
		self.roundId = snap.roundId
		self:Finish()
		local racing = false
		for _, entry in ipairs(snap.racers or {}) do
			if entry.userId == self.myUserId then
				racing = true
			end
		end
		if not racing or self.reducedMotion or self.skipSetting or type(snap.stateStartedAt) ~= "number" then
			return -- the fast variant: you simply see the grid in your chase view
		end
		self:_start(snap.stateStartedAt + L.StartDelay)
	elseif snap.state ~= S.Preparing and snap.state ~= S.Countdown then
		self:Finish()
	end
end

local function newPart(parent, props)
	local p = Instance.new("Part")
	p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch, p.CastShadow = true, false, false, false, false
	p.TopSurface, p.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
	for key, value in pairs(props) do
		p[key] = value
	end
	p.Parent = parent
	return p
end

function RaceIntro:_buildRamp(geo, theme)
	local folder = Instance.new("Folder")
	folder.Name = "TC_LaunchRamp"
	local width = 30
	local deckStart = geo.top - geo.slope * (3 * L.RowSpacing + 6)
	local deckEnd = geo.lip + geo.slope * 1.5
	local length = (deckEnd - deckStart).Magnitude
	local centre = (deckStart + deckEnd) / 2 - geo.deckUp * 0.5
	local frame = CFrame.lookAt(centre, centre + geo.slope, geo.deckUp)
	local okMat, material = pcall(function()
		return Enum.Material[theme.material]
	end)
	newPart(folder, { Name = "Deck", Size = Vector3.new(width, 1, length), CFrame = frame, Color = theme.deck, Material = okMat and material or Enum.Material.SmoothPlastic })
	for _, side in ipairs({ -1, 1 }) do
		newPart(folder, { Name = "Rail", Size = Vector3.new(0.8, 1.6, length), CFrame = frame * CFrame.new(side * (width / 2 + 0.4), 1.1, 0), Color = theme.rail, Material = Enum.Material.Neon })
		for _, along in ipairs({ -0.3, 0.25 }) do
			local top = (frame * CFrame.new(side * (width / 2 - 2), -0.5, along * length)).Position
			newPart(folder, { Name = "Support", Size = Vector3.new(1.6, 36, 1.6), CFrame = CFrame.new(top - UP * 18), Color = theme.deck:Lerp(Color3.new(0, 0, 0), 0.35), Material = Enum.Material.Metal })
		end
	end
	-- lip strip + chevrons in the accent colour (the deck's -Z end faces the grid)
	newPart(folder, { Name = "Lip", Size = Vector3.new(width, 0.4, 1.2), CFrame = frame * CFrame.new(0, 0.55, -length / 2 + 1), Color = theme.accent, Material = Enum.Material.Neon })
	for i = 1, 3 do
		newPart(folder, { Name = "Chevron", Size = Vector3.new(width * 0.6, 0.12, 0.6), CFrame = frame * CFrame.new(0, 0.52, -length / 2 + 6 + i * 5), Color = theme.accent, Material = Enum.Material.Neon, Transparency = 0.2 })
	end
	-- start arch at the top
	local archBase = (frame * CFrame.new(0, 0, length / 2 - 2)).Position
	for _, side in ipairs({ -1, 1 }) do
		local p = archBase + geo.right * side * (width / 2) + geo.deckUp * 4.5
		newPart(folder, { Name = "Arch", Size = Vector3.new(1, 9, 1), CFrame = CFrame.lookAt(p, p + geo.slope, geo.deckUp), Color = theme.rail, Material = Enum.Material.Neon })
	end
	local beam = archBase + geo.deckUp * 9
	newPart(folder, { Name = "Arch", Size = Vector3.new(width + 1, 1, 1), CFrame = CFrame.lookAt(beam, beam + geo.slope, geo.deckUp), Color = theme.rail, Material = Enum.Material.Neon })
	folder.Parent = workspace.CurrentCamera
	return folder
end

function RaceIntro:_start(t0)
	local layout = self.getLayout and self.getLayout()
	if not layout or not layout.GridSlots or #layout.GridSlots == 0 then
		return
	end
	local backCenter, forward = RaceIntro.GridFrame(layout.GridSlots, L.Radius)
	if not backCenter then
		return
	end
	local geo = MotionFeel.RampGeometry(backCenter, forward)
	local ok, ramp = pcall(function()
		return self:_buildRamp(geo, RaceIntro.ThemeFor(self.getMapId and self.getMapId()))
	end)
	self.active = { t0 = t0, geo = geo, layout = layout, ramp = ok and ramp or nil, stands = {}, burst = false, maxEnd = MotionFeel.LaunchEnd(4) }
	if self.skipGui then
		self.skipGui.Enabled = true
	end
	if self.camera and self.camera.SetScripted then
		self.camera:SetScripted(function(chase)
			return self:_cameraPose(chase)
		end)
	end
end

function RaceIntro:_now()
	local a = self.active
	return a and (workspace:GetServerTimeNow() - a.t0) or 0
end

-- Hide the real marble for this client and build its stand-in.
function RaceIntro:_stage(ball)
	local a = self.active
	local parts = { ball }
	for _, d in ipairs(ball:GetDescendants()) do
		if d:IsA("BasePart") then
			parts[#parts + 1] = d
		end
	end
	local okClone, copy = pcall(function()
		return ball:Clone()
	end)
	if not okClone or not copy then
		a.stands[ball] = { done = true } -- no stand-in: the real marble just stays visible
		return
	end
	local row, lateral = RaceIntro.SlotInfo(a.layout.GridSlots, ball.Position)
	local path = MotionFeel.LaunchPath(a.geo, ball.Position, row, lateral)
	local styleId = ball:GetAttribute("TC_Launch")
	local rampLen = (path.lip - path.start).Magnitude
	local arcLen = (path.slot - path.lip).Magnitude
	local stand = {
		ball = ball,
		parts = parts,
		path = path,
		style = styleId,
		axis = a.geo.right,
		rot = ball.CFrame - ball.CFrame.Position,
		rollScale = RaceIntro.RollScale((rampLen + arcLen) / L.Radius),
		effects = {},
		echoes = {},
	}
	for name in pairs(copy:GetAttributes()) do
		copy:SetAttribute(name, nil)
	end
	copy.Name = "TC_StandIn"
	for _, d in ipairs(copy:GetDescendants()) do
		if d:IsA("Highlight") or d:IsA("BillboardGui") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.CanCollide, d.CanQuery, d.CanTouch = false, false, false
			d.LocalTransparencyModifier = 0
		end
	end
	copy.Anchored, copy.CanCollide, copy.CanQuery, copy.CanTouch = true, false, false, false
	copy.LocalTransparencyModifier = 0
	local style = MotionFeel.LaunchStyle(styleId)
	for i, lag in ipairs(style.echoes or {}) do
		local okEcho, echo = pcall(function()
			return copy:Clone()
		end)
		if okEcho and echo then
			echo.Name = "TC_StandInEcho"
			local fade = i == 1 and 0.55 or 0.75
			for _, d in ipairs(echo:GetDescendants()) do
				if d:IsA("BasePart") then
					d.Transparency = math.max(d.Transparency, fade)
				end
			end
			echo.Transparency = fade
			stand.echoes[#stand.echoes + 1] = { part = echo, lag = lag }
		end
	end
	if style.streak then
		pcall(function()
			local a0 = Instance.new("Attachment")
			local a1 = Instance.new("Attachment")
			a0.Parent, a1.Parent = workspace.Terrain, workspace.Terrain
			local trail = Instance.new("Trail")
			trail.Attachment0, trail.Attachment1 = a0, a1
			trail.FaceCamera = true
			trail.Lifetime = 0.35
			trail.LightEmission = 1
			trail.Color = ColorSequence.new(Color3.fromRGB(255, 230, 160), Color3.fromRGB(255, 90, 30))
			trail.Transparency = NumberSequence.new(0.1, 1)
			trail.WidthScale = NumberSequence.new(1, 0.1)
			trail.Enabled = false
			trail.Parent = workspace.Terrain
			stand.streak = { trail = trail, a0 = a0, a1 = a1 }
		end)
	end
	-- hide the real marble (and its glows) until the stand-in lands on it
	for _, part in ipairs(parts) do
		part.LocalTransparencyModifier = 1
	end
	for _, d in ipairs(ball:GetDescendants()) do
		if (d:IsA("ParticleEmitter") or d:IsA("Light") or d:IsA("Highlight")) and d.Enabled then
			d.Enabled = false
			stand.effects[#stand.effects + 1] = d
		end
	end
	stand.copy = copy
	copy.Parent = workspace.CurrentCamera
	for _, e in ipairs(stand.echoes) do
		e.part.Parent = workspace.CurrentCamera
	end
	a.stands[ball] = stand
end

local function poseCFrame(stand, t)
	local p, roll = MotionFeel.LaunchPose(stand.path, t, stand.style)
	return CFrame.new(p) * CFrame.fromAxisAngle(-stand.axis, roll * stand.rollScale) * stand.rot
end

function RaceIntro:_unstage(stand)
	if stand.done then
		return
	end
	stand.done = true
	if stand.copy then
		stand.copy:Destroy()
	end
	for _, e in ipairs(stand.echoes) do
		e.part:Destroy()
	end
	if stand.streak then
		stand.streak.trail:Destroy()
		stand.streak.a0:Destroy()
		stand.streak.a1:Destroy()
	end
	for _, part in ipairs(stand.parts) do
		if part.Parent then
			part.LocalTransparencyModifier = 0
		end
	end
	for _, effect in ipairs(stand.effects) do
		if effect.Parent then
			effect.Enabled = true
		end
	end
end

local function fx(props, seconds, goal)
	pcall(function()
		local p = newPart(workspace.CurrentCamera, props)
		local t = game:GetService("TweenService"):Create(p, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal)
		t.Completed:Connect(function()
			p:Destroy()
		end)
		t:Play()
	end)
end

local function puff(position)
	fx({ Name = "TC_IntroFx", Shape = Enum.PartType.Ball, Material = Enum.Material.Neon, Color = Color3.fromRGB(255, 240, 200), Transparency = 0.3, Size = Vector3.new(1, 1, 1), CFrame = CFrame.new(position) }, 0.3, { Size = Vector3.new(4.5, 4.5, 4.5), Transparency = 1 })
end

local function ring(position, color)
	fx({ Name = "TC_IntroFx", Shape = Enum.PartType.Cylinder, Material = Enum.Material.Neon, Color = color, Transparency = 0.25, Size = Vector3.new(0.2, 3, 3), CFrame = CFrame.new(position - Vector3.new(0, 1.85, 0)) * CFrame.Angles(0, 0, math.rad(90)) }, 0.4, { Size = Vector3.new(0.2, 11, 11), Transparency = 1 })
end

-- Every frame (from the bootstrap's render step).
function RaceIntro:Step()
	local a = self.active
	if not a then
		return
	end
	local t = self:_now()
	if t > a.maxEnd + 0.25 then
		self:Finish()
		return
	end
	if t < 0 then
		return
	end
	if t < L.Lip then -- stage grid marbles as they replicate, while there is a launch to see
		for _, ball in ipairs(self.folder:GetChildren()) do
			if not a.stands[ball] and isGridBall(ball) then
				self:_stage(ball)
			end
		end
	end
	local sum, n = Vector3.new(0, 0, 0), 0
	for _, stand in pairs(a.stands) do
		if not stand.done then
			local tt = t - stand.path.delay
			if tt >= L.End or not stand.ball.Parent then
				self:_unstage(stand) -- landed exactly on the real marble: swap
			else
				local cf = poseCFrame(stand, t)
				stand.copy.CFrame = cf
				sum, n = sum + cf.Position, n + 1
				for _, e in ipairs(stand.echoes) do
					e.part.CFrame = poseCFrame(stand, math.max(0, t - e.lag))
				end
				if stand.streak then
					local p = cf.Position
					stand.streak.a0.WorldPosition = p + UP * 0.35
					stand.streak.a1.WorldPosition = p - UP * 0.35
					stand.streak.trail.Enabled = tt > L.Wide and tt < L.Land
				end
				if not stand.landed and tt >= L.Land then
					stand.landed = true
					local style = MotionFeel.LaunchStyle(stand.style)
					if style.flourish ~= "Stick" then
						ring(stand.path.slot, stand.copy.Color)
					end
					if style.flourish == "Spring" then
						ring(stand.path.slot + UP * 0.4, Color3.fromRGB(255, 255, 255))
					end
				end
			end
		end
	end
	if not a.burst and t >= L.Wide then
		a.burst = true -- every marble propels itself forward with a brief burst
		for _, stand in pairs(a.stands) do
			if not stand.done and stand.path then
				puff(stand.path.start - a.geo.slope * 2.2)
			end
		end
	end
	a.packCenter = n > 0 and sum / n or a.packCenter
end

function RaceIntro:_cameraPose(chase)
	local a = self.active
	if not a then
		return nil
	end
	local t = self:_now()
	local shot = MotionFeel.LaunchCamera(a.geo, math.max(0, t), a.packCenter)
	if shot then
		a.lastShot = shot
		return shot
	end
	local handoff = L.End + 0.1 - L.Land
	local x = math.clamp((t - L.Land) / handoff, 0, 1)
	if x >= 1 or not a.lastShot then
		return nil -- the chase camera from here on
	end
	return a.lastShot:Lerp(chase, x * x * x * (x * (x * 6 - 15) + 10))
end

-- End the intro now (skip, setting, state change, failsafe): everything back to the grid.
function RaceIntro:Finish()
	local a = self.active
	if not a then
		return
	end
	self.active = nil
	for _, stand in pairs(a.stands) do
		self:_unstage(stand)
	end
	if a.ramp then
		a.ramp:Destroy()
	end
	if self.camera and self.camera.SetScripted then
		self.camera:SetScripted(nil)
	end
	if self.skipGui then
		self.skipGui.Enabled = false
	end
	if self.speedFeel then
		self.speedFeel:ClearAll() -- grid snap: no ribbon from the intro
	end
end

function RaceIntro:Destroy()
	self:Finish()
	if self.skipMaid then
		self.skipMaid:Cleanup()
	end
end

return RaceIntro
