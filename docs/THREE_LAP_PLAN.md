# Three-lap races and the in-race HUD — plan, baseline and status

Brief: `Tumble-Circuit-Three-Lap-Races-and-HUD-Master-Prompt.md` (owner, 2026-11-26).
Sector maps: `docs/CIRCUIT_MAPS.md` (generated from the live definitions).
Rollback: one flag, `TrackDefinitions.CircuitRaces = false` (the v2 single-run courses come back
and Volcano Vault returns to rotation; the single-run records were never touched).

## 1. Baseline (milestone 1) — what the build did before this brief

Taken from the source and from the owner's footage (`1000020846.mp4`, `1000020867.mp4`, the
countdown screenshot). Nothing below was measured on a device by me.

| Item | Before (v36) | Source |
| --- | --- | --- |
| Route | One-way descent, Neon Foundry 3,4xx studs, 8 checkpoints, catch basin at the end | `TrackDefinitions.NeonFoundry` (layout v2) |
| Race clock | 180 s hard cap, inherited by every map | `RaceConfig.Timers.MaxRaceSeconds` |
| Pace seen in footage | HUD read 41–71 "km/h" (raw studs/s) on the launch straight; CP 1 at ~16 s, CP 2 at ~26 s after GO | video frames |
| Progress | linear route distance; standings = confirmed checkpoints, then distance | `CheckpointService`, `ProgressService` |
| Recovery | last confirmed checkpoint + 6 studs; 1.5 s fall delay; hold-to-reset 1 s | `RoundService.ResolveSpawn`, `RaceConfig.Recovery` |
| Bots | follow the centreline by route distance; inside lane on splits when skilled | `BotService`, `BotBrain` |
| HUD problems in the footage | stacked `BOT` tags over the road at the grid; two "NEON FOUNDRY" titles + "Wait for GO" at the countdown; elapsed clock + "Race ends in" competing; world signs (camera-facing billboards) swelling over the screen; CAM/LIST/TRICK/RESET/BRAKE crowding one thumb zone; tutorial cards across the road | screenshots, video |
| Speed unit | studs/s labelled "KM/H" (1 stud ≈ 0.28 m makes them roughly equal, but it was never measured) | `PrototypeHUDController` |

## 2. What changed

### Courses
* **Neon Foundry circuit (layout v3)** — clockwise lap of 2,963 studs: wide launch straight + trick
  ramp → turbine bank → bumper field → passing straight → **split A** (inside: short-arm sweeper
  shortcut | outside: forward conveyor carry) → inspection hall drop + braked hairpin → alternating
  conveyor lines → passing straight → **split B** (left: walled safe rail | right: kicker + 6-stud
  gap, a signposted risk line) → hammer → **banked maintenance ascent** at 7.4° with a marked
  boost lane on the outside → final turn → main straight with the grid behind the line.
* **Sky Carnival circuit (layout v2)** — counter-clockwise, a different shape: float deck → balloon
  field → wind lane → left carousel → back leg with the **cloud gap** (inside: drum bounce over an
  8-stud gap | outside: bridge) → passing straight → sweep → **sky arc** (inside: two short kicker
  hops | outside: wide arc) → the **cloud drop** (12°, this map's big moment) → drum landing →
  **ribbon helix**: one and a half climbing left turns, stacked 70+ studs apart, with a lift lane
  on the outside, straight onto the main straight.
* Both close exactly (solved offline by `tools/offline/circuit_solver.lua` against the real
  generator; residual < 0.01 stud is spread over the last piece). The return legs are physical
  climbs — no lifts, no teleports, no padding. Throttle alone holds ~38 studs/s on the climbs; the
  boost lane ~41.
* **Volcano Vault is off rotation** while circuits are on (it has no validated circuit yet). The
  registry asks `TrackDefinitions.RaceReady`, so a vote can never pick it; it is not even built.
* Overhead **sign gantries** replace the camera-facing billboards (they leave the view as you pass).

### Race system (server-authoritative, same anti-skip rules)
* Progress is **race distance** = lap × lap length + lap distance (`RouteTracker` loop mode: the
  search window wraps the line; a new tracker starts on the right lap from a hint = the spawn's
  race distance). The grid is behind the line (negative race distance).
* The ordered **target list** (`TrackDefinitions.Targets`) = every lap's checkpoints, the line
  between laps ("Lap" events with lap times) and the finish after lap 3. `CheckpointService`
  judges it with the unchanged swept-crossing / corridor / plausibility rules, so: early or
  reversed line crossings, duplicate contacts, skipped gates and neighbouring-road crossings never
  count (all covered in `Circuits.spec`).
* Recovery = the last confirmed target's respawn transform (a lap line respawns just past it).
* Finishers roll on for 1.2 s, then move to a **finisher deck** beside the line (off the road).
* Race clock from the course: **480 s** cap (provisional, ~2.3× the model's clean race); after the
  leader finishes everyone else gets **90 s** (never more than was left). Both await phone
  slow-finisher data.
* Chaos gates can be collected once **per lap**; grapple anchors and bot steering use lap distance;
  bots take boost lanes and always the walled lane at a risk split.
* Records: the circuit layouts have their own versions (Foundry v3, Sky v2), so three-lap times
  and leaderboards are stored apart from the single-run ones. Time Trial on a circuit = **1 lap**
  (`RaceConfig.TimeTrialLaps`; a 3-lap trial gets its own `TimeTrial3L` key).

### In-race HUD
* Top strip: **LAP 2/3 · P3 / 8 · one clock** (elapsed). Under it: the current-lap progress stripe
  with real checkpoint ticks and rival dots, three **lap pips**, and `CP 4/10` at the right end.
  A coral **FINISH WITHIN 0:45** chip appears only when the leader's grace is running or under a
  minute is left.
* One callout lane: CHECKPOINT, **LAP 2 / 3 + lap time**, **FINAL LAP** (yellow), **WRONG WAY**
  (rolling back for 1.2 s), **MISSED CHECKPOINT · HOLD RESET** (60 studs past an unconfirmed gate).
* Countdown: one title (the course) + the number. No "Wait for GO", no world sign over the grid.
* Name tags: small fixed-pixel chips; hidden on the grid, closer than 16 studs, overlapping, or
  beyond the nearest three. Bots are named in the standings ("STANDINGS · 8 RACERS (5 BOTS)").
* Touch: driving actions stay under the right thumb (BRAKE, TRICK, BOOST, SHIELD); **RESET** is a
  small hold button above the steering stick with a fill that rises while held; **CAM / LIST** are
  two chips in the top-right corner. Left-handed mode mirrors all of it.
* Tutorial cards became small edge cues at the left (4.5 s, never over the road, not tappable).
* Speed reads **STUDS/S** until a km/h conversion is measured.

## 3. Verification

**Ran here (offline, Lua 5.3 against the real modules):** 874 checks, including `Circuits.spec`
(closure, targets, the crossing cases, tracker wrap + respawn hints, branch-equal progress at both
splits of both maps, stacked-helix progress, boost lanes, finisher deck, bots at risk splits,
name-tag declutter, case-opening pose), Luau compile + lint, place assembly + reference check,
both bootstraps' main chunks against proxy Roblox APIs.

**Not verified (needs a Roblox runtime / the owner's phone):** real lap and race times (the numbers
above are a 1-D model), whether the 6-stud and 8-stud gaps are jumpable at typical speeds, how the
hairpin and helix feel, bot completion rates, frame times, HUD fit at minimum/maximum HUD size on
a small phone, two-client races, late join and disconnect mid-lap.

## 4. Owner playtest (phone)

1. Queue for a race on Neon Foundry. Note the lap times shown at each LAP cue and your total.
2. Try both lanes at split A and split B once each; fall into the gap once on purpose and check you
   respawn at the Split B gate on the same lap.
3. Drive one lap the wrong way for a few seconds (WRONG WAY cue) and hold RESET.
4. Next race, vote Sky Carnival; try the drum bounce and the hops; ride the helix lift lane.
5. Send a screenshot of the countdown and one mid-race, plus a clip of a full lap.
