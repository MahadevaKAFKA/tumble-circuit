--[[
	HazardController — the one A1 hazard: the Pulse Bumper.

	Its cycle is a pure function of workspace:GetServerTimeNow(), so every client sees the same
	state without any network traffic:
	  Idle      cyan            plain elastic bounce (physics only)
	  Telegraph cyan -> yellow  smooth 0.8 s colour ramp warning (no flashing)
	  Active    coral           touching it kicks the marble outward to KickSpeed (gentle, capped)

	The kick is applied by the local owner of the marble (client network ownership, A1). A2 must
	move any competitive consequence behind server checks (see BUILD_STATUS A2 notes).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local PhysicsConfig = require(Shared:WaitForChild("PhysicsConfig"))
local HazardTiming = require(Shared:WaitForChild("HazardTiming"))

local HazardController = {}
HazardController.__index = HazardController

-- Shared with the server's near-miss / shield judging (Shared/HazardTiming).
HazardController.PhaseAt = HazardTiming.PhaseAt

function HazardController.new(courseRoot, motor, sound)
	local self = setmetatable({}, HazardController)
	self.motor = motor
	self.sound = sound
	self.bumpers = {}
	local hazards = courseRoot:FindFirstChild("Hazards")
	if hazards then
		for _, folder in ipairs(hazards:GetChildren()) do
			local base = folder:FindFirstChild("Base")
			if base and base:GetAttribute("HazardType") == "PulseBumper" then
				local height = base:GetAttribute("Height") or base.Size.X
				local axis = base.CFrame.RightVector -- cylinder axis = local X = floor normal
				table.insert(self.bumpers, {
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
		end
	end
	return self
end

-- A3: while the local marble's server-confirmed Shield is up, the bumper kick is absorbed.
function HazardController:SetShieldQuery(fn)
	self.isShielded = fn
end

function HazardController:Step(ball)
	if #self.bumpers == 0 then
		return
	end
	local cfg = PhysicsConfig.Hazards.PulseBumper
	local palette = GameConfig.Palette
	local state, blend = HazardController.PhaseAt(workspace:GetServerTimeNow(), cfg)
	local key = state .. math.floor(blend * 20) -- colour only changes in 5% steps
	local color = palette.Cyan
	if state == "Telegraph" then
		color = palette.Cyan:Lerp(palette.Yellow, blend)
	elseif state == "Active" then
		color = palette.Coral
	end
	local ballRadius = PhysicsConfig.Ball.Radius
	local now = os.clock()

	for _, bumper in ipairs(self.bumpers) do
		if bumper.lastKey ~= key then
			bumper.lastKey = key
			bumper.base.Color = state == "Active" and palette.Coral or palette.Cyan
			if bumper.ring then
				bumper.ring.Color = color
			end
			if bumper.floorRing then
				bumper.floorRing.Color = color
			end
		end
		if ball and ball.Parent and state == "Active" and now >= bumper.cooldownUntil then
			local rel = ball.Position - bumper.floorPoint
			local along = rel:Dot(bumper.axis)
			if along > -1 and along < bumper.height + 1 then
				local radial = rel - bumper.axis * along
				local d = radial.Magnitude
				local shielded = self.isShielded and self.isShielded()
				if d > 1e-3 and d <= bumper.radius + ballRadius + cfg.ContactPadding and not shielded then
					if self.motor:ApplyKick(radial / d, cfg.KickSpeed) then
						bumper.cooldownUntil = now + cfg.CooldownSeconds
						self.sound:Play("BumperKick")
					end
				end
			end
		end
	end
end

return HazardController
