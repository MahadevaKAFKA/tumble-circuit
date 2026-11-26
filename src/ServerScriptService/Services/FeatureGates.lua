--[[
	FeatureGates (promo pack prompts 02/07) — which registry gates are on.
	  ForServer()        -> gates that change the SHARED race (map rotation): Studio only.
	  ForPlayer(player)  -> gates for one player's personal choices (which hub they visit):
	                        Studio, or a live account allowed by GameConfig.Features.
	  Pure core: Resolve(isStudio, userId, creatorId, creatorIsUser, config).
]]

local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local MapRegistry = require(Shared:WaitForChild("MapRegistry"))

local FeatureGates = {}

local function all()
	local out = {}
	for _, gate in pairs(MapRegistry.Gates) do
		out[gate] = true
	end
	return out
end

function FeatureGates.Resolve(isStudio, userId, creatorId, creatorIsUser, config)
	if isStudio then
		return all()
	end
	config = config or {}
	if type(userId) ~= "number" then
		return {}
	end
	for _, id in ipairs(config.GatedUserIds or {}) do
		if id == userId then
			return all()
		end
	end
	if config.OwnerSeesGated and creatorIsUser and creatorId == userId then
		return all()
	end
	return {}
end

function FeatureGates.ForServer()
	return RunService:IsStudio() and all() or {}
end

function FeatureGates.ForPlayer(player)
	local creatorIsUser = game.CreatorType == Enum.CreatorType.User
	return FeatureGates.Resolve(RunService:IsStudio(), player and player.UserId, game.CreatorId, creatorIsUser, GameConfig.Features)
end

-- "NewHubs,..." for the player attribute the client reads (display only; the server re-checks)
function FeatureGates.Encode(features)
	local names = {}
	for name, on in pairs(features or {}) do
		if on then
			names[#names + 1] = name
		end
	end
	table.sort(names)
	return table.concat(names, ",")
end

return FeatureGates
