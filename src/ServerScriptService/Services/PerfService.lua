--[[
	PerfService (A4) — server instrumentation for the bot/hazard load (master: profile with 1, 3
	and 8 bots before claiming anything). Every 2 s it publishes workspace attributes the F2 perf
	overlay shows on every client:
	  Perf_ServerFrameAvgMs / Perf_ServerFrameP95Ms   Heartbeat-to-Heartbeat time
	  Perf_PhysicsStepMs, Perf_HeartbeatMs            engine Stats (pcall: may be unavailable)
	  Perf_MovingParts, Perf_Instances, Perf_MemoryMb, Perf_SendKbps
	  Perf_Marbles, Perf_Bots, Perf_CourseParts
	These are measurements of whatever machine runs the server (Studio = your PC). They are NOT
	a device frame-rate claim; client FPS is shown separately by the client overlay.
]]

local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Protocol = require(Shared:WaitForChild("Protocol"))
local Utility = require(Shared:WaitForChild("Utility"))

local PerfService = {}
PerfService.__index = PerfService

PerfService.WindowSeconds = 2

-- Pure: average and 95th percentile of a list of frame times (seconds -> ms).
function PerfService.Summarize(samples)
	local n = #samples
	if n == 0 then
		return 0, 0
	end
	local sorted, total = {}, 0
	for i, dt in ipairs(samples) do
		sorted[i] = dt
		total = total + dt
	end
	table.sort(sorted)
	local index = math.max(1, math.ceil(n * 0.95))
	return total / n * 1000, sorted[index] * 1000
end

function PerfService.new(deps)
	local self = setmetatable({}, PerfService)
	self.track = deps.track
	self.bots = deps.bots
	self.maid = Utility.Maid.new()
	self.samples = {}
	return self
end

local function stat(name)
	local ok, value = pcall(function()
		return game:GetService("Stats")[name]
	end)
	return ok and type(value) == "number" and value or -1
end

function PerfService:Start()
	local root = self.track:GetRaceRoot()
	local courseParts = 0
	for _, d in ipairs(root and root:GetDescendants() or {}) do
		if d:IsA("BasePart") then
			courseParts = courseParts + 1
		end
	end
	workspace:SetAttribute("Perf_CourseParts", courseParts)
	local folder = workspace:FindFirstChild(Protocol.MarblesFolderName) -- made by MarbleCharacterService.new
	assert(folder, "[Perf] marbles folder missing: MarbleCharacterService.new must run first")
	local elapsed = 0
	self.maid:Give(RunService.Heartbeat:Connect(function(dt)
		self.samples[#self.samples + 1] = dt
		elapsed = elapsed + dt
		if elapsed < PerfService.WindowSeconds then
			return
		end
		elapsed = 0
		local avg, p95 = PerfService.Summarize(self.samples)
		self.samples = {}
		workspace:SetAttribute("Perf_ServerFrameAvgMs", math.floor(avg * 10 + 0.5) / 10)
		workspace:SetAttribute("Perf_ServerFrameP95Ms", math.floor(p95 * 10 + 0.5) / 10)
		workspace:SetAttribute("Perf_PhysicsStepMs", stat("PhysicsStepTimeMs"))
		workspace:SetAttribute("Perf_HeartbeatMs", stat("HeartbeatTimeMs"))
		workspace:SetAttribute("Perf_MovingParts", stat("MovingPrimitivesCount"))
		workspace:SetAttribute("Perf_Instances", stat("InstanceCount"))
		workspace:SetAttribute("Perf_SendKbps", stat("DataSendKbps"))
		local okMem, mem = pcall(function()
			return game:GetService("Stats"):GetTotalMemoryUsageMb()
		end)
		workspace:SetAttribute("Perf_MemoryMb", okMem and math.floor(mem) or -1)
		workspace:SetAttribute("Perf_Marbles", #folder:GetChildren())
		workspace:SetAttribute("Perf_Bots", self.bots and self.bots:Count() or 0)
	end))
end

function PerfService:Destroy()
	self.maid:Cleanup()
end

return PerfService
