--[[
	HazardController — every hazard on the race course, on the client.

	All hazard state is a pure function of (seed class, serverTime - epoch) published in the round
	snapshot (A4), so every client and the server agree without per-frame network traffic:
	  Pulse Bumper  Idle cyan -> Telegraph (0.8 s ramp to yellow, no flashing) -> Active coral kick
	                (HazardTiming; per-bumper PhaseOffset from the seed's HazardSim params)
	  Sweeper       arm angle  = HazardSim.SweeperAngle      (visual is non-colliding)
	  Hammer        head lateral = HazardSim.HammerLateral   (visual is non-colliding)
	  Fan / Conveyor  push direction arrows per seed; fan discs show On / Warning / Off
	  Trampoline    upward Δv on the pad (feature: never blocked by a shield)
	  Tiles         toggled by the SERVER (identical floor for everyone and for bots)

	Contact consequences for the LOCAL marble are applied here by its owner (client network
	ownership), bounded by HazardSim.KickCap; bots get the identical model on the server. A shield
	confirmed by the server absorbs bumper / sweeper / hammer hits (the server spends it).
	Moving visuals are anchored, non-colliding parts; no dynamic sphere is ever CFramed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local PhysicsConfig = require(Shared:WaitForChild("PhysicsConfig"))
local HazardTiming = require(Shared:WaitForChild("HazardTiming"))
local HazardSim = require(Shared:WaitForChild("HazardSim"))

local HazardController = {}
HazardController.__index = HazardController

-- Shared with the server's near-miss / shield judging (Shared/HazardTiming).
HazardController.PhaseAt = HazardTiming.PhaseAt

local function frameCFrame(frame, lift)
	return CFrame.fromMatrix(frame.Position + frame.Up * (lift or 0), frame.Right, frame.Up)
end

-- Pure: CFrame of a sweeper arm (centre of the arm part) for angle a (HazardSim convention:
-- x = Right, z = Forward; CFrame local Z points backwards, hence the sign).
function HazardController.SweeperArmCFrame(frame, params, angle)
	return frameCFrame(frame, params.ArmHeight) * CFrame.Angles(0, angle, 0) * CFrame.new(params.ArmLength / 2, 0, 0)
end

function HazardController.HammerHeadCFrame(frame, params, lateral)
	return frameCFrame(frame, 0) * CFrame.new(lateral, params.HeadSize / 2 + 0.2, 0)
end

function HazardController.new(courseRoot, motor, sound, layout)
	local self = setmetatable({}, HazardController)
	self.motor = motor
	self.sound = sound
	self.seed = 0
	self.epoch = 0
	self.bumpers = {}
	self.resolved = {}
	self.byId = {}
	self.cooldowns = {}
	self.reducedMotion = false
	for _, hz in ipairs(layout and layout.Hazards or {}) do
		local entry = { Kind = hz.Kind, Id = hz.Id, Definition = hz.Definition, Frame = hz.Frame, FromFrame = hz.FromFrame, Length = hz.Length, Offset = hz.Offset, parts = {} }
		self.resolved[#self.resolved + 1] = entry
		self.byId[hz.Id] = entry
	end
	local hazards = courseRoot:FindFirstChild("Hazards")
	if hazards then
		for _, folder in ipairs(hazards:GetChildren()) do
			local base = folder:FindFirstChild("Base")
			if base and base:GetAttribute("HazardType") == "PulseBumper" then
				local height = base:GetAttribute("Height") or base.Size.X
				local axis = base.CFrame.RightVector -- cylinder axis = local X = floor normal
				-- A6 colour-blind cue: the bumper's state is also written above it ("!" / "KICK")
				local cue = Instance.new("BillboardGui")
				cue.Name = "TC_Cue"
				cue.Size = UDim2.fromOffset(90, 34)
				cue.StudsOffsetWorldSpace = Vector3.new(0, height + 2.5, 0)
				cue.MaxDistance = 80
				cue.LightInfluence = 0
				cue.Enabled = false
				local cueText = Instance.new("TextLabel")
				cueText.Size = UDim2.fromScale(1, 1)
				cueText.BackgroundTransparency = 1
				cueText.TextScaled = true
				cueText.Font = Enum.Font.GothamBlack
				cueText.TextStrokeTransparency = 0.2
				cueText.Parent = cue
				cue.Adornee = base
				cue.Parent = base
				local rock = folder:FindFirstChild("Rock")
				table.insert(self.bumpers, {
					idleColor = base.Color, -- B1: themed worlds keep their own bumper colour
					rock = rock, -- B1 Volcano: boulder that drops while the bumper warns
					rockRest = rock and rock.CFrame,
					cue = cue,
					cueText = cueText,
					id = base:GetAttribute("HazardId") or folder.Name,
					base = base,
					ring = folder:FindFirstChild("Ring"),
					floorRing = folder:FindFirstChild("FloorRing"),
					radius = base:GetAttribute("Radius") or base.Size.Y / 2,
					height = height,
					axis = axis,
					floorPoint = base.Position - axis * (height / 2 - 0.5),
					cooldownUntil = 0,
					lastKey = nil,
				})
			end
			for _, part in ipairs(folder:GetChildren()) do
				local id = part:IsA("BasePart") and part:GetAttribute("HazardId")
				local entry = id and self.byId[id]
				local role = id and part:GetAttribute("Role")
				if entry and role then
					entry.parts[role] = entry.parts[role] or {}
					table.insert(entry.parts[role], part)
				end
			end
		end
	end
	for _, hz in ipairs(self.resolved) do
		for _, disc in ipairs(hz.parts.FanDisc or {}) do
			disc:SetAttribute("TC_IdleColor", disc.Color) -- B1 theme colour to return to
		end
	end
	self:SetRound(0, 0)
	return self
end

-- B1: the course switched to another world; leave this one's parts quiet.
function HazardController:Destroy()
	for _, bumper in ipairs(self.bumpers) do
		bumper.cue.Enabled = false
		bumper.base.Color = bumper.idleColor
		if bumper.rock then
			bumper.rock.CFrame = bumper.rockRest
			bumper.rock.Transparency = 0
		end
	end
	self.bumpers = {}
	self.resolved = {}
end

-- A3: while the local marble's server-confirmed Shield is up, hits are absorbed.
function HazardController:SetShieldQuery(fn)
	self.isShielded = fn
end

function HazardController:SetReducedMotion(value)
	self.reducedMotion = value == true
end

-- A4: from the round snapshot (hazardSeed, hazardEpoch).
function HazardController:SetRound(seed, epoch)
	seed = tonumber(seed) or 0
	epoch = tonumber(epoch) or 0
	if seed == self.seed and epoch == self.epoch and self.resolved[1] and self.resolved[1].Params then
		return
	end
	self.seed, self.epoch = seed % HazardSim.SeedClasses, epoch
	for _, hz in ipairs(self.resolved) do
		hz.Params = HazardSim.Params(hz.Definition, self.seed)
		hz.lastVisualKey = nil
		-- push arrows: show the set pointing the way this seed pushes
		for _, arrow in ipairs(hz.parts.Arrow or {}) do
			local dir = arrow:GetAttribute("Dir") or 1
			arrow:SetAttribute("Shown", dir == (hz.Params.Direction or 1))
		end
	end
	for _, bumper in ipairs(self.bumpers) do
		local hz = self.byId[bumper.id]
		bumper.phaseOffset = (hz and hz.Params and hz.Params.PhaseOffset) or 0
		bumper.lastKey = nil
	end
end

-- A6 Chaos Vote modifier from VoteState / the snapshot (same timestamps as the server).
function HazardController:SetModifier(modifier)
	self.modifier = type(modifier) == "table" and modifier or nil
	for _, hz in ipairs(self.resolved) do
		hz.lastVisualKey = nil
	end
end

function HazardController:Time()
	return workspace:GetServerTimeNow() - self.epoch
end

-- Continuous push for the local marble (used by MarbleMotorController:SetEnvironmentAccel).
function HazardController:EnvironmentAccel(position)
	local t = self:Time()
	local fanBoost = HazardSim.FanMultiplier(self.modifier, workspace:GetServerTimeNow())
	local total = nil
	for _, hz in ipairs(self.resolved) do
		if hz.Params and (hz.Kind == "Fan" or hz.Kind == "Conveyor") then
			local push = HazardSim.EnvironmentAccel(hz, t, position)
			if push then
				total = (total or Vector3.new(0, 0, 0)) + push * (hz.Kind == "Fan" and fanBoost or 1)
			end
		end
	end
	return total
end

function HazardController:_animate(t)
	local palette = GameConfig.Palette
	for _, hz in ipairs(self.resolved) do
		local p = hz.Params
		if p and hz.Frame then
			if hz.Kind == "Sweeper" then
				local angle = HazardSim.SweeperAngle(p, t)
				for _, arm in ipairs(hz.parts.Arm or {}) do
					arm.CFrame = HazardController.SweeperArmCFrame(hz.Frame, p, angle)
				end
			elseif hz.Kind == "Hammer" then
				local lateral = HazardSim.HammerLateral(p, t)
				for _, head in ipairs(hz.parts.Head or {}) do
					head.CFrame = HazardController.HammerHeadCFrame(hz.Frame, p, lateral)
				end
			elseif hz.Kind == "Fan" or hz.Kind == "Conveyor" then
				local state = hz.Kind == "Fan" and HazardSim.FanState(p, t) or "On"
				local turbo = hz.Kind == "Fan" and HazardSim.FanMultiplier(self.modifier, workspace:GetServerTimeNow()) > 1
				local key = state .. (turbo and "T" or "")
				if key ~= hz.lastVisualKey then
					hz.lastVisualKey = key
					local arrowAlpha = state == "On" and 0.1 or state == "Warning" and 0.5 or 0.92
					for _, arrow in ipairs(hz.parts.Arrow or {}) do
						arrow.Transparency = arrow:GetAttribute("Shown") and arrowAlpha or 1
					end
					for _, disc in ipairs(hz.parts.FanDisc or {}) do
						local idle = disc:GetAttribute("TC_IdleColor") or palette.Cyan
						disc.Color = turbo and palette.Coral or state == "On" and idle or state == "Warning" and palette.Yellow or palette.NavyRail
					end
				end
				if state == "On" and not self.reducedMotion then
					for _, disc in ipairs(hz.parts.FanDisc or {}) do
						disc.CFrame = disc.CFrame * CFrame.Angles(0.25, 0, 0)
					end
				end
			end
		end
	end
end

function HazardController:Step(ball)
	local t = self:Time()
	self:_animate(t)
	local cfg = PhysicsConfig.Hazards.PulseBumper
	local palette = GameConfig.Palette
	local ballRadius = PhysicsConfig.Ball.Radius
	local now = os.clock()
	local shielded = self.isShielded and self.isShielded()
	local bouncy = HazardSim.BumperKickMultiplier(self.modifier, workspace:GetServerTimeNow()) > 1

	-- B2 Phase: tagged hazard props (bumper posts, sweeper arms, hammer heads) don't touch you
	-- for 1.5 s. Locally only, for your own marble (you simulate it); floor/walls never change.
	local phased = self.motor.HasStatus and self.motor:HasStatus("Phase") or false
	if phased ~= self.phased then
		self.phased = phased
		for _, bumper in ipairs(self.bumpers) do
			bumper.base.CanCollide = not phased
			bumper.base.LocalTransparencyModifier = phased and 0.6 or 0
		end
	end
	for _, bumper in ipairs(self.bumpers) do
		local state, blend = HazardController.PhaseAt(t + (bumper.phaseOffset or 0), cfg)
		local key = state .. math.floor(blend * 20) .. (bouncy and "B" or "") -- colour changes in 5% steps
		if bumper.lastKey ~= key then
			bumper.lastKey = key
			local idle = bumper.idleColor or palette.Cyan
			local color = idle
			if state == "Telegraph" then
				color = idle:Lerp(palette.Yellow, blend)
			elseif state == "Active" then
				color = palette.Coral
			end
			bumper.base.Color = state == "Active" and palette.Coral or idle
			if bumper.ring then
				bumper.ring.Color = color
			end
			if bumper.floorRing then
				bumper.floorRing.Color = color
			end
			bumper.cue.Enabled = state ~= "Idle"
			bumper.cueText.Text = state == "Active" and (bouncy and "BOUNCY!" or "KICK") or "!"
			bumper.cueText.TextColor3 = state == "Active" and palette.Coral or palette.Yellow
		end
		if bumper.rock then
			-- B1 rockfall: hidden while idle, drops during the warning, rests on the post while it kicks
			local rock = bumper.rock
			if state == "Idle" then
				rock.Transparency = 1
			elseif state == "Telegraph" and not self.reducedMotion then
				rock.Transparency = 0
				rock.CFrame = bumper.rockRest + bumper.axis * (18 * (1 - blend) ^ 2)
			else
				rock.Transparency = 0
				rock.CFrame = bumper.rockRest
			end
		end
		if ball and ball.Parent and state == "Active" and now >= bumper.cooldownUntil and not phased then
			local rel = ball.Position - bumper.floorPoint
			local along = rel:Dot(bumper.axis)
			if along > -1 and along < bumper.height + 1 then
				local radial = rel - bumper.axis * along
				local d = radial.Magnitude
				if d > 1e-3 and d <= bumper.radius + ballRadius + cfg.ContactPadding and not shielded then
					if self.motor:ApplyKick(radial / d, cfg.KickSpeed * HazardSim.BumperKickMultiplier(self.modifier, workspace:GetServerTimeNow())) then
						bumper.cooldownUntil = now + cfg.CooldownSeconds
						self.sound:Play("BumperKick")
					end
				end
			end
		end
	end

	-- A4 moving-hazard contact for the local marble (same model the server uses for bots).
	if ball and ball.Parent and not ball.Anchored then
		for _, hz in ipairs(self.resolved) do
			if hz.Params and hz.Frame and (hz.Kind == "Sweeper" or hz.Kind == "Hammer" or hz.Kind == "Trampoline") then
				if (self.cooldowns[hz.Id] or 0) <= now then
					local kick = HazardSim.Contact(hz, t, ball.Position, ballRadius)
					if kick and hz.Kind ~= "Trampoline" and phased then
						kick = nil -- B2 Phase: sweeper arms / hammer heads pass through you
					end
					if kick and (hz.Kind == "Trampoline" or not shielded) then
						self.cooldowns[hz.Id] = now + 0.5
						local cap = HazardSim.KickCap + 15
						if self.motor:ApplyExternalImpulse(kick, math.min(kick.Magnitude, cap), cap) then
							self.sound:Play("BumperKick")
						end
					elseif kick then
						self.cooldowns[hz.Id] = now + 0.5 -- absorbed by the shield
					end
				end
			end
		end
	end
end

return HazardController
