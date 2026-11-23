-- Tracks each player's checkpoint, run timer and best time.
-- State lives in Player attributes so the client HUD can read it directly:
--   Checkpoint (number), CheckpointCount (number), RunState ("Ready" | "Running" | "Finished"),
--   RunStartTime (server time), LastTime (seconds), BestTime (seconds, 0 = none yet)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("Config"))
local CourseData = require(Shared:WaitForChild("CourseData"))

local CheckpointService = {}

local RUN_READY = "Ready"
local RUN_RUNNING = "Running"
local RUN_FINISHED = "Finished"

-- [Player] = { seenInStart = boolean, lastRestart = number }
local runtime = {}

function CheckpointService.getMarble(player)
	local character = player.Character
	if not character then
		return nil
	end
	local ref = character:FindFirstChild("MarbleRef")
	if ref and ref:IsA("ObjectValue") then
		local marble = ref.Value
		if marble and marble:IsA("BasePart") and marble.Parent then
			return marble
		end
	end
	return nil
end

function CheckpointService.initPlayer(player)
	runtime[player] = { seenInStart = false, lastRestart = 0 }
	player:SetAttribute("Checkpoint", 1)
	player:SetAttribute("CheckpointCount", #CourseData.Checkpoints)
	player:SetAttribute("RunState", RUN_READY)
	player:SetAttribute("RunStartTime", 0)
	player:SetAttribute("LastTime", 0)
	player:SetAttribute("BestTime", 0)
end

function CheckpointService.getCheckpoint(player)
	local index = player:GetAttribute("Checkpoint")
	if type(index) ~= "number" or not CourseData.Checkpoints[index] then
		return 1
	end
	return index
end

-- Back to the start pad with a fresh timer. Progress is ignored until the
-- marble has been seen on the start pad again, so a late network update from
-- the old position cannot count as a checkpoint or start the timer early.
function CheckpointService.restart(player)
	local state = runtime[player]
	if not state then
		return false
	end
	local now = os.clock()
	if now - state.lastRestart < Config.Checkpoints.RestartCooldown then
		return false
	end
	state.lastRestart = now
	state.seenInStart = false
	player:SetAttribute("Checkpoint", 1)
	player:SetAttribute("RunState", RUN_READY)
	player:SetAttribute("RunStartTime", 0)
	return true
end

local function updatePlayer(player, state)
	local marble = CheckpointService.getMarble(player)
	if not marble then
		return
	end
	local position = marble.Position
	local start = CourseData.Checkpoints[1]
	local inStart = CourseData.isInZone(position, start.ZoneCenter, start.ZoneSize)

	if not state.seenInStart then
		if inStart then
			state.seenInStart = true
		end
		return
	end

	local runState = player:GetAttribute("RunState")
	if runState == RUN_READY and not inStart then
		runState = RUN_RUNNING
		player:SetAttribute("RunStartTime", Workspace:GetServerTimeNow())
		player:SetAttribute("RunState", RUN_RUNNING)
	end

	local current = CheckpointService.getCheckpoint(player)
	for index = current + 1, #CourseData.Checkpoints do
		local checkpoint = CourseData.Checkpoints[index]
		if CourseData.isInZone(position, checkpoint.ZoneCenter, checkpoint.ZoneSize) then
			player:SetAttribute("Checkpoint", index)
			break
		end
	end

	if runState == RUN_RUNNING and CourseData.isInZone(position, CourseData.Finish.ZoneCenter, CourseData.Finish.ZoneSize) then
		local startedAt = player:GetAttribute("RunStartTime")
		if type(startedAt) ~= "number" then
			startedAt = Workspace:GetServerTimeNow()
		end
		local elapsed = math.max(0, Workspace:GetServerTimeNow() - startedAt)
		player:SetAttribute("LastTime", elapsed)
		local best = player:GetAttribute("BestTime")
		if type(best) ~= "number" or best <= 0 or elapsed < best then
			player:SetAttribute("BestTime", elapsed)
		end
		player:SetAttribute("RunState", RUN_FINISHED)
	end
end

function CheckpointService.start()
	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed < Config.Checkpoints.PollInterval then
			return
		end
		elapsed = 0
		for player, state in pairs(runtime) do
			if player.Parent then
				local ok, err = pcall(updatePlayer, player, state)
				if not ok then
					warn("[TumbleCircuit] checkpoint update failed: " .. tostring(err))
				end
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		runtime[player] = nil
	end)
end

return CheckpointService
