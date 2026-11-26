--[[
	HubBuilder — the A2 minimal Orbital Garage: a round glass platform with a rim (open where the
	Practice Chute leaves), a holographic "next race" board above the chute entrance, a simple
	three-step podium and 16 spawn spots. Full lobby decoration is A6. No shop, no paid anything.

	Pure spec/spawn functions + Build(). The board's labels are updated by each client from the
	round snapshot (no per-second server writes).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local PhysicsConfig = require(Shared:WaitForChild("PhysicsConfig"))

local HubBuilder = {}

local function headingVectors(deg)
	local psi = math.rad(deg)
	local look = Vector3.new(math.sin(psi), 0, -math.cos(psi))
	local right = Vector3.new(math.cos(psi), 0, math.sin(psi))
	return look, right
end

-- Spawn CFrames on a ring around the centre, all facing the chute.
-- Podium steps (1st centre, 2nd left, 3rd right) shared by the builder and the A6 podium displays.
HubBuilder.PodiumSteps = { { offset = 0, height = 3 }, { offset = -5, height = 2 }, { offset = 5, height = 1.2 } }

-- A6: top-centre of each podium cap (where the display marbles sit), indexed by place.
function HubBuilder.PodiumSpots(hub)
	local look, right = headingVectors(hub.ChuteHeadingDeg)
	local up = Vector3.new(0, 1, 0)
	local base = hub.Center - look * (hub.Radius - 9)
	local out = {}
	for place, step in ipairs(HubBuilder.PodiumSteps) do
		out[place] = base + right * step.offset + up * (step.height + 0.25)
	end
	return out
end

function HubBuilder.SpawnCFrames(hub, ballRadius, lift)
	local look, right = headingVectors(hub.ChuteHeadingDeg)
	local out = {}
	for i = 1, hub.SpawnSlots do
		local angle = (i - 1) / hub.SpawnSlots * math.pi * 2
		local offset = Vector3.new(math.cos(angle), 0, math.sin(angle)) * hub.SpawnRingRadius
		local position = hub.Center + offset + Vector3.new(0, ballRadius + lift, 0)
		out[i] = CFrame.fromMatrix(position, right, Vector3.new(0, 1, 0))
	end
	return out, look
end

function HubBuilder.ComputeSpecs(hub, chuteWidth)
	local palette = GameConfig.Palette
	local track = PhysicsConfig.Track
	local specs = {}
	local function add(spec)
		specs[#specs + 1] = spec
		return spec
	end
	local up = Vector3.new(0, 1, 0)
	local look, right = headingVectors(hub.ChuteHeadingDeg)
	local floorPhysics = { Density = 0.7, Friction = track.FloorFriction, Elasticity = track.FloorElasticity, FrictionWeight = 1, ElasticityWeight = 1 }
	local railPhysics = { Density = 0.7, Friction = track.RailFriction, Elasticity = track.RailElasticity, FrictionWeight = 1, ElasticityWeight = 1 }

	add({
		Class = "Part",
		Shape = "Cylinder",
		Name = "HubFloor",
		Folder = "Floor",
		Size = Vector3.new(hub.FloorThickness, hub.Radius * 2, hub.Radius * 2),
		CFrame = CFrame.fromMatrix(hub.Center - up * (hub.FloorThickness / 2), up, right),
		Color = palette.Navy:Lerp(palette.Cyan, 0.12),
		Material = "Glass",
		Transparency = 0.2,
		Reflectance = 0.15,
		Physics = floorPhysics,
	})
	add({
		Class = "Part",
		Shape = "Cylinder",
		Name = "HubRing",
		Folder = "Decor",
		Size = Vector3.new(0.1, hub.SpawnRingRadius * 2 + 2, hub.SpawnRingRadius * 2 + 2),
		CFrame = CFrame.fromMatrix(hub.Center + up * 0.04, up, right),
		Color = palette.Violet,
		Material = "Neon",
		Transparency = 0.7,
		Collide = false,
	})

	-- Rim wall, open where the chute leaves (angle measured from the chute heading).
	local segments = 32
	local gapHalf = math.asin(math.min(1, (chuteWidth / 2 + 2.5) / hub.Radius))
	local segmentLength = 2 * math.pi * (hub.Radius + 0.6) / segments * 1.06
	for i = 0, segments - 1 do
		local angle = i / segments * math.pi * 2
		local relative = angle
		if relative > math.pi then
			relative = relative - math.pi * 2
		end
		if math.abs(relative) > gapHalf + math.pi / segments then
			local radial = look * math.cos(angle) + right * math.sin(angle)
			local tangent = radial:Cross(up)
			local position = hub.Center + radial * (hub.Radius + 0.6) + up * ((hub.RimHeight - hub.FloorThickness) / 2)
			local wall = add({
				Class = "Part",
				Name = "Rim",
				Folder = "Rails",
				Size = Vector3.new(1.2, hub.RimHeight + hub.FloorThickness, segmentLength),
				CFrame = CFrame.fromMatrix(position, radial, up), -- Z = radial x up = tangent (length axis)
				Color = palette.NavyRail,
				Material = "SmoothPlastic",
				Physics = railPhysics,
			})
			add({
				Class = "Part",
				Name = "RimCap",
				Folder = "Decor",
				Size = Vector3.new(1.3, 0.3, segmentLength),
				CFrame = wall.CFrame * CFrame.new(0, wall.Size.Y / 2 + 0.15, 0),
				Color = palette.Cyan,
				Material = "Neon",
				Collide = false,
			})
		end
	end

	-- Next-race board above the chute entrance, facing the spawn ring.
	local boardPos = hub.Center + look * (hub.Radius + 4) + up * 17
	add({
		Class = "Part",
		Name = "NextRaceBoard",
		Folder = "Decor",
		Size = Vector3.new(30, 11, 0.6),
		CFrame = CFrame.lookAt(boardPos, boardPos - look),
		Color = palette.Ink,
		Material = "SmoothPlastic",
		Transparency = 0.15,
		Collide = false,
		Gui = { Kind = "Board" },
	})
	for _, side in ipairs({ -1, 1 }) do
		add({
			Class = "Part",
			Name = "BoardPillar",
			Folder = "Decor",
			Size = Vector3.new(1, 22, 1),
			CFrame = CFrame.new(boardPos + right * (side * 15.5) - up * 5.5),
			Color = palette.Violet,
			Material = "Neon",
			Collide = false,
		})
	end

	-- Minimal podium on the far side (1st centre, 2nd left, 3rd right). Decorative in A2.
	local podiumBase = hub.Center - look * (hub.Radius - 9)
	local podiumColors = { palette.Yellow, palette.White, palette.Coral }
	local steps = {}
	for i, step in ipairs(HubBuilder.PodiumSteps) do
		steps[i] = { offset = step.offset, height = step.height, color = podiumColors[i] }
	end
	for i, step in ipairs(steps) do
		local position = podiumBase + right * step.offset + up * (step.height / 2)
		add({
			Class = "Part",
			Name = "Podium" .. i,
			Folder = "Decor",
			Size = Vector3.new(4.6, step.height, 4.6),
			CFrame = CFrame.lookAt(position, position + look),
			Color = palette.NavyRail,
			Material = "SmoothPlastic",
			Collide = false,
		})
		add({
			Class = "Part",
			Name = "PodiumCap" .. i,
			Folder = "Decor",
			Size = Vector3.new(4.8, 0.25, 4.8),
			CFrame = CFrame.lookAt(position + up * (step.height / 2 + 0.12), position + up * (step.height / 2 + 0.12) + look),
			Color = step.color,
			Material = "Neon",
			Collide = false,
		})
	end

	-- A6 polish: podium backdrop arch, a marble showcase pedestal and hologram pylons on the rim
	-- (all decorative, non-colliding, native parts only).
	local archCenter = podiumBase - look * 3 + up * 7
	for _, side in ipairs({ -1, 1 }) do
		add({ Class = "Part", Name = "PodiumArchPost", Folder = "Decor", Size = Vector3.new(0.8, 9, 0.8), CFrame = CFrame.new(archCenter + right * (side * 8.5) - up * 2.5), Color = palette.Violet, Material = "Neon", Collide = false })
	end
	add({ Class = "Part", Name = "PodiumArchBeam", Folder = "Decor", Size = Vector3.new(17.8, 0.8, 0.8), CFrame = CFrame.lookAt(archCenter + up * 2, archCenter + up * 2 + right), Color = palette.Yellow, Material = "Neon", Collide = false })
	local pedestalPos = hub.Center + right * (hub.Radius - 10) - look * 6
	add({ Class = "Part", Shape = "Cylinder", Name = "MarblePedestal", Folder = "Decor", Size = Vector3.new(2.4, 6, 6), CFrame = CFrame.fromMatrix(pedestalPos + up * 1.2, up, right), Color = palette.NavyRail, Material = "SmoothPlastic", Collide = false })
	add({ Class = "Part", Shape = "Cylinder", Name = "PedestalRing", Folder = "Decor", Size = Vector3.new(0.2, 6.6, 6.6), CFrame = CFrame.fromMatrix(pedestalPos + up * 2.45, up, right), Color = palette.Cyan, Material = "Neon", Collide = false })
	add({ Class = "Part", Shape = "Ball", Name = "ShowcaseMarble", Folder = "Decor", Size = Vector3.new(4, 4, 4), CFrame = CFrame.new(pedestalPos + up * 4.6), Color = palette.Cyan, Material = "SmoothPlastic", Reflectance = 0.3, Collide = false })
	add({ Class = "Part", Shape = "Cylinder", Name = "ShowcaseHalo", Folder = "Decor", Size = Vector3.new(0.15, 5.6, 5.6), CFrame = CFrame.fromMatrix(pedestalPos + up * 4.6, up, right), Color = palette.Yellow, Material = "Neon", Transparency = 0.4, Collide = false })
	for k = 0, 3 do
		local angle = math.pi / 4 + k * math.pi / 2
		local radial = look * math.cos(angle) + right * math.sin(angle)
		local base = hub.Center + radial * (hub.Radius + 3)
		add({ Class = "Part", Shape = "Cylinder", Name = "HoloPylon", Folder = "Decor", Size = Vector3.new(10, 1, 1), CFrame = CFrame.fromMatrix(base + up * 5, up, right), Color = palette.NavyRail, Material = "SmoothPlastic", Collide = false })
		add({ Class = "Part", Shape = "Cylinder", Name = "HoloRing", Folder = "Decor", Size = Vector3.new(0.2, 4, 4), CFrame = CFrame.fromMatrix(base + up * 10.4, up, right), Color = k % 2 == 0 and palette.Mint or palette.Violet, Material = "Neon", Transparency = 0.3, Collide = false })
	end

	-- Spawn spot markers
	local spawns = HubBuilder.SpawnCFrames(hub, 0, 0)
	for _, cf in ipairs(spawns) do
		add({
			Class = "Part",
			Shape = "Cylinder",
			Name = "SpawnSpot",
			Folder = "Decor",
			Size = Vector3.new(0.1, 4.5, 4.5),
			CFrame = CFrame.fromMatrix(cf.Position + up * 0.05, up, right),
			Color = palette.Mint,
			Material = "Neon",
			Transparency = 0.35,
			Collide = false,
		})
	end
	return specs
end

local function boardGui(part, title)
	local palette = GameConfig.Palette
	local surface = Instance.new("SurfaceGui")
	surface.Name = "Board"
	surface.Face = Enum.NormalId.Front
	surface.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	surface.PixelsPerStud = 30
	surface.LightInfluence = 0
	local function line(name, y, h, color, font, text)
		local label = Instance.new("TextLabel")
		label.Name = name
		label.BackgroundTransparency = 1
		label.Position = UDim2.fromScale(0.04, y)
		label.Size = UDim2.fromScale(0.92, h)
		label.TextScaled = true
		label.Font = font
		label.TextColor3 = color
		label.Text = text
		label.Parent = surface
	end
	line("BoardTitle", 0.06, 0.2, palette.Cyan, Enum.Font.GothamBlack, title or "ORBITAL GARAGE")
	line("BoardMain", 0.3, 0.38, palette.White, Enum.Font.GothamBlack, "WAITING FOR RACERS")
	line("BoardSub", 0.72, 0.18, palette.Mint, Enum.Font.GothamBold, "Roll down the practice chute while you wait")
	surface.Parent = part
end

function HubBuilder.Build(hub, parent, name, chuteWidth, makePart, title)
	local root = Instance.new("Folder")
	root.Name = name
	local folders = {}
	for _, folderName in ipairs({ "Floor", "Rails", "Decor" }) do
		local folder = Instance.new("Folder")
		folder.Name = folderName
		folder.Parent = root
		folders[folderName] = folder
	end
	local specs = HubBuilder.ComputeSpecs(hub, chuteWidth)
	for _, spec in ipairs(specs) do
		local isBoard = spec.Gui and spec.Gui.Kind == "Board"
		if isBoard then
			spec.Gui = nil
		end
		local part = makePart(spec, folders[spec.Folder])
		if isBoard then
			boardGui(part, title)
		end
	end
	root.Parent = parent
	return root, #specs
end

return HubBuilder
