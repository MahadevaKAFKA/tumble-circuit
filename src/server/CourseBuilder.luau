-- Builds the Phase A1 practice course from CourseData at server start.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CourseData = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("CourseData"))

local CourseBuilder = {}

local WORLD_UP = Vector3.new(0, 1, 0)

local STYLES = {
	Floor = {
		Color = Color3.fromRGB(226, 231, 240),
		Material = Enum.Material.SmoothPlastic,
		Physics = PhysicalProperties.new(1, 0.5, 0.2, 1, 1),
	},
	Start = {
		Color = Color3.fromRGB(196, 222, 255),
		Material = Enum.Material.SmoothPlastic,
		Physics = PhysicalProperties.new(1, 0.5, 0.2, 1, 1),
	},
	Ramp = {
		Color = Color3.fromRGB(176, 196, 222),
		Material = Enum.Material.SmoothPlastic,
		Physics = PhysicalProperties.new(1, 0.5, 0.2, 1, 1),
	},
	Finish = {
		Color = Color3.fromRGB(255, 236, 179),
		Material = Enum.Material.SmoothPlastic,
		Physics = PhysicalProperties.new(1, 0.6, 0.1, 1, 1),
	},
	Rail = {
		Color = Color3.fromRGB(58, 66, 86),
		Material = Enum.Material.SmoothPlastic,
		Physics = PhysicalProperties.new(1, 0.15, 0.55, 1, 1),
	},
	Bumper = {
		Color = Color3.fromRGB(255, 170, 0),
		Material = Enum.Material.SmoothPlastic,
		Physics = PhysicalProperties.new(1, 0.1, 0.9, 1, 1),
	},
	SweeperArm = {
		Color = Color3.fromRGB(230, 60, 60),
		Material = Enum.Material.SmoothPlastic,
		Physics = PhysicalProperties.new(5, 0.2, 0.5, 1, 1),
	},
	SweeperPost = {
		Color = Color3.fromRGB(60, 60, 70),
		Material = Enum.Material.SmoothPlastic,
		Physics = PhysicalProperties.new(1, 0.2, 0.5, 1, 1),
	},
}

local CHECKPOINT_IDLE = Color3.fromRGB(150, 160, 175)
local FINISH_GOLD = Color3.fromRGB(255, 200, 40)

-- A slab is described by the centre line of its TOP surface (from -> to).
-- Returns the part CFrame and the slab length.
local function slabCFrame(fromTop, toTop, thickness)
	local delta = toTop - fromTop
	local length = delta.Magnitude
	local look = delta.Unit
	local right = look:Cross(WORLD_UP)
	if right.Magnitude < 1e-4 then
		right = Vector3.new(1, 0, 0)
	end
	right = right.Unit
	local up = right:Cross(look)
	local midTop = (fromTop + toTop) * 0.5
	local center = midTop - up * (thickness * 0.5)
	return CFrame.fromMatrix(center, right, up), length
end
CourseBuilder.slabCFrame = slabCFrame

local function makePart(name, size, cframe, style, parent)
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Color = style.Color
	part.Material = style.Material
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	if style.Physics then
		part.CustomPhysicalProperties = style.Physics
	end
	part.Parent = parent
	return part
end

local function makeMarker(name, center, size, color, parent)
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Size = size
	part.CFrame = CFrame.new(center)
	part.Color = color
	part.Material = Enum.Material.Neon
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function makeSign(text, position, parent)
	local anchor = Instance.new("Part")
	anchor.Name = "Sign"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(1, 1, 1)
	anchor.CFrame = CFrame.new(position)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "Label"
	billboard.Size = UDim2.new(14, 0, 2.5, 0)
	billboard.MaxDistance = 220
	billboard.LightInfluence = 0
	billboard.Parent = anchor

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 1, 0)
	label.Text = text
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextStrokeTransparency = 0.2
	label.Parent = billboard

	anchor.Parent = parent
	return anchor
end

local function buildSweeper(sweeper, parent)
	local postCFrame = CFrame.new(sweeper.Base + Vector3.new(0, sweeper.PostHeight * 0.5, 0))
		* CFrame.Angles(0, 0, math.pi * 0.5)
	local post = makePart(
		sweeper.Name .. "Post",
		Vector3.new(sweeper.PostHeight, sweeper.PostDiameter, sweeper.PostDiameter),
		postCFrame,
		STYLES.SweeperPost,
		parent
	)
	post.Shape = Enum.PartType.Cylinder

	local armCenter = sweeper.Base + Vector3.new(0, sweeper.FloorGap + sweeper.ArmHeight * 0.5, 0)
	local arm = makePart(
		sweeper.Name .. "Arm",
		Vector3.new(sweeper.ArmLength, sweeper.ArmHeight, sweeper.ArmThickness),
		CFrame.new(armCenter),
		STYLES.SweeperArm,
		parent
	)
	arm.Anchored = false

	-- Hinge axis is the attachments' X axis; rotate it to point straight up.
	local axis = CFrame.new(armCenter) * CFrame.Angles(0, 0, math.pi * 0.5)
	local postAttachment = Instance.new("Attachment")
	postAttachment.Name = "HingeAttachment"
	postAttachment.CFrame = post.CFrame:ToObjectSpace(axis)
	postAttachment.Parent = post

	local armAttachment = Instance.new("Attachment")
	armAttachment.Name = "HingeAttachment"
	armAttachment.CFrame = arm.CFrame:ToObjectSpace(axis)
	armAttachment.Parent = arm

	local hinge = Instance.new("HingeConstraint")
	hinge.Name = "Motor"
	hinge.Attachment0 = postAttachment
	hinge.Attachment1 = armAttachment
	hinge.ActuatorType = Enum.ActuatorType.Motor
	hinge.AngularVelocity = sweeper.AngularSpeed
	hinge.MotorMaxTorque = 1e8
	hinge.Parent = arm

	local noCollide = Instance.new("NoCollisionConstraint")
	noCollide.Part0 = post
	noCollide.Part1 = arm
	noCollide.Parent = arm

	-- The server simulates the sweeper so every player sees the same motion.
	if arm:IsDescendantOf(Workspace) then
		local ok, err = pcall(function()
			arm:SetNetworkOwner(nil)
		end)
		if not ok then
			warn("[TumbleCircuit] sweeper ownership: " .. tostring(err))
		end
	end
	return arm
end

local function placeSpawn()
	local spawnLocation = Workspace:FindFirstChild("StartSpawn")
	if not (spawnLocation and spawnLocation:IsA("SpawnLocation")) then
		spawnLocation = Instance.new("SpawnLocation")
		spawnLocation.Name = "StartSpawn"
		spawnLocation.Parent = Workspace
	end
	local start = CourseData.Checkpoints[1]
	spawnLocation.Anchored = true
	spawnLocation.Neutral = true
	spawnLocation.Duration = 0
	spawnLocation.CanCollide = false
	spawnLocation.CanQuery = false
	spawnLocation.CanTouch = false
	spawnLocation.Transparency = 1
	spawnLocation.Size = Vector3.new(6, 1, 6)
	spawnLocation.CFrame = CFrame.new(start.Spawn - Vector3.new(0, 0.45, 0))
	return spawnLocation
end

function CourseBuilder.build()
	local existing = Workspace:FindFirstChild("Course")
	if existing then
		existing:Destroy()
	end

	local course = Instance.new("Folder")
	course.Name = "Course"
	local floors = Instance.new("Folder")
	floors.Name = "Floors"
	floors.Parent = course
	local rails = Instance.new("Folder")
	rails.Name = "Rails"
	rails.Parent = course
	local obstacles = Instance.new("Folder")
	obstacles.Name = "Obstacles"
	obstacles.Parent = course
	local markers = Instance.new("Folder")
	markers.Name = "Markers"
	markers.Parent = course

	for _, slab in ipairs(CourseData.Slabs) do
		local cframe, length = slabCFrame(slab.From, slab.To, slab.Thickness)
		local style = STYLES[slab.Style] or STYLES.Floor
		makePart(slab.Name, Vector3.new(slab.Width, slab.Thickness, length), cframe, style, floors)
	end

	for _, rail in ipairs(CourseData.Rails) do
		local cframe, length = slabCFrame(rail.From, rail.To, CourseData.RailThickness)
		makePart(
			rail.Name,
			Vector3.new(CourseData.RailWidth, CourseData.RailThickness, length + CourseData.RailWidth),
			cframe,
			STYLES.Rail,
			rails
		)
	end

	for _, bumper in ipairs(CourseData.Bumpers) do
		local cframe = CFrame.new(bumper.Base + Vector3.new(0, bumper.Height * 0.5, 0)) * CFrame.Angles(0, 0, math.pi * 0.5)
		local part = makePart(
			bumper.Name,
			Vector3.new(bumper.Height, bumper.Diameter, bumper.Diameter),
			cframe,
			STYLES.Bumper,
			obstacles
		)
		part.Shape = Enum.PartType.Cylinder
	end

	for index, checkpoint in ipairs(CourseData.Checkpoints) do
		local strip = makeMarker(
			"CheckpointStrip" .. index,
			checkpoint.StripCenter,
			checkpoint.StripSize,
			CHECKPOINT_IDLE,
			markers
		)
		strip:SetAttribute("CheckpointIndex", index)
	end
	makeMarker("FinishStrip", CourseData.Finish.StripCenter, CourseData.Finish.StripSize, FINISH_GOLD, markers)

	for _, sign in ipairs(CourseData.Signs) do
		makeSign(sign.Text, sign.Position, markers)
	end

	course.Parent = Workspace

	-- Unanchored moving parts are created after the course is in the workspace so
	-- their network owner can be set.
	for _, sweeper in ipairs(CourseData.Sweepers) do
		buildSweeper(sweeper, obstacles)
	end

	placeSpawn()
	return course
end

return CourseBuilder
