# BUILD_STATUS — Tumble Circuit: Chaos Drop

**Active milestone:** A1 — "The marble must feel great"
**State:** source complete · offline-verified (pure logic only) · **awaiting first Studio Play Solo
by the owner** · A2 not started (stop gate).
**Last updated:** 2026-11-23 (mobile playtest pipeline added — see next section)

Legend: **Done** = implemented and verified by a test that actually ran · **Implemented,
untested** = code exists, needs Roblox Studio to verify · **Not measured** = needs a device /
profiler · **Out of scope** = later milestone, intentionally absent (no stubs).

## 2026-11-23 — mobile playtest pipeline (no Studio)

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

## Build environment (inspected 2026-11-19)

| Tool | Available? | Notes |
|---|---|---|
| Roblox Studio | **No** | Linux container. No Play Solo, no engine, no profiler. |
| Rojo | **No** | Not installed; package installs blocked (no network for installs). `default.project.json` written for Rojo 7; `tools/build_rbxlx.py` builds the place instead. |
| Luau / luau-analyze / selene / StyLua | **No** | Code written in the Lua 5.1 subset of Luau so it parses under the available Lua. No Luau type checking was possible, so files are non-strict (no `--!strict`). |
| Lua 5.3 (`texlua`, LuaTeX 1.17) | Yes | Used for syntax checks + pure-module tests with a Roblox datatype shim. |
| Python 3.13 | Yes | Place builder + XML validation. |
| Git | Yes | Not used for commits (none requested). |
| Roblox API docs (web) | Yes | Checked: Server Authority (full release, requirements), Input Action System, `WorldRoot:Spherecast`. |

## A1 decisions

| ID | Decision | Why |
|---|---|---|
| ADR-02 authority | **Client network ownership** of the marble (`SetNetworkOwner(player)`); server creates/spawns/resets, times runs, logs speed anomalies. | Server Authority is in full release (needs `AuthorityMode=Server`, StreamingEnabled, NextGenerationReplication, Deferred signals, Input Action System + `RunService:BindToSimulation`; prediction centres on the Character, which this game does not have). None of it could be tested here; A1 validates *feel*, where zero-latency local physics is the proven baseline. **Revisit in A2** with the two-client authority test. |
| ADR-05 lifecycle | No Character / Humanoid (`CharacterAutoLoads=false`, stray characters destroyed). One `Ball` part r=2 per player, named `Marble_<UserId>`, attribute `OwnerUserId`. Visual stripes welded, massless, collision/query/touch off. Every spawn = new ball at the server spawn; old ball destroyed. Reset = server request with no payload, rate-limited 0.75 s. Fall (below course − 40) → respawn after 1.0 s. Unexpected removal → respawn. Leave → ball destroyed, state dropped. | Single code path for join/reset/fall/try-again/rejoin; no second collider; no CFrame writes to a client-owned body; no client-chosen positions. |
| Input | `UserInputService` polling + one explicit touch stick; default touch controls disabled (`GuiService.TouchControlsEnabled=false` + `PlayerModule:GetControls():Disable()`). | Input Action System could not be verified; polling is deterministic and drops nothing on focus changes. Revisit if Server Authority is adopted (it requires IAS). |
| Steering frame | Route tangent, gravity-projected, 4 studs ahead, exponentially smoothed. Lateral steering is a one-sided velocity target (cap 22); forward thrust tapers at 44 studs/s. | Cannot flip when the camera pitches into a drop. |
| Motor | One world-space `VectorForce` at the centre of mass, set every frame; engine integrates at its own rate; no dt clamping; ×1.4 inertia compensation while grounded so configured accelerations are what the rolling sphere gets. | Spec: forces, no per-frame CFrame, no `math.min(dt,1/30)`. |
| Speed envelope | Rolling resistance 3 + linear drag 0.2/s + smooth terminal drag above 80. | Offline model without them showed every slope saturating at 80 (11 s run). Hypothesis — tune by feel. |
| Camera | Scriptable, heading from route, pitch adds 85 % of the drop angle ahead (cap 58°), world-up, raycast zoom (ignores rails/decor/hazards/marbles), exponential smoothing, snap on respawn, FOV 70, Chase 20 / Wide 26. | Spec camera contract. |
| Course | 6 segments, 17 pieces, 947-stud route: start pad (practice + spawn) → straight ramp → banked S-turn → widened bumper lane → 90° banked drop (to 20°) → run-out, finish, uphill basin with end wall. Floor = ribbon of boxes (flat) and WedgePart triangle pairs (curved/banked). 701 parts, 438 collidable. | Spec item 7. |
| Hazard | One Pulse Bumper: cyan idle bounce → 0.8 s cyan→yellow ramp (no flashing) → coral active kick (24 studs/s outward, capped, 0.5 s cooldown). Phase = function of server time. Yellow floor chevrons + sign before it. | "One gentle bumper" + "one hazard telegraph". |

## A1 ledger

### Done (verified by tests that ran here)
- [x] Project layout, Rojo map, place file; all 23 scripts embedded byte-identical (`build_rbxlx.py` + XML check)
- [x] Config ranges & spec hypotheses (accel 35, lateral 22, terminal 80, air 40 %, brake ×0.65, deadzone 0.12, camera 18–26, FOV 70, hold 1 s)
- [x] Frame-rate-independent smoothing (exact exponential), controller gains stable to 15 FPS (k·dt < 1)
- [x] Course generator deterministic; validator: 6 segments, continuity of pitch/bank/width, lane ≥ 4 ball widths, rails ≥ 1 diameter, ordered start/marks/finish, run-off, no self-overlap, min height
- [x] Floor geometry: every wedge/box top face lies exactly on the track ribbon, slabs hang below (mutation-tested: two deliberate geometry bugs were both caught); wedge construction matches EgoMoose's known-good formula
- [x] Steering frame defined along the whole route; never jumps > 10° per 2 studs (no flip in the drop)
- [x] Route tracker: monotonic progress along the course, re-acquire after respawn jump
- [x] Spawn on the practice pad with floor clearance; camera sight line clears the back wall (Chase 2.5 studs, Wide 4.1 studs)
- [x] Hazard cycle Idle → Telegraph (0.8 s) → Active → Idle
- [x] No invented asset ids; exactly one remote; attribute names valid
- [x] Every file parses (Lua 5.3 parser over Lua-5.1-subset Luau; Lua-5.3-only syntax scan clean)

### Implemented, untested (needs Studio Play Solo — see TEST_PLAN.md)
- [ ] Server boot, course build, lighting; Studio TestRunner integration checks
- [ ] Marble spawn, network ownership, single collider, stripes visible & rolling
- [ ] Steering/brake/thrust feel; rolling resistance & drag values; bumper bounce & kick
- [ ] Ground detection via `Spherecast` on wedges and banks
- [ ] Camera follow, drop pitch adaptation, obstruction zoom, Chase/Wide, snap on respawn
- [ ] Reset (R / Y / RESET / mouse hold / Roblox menu), fall respawn, Try Again, rejoin
- [ ] Practice timer start/finish, marks, session best, Finish! overlay
- [ ] Title / tutorial / HUD / toasts, device hint switching, UI scaling
- [ ] Touch stick + BRAKE / RESET / CAM on a phone (or Studio device emulator); no double stick
- [ ] Gamepad LT / Y / R3 / A
- [ ] Default-controls disabling (`GuiService.TouchControlsEnabled`, PlayerModule) — both wrapped in pcall
- [ ] WedgePart seams: possible small bumps where triangles meet at speed

### Not measured
- [ ] FPS / frame time: **no measurement exists.** The F2 overlay (avg + p95 over 240 frames) and Studio MicroProfiler procedure are in TEST_PLAN.md.
- [ ] Clean-run time: a 1-D model (full throttle, no braking) estimates ~18 s; real first attempts unknown. Spec target 35–75 s on first attempts — **likely short**; length is one table in `TrackDefinitions.lua`.

### Out of scope for A1 (no code, no stubs)
Rounds/countdown, multiplayer race flow, checkpoints beyond the two run marks, bots, abilities,
tricks, slipstream, persistence, coins, XP, cosmetics, shop, lobby, spectating.

## Known issues / risks (honest list)
1. **Never run in Studio.** Expect at least one runtime error on first Play; Output will show it.
2. Course may be too short for the 35–75 s target (see "Not measured").
3. Drag 0.2/s + rolling resistance 3 are guesses chosen from a model; the marble may feel "sticky" or still too fast.
4. Lateral assist (1.0/s) gently aligns velocity with the track when not steering; may feel like auto-steer. Set `LateralAssistDamping = 0` to compare.
5. WedgePart seams on curves/banks could cause small hops at high speed.
6. `UserInputService.PreferredInput` is read via pcall and its enum names are matched by text ("Touch"/"Gamepad"); falls back to last input type.
7. Touch stick coordinate mapping assumes `InputObject.Position` and `AbsolutePosition` share a space (documented behaviour; unverified on device).
8. The Pulse Bumper kick and all steering forces are client-applied (client ownership). Fine for solo practice; see A2 notes.
9. Studio TestRunner prints one expected warning ("deliberate test error") from the signal-isolation test.

## A2 security notes (carry forward, not implemented)
- With client ownership, a modified client can move its marble arbitrarily. A2 must validate on
  the server: ordered checkpoints with min travel time, speed envelope (already logged), path
  plausibility between checkpoints, and reject suspicious finishes/rewards — or adopt Server
  Authority and move the motor into `BindToSimulation`.
- Keep remotes payload-free or strictly typed; RequestReset already reads no payload.

## Test ledger

| Date | Command / action | Environment | Result |
|---|---|---|---|
| 2026-11-19 | `texlua tools/offline/run_tests.lua .` | Linux, LuaTeX 1.17 (Lua 5.3) + shim | 26 files parse; **57 passed, 0 failed** |
| 2026-11-19 | Mutation: slab above surface / mirrored wedge centre | same | both caught by the floor-geometry spec |
| 2026-11-19 | `python3 tools/build_rbxlx.py . TumbleCircuit.rbxlx` + XML parse + source diff | Python 3.13 | well-formed; 23/23 scripts identical; service properties present |
| 2026-11-19 | Camera line-of-sight over start wall (offline calc) | texlua | Chase +2.46, Wide +4.11 studs clearance |
| — | Studio Play Solo / TestRunner | **not available** | **pending owner** |
| — | FPS 30/60/120, low-FPS | **not available** | pending (mobile device: see 2026-11-23 playtest row) |
| 2026-11-23 | `python3 tools/luau_check.py src PLACEHOLDER_IDS.lua` | Linux, Python 3.13 | 23 files: 0 errors, 0 warnings; injected typos caught |
| 2026-11-23 | Offline place build (Rojo-compatible) + `tests/verify_place.py` | Python 3.13 | 35 instances, 23 scripts, all references resolve |
| 2026-11-23 | `python3 tests/test_publish.py` | Python 3.13 | 10 passed, 0 failed |
| 2026-11-23 | GitHub Actions **Build** run 45146791501 (`rojo build`, Selene 0.32.0, Lune 0.10.5, Lua 5.3 specs) | GitHub cloud, ubuntu-latest | **success**: 57 specs passed; Selene 0 errors / 6 style warnings; Rojo built .rbxl (80 KB) + .rbxlx; Lune: 35 instances, 23 scripts, all references resolve |
| 2026-11-23 | GitHub Actions **Deploy** run 45160813071 (`scripts/publish.py`, Open Cloud Assets API) | GitHub cloud | **success**: version 4 published; privacy guard read visibility PRIVATE |
| 2026-11-23 | First real runtime playtest of A1 (owner) | Samsung Galaxy S25 Ultra, private experience | **owner reports it works well** (no detailed checklist results recorded yet) |
| — | Detailed A1 checklist (docs/ANDROID_PLAYTEST.md), FPS 30/60/120, Studio TestRunner | — | pending |

