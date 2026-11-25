--[[
	PLACEHOLDER_IDS — mapped by Rojo to ReplicatedStorage.Shared.PlaceholderIds

	No asset IDs are invented. Every slot is nil (commented out) until the owner uploads or
	licenses an asset and pastes its id as "rbxassetid://<number>".
	Code treats a missing id as "silent / hidden" — the game is fully playable with this file as is.

	D: product / Game Pass ids live below, ALL nil until the owner creates them in the Creator
	Dashboard and pastes the number. A nil id = that offer shows "Not on sale yet" and cannot be
	bought. Nothing is purchasable with this file as shipped.
]]

return {
	Sounds = {
		-- RunStart = "rbxassetid://<id>",
		-- Finish = "rbxassetid://<id>",
		-- BumperKick = "rbxassetid://<id>",
		-- Respawn = "rbxassetid://<id>",
		-- Checkpoint = "rbxassetid://<id>",
		-- UIClick = "rbxassetid://<id>",
	},
	Music = {
		-- Practice = "rbxassetid://<id>",
	},
	-- D: optional direct-sale cosmetics (Developer Products). Number ids only, e.g. 1234567890.
	Products = {
		-- MarblePolishedCopper = <id>,
		-- MarbleQuantumChrome = <id>,
		-- MarblePhoenixEmber = <id>,
		-- TrailEmber = <id>,
		-- TrailRainbow = <id>,
		-- BurstLightning = <id>,
		-- EmoteRematch = <id>,
		-- SeasonPremium_S1 = <id>, -- season-keyed: only Season 1's premium lane
	},
	-- D: Founder's Style Pack (a permanent Game Pass)
	GamePasses = {
		-- FounderPack = <id>,
	},
	-- D2: paid random capsules. OFF. Changing this needs the owner's explicit, informed decision
	-- AND code that does not exist in this build (there is no paid capsule route at all).
	ENABLE_PAID_CAPSULES = false,
	-- Keys the code may ask for. Tests check that anything you fill in is well-formed.
	KnownSoundKeys = { "RunStart", "Finish", "BumperKick", "Respawn", "UIClick", "Checkpoint" },
}
