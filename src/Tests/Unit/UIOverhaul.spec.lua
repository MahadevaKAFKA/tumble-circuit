--[[
	UIOverhaul.spec (2026-11-26) — player display preferences (schema, sanitizing, migration,
	reset plan), the style maths (HUD size, panel opacity, accents), left-handed mirroring and
	the "same handlers, re-placed" rules of the new hub card. Pure modules + source reads.
]]

local Spec = {}

function Spec.run(m)
	local results = { passed = 0, failed = 0, lines = {}, info = {} }
	local function check(name, ok, detail)
		if ok then
			results.passed = results.passed + 1
			table.insert(results.lines, "PASS  " .. name)
		else
			results.failed = results.failed + 1
			table.insert(results.lines, "FAIL  " .. name .. (detail and ("  -- " .. tostring(detail)) or ""))
		end
	end
	local Schema = m.PlayerDataSchema
	if not Schema then
		check("schema loads", false)
		return results
	end
	------------------------------------------------------------------ schema
	local want = { hudScale = 1.0, panelOpacity = 0.95, hudDensity = "Standard", uiAccent = "FollowMap", highContrast = false, controlLayout = "Default", sceneryDetail = "Standard", perfOverlay = false }
	local defaultsOk, short = true, true
	for key, value in pairs(want) do
		local spec = Schema.Settings[key]
		defaultsOk = defaultsOk and spec ~= nil and spec.default == value
		short = short and #key <= 16
	end
	check("display preferences exist with the handoff defaults (100%, 95%, Standard, Follow map, ...)", defaultsOk)
	check("every key fits the 16-character RequestSettings limit", short)
	local S = Schema.SanitizeSetting
	local function near(a, b)
		return type(a) == "number" and math.abs(a - b) < 1e-6
	end
	check("HUD size clamps to 85-125% in 5% steps", near(S("hudScale", 2), 1.25) and near(S("hudScale", 0.1), 0.85) and near(S("hudScale", "1.07"), 1.05))
	check("panel opacity clamps to 75-100%", near(S("panelOpacity", 0.2), 0.75) and near(S("panelOpacity", 5), 1))
	check("garbage values fall back to defaults (NaN, unknown enum, wrong type)", S("hudScale", 0 / 0) == 1.0 and S("uiAccent", "Plaid") == "FollowMap" and S("highContrast", 7) == false)
	check("unknown keys are rejected", S("fontSize", 3) == nil)
	local old = Schema.Migrate({ schemaVersion = 5, settings = { music = 0.3, cameraMode = "Wide", bogus = "x" } })
	check("an old save keeps its settings and gains display defaults (unknown keys dropped)", near(old.settings.music, 0.3) and old.settings.cameraMode == "Wide" and old.settings.hudScale == 1.0 and old.settings.uiAccent == "FollowMap" and old.settings.bogus == nil)
	local display = {}
	for _, key in ipairs(Schema.DisplaySettingOrder) do
		display[key] = Schema.Settings[key] ~= nil
	end
	check("the DISPLAY tab lists only real settings", display.hudScale and display.panelOpacity and display.hudDensity and display.uiAccent and display.highContrast and display.sceneryDetail)
	-- brief 2026-11-26: one dedicated DRIVING view (camera, steering, touch layout, HUD
	-- position, motion feedback, trails, intro skip) and every row is a real, saved setting
	local driving, seen, dup = {}, {}, false
	for _, order in ipairs({ Schema.SettingOrder, Schema.DrivingSettingOrder, Schema.DisplaySettingOrder }) do
		for _, key in ipairs(order) do
			dup = dup or seen[key] == true
			seen[key] = true
		end
	end
	for _, key in ipairs(Schema.DrivingSettingOrder) do
		driving[key] = Schema.Settings[key] ~= nil
	end
	check("DRIVING tab: camera, steering, control layout, HUD position, reduced motion, speed effects, trails, intro skip", driving.cameraMode and driving.sensitivity and driving.controlLayout and driving.hudAlign and driving.reducedMotion and driving.speedEffects and driving.trailVisibility and driving.introSkip and #Schema.DrivingSettingOrder <= 8)
	check("no setting appears on two tabs; every saved setting except the Garage filter has a row", not dup and (function()
		for key in pairs(Schema.Settings) do
			if not seen[key] and key ~= "garageFilter" then
				return false
			end
		end
		return true
	end)())

	------------------------------------------------------------------ settings view
	local SC = m.SettingsPure
	if SC then
		local current = Schema.DefaultSettings()
		current.hudScale, current.uiAccent, current.music = 1.2, "Violet", 0.1
		local plan = SC.ResetPlan(current)
		check("RESET DISPLAY changes only display keys that differ from the defaults", plan.hudScale == 1.0 and plan.uiAccent == "FollowMap" and plan.music == nil and plan.panelOpacity == nil)
		check("enum rows cycle (accent: Follow map -> Cyan)", SC.Step("uiAccent", "FollowMap", 1) == "Cyan" and SC.Step("controlLayout", "Default", 1) == "LeftHanded")
		check("number rows step and clamp (HUD size 125% + step stays 125%)", math.abs(SC.Step("hudScale", 1.25, 1) - 1.25) < 1e-6 and math.abs(SC.Step("hudScale", 1.0, -1) - 0.95) < 1e-6)
	end

	------------------------------------------------------------------ style maths
	local UI = m.UIKitPure
	if UI then
		check("95% opacity = the designed look; 75% is more see-through; 100% is opaque", math.abs(UI.PanelTransparency(0.05, 0.95) - 0.05) < 1e-9 and UI.PanelTransparency(0.05, 0.75) > 0.2 and UI.PanelTransparency(0.05, 1) < 0.01)
		check("modal panels scale the same way and never leave 0-1", UI.PanelTransparency(0.04, 1) >= 0 and UI.PanelTransparency(0.9, 0.75) <= 1)
		local sky = UI.StyleFromSettings({ uiAccent = "FollowMap", hudScale = 1.25 }, "SkyCarnival_B1")
		local cyan = UI.StyleFromSettings({ uiAccent = "Cyan" }, "SkyCarnival_B1")
		check("Follow map uses the map's accent; an explicit accent overrides it", sky.accent == UI.MapAccents.SkyCarnival_B1 and cyan.accent == UI.Accents.Cyan and sky.scale == 1.25)
		check("an unknown map falls back to cyan", UI.StyleFromSettings({}, "Nope").accent == UI.Accents.Cyan)
	end
	local TC = m.TouchControlsPure
	if TC then
		local pos, anchor = TC.Mirror(UDim2.new(1, -24, 1, -24), Vector2.new(1, 1))
		local back, backAnchor = TC.Mirror(pos, anchor)
		check("left-handed mirror: bottom-right button -> bottom-left, same distance from the edge", pos.X.Scale == 0 and pos.X.Offset == 24 and anchor.X == 0 and back.X.Scale == 1 and back.X.Offset == -24 and backAnchor.X == 1)
	end

	------------------------------------------------------------------ one handler per action
	if m.ReadFile then
		local match = m.ReadFile("src/StarterPlayer/StarterPlayerScripts/Controllers/MatchUIController.lua")
		local _, joins = match:gsub("self%.JoinRequested:Fire%(", "")
		check("one queue path: JoinRequested fires from one place only", joins == 1, tostring(joins))
		check("the card re-parents the existing buttons (no second set)", match:find("self.queueButton.Parent = card", 1, true) and match:find("b.Parent = drawer", 1, true) and match:find("self.settingsButton.Parent = card", 1, true))
		local boot = m.ReadFile("src/StarterPlayer/StarterPlayerScripts/ClientBootstrap.client.lua")
		local _, ability = boot:gsub("RequestAbility", "")
		check("no second ability path: the bootstrap still calls abilities:RequestAbility exactly once", ability == 1, tostring(ability))
		check("legacy HUD stays one flag away", m.GameConfig.UI.LegacyHud == false and boot:find("if not GameConfig.UI.LegacyHud then", 1, true) ~= nil)
		check("debug telemetry is off in the player view; developers only", m.GameConfig.Debug.PerfOverlayDefault == false and boot:find("s.perfOverlay == true and isDeveloper()", 1, true) ~= nil)
		local settingsSrc = m.ReadFile("src/StarterPlayer/StarterPlayerScripts/Controllers/SettingsController.lua")
		check("closing Settings during a reset preview undoes it", settingsSrc:find("if not visible and self.preview then", 1, true) ~= nil)
		local ui = m.UIController
		if ui then
			local lobby = {}
			for _, b in ipairs(ui.Screens.Lobby.buttons) do
				lobby[b] = true
			end
			check("hub card controls are wired screen buttons (MAPS, MENU, profile, EXIT PRACTICE)", lobby.Maps and lobby.HubDrawer and lobby.ProfileDrawer and lobby.ExitPractice)
		end
	end
	------------------------------------------------------------------ brief 2026-11-26 (M4)
	local PS = m.PhaseStripPure
	if PS then
		local base = { v = 14, state = "Intermission", stateEndsAt = 114, nextWorldId = "SkyCarnival_B1", worldId = "NeonFoundry_A4", readyOpen = false, queuedCount = 2, raceCapacity = 16 }
		local t = PS.Text(base, { now = 100 })
		check("phase strip: map, phase and the ONE next-race timer in the lobby", t.map == "SKY CARNIVAL" and t.phase == "QUEUE OPEN" and t.timer == "STARTS IN 14")
		base.queuedCount = 0
		check("phase strip with nobody queued says WAITING 0/16, never 'NEXT RACE 0' (owner screenshot)", PS.Text(base, { now = 100 }).timer == "WAITING 0/16")
		base.state = "Countdown"
		local c = PS.Text(base, { now = 100 })
		check("phase strip during the countdown: map + STARTING for the hub; hidden for racers (the race HUD shows the course)", c.map == "NEON FOUNDRY" and c.phase == "STARTING" and c.timer == "" and PS.Text(base, { now = 100, racing = true }) == nil)
		base.state = "Racing"
		base.raceStartedAt = 40
		check("phase strip hides for racers during the race (the race strip carries it), shows RACE LIVE to others", PS.Text(base, { now = 100, racing = true }) == nil and PS.Text(base, { now = 100, racing = false }).phase == "RACE LIVE")
	end
	local HM2 = m.HubMenusPure
	if HM2 and HM2.SortItems then
		local items = HM2.FilterItems("Marble", "All", { owned = {}, favorites = {} }, "")
		local state = { owned = { cobalt = true, tangerine = true }, favorites = {} }
		local sorted = HM2.SortItems(items, function(it)
			return it.Id == "tangerine"
		end, state)
		check("Garage order: equipped first, then owned, then rarest first", sorted[1].Id == "tangerine" and sorted[2].Id == "cobalt" and sorted[3].Rarity == "Mythic")
		local found = HM2.FilterItems("Trail", "All", state, "emb")
		check("Garage search filters by name (case-insensitive)", #found == 1 and found[1].Id == "trail_ember")
		check("Garage categories with labels: Skins, Trails, Launch, Bursts, Emotes", HM2.Tabs[1] == "Marble" and HM2.Tabs[3] == "Launch" and HM2.TabLabels.Marble == "SKINS")
	end
	------------------------------------------------------------------ v36 redesign (owner: "the UI looks the same")
	if UI and UI.LaneClaim then
		local flash = { Visible = false, Parent = true }
		local toast = { Visible = false, Parent = true }
		local count = { Visible = false, Parent = true }
		UI.LaneJoin(toast, 1, false)
		UI.LaneJoin(flash, 2, false)
		UI.LaneJoin(count, 3, false)
		toast.Visible = true
		local tOk = UI.LaneClaim(toast)
		flash.Visible = true
		local fOk = UI.LaneClaim(flash)
		check("callout lane: a checkpoint flash replaces a showing toast (never two stacked)", tOk and fOk and flash.Visible and not toast.Visible)
		count.Visible = true
		UI.LaneClaim(count)
		toast.Visible = true
		local blocked = UI.LaneClaim(toast)
		check("callout lane: the countdown keeps the lane; a toast during it stays hidden", count.Visible and not flash.Visible and not blocked and not toast.Visible)
		for k in pairs(UI.LaneMembers) do
			if k == flash or k == toast or k == count then
				UI.LaneMembers[k] = nil
			end
		end
		check("design system v2: font + colour tokens exist (Display face for titles and timers)", UI.Fonts ~= nil and UI.Colors ~= nil and UI.Colors.Surface ~= nil)
	end
	if m.ReadFile then
		local shop = m.ReadFile("src/StarterPlayer/StarterPlayerScripts/Controllers/ShopController.lua")
		check("Shop is a storefront: case cards (VIEW ODDS) and item cards drawn in the item's own colours", shop:find('Name = "ShopCase"', 1, true) and shop:find("ItemSwatch.Draw(art, offer.grants[1])", 1, true) and shop:find("ItemSwatch.Draw(self.flat, item)", 1, true)) -- shop brief: the detail preview (3D marble / trail loop / podium ring / swatch)
		local lab = m.ReadFile("src/StarterPlayer/StarterPlayerScripts/Controllers/LabController.lua")
		check("case contents show each item's swatch, not only its name", lab:find("ItemSwatch.Draw(tile.art", 1, true) ~= nil)
		local match = m.ReadFile("src/StarterPlayer/StarterPlayerScripts/Controllers/MatchUIController.lua")
		check("hub: bottom icon dock + compact play card replace the long button column", match:find('"HubDock"', 1, true) and match:find('"HubCard"', 1, true))
		local touch = m.ReadFile("src/StarterPlayer/StarterPlayerScripts/Controllers/TouchControls.lua")
		check("race thumb controls are glass (dark translucent with a thin white ring)", touch:find("GLASS", 1, true) ~= nil)
	end
	return results
end

return Spec
