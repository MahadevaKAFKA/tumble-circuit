--[[
	VisualProfiles (promo pack prompts 02 / 04 / 16) — lighting + post-effect profiles by name.
	Registry maps and hubs name one each. Presentation only: no collision, timing or physics.

	Every profile sets EVERY field it owns (no partial profiles), so switching from any profile to
	any other leaves nothing behind. Apply(lighting, profile, effects) takes the Lighting
	service (or a fake table in specs) and returns the list of fields it wrote.
	"NeonFoundry" is the exact pre-registry environment (TrainingTrackService:ApplyEnvironment).
]]

local VisualProfiles = {}

local function rgb(r, g, b)
	return Color3.fromRGB(r, g, b)
end

VisualProfiles.Default = "NeonFoundry"

VisualProfiles.Profiles = {
	NeonFoundry = {
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
	},
	SkyCarnival = {
		ClockTime = 14.5,
		Brightness = 2.6,
		Ambient = rgb(120, 130, 170),
		OutdoorAmbient = rgb(150, 160, 200),
		EnvironmentDiffuseScale = 0.6,
		EnvironmentSpecularScale = 0.6,
		FogColor = rgb(200, 220, 245),
		FogStart = 500,
		FogEnd = 2400,
		Bloom = { Intensity = 0.35, Size = 18, Threshold = 1.8 },
		Grade = { Contrast = 0.05, Saturation = 0.1, Brightness = 0.02, TintColor = rgb(255, 250, 244) },
	},
	VolcanoVault = {
		ClockTime = 19,
		Brightness = 1.6,
		Ambient = rgb(70, 46, 46),
		OutdoorAmbient = rgb(96, 64, 58),
		EnvironmentDiffuseScale = 0.4,
		EnvironmentSpecularScale = 0.8,
		FogColor = rgb(41, 35, 41),
		FogStart = 260,
		FogEnd = 1500,
		Bloom = { Intensity = 0.55, Size = 22, Threshold = 1.5 },
		Grade = { Contrast = 0.1, Saturation = 0.05, Brightness = 0, TintColor = rgb(255, 244, 236) },
	},
}
VisualProfiles.Profiles.OrbitalGarage = VisualProfiles.Profiles.NeonFoundry
VisualProfiles.Profiles.BalloonTerminal = VisualProfiles.Profiles.SkyCarnival

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
	return written
end

return VisualProfiles
