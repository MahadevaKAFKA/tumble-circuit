--[[
	ChallengeController (challenges/cups/creator brief, 2026-11-26) — the client side of solo
	challenges. Display + requests only; the server times, judges and saves every attempt.

	- Card (MORE > CHALLENGE, or opened by a share code / invite): name, medal times, your best
	  and medal, map mastery, the Weekly window and its top 10, TRY, CODE entry, CLEAN CAPTURE.
	- Attempt screen ("Challenge" layer): 3-2-1-GO, timer, gate n/N with the split delta against
	  your best, medal targets, RETRY (one tap - straight back to the start) and QUIT.
	- Ghosts: your PB ghost (mint) and, when a friend in this server has shared one for the same
	  challenge version, theirs (yellow, named). GHOST cycles BOTH / PB / OFF. When there is no
	  friend ghost the card says so plainly.
	- Result card: "THE DROP SHAFT · 24.81 s · SILVER", NEW BEST, the share line with the code,
	  SHARE GHOST (explicit; off by default), RETRY, QUIT.
	- Clean Capture: during the run, hides every chrome element this controller owns except a
	  small timer (buttons and the result card return when the attempt ends), and draws a 9:16
	  framing guide for vertical clips. Nothing is recorded or posted by the game -
	  the player records with their own device tools.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local ChallengeConfig = require(Shared:WaitForChild("ChallengeConfig"))
local PhysicsConfig = require(Shared:WaitForChild("PhysicsConfig"))
local TimeTrialRules = require(Shared:WaitForChild("TimeTrialRules"))
local TrackDefinitions = require(Shared:WaitForChild("TrackDefinitions"))
local Utility = require(Shared:WaitForChild("Utility"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local palette = UIKit.Palette

local Challenge = {}
Challenge.__index = Challenge

Challenge.MedalColors = {
	Gold = Color3.fromRGB(255, 205, 64),
	Silver = Color3.fromRGB(214, 222, 236),
	Bronze = Color3.fromRGB(222, 140, 82),
}
Challenge.GhostModes = { "BOTH", "PB", "OFF" }

local function fmt(seconds)
	return type(seconds) == "number" and string.format("%.2f", seconds) or "--"
end
Challenge.Format = fmt

-- Pure: signed split delta text ("-0.42" green / "+1.10" red); nil when no comparison
function Challenge.DeltaText(delta)
	if type(delta) ~= "number" then
		return nil
	end
	return string.format("%s%.2f", delta < 0 and "-" or "+", math.abs(delta)), delta < 0
end

-- Pure: the countdown digit for a given server time ("3", "2", "1", "GO")
function Challenge.CountdownText(goAt, now)
	local left = (goAt or now) - now
	return left > 0 and tostring(math.ceil(left)) or "GO"
end

-- Pure: "ends in 3d 4h" / "ends in 5h 12m"
function Challenge.EndsIn(ends, now)
	local left = math.max(0, (ends or now) - now)
	local d = math.floor(left / 86400)
	local h = math.floor((left % 86400) / 3600)
	local m = math.floor((left % 3600) / 60)
	if d > 0 then
		return string.format("ends in %dd %dh", d, h)
	end
	return string.format("ends in %dh %dm", h, m)
end

-- Pure: the card's text for a "Card" payload
function Challenge.CardLines(card, now)
	local c = card and ChallengeConfig.ById[card.id]
	if not c then
		return nil
	end
	local medals = string.format("GOLD %s  ·  SILVER %s  ·  BRONZE %s", fmt(c.Medals.Gold), fmt(c.Medals.Silver), fmt(c.Medals.Bronze))
	local best = card.best and string.format("YOUR BEST %s s%s", fmt(card.best), card.medal and ("  ·  " .. string.upper(card.medal)) or "") or "No time yet - your first finish sets your best"
	local mastery = card.mastery and string.format("%s MASTERY %d / %d", string.upper(c.MapName or "MAP"), card.mastery.done or 0, card.mastery.total or 0) or ""
	local week = card.weekly and string.format("WEEKLY CHALLENGE  ·  WEEK %d  ·  %s", card.week or 0, Challenge.EndsIn(card.weekEnds, now)) or "Not this week's challenge - times still count for your best"
	return {
		title = string.upper(c.Title) .. (card.weekly and "  ·  WEEKLY" or ""),
		medals = medals,
		best = best,
		mastery = mastery,
		week = week,
		blurb = c.Goal or "",
		code = "CODE " .. c.Code,
	}
end

-- Pure: the result card for a "Finished" payload
function Challenge.ResultLines(result)
	local c = result and ChallengeConfig.ById[result.id]
	if not c then
		return nil
	end
	local medal = result.medal and string.upper(result.medal) or "NO MEDAL"
	local head = string.format("%s  ·  %s s  ·  %s", string.upper(c.Title), fmt(result.seconds), medal)
	local sub
	if result.pb and result.previous then
		sub = string.format("NEW BEST  (was %s s)", fmt(result.previous))
	elseif result.pb then
		sub = "FIRST TIME SET"
	else
		sub = string.format("Best %s s", fmt(result.best))
	end
	if result.saved == false then
		sub = sub .. "  ·  not saved yet (data loading)"
	end
	if result.signature then
		sub = sub .. "  ·  SIGNATURE LINE"
	end
	return { head = head, sub = sub, share = result.line or "", medal = result.medal }
end

-- Pure: the centred 9:16 framing guide inside a W x H viewport (px): x, y, w, h
function Challenge.CaptureGuide(width, height)
	if width <= 0 or height <= 0 then
		return 0, 0, 0, 0
	end
	local h = height
	local w = h * 9 / 16
	if w > width then
		w = width
		h = w * 16 / 9
	end
	return (width - w) / 2, (height - h) / 2, w, h
end

function Challenge.new(deps)
	local self = setmetatable({}, Challenge)
	self.remotes = deps.remotes
	self.toast = deps.toast
	self.state = nil -- the current attempt (phase, id, goAt, startedAt, best, gate, total, delta, result)
	self.card = nil
	self.ghost, self.friend, self.friendName = nil, nil, nil
	self.ghostMode = 1
	self.ghostParts = {}
	self.capture = false
	self.Changed = Utility.Signal.new()
	local gui, root, maid = UIKit.screen("TumbleChallenge", 23)
	self.gui, self.root, self.maid = gui, root, maid

	-- MORE drawer entry (MatchUI adopts it) ------------------------------------------------
	self.openButton = UIKit.button(root, { Name = "Challenge", Size = UDim2.fromOffset(121, 44), Text = "CHALLENGE", Visible = false }, palette.Coral)
	maid:Give(self.openButton.Activated:Connect(function()
		self:Open(ChallengeConfig.Weekly(os.time()) and ChallengeConfig.Weekly(os.time()).Id or ChallengeConfig.Challenges[1].Id)
	end))

	-- Card ---------------------------------------------------------------------------------
	local card = UIKit.panel(root, { Name = "ChallengeCard", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.5), Size = UDim2.fromOffset(540, 340), Visible = false })
	self.cardPanel = card
	self.cTitle = UIKit.Title(card, { Position = UDim2.fromOffset(20, 14), Size = UDim2.fromOffset(440, 30), Text = "CHALLENGE" })
	local close = UIKit.button(card, { Name = "Close", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 12), Size = UDim2.fromOffset(44, 36), Text = "X" }, palette.White)
	maid:Give(close.Activated:Connect(function()
		self:Close()
	end))
	local function line(y, size, color, font)
		return UIKit.label(card, { Position = UDim2.fromOffset(20, y), Size = UDim2.fromOffset(300, size + 6), TextScaled = false, TextSize = size, Font = font or Enum.Font.GothamBold, TextColor3 = color or palette.White, TextXAlignment = Enum.TextXAlignment.Left, TextWrapped = true })
	end
	self.cBlurb = line(48, 14, UIKit.Colors.Muted, Enum.Font.Gotham)
	self.cBlurb.Size = UDim2.fromOffset(300, 36)
	self.cMedals = line(90, 14, Challenge.MedalColors.Gold)
	self.cBest = line(112, 16)
	self.cMastery = line(136, 14, palette.Mint)
	self.cWeek = line(158, 13, UIKit.Colors.Muted)
	self.cWeek.Size = UDim2.fromOffset(300, 34)
	-- weekly top 10 (right column)
	self.cBoard = UIKit.label(card, { Position = UDim2.fromOffset(334, 52), Size = UDim2.fromOffset(186, 190), TextScaled = false, TextSize = 13, Font = Enum.Font.Code, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, TextWrapped = true, Text = "WEEKLY TOP 10\n(loading)" })
	self.tryButton = UIKit.Primary(UIKit.button(card, { Name = "ChallengeTry", Position = UDim2.fromOffset(20, 266), Size = UDim2.fromOffset(170, 54), Text = "TRY" }, palette.Mint))
	maid:Give(self.tryButton.Activated:Connect(function()
		if self.card then
			self.remotes.RequestChallenge:FireServer(self.card.id, "start")
		end
	end))
	self.codeBox = UIKit.new("TextBox", { Name = "ChallengeCodeBox", Position = UDim2.fromOffset(202, 272), Size = UDim2.fromOffset(110, 42), PlaceholderText = "CODE", Text = "", ClearTextOnFocus = false, TextSize = 18, Font = Enum.Font.GothamBold, TextColor3 = palette.White, BackgroundColor3 = Color3.fromRGB(20, 26, 40), BackgroundTransparency = 0.2 }, card)
	local codeButton = UIKit.button(card, { Name = "ChallengeCode", Position = UDim2.fromOffset(318, 272), Size = UDim2.fromOffset(58, 42), Text = "GO" }, palette.Yellow)
	maid:Give(codeButton.Activated:Connect(function()
		local text = string.sub(self.codeBox.Text or "", 1, 40)
		if text ~= "" then
			self.remotes.RequestChallenge:FireServer(text, "code")
		end
	end))
	self.captureButton = UIKit.button(card, { Name = "ChallengeCapture", Position = UDim2.fromOffset(386, 272), Size = UDim2.fromOffset(134, 42), Text = "CLEAN CAPTURE: OFF" }, palette.White)
	self.captureButton.TextSize = 12
	maid:Give(self.captureButton.Activated:Connect(function()
		self:SetCapture(not self.capture)
	end))
	self.cardShare = UIKit.button(card, { Name = "ChallengeShare", Position = UDim2.fromOffset(334, 230), Size = UDim2.fromOffset(186, 34), Text = "SHARE MY GHOST" }, palette.Violet)
	self.cardShare.TextSize = 13
	maid:Give(self.cardShare.Activated:Connect(function()
		if self.card then
			self.remotes.RequestChallenge:FireServer(self.card.id, self.shared and "unshare" or "share")
		end
	end))

	-- Attempt layer ------------------------------------------------------------------------
	local layer = UIKit.new("Frame", { Name = "Challenge", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false }, root)
	self.layer = layer
	local chrome = UIKit.new("Frame", { Name = "Chrome", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1) }, layer)
	self.chrome = chrome
	local top = UIKit.panel(layer, { Name = "Timer", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 8), Size = UDim2.fromOffset(300, 78) })
	self.timerPanel = top
	self.aTitle = UIKit.label(top, { Position = UDim2.fromOffset(10, 4), Size = UDim2.new(1, -20, 0, 16), TextScaled = false, TextSize = 13, Font = Enum.Font.GothamBold, TextColor3 = UIKit.Colors.Muted, Text = "THE DROP SHAFT" })
	self.aTime = UIKit.label(top, { Position = UDim2.fromOffset(10, 20), Size = UDim2.new(1, -20, 0, 34), TextScaled = false, TextSize = 32, Font = Enum.Font.GothamBlack, Text = "0.00" })
	self.aSub = UIKit.label(top, { Position = UDim2.fromOffset(10, 54), Size = UDim2.new(1, -20, 0, 18), TextScaled = false, TextSize = 14, Font = Enum.Font.GothamBold, Text = "" })
	self.aDelta = UIKit.label(chrome, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 92), Size = UDim2.fromOffset(200, 30), TextScaled = false, TextSize = 26, Font = Enum.Font.GothamBlack, Text = "", TextStrokeTransparency = 0.4 })
	self.aTargets = UIKit.label(chrome, { AnchorPoint = Vector2.new(0, 0), Position = UDim2.fromOffset(14, 10), Size = UDim2.fromOffset(170, 60), TextScaled = false, TextSize = 13, Font = Enum.Font.GothamBold, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Top, Text = "" })
	-- top right: RETRY / QUIT / GHOST (the bottom corners belong to the touch stick + brake)
	self.retryButton = UIKit.Primary(UIKit.button(chrome, { Name = "ChallengeRetry", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 10), Size = UDim2.fromOffset(110, 48), Text = "RETRY" }, palette.Mint))
	maid:Give(self.retryButton.Activated:Connect(function()
		if self.state then
			self.remotes.RequestChallenge:FireServer(self.state.id, "retry")
		end
	end))
	self.quitButton = UIKit.button(chrome, { Name = "ChallengeQuit", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -132, 0, 10), Size = UDim2.fromOffset(80, 48), Text = "QUIT" }, palette.White)
	maid:Give(self.quitButton.Activated:Connect(function()
		if self.state then
			self.remotes.RequestChallenge:FireServer(self.state.id, "quit")
		end
	end))
	self.ghostButton = UIKit.button(chrome, { Name = "ChallengeGhost", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 64), Size = UDim2.fromOffset(110, 36), Text = "GHOST: BOTH" }, palette.White)
	self.ghostButton.TextSize = 13
	maid:Give(self.ghostButton.Activated:Connect(function()
		self.ghostMode = self.ghostMode % #Challenge.GhostModes + 1
		self.ghostButton.Text = "GHOST: " .. Challenge.GhostModes[self.ghostMode]
		self:_clearGhosts()
	end))
	self.aNote = UIKit.label(chrome, { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 104), Size = UDim2.fromOffset(240, 34), TextScaled = false, TextSize = 12, Font = Enum.Font.Gotham, TextColor3 = UIKit.Colors.Muted, TextXAlignment = Enum.TextXAlignment.Right, TextWrapped = true, Text = "" })
	-- result card (centre)
	local result = UIKit.panel(chrome, { Name = "ChallengeResult", AnchorPoint = Vector2.new(0.5, 0.5), Position = UDim2.fromScale(0.5, 0.52), Size = UDim2.fromOffset(500, 190), Visible = false })
	self.resultPanel = result
	self.rHead = UIKit.label(result, { Position = UDim2.fromOffset(16, 14), Size = UDim2.new(1, -32, 0, 30), TextScaled = false, TextSize = 22, Font = Enum.Font.GothamBlack, Text = "" })
	self.rSub = UIKit.label(result, { Position = UDim2.fromOffset(16, 50), Size = UDim2.new(1, -32, 0, 20), TextScaled = false, TextSize = 15, Font = Enum.Font.GothamBold, TextColor3 = palette.Mint, Text = "" })
	self.rShare = UIKit.label(result, { Position = UDim2.fromOffset(16, 76), Size = UDim2.new(1, -32, 0, 40), TextScaled = false, TextSize = 14, Font = Enum.Font.Gotham, TextColor3 = UIKit.Colors.Muted, TextWrapped = true, Text = "" })
	self.resultShare = UIKit.button(result, { Name = "ChallengeShare", Position = UDim2.fromOffset(16, 126), Size = UDim2.fromOffset(200, 48), Text = "SHARE MY GHOST" }, palette.Violet)
	self.resultShare.TextSize = 14
	maid:Give(self.resultShare.Activated:Connect(function()
		if self.state then
			self.remotes.RequestChallenge:FireServer(self.state.id, self.shared and "unshare" or "share")
		end
	end))
	-- Clean Capture: the 9:16 guide (two shaded side bands + a thin frame)
	local guide = UIKit.new("Frame", { Name = "CaptureGuide", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Visible = false, ZIndex = 1 }, root)
	self.guide = guide
	self.guideLeft = UIKit.new("Frame", { BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.72, BorderSizePixel = 0 }, guide)
	self.guideRight = UIKit.new("Frame", { BackgroundColor3 = Color3.new(0, 0, 0), BackgroundTransparency = 0.72, BorderSizePixel = 0 }, guide)
	self.guideFrame = UIKit.new("Frame", { BackgroundTransparency = 1, BorderSizePixel = 0 }, guide)
	pcall(function()
		local stroke = Instance.new("UIStroke")
		stroke.Color = palette.White
		stroke.Transparency = 0.5
		stroke.Thickness = 1
		stroke.Parent = self.guideFrame
	end)
	UIKit.label(guide, { AnchorPoint = Vector2.new(0.5, 1), Position = UDim2.new(0.5, 0, 1, -6), Size = UDim2.fromOffset(260, 16), TextScaled = false, TextSize = 11, Font = Enum.Font.GothamBold, TextColor3 = palette.White, TextTransparency = 0.35, Text = "9:16 GUIDE  ·  record with your device" })

	maid:Give(self.remotes.ChallengeState.OnClientEvent:Connect(function(payload)
		self:_apply(payload)
	end))
	return self
end

-- The challenge course a bound marble rides (its HubId attribute), generated once on first use
-- from the same data the server built it from; nil = not a challenge marble.
function Challenge:BindCourse(id)
	local c = type(id) == "string" and ChallengeConfig.ById[id] or nil
	if not c or c.Status ~= "Live" then
		self.boundLayout = nil
		return nil
	end
	self.courseLayouts = self.courseLayouts or {}
	local layout = self.courseLayouts[id]
	if layout == nil then
		local def = TrackDefinitions[c.Course]
		local ok, value = pcall(function()
			return def and TrackDefinitions.Generate(def, PhysicsConfig.Ball.Radius)
		end)
		layout = ok and value or false
		self.courseLayouts[id] = layout
	end
	self.boundLayout = layout or nil
	return self.boundLayout
end

function Challenge:BoundLayout()
	return self.boundLayout
end

function Challenge:RegisterLayers(ui)
	ui:Register("Challenge", function(visible)
		self.layer.Visible = visible
		if not visible then
			self:_clearGhosts()
		end
	end)
end

function Challenge:IsActive()
	local s = self.state
	return s ~= nil and (s.phase == "Countdown" or s.phase == "Running" or s.phase == "Failed" or s.phase == "Finished")
end

function Challenge:IsCleanCapture()
	return self.capture and self:IsActive()
end

function Challenge:SetCapture(on)
	self.capture = on == true
	self.captureButton.Text = self.capture and "CLEAN CAPTURE: ON" or "CLEAN CAPTURE: OFF"
	self.Changed:Fire()
end

function Challenge:Open(id)
	self.cardPanel.Visible = true
	UIKit.Enter(self.cardPanel, "FromBelow", 0.2)
	self.remotes.RequestChallenge:FireServer(id, "card")
	self.remotes.RequestChallenge:FireServer(id, "board")
end

function Challenge:Close()
	self.cardPanel.Visible = false
end

function Challenge:_setShared(shared)
	self.shared = shared == true
	local text = self.shared and "GHOST SHARED - TAP TO STOP" or "SHARE MY GHOST"
	self.cardShare.Text = text
	self.resultShare.Text = text
end

function Challenge:_apply(p)
	if type(p) ~= "table" then
		return
	end
	local phase = p.phase
	if phase == "Card" then
		self.card = p
		local lines = Challenge.CardLines(p, os.time())
		if lines then
			self.cTitle.Text = lines.title
			self.cBlurb.Text = lines.blurb
			self.cMedals.Text = lines.medals
			self.cBest.Text = lines.best
			self.cMastery.Text = lines.mastery
			self.cWeek.Text = lines.week .. "  ·  " .. lines.code
		end
		if p.invited then
			self.cardPanel.Visible = true
			if self.toast then
				self.toast("You were challenged: " .. (ChallengeConfig.ById[p.id] and ChallengeConfig.ById[p.id].Title or "a challenge") .. " - tap TRY", 4)
			end
			self.remotes.RequestChallenge:FireServer(p.id, "board")
		end
	elseif phase == "Board" then
		local rows = { "WEEKLY TOP 10" }
		if p.error then
			rows[#rows + 1] = p.error
		elseif #(p.rows or {}) == 0 then
			rows[#rows + 1] = "No times yet - be first"
		end
		for _, r in ipairs(p.rows or {}) do
			rows[#rows + 1] = string.format("%2d  %-10s %s", r.rank or 0, string.sub(r.name or ("#" .. tostring(r.userId)), 1, 10), fmt(r.seconds))
		end
		self.cBoard.Text = table.concat(rows, "\n")
		-- names arrive later (a yielding lookup per row, never blocking the card)
		task.spawn(function()
			local named = false
			for _, r in ipairs(p.rows or {}) do
				if not r.name and r.userId then
					local ok, name = pcall(function()
						return Players:GetNameFromUserIdAsync(r.userId)
					end)
					r.name = ok and name or nil
					named = named or ok
				end
			end
			if named and self.cardPanel.Visible then
				local again = { "WEEKLY TOP 10" }
				for _, r in ipairs(p.rows) do
					again[#again + 1] = string.format("%2d  %-10s %s", r.rank or 0, string.sub(r.name or ("#" .. tostring(r.userId)), 1, 10), fmt(r.seconds))
				end
				self.cBoard.Text = table.concat(again, "\n")
			end
		end)
	elseif phase == "Refused" then
		if self.toast then
			self.toast(p.reason or "Not now", 3)
		end
	elseif phase == "Countdown" then
		self.cardPanel.Visible = false
		self.state = { phase = "Countdown", id = p.id, goAt = p.goAt, best = p.best, medals = p.medals, gate = 0, total = p.total or 0, attempt = p.attempt }
		self.resultPanel.Visible = false
		self.aDelta.Text = ""
		self:_clearGhosts()
		self.Changed:Fire()
	elseif phase == "Running" and self.state then
		self.state.phase = "Running"
		self.state.startedAt = p.startedAt
		self.Changed:Fire()
	elseif phase == "Split" and self.state then
		self.state.gate = p.index or self.state.gate
		self.state.total = p.total or self.state.total
		local text, ahead = Challenge.DeltaText(p.delta)
		self.aDelta.Text = text or ""
		self.aDelta.TextColor3 = ahead and palette.Mint or palette.Coral
		self.state.deltaUntil = os.clock() + 2.5
	elseif phase == "Failed" and self.state then
		self.state.phase = "Failed"
		self.state.reason = p.reason
		self:_clearGhosts()
		self.Changed:Fire()
	elseif phase == "Finished" and self.state then
		self.state.phase = "Finished"
		self.state.final = p.seconds
		self.state.best = p.best
		local lines = Challenge.ResultLines(p)
		if lines then
			self.rHead.Text = lines.head
			self.rHead.TextColor3 = lines.medal and Challenge.MedalColors[lines.medal] or palette.White
			self.rSub.Text = lines.sub
			self.rShare.Text = lines.share
			self.resultPanel.Visible = true
		end
		self:_clearGhosts()
		self.Changed:Fire()
	elseif phase == "Ended" then
		self.state = nil
		self.resultPanel.Visible = false
		self:_clearGhosts()
		self.ghost, self.friend = nil, nil
		self.Changed:Fire()
	elseif phase == "Ghost" then
		self.ghost = type(p.ghost) == "table" and p.ghost or nil
		self.friend = type(p.friend) == "table" and p.friend or nil
		self.friendName = p.friendName
		self.aNote.Text = p.friend and ("Racing " .. tostring(p.friendName) .. "'s shared ghost") or (p.friendNote or p.note or "")
		self:_setShared(self.ghost ~= nil and self.ghost.shared == true)
	elseif phase == "Shared" then
		self:_setShared(p.shared)
		if self.toast then
			self.toast(p.note or (p.shared and "Ghost shared - friends in your server can race it" or "Ghost sharing off"), 3)
		end
	elseif phase == "Mastery" then
		if self.toast then
			self.toast(string.format("MASTERY  %s  ·  %d / %d", string.upper(p.title or p.goal or ""), p.done or 0, p.total or 0), 4)
		end
	end
end

function Challenge:_clearGhosts()
	for key, part in pairs(self.ghostParts) do
		part:Destroy()
		self.ghostParts[key] = nil
	end
end

function Challenge:_ghostPart(key, color, label)
	local part = self.ghostParts[key]
	if part and part.Parent then
		return part
	end
	part = Instance.new("Part")
	part.Name = "TC_ChallengeGhost_" .. key
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.new(4, 4, 4)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.ForceField
	part.Color = color
	part.Transparency = 0.35
	local tag = Instance.new("BillboardGui")
	tag.Size = UDim2.fromOffset(110, 24)
	tag.StudsOffsetWorldSpace = Vector3.new(0, 3.4, 0)
	tag.MaxDistance = 140
	tag.LightInfluence = 0
	local text = Instance.new("TextLabel")
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.TextScaled = true
	text.Font = Enum.Font.GothamBlack
	text.TextColor3 = color
	text.TextStrokeTransparency = 0.3
	text.Text = label
	text.Parent = tag
	tag.Parent = part
	part.Parent = workspace
	self.ghostParts[key] = part
	return part
end

-- per frame (now = server time)
function Challenge:Step(now)
	local s = self.state
	-- the capture guide follows the viewport
	local camera = workspace.CurrentCamera
	local showGuide = self:IsCleanCapture()
	self.guide.Visible = showGuide
	if showGuide and camera then
		local vp = camera.ViewportSize
		local x, y, w, h = Challenge.CaptureGuide(vp.X, vp.Y)
		self.guideLeft.Position, self.guideLeft.Size = UDim2.fromOffset(0, 0), UDim2.fromOffset(x, vp.Y)
		self.guideRight.Position, self.guideRight.Size = UDim2.fromOffset(x + w, 0), UDim2.fromOffset(vp.X - x - w, vp.Y)
		self.guideFrame.Position, self.guideFrame.Size = UDim2.fromOffset(x, y), UDim2.fromOffset(w, h)
	end
	-- Clean Capture keeps the run itself clean; RETRY / QUIT / the result card come back once
	-- the attempt is over (Failed / Finished), so you are never stuck without a button
	self.chrome.Visible = not self.capture or (s ~= nil and (s.phase == "Failed" or s.phase == "Finished"))
	if not s then
		return
	end
	local c = ChallengeConfig.ById[s.id]
	self.aTitle.Text = c and string.upper(c.Title) or "CHALLENGE"
	local elapsed = 0
	if s.phase == "Countdown" then
		self.aTime.Text = Challenge.CountdownText(s.goAt, now)
	elseif s.phase == "Running" then
		elapsed = math.max(0, now - (s.startedAt or now))
		self.aTime.Text = fmt(elapsed)
	elseif s.phase == "Finished" then
		self.aTime.Text = fmt(s.final)
	elseif s.phase == "Failed" then
		self.aTime.Text = "RETRY"
	end
	if s.phase == "Failed" then
		self.aSub.Text = string.upper(s.reason or "Attempt over") .. "  ·  TAP RETRY"
	else
		self.aSub.Text = string.format("GATE %d/%d   BEST %s", s.gate or 0, s.total or 0, fmt(s.best))
	end
	if s.deltaUntil and os.clock() > s.deltaUntil then
		self.aDelta.Text = ""
		s.deltaUntil = nil
	end
	if c then
		self.aTargets.Text = string.format("GOLD %s\nSILVER %s\nBRONZE %s", fmt(c.Medals.Gold), fmt(c.Medals.Silver), fmt(c.Medals.Bronze))
	end
	-- ghosts (server-recorded samples of a valid finish)
	local mode = Challenge.GhostModes[self.ghostMode]
	if s.phase == "Running" and mode ~= "OFF" then
		local function place(key, ghost, color, label)
			local x, y, z = TimeTrialRules.GhostAt(ghost, elapsed)
			if x then
				self:_ghostPart(key, color, label).CFrame = CFrame.new(x, y, z)
			elseif self.ghostParts[key] then
				self.ghostParts[key]:Destroy()
				self.ghostParts[key] = nil
			end
		end
		if self.ghost then
			place("pb", self.ghost, palette.Mint, "PB GHOST")
		end
		if self.friend and mode == "BOTH" then
			place("friend", self.friend, Challenge.MedalColors.Gold, string.upper(tostring(self.friendName or "FRIEND")))
		end
	end
end

function Challenge:Destroy()
	self:_clearGhosts()
	self.maid:Cleanup()
end

return Challenge
