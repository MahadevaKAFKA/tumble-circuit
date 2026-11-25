--[[
	Offline module loader: emulates just enough of `game`, `script`, `require` and Rojo's
	file->instance mapping to load the PURE Tumble Circuit modules from disk under texlua (Lua 5.3).
	Usage: texlua tools/offline/harness.lua <projectRoot>  (see run_tests.lua)
]]

local harness = {}

local function exists(path, mode)
	local attr = lfs.attributes(path)
	return attr ~= nil and (mode == nil or attr.mode == mode)
end

function harness.new(root)
	local shim = dofile(root .. "/tools/offline/roblox_shim.lua")
	local self = { root = root, cache = {}, shim = shim }
	shim.install(_G)

	-- Rojo mapping (subset of default.project.json) for the services pure modules touch.
	local serviceDirs = {
		ReplicatedStorage = root .. "/src/ReplicatedStorage",
		ServerStorage = root .. "/src/ServerStorage",
		ServerScriptService = root .. "/src/ServerScriptService",
		StarterPlayer = root .. "/src/StarterPlayer",
	}
	-- Services a module may *reference* at load time but must not use in the tested functions
	-- (client controllers: Players, TweenService...). Opt-in per name from run_tests.lua.
	self.stubServices = {}
	local overrides = {
		[root .. "/src/ReplicatedStorage/Shared/PlaceholderIds"] = root .. "/PLACEHOLDER_IDS.lua",
	}

	local Fake = {}
	local function fake(path, name)
		return setmetatable({ __path = path, Name = name }, Fake)
	end
	local function child(inst, name)
		local base = inst.__path .. "/" .. name
		if overrides[base] then
			return fake(base, name)
		end
		if exists(base .. ".lua", "file") then
			return fake(base, name)
		end
		if exists(base, "directory") then
			return fake(base, name)
		end
		return nil
	end
	Fake.__index = function(inst, key)
		if key == "WaitForChild" or key == "FindFirstChild" then
			return function(this, name)
				local c = child(this, name)
				if not c and key == "WaitForChild" then
					error("offline harness: missing child " .. name .. " under " .. this.__path)
				end
				return c
			end
		elseif key == "Parent" then
			local parentPath = inst.__path:match("^(.*)/[^/]+$")
			return fake(parentPath, parentPath:match("([^/]+)$"))
		end
		return child(inst, key)
	end

	local game = {
		GetService = function(_, name)
			local dir = serviceDirs[name]
			if not dir and self.stubServices[name] then
				return self.stubServices[name]
			end
			if not dir then
				error("offline harness: service " .. name .. " is not available to pure modules")
			end
			return fake(dir, name)
		end,
	}
	self.game = game

	function self.require(inst)
		local path = inst.__path
		local file = overrides[path] or (path .. ".lua")
		if self.cache[file] ~= nil then
			return self.cache[file]
		end
		local env = setmetatable({}, { __index = _G })
		env.script = fake(path, path:match("([^/]+)$"))
		env.game = game
		env.require = self.require
		local chunk, err = loadfile(file, "t", env)
		if not chunk then
			error("offline harness: syntax error in " .. file .. ": " .. tostring(err))
		end
		local result = chunk()
		self.cache[file] = result
		return result
	end

	function self.module(relative)
		-- relative like "ReplicatedStorage/Shared/TrackDefinitions"
		local service, rest = relative:match("^([^/]+)/(.*)$")
		local inst = game:GetService(service)
		for part in rest:gmatch("[^/]+") do
			inst = inst:WaitForChild(part)
		end
		return self.require(inst)
	end

	return self
end

return harness
