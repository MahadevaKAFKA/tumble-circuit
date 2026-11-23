--[[
	TrainingTrackService — builds and owns the A1 practice course.
	Generates the deterministic layout, validates it, builds parts, publishes CourseReady, and
	exposes spawn / kill height / layout to the other services. Also sets the night palette.
]]

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local PhysicsConfig = require(Shared:WaitForChild("PhysicsConfig"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local TrackDefinitions = require(Shared:WaitForChild("TrackDefinitions"))
local Builder = require(ServerStorage:WaitForChild("ProceduralBuilders"):WaitForChild("TrainingTrackBuilder"))

local TrainingTrackService = {}
TrainingTrackService.__index = TrainingTrackService

function TrainingTrackService.new()
	local self = setmetatable({}, TrainingTrackService)
	self.layout = nil
	self.root = nil
	self.validationErrors = {}
	return self
end

function TrainingTrackService:ApplyEnvironment()
	local palette = GameConfig.Palette
	if PhysicsConfig.GravityMultiplier ~= 1 then
		workspace.Gravity = 196.2 * PhysicsConfig.GravityMultiplier
	end
	Lighting.ClockTime = 0 -- night sky behind the neon course
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

function TrainingTrackService:Build()
	local def = TrackDefinitions.Training
	local radius = PhysicsConfig.Ball.Radius
	local layout = TrackDefinitions.Generate(def, radius)
	local errors = TrackDefinitions.Validate(def, layout)
	self.validationErrors = errors
	if #errors > 0 then
		for _, message in ipairs(errors) do
			warn("[TrainingTrack] validation: " .. message)
		end
		workspace:SetAttribute(Protocol.WorkspaceAttributes.CourseError, table.concat(errors, "; "))
	end

	local existing = workspace:FindFirstChild(Protocol.CourseModelName)
	if existing then
		existing:Destroy()
	end
	local started = os.clock()
	local root, count = Builder.Build(layout, workspace, Protocol.CourseModelName)
	self.layout = layout
	self.root = root

	local spawn = layout.SpawnFrame
	self.spawnCFrame = CFrame.fromMatrix(spawn.Position + spawn.Up * (radius + GameConfig.Spawn.SpawnLift), spawn.Right, spawn.Up)
	self.killY = layout.MinY - PhysicsConfig.Server.KillDepthBelowCourse

	workspace:SetAttribute(Protocol.WorkspaceAttributes.CourseReady, true)
	print(string.format(
		"[TrainingTrack] built %s: %d parts, route %.0f studs, %d validation issue(s), %.1f ms",
		def.Id,
		count,
		layout.Route.total,
		#errors,
		(os.clock() - started) * 1000
	))
	return root
end

function TrainingTrackService:GetLayout()
	return self.layout
end

function TrainingTrackService:GetRoot()
	return self.root
end

function TrainingTrackService:GetSpawnCFrame()
	return self.spawnCFrame
end

function TrainingTrackService:GetKillY()
	return self.killY
end

function TrainingTrackService:GetValidationErrors()
	return self.validationErrors
end

return TrainingTrackService
