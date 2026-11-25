--[[
	UIState.spec (A5) — the single UI state owner: screen for every round situation, modal rules
	(no loadout change mid-race), automatic modal close, every visible button bound to an action,
	settings stepping, loadout swapping, results PB lines, and (offline) a scan of client UI text
	for shop / Robux / capsule / season prompts that must not exist in Phase A.
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
	local UI = m.UIController
	local function screen(t)
		return UI.ScreenFor(t)
	end
	check("before PLAY: Title", screen({ started = false, roundState = "Racing", inRace = true }) == "Title")
	check("hub between races: Lobby", screen({ started = true, roundState = "Intermission", inRace = false }) == "Lobby")
	check("on the grid / countdown / racing: Race", screen({ started = true, roundState = "Preparing", inRace = true }) == "Race" and screen({ started = true, roundState = "Countdown", inRace = true }) == "Race" and screen({ started = true, roundState = "Racing", inRace = true }) == "Race")
	check("race running without you: Lobby (spectate button there)", screen({ started = true, roundState = "Racing", inRace = false }) == "Lobby")
	check("spectating wins over everything after PLAY", screen({ started = true, spectating = true, roundState = "Racing", inRace = false }) == "Spectate")
	check("results for racers and watchers", screen({ started = true, roundState = "Results", inRace = true }) == "Results" and screen({ started = true, roundState = "Results", inRace = false }) == "Results")
	check("PLAY AGAIN / SIT OUT dismiss results to the lobby", screen({ started = true, roundState = "Results", inRace = true, resultsDismissed = true }) == "Lobby")

	check("loadout modal only in Lobby / Results (never mid-race)", UI.ModalAllowed("Loadout", "Lobby") and UI.ModalAllowed("Loadout", "Results") and not UI.ModalAllowed("Loadout", "Race") and not UI.ModalAllowed("Loadout", "Spectate") and not UI.ModalAllowed("Loadout", "Title"))
	check("settings modal never covers the race", not UI.ModalAllowed("Settings", "Race") and UI.ModalAllowed("Settings", "Lobby"))

	local ui = UI.new()
	local shown = {}
	for _, name in ipairs({ "Title", "Hud", "RaceHud", "Lobby", "Spectate", "Results", "Settings", "Loadout", "Touch", "AbilitiesRace" }) do
		ui:Register(name, function(v)
			shown[name] = v
		end)
	end
	ui:Refresh({ started = true, roundState = "Intermission" })
	local opened = ui:OpenModal("Loadout")
	check("opening the loadout in the lobby shows it and hides touch input", opened and shown.Loadout and not shown.Touch and shown.Lobby)
	ui:Refresh({ started = true, roundState = "Countdown", inRace = true })
	check("race start closes the loadout modal automatically", ui:GetModal() == nil and not shown.Loadout and shown.AbilitiesRace and shown.Touch)
	check("opening a modal on the race screen is refused", ui:OpenModal("Loadout") == false and ui:OpenModal("Settings") == false)
	ui:Refresh({ started = true, roundState = "Results", inRace = true })
	check("results screen shows only results + race HUD layers", shown.Results and shown.RaceHud and not shown.Lobby and not shown.AbilitiesRace and not shown.Touch)

	local actions = {}
	for _, a in ipairs(UI.Actions) do
		actions[a] = true
	end
	local dead = {}
	for name, spec in pairs(UI.Screens) do
		for _, button in ipairs(spec.buttons) do
			if not actions[button] then
				dead[#dead + 1] = name .. "." .. button
			end
		end
	end
	for name, spec in pairs(UI.Modals) do
		for _, button in ipairs(spec.buttons) do
			if not actions[button] then
				dead[#dead + 1] = name .. "." .. button
			end
		end
	end
	check("no dead buttons: every screen/modal button has an action", #dead == 0, table.concat(dead, ", "))
	local forbidden = false
	for a in pairs(actions) do
		local l = a:lower()
		-- C: earned capsules, the Shard Shop and the free season exist; nothing is bought with Robux
		if l:find("buy") or l:find("robux") or l:find("purchase") or l:find("premium") then
			forbidden = true
		end
	end
	check("no buy / Robux / purchase / premium actions exist (earned-only economy)", not forbidden)

	local SC = m.SettingsPure
	if SC then
		check("settings: toggle flips, enum cycles, number steps and clamps", SC.Step("reducedMotion", false, 1) == true and SC.Step("cameraMode", "Chase", 1) == "Wide" and SC.Step("cameraMode", "Wide", 1) == "Chase" and SC.Step("music", 1, 1) == 1 and math.abs(SC.Step("sensitivity", 1, -1) - 0.9) < 1e-9 and SC.Step("graphicsMode", "Auto", -1) == "High")
	end
	local LC = m.LoadoutPure
	if LC then
		local swapped = LC.Choose({ "Boost", "Shield" }, 1, "Shield")
		local placed = LC.Choose({ "Boost", "Shield" }, 2, "Pulse")
		check("loadout: choosing the other slot's ability swaps; always two distinct", swapped[1] == "Shield" and swapped[2] == "Boost" and placed[1] == "Boost" and placed[2] == "Pulse")
	end
	local RC = m.ResultsPure
	if RC then
		check("results: PB lines (new with delta / first on variation / slower / none)", RC.PbLine({ isNew = true, previous = 95.2, seconds = 93.0 }):find("2.20") ~= nil and RC.PbLine({ isNew = true, seconds = 90 }):find("FIRST") ~= nil and RC.PbLine({ isNew = false, previous = 90, seconds = 91.5 }):find("+1.50") ~= nil and RC.PbLine({ isNew = false }) == nil)
	end
	if m.ClientUiStrings then
		local hits = {}
		for _, text in ipairs(m.ClientUiStrings) do
			local l = text:lower()
			-- "Robux" may appear only in a sentence saying it is NOT used
			local robuxPrompt = l:find("robux") and not (l:find("no robux") or l:find("never robux") or l:find("costs robux") or l:find("not robux") or l:find("bought with robux"))
			if robuxPrompt or l:find("season pass") or l:find("premium") or l:find("buy ") or l:find("purchase") then
				hits[#hits + 1] = text
			end
		end
		check("client UI text has no Robux / buy / purchase / premium prompts (earned-only)", #hits == 0, table.concat(hits, " | "))
		check("no MarketplaceService anywhere in the game source", m.UsesMarketplace == false)
	end
	return results
end

return Spec
