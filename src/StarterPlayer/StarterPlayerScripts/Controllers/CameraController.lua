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
	self:_takeControl()
	if self.camera then
		self.camera.CameraSubject = ball
	end
end

-- Keep the last view while there is no marble (e.g. between a fall and the respawn).
function CameraController:Unbind()
	self.ball = nil
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

	local focus = Vector3.new(position.X, self.focusY + cfg.FocusHeight, position.Z)
	local pitchRad = math.rad(self.pitch)
	local offsetDir = (-self.heading * math.cos(pitchRad)) + UP * math.sin(pitchRad)

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
	local aim = focus + self.heading * cfg.AimAheadStuds
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
