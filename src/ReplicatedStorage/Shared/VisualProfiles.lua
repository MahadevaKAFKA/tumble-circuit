--[[
	VisualProfiles (promo pack prompts 02 / 04 / 16) — lighting + post-effect profiles by name.
	Registry maps and hubs name one each. Presentation only: no collision, timing or physics.

	Every profile sets EVERY field it owns (no partial profiles), so switching from any profile to
	any other leaves nothing behind. Apply(lighting, profile, effects) takes the Lighting
	service (or a fake table in specs) and returns the list of fields it wrote.
	"ClassicNight" is the exact pre-registry environment (the server's start-up lighting); the
	map profiles (UI / environment overhaul) are applied by each client for the zone it is in.
]]

local VisualProfiles = {}

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

VisualProfiles.Default = "ClassicNight"

-- Atmosphere defaults for profiles that have none (= effectively off)
local NO_ATMOSPHERE = { Density = 0, Offset = 0, Color = rgb(199, 199, 199), Decay = rgb(106, 112, 125), Glare = 0, Haze = 0 }

VisualProfiles.Profiles = {
	-- the A1-B1 night look; the server's start-up lighting and the fallback for unknown names
	ClassicNight = {
		ClockTime = 0,
		Brightness = 2,
		Ambient = rgb(46, 56, 96),
		OutdoorAmbient = rgb(70, 82, 130),
		EnvironmentDiffuseScale = 0.4,
		EnvironmentSpecularScale = 1,
		FogColor = rgb(16, 23, 45),
		FogStart = 300,
		FogEnd = 1600,
		Bloom = { Intensity = 0.7, Size = 24, Threshold = 1.4 },
		Grade = { Contrast = 0.08, Saturation = 0.12, Brightness = 0, TintColor = rgb(255, 255, 255) },
		Atmosphere = NO_ATMOSPHERE,
	},
	-- UI / environment overhaul (2026-11-26): one art direction per map (handoff table)
	NeonFoundry = { -- cobalt dusk
		ClockTime = 18.4,
		Brightness = 1.8,
		Ambient = rgb(60, 70, 110),
		OutdoorAmbient = rgb(82, 94, 142),
		EnvironmentDiffuseScale = 0.5,
		EnvironmentSpecularScale = 0.6,
		FogColor = rgb(44, 56, 102),
		FogStart = 420,
		FogEnd = 2400,
		Bloom = { Intensity = 0.45, Size = 20, Threshold = 1.6 },
		Grade = { Contrast = 0.08, Saturation = 0.08, Brightness = 0, TintColor = rgb(236, 240, 255) },
		Atmosphere = { Density = 0.3, Offset = 0.1, Color = rgb(98, 112, 170), Decay = rgb(40, 46, 92), Glare = 0.2, Haze = 1.6 },
	},
	SkyCarnival = { -- peach daylight
		ClockTime = 16.2,
		Brightness = 2.6,
		Ambient = rgb(140, 128, 128),
		OutdoorAmbient = rgb(170, 152, 140),
		EnvironmentDiffuseScale = 0.6,
		EnvironmentSpecularScale = 0.5,
		FogColor = rgb(255, 214, 190),
		FogStart = 650,
		FogEnd = 3200,
		Bloom = { Intensity = 0.3, Size = 18, Threshold = 2.0 },
		Grade = { Contrast = 0.04, Saturation = 0.12, Brightness = 0.01, TintColor = rgb(255, 246, 236) },
		Atmosphere = { Density = 0.26, Offset = 0.2, Color = rgb(255, 206, 176), Decay = rgb(255, 170, 150), Glare = 0.4, Haze = 1.2 },
	},
	VolcanoVault = { -- smoky copper (no full-screen orange haze: moderate density)
		ClockTime = 17.6,
		Brightness = 1.5,
		Ambient = rgb(92, 66, 56),
		OutdoorAmbient = rgb(112, 80, 64),
		EnvironmentDiffuseScale = 0.45,
		EnvironmentSpecularScale = 0.6,
		FogColor = rgb(90, 60, 46),
		FogStart = 320,
		FogEnd = 2000,
		Bloom = { Intensity = 0.4, Size = 20, Threshold = 1.6 },
		Grade = { Contrast = 0.1, Saturation = 0, Brightness = 0, TintColor = rgb(255, 238, 226) },
		Atmosphere = { Density = 0.38, Offset = 0.15, Color = rgb(176, 112, 76), Decay = rgb(92, 50, 34), Glare = 0.1, Haze = 2.2 },
	},
}
VisualProfiles.Profiles.OrbitalGarage = VisualProfiles.Profiles.NeonFoundry
VisualProfiles.Profiles.BalloonTerminal = VisualProfiles.Profiles.SkyCarnival
VisualProfiles.Profiles.BasaltDeck = VisualProfiles.Profiles.VolcanoVault

VisualProfiles.Fields = {
	"ClockTime", "Brightness", "Ambient", "OutdoorAmbient", "EnvironmentDiffuseScale",
	"EnvironmentSpecularScale", "FogColor", "FogStart", "FogEnd",
}

function VisualProfiles.Get(name)
	return VisualProfiles.Profiles[name or ""] or VisualProfiles.Profiles[VisualProfiles.Default], VisualProfiles.Profiles[name or ""] == nil
end

-- effects = { bloom = BloomEffect, grade = ColorCorrectionEffect } (either may be nil)
function VisualProfiles.Apply(lighting, profile, effects)
	local written = {}
	if not (lighting and profile) then
		return written
	end
	for _, field in ipairs(VisualProfiles.Fields) do
		if profile[field] ~= nil then
			lighting[field] = profile[field]
			written[#written + 1] = field
		end
	end
	effects = effects or {}
	if effects.bloom and profile.Bloom then
		for key, value in pairs(profile.Bloom) do
			effects.bloom[key] = value
		end
		written[#written + 1] = "Bloom"
	end
	if effects.grade and profile.Grade then
		for key, value in pairs(profile.Grade) do
			effects.grade[key] = value
		end
		written[#written + 1] = "Grade"
	end
	if effects.atmosphere then
		for key, value in pairs(profile.Atmosphere or NO_ATMOSPHERE) do
			effects.atmosphere[key] = value
		end
		written[#written + 1] = "Atmosphere"
	end
	return written
end

return VisualProfiles
