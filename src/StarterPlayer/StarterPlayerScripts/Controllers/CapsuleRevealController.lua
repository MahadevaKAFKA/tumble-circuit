--[[
	CapsuleRevealController — the "racing spool" case reveal (owner brief 2026-11-26, section 3).
	Original to Tumble Circuit: masked marbles queue on a curved launch track, race, and the
	(already chosen) winner crosses the reveal line first; only the winner is unmasked.

	  0.00-0.35  the spool queued on the curved launch track, wide establishing shot
	  0.35-1.15  release: wide follow, then a low chase angle (positions are continuous across
	             cuts, nothing jumps)
	  1.15-2.05  stable rail-side framing at the reveal line; the pack eases down and the winner
	             crosses first (one sound cue: "Reveal")
	  2.05-2.50  the winner is unmasked: real look, rarity, category; EQUIP / DONE; a duplicate
	             shows its real Shard conversion

	Honesty (brief + MONETIZATION_COMPLIANCE.md): the server has already chosen and saved the
	result before anything plays. Entrants are drawn from the capsule's shown odds, every
	entrant is a neutral silhouette from its real outline family (same shape = same mask at any
	rarity, colours / materials / names hidden), so no tile can suggest a near-miss. Timing,
	cuts, SKIP, MUTE or the display RNG never touch the reward. Reduced motion shows the result
	at once; Low graphics uses a single-camera ribbon with the same outcome and masks.
	Shown full screen (the hub chrome is covered), then focus returns to the Lab.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Catalog = require(Shared:WaitForChild("Catalog"))
local MarbleLook = require(Shared:WaitForChild("MarbleLook"))
local Utility = require(Shared:WaitForChild("Utility"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local palette = UIKit.Palette

local Reveal = {}
Reveal.__index = Reveal

Reveal.Times = { Queue = 0.35, Chase = 0.75, Rail = 1.15, Cross = 2.0, Unmask = 2.05, Done = 2.5 }
-- 2026-11-26 owner: "there's no animation when actually opening chests" - the case itself now
-- opens first: it pops in, shakes harder and harder, the lid blows off with a flash, then the
-- spool runs. Reduced Motion: a short fade-open without the shake.
Reveal.OpenTimes = { Pop = 0.22, Shake = 0.95, Burst = 1.25 }
Reveal.ReducedOpen = 0.45

-- Pure: the case's pose at time t of the opening (scale, rotation degrees, lid lift studs-ish
-- px, lid rotation, flash alpha 0..1, burst 0..1). Deterministic so tests can sample it.
function Reveal.ChestPose(t, reduced)
	local O = Reveal.OpenTimes
	if reduced then
		local u = math.clamp(t / Reveal.ReducedOpen, 0, 1)
		return { scale = 1, rotation = 0, lid = u * 40, lidRotation = u * -20, flash = u < 0.5 and u * 2 or (1 - u) * 2, burst = u }
	end
	if t < O.Pop then
		local u = t / O.Pop
		local back = 1 + 1.70158
		local e = 1 + back * (u - 1) ^ 3 + 1.70158 * (u - 1) ^ 2 -- back-out pop
		return { scale = e, rotation = 0, lid = 0, lidRotation = 0, flash = 0, burst = 0 }
	elseif t < O.Shake then
		local u = (t - O.Pop) / (O.Shake - O.Pop)
		local amp = 2 + u * u * 9 -- degrees, building up
		return { scale = 1 + u * 0.06, rotation = math.sin(t * (28 + u * 30)) * amp, lid = u * 3, lidRotation = 0, flash = u * 0.25, burst = 0 }
	end
	local u = math.clamp((t - O.Shake) / (O.Burst - O.Shake), 0, 1)
	return { scale = 1.06 - u * 0.12, rotation = 0, lid = 18 + u * 160, lidRotation = -25 - u * 70, flash = 1 - u, burst = u }
end
Reveal.Entrants = 6
Reveal.Radius = 40 -- track arc radius (studs)
Reveal.Sweep = 1.3 -- radians of arc per unit of progress (s = 0 start, s = 1 reveal line)
Reveal.Lanes = { -4.5, -1.5, 1.5, 4.5 }
Reveal.Neutral = Color3.fromRGB(150, 156, 170)
Reveal.NeutralShell = Color3.fromRGB(104, 110, 126)

---------------------------------------------------------------------------------------------
-- Pure parts

-- The mask family of an item: the same family always renders the same silhouette.
function Reveal.Mask(item)
	if not item then
		return "Unknown"
	end
	if item.Kind == "Marble" then
		return "Marble:" .. ((item.Look and item.Look.pattern) or "None")
	elseif item.Kind == "Trail" then
		return "Trail:" .. (item.Profile or "Ribbon")
	end
	return item.Kind
end

local function smooth(x)
	x = math.clamp(x, 0, 1)
	return x * x * (3 - 2 * x)
end

-- Progress s of entrant i at time t. order = { [i] = queue position 0.. }, rank = { [i] = finish
-- rank 0.. (0 = the winner) }. The winner is exactly on the line (s = 1) at Times.Cross and is
-- ahead of every other entrant there; before release everyone waits in the queue.
function Reveal.Progress(t, queuePos, rank)
	local T = Reveal.Times
	local queueS = -0.07 * queuePos
	if t <= T.Queue then
		return queueS
	end
	local u = math.clamp((t - T.Queue) / (T.Cross - T.Queue), 0, 1.2)
	local base
	if u <= 1 then
		base = 1 - (1 - u) ^ 2.2 -- fast out of the gate, easing down to the line
	else
		base = 1 + (u - 1) * 0.12 -- rolls a little past the line, then holds
	end
	local w = smooth(u)
	local gap = rank == 0 and 0 or (0.04 + rank * 0.08) -- >= one marble apart in a shared lane
	return base + (1 - w) * queueS - w * gap
end

-- Track centre point and tangent at progress s (the queue part, s < 0, climbs up the launch track)
function Reveal.TrackPoint(s)
	local theta = math.pi * 0.9 - s * Reveal.Sweep
	local p = Vector3.new(Reveal.Radius * math.cos(theta), 0, Reveal.Radius * math.sin(theta))
	if s < 0 then
		p = p + Vector3.new(0, -s * 14, 0)
	end
	local tangent = Vector3.new(math.sin(theta), 0, -math.cos(theta))
	local outward = Vector3.new(math.cos(theta), 0, math.sin(theta))
	return p, tangent, outward
end

-- The entrants: the winner plus fillers drawn from the shown odds (pick() -> item id). Returns
-- { ids, winnerIndex, queuePos, rank }. rng() in [0,1) is display-only.
function Reveal.Lineup(winnerId, pick, rng, n)
	n = n or Reveal.Entrants
	local ids = {}
	local winnerIndex = math.min(n, math.floor(rng() * n) + 1)
	for i = 1, n do
		ids[i] = i == winnerIndex and winnerId or pick()
	end
	local queuePos, rank = {}, {}
	local others = {}
	for i = 1, n do
		queuePos[i] = i - 1
		if i ~= winnerIndex then
			others[#others + 1] = i
		end
	end
	for k = #others, 2, -1 do -- shuffle the finishing order of the others (display only)
		local j = math.floor(rng() * k) + 1
		others[k], others[j] = others[j], others[k]
	end
	rank[winnerIndex] = 0
	for r, i in ipairs(others) do
		rank[i] = r
	end
	return { ids = ids, winnerIndex = winnerIndex, queuePos = queuePos, rank = rank }
end

-- Camera for the shots (pure). pack = centre of the entrants.
function Reveal.CameraAt(t, pack)
	local T = Reveal.Times
	local UP = Vector3.new(0, 1, 0)
	if t < T.Queue then
		local q = Reveal.TrackPoint(-0.18)
		return CFrame.lookAt(q + Vector3.new(0, 26, 0) + (q.Unit * 30), q, UP)
	elseif t < T.Chase then
		return CFrame.lookAt(Vector3.new(0, 34, 0) + (pack * 0.35), pack, UP)
	elseif t < T.Rail then
		local _, tangent = Reveal.TrackPoint(0.5)
		local behind = pack - tangent * 14 + UP * 3.5
		return CFrame.lookAt(behind, pack + tangent * 6, UP)
	end
	local line, _, outward = Reveal.TrackPoint(1)
	local eye = line + outward * 22 + UP * 6 - (Reveal.TrackPoint(0.85) - line) * 0.2
	local look = t < T.Unmask and Reveal.TrackPoint(0.94) or line
	return CFrame.lookAt(eye, look, UP)
end

---------------------------------------------------------------------------------------------
-- Rendering

function Reveal.new(deps)
	local self = setmetatable({}, Reveal)
	self.sound = deps.sound
	self.remotes = deps.remotes
	self.Finished = Utility.Signal.new() -- ("Equip" | "Done", result)
	self.muted = false
	self.low = false
	self.reducedMotion = false
	local gui, root, maid = UIKit.screen("TumbleCaseReveal", 40)
	gui.Enabled = false
	self.gui, self.root, self.maid = gui, root, maid
	local backdrop = UIKit.new("Frame", { Name = "Backdrop", Size = UDim2.fromScale(1, 1), BackgroundColor3 = palette.Ink, BackgroundTransparency = 0.02, Active = true }, root)
	self.backdrop = backdrop
	self.title = UIKit.label(backdrop, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 18), Size = UDim2.fromOffset(700, 34), Font = Enum.Font.GothamBlack, Text = "" })
	local viewport = UIKit.new("ViewportFrame", { Name = "Spool", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 60), Size = UDim2.fromOffset(900, 380), BackgroundColor3 = Color3.fromRGB(14, 20, 38), BackgroundTransparency = 0, Ambient = Color3.fromRGB(150, 155, 175), LightColor = Color3.new(1, 1, 1), LightDirection = Vector3.new(-0.4, -1, -0.3) }, backdrop)
	UIKit.corner(viewport, 0.04)
	self.viewport = viewport
	local camera = Instance.new("Camera")
	camera.FieldOfView = 50
	camera.Parent = viewport
	viewport.CurrentCamera = camera
	self.camera = camera
	self.ribbon = UIKit.new("Frame", { Name = "Ribbon", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 160), Size = UDim2.fromOffset(860, 150), BackgroundColor3 = palette.Navy, ClipsDescendants = true, Visible = false }, backdrop)
	UIKit.corner(self.ribbon, 0.06)
	self.ribbonStrip = UIKit.new("Frame", { Name = "Strip", Size = UDim2.new(0, 40 * 124, 1, 0), BackgroundTransparency = 1 }, self.ribbon)
	UIKit.new("Frame", { Name = "Line", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.fromScale(0.5, 0), Size = UDim2.new(0, 4, 1, 0), BackgroundColor3 = palette.White, BorderSizePixel = 0, ZIndex = 5 }, self.ribbon)
	self.legend = UIKit.label(backdrop, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 444), Size = UDim2.fromOffset(900, 20), Font = Enum.Font.Gotham, TextTransparency = 0.2, Text = "" })
	-- result card
	local card = UIKit.panel(backdrop, { Name = "Result", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 470), Size = UDim2.fromOffset(900, 150), BackgroundColor3 = palette.NavyFloor, Visible = false })
	self.card = card
	self.rarity = UIKit.label(card, { Position = UDim2.fromOffset(20, 10), Size = UDim2.fromOffset(520, 30), Font = Enum.Font.GothamBlack, TextXAlignment = Enum.TextXAlignment.Left, Text = "" })
	self.itemName = UIKit.label(card, { Position = UDim2.fromOffset(20, 42), Size = UDim2.fromOffset(520, 44), Font = Enum.Font.GothamBlack, TextXAlignment = Enum.TextXAlignment.Left, Text = "" })
	self.outcome = UIKit.label(card, { Position = UDim2.fromOffset(20, 92), Size = UDim2.fromOffset(520, 44), Font = Enum.Font.Gotham, TextWrapped = true, TextXAlignment = Enum.TextXAlignment.Left, Text = "" })
	self.equipButton = UIKit.Primary(UIKit.button(card, { Name = "RevealEquip", Position = UDim2.fromOffset(560, 24), Size = UDim2.fromOffset(150, 56), Text = "EQUIP" }, palette.Mint))
	self.doneButton = UIKit.button(card, { Name = "RevealDone", Position = UDim2.fromOffset(726, 24), Size = UDim2.fromOffset(150, 56), Text = "DONE" }, palette.White)
	maid:Give(self.equipButton.Activated:Connect(function()
		self:_close("Equip")
	end))
	maid:Give(self.doneButton.Activated:Connect(function()
		self:_close("Done")
	end))
	-- controls during the cinematic
	self.skipButton = UIKit.button(backdrop, { Name = "SkipReveal", AnchorPoint = Vector2.new(1, 1), Position = UDim2.new(1, -24, 1, -24), Size = UDim2.fromOffset(160, 50), Text = "SKIP" }, palette.White)
	maid:Give(self.skipButton.Activated:Connect(function()
		self:Skip()
	end))
	self.muteButton = UIKit.button(backdrop, { Name = "RevealMute", AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 24, 1, -24), Size = UDim2.fromOffset(140, 50), Text = "SOUND ON" }, palette.White)
	maid:Give(self.muteButton.Activated:Connect(function()
		self.muted = not self.muted
		self.muteButton.Text = self.muted and "MUTED" or "SOUND ON"
	end))
	self.syncLabel = UIKit.label(backdrop, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 470), Size = UDim2.fromOffset(900, 60), Font = Enum.Font.GothamBold, TextWrapped = true, Text = "", Visible = false })
	-- the case itself (opening stage)
	local chest = UIKit.new("Frame", { Name = "Chest", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.new(0.5, 0, 0, 250), Size = UDim2.fromOffset(260, 260), BackgroundTransparency = 1, Visible = false, ZIndex = 5 }, backdrop)
	self.chest = chest
	self.chestScale = UIKit.new("UIScale", { Scale = 1 }, chest)
	self.chestGlow = UIKit.new("Frame", { Name = "Glow", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.52), Size = UDim2.fromOffset(240, 240), BackgroundColor3 = palette.White, BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 4 }, chest)
	UIKit.corner(self.chestGlow, 0.5)
	self.chestRays = {}
	for k = 1, 10 do
		local ray = UIKit.new("Frame", { Name = "Ray", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(6, 120), Rotation = k * 36, BackgroundColor3 = palette.White, BackgroundTransparency = 1, BorderSizePixel = 0, ZIndex = 4 }, chest)
		self.chestRays[k] = ray
	end
	self.chestBody = UIKit.new("Frame", { Name = "Body", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -40), Size = UDim2.fromOffset(170, 112), BackgroundColor3 = palette.Cyan, BorderSizePixel = 0, ZIndex = 6 }, chest)
	UIKit.corner(self.chestBody, 0.08)
	UIKit.new("Frame", { Name = "Band", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.fromScale(0, 0.38), Size = UDim2.new(1, 0, 0, 14), BackgroundColor3 = palette.Ink, BorderSizePixel = 0, ZIndex = 7 }, self.chestBody)
	UIKit.new("Frame", { Name = "Latch", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.38), Size = UDim2.fromOffset(28, 30), BackgroundColor3 = palette.White, BorderSizePixel = 0, ZIndex = 8 }, self.chestBody)
	self.chestLid = UIKit.new("Frame", { Name = "Lid", AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -150), Size = UDim2.fromOffset(186, 38), BackgroundColor3 = palette.Cyan, BorderSizePixel = 0, ZIndex = 9 }, chest)
	UIKit.corner(self.chestLid, 0.08)
	UIKit.new("Frame", { Name = "LidEdge", AnchorPoint = Vector2.new(0, 1), Position = UDim2.fromScale(0, 1), Size = UDim2.new(1, 0, 0, 6), BackgroundColor3 = palette.Ink, BorderSizePixel = 0, ZIndex = 10 }, self.chestLid)
	maid:Give(game:GetService("RunService").RenderStepped:Connect(function()
		if self.playing then
			self:_step()
		end
	end))
	return self
end

function Reveal:SetQuality(low)
	self.low = low == true
end

function Reveal:SetReducedMotion(value)
	self.reducedMotion = value == true
end

function Reveal:IsOpen()
	return self.gui.Enabled
end

local function neutralPart(model, props)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.Material = Enum.Material.SmoothPlastic
	p.Color = Reveal.Neutral
	p.TopSurface, p.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
	for k, v in pairs(props) do
		p[k] = v
	end
	p.Parent = model
	return p
end

-- A neutral silhouette for an item (its outline family only). Returns model, root, extras.
function Reveal:_silhouette(item)
	local model = Instance.new("Model")
	local root = neutralPart(model, { Shape = Enum.PartType.Ball, Size = Vector3.new(4, 4, 4) })
	model.PrimaryPart = root
	local offsets = {}
	if item and item.Kind == "Marble" and item.Look then
		for _, spec in ipairs(MarbleLook.Specs(item.Look, 4)) do
			local shell = neutralPart(model, { Shape = spec.shape == "Ball" and Enum.PartType.Ball or Enum.PartType.Cylinder, Size = spec.size, Color = Reveal.NeutralShell })
			offsets[#offsets + 1] = { part = shell, offset = spec.offset }
		end
	elseif item and item.Kind == "Burst" then
		for k = 0, 5 do
			local a = k * math.pi / 3
			local spike = neutralPart(model, { Size = Vector3.new(0.5, 0.5, 2), Color = Reveal.NeutralShell })
			offsets[#offsets + 1] = { part = spike, offset = CFrame.Angles(0, a, 0) * CFrame.new(0, 2.6, 0) * CFrame.Angles(math.rad(70), 0, 0) }
		end
	elseif item and item.Kind == "Emote" then
		local bubble = neutralPart(model, { Size = Vector3.new(3.4, 2.2, 0.6), Color = Reveal.NeutralShell })
		offsets[#offsets + 1] = { part = bubble, offset = CFrame.new(0, 3.6, 0), upright = true }
	end
	local trace = nil
	if item and item.Kind == "Trail" then
		trace = { profile = item.Profile or "Ribbon", parts = {} }
		local twin = trace.profile == "Twin"
		local width = ({ Ribbon = 1.2, Thin = 0.5, Wide = 2.1, Twin = 0.6 })[trace.profile] or 1.2
		for k = 1, (twin and 10 or 5) do
			trace.parts[k] = neutralPart(model, { Size = Vector3.new(width * (1 - ((k - 1) % 5) * 0.15), 0.3, 2.2), Color = Reveal.NeutralShell, Transparency = ((k - 1) % 5) * 0.12 })
		end
	end
	return model, root, offsets, trace
end

function Reveal:_clear()
	for _, child in ipairs(self.viewport:GetChildren()) do
		if not child:IsA("Camera") then
			child:Destroy()
		end
	end
	for _, child in ipairs(self.ribbonStrip:GetChildren()) do
		child:Destroy()
	end
end

function Reveal:_buildTrack()
	local track = Instance.new("Model")
	track.Name = "Track"
	for k = -10, 30 do
		local s = k / 25
		local p, tangent = Reveal.TrackPoint(s)
		local cf = CFrame.lookAt(p - Vector3.new(0, 2.4, 0), p - Vector3.new(0, 2.4, 0) + tangent)
		neutralPart(track, { Size = Vector3.new(13, 0.6, 3.4), CFrame = cf, Color = Color3.fromRGB(34, 42, 66) })
		for _, side in ipairs({ -1, 1 }) do
			neutralPart(track, { Size = Vector3.new(0.4, 0.9, 3.4), CFrame = cf * CFrame.new(side * 6.7, 0.7, 0), Color = Color3.fromRGB(80, 92, 130), Material = Enum.Material.Metal })
		end
		if k == 25 then -- the reveal line
			neutralPart(track, { Size = Vector3.new(13.4, 0.2, 0.7), CFrame = cf * CFrame.new(0, 0.42, 0), Color = Color3.fromRGB(255, 255, 255), Material = Enum.Material.Neon })
			for _, side in ipairs({ -1, 1 }) do
				neutralPart(track, { Size = Vector3.new(0.5, 7, 0.5), CFrame = cf * CFrame.new(side * 7.2, 3.6, 0), Color = Color3.fromRGB(255, 255, 255), Material = Enum.Material.Neon })
			end
		end
	end
	track.Parent = self.viewport
end

-- Play a confirmed result. result = { id, tier, dup, shards, box }, pick() draws a filler id from
-- the capsule's shown odds. mixed = the capsule holds more than one kind.
function Reveal:Play(result, pick, mixed)
	self:_clear()
	self.result = result
	self.gui.Enabled = true
	self.card.Visible = false
	self.syncLabel.Visible = false
	self.skipButton.Visible = true
	self.muteButton.Visible = true
	self.title.Text = string.upper(result.boxName or "CAPSULE")
	self.title.TextColor3 = palette.White
	local winner = Catalog.Get(result.id)
	self.legend.Text = mixed and "SHAPES SHOW THE CATEGORY:  marble = a skin   ·   marble + trace = a trail   ·   spikes = a burst   ·   bubble = an emote" or "Silhouettes only - colours and names stay hidden until the winner crosses the line"
	-- the case opens first (both quality levels; Reduced Motion = a short fade-open)
	local color = result.boxColor or palette.Cyan
	self.chestBody.BackgroundColor3 = color
	self.chestLid.BackgroundColor3 = color:Lerp(palette.White, 0.25)
	self.chest.Visible = true
	self.viewport.Visible, self.ribbon.Visible = false, false
	self.openStart = os.clock()
	self.phase = "Open"
	self:_poseChest(0)
	if self.sound and not self.muted then
		pcall(function()
			self.sound:Play("CaseOpen")
		end)
	end
	local rng = Random.new()
	local lineup = Reveal.Lineup(result.id, pick, function()
		return rng:NextNumber()
	end)
	self.lineup = lineup
	self.crossed = false
	if not self.reducedMotion then
		local built = false
		if not self.low then
			-- the 3D spool; if anything fails to build, the single-camera ribbon plays instead (never
			-- a blank screen)
			built = pcall(function()
				self:_buildTrack()
				self.entrants = {}
				for i, id in ipairs(lineup.ids) do
					local item = Catalog.Get(id)
					local model, root, offsets, trace = self:_silhouette(item or winner)
					model.Parent = self.viewport
					self.entrants[i] = { model = model, root = root, offsets = offsets, trace = trace, lane = Reveal.Lanes[(i - 1) % #Reveal.Lanes + 1] }
				end
			end)
			if not built then
				self:_clear()
				self.entrants = nil
			end
		end
		self.useRibbon = not built
		if self.useRibbon then
			self:_playRibbon(lineup)
			self.ribbon.Visible = false -- shown when the case has opened
		end
	end
	self.playing = true
end

function Reveal:_poseChest(t)
	local pose = Reveal.ChestPose(t, self.reducedMotion)
	self.chestScale.Scale = pose.scale
	self.chest.Rotation = pose.rotation
	self.chestLid.Position = UDim2.new(0.5, pose.lid * 0.4, 1, -150 - pose.lid)
	self.chestLid.Rotation = pose.lidRotation
	self.chestLid.BackgroundTransparency = math.clamp((pose.burst - 0.4) / 0.6, 0, 1)
	self.chestGlow.BackgroundTransparency = 1 - pose.flash * 0.85
	self.chestGlow.Size = UDim2.fromOffset(160 + pose.burst * 260, 160 + pose.burst * 260)
	for k, ray in ipairs(self.chestRays) do
		ray.BackgroundTransparency = pose.burst > 0 and (0.2 + pose.burst * 0.8) or 1
		ray.Size = UDim2.fromOffset(6, 60 + pose.burst * 160 + (k % 2) * 30)
	end
end

-- Low graphics: one camera, a ribbon of the same masks sliding to the same winner.
function Reveal:_playRibbon(lineup)
	self.viewport.Visible, self.ribbon.Visible = false, true
	self.ribbonTiles = {}
	local n = 40
	local landing = 33
	for i = 1, n do
		local id = i == landing and lineup.ids[lineup.winnerIndex] or lineup.ids[(i % #lineup.ids) + 1]
		local item = Catalog.Get(id)
		local tile = UIKit.new("Frame", { Position = UDim2.fromOffset((i - 1) * 124 + 2, 10), Size = UDim2.fromOffset(120, 130), BackgroundColor3 = palette.NavyFloor, BorderSizePixel = 0 }, self.ribbonStrip)
		UIKit.corner(tile, 0.08)
		Reveal.Glyph(tile, item)
	end
	self.ribbonStrip.Position = UDim2.fromOffset(0, 0)
	self.ribbonStop = 430 - ((landing - 1) * 124 + 62)
end

-- 2D silhouette glyph (Low graphics ribbon): a neutral disc + its outline family
function Reveal.Glyph(parent, item)
	local disc = UIKit.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(64, 64), BackgroundColor3 = Reveal.Neutral, BorderSizePixel = 0 }, parent)
	UIKit.corner(disc, 0.5)
	local family = Reveal.Mask(item)
	local function bar(rotation, w, h, y)
		local b = UIKit.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, y or 0.5), Size = UDim2.fromOffset(w, h), Rotation = rotation, BackgroundColor3 = Reveal.NeutralShell, BorderSizePixel = 0 }, disc)
		return b
	end
	if family == "Marble:Stripes" then
		bar(0, 64, 8)
		bar(90, 64, 8)
	elseif family == "Marble:Ring" then
		bar(0, 70, 8)
	elseif family == "Marble:Bands" then
		bar(90, 6, 60, 0.5).Position = UDim2.fromScale(0.25, 0.5)
		bar(90, 6, 64, 0.5)
		bar(90, 6, 60, 0.5).Position = UDim2.fromScale(0.75, 0.5)
	elseif family == "Marble:Speckle" then
		for k = 0, 5 do
			local dot = UIKit.new("Frame", { AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5 + 0.3 * math.cos(k), 0.5 + 0.3 * math.sin(k * 1.7)), Size = UDim2.fromOffset(9, 9), BackgroundColor3 = Reveal.NeutralShell, BorderSizePixel = 0 }, disc)
			UIKit.corner(dot, 0.5)
		end
	elseif family == "Marble:Halo" then
		UIKit.new("UIStroke", { Color = Reveal.NeutralShell, Thickness = 6 }, disc)
		bar(0, 84, 4)
	elseif family == "Marble:Core" then
		bar(0, 64, 6)
		bar(90, 64, 6)
		bar(45, 20, 20)
	elseif family == "Marble:Orbit" then
		bar(55, 80, 5)
		bar(-55, 80, 5)
	elseif string.sub(family, 1, 6) == "Trail:" then
		local profile = string.sub(family, 7)
		local h = ({ Ribbon = 12, Thin = 5, Wide = 22, Twin = 6 })[profile] or 12
		local function trace(y)
			local t = UIKit.new("Frame", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(0, 4, y, 0), Size = UDim2.fromOffset(46, h), BackgroundColor3 = Reveal.NeutralShell, BackgroundTransparency = 0.2, BorderSizePixel = 0 }, disc)
			return t
		end
		if profile == "Twin" then
			trace(0.35)
			trace(0.65)
		else
			trace(0.5)
		end
	elseif family == "Burst" then
		for k = 0, 5 do
			bar(k * 60, 6, 86)
		end
	elseif family == "Emote" then
		disc.Size = UDim2.fromOffset(78, 50)
		UIKit.corner(disc, 0.3)
	end
	return disc
end

function Reveal:_step()
	if self.phase == "Open" then
		local t = os.clock() - self.openStart
		self:_poseChest(t)
		local done = self.reducedMotion and Reveal.ReducedOpen or Reveal.OpenTimes.Burst
		if t < done then
			return
		end
		self.phase = "Spool"
		self.chest.Visible = false
		if self.reducedMotion then
			self:_unmask()
			return
		end
		if self.useRibbon then
			self.ribbon.Visible = true
		else
			self.viewport.Visible = true
		end
		self.t0 = os.clock()
	end
	local t = os.clock() - self.t0
	local T = Reveal.Times
	if self.ribbon.Visible then
		local u = math.clamp((t - 0.2) / (T.Cross - 0.2), 0, 1)
		local eased = 1 - (1 - u) ^ 3
		self.ribbonStrip.Position = UDim2.fromOffset(self.ribbonStop * eased, 0)
	elseif self.entrants then
		local sum = Vector3.new(0, 0, 0)
		local winnerPos
		for i, e in ipairs(self.entrants) do
			local s = Reveal.Progress(t, self.lineup.queuePos[i], self.lineup.rank[i])
			local p, tangent, outward = Reveal.TrackPoint(s)
			local laneShift = e.lane + math.sin(t * 2.3 + i) * 0.6 * math.clamp(t - T.Queue, 0, 1)
			local pos = p + outward * laneShift
			local roll = s * Reveal.Radius * Reveal.Sweep / 2
			local frame = CFrame.lookAt(pos, pos + tangent) * CFrame.Angles(-roll, 0, 0)
			e.root.CFrame = frame
			for _, o in ipairs(e.offsets) do
				o.part.CFrame = o.upright and (CFrame.new(pos) * o.offset) or (frame * o.offset)
			end
			if e.trace then
				local twin = e.trace.profile == "Twin"
				for k, part in ipairs(e.trace.parts) do
					local step = ((k - 1) % 5) + 1
					local back, _, backOut = Reveal.TrackPoint(s - step * 0.05)
					local side = twin and ((k <= 5) and -1 or 1) * 0.8 or 0
					local bp = back + backOut * (laneShift + side) - Vector3.new(0, 1.4, 0)
					part.CFrame = CFrame.lookAt(bp, bp + tangent)
				end
			end
			sum = sum + pos
			if i == self.lineup.winnerIndex then
				winnerPos = pos
			end
		end
		local pack = sum / #self.entrants
		self.camera.CFrame = Reveal.CameraAt(t, t < T.Rail and pack or winnerPos)
	end
	if not self.crossed and t >= T.Cross then
		self.crossed = true
		if self.sound and not self.muted then
			self.sound:Play("Reveal") -- one cue as the winner crosses the line
		end
	end
	if t >= T.Unmask then
		self:_unmask()
	end
end

function Reveal:Skip()
	if self.playing then
		self.chest.Visible = false
		self.phase = "Spool"
		self:_unmask()
	end
end

-- Show the winner: its real look (viewport) and the result card.
function Reveal:_unmask()
	self.playing = false
	self.chest.Visible = false
	if self.entrants then
		self.viewport.Visible = true
	elseif self.useRibbon and not self.reducedMotion then
		self.ribbon.Visible = true
	end
	local result = self.result
	local item = result and Catalog.Get(result.id)
	if self.entrants and self.lineup then
		for i, e in ipairs(self.entrants) do
			if i ~= self.lineup.winnerIndex then
				for _, d in ipairs(e.model:GetDescendants()) do
					if d:IsA("BasePart") then
						d.Transparency = math.max(d.Transparency, 0.7)
					end
				end
			end
		end
		local w = self.entrants[self.lineup.winnerIndex]
		if w and item and (item.Kind == "Marble" or item.Kind == "Trail") then
			local look = item.Kind == "Marble" and item or Catalog.Get(Catalog.Defaults.marble)
			local frame = w.root.CFrame
			w.model:Destroy()
			local model = Instance.new("Model")
			local ball = neutralPart(model, { Shape = Enum.PartType.Ball, Size = Vector3.new(4, 4, 4), CFrame = frame })
			MarbleLook.Apply(ball, look, function(_, part)
				part.Anchored = true
				part.Parent = model
			end, nil)
			if item.Kind == "Trail" then
				for k = 1, 5 do
					local p = neutralPart(model, { Size = Vector3.new(1.2, 0.3, 2.2), Material = Enum.Material.Neon, Color = item.Colors[1]:Lerp(item.Colors[2], k / 5), Transparency = k * 0.12 })
					p.CFrame = frame * CFrame.new(0, -1.4, k * 2.2)
				end
			end
			model.Parent = self.viewport
		end
		local line = Reveal.TrackPoint(1)
		self.camera.CFrame = Reveal.CameraAt(Reveal.Times.Unmask, line)
	end
	if self.ribbon.Visible then
		self.ribbonStrip.Position = UDim2.fromOffset(self.ribbonStop or 0, 0)
	end
	self.skipButton.Visible = false
	self.card.Visible = true
	UIKit.Enter(self.card, "FromBelow", 0.25)
	if item then
		self.rarity.Text = string.upper(item.Rarity) .. "  -  " .. string.upper(item.Kind)
		self.rarity.TextColor3 = Catalog.RarityColors[item.Rarity] or palette.White
		self.itemName.Text = item.Name
		self.outcome.Text = result.dup and string.format("Already owned: converted to +%d SHARDS (the duplicate rate shown before opening).", result.shards or 0) or "NEW - added to your Garage."
		local canEquip = not result.dup and item.Kind ~= "Emote"
		self.equipButton.Visible = canEquip
	else
		self.rarity.Text = ""
		self.itemName.Text = "Opened"
		self.outcome.Text = "Your result is saved - see LAST 20 OPENED."
		self.equipButton.Visible = false
	end
	UIKit.Punch(self.itemName, 1.2, 0.3)
end

-- The opening is still syncing with the server (shown instead of a fake animation)
function Reveal:ShowSyncing(text)
	self:_clear()
	self.gui.Enabled = true
	self.playing = false
	self.card.Visible = false
	self.viewport.Visible, self.ribbon.Visible = false, false
	self.chest.Visible = false
	self.skipButton.Visible = false
	self.muteButton.Visible = false
	self.title.Text = "OPENING"
	self.legend.Text = ""
	self.syncLabel.Visible = true
	self.syncLabel.Text = text or "Syncing with the server... nothing is charged twice, and your result is saved the moment it's decided."
end

function Reveal:_close(action)
	local result = self.result
	self.playing = false
	self.gui.Enabled = false
	self:_clear()
	self.entrants, self.lineup = nil, nil
	self.Finished:Fire(action, result)
end

function Reveal:Close()
	if self.gui.Enabled then
		self:_close("Done")
	end
end

function Reveal:Destroy()
	self.maid:Cleanup()
end

return Reveal
