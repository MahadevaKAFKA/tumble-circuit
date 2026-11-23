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

		-- Forward thrust / back bias (no thrust while braking)
		local throttle = ctx.brake and 0 or ctx.steer.Y
		local forwardSpeed = v:Dot(fwd)
		if throttle > 0 then
			local taper = Utility.clamp((m.ThrottleTargetSpeed - forwardSpeed) / m.ThrottleTaperRange, 0, 1)
			accel = accel + fwd * (m.AlongTrackAccel * throttle * taper * control)
		elseif throttle < 0 and forwardSpeed > -m.ReverseSpeedCap then
			accel = accel + fwd * (m.ReverseAccel * throttle * control)
		end

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
	if speed > m.TerminalSpeed then
		accel = accel - velDir * math.min(m.TerminalDragMax, (speed - m.TerminalSpeed) * m.TerminalDragResponse)
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
	return true
end

function MarbleMotorController:Destroy()
	self:Unbind()
end

return MarbleMotorController
