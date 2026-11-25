# BUILD_STATUS — Tumble Circuit: Chaos Drop

**Active milestone:** A2 approved on the owner's phone (2026-11-25); A3 waiting for its spec/source
**State:** A1 played on the owner's phone (2026-11-23): **go** on every A1 question. A2 source merged
with the phone fixes, offline-verified (92 specs), built by Rojo in GitHub Actions and published
privately — **A2 has not been played in Roblox yet** (first runtime test = owner's next phone session).
**Last updated:** 2026-11-23

Legend: **Done** = implemented and verified by a test that actually ran · **Implemented,
untested** = needs a Roblox runtime · **Blocked** = needs something not available here.

## 2026-11-23 — A2 merged onto the phone build

A2 (written 2026-11-21 against the original A1 source) was three-way merged with the A1 phone
changes made since (base = original A1 upload). Clean merge except four regions in
`ClientBootstrap` and two in `PrototypeHUDController`, resolved by keeping both sides:
- kept from the phone build: TouchStarted → touch layout; wait for `CurrentCamera`; chord-smoothed
  camera heading and steering frame (`RouteTracker.SmoothHorizontalTangentAtS`; the steering frame
  now uses the current zone's route — hub chute or race course); stats overlay + hitch log (hitch
  label is now `@<zone>/<piece>`).
- kept from A2: zones, spectating, stuck hint, board updates, round/race UI, everything server-side.
- one small addition for phones: a **LIST** touch button (above RESET) toggles A2's standings list,
  which otherwise needs Tab / D-pad up.
- `tests/place_expectations.json` updated for A2's 34 scripts; every new runtime-created name
  (`RoundSnapshot`, `CheckpointFeedback`, `FinishNotice`, `Gates`, `StartGate`, `OrbitalGarage`,
  `PracticeChute`, `TrainingCourse`, `Board`, `NextRaceBoard`, `BoardMain`, `BoardSub`) was checked
  to be created by server code before being whitelisted.

## 2026-11-23 — mobile playtest pipeline (no Studio, A1)

Goal: play A1 on an Android phone without installing Studio or tools on the PC.

**Added (no gameplay changes):**
- GitHub Actions **Build** workflow: Luau static checks → the A1 pure specs (this harness, Lua 5.3)
  → Selene lint → `rojo build` (.rbxl + .rbxlx) → Lune verification of the built place → artifact.
- GitHub Actions **Deploy** workflow (manual): Open Cloud publish to the owner's existing
  experience, polls the operation until Roblox confirms, refuses PUBLIC experiences unless
  `allow_public` is ticked. Secrets only in GitHub (`ROBLOX_API_KEY`; IDs as variables).
- `tools/luau_check.py` — offline Luau parser + scope checker (unknown/accidental globals, unused
  locals, `Module.field` and `XConfig.Section.Key` references). Clean on all 23 scripts;
  mutation-tested on this code (3 injected typos + 1 unused local all reported).
- `tests/verify_place.py` / `.luau` — built place has every expected instance/class/property and
  every `WaitForChild`/`FindFirstChild` target exists in the place or is created at runtime.
- `scripts/publish.py` + `tests/test_publish.py` (10 scenarios against a fake Open Cloud).
- Docs: `docs/SETUP.md`, `docs/ANDROID_PLAYTEST.md`.

**Two small client changes (mobile hardening):**
1. `InputController`: any `TouchStarted` switches the device to Touch. Before, touch controls only
   appeared if `UserInputService.PreferredInput` reported Touch; a misreport (possible in the Web
   Play beta) would have left a phone with no stick.
2. `ClientBootstrap`: waits for `workspace.CurrentCamera` before creating TouchControls/HUD
   (both read it in their constructors).

**Review:** all 23 scripts read in full. No runtime errors found by inspection; the risks listed
below ("Known issues") still stand. A1 scope is unchanged: no checkpoints beyond the two run
marks, no abilities, no jump — falls and RESET return to the start pad by design.

## Build environment (inspected 2026-11-19 / 2026-11-21)
| Tool | Available? | Notes |
|---|---|---|
| Roblox Studio | **No** | Linux container: no Play Solo, no multi-client Test, no profiler. |
| Rojo | **In CI** | Rojo 7.7.1 in GitHub Actions builds the published place (local container still has none). |
| Luau / selene | **Selene in CI** | Selene 0.32 + Lune 0.10.5 run in GitHub Actions; locally `tools/luau_check.py` (parser + scope/reference checks). |
| Lua 5.3 (`texlua`) | Yes | Syntax checks + pure-module tests with a Roblox datatype shim. |
| Python 3 | Yes | Place builder + XML validation. |

## Decisions
| ID | Decision |
|---|---|
| ADR-02 authority | Client network ownership of the marble; server spawns, freezes/releases, judges checkpoints/finish/placement from **observed** positions, audits movement. Server Authority (fully released 2026) still untried: needs IAS + `BindToSimulation` + Streaming; revisit when a Studio 2-client test exists. |
| ADR-05 lifecycle | No Character/Humanoid. One Ball (r=2) per player; every spawn = fresh ball at a **server-resolved** spot (hub ring / frozen grid / last checkpoint / finish basin). `Zone` attribute on the ball tells the client which route to use. |
| A2 rounds | RoundService state machine with an explicit transition graph (RoundProtocol), os.clock deadlines, server-time timestamps in every snapshot. Everyone autoqueued; RequestJoinRace(bool) = sit out / play again. One human is enough to race. |
| A2 start | Racers respawned **anchored** on a shuffled 4x4 grid (Park-Miller seed = roundId); GO unanchors, hands ownership, opens a physical coral gate. Recovery refused during Preparing/Countdown. |
| A2 judging | CheckpointService: crossing must be a continuous sweep inside one 20 Hz sample (jump ≤ envelope), inside the corridor, with a plausible split (≤ 80 × 1.35 studs/s). Time interpolated inside the sample; same-sample finishes ordered by time then join ordinal. Standings: finish order → checkpoint → distance capped at the next checkpoint → DNF → ordinal. |
| A2 audit | 1 s sliding-window teleport check (moved ≤ 80 × 1.35 × t + 15). Violation: logged + marble returned to last checkpoint. No bans. |
| A2 collisions | Collision groups TC_Marble / TC_Protected; 2 s ghost after every spawn and after GO. Client bump limiter: one-frame Δv from a marble contact capped at 45 (18 for 1.2 s after a big bump) via counter-impulse. |
| A2 hub | Orbital Garage minimal: round glass platform, rim, board (client-rendered text), podium blocks, 16 spawn spots, Practice Chute (174 studs) that loops back to the hub. |
| Protocol | Remotes: RequestSnapshot, RequestRecover, RequestJoinRace(boolean) [client→server, schema-checked, rate-limited]; RoundSnapshot, CheckpointFeedback, FinishNotice [server→client]. No client-sent checkpoint/time/position remote exists. |

## Ledger
### Done (verified by tests that ran here)
- [x] A1: config ranges, smoothing, course generator/validator, floor geometry exactness (mutation-tested), steering-frame stability, route tracking, spawn clearance, hazard cycle, no invented ids
- [x] A2: transition graph (reachable, no dead ends, legal full cycle, no shortcuts to Racing)
- [x] A2: payload validation accepts only exact schemas; every client remote rate limited; no Set* remotes
- [x] A2: standings order incl. DNF and ordinal ties; near-simultaneous finish ordering; crossing interpolation
- [x] A2: grid shuffle deterministic permutation, varies per round; 16 grid slots validated (spacing, rails, behind gate)
- [x] A2: checkpoint judging with simulated samples — ordered CP1→CP3→finish, interpolated finish time, teleport jump rejected, corridor rejected, impossible split rejected, respawn never crosses, progress capped
- [x] A2: hub spawns spaced/inside rim, chute flush with hub edge, rim gap open, chute validates
- [x] 37 files parse; place file well-formed (rebuilt each milestone)

### Implemented, untested (needs Studio — TEST_PLAN sections 3 and 5)
- [ ] Everything engine-side from A1 (feel, camera, devices, UI)
- [ ] Round loop timing, snapshots on both clients, late joiner sync, 3 consecutive rounds
- [ ] Grid freeze/release, gate toggle, protection ghosting, marble bumps + limiter
- [ ] Checkpoint flashes, placement badge, standings, results, DNF, disconnect handling, spectate cycling
- [ ] Practice chute loop, hub board text

### Blocked
- [ ] **2-client network verification** — no Studio here. Steps + expected log order: TEST_PLAN §5.
- [ ] FPS/frame time — no device. F2 overlay + MicroProfiler procedure in TEST_PLAN §3G.

## Known risks
1. Never run in Studio; expect first-run errors (Output will name file and line).
2. Client-owned marbles colliding is resolved per-client; bumps may look asymmetric under latency.
3. Course likely short for the 35–75 s target (1-D model ~18 s perfect run).
4. A cheating client can still drive its own marble anywhere physically plausible (that is the ownership trade-off); impossible movement is rejected and logged.
5. Same-sample finish ordering assumes Heartbeat samples; extreme server hitches coarsen timing.

## Test ledger
| Date | Command | Result |
|---|---|---|
| 2026-11-19 | `texlua tools/offline/run_tests.lua .` (A1) | 26 files parse; 57 passed |
| 2026-11-21 | `texlua tools/offline/run_tests.lua .` (A1+A2) | 37 files parse; **83 passed, 0 failed** (A1 56 + A2 27) |
| 2026-11-21 | `python3 tools/build_rbxlx.py . TumbleCircuit.rbxlx` + XML parse | well-formed |
| 2026-11-23 | `python3 tools/luau_check.py src PLACEHOLDER_IDS.lua` (Linux, Python 3.13) | 23 files: 0 errors, 0 warnings; injected typos caught |
| 2026-11-23 | Offline place build (Rojo-compatible) + `tests/verify_place.py` (Python 3.13) | 35 instances, 23 scripts, all references resolve |
| 2026-11-23 | `python3 tests/test_publish.py` (Python 3.13) | 10 passed, 0 failed |
| 2026-11-23 | GitHub Actions **Build** run 45146791501 (`rojo build`, Selene 0.32.0, Lune 0.10.5, Lua 5.3 specs) (GitHub cloud, ubuntu-latest) | **success**: 57 specs passed; Selene 0 errors / 6 style warnings; Rojo built .rbxl (80 KB) + .rbxlx; Lune: 35 instances, 23 scripts, all references resolve |
| 2026-11-23 | GitHub Actions **Deploy** run 45160813071 (`scripts/publish.py`, Open Cloud Assets API) (GitHub cloud) | **success**: version 4 published; privacy guard read visibility PRIVATE |
| 2026-11-23 | First real runtime playtest of A1 (owner) (Samsung Galaxy S25 Ultra, private experience) | **owner reports it works well** (no detailed checklist results recorded yet) |
| 2026-11-23 | Owner feedback: turns "jump"/stutter, marble feels like it has corners → camera heading and steering frame now follow a chord-smoothed route tangent (±10 studs) instead of the 5°-per-vertex polyline (`RouteTracker.SmoothHorizontalTangentAtS`, `GameConfig.Camera.HeadingSmoothingStuds`, `PhysicsConfig.Movement.SteerFrameSmoothingStuds`) (texlua offline specs) | **66 passed**; simulated camera turn-rate kick at 35 studs/s, 60 fps: 1.31 °/s per frame (was 19.69); setting smoothing to 0 makes 3 new specs fail |
| 2026-11-23 | Owner playtest of v5: camera turns now fine; lag at the first S-bend, then a 1–2 s whole-screen freeze at the next bend (same run, Roblox Android app). No cause found by code review (no runtime loops, no sliver floor wedges: thinnest wedge leg 0.79 studs). Added a hitch logger (frames ≥ 0.25 s logged with course piece + run number to the overlay and the dev console) and turned the frame-time overlay on by default for private playtests (texlua offline specs, luau_check) | 66 passed; 0 lint errors. Cause **not yet known** — waiting for overlay readings |
| 2026-11-23 | Deploys v5 (smoothing) and v6 (stats box + hitch log), runs 45162969643 / 45170849945 | **success**, visibility PRIVATE both times |
| 2026-11-23 | Owner, several more runs on v6 | **no freeze again**; treated as a one-off (phone or first-time graphics setup). Stats box stays on for playtests |
| 2026-11-23 | A2 three-way merge + `luau_check` (34 files) + `texlua tools/offline/run_tests.lua .` | 0 errors, 1 warning (unused local `tangent` in HubBuilder, harmless); **92 passed, 0 failed** (A1 65 + A2 27) |
| 2026-11-23 | Offline place build + `tests/verify_place.py` (A2) | 48 instances, 34 scripts, all references resolve |
| 2026-11-23 | Smoothed heading on the A2 practice chute (offline) | defined everywhere; worst 0.92°/stud |
| 2026-11-23 | GitHub Actions **Deploy** run 45173389534 (A2 commit 84d195d: Rojo build, Selene, Lune, 92 specs, publish) | **success**: Selene 0 errors / 19 style warnings (shadowing, `_G` in tests, UDim2 style); Lune: 48 instances, 34 scripts, all references resolve; **version 7** published, visibility PRIVATE |
| 2026-11-23 | **A2 first phone playtest** (owner, v7, Roblox Android app): (1) after GO the marble could not move until a manual reset; (2) results screen: tapping the button did nothing visible until the round moved everyone to the hub; (3) in the hub the player was "sitting out", told to "press JOIN" (no such button) and no race started. | Diagnosis by code reading: (1) GO unanchored the grid ball in place; a reset (fresh, never-anchored ball on the same slot) worked → GO now takes the reset path (`MarbleCharacterService:Release` respawns, reason `Go`; checkpoint records begin first). Root cause of the stuck anchored ball not confirmed in a runtime. (2)+(3) the queue chip showed the current state ("IN NEXT RACE"), so tapping it sat the player out; results PLAY AGAIN gave no feedback → queue button now names its action (SIT OUT / JOIN RACE), updates instantly, toasts; results buttons close the panel; hint says JOIN RACE. 92 specs pass, 0 lint errors |
| 2026-11-25 | A2 phone re-test of v8 (owner, Roblox Android app) | **owner: "everything is going smoothly"** — marble moves at GO, join/sit-out and results work; A2 approved, go to A3 |
| — | 2-client network verification | **pending** (needs a second account) |
