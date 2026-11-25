--[[
	SocialController (A6) — client side of the spectator Chaos Vote and quick emotes.
	  Vote panel   : shown only to eligible voters (not an active racer) while a poll is open;
	                 two buttons with plain descriptions + seconds left; one vote, then "Vote cast".
	  Chaos banner : everyone sees the result ("SPECTATORS CHOSE TURBO FANS - in 3 s") and a
	                 countdown while it is active. Hazards get the same timestamps (HazardController).
	  Emotes       : GG / Nice Save! / Oops! buttons (lobby + spectate) and keys 1 / 2 / 3
	                 (gamepad D-pad left / right / down). Bubbles above marbles within 120 studs,
	                 2.5 s, preset text only; "Mute quick emotes" hides other players' bubbles.
	The server validates everything (eligibility, poll id, one vote, emote cooldown).
]]

local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Protocol = require(Shared:WaitForChild("Protocol"))
local SocialConfig = require(Shared:WaitForChild("SocialConfig"))
local Utility = require(Shared:WaitForChild("Utility"))
local UIKit = require(script.Parent:WaitForChild("UIKit"))

local Social = {}
Social.__index = Social

local palette = UIKit.Palette

-- Pure: banner text for a modifier at server time `now` (nil = nothing to show).
function Social.BannerText(modifier, now)
	if type(modifier) ~= "table" or not modifier.startsAt then
		return nil
	end
	if now < modifier.startsAt then
		return string.format("SPECTATORS CHOSE %s - in %d s", modifier.label or modifier.kind, math.ceil(modifier.startsAt - now))
	elseif now < modifier.endsAt then
		return string.format("%s  %d s  -  %s", modifier.label or modifier.kind, math.ceil(modifier.endsAt - now), modifier.description or "")
	end
	return nil
end

function Social.new(deps)
	local self = setmetatable({}, Social)
	self.remotes = deps.remotes
	self.marbles = deps.marblesFolder
	self.localUserId = deps.localUserId
	self.maid = Utility.Maid.new()
	self.muted = false
	self.eligible = false
	self.allowEmotes = false
	self.poll = nil
	self.voted = nil
	self.modifier = nil
	self.emoteReadyAt = 0
	self.ModifierChanged = Utility.Signal.new() -- (modifier or nil)
	local gui, root, maid = UIKit.screen("TumbleSocial", 9)
	self.gui = gui
	self.maid:Give(maid)

	-- vote panel
	local vote = UIKit.panel(root, { Name = "Vote", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 112), Size = UDim2.fromOffset(560, 150), Visible = false })
	UIKit.new("UIStroke", { Color = palette.Yellow, Thickness = 2 }, vote)
	self.voteTitle = UIKit.label(vote, { Position = UDim2.fromOffset(12, 6), Size = UDim2.new(1, -24, 0, 28), Font = Enum.Font.GothamBlack, TextColor3 = palette.Yellow, Text = "SPECTATOR CHAOS VOTE" })
	self.voteButtons = {}
	for i, option in ipairs(SocialConfig.Vote.Options) do
		local b = UIKit.button(vote, { Position = UDim2.fromOffset(12 + (i - 1) * 274, 40), Size = UDim2.fromOffset(262, 96), Text = "" }, i == 1 and palette.Cyan or palette.Coral)
		UIKit.label(b, { Position = UDim2.fromScale(0.04, 0.08), Size = UDim2.fromScale(0.92, 0.45), Font = Enum.Font.GothamBlack, Text = option.label })
		UIKit.label(b, { Position = UDim2.fromScale(0.04, 0.56), Size = UDim2.fromScale(0.92, 0.34), Font = Enum.Font.Gotham, Text = option.description })
		maid:Give(b.Activated:Connect(function()
			self:CastVote(i)
		end))
		self.voteButtons[i] = b
	end
	self.votePanel = vote

	-- chaos banner (everyone)
	self.banner = UIKit.label(root, { Name = "ChaosBanner", AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 104), Size = UDim2.fromOffset(640, 26), Font = Enum.Font.GothamBlack, TextColor3 = palette.Yellow, TextStrokeTransparency = 0.3, Visible = false })

	-- emote bar (right column, under the lobby buttons)
	local bar = UIKit.new("Frame", { Name = "Emotes", AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, -14, 0, 352), Size = UDim2.fromOffset(250, 48), BackgroundTransparency = 1, Visible = false }, root)
	self.emoteButtons = {}
	for i, emote in ipairs(SocialConfig.Emotes.List) do
		local b = UIKit.button(bar, { Position = UDim2.fromOffset((i - 1) * 84, 0), Size = UDim2.fromOffset(80, 48), Text = emote.text }, palette.Mint)
		maid:Give(b.Activated:Connect(function()
			self:SendEmote(emote.id)
		end))
		self.emoteButtons[i] = b
	end
	self.emoteBar = bar

	maid:Give(self.remotes.VoteState.OnClientEvent:Connect(function(data)
		if type(data) == "table" then
			self:_onVoteState(data)
		end
	end))
	maid:Give(self.remotes.EmoteShown.OnClientEvent:Connect(function(data)
		if type(data) == "table" and type(data.userId) == "number" and type(data.id) == "number" then
			self:_showBubble(data.userId, data.id)
		end
	end))
	local emoteKeys = {
		[Enum.KeyCode.One] = 1,
		[Enum.KeyCode.Two] = 2,
		[Enum.KeyCode.Three] = 3,
		[Enum.KeyCode.DPadLeft] = 1,
		[Enum.KeyCode.DPadRight] = 2,
		[Enum.KeyCode.DPadDown] = 3,
	}
	maid:Give(UserInputService.InputBegan:Connect(function(input, processed)
		local id = emoteKeys[input.KeyCode]
		if id and not processed and self.keysEnabled then
			self:SendEmote(id)
		end
	end))
	return self
end

function Social:SetVisible(visible)
	self.gui.Enabled = visible
end

function Social:SetMuted(muted)
	self.muted = muted == true
end

-- eligible = not an active racer; emotes = show the emote bar (lobby / spectate)
function Social:SetContext(eligible, showEmoteBar, keysEnabled)
	self.eligible = eligible
	self.emoteBar.Visible = showEmoteBar
	self.keysEnabled = keysEnabled
end

function Social:SetModifier(modifier)
	self.modifier = type(modifier) == "table" and modifier or nil
	self.ModifierChanged:Fire(self.modifier)
end

function Social:_onVoteState(data)
	if data.phase == "Open" then
		self.poll = data
		self.voted = nil
	elseif data.phase == "Voted" then
		if self.poll and data.pollId == self.poll.pollId then
			self.voted = data.option
		end
	elseif data.phase == "Result" then
		self.poll = nil
		self:SetModifier(data.modifier)
	elseif data.phase == "NoVotes" then
		self.poll = nil
	elseif data.phase == "Closed" then
		self.poll = nil
		self:SetModifier(nil)
	end
end

function Social:CastVote(option)
	local poll = self.poll
	if poll and self.eligible and not self.voted then
		self.remotes.CastSpectatorVote:FireServer(poll.pollId, option)
		self.voted = option -- optimistic; the server's "Voted" confirms
	end
end

function Social:SendEmote(id)
	if os.clock() < self.emoteReadyAt then
		return
	end
	self.emoteReadyAt = os.clock() + SocialConfig.Emotes.CooldownSeconds
	self.remotes.QuickEmote:FireServer(id)
end

function Social:_showBubble(userId, id)
	if self.muted and userId ~= self.localUserId then
		return
	end
	local emote = SocialConfig.Emotes.List[id]
	local ball = self.marbles:FindFirstChild(Protocol.MarbleName(userId))
	local camera = workspace.CurrentCamera
	if not emote or not ball or not camera or (ball.Position - camera.CFrame.Position).Magnitude > SocialConfig.Emotes.MaxDistance then
		return
	end
	local old = ball:FindFirstChild("TC_Emote")
	if old then
		old:Destroy()
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "TC_Emote"
	gui.Size = UDim2.fromOffset(150, 46)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 6.5, 0)
	gui.MaxDistance = SocialConfig.Emotes.MaxDistance
	gui.LightInfluence = 0
	gui.AlwaysOnTop = true
	local frame = UIKit.new("Frame", { Size = UDim2.fromScale(1, 1), BackgroundColor3 = palette.Navy, BackgroundTransparency = 0.1 }, gui)
	UIKit.corner(frame, 0.4)
	UIKit.new("UIStroke", { Color = palette.Mint, Thickness = 2 }, frame)
	UIKit.label(frame, { Size = UDim2.fromScale(1, 1), Font = Enum.Font.GothamBlack, TextColor3 = palette.Mint, Text = emote.icon .. " " .. emote.text })
	gui.Parent = ball
	task.delay(SocialConfig.Emotes.ShowSeconds, function()
		if gui.Parent then
			gui:Destroy()
		end
	end)
end

function Social:Update(now)
	local poll = self.poll
	local showVote = poll ~= nil and self.eligible and now < (poll.closesAt or 0)
	self.votePanel.Visible = showVote
	if showVote then
		local left = math.max(0, math.ceil(poll.closesAt - now))
		UIKit.setText(self.voteTitle, self.voted and string.format("VOTE CAST: %s  (%d s)", SocialConfig.Vote.Options[self.voted].label, left) or string.format("SPECTATOR CHAOS VOTE  -  %d s", left))
		for i, b in ipairs(self.voteButtons) do
			b.AutoButtonColor = not self.voted
			b.BackgroundTransparency = (self.voted and self.voted ~= i) and 0.6 or 0
		end
	end
	local text = Social.BannerText(self.modifier, now)
	self.banner.Visible = text ~= nil and not showVote
	if text then
		UIKit.setText(self.banner, text)
	end
	local cooling = os.clock() < self.emoteReadyAt
	for i, b in ipairs(self.emoteButtons) do
		b.TextTransparency = cooling and 0.6 or 0
		local emote = SocialConfig.Emotes.List[i]
		UIKit.setText(b, cooling and tostring(math.ceil(self.emoteReadyAt - os.clock())) or emote.text)
	end
end

function Social:GetFirstVoteButton()
	return self.voteButtons[1]
end

function Social:Destroy()
	self.maid:Cleanup()
end

return Social
