--[[
	MarbleReadability (brief 3, 2026-11-26) — keeps YOUR marble readable on any surface:
	  * a soft contact shadow on the road under it (one raycast a frame; it fades with height,
	    so jumps and drops also read)
	  * a thin outline (one Highlight, outline only) - brighter with High contrast
	Visual only: no collision, no queries, nothing replicated. Rival marbles stay plain (budget).
]]

local Readability = {}
Readability.__index = Readability

Readability.MaxShadowHeight = 14 -- studs; the shadow is gone above this

-- Pure: shadow transparency and size for a ball `height` studs above the ground (radius r).
function Readability.ShadowFor(height, r)
	local u = math.clamp(height / Readability.MaxShadowHeight, 0, 1)
	return 0.45 + 0.55 * u, (2 * r) * (1.15 - 0.35 * u)
end

function Readability.new()
	local self = setmetatable({}, Readability)
	local shadow = Instance.new("Part")
	shadow.Name = "TC_ContactShadow"
	shadow.Shape = Enum.PartType.Cylinder
	shadow.Anchored = true
	shadow.CanCollide = false
	shadow.CanQuery = false
	shadow.CanTouch = false
	shadow.CastShadow = false
	shadow.Material = Enum.Material.SmoothPlastic
	shadow.Color = Color3.new(0, 0, 0)
	shadow.Size = Vector3.new(0.05, 4, 4)
	shadow.Transparency = 1
	self.shadow = shadow
	self.params = RaycastParams.new()
	self.params.FilterType = Enum.RaycastFilterType.Exclude
	return self
end

function Readability:Attach(ball, ignore, highContrast)
	self:Detach()
	self.ball = ball
	self.shadow.Parent = workspace
	local list = { ball, self.shadow }
	for _, item in ipairs(ignore or {}) do
		list[#list + 1] = item
	end
	self.params.FilterDescendantsInstances = list
	local ok, highlight = pcall(function()
		local h = Instance.new("Highlight")
		h.Name = "TC_Outline"
		h.FillTransparency = 1
		h.OutlineColor = Color3.new(1, 1, 1)
		h.OutlineTransparency = highContrast and 0.05 or 0.45
		h.DepthMode = Enum.HighlightDepthMode.Occluded
		h.Adornee = ball
		h.Parent = ball
		return h
	end)
	self.highlight = ok and highlight or nil
end

function Readability:SetHighContrast(on)
	if self.highlight then
		self.highlight.OutlineTransparency = on and 0.05 or 0.45
	end
end

-- visual only: a failure here must never break the render loop
function Readability:Step(radius)
	local ok = pcall(self._step, self, radius)
	if not ok then
		self.shadow.Transparency = 1
	end
end

function Readability:_step(radius)
	local ball = self.ball
	if not ball or not ball.Parent then
		self.shadow.Transparency = 1
		return
	end
	local origin = ball.Position
	local hit = workspace:Raycast(origin, Vector3.new(0, -(radius + Readability.MaxShadowHeight), 0), self.params)
	if not hit then
		self.shadow.Transparency = 1
		return
	end
	local distance = tonumber((origin - hit.Position).Magnitude)
	if not distance then
		return -- (offline proxies) nothing to draw
	end
	local height = math.max(0, distance - radius)
	local alpha, size = Readability.ShadowFor(height, radius)
	self.shadow.Transparency = alpha
	self.shadow.Size = Vector3.new(0.05, size, size)
	local n = hit.Normal
	local side = math.abs(tonumber(n.Y) or 1) < 0.95 and Vector3.new(0, 1, 0):Cross(n).Unit or Vector3.new(1, 0, 0)
	self.shadow.CFrame = CFrame.fromMatrix(hit.Position + n * 0.06, n, side)
end

function Readability:Detach()
	if self.highlight then
		self.highlight:Destroy()
		self.highlight = nil
	end
	self.ball = nil
	self.shadow.Transparency = 1
end

function Readability:Destroy()
	self:Detach()
	self.shadow:Destroy()
end

return Readability
