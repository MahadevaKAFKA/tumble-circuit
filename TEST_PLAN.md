# TEST_PLAN — A1

Three layers: automated offline (runs anywhere), automated in Studio (runs on Play), and a manual
playtest checklist only a human in Studio can do. Record results in `BUILD_STATUS.md`
(date, device, what you saw).

## 1. Automated — offline

```
texlua tools/offline/run_tests.lua .
```
Covers: syntax of every file; config ranges; smoothing/deadzone/time maths; course generation and
validation; floor geometry exactness; steering-frame stability; route tracking; spawn clearance;
hazard timing. Does **not** cover anything the engine does.

## 2. Automated — Studio (TestRunner)

Press **Play**. In **Output** look for:
```
[TumbleTests] ===== A1 pure specs: 57 passed, 0 failed =====
[TumbleTests] ===== A1 Studio integration: N passed, 0 failed =====
```
Integration checks: course built with every computed part; no validation errors; spawn clear of
geometry with floor beneath it; floor under every route sample; exactly one RemoteEvent;
`CharacterAutoLoads` off; no Humanoid anywhere; marble exists, one collider, 4-stud ball, mass =
ball only, unanchored, no Character. Any `FAIL` line is printed as a warning.

## 3. Manual Play Solo checklist (maps to the A1 acceptance tests)

Do these in order. Tick each, note anything odd.

**A. First load (acceptance 1, 6)**
- [ ] Press Play. Within a few seconds: night sky, neon course, title "TUMBLE CIRCUIT / CHAOS DROP", marble visible behind the dim overlay.
- [ ] No grey blank viewport; no default avatar anywhere.
- [ ] Output has no red errors. (Yellow `[TumbleTests]` "deliberate test error" warning is expected.)
- [ ] No sound plays at all (all ids are nil) and nothing errors about sound.

**B. Steering & camera (acceptance 2)**
- [ ] Click PLAY PRACTICE. The steering hint card appears. Tap A then D: LEFT and RIGHT turn green, card closes with "Nice steering!". (Also try SKIP on a second session.)
- [ ] On the pad, D moves the marble to the screen's right, A to the left. The stripes visibly roll.
- [ ] W rolls forward; S pulls back gently.
- [ ] Roll through START: the timer starts counting.
- [ ] Through the S-turn, the camera swings smoothly with the track; A/D stay screen-left/right.
- [ ] Into the banked drop: the camera tilts down; it **never flips** or spins 180°; A/D still mean left/right.
- [ ] Press V (or CAM): toast "Camera: Wide", view pulls back; press again for Chase.

**C. Braking & physics (acceptance 3)**
- [ ] At speed, hold Shift: speed number drops smoothly to ~65 % and holds on downhill; no snapping.
- [ ] Release and press again: another smooth cut.
- [ ] Hit a rail: the marble bounces off, does not stop dead or tunnel through.
- [ ] Bumper: watch it go cyan → yellow → coral. Touching it while **coral** pushes you away; while cyan it just bounces you.

**D. Finish loop ×3 (acceptance 4)**
- [ ] Cross the checkered line: "FINISH!" + time, marble slows in the basin.
- [ ] TRY AGAIN (click / Enter / A): back on the pad, timer 0.00, overlay gone.
- [ ] Complete **three consecutive runs**. Session best updates when you beat it ("NEW SESSION BEST!").

**E. Resets & respawn (acceptance 5)**
- [ ] Hold R mid-run: fill bar, after 1 s marble is back on the pad, timer reset, camera snaps (no swoop), steering works immediately.
- [ ] Holding R keeps you on the pad (does not reset every second) until you release.
- [ ] Deliberately fall off (e.g. jump the rail at the drop if possible, or steer off the pad's open front edge at speed): "Fell off" toast after ~1 s, respawn on pad.
- [ ] Finish, then hold R instead of TRY AGAIN: same clean reset.
- [ ] Roblox menu (Esc) → Reset Character: marble resets.
- [ ] Stop, Play again (rejoin): title shows, everything works as on first load.

**F. Devices**
- [ ] Gamepad (if available): left stick steer, LT brake, hold Y reset, R3 camera, A on title/finish.
- [ ] Touch: Studio **Test → Device** emulator (pick a phone, landscape). Exactly **one** stick appears on the left when you drag; BRAKE, RESET (hold, with fill) and CAM on the right; nothing overlaps the timer or speed. No Roblox jump button or second stick.
- [ ] Type in chat with A/D/R in the message: the marble does not steer or reset.

**G. Frame time (acceptance 7)**
- [ ] Press F2: top-left shows `FPS / avg ms / p95 ms`. Note values on the pad and in the banked drop.
- [ ] Studio MicroProfiler (View → MicroProfiler, or Ctrl+F6) during the drop: note any spikes.
- [ ] Low-FPS feel test: limit the frame rate (Roblox in-game Settings → Maximum Frame Rate, where available, e.g. 30) and repeat B–C. Steering and brake should feel the same, just less smooth. Write down if anything changes behaviour.

## 4. Owner playtest questions (please answer before A2)

1. **Roll feel:** Does steering feel responsive or floaty? Is A/D strength right (too twitchy / too weak)?
2. **Speed:** Is cruising (~40 studs/s with W) and the drop (~80) fun, too slow, or scary? Does it feel "sticky" (too much drag)?
3. **Brake:** Is "each press cuts ~35 % and holds" intuitive, or would you prefer a plain hold-to-slow brake?
4. **Auto-align:** When you let go of A/D the marble gently lines up with the track. Helpful, or does it feel like the game steers for you?
5. **Camera:** Distance and tilt OK? Any moment you lost sight of the marble or felt sick? Chase or Wide as default?
6. **Course:** How long did your first three runs take? (Target 35–75 s on first attempts; our model guesses ~18 s for a perfect run.) Which section was most fun, which was boring?
7. **Bumper:** Was the coral warning readable? Kick too weak / too strong?
8. **Bugs:** Any Output errors (copy the red lines), bumps on the floor seams, getting stuck, falling through?
9. **Performance:** F2 numbers on your PC (and phone, if tried).
10. **Go / no-go:** Is the roll + camera + first track fun enough to start A2 (multiplayer rounds)?

## 5. A2 — multiplayer rounds (Studio Test tab)

**Automated:** Output shows `A2 round specs: ... 0 failed`, `Studio integration (round)`, and after
~2 minutes a `[TumbleTests] timeline` listing transitions with timestamps.

**Two-client run:** Studio → **Test** tab → Clients and Servers → *Local Server*, **2 players** → Start.
Arrange the two client windows side by side. Expected server log order per round:
`Intermission -> Preparing (~15 s) -> Countdown (+2 s) -> Racing (+3 s) -> Results -> Cleanup (+12 s) -> Intermission (+1 s)`.

- [ ] Both clients: PLAY → you are on the round glass hub, can roll and use the practice chute; reaching its basin returns you to the hub.
- [ ] Board above the chute and the top HUD both count down the same "NEXT RACE" number (within ~0.2 s) on both clients.
- [ ] Start a 3rd client a few seconds late (or stop/start one client): it shows the same countdown immediately (late joiner).
- [ ] Preparing: both marbles appear on the start grid, slightly transparent, and cannot move (A/D does nothing).
- [ ] Countdown 3-2-1 then GO! appear at the same moment on both clients; the coral start gate vanishes at GO.
- [ ] Holding R during the countdown does nothing (cannot start early).
- [ ] After GO: marbles pass through each other for ~2 s (spawn protection), then bump visibly. A hard bump never launches a marble far.
- [ ] Each violet CHECKPOINT arch flashes "CHECKPOINT n / 3" only after it is actually passed; placement badge (1ST/2ND) and CP chip update.
- [ ] Tab shows the same standings order on both clients.
- [ ] Fall off at the banked drop: back at your last checkpoint after ~1.5 s, transparent briefly; checkpoint count unchanged.
- [ ] Hold R mid-race: back at last checkpoint (or grid before CP1).
- [ ] Finish: "FINISHED #n"; the other client toasts "<name> finished #n"; both Results screens list the same order and times.
- [ ] Let one player not finish: race ends at 180 s, that player shows DNF.
- [ ] Mid-race: close one client. The other keeps racing; if they were the last racer, the round goes to Cleanup/Intermission cleanly.
- [ ] Non-racer during a race: SPECTATE, then < / > (or Q/E, LB/RB) cycle racers; EXIT returns to your marble.
- [ ] SIT OUT on results → panel closes, next round runs without you; the hub button then reads JOIN RACE → tap it → "You're in the next race" and the button reads SIT OUT. PLAY AGAIN → panel closes, you race next round.
- [ ] Run 3 rounds in a row: no duplicate marbles in Workspace.TumbleMarbles, gate closed again at each Intermission, camera never lost.
- [ ] Output during all of this: no red errors. `[RacePhysics] movement rejected` should not appear in normal play (if it does, note when).

**Forged/malformed requests (Command Bar, server context, while playing):** the server only exposes
`RequestSnapshot`, `RequestRecover`, `RequestJoinRace(boolean)`. Malformed calls are rejected and logged
once per minute (`[Round] rejected: malformed ...`). A client cannot send checkpoints, times or positions:
there is no remote for them. (Blocked here: no client exploit harness; verify by reading RoundProtocol.)

**Network latency:** Studio's network simulation settings are a manual QA step (ADR-19); note any desync you see.

## 6. A3 — abilities and micro-skills

**Automated:** `A3 ability specs`, `A3 micro-skill specs`, `A3 ability security specs` (0 failed).

**Play Solo**
- [ ] Hub: the ABILITIES panel (bottom left; upper left on phones, so the stick keeps its corner) shows Q: BOOST, E: SHIELD. Tap a slot → it cycles (Boost/Shield/Pulse); choosing the other slot's ability swaps them. During a race the panel is hidden and changes are refused.
- [ ] Race: two round buttons bottom right with READY. Q (or LB / tap) → Boost: cyan trail, camera FOV widens slightly, speed rises to ~1.3x for 1.6 s then settles; button shows a 20 s countdown fill.
- [ ] E → Shield: violet shell for 2.5 s. Touch the coral (active) bumper while shielded: no kick, "Shield blocked it!", shell disappears.
- [ ] Pressing an ability during countdown, in the hub, after finishing → "Abilities work during a race", nothing happens.
- [ ] Pressing while cooling → "Cooling down".
- [ ] Trick ramp (green kicker, left half of the long straight): jump it and press SPACE / (A) / TRICK in the air → spin + stars, "TRICK! +15% speed", both ability timers drop by 1.5 s ("Cooldowns -1.5 s").
- [ ] Jump without pressing → no reward. Press SPACE on flat ground → "Can't trick here - use the TRICK RAMP". Press twice in one jump → "One trick per jump".
- [ ] Pass close to the bumper while yellow/coral without touching → "NEAR MISS!" once per pass.
- [ ] Three events within 3 s give only one cooldown reduction.
- [ ] Respawn (hold R) cancels an active Boost/Shield; a new race starts with both abilities READY.
- [ ] Reduced Motion ON (hub panel): no FOV change on Boost, no spin/stars on Trick.

**Two clients (Test tab, 2 players)**
- [ ] Equip Pulse on client A. Drive A within ~12 studs of B and press it: coral ring on both screens; B gets nudged sideways (bounded, no launch) and sees "PULSED!".
- [ ] B activates Shield first, then A pulses: B is not moved; both see the shield vanish; B sees "Shield blocked it!".
- [ ] Pulse twice quickly on the same target: second hit within 1.2 s is ignored (anti-chain).
- [ ] Drive B directly behind A within 12 studs for 1.5 s on a straight → B sees "SLIPSTREAM +12%" and faint streaks; overtake or drop back → it ends. Cooldown reduction only once per acquisition.
- [ ] Spamming Q/E/Space: no errors; server log shows no flood (rate limits are silent).
- [ ] 3 rounds in a row: no leftover trails, shells, streaks or speed buffs at the next GO.

## 7. A4 — Neon Foundry, hazards, bots, Chaos Gates

**Automated:** `A4 track validation specs`, `A4 hazard reset specs`, `A4 bot navigation specs`, `A4 chaos gate specs` (offline and in Studio, 0 failed). Studio integration adds: hazard visuals tagged and non-colliding, 32 tiles, A4 services published, hazard seed in the snapshot, bot marbles labelled, and a timeline line per transition with bots / bot marbles / hazard seed / instance count.

**Play Solo (you + 7 bots)**
- [ ] At Preparing the grid holds you + 7 coral marbles labelled `[BOT] <name>`; standings (Tab) show `[BOT]` in front of each. GO releases everyone at once.
- [ ] Walk the whole course once (ROUTE_MAP.md lists all 16 modules): trick ramp, big right sweep + S-turns, bumper field (3 bumpers with staggered timing), rotating sweeper (coral arm turns smoothly, kicks you on contact, never launches you off the course), split lane (outside safe / inside shortcut with a bumper), hairpin, fan tunnel (arrows + discs: cyan = pushing, yellow = about to, dark = calm), drop shaft, trampoline pad (mint, launches you up), falling tiles (yellow = about to drop, see-through = gone), swinging hammer, side conveyor, long sweep, funnel, final carve, finish.
- [ ] **Race time:** record 3 runs after one practice lap. Target 90–150 s. The 1-D model says ~64 s for a perfect run — if your real runs are under 90 s, tell me and I'll lengthen modules (pure data change).
- [ ] Each of the 3 hazard variations: rounds 1, 2, 3 use seed classes 1, 2, 0 (sweeper direction/speed, hammer timing, tile pattern, fan/conveyor direction change). Finish one race on each.
- [ ] Chaos Gates (violet/yellow half-lane arches at the S-turn, sweeper, trampoline, funnel): drive through one → "CHAOS GATE SURGE +x%" flash and a coloured shell; driving through again (back and forth) gives nothing more. Leading (top 3) = +8%, last half = +22% + short shield, middle = +14%.
- [ ] Shield then touch the sweeper / hammer / an active bumper → no kick, shield spent. The trampoline still launches you while shielded (it's a feature).
- [ ] Finish first → bots get up to 10 s more to finish, then Results. No human ever waits 180 s for bots.
- [ ] Cleanup: all bot marbles vanish; the hub never contains bots; the practice chute never has bots.
- [ ] Spectate (after you finish): Q / E cycles through bots too.
- [ ] F2 overlay: second line shows SERVER frame avg/p95, physics ms, moving parts, marbles (bots). Note the numbers with 1, 3 and 8 racers.

**Bot progression (owner, Studio)** — set `RaceConfig.Bots.FillTo` to 2, then 4, then 8 (= 1, 3, 7 bots with you):
- [ ] Bots finish most races, recover at their last checkpoint when they fall, never sit stuck for more than ~8 s (Output warns `[Bots] ... stuck 3x near route distance N` if a spot traps them — tell me the number).
- [ ] No bot is faster than a good human on straights (same motor, same caps).
- [ ] Server frame p95 with 8 racers: record it. If it's high, keep fewer bots (`FillTo`) and tell me — I won't call 8 bots done without your numbers.

**3 consecutive races (leak / reset check)**
- [ ] Timeline lines at each `Intermission`: `bots 0, bot marbles 0` and an `instances` number that does not grow round after round (small ±50 drift from UI is fine).
- [ ] Hazards restart from the same pose at every GO for the same seed class (watch the sweeper arm angle at GO in rounds 1 and 4).

**Two clients**
- [ ] Both clients see the sweeper arm, hammer and tiles in the same place at the same time (hazards are computed from the shared server clock, no per-frame network traffic).
- [ ] Two marbles side by side in the split lane (one inside, one outside) show placements that match who is actually ahead.
- [ ] A Chaos Gate collected by client A flashes a shell on A's marble on B's screen too.

## 8. A4 owner requests — free look and READY vote

**Automated:** `A4 ready vote specs` (offline and in Studio), `A4 free look specs (offline only)`:
the real CameraController against a fake camera — look right/left, held vs released, return after
1.5 s, pitch limits −10°..75°, reset on respawn, motor never reads the camera.

**Free look**
- [ ] Phone: steer with the left thumb and drag anywhere else (not on a button) with the right
      thumb → the camera orbits around the marble; the marble keeps going where you steer.
- [ ] Let go → about 1.5 s later the camera swings back behind the marble.
- [ ] PC: hold the right mouse button and move → same; release → same return.
- [ ] Drag up/down → the camera rises to almost overhead / drops to just below the marble, never flips.
- [ ] Respawn (fall or hold RESET) while looking → camera is behind the marble again.

**READY vote**
- [ ] Solo (or any race that isn't full): hub and HUD show `NEXT RACE` with
      "Waiting for players (n/16)" under it; no READY button; the timer runs as before.
- [ ] Full race (16 queued, or a test build with `RaceConfig.Ready.CapacityOverride`): READY
      button under SIT OUT shows `READY? r/N`; tapping it → `READY r/N` (mint); tapping again takes
      it back. When the last player taps READY the 3-2-1 starts at once.
- [ ] Someone leaves or sits out while the race is full → the button disappears and the message
      goes back to "Waiting for players".

## 9. A5 — UI flow, profile, Coins/XP, saving

**Automated:** `A5 persistence specs`, `A5 reward idempotence specs`, `A5 UI state specs` (0 failed). Offline also scans every client UI string for Robux / shop / capsule / season / buy prompts and the whole game for MarketplaceService (none). Studio integration checks the mock store, loaded profiles and that DevCommand exists only in Studio.

**Play Solo (Studio = MOCK profile: Output prints `[Profiles] Studio MOCK mode`)**
- [ ] Lobby (right column): LEVEL 1, XP bar "0 / 400 XP to level 2", "0 COINS - 0 races - 0 wins", "Studio test profile - not saved to Roblox". LOADOUT button shows "BOOST + SHIELD", SETTINGS opens the settings modal.
- [ ] LOADOUT: three cards with real stats; tap SLOT 1/SLOT 2 to equip; choosing the other slot's ability swaps. "Equipped - ready for your next race". Start a race → the modal closes by itself and can't be opened (toast explains). The equipped pair is what Q/E use.
- [ ] Settings: Reduced Motion ON → no FOV pulse on Boost, no trick spin/stars, no fan-disc spin, results card doesn't pop; CAMERA toggles Chase/Wide (CAM button also remembers it); STEERING SENSITIVITY 50% feels half as strong, 150% stronger; GRAPHICS LOW turns bloom and decorative trails off. Music/SFX levels show and stay (the build has no audio files - it says so).
- [ ] Race HUD: timer, placement badge top right ("2ND of 8"), checkpoint chip, progress bar with your mint dot, coral rival dots and violet checkpoint ticks; Tab standings; checkpoint flash.
- [ ] Hints: steer card at first roll, TRICK RAMP hint before the ramp, ABILITIES hint at the first GO - each skippable (OK) and shown once.
- [ ] Don't touch anything for a whole race (let the marble roll) → results say "No input detected this race - no reward".
- [ ] Finish a race → results: podium (3 marbles, [BOT] labels, times), your place/time, PB line ("FIRST TIME ON THIS HAZARD VARIATION" first, later "NEW PERSONAL BEST -x.xx s" or "+x.xx s"), the Coins/XP lines (Finished / Placement / Completion / PB / bot practice), totals counting up, level line, "Studio test profile - not saved to Roblox". The card pops in even if you're 8th.
- [ ] 1st of 8 = 200 Coins + 160 XP (+30 XP PB); 4th = 135; 8th = 110; DNF after checkpoint 1 = 25 Coins / 20 XP.
- [ ] Solo with bots: races 1-3 today say "Bot practice race N of 3 at full Coins today"; race 4 shows a "Coins x0.6" line and the note.
- [ ] PLAY AGAIN (primary) → back to the lobby queued; SIT OUT → lobby, not queued; Space / (A) = PLAY AGAIN.
- [ ] DEV PANEL (F8, Studio only): START NOW, END RACE, BOTS 0/3/7/AUTO, +500 MOCK COINS, RESET MOCK PROFILE, DIAGNOSTICS all work.

**Rejoin (Studio Test tab, 1 player + server)**
- [ ] Earn Coins, change settings and loadout, then leave the client (keep the server) and rejoin: level, Coins, PB, settings and loadout are back (the mock survives inside one server session).
- [ ] Leave during Results right after the reward appears, rejoin: Coins counted once.

**Live store (only in a throwaway test universe)** — publish, enable Studio API access, set `GameConfig.Persistence.StudioMode = "Live"`:
- [ ] Profile chip says "Progress saved to your account" after the first save; results say "Progress saved" only after the save completed.
- [ ] Join the same account from two devices/servers: the second waits ~12 s and takes over; the first stops saving and shows "You joined another server - this one stopped saving".
- [ ] Turn API access off and play: "Saved progress couldn't load - this session won't be saved"; the race still works.

**Layout**
- [ ] Studio Device Emulator at 640x360 (phone landscape) and 1920x1080: lobby column, results (980x560 reference) and modals fit; touch buttons ≥ 44 px; nothing under the Roblox top bar or chat. Console (gamepad) navigation of modals is NOT implemented beyond A/Space for PLAY AGAIN - noted.
- [ ] 3 races + a rejoin: `Perf_Instances` (F2) flat between Intermissions.
