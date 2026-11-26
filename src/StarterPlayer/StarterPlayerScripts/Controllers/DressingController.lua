--[[
	DressingController (promo pack prompts 05 / 06) — builds the Shared/Dressing parts on THIS
	client only (workspace.TC_LocalDressing) and restyles a few existing Foundry parts locally,
	for players with the NewHubs gate. Everything is anchored, non-colliding, not raycast, not
	touched and never replicated: race lines, checkpoints, physics and other players' views are
	unchanged. SetEnabled(false) removes the parts and restores every restyled part exactly.
	SetQuality("Low") drops the Detail parts (panel breaks, spines, turbine blades).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Dressing = require(Shared:WaitForChild("Dressing"))
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local TrackDefinitions = require(Shared:WaitForChild("TrackDefinitions"))

local DressingController = {}
DressingController.__index = DressingController

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

-- deps = { course = Folder, foundryId, foundryLayout, hubGeometry, hubRoot, chuteWidth }
function DressingController.new(deps)
	local self = setmetatable({}, DressingController)
	self.deps = deps
	self.enabled = false
	self.low = false
	self.folder = nil
	self.detail = {} -- parts hidden on Low
	self.restyled = {} -- { part, color, material }
	self.pads = {}
	return self
end

function DressingController:_restyle()
	local root = self.deps.course and self.deps.course:FindFirstChild(self.deps.foundryId)
	if not root then
		return
	end
	local defaultFloor = GameConfig.Palette.NavyFloor
	local floor = root:FindFirstChild("Floor")
	for _, part in ipairs(floor and floor:GetChildren() or {}) do
		if part:IsA("BasePart") and string.sub(part.Name, 1, 6) == "Floor_" and part.Color == defaultFloor then
			self.restyled[#self.restyled + 1] = { part = part, color = part.Color, material = part.Material }
			part.Color = Dressing.Restyle.Floor.Color -- colour only: physics come from the server's properties
		end
	end
	local decor = root:FindFirstChild("Decor")
	for _, part in ipairs(decor and decor:GetChildren() or {}) do
		if part:IsA("BasePart") and part.Name == "GatePillar" then
			self.restyled[#self.restyled + 1] = { part = part, color = part.Color, material = part.Material }
			part.Color = Dressing.Restyle.GatePillar.Color
			part.Material = Enum.Material[Dressing.Restyle.GatePillar.Material]
		end
	end
end

function DressingController:SetEnabled(on)
	on = on == true
	if on == self.enabled then
		return
	end
	self.enabled = on
	if not on then
		for _, entry in ipairs(self.restyled) do
			if entry.part.Parent then
				entry.part.Color = entry.color
				entry.part.Material = entry.material
			end
		end
		for _, part in ipairs(self.detail) do
			part:Destroy() -- detail parts may be parked outside the folder on Low
		end
		self.restyled, self.detail, self.pads = {}, {}, {}
		if self.folder then
			self.folder:Destroy()
			self.folder = nil
		end
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "TC_LocalDressing"
	local function build(list, hubId)
		for _, spec in ipairs(list) do
			local part = makePart(spec, folder)
			if spec.Detail then
				self.detail[#self.detail + 1] = part
			end
			if spec.Attributes and spec.Attributes.TC_Selector then
				self.pads[#self.pads + 1] = { part = part, radius = spec.Attributes.Radius or 3.5, hubId = hubId }
			end
		end
	end
	local ok, err = pcall(function()
		if self.deps.foundryLayout then
			build(Dressing.FoundrySpecs(self.deps.foundryLayout, TrackDefinitions.SampleAtH))
		end
		if self.deps.hubGeometry then
			build(Dressing.GarageSpecs(self.deps.hubGeometry, self.deps.foundryLayout, self.deps.chuteWidth), self.deps.hubId)
		end
		self:_restyle()
	end)
	if not ok then
		warn("[Dressing] build failed, keeping the standard look: " .. tostring(err))
	end
	folder.Parent = workspace
	self.folder = folder
	self:SetQuality(self.low)
end

function DressingController:SetQuality(low)
	self.low = low == true
	for _, part in ipairs(self.detail) do
		part.Parent = (self.low or not self.folder) and nil or self.folder
	end
end

function DressingController:GetSelectorPads()
	return self.pads
end

function DressingController:Destroy()
	self:SetEnabled(false)
end

return DressingController
