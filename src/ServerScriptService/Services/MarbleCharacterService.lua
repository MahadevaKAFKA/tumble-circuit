--[[
	MarbleCharacterService — the marble/avatar lifecycle (ADR-05), A2 edition.

	* No Roblox Character / Humanoid. One Ball part (radius 2, "BallRoot") per player named
	  Marble_<UserId>; welded stripes are massless and non-colliding. Identity = Player + name +
	  OwnerUserId attribute.
	* Every spawn creates a FRESH ball. WHERE it spawns is decided by a server-side resolver
	  (RoundService): hub ring, start grid (frozen), last confirmed checkpoint, or finish basin.
	  The client can only request recovery; it never supplies a position.
	* Frozen spawns are Anchored (no ownership, cannot move) until Release() at GO, which unanchors
	  and hands network ownership to the player.
	* Every spawn is protected for RaceConfig.Recovery.ProtectionSeconds: collision group
	  TC_Protected does not collide with marbles (spawn shoving / chain bumps), then TC_Marble.
	* Network ownership: client (A1/A2 authority decision, see BUILD_STATUS).
]]

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local PhysicsConfig = require(Shared:WaitForChild("PhysicsConfig"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local RaceConfig = require(Shared:WaitForChild("RaceConfig"))
local Utility = require(Shared:WaitForChild("Utility"))
local BotFactory = require(ServerStorage:WaitForChild("ProceduralBuilders"):WaitForChild("BotFactory"))

local MarbleCharacterService = {}
MarbleCharacterService.__index = MarbleCharacterService

local ATTR = Protocol.PlayerAttributes
local BALL = Protocol.BallAttributes
local GROUPS = RaceConfig.Collisions

function MarbleCharacterService.SetupCollisionGroups()
	for _, name in ipairs({ GROUPS.MarbleGroup, GROUPS.ProtectedGroup }) do
		local ok, registered = pcall(function()
			return PhysicsService:IsCollisionGroupRegistered(name)
		end)
		if not (ok and registered) then
			PhysicsService:RegisterCollisionGroup(name)
		end
	end
	PhysicsService:CollisionGroupSetCollidable(GROUPS.MarbleGroup, GROUPS.MarbleGroup, true)
	PhysicsService:CollisionGroupSetCollidable(GROUPS.ProtectedGroup, GROUPS.MarbleGroup, false)
	PhysicsService:CollisionGroupSetCollidable(GROUPS.ProtectedGroup, GROUPS.ProtectedGroup, false)
end

function MarbleCharacterService.new(trackService)
	local self = setmetatable({}, MarbleCharacterService)
	self.track = trackService
	self.players = {}
	self.maid = Utility.Maid.new()
	self.resolveSpawn = nil
	self.MarbleSpawned = Utility.Signal.new() -- (player, ball, reason, zone)
	self.MarbleRemoved = Utility.Signal.new() -- (player)
	self.PlayerJoined = Utility.Signal.new() -- (player)
	self.PlayerLeaving = Utility.Signal.new() -- (player)
	-- The marbles folder exists from construction, so services started before this one (A3's
	-- MicroSkillService filters its line-of-sight raycasts by it) never wait for Start().
	-- Owner playtest 2026-11-25: waiting for it here deadlocked server start-up.
	self.folder = MarbleCharacterService._ensureFolder()
	return self
end

function MarbleCharacterService._ensureFolder()
	local folder = workspace:FindFirstChild(Protocol.MarblesFolderName)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = Protocol.MarblesFolderName
		folder.Parent = workspace
	end
	return folder
end

-- resolver(player, reason) -> { CFrame = CFrame, Zone = string, Frozen = bool }
function MarbleCharacterService:SetSpawnResolver(resolver)
	self.resolveSpawn = resolver
end

local function weldVisual(ball, part)
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
	part.CFrame = ball.CFrame * part.CFrame
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = ball
	weld.Part1 = part
	weld.Parent = part
	part.Parent = ball
end

local function createBall(player, cframe, zone, frozen)
	local cfg = PhysicsConfig.Ball
	local palette = GameConfig.Palette
	local diameter = cfg.Radius * 2
	local ball = Instance.new("Part")
	ball.Name = Protocol.MarbleName(player.UserId)
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.new(diameter, diameter, diameter)
	ball.Material = Enum.Material.SmoothPlastic
	ball.Color = palette.Cyan
	ball.Reflectance = 0.2
	ball.TopSurface = Enum.SurfaceType.Smooth
	ball.BottomSurface = Enum.SurfaceType.Smooth
	ball.CustomPhysicalProperties = PhysicalProperties.new(cfg.Density, cfg.Friction, cfg.Elasticity, cfg.FrictionWeight, cfg.ElasticityWeight)
	ball.CanCollide = true
	ball.CanTouch = false
	ball.CanQuery = true
	ball.RootPriority = 10
	ball.Anchored = frozen
	ball.CollisionGroup = GROUPS.ProtectedGroup
	ball.Transparency = 0.35 -- protected look; restored when protection ends
	ball.CFrame = cframe
	ball:SetAttribute(BALL.OwnerUserId, player.UserId)
	ball:SetAttribute(BALL.Zone, zone)
	ball:SetAttribute(BALL.Protected, true)
	ball:SetAttribute(BALL.Frozen, frozen)
	ball:SetAttribute("BallRoot", true)
	for i, axisTurn in ipairs({ CFrame.new(), CFrame.Angles(0, math.pi / 2, 0) }) do
		local stripe = Instance.new("Part")
		stripe.Name = "Stripe" .. i
		stripe.Shape = Enum.PartType.Cylinder
		stripe.Size = Vector3.new(0.55, diameter + 0.08, diameter + 0.08)
		stripe.Material = Enum.Material.Neon
		stripe.Color = i == 1 and palette.Coral or palette.Yellow
		stripe.CFrame = axisTurn
		weldVisual(ball, stripe)
	end
	local plate = BotFactory.AddNameplate(ball, player.DisplayName, palette.White)
	-- Your own name never floats in front of your chase camera. Hidden by the engine for the owner
	-- (owner playtest 2026-11-25: the client-side hide missed and the name sat mid-screen).
	plate.PlayerToHideFrom = player
	return ball
end

function MarbleCharacterService:Start()
	Players.CharacterAutoLoads = false
	MarbleCharacterService.SetupCollisionGroups()
	self.folder = MarbleCharacterService._ensureFolder()
	self.maid:Give(Players.PlayerAdded:Connect(function(player)
		self:_onPlayerAdded(player)
	end))
	self.maid:Give(Players.PlayerRemoving:Connect(function(player)
		self:_onPlayerRemoving(player)
	end))
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(self._onPlayerAdded, self, player)
	end
end

function MarbleCharacterService:_onPlayerAdded(player)
	if self.players[player] then
		return
	end
	local state = { ball = nil, generation = 0, spawnCount = 0, pendingRespawn = false, removed = false, maid = Utility.Maid.new() }
	self.players[player] = state
	pcall(function()
		player.DevEnableMouseLock = false
	end)
	local function removeCharacter(character)
		task.defer(function()
			if character and character.Parent then
				warn("[Marble] removing unexpected Character for " .. player.Name .. " (marble avatar only)")
				character:Destroy()
			end
		end)
	end
	if player.Character then
		removeCharacter(player.Character)
	end
	state.maid:Give(player.CharacterAdded:Connect(removeCharacter))
	self.PlayerJoined:Fire(player)
	self:SpawnMarble(player, Protocol.SpawnReasons.Join)
end

function MarbleCharacterService:_onPlayerRemoving(player)
	local state = self.players[player]
	if not state then
		return
	end
	self.PlayerLeaving:Fire(player)
	state.removed = true
	self:_destroyBall(player, state)
	state.maid:Cleanup()
	self.players[player] = nil
end

function MarbleCharacterService:_destroyBall(player, state)
	if state.ballConnection then
		state.ballConnection:Disconnect()
		state.ballConnection = nil
	end
	local old = state.ball
	state.ball = nil
	if old then
		old:Destroy()
		self.MarbleRemoved:Fire(player)
	end
end

function MarbleCharacterService:_resolve(player, reason)
	if self.resolveSpawn then
		local ok, result = pcall(self.resolveSpawn, player, reason)
		if ok and result and result.CFrame then
			return result
		end
		warn("[Marble] spawn resolver failed (" .. tostring(result) .. "); using hub")
	end
	return { CFrame = self.track:NextHubSpawnCFrame(), Zone = Protocol.Zones.Hub, Frozen = false }
end

function MarbleCharacterService:SpawnMarble(player, reason)
	local state = self.players[player]
	if not state or state.removed or not player.Parent then
		return nil
	end
	state.generation = state.generation + 1
	state.pendingRespawn = false
	self:_destroyBall(player, state)

	local spot = self:_resolve(player, reason)
	local frozen = spot.Frozen == true
	local ball = createBall(player, spot.CFrame, spot.Zone, frozen)
	ball.Parent = self.folder
	if not frozen then
		local ok, err = pcall(function()
			ball:SetNetworkOwner(player)
		end)
		if not ok then
			warn("[Marble] SetNetworkOwner failed for " .. player.Name .. ": " .. tostring(err))
		end
	end
	pcall(function()
		player.ReplicationFocus = ball
	end)

	state.ball = ball
	state.zone = spot.Zone
	state.ballConnection = ball.AncestryChanged:Connect(function()
		if state.ball == ball and not ball:IsDescendantOf(workspace) then
			state.ball = nil
			self.MarbleRemoved:Fire(player)
			self:ScheduleRespawn(player, Protocol.SpawnReasons.Lost, RaceConfig.Recovery.FallRespawnDelaySeconds)
		end
	end)

	-- Spawn protection (frozen grid balls stay protected until shortly after release).
	if not frozen then
		self:_scheduleProtectionEnd(player, ball, RaceConfig.Recovery.ProtectionSeconds)
	end

	state.spawnCount = state.spawnCount + 1
	player:SetAttribute(ATTR.SpawnCount, state.spawnCount)
	player:SetAttribute(ATTR.LastSpawnReason, reason)
	self.MarbleSpawned:Fire(player, ball, reason, spot.Zone)
	return ball
end

function MarbleCharacterService:_scheduleProtectionEnd(player, ball, seconds)
	task.delay(seconds, function()
		local state = self.players[player]
		if state and state.ball == ball and ball.Parent then
			ball.CollisionGroup = GROUPS.MarbleGroup
			ball.Transparency = 0
			ball:SetAttribute(BALL.Protected, false)
		end
	end)
end

-- GO: replace the frozen grid ball with a free one on the same slot, owned by its player from
-- the moment it exists (the spawn resolver returns the grid slot, unfrozen, once Racing).
-- Owner playtest 2026-11-23 (Roblox Android app): unanchoring the grid ball in place left the
-- marble unable to move until a manual reset, and a reset (a fresh, never-anchored ball on the
-- same slot) always worked. So GO now takes the reset path. Spawn protection applies as before.
function MarbleCharacterService:Release(player)
	local state = self.players[player]
	local ball = state and state.ball
	if not ball or not ball.Parent or not ball.Anchored then
		return false
	end
	return self:SpawnMarble(player, Protocol.SpawnReasons.Go) ~= nil
end

function MarbleCharacterService:ScheduleRespawn(player, reason, delaySeconds)
	local state = self.players[player]
	if not state or state.removed or state.pendingRespawn then
		return
	end
	state.pendingRespawn = true
	local generation = state.generation
	task.delay(delaySeconds, function()
		local current = self.players[player]
		if current == state and not state.removed and state.generation == generation then
			self:SpawnMarble(player, reason)
		end
	end)
end

function MarbleCharacterService:GetBall(player)
	local state = self.players[player]
	return state and state.ball
end

function MarbleCharacterService:GetZone(player)
	local state = self.players[player]
	return state and state.zone
end

function MarbleCharacterService:IsRespawnPending(player)
	local state = self.players[player]
	return state ~= nil and state.pendingRespawn
end

function MarbleCharacterService:GetPlayers()
	local out = {}
	for player in pairs(self.players) do
		out[#out + 1] = player
	end
	return out
end

function MarbleCharacterService:Destroy()
	self.maid:Cleanup()
	for player, state in pairs(self.players) do
		self:_destroyBall(player, state)
		state.maid:Cleanup()
	end
	self.players = {}
end

return MarbleCharacterService
