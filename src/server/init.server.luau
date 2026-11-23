-- Tumble Circuit: Chaos Drop — server entry point (Phase A1)
-- Builds the practice course, then spawns players as marbles.

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Characters are spawned by MarbleService once the course exists.
Players.CharacterAutoLoads = false

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Config"))
local CourseBuilder = require(script:WaitForChild("CourseBuilder"))
local CheckpointService = require(script:WaitForChild("CheckpointService"))
local MarbleService = require(script:WaitForChild("MarbleService"))

Lighting.ClockTime = 14.5
Lighting.Brightness = 2
Lighting.OutdoorAmbient = Color3.fromRGB(140, 150, 170)

local built, buildError = pcall(CourseBuilder.build)
if not built then
	warn("[TumbleCircuit] course build failed: " .. tostring(buildError))
end

CheckpointService.start()
MarbleService.start(CheckpointService)

print("[TumbleCircuit] server ready (" .. Config.Version .. ")")
