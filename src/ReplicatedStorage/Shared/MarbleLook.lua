--[[
	MarbleLook (B3) — builds a catalog marble's look on a ball. Used by the server (real marbles)
	and by the garage preview (a ViewportFrame copy). Visual only:
	- the ball keeps its size, shape, physical properties and collision; only Color / Material /
	  Reflectance change
	- every extra part is Massless, CanCollide/CanQuery/CanTouch false, CastShadow false, and
	  attached with `attach(ball, part)` (a weld on the server, a plain parent in a viewport)
	- the trail is a Trail between two attachments (disabled locally on Low graphics)
]]

local MarbleLook = {}

local function shell(props)
	local part = Instance.new("Part")
	part.Massless = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in pairs(props) do
		part[key] = value
	end
	return part
end

-- golden-spiral points on a unit sphere (deterministic speckles)
local function spiral(n)
	local out = {}
	local golden = math.pi * (3 - math.sqrt(5))
	for i = 0, n - 1 do
		local y = 1 - (i / (n - 1)) * 2
		local r = math.sqrt(1 - y * y)
		local theta = golden * i
		out[#out + 1] = Vector3.new(math.cos(theta) * r, y, math.sin(theta) * r)
	end
	return out
end

-- Returns the list of shell specs { size, offset CFrame, color, material, shape } (pure: testable)
function MarbleLook.Specs(look, diameter)
	local specs = {}
	local accent = look.accent or Color3.new(1, 1, 1)
	local accent2 = look.accent2 or accent
	local mat = look.glow and "Neon" or "SmoothPlastic"
	local function ring(cf, color, extra, width)
		specs[#specs + 1] = { shape = "Cylinder", size = Vector3.new(width or 0.5, diameter + (extra or 0.08), diameter + (extra or 0.08)), offset = cf, color = color, material = mat }
	end
	local p = look.pattern or "None"
	if p == "Stripes" then
		ring(CFrame.new(), accent)
		ring(CFrame.Angles(0, math.pi / 2, 0), accent2)
	elseif p == "Ring" then
		ring(CFrame.Angles(0, 0, math.pi / 2), accent)
	elseif p == "Bands" then
		for i, x in ipairs({ -0.9, 0, 0.9 }) do
			local d = math.sqrt(math.max(0.1, (diameter / 2) ^ 2 - x * x)) * 2
			specs[#specs + 1] = { shape = "Cylinder", size = Vector3.new(0.35, d + 0.08, d + 0.08), offset = CFrame.new(x, 0, 0), color = i == 2 and accent2 or accent, material = mat }
		end
	elseif p == "Speckle" then
		for _, dir in ipairs(spiral(12)) do
			specs[#specs + 1] = { shape = "Ball", size = Vector3.new(0.55, 0.55, 0.55), offset = CFrame.new(dir * (diameter / 2 - 0.12)), color = accent, material = mat }
		end
	elseif p == "Halo" then
		ring(CFrame.Angles(0, 0, math.pi / 2), accent, 1.4, 0.25)
		ring(CFrame.Angles(0, 0, math.pi / 2), accent2, 0.08, 0.35)
	elseif p == "Core" then
		ring(CFrame.Angles(0, 0, math.pi / 2), accent, 0.08, 0.3)
		ring(CFrame.Angles(math.pi / 2, 0, 0), accent, 0.08, 0.3)
	elseif p == "Orbit" then
		ring(CFrame.Angles(0, 0, math.rad(55)), accent, 0.6, 0.25)
		ring(CFrame.Angles(0, 0, math.rad(-55)), accent2, 0.6, 0.25)
	end
	return specs
end

function MarbleLook.Apply(ball, item, attach, trailItem)
	local look = item and item.Look
	if not look then
		return
	end
	ball.Color = look.color
	local ok = pcall(function()
		ball.Material = Enum.Material[look.material or "SmoothPlastic"]
	end)
	if not ok then
		ball.Material = Enum.Material.SmoothPlastic
	end
	ball.Reflectance = look.reflectance or 0.2
	local diameter = ball.Size.X
	for i, spec in ipairs(MarbleLook.Specs(look, diameter)) do
		local part = shell({
			Name = "Look" .. i,
			Shape = spec.shape == "Ball" and Enum.PartType.Ball or Enum.PartType.Cylinder,
			Size = spec.size,
			Color = spec.color,
			Material = Enum.Material[spec.material],
		})
		part.CFrame = ball.CFrame * spec.offset
		attach(ball, part, spec.offset)
	end
	if trailItem and trailItem.Colors then
		local a0 = Instance.new("Attachment")
		a0.Name = "TrailA"
		a0.Position = Vector3.new(0, 0.9, 0)
		local a1 = Instance.new("Attachment")
		a1.Name = "TrailB"
		a1.Position = Vector3.new(0, -0.9, 0)
		local trail = Instance.new("Trail")
		trail.Name = "TC_Trail"
		trail.Attachment0, trail.Attachment1 = a0, a1
		trail.Color = ColorSequence.new(trailItem.Colors[1], trailItem.Colors[2])
		trail.Transparency = NumberSequence.new(0.25, 1)
		trail.Lifetime = 0.45
		trail.MinLength = 0.2
		trail.LightEmission = 0.6
		a0.Parent, a1.Parent = ball, ball
		trail.Parent = ball
	end
end

return MarbleLook
