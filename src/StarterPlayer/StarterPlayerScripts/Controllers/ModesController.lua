--[[
	ModesController (B1) — the lobby's mode controls and the Time Trial HUD.
	Layers (UIController): "Modes" (lobby: MAPS button, TIME TRIAL + PARTY row, the next-race
	ballot strip, party card) and "TimeTrial" (timer card, QUIT). Display/requests only:
	- prompt 03: MAPS opens Map Selection; during the intermission a strip shows each map's
	  ballots and a tap votes (deps.castBallot -> RequestBallot); counts come from the snapshot
	- Time Trial: RequestTimeTrial(true/false); phases come from TimeTrialState
	- ghost: GhostPath (the player's own PB run, recorded by the server) replayed as a labelled,
	  non-colliding, non-queryable marble
	- party: tags from the snapshot; INVITE uses Roblox's own invite prompt when allowed
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SocialService = game:GetService("SocialService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local GameConfig = require(Shared:WaitForChild("GameConfig"))
local TimeTrialRules = require(Shared:WaitForChild("TimeTrialRules"))
local TrackDefinitions = require(Shared:WaitForChild("TrackDefinitions"))
local Utility = require(Shared:WaitForChild("Utility"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local palette = GameConfig.Palette

local ModesController = {}
ModesController.__index = ModesController

local function worldName(id)
	local def = TrackDefinitions.WorldsById[id]
	return def and def.DisplayName or tostring(id)
end
ModesController.WorldName = worldName

function ModesController.new(deps)
	local self = setmetatable({}, ModesController)
	self.remotes = deps.remotes
	self.toast = deps.toast
	self.flash = deps.flash
	self.localUserId = Players.LocalPlayer.UserId
	local gui, root, maid = UIKit.screen("TumbleModesUI", 9)
	self.gui, self.root, self.maid = gui, root, maid
	self.trial = nil -- { phase, startedAt, goAt, best, cp, total, world }
	self.ghost = nil -- payload from GhostPath
	self.ghostPart = nil
	self.castBallot = deps.castBallot
	self.MapsRequested = Utility.Signal.new() -- prompt 03: MAPS tapped
	self.Changed = Utility.Signal.new() -- trial state changed (refresh screens)

	-- Lobby "Modes" layer ----------------------------------------------------------------
	local modes = UIKit.new("Frame", { Name = "Modes", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false }, root)
	self.modes = modes
	self.trialButton = UIKit.button(modes, { Name = "TimeTrial", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -143, 0, 320), Size = UDim2.fromOffset(121, 44), Text = "TIME TRIAL" }, palette.Mint)
	maid:Give(self.trialButton.Activated:Connect(function()
		self.remotes.RequestTimeTrial:FireServer(true)
	end))
	self.partyButton = UIKit.button(modes, { Name = "Party", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 320), Size = UDim2.fromOffset(121, 44), Text = "PARTY" }, palette.Yellow)
	maid:Give(self.partyButton.Activated:Connect(function()
		self.partyCard.Visible = not self.partyCard.Visible
	end))

	-- party card (left of the column)
	local card = UIKit.panel(modes, { Name = "PartyCard", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -278, 0, 320), Size = UDim2.fromOffset(250, 132), Visible = false })
	UIKit.new("UIStroke", { Color = palette.Yellow, Thickness = 2 }, card)
	self.partyCard = card
	UIKit.label(card, { Position = UDim2.fromOffset(10, 4), Size = UDim2.new(1, -20, 0, 24), Font = Enum.Font.GothamBlack, TextColor3 = palette.Yellow, Text = "PARTY RACE" })
	self.partyText = UIKit.label(card, { Position = UDim2.fromOffset(10, 30), Size = UDim2.new(1, -20, 0, 44), Font = Enum.Font.Gotham, TextWrapped = true, Text = "" })
	self.inviteButton = UIKit.button(card, { Name = "Invite", Position = UDim2.fromOffset(10, 80), Size = UDim2.new(1, -20, 0, 42), Text = "INVITE FRIENDS" }, palette.Yellow)
	maid:Give(self.inviteButton.Activated:Connect(function()
		self:_invite()
	end))

	-- prompt 03: MAPS (top centre, one tap from anywhere in the hub)
	self.mapsButton = UIKit.button(modes, { Name = "Maps", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 8), Size = UDim2.fromOffset(360, 46), Text = "MAPS" }, palette.Cyan)
	maid:Give(self.mapsButton.Activated:Connect(function()
		self.MapsRequested:Fire()
	end))
	-- the next-race ballot strip (top centre, under MAPS, during the intermission)
	local vote = UIKit.panel(modes, { Name = "MapVote", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 112), Size = UDim2.fromOffset(560, 132), Visible = false })
	UIKit.new("UIStroke", { Color = palette.Cyan, Thickness = 2 }, vote)
	self.votePanel = vote
	self.voteTitle = UIKit.label(vote, { Position = UDim2.fromOffset(12, 6), Size = UDim2.new(1, -24, 0, 26), Font = Enum.Font.GothamBlack, TextColor3 = palette.Cyan, Text = "VOTE FOR THE NEXT RACE" })
	self.voteButtons = {}
	for i = 1, 3 do
		local b = UIKit.button(vote, { Name = "MapVote", Position = UDim2.fromOffset(12 + (i - 1) * 182, 40), Size = UDim2.fromOffset(170, 80), Text = "" }, palette.Cyan)
		local name = UIKit.label(b, { Position = UDim2.fromScale(0.04, 0.05), Size = UDim2.fromScale(0.92, 0.5), Font = Enum.Font.GothamBlack, Text = "" })
		local count = UIKit.label(b, { Position = UDim2.fromScale(0.04, 0.58), Size = UDim2.fromScale(0.92, 0.34), Font = Enum.Font.Gotham, Text = "" })
		self.voteButtons[i] = { button = b, name = name, count = count }
		maid:Give(b.Activated:Connect(function()
			local ballot = self.snapshot and self.snapshot.ballot
			local mine = ballot and ballot.choices and ballot.choices[tostring(self.localUserId)]
			if self.castBallot and mine ~= (i + (self.votePage - 1) * 3) then
				self.castBallot(i + (self.votePage - 1) * 3)
			end
		end))
	end
	self.votePage = 1

	-- Time Trial layer --------------------------------------------------------------------
	local tt = UIKit.new("Frame", { Name = "TimeTrialLayer", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false }, root)
	self.ttLayer = tt
	local ttCard = UIKit.panel(tt, { Name = "TrialCard", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 8), Size = UDim2.fromOffset(360, 74) })
	UIKit.new("UIStroke", { Color = palette.Mint, Thickness = 2 }, ttCard)
	self.ttTitle = UIKit.label(ttCard, { Position = UDim2.fromOffset(10, 4), Size = UDim2.new(1, -20, 0, 20), Font = Enum.Font.GothamBold, TextColor3 = palette.Mint, Text = "TIME TRIAL" })
	self.ttTime = UIKit.label(ttCard, { Position = UDim2.fromOffset(10, 24), Size = UDim2.new(1, -20, 0, 30), Font = Enum.Font.GothamBlack, Text = "0:00.0" })
	self.ttSub = UIKit.label(ttCard, { Position = UDim2.fromOffset(10, 54), Size = UDim2.new(1, -20, 0, 16), Font = Enum.Font.Gotham, TextTransparency = 0.15, Text = "" })
	self.quitButton = UIKit.button(tt, { Name = "QuitTrial", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 8), Size = UDim2.fromOffset(120, 44), Text = "QUIT" }, palette.Coral)
	maid:Give(self.quitButton.Activated:Connect(function()
		self.remotes.RequestTimeTrial:FireServer(false)
	end))

	maid:Give(self.remotes.TimeTrialState.OnClientEvent:Connect(function(data)
		self:_onTrialState(data)
	end))
	maid:Give(self.remotes.GhostPath.OnClientEvent:Connect(function(ghost)
		if type(ghost) == "table" and type(ghost.points) == "table" and type(ghost.hz) == "number" then
			self.ghost = ghost
		end
	end))
	return self
end

-- UI overhaul: the hub card carries MAPS and the next race; TIME TRIAL / PARTY live in its MENU
-- drawer, and the party card opens where the drawer was.
function ModesController:SetCardMode(on)
	self.cardMode = on == true
	self.mapsButton.Visible = not self.cardMode
	if self.cardMode then
		-- v2 hub: the party card opens above the dock, centred
		self.partyCard.AnchorPoint = Vector2.new(0.5, 1)
		self.partyCard.Position = UDim2.new(0.5, 0, 1, -94)
	end
end

function ModesController:RegisterLayers(ui)
	ui:Register("Modes", function(visible)
		self.modes.Visible = visible
	end)
	ui:Register("TimeTrial", function(visible)
		self.ttLayer.Visible = visible
	end)
end

function ModesController:IsInTrial()
	local t = self.trial
	return t ~= nil and (t.phase == "Countdown" or t.phase == "Running" or t.phase == "Finished")
end

function ModesController:_onTrialState(data)
	if type(data) ~= "table" or type(data.phase) ~= "string" then
		return
	end
	local phase = data.phase
	if phase == "Refused" then
		self.toast(tostring(data.reason or "Time Trial not available right now"), 2.5)
		return
	elseif phase == "Countdown" then
		self.ghost = nil
		self.trial = { phase = phase, goAt = data.goAt, best = data.best, cp = 0, total = data.total or 8, world = data.world }
		self.flash("TIME TRIAL - " .. string.upper(tostring(data.world or "")), palette.Mint, 2)
	elseif phase == "Running" and self.trial then
		self.trial.phase = phase
		self.trial.startedAt = data.startedAt
		self.flash("GO!", palette.Mint, 1)
	elseif phase == "Checkpoint" and self.trial then
		self.trial.cp = data.index or self.trial.cp
	elseif phase == "Finished" and self.trial then
		self.trial.phase = phase
		self.trial.final = data.seconds
		self.trial.best = data.best
		local line = Utility.formatTime(data.seconds or 0)
		if data.pb and data.previous then
			line = line .. string.format("  NEW BEST (-%.2f s)", data.previous - data.seconds)
		elseif data.pb then
			line = line .. "  FIRST BEST TIME"
		elseif data.previous then
			line = line .. string.format("  best %s", Utility.formatTime(data.previous))
		end
		self.flash(line, data.pb and palette.Yellow or palette.Mint, 3)
	elseif phase == "Ended" then
		if self.trial and data.reason then
			self.toast(tostring(data.reason), 2.5)
		end
		self.trial = nil
		self:_removeGhost()
	end
	self.Changed:Fire()
end

function ModesController:_removeGhost()
	if self.ghostPart then
		self.ghostPart:Destroy()
		self.ghostPart = nil
	end
end

function ModesController:_ghostPartFor()
	if self.ghostPart and self.ghostPart.Parent then
		return self.ghostPart
	end
	local ball = Instance.new("Part")
	ball.Name = "TC_PBGhost"
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.new(4, 4, 4)
	ball.Anchored = true
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball.CastShadow = false
	ball.Material = Enum.Material.ForceField
	ball.Color = palette.Mint
	ball.Transparency = 0.35
	local tag = Instance.new("BillboardGui")
	tag.Size = UDim2.fromOffset(90, 24)
	tag.StudsOffsetWorldSpace = Vector3.new(0, 3.4, 0)
	tag.MaxDistance = 120
	tag.LightInfluence = 0
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.TextScaled = true
	text.Font = Enum.Font.GothamBlack
	text.TextColor3 = palette.Mint
	text.TextStrokeTransparency = 0.3
	text.Text = "PB GHOST"
	text.Parent = tag
	tag.Parent = ball
	ball.Parent = workspace
	self.ghostPart = ball
	return ball
end

-- per frame
function ModesController:Step(now)
	local t = self.trial
	if t then
		local elapsed = 0
		if t.phase == "Countdown" then
			local left = math.max(0, (t.goAt or now) - now)
			self.ttTime.Text = left > 0 and tostring(math.ceil(left)) or "GO"
		elseif t.phase == "Running" then
			elapsed = now - (t.startedAt or now)
			self.ttTime.Text = Utility.formatTime(math.max(0, elapsed))
		elseif t.phase == "Finished" then
			self.ttTime.Text = Utility.formatTime(t.final or 0)
		end
		self.ttTitle.Text = "TIME TRIAL - " .. string.upper(tostring(t.world or ""))
		self.ttSub.Text = string.format("CHECKPOINT %d/%d   BEST %s%s", t.cp or 0, t.total or 8, t.best and Utility.formatTime(t.best) or "--", self.ghost and "   GHOST ON" or "")
		if self.ghost and t.phase == "Running" then
			local x, y, z = TimeTrialRules.GhostAt(self.ghost, elapsed)
			if x then
				self:_ghostPartFor().CFrame = CFrame.new(x, y, z)
			else
				self:_removeGhost()
			end
		end
	end
	-- prompt 03: the ballot strip's countdown ticks once a second between snapshots
	local second = math.floor(now)
	if self.votePanel.Visible and second ~= self.voteTick then
		self.voteTick = second
		self:_renderVote()
	end
end

-- snapshot: map vote, party card, next world
function ModesController:ApplySnapshot(snap)
	self.snapshot = snap
	self:_renderVote()
	local party = snap.party
	local mine = party and party.tags and party.tags[tostring(self.localUserId)]
	local here = 0
	if mine then
		for _, group in pairs(party.tags) do
			if group == mine then
				here = here + 1
			end
		end
	end
	if party and party.available == false then
		self.partyText.Text = "Roblox parties aren't available here. You can still invite friends."
	elseif mine then
		self.partyText.Text = string.format("%d of your party here - you start next to each other (max %d).", here, party.maxSize or 4)
	else
		self.partyText.Text = "Join a Roblox party with friends: you'll start side by side (max 4)."
	end
	self.partyButton.Text = mine and string.format("PARTY  %d", here) or "PARTY"
end

function ModesController:_renderVote()
	local snap = self.snapshot
	local ballot = snap and snap.ballot
	local lead = snap and snap.nextWorldId and worldName(snap.nextWorldId)
	self.mapsButton.Text = lead and ("MAPS   |   NEXT: " .. string.upper(lead)) or "MAPS"
	self.mapsButton.Visible = not self.cardMode
	local queued = snap and snap.queued and snap.queued[tostring(self.localUserId)]
	local open = ballot ~= nil and #ballot.maps > 1 and snap.state == "Intermission" and queued == true
	self.votePanel.Visible = open
	if not open then
		return
	end
	local mine = ballot.choices and ballot.choices[tostring(self.localUserId)]
	local left = math.max(0, math.ceil((snap.stateEndsAt or 0) - workspace:GetServerTimeNow()))
	self.voteTitle.Text = mine and string.format("VOTED - CHANGE IT UNTIL THE GRID FORMS (%d s)", left) or string.format("VOTE FOR THE NEXT RACE - %d s", left)
	self.votePage = 1
	for i, entry in ipairs(self.voteButtons) do
		local index = i
		local id = ballot.maps[index]
		entry.button.Visible = id ~= nil
		if id then
			local count = ballot.counts[index] or 0
			entry.name.Text = string.upper(worldName(id))
			entry.count.Text = string.format("%d vote%s%s", count, count == 1 and "" or "s", mine == index and "  (yours)" or "")
			entry.button.AutoButtonColor = mine ~= index
		end
	end
end

function ModesController:_invite()
	local player = Players.LocalPlayer
	local ok, can = pcall(function()
		return SocialService:CanSendGameInviteAsync(player)
	end)
	if ok and can then
		pcall(function()
			SocialService:PromptGameInvite(player)
		end)
	else
		self.toast("Invites aren't available for this account or experience right now", 2.5)
	end
end

function ModesController:Destroy()
	self:_removeGhost()
	self.maid:Cleanup()
end

return ModesController
