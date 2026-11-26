--[[
	RaceIntroController (owner request 2026-11-26: "an animation of all players (balls) entering
	the race"). Client-only and purely visual.

	When a round enters Preparing, every marble that appears on the grid (players and bots) drops
	in from above with a bounce and a landing ring, front row first, while the camera swoops from
	a high shot of the grid down to the chase view (CameraController:PlayIntro).

	The real marbles never move: the server keeps them anchored until GO. Each one is hidden
	locally (LocalTransparencyModifier) while a client-only copy (no collision, query or touch,
	parented to the camera, attributes stripped so nothing mistakes it for a marble) falls into
	its exact place; then the copy is removed and the real marble shown again. Every drop ends
	before the countdown's first number, a failsafe re-shows a marble whatever happens, and
	Reduced motion turns the whole intro off.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Protocol = require(Shared:WaitForChild("Protocol"))
local RaceConfig = require(Shared:WaitForChild("RaceConfig"))
local RoundProtocol = require(Shared:WaitForChild("RoundProtocol"))

local RaceIntro = {}
RaceIntro.__index = RaceIntro

RaceIntro.DropHeight = 26 -- studs above the grid slot
RaceIntro.DropSeconds = 0.7 -- fall + bounce
RaceIntro.StaggerSeconds = 0.08 -- between rows, front first
RaceIntro.CollectSeconds = 0.12 -- wait for the grid to replicate, then sort
RaceIntro.WindowSeconds = 1.0 -- marbles arriving later than this just appear
RaceIntro.CameraSeconds = 2.2

-- Pure: the start delay for the n-th marble (1 = front of the grid). Clamped so the last drop
-- still lands inside Preparing (checked by RaceIntro.spec).
function RaceIntro.DelayFor(rank)
	local maxDelay = RaceConfig.Timers.PreparingSeconds - RaceIntro.CollectSeconds - RaceIntro.DropSeconds - 0.15
	return math.min(math.max(0, (rank - 1) * RaceIntro.StaggerSeconds), maxDelay)
end

-- Pure: order grid positions front to back along `forward` (unit Vector3). Returns indices.
function RaceIntro.Order(positions, forward)
	local idx = {}
	for i in ipairs(positions) do
		idx[i] = i
	end
	table.sort(idx, function(a, b)
		local da, db = positions[a]:Dot(forward), positions[b]:Dot(forward)
		if math.abs(da - db) > 0.5 then
			return da > db
		end
		return a < b
	end)
	return idx
end

function RaceIntro.new(deps)
	local self = setmetatable({}, RaceIntro)
	self.folder = deps.marblesFolder
	self.camera = deps.cameraController
	self.forward = deps.forward -- function() -> Vector3 (route direction at the start), may be nil
	self.myName = Protocol.MarbleName(Players.LocalPlayer.UserId)
	self.reducedMotion = false
	self.roundId = nil
	self.windowUntil = 0
	self.pending = {}
	self.active = {} -- ball -> record
	self.seen = setmetatable({}, { __mode = "k" })
	self.connection = self.folder.ChildAdded:Connect(function(child)
		task.defer(function() -- after the bootstrap has bound (and outlined) your own marble
			self:_consider(child)
		end)
	end)
	return self
end

function RaceIntro:SetReducedMotion(value)
	self.reducedMotion = value == true
	if self.reducedMotion then
		self:FinishAll()
	end
end

local function isGridBall(ball)
	return ball:IsA("BasePart") and ball:GetAttribute(Protocol.BallAttributes.Zone) == Protocol.Zones.Race and ball:GetAttribute(Protocol.BallAttributes.Frozen) == true
end

-- Called with every round snapshot.
function RaceIntro:OnSnapshot(snap)
	local S = RoundProtocol.States
	if snap.state == S.Preparing and snap.roundId ~= self.roundId then
		self.roundId = snap.roundId
		if self.reducedMotion then
			return
		end
		self.windowUntil = os.clock() + RaceIntro.WindowSeconds
		self.pending = {}
		self.flushed = false
		for _, child in ipairs(self.folder:GetChildren()) do
			self:_consider(child)
		end
		task.delay(RaceIntro.CollectSeconds, function()
			self:_flush()
		end)
	elseif snap.state ~= S.Preparing and snap.state ~= S.Countdown then
		self:FinishAll() -- racing / results / lobby: nothing stays hidden
	end
end

function RaceIntro:_consider(ball)
	if self.reducedMotion or os.clock() > self.windowUntil or self.seen[ball] then
		return
	end
	if not isGridBall(ball) then
		return
	end
	self.seen[ball] = true
	local record = self:_hide(ball)
	if not record then
		return
	end
	if ball.Name == self.myName and self.camera and self.camera.PlayIntro then
		self.camera:PlayIntro(ball, RaceIntro.CameraSeconds)
	end
	if self.flushed then
		self:_drop(record, 0) -- a late arrival drops straight away
	else
		self.pending[#self.pending + 1] = record
	end
end

function RaceIntro:_flush()
	self.flushed = true
	local list = self.pending
	self.pending = {}
	local positions = {}
	for i, record in ipairs(list) do
		positions[i] = record.ball.Position
	end
	local forward = self.forward and self.forward() or Vector3.new(0, 0, -1)
	for rank, i in ipairs(RaceIntro.Order(positions, forward)) do
		self:_drop(list[i], RaceIntro.DelayFor(rank))
	end
end

-- Hide the real marble (and its welded look shells) for this client only.
function RaceIntro:_hide(ball)
	local parts = { ball }
	for _, d in ipairs(ball:GetDescendants()) do
		if d:IsA("BasePart") then
			parts[#parts + 1] = d
		end
	end
	local outline = ball:FindFirstChild("TC_SelfOutline")
	local record = { ball = ball, parts = parts, outline = outline, target = ball.CFrame, effects = {} }
	-- the falling copy is cloned now, before the real marble's effects are switched off
	local ok, copy = pcall(function()
		return ball:Clone()
	end)
	if not ok or not copy then
		return nil
	end
	record.template = copy
	for _, part in ipairs(parts) do
		part.LocalTransparencyModifier = 1
	end
	if outline then
		outline.Enabled = false
	end
	for _, d in ipairs(ball:GetDescendants()) do -- look glows / sparkles would float on the empty slot
		if (d:IsA("ParticleEmitter") or d:IsA("Light") or d:IsA("Trail")) and d.Enabled then
			d.Enabled = false
			record.effects[#record.effects + 1] = d
		end
	end
	self.active[ball] = record
	-- failsafe: whatever happens to the tween, the real marble is shown again
	task.delay(RaceConfig.Timers.PreparingSeconds + 1, function()
		self:_finish(record)
	end)
	return record
end

local function tween(inst, seconds, props, style, direction)
	local t = game:GetService("TweenService"):Create(inst, TweenInfo.new(seconds, style, direction), props)
	t:Play()
	return t
end

function RaceIntro:_drop(record, delay)
	task.delay(delay, function()
		if record.done or not record.ball.Parent then
			self:_finish(record)
			return
		end
		local copy = record.template
		record.template = nil
		local outline = record.ball:FindFirstChild("TC_SelfOutline")
		if outline and outline.Enabled then
			outline.Enabled = false
			record.outline = outline
		end
		if not copy then
			self:_finish(record)
			return
		end
		for name in pairs(copy:GetAttributes()) do
			copy:SetAttribute(name, nil)
		end
		copy.Name = "TC_IntroMarble"
		for _, d in ipairs(copy:GetDescendants()) do
			if d:IsA("Highlight") then
				d:Destroy()
			elseif d:IsA("BasePart") then
				d.CanCollide, d.CanQuery, d.CanTouch = false, false, false
				d.LocalTransparencyModifier = 0
			end
		end
		copy.Anchored = true
		copy.CanCollide, copy.CanQuery, copy.CanTouch = false, false, false
		copy.LocalTransparencyModifier = 0
		local target = record.target
		-- start high and half a turn back, so it rolls forward as it lands
		copy.CFrame = (target + Vector3.new(0, RaceIntro.DropHeight, 0)) * CFrame.Angles(math.rad(-160), 0, 0)
		copy.Parent = workspace.CurrentCamera
		record.copy = copy
		local t = tween(copy, RaceIntro.DropSeconds, { CFrame = target }, Enum.EasingStyle.Bounce, Enum.EasingDirection.Out)
		task.delay(RaceIntro.DropSeconds * 0.36, function()
			self:_ring(target.Position, copy) -- Bounce/Out first touches down at ~36% of the time
		end)
		t.Completed:Connect(function()
			self:_finish(record)
		end)
	end)
end

-- A flat ring that widens and fades where the marble lands (client-local, no collision).
function RaceIntro:_ring(position, copy)
	if self.reducedMotion then
		return
	end
	local ok = pcall(function()
		local color = copy and copy.Parent and copy.Color or Color3.fromRGB(255, 255, 255)
		local ring = Instance.new("Part")
		ring.Name = "TC_IntroRing"
		ring.Shape = Enum.PartType.Cylinder
		ring.Anchored, ring.CanCollide, ring.CanQuery, ring.CanTouch, ring.CastShadow = true, false, false, false, false
		ring.Material = Enum.Material.Neon
		ring.Color = color
		ring.Transparency = 0.25
		ring.Size = Vector3.new(0.2, 3, 3)
		ring.CFrame = CFrame.new(position - Vector3.new(0, 1.85, 0)) * CFrame.Angles(0, 0, math.rad(90))
		ring.Parent = workspace.CurrentCamera
		local t = tween(ring, 0.4, { Size = Vector3.new(0.2, 11, 11), Transparency = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		t.Completed:Connect(function()
			ring:Destroy()
		end)
	end)
	return ok
end

function RaceIntro:_finish(record)
	if record.done then
		return
	end
	record.done = true
	self.active[record.ball] = nil
	if record.copy then
		record.copy:Destroy()
		record.copy = nil
	end
	if record.template then
		record.template:Destroy()
		record.template = nil
	end
	for _, part in ipairs(record.parts) do
		if part.Parent then
			part.LocalTransparencyModifier = 0
		end
	end
	if record.outline and record.outline.Parent then
		record.outline.Enabled = true
	end
	for _, effect in ipairs(record.effects) do
		if effect.Parent then
			effect.Enabled = true
		end
	end
end

function RaceIntro:FinishAll()
	self.windowUntil = 0
	local list = {}
	for _, record in pairs(self.active) do
		list[#list + 1] = record
	end
	for _, record in ipairs(list) do
		self:_finish(record)
	end
	for _, record in ipairs(self.pending) do
		self:_finish(record)
	end
	self.pending = {}
end

function RaceIntro:Destroy()
	self:FinishAll()
	if self.connection then
		self.connection:Disconnect()
		self.connection = nil
	end
end

return RaceIntro
