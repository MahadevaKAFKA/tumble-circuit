--[[
	CameraController — scriptable 3/4 chase camera.

	* Heading = smoothed gravity-projected route tangent a few studs ahead (never the ball's spin,
	  never its velocity), turned with turnToward() which cannot snap 180 degrees. The tangent is
	  the chord-smoothed one (RouteTracker.SmoothHorizontalTangentAtS), so the camera turns
	  steadily through curves instead of in a small kick at every 5-degree polyline vertex.
	* Pitch adapts to drops: the route's descent angle LookAheadStuds ahead is added to the base
	  pitch, capped at MaxPitchDeg so the look vector never approaches vertical. Up is always
	  world +Y, so CFrame.lookAt cannot flip.
	* Distance 20 (Chase) or 26 (Wide); a raycast from the marble to the camera pulls it in fast
	  when geometry is in the way and lets it out slowly. Rails, decor, hazards and marbles are
	  ignored by that ray so the camera does not twitch against them.
	* All smoothing is exponential with exact dt (same feel at any frame rate).
	* Respawn / big jumps snap instead of swooping. Destroy() restores the default camera.
	* Free look (A4, owner request): AddLook() orbits the view around the marble (yaw any amount,
	  total pitch within FreeLook.Min/MaxPitchDeg). It is display only; the chase heading keeps
	  following the route underneath, and the view eases back behind the marble ReturnDelaySeconds
	  after the last look input. A new marble (Bind) resets it. Input lives in FreeLookController.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local RouteTracker = require(Shared:WaitForChild("RouteTracker"))
local Utility = require(Shared:WaitForChild("Utility"))

local CameraController = {}
CameraController.__index = CameraController

local UP = Vector3.new(0, 1, 0)

function CameraController.new()
	local self = setmetatable({}, CameraController)
	local cfg = GameConfig.Camera
	self.maid = Utility.Maid.new()
	self.camera = workspace.CurrentCamera
	self.mode = cfg.DefaultMode
	self.heading = Vector3.new(0, 0, -1)
	self.pitch = cfg.BasePitchDeg
	self.distance = cfg.Modes[self.mode].Distance
	self.focusY = nil
	self.active = false
	self.snapNext = true
	self.params = RaycastParams.new()
	self.params.FilterType = Enum.RaycastFilterType.Exclude
	self.params.IgnoreWater = true
	self.ModeChanged = Utility.Signal.new()
	self.fovTarget = cfg.FieldOfView
	self.fov = cfg.FieldOfView
	self.lookYaw = 0 -- degrees, positive = look right
	self.lookPitch = 0 -- degrees added to the chase pitch, positive = camera higher, looking down
	self.lookHeld = false
	self.lookIdle = math.huge

	self.maid:Give(workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
		self.camera = workspace.CurrentCamera
		if self.active then
			self:_takeControl()
		end
	end))
	return self
end

function CameraController:_takeControl()
	local camera = self.camera
	if not camera then
		return
	end
	camera.CameraType = Enum.CameraType.Scriptable
	camera.FieldOfView = GameConfig.Camera.FieldOfView
end

function CameraController:Bind(ball, route, ignoreInstances)
	self.ball = ball
	self.route = route
	self.params.FilterDescendantsInstances = ignoreInstances or {}
	self.active = true
	self.snapNext = true
	self:ResetLook()
	self:_takeControl()
	if self.camera then
		self.camera.CameraSubject = ball
	end
end

-- Keep the last view while there is no marble (e.g. between a fall and the respawn).
function CameraController:Unbind()
	self.ball = nil
end

-- A3: boost FOV pulse (70 -> up to 82). The caller passes the base FOV under Reduced Motion.
function CameraController:SetFovTarget(fov)
	self.fovTarget = math.clamp(fov, 60, 82)
end

-- Free look -------------------------------------------------------------------------------
local function wrapDeg(angle)
	return (angle + 180) % 360 - 180
end

function CameraController:AddLook(yawDeg, pitchDeg)
	local look = GameConfig.Camera.FreeLook
	self.lookYaw = wrapDeg(self.lookYaw + yawDeg)
	-- keep the total pitch inside the free-look limits, whatever the chase pitch is right now
	local total = Utility.clamp(self.pitch + self.lookPitch + pitchDeg, look.MinPitchDeg, look.MaxPitchDeg)
	self.lookPitch = total - self.pitch
	self.lookIdle = 0
end

-- A finger, the right mouse button or the right stick is currently looking (no return yet).
function CameraController:SetLookHeld(held)
	self.lookHeld = held
	self.lookIdle = 0
end

function CameraController:ResetLook()
	self.lookYaw = 0
	self.lookPitch = 0
	self.lookIdle = math.huge
end

function CameraController:IsLooking()
	return math.abs(self.lookYaw) > 0.5 or math.abs(self.lookPitch) > 0.5
end

function CameraController:GetMode()
	return self.mode
end

function CameraController:ToggleMode()
	self.mode = self.mode == "Chase" and "Wide" or "Chase"
	self.ModeChanged:Fire(self.mode)
	return self.mode
end

function CameraController:Step(dt, progressS)
	if not self.active then
		return
	end
	local camera = self.camera
	local ball = self.ball
	if not camera or not ball or not ball.Parent or not self.route then
		return
	end
	if camera.CameraType ~= Enum.CameraType.Scriptable then
		self:_takeControl()
	end

	local cfg = GameConfig.Camera
	local modeCfg = cfg.Modes[self.mode]
	local route = self.route
	local position = ball.Position
	local s = progressS or 0

	local snap = self.snapNext
	if self.lastBallPosition and (position - self.lastBallPosition).Magnitude > cfg.SnapDistance then
		snap = true
	end
	self.snapNext = false
	self.lastBallPosition = position

	local targetHeading = RouteTracker.SmoothHorizontalTangentAtS(route, s + cfg.HeadingLookAheadStuds, cfg.HeadingSmoothingStuds)
		or self.heading
	local ahead = RouteTracker.PointAtS(route, s + cfg.LookAheadStuds)
	local delta = ahead - position
	local horizontal = math.max(1, Vector3.new(delta.X, 0, delta.Z).Magnitude)
	local dropDeg = math.deg(math.atan2(-delta.Y, horizontal))
	local targetPitch = Utility.clamp(cfg.BasePitchDeg + modeCfg.PitchOffsetDeg + dropDeg * cfg.DropPitchGain, cfg.MinPitchDeg, cfg.MaxPitchDeg)

	if snap or not self.focusY then
		self.heading = targetHeading
		self.pitch = targetPitch
		self.focusY = position.Y
	else
		local turned = Utility.turnToward(self.heading, targetHeading, Utility.expAlpha(cfg.HeadingResponse, dt), UP)
		self.heading = Utility.safeUnit(Vector3.new(turned.X, 0, turned.Z), self.heading)
		self.pitch = Utility.lerp(self.pitch, targetPitch, Utility.expAlpha(cfg.PitchResponse, dt))
		self.focusY = Utility.lerp(self.focusY, position.Y, Utility.expAlpha(cfg.FocusVerticalResponse, dt))
	end

	-- free look: ease back behind the marble once nobody has looked for ReturnDelaySeconds
	local look = cfg.FreeLook
	if self.lookHeld then
		self.lookIdle = 0
	else
		self.lookIdle = self.lookIdle + dt
		if self.lookIdle >= look.ReturnDelaySeconds then
			local alpha = Utility.expAlpha(look.ReturnResponse, dt)
			self.lookYaw = Utility.lerp(self.lookYaw, 0, alpha)
			self.lookPitch = Utility.lerp(self.lookPitch, 0, alpha)
			if math.abs(self.lookYaw) < 0.05 and math.abs(self.lookPitch) < 0.05 then
				self.lookYaw, self.lookPitch = 0, 0
			end
		end
	end
	local viewHeading = self.heading
	if self.lookYaw ~= 0 then
		-- Ry(-yaw): positive yaw turns the view to the right (heading -Z -> +X at 90 degrees)
		viewHeading = CFrame.Angles(0, -math.rad(self.lookYaw), 0):VectorToWorldSpace(self.heading)
	end
	local viewPitch = self.pitch
	if self.lookPitch ~= 0 then
		viewPitch = Utility.clamp(self.pitch + self.lookPitch, look.MinPitchDeg, look.MaxPitchDeg)
	end

	local focus = Vector3.new(position.X, self.focusY + cfg.FocusHeight, position.Z)
	local pitchRad = math.rad(viewPitch)
	local offsetDir = (-viewHeading * math.cos(pitchRad)) + UP * math.sin(pitchRad)

	local desired = modeCfg.Distance
	local allowed = desired
	local hit = workspace:Raycast(focus, offsetDir * (desired + cfg.ObstructionPadding), self.params)
	if hit then
		allowed = math.max(cfg.MinDistance, hit.Distance - cfg.ObstructionPadding)
	end
	if snap then
		self.distance = allowed
	elseif allowed < self.distance then
		self.distance = Utility.lerp(self.distance, allowed, Utility.expAlpha(cfg.ZoomInResponse, dt))
	else
		self.distance = Utility.lerp(self.distance, allowed, Utility.expAlpha(cfg.ZoomOutResponse, dt))
	end

	local cameraPosition = focus + offsetDir * self.distance
	local aim = focus + viewHeading * cfg.AimAheadStuds
	self.fov = Utility.lerp(self.fov, self.fovTarget, Utility.expAlpha(6, dt))
	camera.FieldOfView = self.fov
	camera.CFrame = CFrame.lookAt(cameraPosition, aim, UP)
	camera.Focus = CFrame.new(focus)
end

function CameraController:Destroy()
	self.active = false
	self.maid:Cleanup()
	local camera = workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Custom
	end
end

return CameraController
