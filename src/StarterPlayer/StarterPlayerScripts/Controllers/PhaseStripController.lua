--[[
	PhaseStripController (owner brief 2026-11-26, section 4: "make the active phase and timer
	readable in one glance") — ONE compact strip, top centre: MAP · PHASE · TIMER.
	It is the only place the next-race countdown is shown on screen (the hub card now shows
	your queue status, the in-world board the map and the field), so nothing is duplicated.

	  Intermission  NEON FOUNDRY · QUEUE OPEN (or READY CHECK n/m) · NEXT RACE 0:14
	  Preparing     NEON FOUNDRY · ON THE GRID
	  Countdown     NEON FOUNDRY · STARTING (the big centre 3-2-1 is the cue)
	  Racing        hidden for racers (the race strip carries place / time / checkpoint);
	                spectators and the hub see NEON FOUNDRY · RACE LIVE · 1:12
	  Results       RESULTS · NEXT RACE SOON
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local RoundProtocol = require(Shared:WaitForChild("RoundProtocol"))
local TrackDefinitions = require(Shared:WaitForChild("TrackDefinitions"))
local Utility = require(Shared:WaitForChild("Utility"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local S = RoundProtocol.States
local palette = UIKit.Palette

local Phase = {}
Phase.__index = Phase

local function worldName(id)
	local def = id and TrackDefinitions.WorldsById[id]
	return def and string.upper(def.DisplayName) or nil
end

local function clock(seconds)
	return (Utility.formatTime(math.max(0, seconds or 0)):gsub("%.%d+$", ""))
end

-- Pure: the strip's three parts for a snapshot. ctx = { now, racing (you are racing) }.
-- Returns { map, phase, timer, live } or nil (hidden).
function Phase.Text(snap, ctx)
	if not snap then
		return nil
	end
	local now = ctx.now or 0
	local left = snap.stateEndsAt and math.max(0, snap.stateEndsAt - now) or nil
	if snap.state == S.Intermission then
		local phase = snap.readyOpen and string.format("READY CHECK %d/%d", snap.readyCount or 0, snap.queuedCount or 0) or "QUEUE OPEN"
		return { map = worldName(snap.nextWorldId) or "NEXT RACE", phase = phase, timer = left and ("NEXT RACE " .. clock(left)) or "", live = false }
	elseif snap.state == S.Preparing then
		return { map = worldName(snap.worldId) or "RACE", phase = "ON THE GRID", timer = "", live = true }
	elseif snap.state == S.Countdown then
		return { map = worldName(snap.worldId) or "RACE", phase = "STARTING", timer = "", live = true } -- the big 3-2-1 is the cue
	elseif snap.state == S.Racing then
		if ctx.racing then
			return nil -- the race strip shows your place, time and checkpoints
		end
		local elapsed = snap.raceStartedAt and (now - snap.raceStartedAt) or 0
		return { map = worldName(snap.worldId) or "RACE", phase = "RACE LIVE", timer = clock(elapsed), live = true }
	elseif snap.state == S.Results or snap.state == S.Cleanup then
		return { map = "RESULTS", phase = worldName(snap.worldId) or "", timer = "NEXT RACE SOON", live = false }
	end
	return { map = "WAITING FOR RACERS", phase = "", timer = "", live = false }
end

function Phase.new()
	local self = setmetatable({}, Phase)
	local gui, root, maid = UIKit.screen("TumblePhaseStrip", 12)
	self.gui, self.maid = gui, maid
	local strip = UIKit.panel(root, { Name = "PhaseStrip", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 8), Size = UDim2.fromOffset(460, 36), BackgroundColor3 = palette.Ink, BackgroundTransparency = 0.15 })
	self.strip = strip
	UIKit.new("UIStroke", { Color = palette.White, Thickness = 1 }, strip)
	self.dot = UIKit.new("Frame", { Name = "Live", AnchorPoint = Vector2.new(0, 0.5), Position = UDim2.new(0, 12, 0.5, 0), Size = UDim2.fromOffset(8, 8), BorderSizePixel = 0 }, strip)
	UIKit.corner(self.dot, 0.5)
	UIKit.TrackAccent(self.dot, "BackgroundColor3")
	self.map = UIKit.label(strip, { Position = UDim2.fromOffset(26, 6), Size = UDim2.fromOffset(150, 24), Font = Enum.Font.GothamBlack, TextXAlignment = Enum.TextXAlignment.Left, Text = "" })
	self.phase = UIKit.label(strip, { Position = UDim2.fromOffset(182, 6), Size = UDim2.fromOffset(140, 24), Font = Enum.Font.GothamBold, TextColor3 = palette.Cyan, Text = "" })
	self.timer = UIKit.label(strip, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -12, 0, 6), Size = UDim2.fromOffset(130, 24), Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Right, Text = "" })
	self.visible = false
	return self
end

function Phase:SetVisible(visible)
	self.visible = visible == true
	if not self.visible then
		self.strip.Visible = false
	end
end

function Phase:Update(snap, ctx)
	if not self.visible then
		return
	end
	local text = Phase.Text(snap, ctx)
	local show = text ~= nil
	if show ~= self.strip.Visible then
		UIKit.Show(self.strip, show, "FromAbove", 0.2)
	end
	if not text then
		return
	end
	UIKit.setText(self.map, text.map)
	UIKit.setText(self.phase, text.phase)
	UIKit.setText(self.timer, text.timer)
	self.dot.BackgroundTransparency = text.live and 0 or 0.7
end

function Phase:Destroy()
	self.maid:Cleanup()
end

return Phase
