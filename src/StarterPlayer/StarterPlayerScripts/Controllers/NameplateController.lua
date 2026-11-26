--[[
	NameplateController (2026-11-26 three-lap brief) — declutters the other racers' name tags.

	The playtest screenshot showed a row of big "BOT" tags covering the road at the start. Tags
	are now small fixed-pixel chips (BotFactory.AddNameplate) and this controller decides, a few
	times a second, which ones are shown:
	  * none on the start grid (Preparing / Countdown) and none while the HUD is in capture view
	  * not when the marble is very close to the camera (it is right there) or far away
	  * at most MaxShown, nearest first, and never two whose screen positions overlap
	Pure decision (Decide) + a thin Roblox adapter (Step). Bots are named in the standings.
]]

local Nameplates = {}
Nameplates.__index = Nameplates

Nameplates.MinDistance = 16 -- studs from the camera
Nameplates.MaxDistance = 70
Nameplates.MaxShown = 3
Nameplates.MinScreenGap = 70 -- px between two shown tags

-- candidates: { { id, distance, x, y, onScreen } }; opts = { hideAll }. Returns { [id] = true }.
function Nameplates.Decide(candidates, opts)
	local show = {}
	if opts and opts.hideAll then
		return show
	end
	local list = {}
	for _, c in ipairs(candidates) do
		if c.onScreen and c.distance >= Nameplates.MinDistance and c.distance <= Nameplates.MaxDistance then
			list[#list + 1] = c
		end
	end
	table.sort(list, function(a, b)
		if a.distance ~= b.distance then
			return a.distance < b.distance
		end
		return tostring(a.id) < tostring(b.id)
	end)
	local shown = {}
	for _, c in ipairs(list) do
		if #shown >= Nameplates.MaxShown then
			break
		end
		local clear = true
		for _, s in ipairs(shown) do
			local dx, dy = c.x - s.x, c.y - s.y
			if dx * dx + dy * dy < Nameplates.MinScreenGap * Nameplates.MinScreenGap then
				clear = false
				break
			end
		end
		if clear then
			shown[#shown + 1] = c
			show[c.id] = true
		end
	end
	return show
end

function Nameplates.new()
	return setmetatable({ timer = 0 }, Nameplates)
end

-- folder = the marbles folder; ownBall = never tagged; hideAll = grid / capture view
function Nameplates:Step(dt, folder, ownBall, hideAll)
	self.timer = self.timer + dt
	if self.timer < 0.15 or not folder then
		return
	end
	self.timer = 0
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local camPos = camera.CFrame.Position
	local candidates, plates = {}, {}
	for _, ball in ipairs(folder:GetChildren()) do
		local plate = ball ~= ownBall and ball:FindFirstChild("Nameplate")
		if plate and plate:IsA("BillboardGui") and ball:IsA("BasePart") then
			local point, onScreen = camera:WorldToViewportPoint(ball.Position + Vector3.new(0, 3.4, 0))
			local id = ball.Name
			plates[id] = plate
			candidates[#candidates + 1] = { id = id, distance = (ball.Position - camPos).Magnitude, x = point.X, y = point.Y, onScreen = onScreen and point.Z > 0 }
		end
	end
	local show = Nameplates.Decide(candidates, { hideAll = hideAll })
	for id, plate in pairs(plates) do
		local want = show[id] == true
		if plate.Enabled ~= want then
			plate.Enabled = want
		end
	end
end

return Nameplates
