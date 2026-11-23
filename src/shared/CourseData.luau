-- Course data for the Phase A1 practice course.
-- The raw numbers live in CourseLayout.json (Rojo turns it into a ModuleScript),
-- so the layout can be checked by tools outside Roblox. This module converts the
-- arrays into Vector3 / CFrame values and adds a few helpers that both the server
-- (course building, checkpoint detection) and the client (respawning) use.

local Layout = require(script.Parent:WaitForChild("CourseLayout"))

local CourseData = {}

local function vec(list)
	return Vector3.new(list[1], list[2], list[3])
end

CourseData.KillY = Layout.KillY
CourseData.RailWidth = Layout.RailWidth
CourseData.RailThickness = Layout.RailThickness

CourseData.Slabs = {}
for _, slab in ipairs(Layout.Slabs) do
	table.insert(CourseData.Slabs, {
		Name = slab.Name,
		From = vec(slab.From),
		To = vec(slab.To),
		Width = slab.Width,
		Thickness = slab.Thickness,
		Style = slab.Style,
	})
end

CourseData.Rails = {}
for _, rail in ipairs(Layout.Rails) do
	table.insert(CourseData.Rails, {
		Name = rail.Name,
		From = vec(rail.From),
		To = vec(rail.To),
	})
end

CourseData.Bumpers = {}
for _, bumper in ipairs(Layout.Bumpers) do
	table.insert(CourseData.Bumpers, {
		Name = bumper.Name,
		Base = vec(bumper.Base),
		Height = bumper.Height,
		Diameter = bumper.Diameter,
	})
end

CourseData.Sweepers = {}
for _, sweeper in ipairs(Layout.Sweepers) do
	table.insert(CourseData.Sweepers, {
		Name = sweeper.Name,
		Base = vec(sweeper.Base),
		ArmLength = sweeper.ArmLength,
		ArmHeight = sweeper.ArmHeight,
		ArmThickness = sweeper.ArmThickness,
		FloorGap = sweeper.FloorGap,
		PostHeight = sweeper.PostHeight,
		PostDiameter = sweeper.PostDiameter,
		AngularSpeed = sweeper.AngularSpeed,
	})
end

CourseData.Checkpoints = {}
for index, checkpoint in ipairs(Layout.Checkpoints) do
	table.insert(CourseData.Checkpoints, {
		Index = index,
		Name = checkpoint.Name,
		Spawn = vec(checkpoint.Spawn),
		Yaw = math.rad(checkpoint.YawDegrees),
		ZoneCenter = vec(checkpoint.ZoneCenter),
		ZoneSize = vec(checkpoint.ZoneSize),
		StripCenter = vec(checkpoint.StripCenter),
		StripSize = vec(checkpoint.StripSize),
	})
end

CourseData.Finish = {
	ZoneCenter = vec(Layout.Finish.ZoneCenter),
	ZoneSize = vec(Layout.Finish.ZoneSize),
	StripCenter = vec(Layout.Finish.StripCenter),
	StripSize = vec(Layout.Finish.StripSize),
}

CourseData.Signs = {}
for _, sign in ipairs(Layout.Signs) do
	table.insert(CourseData.Signs, {
		Text = sign.Text,
		Position = vec(sign.Position),
	})
end

-- True when a point is inside an axis-aligned box.
function CourseData.isInZone(position, center, size)
	local offset = position - center
	return math.abs(offset.X) <= size.X * 0.5
		and math.abs(offset.Y) <= size.Y * 0.5
		and math.abs(offset.Z) <= size.Z * 0.5
end

-- Where a marble of the given radius should appear for a checkpoint.
-- Returns the CFrame (position + facing) and the checkpoint entry.
function CourseData.getSpawnCFrame(index, radius)
	local checkpoint = CourseData.Checkpoints[index] or CourseData.Checkpoints[1]
	local position = checkpoint.Spawn + Vector3.new(0, radius + 0.5, 0)
	return CFrame.new(position) * CFrame.Angles(0, checkpoint.Yaw, 0), checkpoint
end

-- CFrame at `position` looking toward `target` (world up), built without
-- CFrame.lookAt so it works with every linter standard library.
function CourseData.lookAt(position, target)
	local look = target - position
	if look.Magnitude < 1e-4 then
		return CFrame.new(position)
	end
	look = look.Unit
	local right = look:Cross(Vector3.new(0, 1, 0))
	if right.Magnitude < 1e-4 then
		right = Vector3.new(1, 0, 0)
	end
	right = right.Unit
	local up = right:Cross(look)
	return CFrame.fromMatrix(position, right, up)
end

return CourseData
