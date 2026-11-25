--[[
	MarbleMotorController — client-side steering for the locally owned marble.

	Forces only: one VectorForce through the centre of mass (world space), recomputed every frame
	from PhysicsConfig. The engine integrates it at its own physics rate, so a slow frame does not
	discard simulated time (no dt clamping anywhere). The ball is never CFramed or velocity-set
	by this script; the only impulse is the bumper kick (ApplyKick), bounded by KickSpeed.

	Rolling comes from real friction against the floor (the force acts at the centre, contact
	friction spins the sphere), so the visual roll matches the motion.

	Axes: steering is measured against forwardH — the route's gravity-projected tangent supplied
	by ClientBootstrap — projected onto the ground plane. It never uses the camera's heading, so
	looking down the banked drop cannot reverse left/right.

	The VectorForce/Attachment are created locally (they do not replicate) and die with the ball.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local PhysicsConfig = require(Shared:WaitForChild("PhysicsConfig"))
local RaceConfig = require(Shared:WaitForChild("RaceConfig"))
local Utility = require(Shared:WaitForChild("Utility"))

local MarbleMotorController = {}
MarbleMotorController.__index = MarbleMotorController

MarbleMotorController.Modes = { Idle = "Idle", Play = "Play", Finished = "Finished" }

function MarbleMotorController.new()
	local self = setmetatable({}, MarbleMotorController)
	self.ball = nil
	self.force = nil
	self.attachment = nil
	self.grounded = false
	self.groundedUntil = 0
	self.groundNormal = Vector3.new(0, 1, 0)
	self.brakeTarget = nil
	self.params = RaycastParams.new()
	self.params.FilterType = Enum.RaycastFilterType.Exclude
	self.params.IgnoreWater = true
	self.debug = { accel = Vector3.new(0, 0, 0) }
	return self
end

function MarbleMotorController:Bind(ball, excludeInstances)
	self:Unbind()
	local attachment = Instance.new("Attachment")
	attachment.Name = "TC_MotorAttachment"
	attachment.Parent = ball
	local force = Instance.new("VectorForce")
	force.Name = "TC_Motor"
	force.Attachment0 = attachment
	force.RelativeTo = Enum.ActuatorRelativeTo.World
	force.ApplyAtCenterOfMass = true
	force.Force = Vector3.new(0, 0, 0)
	force.Parent = ball
	self.ball = ball
	self.attachment = attachment
	self.force = force
	self.params.FilterDescendantsInstances = excludeInstances or {}
	self.grounded = false
	self.groundedUntil = 0
	self.brakeTarget = nil
	self.lastVelocity = nil
	self.chainUntil = 0
	self.skipBumpCheck = true
end

-- A3: server-sent timed speed modifiers. Strongest active one applies (never stacked);
-- effects = { modifiers = { {kind, multiplier, endsAt (server time or nil), extraAccel} }, hardCap }
function MarbleMotorController:SetEffects(effects)
	self.effects = effects
end

function MarbleMotorController:_modifier()
	local effects = self.effects
	if not effects or not effects.modifiers then
		return 1, 0, PhysicsConfig.Movement.TerminalSpeed
	end
	local now = workspace:GetServerTimeNow()
	local best, extra = 1, 0
	for _, mod in ipairs(effects.modifiers) do
		if mod.endsAt == nil or now < mod.endsAt then
			if mod.multiplier > best then
				best = mod.multiplier
			end
			extra = math.max(extra, mod.extraAccel or 0)
		end
	end
	local terminal = math.min(PhysicsConfig.Movement.TerminalSpeed * best, effects.hardCap or PhysicsConfig.Movement.TerminalSpeed)
	return best, extra, terminal
end

function MarbleMotorController:GetSpeedMultiplier()
	local mult = self:_modifier()
	return mult
end

-- A3: a server-approved impulse (Pulse). Bounded by the caller and here.
function MarbleMotorController:ApplyExternalImpulse(direction, deltaV, cap)
	local ball = self.ball
	if not ball or not ball.Parent or ball.Anchored then
		return false
	end
	local dv = math.min(deltaV, cap or 18)
	ball:ApplyImpulse(direction.Unit * (dv * ball.AssemblyMass))
	self.skipBumpCheck = true
	return true
end

-- Folder holding every marble, used to tell marble bumps from wall bounces.
function MarbleMotorController:SetMarblesFolder(folder)
	self.marblesFolder = folder
end

-- Bounded knockback (master: capped impulses, 1.2 s anti-chain-stun). A single-frame velocity
-- change while touching another marble is limited with a counter-impulse; never a velocity set.
function MarbleMotorController:_limitBump(ball, v, now)
	local previous = self.lastVelocity
	self.lastVelocity = v
	if self.skipBumpCheck or not previous or not self.marblesFolder then
		self.skipBumpCheck = false
		return
	end
	local delta = v - previous
	local cfg = RaceConfig.Collisions
	local cap = now < self.chainUntil and cfg.ChainBumpDeltaV or cfg.MaxBumpDeltaV
	local magnitude = delta.Magnitude
	if magnitude <= cap then
		return
	end
	local nearMarble = false
	local position = ball.Position
	for _, other in ipairs(self.marblesFolder:GetChildren()) do
		if other ~= ball and other:IsA("BasePart") and (other.Position - position).Magnitude <= cfg.BumpProximity then
			nearMarble = true
			break
		end
	end
	if not nearMarble then
		return
	end
	local excess = delta * ((magnitude - cap) / magnitude)
	ball:ApplyImpulse(-excess * ball.AssemblyMass)
	self.lastVelocity = v - excess
	self.chainUntil = now + cfg.AntiChainSeconds
end

function MarbleMotorController:Unbind()
	if self.force then
		self.force:Destroy()
	end
	if self.attachment then
		self.attachment:Destroy()
	end
	self.force = nil
	self.attachment = nil
	self.ball = nil
	self.brakeTarget = nil
end

function MarbleMotorController:IsGrounded()
	return self.grounded
end

function MarbleMotorController:_probeGround(now)
	local radius = PhysicsConfig.Ball.Radius
	local g = PhysicsConfig.Ground
	local probeRadius = radius * g.ProbeRadiusFactor
	local sweep = (radius - probeRadius) + g.ProbeExtra
	local result = workspace:Spherecast(self.ball.Position, probeRadius, Vector3.new(0, -sweep, 0), self.params)
	if result and result.Normal.Y >= g.MinNormalY then
		self.groundNormal = result.Normal
		self.groundedUntil = now + g.CoyoteSeconds
	end
	self.grounded = now <= self.groundedUntil
	if not self.grounded then
		self.groundNormal = Vector3.new(0, 1, 0)
	end
end

-- ctx = { mode, steer (Vector2), brake (bool), brakePressed (bool), forwardH (unit Vector3) }
function MarbleMotorController:Step(dt, ctx)
	local ball = self.ball
	if not ball or not ball.Parent or not self.force or not self.force.Parent then
		return
	end
	local now = os.clock()
	self:_probeGround(now)

	local m = PhysicsConfig.Movement
	local v = ball.AssemblyLinearVelocity
	if not ball.Anchored then
		self:_limitBump(ball, v, now)
		v = ball.AssemblyLinearVelocity
	end
	local speed = v.Magnitude
	local up = self.groundNormal
	local forwardH = ctx.forwardH
	local fwd = Utility.safeUnit(Utility.projectOnPlane(forwardH, up), forwardH)
	local right = Utility.safeUnit(fwd:Cross(up), Vector3.new(1, 0, 0))
	local control = self.grounded and 1 or m.AirControl
	local accel = Vector3.new(0, 0, 0)
	local velDir = speed > 1e-3 and v / speed or Vector3.new(0, 0, 0)

	if ctx.mode == MarbleMotorController.Modes.Finished then
		if speed > 0.5 then
			accel = accel - velDir * math.min(m.FinishBrakeDecel, speed * 4)
		end
		self.brakeTarget = nil
	elseif ctx.mode == MarbleMotorController.Modes.Play then
		-- Lateral: push toward steer * LateralSpeedCap, one-sided (never fights drift that is
		-- already past the target in the steering direction, e.g. on a bank).
		local steerX = ctx.steer.X
		local lateralSpeed = v:Dot(right)
		local lateralAccel
		if steerX ~= 0 then
			lateralAccel = (steerX * m.LateralSpeedCap - lateralSpeed) * m.LateralResponse
			if steerX > 0 then
				lateralAccel = math.max(0, lateralAccel)
			else
				lateralAccel = math.min(0, lateralAccel)
			end
		else
			lateralAccel = -lateralSpeed * m.LateralAssistDamping
		end
		lateralAccel = Utility.clamp(lateralAccel, -m.LateralAccelMax, m.LateralAccelMax)
		accel = accel + right * (lateralAccel * control)

		-- Forward thrust / back bias (no thrust while braking). A3 modifiers scale the thrust,
		-- its target and the terminal envelope; Boost adds a forward push up to the cap.
		local mult, extraAccel, terminal = self:_modifier()
		local throttle = ctx.brake and 0 or ctx.steer.Y
		local forwardSpeed = v:Dot(fwd)
		if throttle > 0 then
			local taper = Utility.clamp((m.ThrottleTargetSpeed * mult - forwardSpeed) / m.ThrottleTaperRange, 0, 1)
			accel = accel + fwd * (m.AlongTrackAccel * mult * throttle * taper * control)
		elseif throttle < 0 and forwardSpeed > -m.ReverseSpeedCap then
			accel = accel + fwd * (m.ReverseAccel * throttle * control)
		end
		if extraAccel > 0 and not ctx.brake and forwardSpeed < terminal then
			accel = accel + fwd * (extraAccel * control)
		end
		self.terminalOverride = terminal

		-- Brake: bounded pull toward a target captured at press (see PhysicsConfig)
		if ctx.brake then
			if self.brakeTarget == nil or ctx.brakePressed then
				self.brakeTarget = math.max(m.BrakeMinTargetSpeed, speed * m.BrakeTargetSpeedMultiplier)
			end
			if speed > self.brakeTarget then
				local decel = math.min(m.BrakeMaxDecel, (speed - self.brakeTarget) * m.BrakeResponse)
				accel = accel - velDir * (decel * control)
			end
		else
			self.brakeTarget = nil
		end
	else
		self.brakeTarget = nil
	end

	-- Speed envelope (all modes)
	if self.grounded then
		accel = accel - velDir * (m.RollingResistance * Utility.clamp(speed / 3, 0, 1))
	end
	accel = accel - v * m.LinearDrag
	local terminalSpeed = (ctx.mode == MarbleMotorController.Modes.Play and self.terminalOverride) or m.TerminalSpeed
	self.terminalOverride = nil
	if speed > terminalSpeed then
		accel = accel - velDir * math.min(m.TerminalDragMax, (speed - terminalSpeed) * m.TerminalDragResponse)
	end

	if self.grounded then
		accel = accel * m.RollingInertiaCompensation
	end
	self.debug.accel = accel
	self.force.Force = accel * ball.AssemblyMass
end

-- Guarantee at least kickSpeed of velocity along unit `direction` (bumper kick). Bounded.
function MarbleMotorController:ApplyKick(direction, kickSpeed)
	local ball = self.ball
	if not ball or not ball.Parent then
		return false
	end
	local along = ball.AssemblyLinearVelocity:Dot(direction)
	local deltaV = kickSpeed - along
	if deltaV <= 0 then
		return false
	end
	ball:ApplyImpulse(direction * (deltaV * ball.AssemblyMass))
	self.skipBumpCheck = true -- our own kick is not a marble bump
	return true
end

function MarbleMotorController:Destroy()
	self:Unbind()
end

return MarbleMotorController
