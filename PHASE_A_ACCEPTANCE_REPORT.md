# PHASE A ACCEPTANCE REPORT — Tumble Circuit: Chaos Drop

**Date:** 2026-11-22 · **Build:** A6.0 ("Phase A closed-playtest build")
**Environment where this was built and tested:** Linux container, no Roblox Studio, no Rojo, no
Luau toolchain, no devices, no network installs. Verification = `texlua tools/offline/run_tests.lua .`
(Lua 5.3 syntax check of 80 files written in the Lua-5.1 subset of Luau + 298 assertions on the
pure modules with a Roblox datatype shim) and an XML check of the generated place file.

**Bottom line: Phase A is code-complete but NOT playtested.** Nothing below has run inside the
Roblox engine. Every engine-side behaviour is "NOT TESTED" until the owner's Studio run. Phase B is
blocked until the owner personally playtests and approves (ADR-16). Do not treat this as release-ready.

Legend: **PASS (logic)** = the server/shared rule is verified by automated tests that actually ran;
the in-engine experience is still untested. **NOT TESTED** = needs Studio, two clients or devices.
No item is marked PASS for the engine.

| # | A6 exit criterion | Result | Evidence / method | Open blockers |
|---|---|---|---|---|
| 1 | New user rolls promptly and can finish/replay with only 3 contextual hints | **NOT TESTED** | Title → PLAY → hub roll is immediate by design; hints: steer card, TRICK RAMP, ABILITIES (skippable, once). UIState.spec covers screen flow for every round state. | Owner Play Solo (TEST_PLAN §3, §8) |
| 2 | 8 labelled bots populate a solo race where profiling allows; fair finish; 2 humans agree on results | **PASS (logic) / NOT TESTED in engine** | Bot fill rule (0→0, 1→7, 7→1, 8+→0), same motor/abilities/judging as humans, `[BOT]` labels, never in hub, despawn at Cleanup (ChaosGate.spec, BotNavigation.spec kinematic lane model: stays on course, avoids divider). Results are server-computed, so both clients receive the same list. | Studio: 1 / 3 / 8 bot progression, server p95 (TEST_PLAN §7). Physics navigation unproven. |
| 3 | Full Neon Foundry base + 2 hazard permutations reachable within target time | **PASS (logic) / NOT TESTED** | TrackValidator 0 errors; 16 modules with continuous ports; tile pattern passable and hammer inside the lane for all 3 seed classes; ribbon never self-intersects (TrackValidation.spec, HazardReset.spec). | **Race time unproven:** the 1-D model gives ~64 s for a perfect run; target is 90–150 s for a practised player. Measure 3 runs per variation in Studio. |
| 4 | Boost/Shield/Pulse, Trick, Draft, Cooldown Charge, Gate surge, recovery across 3 consecutive rounds | **PASS (logic) / NOT TESTED** | Ability.spec, MicroSkill.spec, AbilitySecurity.spec, ChaosGate.spec, RoundState.spec (checkpoint respawn). | Studio 3-round run (TEST_PLAN §6, §7). |
| 5 | Spectator votes modify real compatible hazards, affect only active racers, require server-validated votes | **PASS (logic) / NOT TESTED** | Social.spec: eligibility, one vote per poll, stale/closed/bad votes, ties, no-vote, modifier window, bounded effects (fans 42 < steering 70; bumper kick 30 = cap). Modifier changes only fan push and bumper kicks, from shared timestamps, on server (bots) and owners' clients. | 2-client Studio test (TEST_PLAN §9). |
| 6 | Coins/XP/PB/loadout/settings persist across rejoin, or explicitly UNTESTED in live storage | **PASS (logic, mock store) / live DataStore UNTESTED** | Persistence.spec + RewardIdempotence.spec over the in-memory backend: session lock, takeover refusal, bounded retries, honest Unsaved/Unavailable, leave-at-results → rejoin pays once. | Live DataStore only in a throwaway test universe (TEST_PLAN §8). BindToClose timing untested. |
| 7 | Reduced motion / colour-blind cues / graphics quality on different viewports; no unreachable controls | **NOT TESTED** | Implemented: Reduced Motion (FOV pulse, spin, fan spin, card pop, confetti off), text/material cues, Low graphics (bloom + decorative VFX off), right-column lobby layout, gamepad focus on menus. UIState.spec checks modal rules and no dead buttons. | Device Emulator 640x360 / 1280x720 / 1920x1080, console, touch. |
| 8 | No known exploit lets a client award money, teleport to finish, repeat gate pickup or reset cooldowns | **PASS (logic)** with one known limitation | No remote grants/sets Coins, XP, times, PBs, placement or cooldowns (AbilitySecurity/UIState scans). Finish/checkpoints need server-observed continuous crossings with plausible splits; 1 s teleport audit; gates pay once per gate per round; rewards once per raceId (ledger). | Limitation (client ownership): a modified client can ignore hazard kicks or Pulse nudges on its own marble; impossible movement is still rejected. |
| 9 | BUILD_STATUS gives measured performance or transparent UNTESTED with instructions | **PASS (transparency)** | No performance number is claimed. PerfService publishes server frame avg/p95, physics step, moving parts, instances, memory, marbles, bots; F2 overlay shows them with client FPS. Instructions in TEST_PLAN §3G, §7, §9. | All numbers pending owner measurement. |

## Addendum 2026-11-25 — what has now run in Roblox (owner's phone, private experience)

The owner does not use Studio; every build is built by Rojo in GitHub Actions and published to a
private experience, then played in the Roblox Android app. Played and approved by the owner:
A1 (movement, camera — after a turn-smoothing fix), A2 (rounds — after the GO, results and
join/sit-out fixes), A3 (abilities — after a server start-up deadlock fix), A4 (Foundry, bots —
after the bots-stuck-at-GO fix, plus owner-requested free look and READY vote), A5 (UI, Coins/XP,
saving to the live DataStore). A6 itself: **not yet played**. Still untested anywhere: two human
players (votes, emotes, bumps, results agreement), console, measured race times, rejoin
persistence beyond the owner's own sessions. See BUILD_STATUS test ledger for each run.

## What the owner should do next (in order)
1. Open `TumbleCircuit.rbxlx` in Studio → Play. In Output, every `[TumbleTests] ===== ... failed =====` line should say `0 failed`; send me any red error with file and line.
2. Play Solo through TEST_PLAN §3 → §9 (about 30–40 min). Note real race times on the Foundry.
3. Test tab → 2 players: rounds, spectate, vote, emotes, results agreement (§5, §9).
4. Optional: throwaway test universe with Studio API access + `StudioMode = "Live"` for the save tests (§8).
5. Reply with: crashes / errors, race times, bot behaviour, F2 numbers with 8 racers, anything confusing.

## Known open issues (honest list)
- Never run in the engine: expect first-run fixes (typos the Lua 5.3 parser cannot catch, Roblox API details).
- Race length may be short of the 90–150 s target (pure data change once measured).
- Bot physics navigation is only modelled kinematically; real bots may get stuck somewhere (they recover; Output names the spot).
- Console modal navigation relies on Roblox's default selection traversal; not verified.
- No audio (no licensed sound ids exist); volume settings are stored for later.
- Server Authority (Roblox) was not adopted; client ownership trade-offs are documented in BUILD_STATUS.

## Packaging
Source + Rojo map (`default.project.json`) + generated `TumbleCircuit.rbxlx` (built by
`tools/build_rbxlx.py`, the no-Rojo installer alternative; XML verified well-formed, NOT opened in
Studio here).
