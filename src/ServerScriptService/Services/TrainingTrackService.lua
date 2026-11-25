--[[
	TrainingTrackService — builds and owns every course (A2, A4):
	  zone "Race": TrackDefinitions.Race = the Neon Foundry (A4, 16 modules, checkpoints, grid,
	               start gate, hazards, Chaos Gates); validated by TrackValidator before use
	  zone "Hub" : the Orbital Garage platform + Practice Chute
	Both are built ONCE at boot and reused every round (only the start gate toggles).
	Exposes layouts, spawn CFrames, kill heights and the gate to the other services.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local PhysicsConfig = require(Shared:WaitForChild("PhysicsConfig"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local TrackDefinitions = require(Shared:WaitForChild("TrackDefinitions"))
local Builders = ServerStorage:WaitForChild("ProceduralBuilders")
local Builder = require(Builders:WaitForChild("TrainingTrackBuilder"))
local HubBuilder = require(Builders:WaitForChild("HubBuilder"))
local TrackValidator = require(script.Parent:WaitForChild("TrackValidator"))

local TrainingTrackService = {}
TrainingTrackService.__index = TrainingTrackService

local ZONES = Protocol.Zones

function TrainingTrackService.new()
	local self = setmetatable({}, TrainingTrackService)
	self.layouts = {}
	self.killY = {}
	self.validationErrors = {}
	return self
end

function TrainingTrackService:ApplyEnvironment()
	local palette = GameConfig.Palette
	if PhysicsConfig.GravityMultiplier ~= 1 then
		workspace.Gravity = 196.2 * PhysicsConfig.GravityMultiplier
	end
	Lighting.ClockTime = 0
	Lighting.Brightness = 2
	Lighting.Ambient = Color3.fromRGB(46, 56, 96)
	Lighting.OutdoorAmbient = Color3.fromRGB(70, 82, 130)
	Lighting.EnvironmentDiffuseScale = 0.4
	Lighting.EnvironmentSpecularScale = 1
	Lighting.FogColor = palette.Navy
	Lighting.FogStart = 300
	Lighting.FogEnd = 1600
	local bloom = Lighting:FindFirstChild("TC_Bloom") or Instance.new("BloomEffect")
	bloom.Name = "TC_Bloom"
	bloom.Intensity = 0.7
	bloom.Size = 24
	bloom.Threshold = 1.4
	bloom.Parent = Lighting
	local grade = Lighting:FindFirstChild("TC_Grade") or Instance.new("ColorCorrectionEffect")
	grade.Name = "TC_Grade"
	grade.Contrast = 0.08
	grade.Saturation = 0.12
	grade.Parent = Lighting
end

local function validate(self, def, layout, full)
	local errors = full and TrackValidator.Validate(def, layout) or TrackDefinitions.Validate(def, layout)
	for _, message in ipairs(errors) do
		table.insert(self.validationErrors, def.Id .. ": " .. message)
		warn("[Track] validation " .. def.Id .. ": " .. message)
	end
end

function TrainingTrackService:Build()
	local radius = PhysicsConfig.Ball.Radius
	local started = os.clock()
	for _, name in ipairs({ Protocol.CourseModelName, Protocol.HubModelName }) do
		local existing = workspace:FindFirstChild(name)
		if existing then
			existing:Destroy()
		end
	end

	-- Race track
	local raceDef = TrackDefinitions.Race
	local race = TrackDefinitions.Generate(raceDef, radius)
	validate(self, raceDef, race, true)
	local raceRoot, raceCount = Builder.Build(race, workspace, Protocol.CourseModelName)
	self.layouts[ZONES.Race] = race
	self.raceRoot = raceRoot
	self.killY[ZONES.Race] = race.MinY - PhysicsConfig.Server.KillDepthBelowCourse
	self.startGate = raceRoot:FindFirstChild("Gates") and raceRoot.Gates:FindFirstChild("StartGate")

	-- Hub + practice chute
	local hub = TrackDefinitions.Hub
	local chuteDef = TrackDefinitions.PracticeChute
	local chute = TrackDefinitions.Generate(chuteDef, radius)
	validate(self, chuteDef, chute)
	local hubRoot, hubCount = HubBuilder.Build(hub, workspace, Protocol.HubModelName, chuteDef.Pieces[1].Width[1], Builder.MakePart)
	local _, chuteCount = Builder.Build(chute, hubRoot, "PracticeChute")
	self.layouts[ZONES.Hub] = chute
	self.hubRoot = hubRoot
	self.hubSpawns = HubBuilder.SpawnCFrames(hub, radius, GameConfig.Spawn.SpawnLift)
	self.hubSpawnCursor = 0
	self.killY[ZONES.Hub] = math.min(hub.Center.Y, chute.MinY) - PhysicsConfig.Server.KillDepthBelowCourse

	if #self.validationErrors > 0 then
		workspace:SetAttribute(Protocol.WorkspaceAttributes.CourseError, table.concat(self.validationErrors, "; "))
	end
	workspace:SetAttribute(Protocol.WorkspaceAttributes.CourseReady, true)
	print(string.format(
		"[Track] built race %s (%d parts, %.0f studs, %d checkpoints) + hub (%d parts) + chute (%d parts) in %.1f ms",
		raceDef.Id, raceCount, race.Route.total, #race.Checkpoints, hubCount, chuteCount, (os.clock() - started) * 1000
	))
end

function TrainingTrackService:GetLayout(zone)
	return self.layouts[zone or ZONES.Race]
end

function TrainingTrackService:GetKillY(zone)
	return self.killY[zone or ZONES.Race]
end

function TrainingTrackService:GetRaceRoot()
	return self.raceRoot
end

local function frameToCFrame(frame, lateral)
	local radius = PhysicsConfig.Ball.Radius
	local position = frame.Position + frame.Right * (lateral or 0) + frame.Up * (radius + GameConfig.Spawn.SpawnLift)
	return CFrame.fromMatrix(position, frame.Right, frame.Up)
end

-- Hub spawns rotate through the ring so simultaneous arrivals do not stack.
function TrainingTrackService:NextHubSpawnCFrame()
	self.hubSpawnCursor = self.hubSpawnCursor % #self.hubSpawns + 1
	return self.hubSpawns[self.hubSpawnCursor]
end

function TrainingTrackService:GetGridSlotCount()
	return #self.layouts[ZONES.Race].GridSlots
end

function TrainingTrackService:GetGridCFrame(slotIndex)
	local slots = self.layouts[ZONES.Race].GridSlots
	local slot = slots[((slotIndex - 1) % #slots) + 1]
	return frameToCFrame(slot.Frame, slot.Offset)
end

function TrainingTrackService:GetCheckpointRespawnCFrame(index)
	local cp = self.layouts[ZONES.Race].Checkpoints[index]
	return cp and frameToCFrame(cp.RespawnFrame, 0)
end

function TrainingTrackService:GetFinishRespawnCFrame()
	local layout = self.layouts[ZONES.Race]
	local frame = TrackDefinitions.SampleAtH(layout, layout.FinishLineFrame.H + 10)
	return frameToCFrame(frame, 0)
end

function TrainingTrackService:SetStartGateClosed(closed)
	local gate = self.startGate
	if not gate then
		return
	end
	gate.CanCollide = closed
	gate.CanQuery = closed
	gate.Transparency = closed and 0.35 or 1
end

function TrainingTrackService:GetValidationErrors()
	return self.validationErrors
end

return TrainingTrackService
