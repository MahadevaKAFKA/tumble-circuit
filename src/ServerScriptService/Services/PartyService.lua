--[[
	PartyService (B1) — Party Race: members of the same Roblox party who are in this server start
	on neighbouring grid slots (max 4 per party) and see each other tagged PARTY. Reads
	Player.PartyId only (Roblox's own party feature; privacy is Roblox's). Inviting friends is
	the native SocialService prompt on the client. If the party API is unavailable, everyone
	races normally and the lobby says so.
]]

local Players = game:GetService("Players")

local PartyRules = require(script.Parent:WaitForChild("PartyRules"))

local PartyService = {}
PartyService.__index = PartyService

function PartyService.new(deps)
	local self = setmetatable({}, PartyService)
	self.marbles = deps.marbles
	self.available = true
	return self
end

local function partyIdOf(player)
	local ok, id = pcall(function()
		return player.PartyId
	end)
	if ok and type(id) == "string" then
		return id
	end
	return nil
end

function PartyService:_members()
	local members, joinOrder = {}, {}
	local any = false
	for _, player in ipairs(Players:GetPlayers()) do
		local id = partyIdOf(player)
		if id ~= nil then
			any = true
		end
		members[player.UserId] = id or ""
		joinOrder[#joinOrder + 1] = player.UserId
	end
	self.available = any or #joinOrder == 0
	return members, joinOrder
end

function PartyService:GroupGridOrder(order)
	local members, joinOrder = self:_members()
	return PartyRules.GroupOrder(order, members, joinOrder)
end

-- snapshot: { available, tags = { [tostring(userId)] = groupNumber } } for parties of >= 2 here
function PartyService:SnapshotFor()
	local members, joinOrder = self:_members()
	local groups = PartyRules.Groups(members, joinOrder)
	local tags, n = {}, 0
	local keys = {}
	for partyId in pairs(groups) do
		keys[#keys + 1] = partyId
	end
	table.sort(keys)
	for _, partyId in ipairs(keys) do
		n = n + 1
		for _, userId in ipairs(groups[partyId]) do
			tags[tostring(userId)] = n
		end
	end
	return { available = self.available, tags = tags, maxSize = PartyRules.MaxSize }
end

return PartyService
