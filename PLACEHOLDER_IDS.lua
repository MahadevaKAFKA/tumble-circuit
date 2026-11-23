--[[
	PLACEHOLDER_IDS — mapped by Rojo to ReplicatedStorage.Shared.PlaceholderIds

	No asset IDs are invented. Every slot is nil (commented out) until the owner uploads or
	licenses an asset and pastes its id as "rbxassetid://<number>".
	Code treats a missing id as "silent / hidden" — the game is fully playable with this file as is.

	Product and Game Pass ids are intentionally absent: they do not exist before Phase D.
]]

return {
	Sounds = {
		-- RunStart = "rbxassetid://<id>",
		-- Finish = "rbxassetid://<id>",
		-- BumperKick = "rbxassetid://<id>",
		-- Respawn = "rbxassetid://<id>",
		-- UIClick = "rbxassetid://<id>",
	},
	Music = {
		-- Practice = "rbxassetid://<id>",
	},
	-- Keys the code may ask for. Tests check that anything you fill in is well-formed.
	KnownSoundKeys = { "RunStart", "Finish", "BumperKick", "Respawn", "UIClick" },
}
