--[[
	SocialConfig (A6) — spectator Chaos Vote and quick emotes, shared by server and client.
	Both vote options are harmless, telegraphed and bounded (HazardSim.Modifiers): they only
	change existing hazards for a short window and never make the course impossible.
]]

local SocialConfig = {}

SocialConfig.Vote = {
	IntervalSeconds = 20, -- a poll may open every 20 s of Racing...
	WindowSeconds = 5, -- ...stays open 5 s...
	LeadSeconds = 3, -- ...the winner is announced to racers 3 s before it starts...
	DurationSeconds = 8, -- ...and lasts 8 s.
	MinSecondsLeft = 20, -- no poll when the race is about to end
	Options = {
		{ id = "TurboFans", label = "TURBO FANS", description = "Fan tunnel gusts +50% for 8 s" },
		{ id = "BouncyBumpers", label = "BOUNCY BUMPERS", description = "Bumper kicks +25% for 8 s" },
	},
}

SocialConfig.Emotes = {
	CooldownSeconds = 5,
	ShowSeconds = 2.5,
	MaxDistance = 120, -- bubbles farther away than this are not drawn
	List = {
		{ id = 1, text = "GG", icon = "★", key = "One" },
		{ id = 2, text = "Nice Save!", icon = "✦", key = "Two" },
		{ id = 3, text = "Oops!", icon = "!", key = "Three" },
	},
}

return SocialConfig
