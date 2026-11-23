--[[
	MarbleCharacterService — the marble/avatar lifecycle (ADR-05). One architecture, decided here:

	* No Roblox Character, no Humanoid. Players.CharacterAutoLoads = false and any character that
	  appears anyway is removed, so there is never a second (invisible) collision body.
	* The player's only physical body is ONE Ball part, radius 2 ("BallRoot"), named
	  Marble_<UserId> with attribute OwnerUserId, in Workspace.TumbleMarbles. Cosmetic stripes are
	  welded, massless and have collision/query/touch disabled — same hitbox and mass always.
	* Identity = the Player object + that name/attribute. (Nameplates arrive with multiplayer in A2.)
	* Every spawn creates a FRESH ball at the server-chosen start spawn and destroys the old one.
	  That makes reset, fall recovery, rejoin and "Try Again" one code path, with no CFrame writes
	  to a client-owned part and no ownership races. The ball is never moved per frame by scripts.
	* Network ownership goes to the player (A1 authority decision: conventional client ownership;
	  see README). The client can only *request* a reset; it never chooses a position.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local PhysicsConfig = require(Shared:WaitForChild("PhysicsConfig"))
local Protocol = require(Shared:WaitForChild("Protocol"))
local Utility = require(Shared:WaitForChild("Utility"))

local MarbleCharacterService = {}
MarbleCharacterService.__index = MarbleCharacterService

local ATTR = Protocol.PlayerAttributes

function MarbleCharacterService.new(trackService)
	local self = setmetatable({}, MarbleCharacterService)
	self.track = trackService
	self.players = {}
	self.maid = Utility.Maid.new()
	self.resetLimiter = Utility.RateLimiter.new(GameConfig.Spawn.ResetCooldownSeconds)
	self.MarbleSpawned = Utility.Signal.new() -- (player, ball, reason)
	self.MarbleRemoved = Utility.Signal.new() -- (player)
	return self
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

local function createBall(player, cframe)
	local cfg = PhysicsConfig.Ball
	local palette = GameConfig.Palette
	local diameter = cfg.Radius * 2

	local ball = Instance.new("Part")
	ball.Name = Protocol.MarbleName(player.UserId)
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.new(diameter, diameter, diameter)
	ball.Material = Enum.Material.SmoothPlastic
	ball.Color = palette.Cyan
	ball.Reflectance = 0.2 -- glossy
	ball.TopSurface = Enum.SurfaceType.Smooth
	ball.BottomSurface = Enum.SurfaceType.Smooth
	ball.CustomPhysicalProperties = PhysicalProperties.new(cfg.Density, cfg.Friction, cfg.Elasticity, cfg.FrictionWeight, cfg.ElasticityWeight)
	ball.CanCollide = true
	ball.CanTouch = false -- A1 uses no Touched events
	ball.CanQuery = true
	ball.RootPriority = 10
	ball.CFrame = cframe
	ball:SetAttribute("OwnerUserId", player.UserId)
	ball:SetAttribute("BallRoot", true)

	-- Two thin stripe discs (equator + meridian) poking 0.04 studs out of the surface so the
	-- roll is readable. A plain sphere spinning looks motionless.
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
	return ball
end

function MarbleCharacterService:Start(remotesFolder)
	Players.CharacterAutoLoads = false

	local folder = workspace:FindFirstChild(Protocol.MarblesFolderName)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = Protocol.MarblesFolderName
		folder.Parent = workspace
	end
	self.folder = folder

	local resetRemote = remotesFolder:WaitForChild(Protocol.Remotes.RequestReset)
	self.maid:Give(resetRemote.OnServerEvent:Connect(function(player)
		-- No payload is read: the client cannot choose where it respawns.
		self:_onResetRequest(player)
	end))

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
		player.DevEnableMouseLock = false -- Shift is Brake, not shift-lock
	end)
	-- We never use a Character. If one exists or appears (e.g. CharacterAutoLoads was on when
	-- the player joined, or another script calls LoadCharacter), remove it.
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

	self:SpawnMarble(player, Protocol.SpawnReasons.Join)
end

function MarbleCharacterService:_onPlayerRemoving(player)
	local state = self.players[player]
	if not state then
		return
	end
	state.removed = true
	self:_destroyBall(player, state)
	state.maid:Cleanup()
	self.players[player] = nil
	self.resetLimiter:Forget(player)
end

function MarbleCharacterService:_onResetRequest(player)
	local state = self.players[player]
	if not state or state.removed then
		return
	end
	if not self.resetLimiter:Try(player) then
		return
	end
	self:SpawnMarble(player, Protocol.SpawnReasons.Reset)
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

function MarbleCharacterService:SpawnMarble(player, reason)
	local state = self.players[player]
	if not state or state.removed or not player.Parent then
		return nil
	end
	state.generation = state.generation + 1
	state.pendingRespawn = false
	self:_destroyBall(player, state)

	local ball = createBall(player, self.track:GetSpawnCFrame())
	ball.Parent = self.folder
	local ok, err = pcall(function()
		ball:SetNetworkOwner(player)
	end)
	if not ok then
		warn("[Marble] SetNetworkOwner failed for " .. player.Name .. ": " .. tostring(err))
	end
	pcall(function()
		player.ReplicationFocus = ball -- keeps streaming centred on the marble if streaming is on
	end)

	state.ball = ball
	state.ballConnection = ball.AncestryChanged:Connect(function()
		if state.ball == ball and not ball:IsDescendantOf(workspace) then
			-- Removed by something other than us (e.g. FallenPartsDestroyHeight).
			state.ball = nil
			self.MarbleRemoved:Fire(player)
			self:ScheduleRespawn(player, Protocol.SpawnReasons.Lost, GameConfig.Spawn.FallRespawnDelaySeconds)
		end
	end)

	state.spawnCount = state.spawnCount + 1
	player:SetAttribute(ATTR.SpawnCount, state.spawnCount)
	player:SetAttribute(ATTR.LastSpawnReason, reason)
	self.MarbleSpawned:Fire(player, ball, reason)
	return ball
end

-- Delayed respawn that cannot double-fire: superseded by any newer spawn (generation check).
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

function MarbleCharacterService:IsRespawnPending(player)
	local state = self.players[player]
	return state ~= nil and state.pendingRespawn
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
