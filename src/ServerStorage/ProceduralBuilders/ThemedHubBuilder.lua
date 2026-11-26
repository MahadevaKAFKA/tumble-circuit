--[[
	ThemedHubBuilder (promo pack prompts 04 / 07 / 08 / 09) — map hubs with their own silhouette.
	Same interaction contract as the Orbital Garage (HubBuilder): a deck with a rim open where
	the practice lane leaves, a NextRaceBoard (same Board gui the clients update), a 16-spot
	spawn ring, plus:
	  * a MAPS selector kiosk next to the spawn ring with a SelectorPad (rolling onto it opens
	    Map Selection; the MAPS button does the same on any device)
	  * a RACE DEPARTURES sign with a painted lane from the ring (the race queue is the JOIN RACE
	    button; the lane just shows where races leave from)
	  * a PRACTICE arch over the practice-lane entrance
	  * a landmark that names the map: Terminal = tethered balloon + canvas awnings + clouds;
	    Basalt = furnace window + chimney + amber instrument panels
	Deck = regular polygon (Terminal: 8 sides, Basalt: 6) with in-radius = Geometry.Radius, so
	the client's free-roam circle always lies on the floor. Pure specs + Build().
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local PhysicsConfig = require(Shared:WaitForChild("PhysicsConfig"))
local HubBuilder = require(script.Parent:WaitForChild("HubBuilder"))

local Themed = {}

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

Themed.Styles = {
	Terminal = {
		Sides = 8,
		Floor = { Color = rgb(255, 242, 203), Material = "WoodPlanks" },
		Inlay = rgb(160, 233, 206),
		Rail = { Color = rgb(40, 70, 141), Material = "SmoothPlastic" },
		RailCap = rgb(240, 139, 174),
		Spot = rgb(240, 139, 174),
		Accent = rgb(160, 233, 206),
		Kiosk = { Body = rgb(40, 70, 141), Roof = rgb(240, 139, 174), Text = rgb(255, 242, 203) },
		PracticeText = "PRACTICE  -  BOUNCE DRUM",
		Landmark = "Balloon",
	},
	Basalt = {
		Sides = 6,
		Floor = { Color = rgb(52, 44, 50), Material = "Basalt" },
		Inlay = rgb(255, 189, 93),
		Rail = { Color = rgb(70, 58, 60), Material = "Slate" },
		RailCap = rgb(255, 112, 71),
		Spot = rgb(255, 189, 93),
		Accent = rgb(255, 189, 93),
		Kiosk = { Body = rgb(70, 58, 60), Roof = rgb(255, 112, 71), Text = rgb(221, 232, 241) },
		PracticeText = "PRACTICE  -  SLOW PISTON",
		Landmark = "Furnace",
	},
}

local UP = Vector3.new(0, 1, 0)

-- Pure: deck polygon helpers. Edge k is centred at angle k * 2pi/n from the chute heading.
function Themed.EdgeDirection(look, right, n, k)
	local a = k * 2 * math.pi / n
	return look * math.cos(a) + right * math.sin(a)
end

function Themed.KioskPosition(hub)
	local look, right = HubBuilder.HeadingVectors(hub.ChuteHeadingDeg)
	return hub.Center - right * (hub.SpawnRingRadius + 9) - look * 4, hub.Center - right * (hub.SpawnRingRadius + 4.5) - look * 4
end

function Themed.ComputeSpecs(hub, chuteWidth, chuteLayout)
	local style = Themed.Styles[hub.Style or ""] or Themed.Styles.Terminal
	local palette = GameConfig.Palette
	local track = PhysicsConfig.Track
	local specs = {}
	local function add(spec)
		specs[#specs + 1] = spec
		return spec
	end
	local look, right = HubBuilder.HeadingVectors(hub.ChuteHeadingDeg)
	local floorPhysics = { Density = 0.7, Friction = track.FloorFriction, Elasticity = track.FloorElasticity, FrictionWeight = 1, ElasticityWeight = 1 }
	local railPhysics = { Density = 0.7, Friction = track.RailFriction, Elasticity = track.RailElasticity, FrictionWeight = 1, ElasticityWeight = 1 }
	local n, R = style.Sides, hub.Radius
	local edge = 2 * R * math.tan(math.pi / n)

	-- floor: n/2 strips (length 2R across opposite edges, width = one edge) = the polygon
	for k = 0, n / 2 - 1 do
		local dir = Themed.EdgeDirection(look, right, n, k)
		local side = dir:Cross(UP)
		add({
			Class = "Part",
			Name = "HubFloor",
			Folder = "Floor",
			Size = Vector3.new(edge + 0.2, hub.FloorThickness, 2 * R),
			CFrame = CFrame.fromMatrix(hub.Center - UP * (hub.FloorThickness / 2), side, UP),
			Color = style.Floor.Color,
			Material = style.Floor.Material,
			Physics = floorPhysics,
		})
	end
	add({ Class = "Part", Shape = "Cylinder", Name = "HubRing", Folder = "Decor", Size = Vector3.new(0.1, hub.SpawnRingRadius * 2 + 2, hub.SpawnRingRadius * 2 + 2), CFrame = CFrame.fromMatrix(hub.Center + UP * 0.04, UP, right), Color = style.Inlay, Material = "Neon", Transparency = 0.55, Collide = false })

	-- rim: every edge except edge 0 (the practice-lane exit)
	local railLength = 2 * (R + 0.6) * math.tan(math.pi / n) + 1.2
	for k = 1, n - 1 do
		local dir = Themed.EdgeDirection(look, right, n, k)
		local position = hub.Center + dir * (R + 0.6) + UP * ((hub.RimHeight - hub.FloorThickness) / 2)
		local wall = add({
			Class = "Part",
			Name = "Rim",
			Folder = "Rails",
			Size = Vector3.new(1.2, hub.RimHeight + hub.FloorThickness, railLength),
			CFrame = CFrame.fromMatrix(position, dir, UP),
			Color = style.Rail.Color,
			Material = style.Rail.Material,
			Physics = railPhysics,
		})
		add({ Class = "Part", Name = "RimCap", Folder = "Decor", Size = Vector3.new(1.3, 0.3, railLength), CFrame = wall.CFrame * CFrame.new(0, wall.Size.Y / 2 + 0.15, 0), Color = style.RailCap, Material = "Neon", Collide = false })
	end

	-- next-race board over the practice exit (same Board gui contract as the Garage)
	local boardPos = hub.Center + look * (R + 4) + UP * 17
	add({ Class = "Part", Name = "NextRaceBoard", Folder = "Decor", Size = Vector3.new(30, 11, 0.6), CFrame = CFrame.lookAt(boardPos, boardPos - look), Color = palette.Ink, Material = "SmoothPlastic", Transparency = 0.15, Collide = false, Gui = { Kind = "Board" } })
	for _, side in ipairs({ -1, 1 }) do
		add({ Class = "Part", Name = "BoardPillar", Folder = "Decor", Size = Vector3.new(1, 22, 1), CFrame = CFrame.new(boardPos + right * (side * 15.5) - UP * 5.5), Color = style.Accent, Material = "Neon", Collide = false })
	end

	-- practice arch over the exit
	local archBase = hub.Center + look * (R - 1)
	local half = chuteWidth / 2 + 1.5
	for _, side in ipairs({ -1, 1 }) do
		add({ Class = "Part", Name = "PracticeArchPost", Folder = "Decor", Size = Vector3.new(1, 10, 1), CFrame = CFrame.new(archBase + right * (side * half) + UP * 5), Color = style.Rail.Color, Material = "SmoothPlastic", Collide = false })
	end
	local archSign = archBase + UP * 10.5
	add({ Class = "Part", Name = "PracticeArch", Folder = "Decor", Size = Vector3.new(half * 2 + 1, 2.4, 0.4), CFrame = CFrame.lookAt(archSign, archSign + look), Color = palette.Ink, Material = "SmoothPlastic", Collide = false, Gui = { Kind = "Surface", Text = style.PracticeText, Color = style.Accent } })

	-- MAPS kiosk beside the spawn ring + the pad that opens Map Selection
	local kiosk, pad = Themed.KioskPosition(hub)
	local toCenter = (hub.Center - kiosk).Unit
	add({ Class = "Part", Name = "KioskBody", Folder = "Rails", Size = Vector3.new(6, 6, 3), CFrame = CFrame.lookAt(kiosk + UP * 3, kiosk + UP * 3 + toCenter), Color = style.Kiosk.Body, Material = "SmoothPlastic", Physics = railPhysics })
	add({ Class = "Part", Name = "KioskRoof", Folder = "Decor", Size = Vector3.new(7, 0.6, 4), CFrame = CFrame.lookAt(kiosk + UP * 6.4, kiosk + UP * 6.4 + toCenter), Color = style.Kiosk.Roof, Material = "Neon", Collide = false })
	local kioskSign = kiosk + UP * 4 + toCenter * 1.6
	add({ Class = "Part", Name = "KioskSign", Folder = "Decor", Size = Vector3.new(5, 2, 0.2), CFrame = CFrame.lookAt(kioskSign, kioskSign - toCenter), Color = palette.Ink, Material = "SmoothPlastic", Collide = false, Gui = { Kind = "Surface", Text = "MAPS", Color = style.Kiosk.Text } })
	add({ Class = "Part", Shape = "Cylinder", Name = "SelectorPad", Folder = "Decor", Size = Vector3.new(0.12, 7, 7), CFrame = CFrame.fromMatrix(pad + UP * 0.06, UP, right), Color = style.Accent, Material = "Neon", Transparency = 0.25, Collide = false, Attributes = { TC_Selector = true, Radius = 3.5 } })

	-- race departures: sign + painted lane from the ring
	local dep = hub.Center + right * (hub.SpawnRingRadius + 9) - look * 4
	local depSign = dep + UP * 5
	add({ Class = "Part", Name = "DeparturesSign", Folder = "Decor", Size = Vector3.new(12, 3.2, 0.4), CFrame = CFrame.lookAt(depSign, depSign + (dep - hub.Center).Unit), Color = palette.Ink, Material = "SmoothPlastic", Collide = false, Gui = { Kind = "Surface", Text = "RACE DEPARTURES - TAP JOIN RACE", Color = style.Accent } })
	for _, side in ipairs({ -1, 1 }) do
		add({ Class = "Part", Name = "DeparturesPost", Folder = "Decor", Size = Vector3.new(0.6, 6.6, 0.6), CFrame = CFrame.new(dep + look * (side * 5.6) + UP * 3.3), Color = style.Rail.Color, Material = "SmoothPlastic", Collide = false })
	end
	for i = 0, 2 do
		local p = hub.Center + right * (hub.SpawnRingRadius + 1.5 + i * 2.5) - look * 4
		add({ Class = "Part", Name = "LaneStripe", Folder = "Decor", Size = Vector3.new(1.2, 0.08, 4), CFrame = CFrame.fromMatrix(p + UP * 0.05, right, UP), Color = style.Accent, Material = "Neon", Transparency = 0.3, Collide = false })
	end

	-- spawn spots
	for _, cf in ipairs(HubBuilder.SpawnCFrames(hub, 0, 0)) do
		add({ Class = "Part", Shape = "Cylinder", Name = "SpawnSpot", Folder = "Decor", Size = Vector3.new(0.1, 4.5, 4.5), CFrame = CFrame.fromMatrix(cf.Position + UP * 0.05, UP, right), Color = style.Spot, Material = "Neon", Transparency = 0.35, Collide = false })
	end

	-- landmark
	local back = hub.Center - look * (R + 14)
	if style.Landmark == "Balloon" then
		local balloon = back + UP * 44
		add({ Class = "Part", Shape = "Ball", Name = "TetheredBalloon", Folder = "Decor", Size = Vector3.new(26, 26, 26), CFrame = CFrame.new(balloon), Color = rgb(240, 139, 174), Material = "SmoothPlastic", Collide = false })
		for _, dy in ipairs({ -5, 5 }) do
			local r = math.sqrt(13 * 13 - dy * dy) * 2 + 0.4
			add({ Class = "Part", Shape = "Cylinder", Name = "BalloonBand", Folder = "Decor", Size = Vector3.new(1.2, r, r), CFrame = CFrame.fromMatrix(balloon + UP * dy, UP, right), Color = rgb(255, 242, 203), Material = "SmoothPlastic", Collide = false })
		end
		local basket = balloon - UP * 19
		add({ Class = "Part", Name = "BalloonBasket", Folder = "Decor", Size = Vector3.new(5, 4, 5), CFrame = CFrame.new(basket), Color = rgb(150, 100, 60), Material = "WoodPlanks", Collide = false })
		local mooring = hub.Center - look * (R - 3)
		add({ Class = "Part", Name = "MooringPost", Folder = "Decor", Size = Vector3.new(1.6, 6, 1.6), CFrame = CFrame.new(mooring + UP * 3), Color = rgb(40, 70, 141), Material = "SmoothPlastic", Collide = false })
		local a, b = mooring + UP * 6, basket - UP * 2
		add({ Class = "Part", Name = "Tether", Folder = "Decor", Size = Vector3.new(0.3, 0.3, (b - a).Magnitude), CFrame = CFrame.lookAt((a + b) / 2, b), Color = rgb(255, 242, 203), Material = "SmoothPlastic", Collide = false })
		-- canvas awnings: striped canopies over the three back edges
		for _, k in ipairs({ 3, 4, 5 }) do
			local dir = Themed.EdgeDirection(look, right, n, k)
			local along = dir:Cross(UP)
			for s = -2, 2 do
				local p = hub.Center + dir * (R - 3) + along * (s * 5.4) + UP * 9
				add({ Class = "Part", Name = "Awning", Folder = "Decor", Size = Vector3.new(5.4, 0.3, 7), CFrame = CFrame.fromMatrix(p, along, UP) * CFrame.Angles(math.rad(-18), 0, 0), Color = s % 2 == 0 and rgb(240, 139, 174) or rgb(255, 242, 203), Material = "Fabric", Collide = false })
			end
			for _, s in ipairs({ -2.5, 2.5 }) do
				add({ Class = "Part", Name = "AwningPost", Folder = "Decor", Size = Vector3.new(0.5, 9, 0.5), CFrame = CFrame.new(hub.Center + dir * (R - 0.5) + along * (s * 5.4) + UP * 4.5), Color = rgb(40, 70, 141), Material = "SmoothPlastic", Collide = false })
			end
		end
		for c = 0, 6 do
			local a2 = c / 7 * math.pi * 2 + 0.4
			local p = hub.Center + (look * math.cos(a2) + right * math.sin(a2)) * (R + 10 + (c % 3) * 6) - UP * (8 + (c % 2) * 5)
			add({ Class = "Part", Shape = "Ball", Name = "Cloud", Folder = "Decor", Size = Vector3.new(14 + c % 3 * 4, 14 + c % 3 * 4, 14 + c % 3 * 4), CFrame = CFrame.new(p), Color = rgb(250, 250, 255), Material = "SmoothPlastic", Transparency = 0.05, Collide = false })
		end
	else
		-- furnace window on the back edge + chimney + amber instrument panels
		local wall = back + look * 8 + UP * 9
		add({ Class = "Part", Name = "FurnaceWall", Folder = "Decor", Size = Vector3.new(30, 18, 2), CFrame = CFrame.lookAt(wall, wall + look), Color = rgb(41, 35, 41), Material = "Basalt", Collide = false })
		add({ Class = "Part", Name = "FurnaceWindow", Folder = "Decor", Size = Vector3.new(22, 10, 0.3), CFrame = CFrame.lookAt(wall + look * 1.1, wall + look * 2), Color = rgb(255, 112, 71), Material = "Neon", Collide = false })
		for _, dx in ipairs({ -7.5, 0, 7.5 }) do
			add({ Class = "Part", Name = "FurnaceBar", Folder = "Decor", Size = Vector3.new(0.6, 10.4, 0.6), CFrame = CFrame.lookAt(wall + look * 1.4 + right * dx, wall + look * 3 + right * dx), Color = rgb(120, 110, 112), Material = "DiamondPlate", Collide = false })
		end
		add({ Class = "Part", Shape = "Cylinder", Name = "Chimney", Folder = "Decor", Size = Vector3.new(44, 8, 8), CFrame = CFrame.fromMatrix(back - look * 4 + right * 10 + UP * 22, UP, right), Color = rgb(41, 35, 41), Material = "Basalt", Collide = false })
		add({ Class = "Part", Shape = "Cylinder", Name = "ChimneyGlow", Folder = "Decor", Size = Vector3.new(0.4, 8.4, 8.4), CFrame = CFrame.fromMatrix(back - look * 4 + right * 10 + UP * 44, UP, right), Color = rgb(255, 189, 93), Material = "Neon", Collide = false })
		for _, k in ipairs({ 2, 4 }) do
			local dir = Themed.EdgeDirection(look, right, n, k)
			local p = hub.Center + dir * (R - 2) + UP * 4
			add({ Class = "Part", Name = "InstrumentPost", Folder = "Decor", Size = Vector3.new(0.8, 4, 0.8), CFrame = CFrame.new(p - UP * 2), Color = rgb(70, 58, 60), Material = "Slate", Collide = false })
			add({ Class = "Part", Name = "InstrumentPanel", Folder = "Decor", Size = Vector3.new(6, 3, 0.3), CFrame = CFrame.lookAt(p + UP * 1.5, p + UP * 1.5 - dir), Color = rgb(255, 189, 93), Material = "Neon", Transparency = 0.15, Collide = false })
		end
	end

	-- landing target on the practice lane (Terminal), from the lane's own layout
	if chuteLayout and chuteLayout.Resolve and hub.LandingTarget then
		local frame = chuteLayout.Resolve(hub.LandingTarget)
		if frame then
			for i, d in ipairs({ 13, 8.5, 4 }) do
				add({ Class = "Part", Shape = "Cylinder", Name = "LandingTarget", Folder = "Decor", Size = Vector3.new(0.1, d, d), CFrame = CFrame.fromMatrix(frame.Position + frame.Up * (0.04 + i * 0.02), frame.Up, frame.Right), Color = i % 2 == 1 and rgb(240, 139, 174) or rgb(255, 242, 203), Material = "Neon", Transparency = 0.3, Collide = false })
			end
		end
	end
	return specs
end

function Themed.Build(hub, parent, name, chuteWidth, makePart, title, chuteLayout)
	local root = Instance.new("Folder")
	root.Name = name
	local folders = {}
	for _, folderName in ipairs({ "Floor", "Rails", "Decor" }) do
		local folder = Instance.new("Folder")
		folder.Name = folderName
		folder.Parent = root
		folders[folderName] = folder
	end
	local specs = Themed.ComputeSpecs(hub, chuteWidth, chuteLayout)
	for _, spec in ipairs(specs) do
		local isBoard = spec.Gui and spec.Gui.Kind == "Board"
		if isBoard then
			spec.Gui = nil
		end
		local part = makePart(spec, folders[spec.Folder])
		if isBoard then
			HubBuilder.BoardGui(part, title)
		end
	end
	root.Parent = parent
	return root, #specs
end

return Themed
