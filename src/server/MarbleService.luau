-- Spawns each player as a marble.
-- The Roblox character is kept (it gives us the standard camera plus the
-- built-in touch thumbstick, jump button, keyboard and gamepad controls) but it
-- is hidden, made weightless and non-colliding, and pinned to the centre of a
-- physics ball that the player's client drives (see client/MarbleController).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local CourseData = require(Shared:WaitForChild("CourseData"))
local Remotes = ReplicatedStorage:WaitForChild("Remotes")

local MarbleService = {}

local checkpoints = nil -- CheckpointService, passed into start()
local lastReload = {} -- [Player] = os.clock() of the last watchdog reload

local function ghost(instance)
	if instance:GetAttribute("IsMarble") then
		return
	end
	if instance:IsA("BasePart") then
		instance.Transparency = 1
		instance.CanCollide = false
		instance.CanQuery = false
		instance.CanTouch = false
		instance.CastShadow = false
		instance.Massless = true
	elseif instance:IsA("Decal") or instance:IsA("Texture") then
		instance.Transparency = 1
	end
end

local function createMarble(spawnCFrame)
	local marbleSettings = Config.Marble
	local marble = Instance.new("Part")
	marble.Name = "Marble"
	marble:SetAttribute("IsMarble", true)
	marble.Shape = Enum.PartType.Ball
	marble.Size = Vector3.new(marbleSettings.Diameter, marbleSettings.Diameter, marbleSettings.Diameter)
	marble.Color = marbleSettings.Color
	marble.Material = marbleSettings.Material
	marble.TopSurface = Enum.SurfaceType.Smooth
	marble.BottomSurface = Enum.SurfaceType.Smooth
	marble.CustomPhysicalProperties = PhysicalProperties.new(
		marbleSettings.Density,
		marbleSettings.Friction,
		marbleSettings.Elasticity,
		marbleSettings.FrictionWeight,
		marbleSettings.ElasticityWeight
	)
	marble.CFrame = CFrame.new(spawnCFrame.Position)

	local center = Instance.new("Attachment")
	center.Name = "CenterAttachment"
	center.Parent = marble

	local drive = Instance.new("VectorForce")
	drive.Name = "DriveForce"
	drive.Attachment0 = center
	drive.RelativeTo = Enum.ActuatorRelativeTo.World
	drive.ApplyAtCenterOfMass = true
	drive.Force = Vector3.new(0, 0, 0)
	drive.Parent = marble

	return marble, center
end

local function spawnCharacter(player)
	if not player.Parent then
		return
	end
	-- A blank description gives a plain body with no accessories to download.
	local ok = pcall(function()
		player:LoadCharacterWithHumanoidDescription(Instance.new("HumanoidDescription"))
	end)
	if not ok then
		local fallbackOk, err = pcall(function()
			player:LoadCharacter()
		end)
		if not fallbackOk then
			warn("[TumbleCircuit] could not spawn " .. player.Name .. ": " .. tostring(err))
		end
	end
end
MarbleService.spawnCharacter = spawnCharacter

local function setupCharacter(player, character)
	local humanoid = character:WaitForChild("Humanoid", 10)
	local root = character:WaitForChild("HumanoidRootPart", 10)
	if not (humanoid and root) then
		warn("[TumbleCircuit] character for " .. player.Name .. " has no Humanoid/HumanoidRootPart")
		return
	end

	-- CharacterAdded can fire before the model is parented to the workspace.
	local deadline = os.clock() + 10
	while not character:IsDescendantOf(Workspace) do
		if os.clock() > deadline or player.Character ~= character then
			return
		end
		task.wait()
	end

	humanoid.WalkSpeed = 0
	humanoid.UseJumpPower = true
	humanoid.JumpPower = 50 -- keeps the mobile jump button visible; the marble does the jumping
	humanoid.AutoRotate = false
	humanoid.PlatformStand = true
	humanoid.RequiresNeck = false
	humanoid.BreakJointsOnDeath = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff

	for _, descendant in ipairs(character:GetDescendants()) do
		ghost(descendant)
	end
	character.DescendantAdded:Connect(ghost)

	local radius = Config.Marble.Diameter * 0.5
	local spawnCFrame = CourseData.getSpawnCFrame(checkpoints.getCheckpoint(player), radius)
	root.CFrame = spawnCFrame

	local marble, marbleCenter = createMarble(spawnCFrame)
	marble.Parent = character

	local follow = Instance.new("Attachment")
	follow.Name = "MarbleFollowAttachment"
	follow.Parent = root

	local align = Instance.new("AlignPosition")
	align.Name = "MarbleFollow"
	align.Mode = Enum.PositionAlignmentMode.TwoAttachment
	align.Attachment0 = follow
	align.Attachment1 = marbleCenter
	align.RigidityEnabled = true
	align.ReactionForceEnabled = false
	align.Parent = root

	local upright = Instance.new("AlignOrientation")
	upright.Name = "MarbleUpright"
	upright.Mode = Enum.OrientationAlignmentMode.OneAttachment
	upright.Attachment0 = follow
	upright.RigidityEnabled = true
	upright.CFrame = spawnCFrame - spawnCFrame.Position
	upright.Parent = root

	local ref = Instance.new("ObjectValue")
	ref.Name = "MarbleRef"
	ref.Value = marble
	ref.Parent = character

	-- The owning client simulates its own marble so controls feel instant.
	local ok, err = pcall(function()
		marble:SetNetworkOwner(player)
	end)
	if not ok then
		warn("[TumbleCircuit] could not give marble to " .. player.Name .. ": " .. tostring(err))
	end

	humanoid.Died:Connect(function()
		task.delay(Config.Respawn.DeathReloadDelay, function()
			if player.Parent and player.Character == character then
				spawnCharacter(player)
			end
		end)
	end)
end

local function watchdog()
	local now = os.clock()
	local floor = CourseData.KillY - Config.Respawn.ServerWatchdogDepth
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		if character and character:IsDescendantOf(Workspace) then
			local marble = checkpoints.getMarble(player)
			local lost = marble == nil and character:FindFirstChild("MarbleRef") ~= nil
			local tooLow = marble ~= nil and marble.Position.Y < floor
			if (lost or tooLow) and now - (lastReload[player] or 0) > 3 then
				lastReload[player] = now
				task.spawn(spawnCharacter, player)
			end
		end
	end
end

function MarbleService.start(checkpointService)
	checkpoints = checkpointService

	local function onPlayerAdded(player)
		checkpoints.initPlayer(player)
		player.CameraMinZoomDistance = Config.Camera.MinZoom
		player.CameraMaxZoomDistance = Config.Camera.MaxZoom
		player.CharacterAdded:Connect(function(character)
			setupCharacter(player, character)
		end)
		spawnCharacter(player)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(onPlayerAdded, player)
	end

	Players.PlayerRemoving:Connect(function(player)
		lastReload[player] = nil
	end)

	Remotes:WaitForChild("RestartRun").OnServerEvent:Connect(function(player)
		checkpoints.restart(player)
	end)

	local sinceCheck = 0
	RunService.Heartbeat:Connect(function(dt)
		sinceCheck += dt
		if sinceCheck >= 1 then
			sinceCheck = 0
			watchdog()
		end
	end)
end

return MarbleService
