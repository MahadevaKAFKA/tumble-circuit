-- Verifies the Rojo-built place file in CI (run with Lune, a standalone Luau runtime).
-- Same expectations as tests/verify_place.py, read from tests/place_expectations.json.
--
-- Usage: lune run tests/verify_place.luau build/TumbleCircuit.rbxl

local fs = require("@lune/fs")
local process = require("@lune/process")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")

local placePath = process.args[1] or "build/TumbleCircuit.rbxl"
local expect = serde.decode("json", fs.readFile("tests/place_expectations.json"))
local game = roblox.deserializePlace(fs.readFile(placePath))

local failures = {}
local function fail(message)
	table.insert(failures, message)
end

local function fullName(instance)
	local parts = {}
	local node = instance
	while node and node.ClassName ~= "DataModel" do
		table.insert(parts, 1, node.Name)
		node = node.Parent
	end
	return table.concat(parts, "/")
end

local function resolve(path)
	local node = game
	for segment in string.gmatch(path, "[^/]+") do
		node = node:FindFirstChild(segment)
		if node == nil then
			return nil
		end
	end
	return node
end

for _, want in expect.instances do
	local instance = resolve(want.path)
	if instance == nil then
		fail("missing " .. want.path .. " (" .. want.class .. ")")
	elseif instance.ClassName ~= want.class then
		fail(want.path .. " is " .. instance.ClassName .. ", expected " .. want.class)
	end
end

for _, want in expect.properties do
	local instance = resolve(want.path)
	if instance == nil then
		fail("missing " .. want.path .. " for property " .. want.name)
	else
		local ok, value = pcall(function()
			return instance[want.name]
		end)
		if not ok then
			fail("could not read " .. want.path .. "." .. want.name .. ": " .. tostring(value))
		elseif value ~= want.value then
			fail(want.path .. "." .. want.name .. " = " .. tostring(value) .. ", expected " .. tostring(want.value))
		end
	end
end

local known = {}
for _, name in expect.runtimeNames do
	known[name] = true
end
local descendants = game:GetDescendants()
for _, instance in descendants do
	known[instance.Name] = true
end

local patterns = { 'WaitForChild%(%s*"([^"]+)"', 'FindFirstChild%(%s*"([^"]+)"' }
local scripts = 0
for _, instance in descendants do
	if instance:IsA("LuaSourceContainer") then
		scripts += 1
		local source = instance.Source
		if type(source) ~= "string" or #source == 0 then
			fail(fullName(instance) .. " has no source")
		else
			for _, pattern in patterns do
				for ref in string.gmatch(source, pattern) do
					if not known[ref] then
						fail(fullName(instance) .. " looks up '" .. ref .. "', which is not in the place or the runtime list")
					end
				end
			end
		end
	end
end

if #failures > 0 then
	print("FAILED: " .. placePath)
	for _, message in failures do
		print("  - " .. message)
	end
	process.exit(1)
end

print(string.format("OK: %s - %d instances, %d scripts, all references resolve", placePath, #descendants, scripts))
