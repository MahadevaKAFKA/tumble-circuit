--[[
	EnvironmentController (UI / environment overhaul, 2026-11-26; replaces DressingController)
	builds each map's backdrop and hub staging on THIS client only:
	  * course backdrops (Shared/EnvironmentProfiles + the Foundry dressing from Shared/Dressing)
	    for the race map in play and for the map of the hub you are in (so Orbital Garage
	    overlooks the Foundry turbine); one folder per map, rebuilt only when that set changes
	  * hub staging for the hub you are in (Garage deck signage, assembly arms, Balloon Terminal
	    drum balloons, Basalt vent field ...)
	  * once at start: road midtones (floor colour only - physics stay the server's), narrow
	    rail-top guide lights (same colours, a thin strip instead of a wide neon bar), the
	    Foundry gate pillars as dark metal with neon insets, the practice lanes' own road colour
	Every part: anchored, CanCollide / CanQuery / CanTouch false, no shadow, never replicated.
	A change of map, hub or scenery detail destroys the old folder first (no stale visuals,
	no leftover connections: this controller connects to nothing).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Dressing = require(Shared:WaitForChild("Dressing"))
local EnvironmentProfiles = require(Shared:WaitForChild("EnvironmentProfiles"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local MapRegistry = require(Shared:WaitForChild("MapRegistry"))
local TrackDefinitions = require(Shared:WaitForChild("TrackDefinitions"))

local EnvironmentController = {}
EnvironmentController.__index = EnvironmentController

local function makePart(spec, parent)
	local part = Instance.new("Part")
	if spec.Shape == "Cylinder" then
		part.Shape = Enum.PartType.Cylinder
	elseif spec.Shape == "Ball" then
		part.Shape = Enum.PartType.Ball
	end
	part.Name = spec.Name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Size = spec.Size
	part.CFrame = spec.CFrame
	part.Color = spec.Color
	part.Material = Enum.Material[spec.Material or "SmoothPlastic"]
	part.Transparency = spec.Transparency or 0
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in pairs(spec.Attributes or {}) do
		part:SetAttribute(key, value)
	end
	if spec.Gui then
		local surface = Instance.new("SurfaceGui")
		surface.Face = Enum.NormalId.Back
		surface.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		surface.PixelsPerStud = 40
		surface.LightInfluence = 0
		local label = Instance.new("TextLabel")
		label.Size = UDim2.fromScale(1, 1)
		label.BackgroundTransparency = 1
		label.Text = spec.Gui.Text
		label.TextScaled = true
		label.Font = Enum.Font.GothamBlack
		label.TextColor3 = spec.Gui.Color or Color3.new(1, 1, 1)
		label.Parent = surface
		surface.Parent = part
	end
	part.Parent = parent
	return part
end
EnvironmentController.MakePart = makePart

-- deps = { course = Folder, worldLayouts = {[mapId] = layout}, hubLayouts = {[hubId] = layout} }
function EnvironmentController.new(deps)
	local self = setmetatable({}, EnvironmentController)
	self.deps = deps
	self.detail = "Standard"
	self.courseFolders = {} -- [mapId] = Folder
	self.wantedMaps = {}
	self.hubId = nil
	self.hubFolder = nil
	self.pads = {}
	self.restyled = false
	return self
end

-- Local restyle of the server-built courses and practice lanes (colour / size only).
function EnvironmentController:Restyle()
	if self.restyled then
		return
	end
	self.restyled = true
	local course = self.deps.course
	for mapId, profile in pairs(EnvironmentProfiles.Maps) do
		local root = course and course:FindFirstChild(mapId)
		local map = MapRegistry.RawMap(mapId)
		local def = map and TrackDefinitions.WorldsById[map.Track]
		local baseFloor = def and def.Theme and def.Theme.NavyFloor or GameConfig.Palette.NavyFloor
		if root then
			local floor = root:FindFirstChild("Floor")
			for _, part in ipairs(floor and floor:GetChildren() or {}) do
				if part:IsA("BasePart") and string.sub(part.Name, 1, 6) == "Floor_" and part.Color == baseFloor then
					part.Color = profile.Road -- start / finish pads keep their own colour
				end
			end
			local decor = root:FindFirstChild("Decor")
			for _, part in ipairs(decor and decor:GetChildren() or {}) do
				if part:IsA("BasePart") and part.Name == "RailCap" then
					local drop = (part.Size.Y - profile.Edge.Height) / 2
					part.Size = Vector3.new(profile.Edge.Width, profile.Edge.Height, part.Size.Z)
					part.CFrame = part.CFrame * CFrame.new(0, -drop, 0)
				elseif part:IsA("BasePart") and part.Name == "GatePillar" and profile.UsesDressing then
					part.Color = Dressing.Restyle.GatePillar.Color
					part.Material = Enum.Material[Dressing.Restyle.GatePillar.Material]
				end
			end
		end
	end
	for hubId, profile in pairs(EnvironmentProfiles.Hubs) do
		local entry = MapRegistry.RawHub(hubId)
		local model = entry and workspace:FindFirstChild(entry.ModelName)
		local chute = model and model:FindFirstChild("PracticeChute")
		local floor = chute and chute:FindFirstChild("Floor")
		for _, part in ipairs(floor and floor:GetChildren() or {}) do
			if part:IsA("BasePart") and string.sub(part.Name, 1, 6) == "Floor_" then
				part.Color = profile.ChuteRoad -- the lane reads as its own surface, apart from the deck
			end
		end
	end
end

function EnvironmentController:_buildCourse(mapId)
	local layout = self.deps.worldLayouts[mapId]
	local folder = Instance.new("Folder")
	folder.Name = "TC_Env_" .. mapId
	local ok, err = pcall(function()
		for _, spec in ipairs(EnvironmentProfiles.CourseSpecs(mapId, layout, self.detail)) do
			makePart(spec, folder)
		end
	end)
	if not ok then
		warn("[Environment] " .. tostring(mapId) .. " backdrop failed, the course stays playable: " .. tostring(err))
	end
	folder.Parent = workspace
	return folder
end

-- The race map in play + the map of your hub. Builds what is new, destroys what left.
function EnvironmentController:SetMaps(mapIds)
	local wanted = {}
	for _, id in ipairs(mapIds) do
		if id and EnvironmentProfiles.Maps[id] then
			wanted[id] = true
		end
	end
	for id, folder in pairs(self.courseFolders) do
		if not wanted[id] then
			folder:Destroy()
			self.courseFolders[id] = nil
		end
	end
	for id in pairs(wanted) do
		if not self.courseFolders[id] then
			self.courseFolders[id] = self:_buildCourse(id)
		end
	end
	self.wantedMaps = wanted
end

function EnvironmentController:SetHub(hubId)
	if hubId == self.hubId and self.hubFolder then
		return
	end
	self.hubId = hubId
	if self.hubFolder then
		self.hubFolder:Destroy()
		self.hubFolder = nil
	end
	self.pads = {}
	local entry = MapRegistry.RawHub(hubId)
	if not entry then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "TC_Env_Hub"
	local ok, err = pcall(function()
		local chute = self.deps.hubLayouts[hubId]
		local specs = EnvironmentProfiles.HubSpecs(hubId, entry.Geometry, chute, self.detail)
		local profile = EnvironmentProfiles.Hubs[hubId]
		if profile and profile.UsesGarageDeck then
			for _, spec in ipairs(Dressing.GarageSpecs(entry.Geometry, self.deps.worldLayouts[entry.Map], entry.Chute.Pieces[1].Width[1])) do
				specs[#specs + 1] = spec
			end
		end
		for _, spec in ipairs(specs) do
			local part = makePart(spec, folder)
			if spec.Attributes and spec.Attributes.TC_Selector then
				self.pads[#self.pads + 1] = { part = part, radius = spec.Attributes.Radius or 3.5, hubId = hubId }
			end
		end
	end)
	if not ok then
		warn("[Environment] hub staging failed, the hub stays playable: " .. tostring(err))
	end
	folder.Parent = workspace
	self.hubFolder = folder
end

-- Scenery detail: rebuild everything at the new level
function EnvironmentController:SetDetail(detail)
	detail = EnvironmentProfiles.Levels[detail or ""] and detail or "Standard"
	if detail == self.detail then
		return
	end
	self.detail = detail
	local maps = {}
	for id in pairs(self.wantedMaps) do
		maps[#maps + 1] = id
	end
	for id, folder in pairs(self.courseFolders) do
		folder:Destroy()
		self.courseFolders[id] = nil
	end
	self:SetMaps(maps)
	local hub = self.hubId
	self.hubId = nil
	if hub then
		self:SetHub(hub)
	end
end

function EnvironmentController:GetSelectorPads()
	return self.pads
end

function EnvironmentController:Destroy()
	for _, folder in pairs(self.courseFolders) do
		folder:Destroy()
	end
	self.courseFolders = {}
	if self.hubFolder then
		self.hubFolder:Destroy()
		self.hubFolder = nil
	end
end

return EnvironmentController
