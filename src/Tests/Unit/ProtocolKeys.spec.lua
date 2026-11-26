--[[
	ProtocolKeys.spec (2026-11-26) — every Protocol attribute / reason key the code uses exists.
	A missing key is nil at runtime: player:SetAttribute(nil) / GetAttributeChangedSignal(nil)
	fail ("Argument 1 missing or nil"); that broke loading in v21-v26 when a second
	Protocol.PlayerAttributes table replaced the first. Offline only (reads source files).
]]

local Spec = {}

local FILES = {
	"src/ReplicatedStorage/Shared",
	"src/ServerScriptService/Services",
	"src/ServerScriptService/ServerBootstrap.server.lua",
	"src/StarterPlayer/StarterPlayerScripts/ClientBootstrap.client.lua",
	"src/StarterPlayer/StarterPlayerScripts/Controllers",
}

function Spec.run(m)
	local results = { passed = 0, failed = 0, lines = {}, info = {} }
	local function check(name, ok, detail)
		if ok then
			results.passed = results.passed + 1
			table.insert(results.lines, "PASS  " .. name)
		else
			results.failed = results.failed + 1
			table.insert(results.lines, "FAIL  " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
		end
	end
	if not (m.ReadFile and m.ListFiles and m.Protocol) then
		check("protocol key scan available (offline only)", true)
		return results
	end
	local P = m.Protocol
	local tables = {
		PlayerAttributes = P.PlayerAttributes, ATTR = P.PlayerAttributes,
		BallAttributes = P.BallAttributes, BALL = P.BallAttributes,
		WorkspaceAttributes = P.WorkspaceAttributes,
		SpawnReasons = P.SpawnReasons, REASONS = P.SpawnReasons,
		Zones = P.Zones, ZONES = P.Zones,
	}
	local missing, used = {}, 0
	for _, entry in ipairs(FILES) do
		for _, rel in ipairs(m.ListFiles(entry)) do
			local src = m.ReadFile(rel)
			for tableName, key in src:gmatch("([%a_]+)%.([%a_]+)") do
				local t = tables[tableName]
				if t then
					used = used + 1
					if t[key] == nil and not (tableName == "ATTR" and rel:find("Controllers/", 1, true)) then
						missing[#missing + 1] = rel:match("[^/]+$") .. ": " .. tableName .. "." .. key
					end
				end
			end
		end
	end
	results.info[#results.info + 1] = string.format("%d protocol key uses scanned", used)
	check("every Protocol attribute / reason / zone key used in code exists", #missing == 0, table.concat(missing, ", "))
	local src = m.ReadFile("src/ReplicatedStorage/Shared/Protocol.lua")
	local seen, dup = {}, {}
	for name in src:gmatch("\nProtocol%.([%a_]+) = {") do
		if seen[name] then
			dup[#dup + 1] = name
		end
		seen[name] = true
	end
	check("no Protocol table is defined twice (a second one silently replaces the first)", #dup == 0, table.concat(dup, ", "))
	return results
end

return Spec
