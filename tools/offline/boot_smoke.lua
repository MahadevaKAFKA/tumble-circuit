--[[
	Boot smoke test (added 2026-11-26 after the v21-v26 loading hang): runs the MAIN CHUNK of
	ServerBootstrap and ClientBootstrap under Lua 5.3 with every Roblox API replaced by a
	permissive proxy. Our own logic runs for real; Roblox calls that need an argument (attribute
	names, FindFirstChild, Connect...) fail on nil like Roblox does ("Argument 1 missing or nil").
	It reproduces the owner's v26 error. It is NOT a Roblox runtime: property names, physics and
	events are not checked.  Usage: texlua tools/offline/boot_smoke.lua <root> <script path>
	Prints "MAIN CHUNK COMPLETED" or "ERROR: ..." and exits 0 / 1.
]]
local function run(root, target)

local shim = dofile(root .. "/tools/offline/roblox_shim.lua")
-- a private global table: the smoke run must not replace the datatypes other specs use
local G = setmetatable({}, { __index = _G })
local savedClamp, savedSign, savedRound = math.clamp, math.sign, math.round
shim.install(G)
math.clamp, math.sign, math.round = savedClamp or math.clamp, savedSign or math.sign, savedRound or math.round
local Vector3, Vector2 = G.Vector3, G.Vector2
local ATTRS = { TC_CourseReady = true, ProtocolVersion = nil, TC_ActiveWorld = "NeonFoundry_A4", TC_Features = "NewHubs", TC_Hub = "OrbitalGarage", TC_MapsEnabled = "NeonFoundry_A4,SkyCarnival_B1,VolcanoVault_B1" }
do -- the server stamps the protocol version on the remotes folder; read it from the source
  local f = assert(io.open(root .. "/src/ReplicatedStorage/Shared/RoundProtocol.lua"))
  ATTRS.ProtocolVersion = tonumber(f:read("*a"):match("RoundProtocol%.Version = (%d+)"))
  f:close()
end
local SPECIAL = {}
local PM = {}
local function proxy(name)
  return setmetatable({ __name = name, __store = {} }, PM)
end
G.__proxy = proxy
PM.__index = function(t, k)
  local store = rawget(t, "__store")
  local v = store[k]
  if v ~= nil then return v end
  if type(k) == "number" then return nil end
  local name = rawget(t, "__name") .. "." .. tostring(k)
  if SPECIAL[k] then v = SPECIAL[k](t) else v = proxy(name) end
  store[k] = v
  return v
end
PM.__newindex = function(t, k, v) rawget(t, "__store")[k] = v end
PM.__call = function(self, ...) return proxy(rawget(self, "__name") .. "()") end
for _, mm in ipairs({ "__add", "__sub", "__mul", "__div", "__mod", "__pow", "__unm", "__idiv" }) do
  PM[mm] = function() return proxy("arith") end
end
PM.__concat = function(a, b) return tostring(a) .. tostring(b) end
PM.__len = function() return 0 end
PM.__lt = function() return false end
PM.__le = function() return false end
PM.__tostring = function(t) return "<" .. rawget(t, "__name") .. ">" end
PM.__pairs = function() return function() return nil end, nil, nil end
local function needArg(method, a)
  if a == nil then error("Argument 1 missing or nil (" .. method .. ")", 3) end
end
SPECIAL.GetAttribute = function() return function(_, name) needArg("GetAttribute", name); return ATTRS[name] end end
SPECIAL.SetAttribute = function() return function(_, name, v) needArg("SetAttribute", name); ATTRS[name] = v end end
for _, m in ipairs({ "GetAttributeChangedSignal", "GetPropertyChangedSignal", "FindFirstChild", "WaitForChild", "Connect", "FindFirstChildOfClass", "FindFirstChildWhichIsA", "IsA", "FireClient" }) do
  if m ~= "IsA" then
    SPECIAL[m] = function(t) return function(_, a) needArg(m, a); return proxy(rawget(t, "__name") .. ":" .. m .. "()") end end
  end
end
SPECIAL.IsA = function() return function(_, a) needArg("IsA", a); return false end end
-- event replay: remember handlers so the client run can fire a round snapshot and render frames
local handlers = {}
SPECIAL.Connect = function(t) return function(_, fn)
  needArg("Connect", fn)
  local key = rawget(t, "__name")
  handlers[#handlers + 1] = { key = key, fn = fn }
  return proxy(key .. ":Connect()")
end end
local renderSteps = {}
SPECIAL.BindToRenderStep = function() return function(_, name, priority, fn)
  needArg("BindToRenderStep", name)
  renderSteps[#renderSteps + 1] = fn
end end
SPECIAL.GetChildren = function() return function() return {} end end
SPECIAL.GetDescendants = function() return function() return {} end end
SPECIAL.GetPlayers = function() return function() return {} end end
SPECIAL.IsA = function() return function() return false end end
SPECIAL.GetServerTimeNow = function() return function() return os.time() end end
SPECIAL.ViewportSize = function() return Vector2.new(1280, 720) end
SPECIAL.UserId = function() return 1 end
SPECIAL.Position = function() return Vector3.new(0, 302, 320) end
SPECIAL.AssemblyLinearVelocity = function() return Vector3.new(0, 0, 0) end
SPECIAL.Anchored = function() return false end
SPECIAL.AssemblyMass = function() return 10 end
SPECIAL.Mass = function() return 10 end
SPECIAL.Gravity = function() return 196.2 end
SPECIAL.AssemblyAngularVelocity = function() return Vector3.new(0, 0, 0) end
SPECIAL.Size = function() return Vector3.new(4, 4, 4) end
SPECIAL.Magnitude = function() return 0 end
SPECIAL.IsStudio = function() return function() return false end end
SPECIAL.TouchEnabled = function() return true end
SPECIAL.KeyboardEnabled = function() return false end
SPECIAL.GamepadEnabled = function() return false end
SPECIAL.MouseEnabled = function() return false end
SPECIAL.GetLastInputType = function() return function() return proxy("Enum.UserInputType.Touch") end end
-- file-backed instances (Rojo mapping) with proxy fallback
local dirs = { ReplicatedStorage = root .. "/src/ReplicatedStorage", ServerStorage = root .. "/src/ServerStorage", ServerScriptService = root .. "/src/ServerScriptService", StarterPlayer = root .. "/src/StarterPlayer" }
local function exists(p) return lfs.attributes(p) ~= nil end
local FM = {}
local function filed(path, name)
  return setmetatable({ __path = path, Name = name, __proxy = proxy(name) }, FM)
end
local function child(inst, name)
  local base = inst.__path .. "/" .. name
  if base:match("Shared/PlaceholderIds$") then return filed(root .. "/PLACEHOLDER_IDS", name) end
  for _, ext in ipairs({ ".lua", ".client.lua", ".server.lua" }) do
    if exists(base .. ext) then return filed(base, name) end
  end
  if exists(base) then return filed(base, name) end
  return nil
end
FM.__index = function(inst, key)
  if key == "WaitForChild" or key == "FindFirstChild" then
    return function(this, name) return child(this, name) or proxy(this.__path .. "/" .. name) end
  elseif key == "Parent" then
    local pp = inst.__path:match("^(.*)/[^/]+$")
    return filed(pp, pp:match("([^/]+)$"))
  end
  return child(inst, key) or rawget(inst, "__proxy")[key]
end
local services = {}
local game = proxy("game")
rawget(game, "__store").GetService = function(_, name)
  if dirs[name] then return filed(dirs[name], name) end
  services[name] = services[name] or proxy(name)
  return services[name]
end
local workspace = proxy("workspace")
rawget(workspace, "__store").CurrentCamera = proxy("Camera")
services.Workspace = workspace
local cache = {}
local function req(inst)
  local path = inst.__path
  local file
  for _, ext in ipairs({ ".lua", ".client.lua", ".server.lua" }) do
    if exists(path .. ext) then file = path .. ext break end
  end
  assert(file, "require: no file for " .. tostring(path))
  if cache[file] ~= nil then return cache[file] end
  local env = setmetatable({}, { __index = G })
  env.script = filed(path, path:match("([^/]+)$"))
  env.game, env.workspace, env.require = game, workspace, req
  env.Instance = { new = function(c) return proxy("new " .. c) end }
  env.Enum = proxy("Enum")
  env.UDim2 = proxy("UDim2"); env.UDim = proxy("UDim"); env.NumberSequence = proxy("NumberSequence"); env.ColorSequence = proxy("ColorSequence")
  env.NumberRange = proxy("NumberRange"); env.RaycastParams = proxy("RaycastParams"); env.TweenInfo = proxy("TweenInfo"); env.PhysicalProperties = proxy("PhysicalProperties"); env.OverlapParams = proxy("OverlapParams"); env.BrickColor = proxy("BrickColor"); env.NumberSequenceKeypoint = proxy("NSK"); env.ColorSequenceKeypoint = proxy("CSK"); env.Rect = proxy("Rect"); env.Font = proxy("Font"); env.DateTime = proxy("DateTime")
  env.task = { wait = function() return 0 end, spawn = function() end, defer = function() end, delay = function() end, cancel = function() end }
  env.tick = os.time; env.time = os.clock; env.wait = function() return 0 end; env.spawn = function() end; env.delay = function() end
  env.print = function(...) print("PRINT", ...) end
  env.utf8 = utf8
  local chunk, err = loadfile(file, "t", env)
  assert(chunk, err)
  local result = chunk()
  cache[file] = result
  return result
end
local path = root .. "/src/" .. target
  local ok, err = xpcall(function() req(filed(path, path:match("([^/]+)$"))) end, debug.traceback)
  if ok and target:find("ServerBootstrap", 1, true) then
    -- server glue: ballots, destinations, spawns and a round transition through the real services
    return xpcall(function()
      local S = _G.TumbleCircuitServer
      assert(S and S.round and S.hubs and S.track, "server services table missing")
      local player = proxy("Players.Tester")
      rawget(player, "__store").UserId = 77
      rawget(player, "__store").Parent = proxy("Players")
      local okB, why = S.round:TryBallot(player, 2, 1, 1)
      assert(okB, "ballot refused: " .. tostring(why))
      local stale = select(2, S.round:TryBallot(player, 3, 99, 2))
      assert(stale == "stale", "stale ballot not refused: " .. tostring(stale))
      S.hubs.features[player] = { NewHubs = true }
      S.hubs.chosen[player] = "OrbitalGarage"
      local d = S.hubs:TryDestination(player, 2, 2)
      assert(d.ok, "destination refused: " .. tostring(d.reason))
      local spot = S.round:ResolveSpawn(player, "Practice")
      assert(spot and spot.Hub == "BalloonTerminal" and spot.Zone == "Hub", "practice spawn not in Balloon Terminal")
      local ring = S.round:ResolveSpawn(player, "ToHub")
      assert(ring.Hub == "BalloonTerminal", "hub return not to the chosen hub")
      S.round.queued[player] = true
      S.round:TryJoin(player, true)
      S.round:_transition("Intermission")
      S.round:_transition("Preparing")
      assert(S.track:GetActiveWorldId() ~= nil, "no active world after Preparing")
      local snap = S.round:GetSnapshot()
      assert(snap.ballot and snap.ballot.epoch == 2, "ballot box did not roll over")
    end, debug.traceback)
  end
  if not ok or not target:find("ClientBootstrap", 1, true) then
    return ok, err
  end
  -- client only: a lobby snapshot, then an intermission snapshot with ballots, then frames
  local maps = { "NeonFoundry_A4", "SkyCarnival_B1", "VolcanoVault_B1" }
  local function snapshot(state, extra)
    local snap = { v = ATTRS.ProtocolVersion, roundId = 0, state = state, stateSeq = 1, stateStartedAt = os.time(), stateEndsAt = os.time() + 15,
      trackId = "NeonFoundry_A4", checkpointTotal = 8, racers = {}, queued = { ["1"] = true }, humanCount = 1, queuedCount = 1, raceCapacity = 16,
      readyOpen = false, readyCount = 0, ready = {}, hazardSeed = 1, hazardEpoch = os.time(), worldId = "NeonFoundry_A4", nextWorldId = "SkyCarnival_B1",
      ballot = { epoch = 1, maps = maps, counts = { 0, 1, 0 }, counted = 1, choices = { ["1"] = 2 } } }
    for k, v in pairs(extra or {}) do snap[k] = v end
    return snap
  end
  local function fire(pattern, ...)
    local args = { ... }
    for _, h in ipairs(handlers) do
      if h.key:find(pattern, 1, true) then
        local okH, errH = xpcall(function() h.fn(table.unpack(args)) end, debug.traceback)
        if not okH then error("handler " .. h.key .. ": " .. tostring(errH), 0) end
      end
    end
  end
  return xpcall(function()
    fire("RoundSnapshot", snapshot("Lobby"))
    fire("RoundSnapshot", snapshot("Intermission"))
    fire("DestinationResult", { ok = true, reason = "ok", hubIndex = 1, mode = 1 })
    fire("DestinationResult", { ok = false, reason = "gated", hubIndex = 2, mode = 1 })
    for _, fn in ipairs(renderSteps) do
      for _ = 1, 3 do fn(1 / 60) end
    end
  end, debug.traceback)
end

if BOOT_SMOKE_AS_MODULE then
  return run
end
local ok, err = run(arg[1], arg[2])
print(ok and "MAIN CHUNK COMPLETED" or ("ERROR: " .. tostring(err)))
os.exit(ok and 0 or 1)
