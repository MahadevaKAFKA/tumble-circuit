--[[
	PartyRules (B1) — pure grouping for Party Race. No Roblox APIs.
	A Roblox party (Player.PartyId) whose members are in this server races on neighbouring grid
	slots. Groups are capped at MaxSize (4); extra members race normally. Players not in a party
	(or alone in this server) are unaffected. Order inside the grid stays the round's fair
	shuffle: a group takes the position of its first member in the shuffled order.
]]

local PartyRules = {}

PartyRules.MaxSize = 4

-- members: { [userId] = partyId or "" }; returns { [partyId] = {userIds in join order} } for
-- parties with >= 2 present (capped)
function PartyRules.Groups(members, joinOrder)
	local byParty = {}
	for _, userId in ipairs(joinOrder) do
		local partyId = members[userId]
		if type(partyId) == "string" and partyId ~= "" then
			local list = byParty[partyId] or {}
			byParty[partyId] = list
			if #list < PartyRules.MaxSize then
				list[#list + 1] = userId
			end
		end
	end
	local groups = {}
	for partyId, list in pairs(byParty) do
		if #list >= 2 then
			groups[partyId] = list
		end
	end
	return groups
end

-- order: shuffled userIds; returns a new order with each party's members next to each other
function PartyRules.GroupOrder(order, members, joinOrder)
	local groups = PartyRules.Groups(members, joinOrder or order)
	local groupOf = {}
	for partyId, list in pairs(groups) do
		for _, userId in ipairs(list) do
			groupOf[userId] = partyId
		end
	end
	local placed, result = {}, {}
	for _, userId in ipairs(order) do
		if not placed[userId] then
			local partyId = groupOf[userId]
			if partyId then
				for _, other in ipairs(order) do -- keep the shuffled order inside the group
					if groupOf[other] == partyId and not placed[other] then
						placed[other] = true
						result[#result + 1] = other
					end
				end
			else
				placed[userId] = true
				result[#result + 1] = userId
			end
		end
	end
	return result
end

return PartyRules
