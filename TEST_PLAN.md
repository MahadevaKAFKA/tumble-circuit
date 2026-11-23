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
