# BUILD_STATUS — Tumble Circuit: Chaos Drop

**Active milestone:** A6 — Phase A closing build (spectator Chaos Vote, quick emotes, hub podium
and decor, accessibility cues). Phase B not started (needs the owner's Phase A approval).
**State:** A1–A5 played on the owner's phone (Roblox Android app) and approved; bots fixed. A6
source (written 2026-11-22) merged with the phone build, offline-verified (332 specs), built by
Rojo in GitHub Actions and published privately — **A6 has not been played in Roblox yet**.
**Last updated:** 2026-11-25

Legend: **Done** = implemented and verified by a test that actually ran · **Implemented,
untested** = needs a Roblox runtime · **Blocked** = needs something not available here.

## 2026-11-25 — A6 merged onto the phone build

Three-way merge (base = A5 upload). One conflict (`GameConfig.Debug`: kept the phone stats box on
and the hitch threshold, added A6's `SoakMinutes`). A6's BotService change (bumper kick × the
Chaos Vote multiplier) merged cleanly into our fixed bot loop. Checked: A6's new server code has no
start-up waits; every new remote is created from RoundProtocol; the vote panel (top centre, during
races), emote bar (right column) and our READY button (lobby, intermission) do not overlap; the
hub podium marbles are decor, not in the marbles folder.

## 2026-11-25 — A5 merged onto the phone build

Three-way merge (base = A4 upload). Conflicts and how they were resolved:
- `RoundProtocol` / `RoundService` / TestRunner / offline runner / TEST_PLAN: kept both sides
  (RequestReady + A5's RequestSettings, ReportActive, ProfileState, RewardNotice, Dev remotes).
- `AbilitySecurity.spec`: A5's ranged-number rule inside our Selene-clean single condition.
- `MatchUIController`: A5 rebuilt it as the lobby/spectate layer (results moved to
  `ResultsController`, which also closes on PLAY AGAIN / SIT OUT — our dismiss code dropped). Our
  changes re-applied on A5's layout: queue button names its action (A5 had brought back the
  IN NEXT RACE / SITTING OUT state label that confused the owner on 2026-11-23), instant tap
  feedback, READY button on the same row left of it, "Waiting for players (n/16)" on the board.
- `AbilityController`: our phone override that moved the hub loadout panel to the upper left was
  removed — A5 moved it to the right column, clear of the stick.
- Results: PLAY AGAIN always says PLAY AGAIN; DNF on the podium shows the checkpoint reached
  (`DNF CP 3/8`) so a playtest shows how far bots got.
Found while merging: the client waited for Studio-only remotes with
`spec.StudioOnly and FindFirstChild(name) or WaitForChild(name, 5)` — when the remote is absent
(every live server) `and/or` falls through to a 5 s wait each: 10 s of extra loading on the phone.
Now an explicit if. luau_check: config helper functions (ProgressionConfig.LevelForXp) are
recognised; `RaceConfig.Bots.FixedCount` (set by the Studio dev panel) is declared.

## 2026-11-25 — A4 merged onto the phone build, plus two owner requests

Three-way merge (base = A3 upload, ours = this repo, theirs = A4 upload). A4 moved
`MarbleMotorController` to `ReplicatedStorage/Shared` (bots run it too); we had not changed it, so
the move was taken as is. Two conflicts, both resolved keeping both sides:
- `RoundService` GO: humans get a fresh free marble (our A2 playtest fix), bots use A4's release;
  checkpoint records still begin first.
- stats box: three lines — client (FPS, p95, worst frame, memory, ping), server (A4 PerfService
  attributes), hitches. The phone ABILITIES panel moved down to y 84 to clear it.
A4 still had the A3 start-up wait in `MicroSkillService` (our fix kept) and added two more
unbounded waits on the marbles folder (`BotService`, `PerfService`) — caught by the new luau_check
rule; both now read the folder MarbleCharacterService.new creates.

**Owner request 1 — free look** (not in the A4 upload). `FreeLookController` + `CameraController`
orbit offsets: hold the right mouse button and move, drag a finger anywhere outside the
steering-stick area (lower left) and off the buttons, or use the gamepad right stick. Yaw any
amount, total pitch −10°..75°. While looking, the view stays; 1.5 s after the last look input it
eases back behind the marble; a respawn resets it. Display only: the motor never reads the camera
(steering follows the track). Offline specs drive the real CameraController against a fake camera
(11 checks, mutation-tested: wrong yaw sign and no return delay both fail).

**Owner request 2 — READY vote** (not in the A4 upload). Server-judged, new remote
`RequestReady(boolean)` (schema-checked, rate limited). The race is full at min(grid slots,
server size) queued players — 16 on the Foundry — so nobody else can join. Until then the
intermission timer runs and the HUD + hub board say "Waiting for players (n/16)". When full, a
READY button appears under SIT OUT; once every queued player is READY the intermission ends at
once (Preparing → 3-2-1 as usual). Votes reset every intermission and when a player leaves or sits
out. Bots do not count as players. `RaceConfig.Ready.CapacityOverride` (0 = off) exists only to
make a private test build where fewer players count as full. 14 pure specs (rules + payloads).

## 2026-11-25 — A3 merged onto the phone build

Three-way merge (base = owner's A2 upload, ours = this repo, theirs = A3 upload): **no conflicts**.
Everything kept: TouchStarted → touch layout, CurrentCamera wait, chord-smoothed camera/steering,
stats box + hitch log, GO = fresh free marble, SIT OUT / JOIN RACE button, closable results, LIST.
- Checked by reading: A3's spawn hooks (AbilityService cancels effects, MicroSkillService resets on
  `MarbleSpawned`) are harmless with the GO respawn; abilities require an unanchored race marble.
- Touch layout checked in reference units: A3's ability buttons (above BRAKE), TRICK (left of
  RESET), CAM and LIST do not overlap.
- One phone change: the hub ABILITIES panel moves from the bottom-left corner (where the stick is
  grabbed, also in the practice chute) to the upper left on touch.
- **Start-up deadlock found on the first phone run** (see test ledger, 2026-11-25) and fixed.
- `tools/luau_check.py`: config check now reads balanced tables (a one-line `X.Owned = { ... }`
  swallowed the sections after it and reported 6 false errors in AbilityConfig users);
  mutation-tested (bad section and bad key still reported).
- Place expectations: +10 scripts (44 total); `RequestTrick` (created from RoundProtocol.Remotes by
  RoundService) and `Features` (course folder built by TrainingTrackBuilder) added as runtime names.

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

## A3 decisions
| Topic | Decision |
|---|---|
| Authority | Server owns loadout, cooldown timestamps (server time), shield, every effect and every Pulse target (from server-observed positions). Client sends only `RequestAbility(slot 1|2)`, `RequestTrick()`, `RequestEquip(slot, id)` (lobby/results only). |
| Speed effects | Server sends timed modifiers (Boost x1.3 1.6 s, Trick x1.15 1.2 s, Slipstream x1.12 while held) to the owner's motor, which scales thrust, thrust target and terminal envelope; strongest wins (no stacking); hard cap 96 studs/s (< 108 audit envelope). Boost also pushes forward without W. |
| Pulse | ≤ 18 studs/s at the centre falling to 9 at 12 studs, horizontal, skips protected/frozen marbles, 1.2 s anti-chain per target. Delivered to the target's owner as an impulse (client ownership: a modified client could ignore it — logged limitation). |
| Shield | 2.5 s or first Pulse / active-bumper contact (server judged from positions); client also skips the bumper kick while its server-confirmed shield is up. |
| Ramp Trick | Tagged half-width kicker (26°) on the long straight. Server judges takeoff (lip crossing, launched height, speed, on the kicker), press window (0.3 s early / 0.45 s late), landing within 1.4 s. Visual spin is a separate local shell, never BallRoot. |
| Slipstream | ≤ 12 studs behind, route distance ahead 0–14, ahead dot ≥ 0.7, server raycast LOS, held 1.5 s; 0.25 s grace; ends on overtake. |
| Near Miss | One judgement per approach (16-stud radius) to the bumper while telegraphing/active, closest gap ≤ 3.5 without contact. |
| Charge | First valid trick / slipstream acquisition / near miss: −1.5 s on cooling slots, clamped at now, 3 s global lockout, no lockout if nothing was cooling. |
| UX | Two ability buttons with cooldown fill (Q/E, LB/RB, tap), TRICK button on touch, hub loadout panel, quiet toasts, 3 skippable hints, Reduced Motion switch (FOV pulse + spin off). |

## A4 decisions
| Topic | Decision |
|---|---|
| Course | `TrackDefinitions.Race` = Neon Foundry v2: 16 modules (ROUTE_MAP.md), 2931 studs, 8 checkpoints, 16 grid slots, 184-stud drop. Lengthened from 1830 studs toward the 90–150 s target; 1-D model perfect run ≈ 64 s (not a measurement). Training stays as the A1 reference definition. |
| Module contract | Module = pieces sharing a `Segment`; generator returns Entry/Exit ports (position, forward, up, width, S), route length, elevation delta. TrackValidator checks ports, widths, facing, dividers, hazard controllers, hammer-in-lane and tile passability **for every seed**. Ribbon self-clearance and hub clearance tested. |
| Hazards | Pure functions of (seed class = roundId mod 3, t = serverTime − epoch), epoch = scheduled GO time in the snapshot. Moving parts are anchored, non-colliding, unqueryable visuals CFramed by clients; contact is HazardSim on the marble's owner (bots: server). Falling tiles are the only server-toggled parts (identical floor for everyone). Kicks ≤ 45 studs/s (KickCap 30 + 15 for the pad). |
| Bots | Server-owned spheres, identical body (BotFactory), **the same MarbleMotorController module humans run** (moved to Shared), same AbilityService cooldowns, same checkpoint judging, same hazard model. BotBrain skill 0.8/1.0/1.2 changes decision interval, aim noise, route choice and ability timing only — never speed. `[BOT]` nameplates, negative ids, names from a fixed safe list. Fill to 8 racers only when ≥ 1 human races; never in the hub; despawned at Cleanup; isBot carried to results for A5 reward exclusion. Humans never wait: after the last human finishes, bots get 10 s. |
| Chaos Gates | 4 half-lane gates. Server-observed crossing (continuous sweep + lateral span), once per gate per racer per round. Tier: top 3 → +8%/1 s; else bottom half → +22%/2 s + 1 s shield; else +14%/1.5 s. Uses the single strongest-wins modifier slot (no stacking, hard cap 96). No client remote exists for gates. |
| Shield priority | A shield absorbs the next Pulse / active bumper / sweeper / hammer hit (server spends it on the first observed contact); never blocks the trampoline, fans or conveyors. Chaos Gate shields extend, never shorten, an active shield. |
| Split lanes | Progress = projection onto the centreline (checkpoint + route distance), so inside/outside lanes level with each other score the same (tested ±2 studs). |
| Perf | PerfService publishes server frame avg/p95, physics step, moving parts, instances, memory, marbles and bots every 2 s as workspace attributes; F2 overlay shows them. No FPS claim is made. |

## A5 decisions
| Topic | Decision |
|---|---|
| UI ownership | `UIController` is the single owner of visibility: screens Title / Lobby / Race / Spectate / Results, modals Settings / Loadout (allowed only on Lobby/Results, Settings also Spectate; auto-closed when the race starts). Every screen button is listed with an action (UIState.spec). Results moved to `ResultsController`; lobby = profile chip + LOADOUT + SETTINGS + queue chip in the right column (clear of chat and the touch stick). |
| Profile | `PlayerDataSchema` (one module, schema v1 + migration from nil/garbage/v0, sanitizing, bounded 25-entry reward ledger, daily bot-practice counter). `ProfileStore` (pure): session lock in `meta.jobId`, load waits 4×4 s then takes over (stale after 600 s), every save re-checks the lock and refuses after a takeover, bounded retries 3 (1/2/4 s), Unavailable / Unsaved / ReadOnly / TakenOver states. `PlayerDataService`: DataStore `TumbleProfiles_v1` live, request budget respected, autosave 60 s, lock refresh 240 s, leave = save + release, BindToClose flush (25 s), same-server rejoin waits for the leave-save. Studio = memory MOCK unless `StudioMode = "Live"`. |
| Rewards | `RewardRules.Apply` adds Coins/XP/records AND the raceId to the ledger in one mutation; raceId = JobId (or Studio GUID) + roundId. Granted only from `RoundService.RaceFinished`; no client remote grants or sets anything. AFK guard: racer must send real input (ReportActive / ability / trick / recover) during Racing. Coins 55 + 125/100/80 (4th..last linear 60→35, rounded) + 20; active DNF (CP1 or 15% route) 25 instead; idle 0. XP 100 + 60/45/30/10 + 30 PB; active DNF 20. Level 1–50, Lv2 400, +80 per level, always derived from XP. Bot practice (1 human + bots): 3 full races per UTC day, then Coins ×0.6, shown as a line + note. PB key `world|layoutVersion|seedClass|mode`; times < 8 s never count. Players who leave before Results get nothing for that race. |
| Settings | reducedMotion, cameraMode, music, sfx, sensitivity (steer ×0.5–1.5), graphicsMode (Auto = Low on touch: no bloom, fewer effects). Client sends one key per 0.25 s with the latest value; server sanitizes; saved with the next autosave. |
| Dev panel | `DevCommand`/`DevResult` remotes are created only in Studio or when `GameConfig.Dev.AuthorizedUserIds` is non-empty; every command re-checks; Coin grant / reset only on MOCK profiles. |

## A6 decisions
| Topic | Decision |
|---|---|
| Chaos Vote | SocialService + pure VoteRules. Eligible = humans who are not active racers (finished, sitting out, late joiners). A poll opens every 20 s of Racing when ≥ 1 eligible and ≥ 1 active racer and ≥ 20 s left; 5 s window; one vote per UserId per poll; stale/closed/bad votes refused; tie alternates by poll id; no votes → nothing. Winner announced 3 s ahead, lasts 8 s, cancelled when Racing ends. Options: Turbo Fans (fan push ×1.5, 42 < steering 70) and Bouncy Bumpers (kick ×1.25 = KickCap 30). Applied from shared timestamps by HazardService (bots) and each client (own marble); in the snapshot for late joiners. |
| Emotes | QuickEmote(1..3) presets GG / Nice Save! / Oops!, 5 s server cooldown + 0.5 s remote limit, broadcast as EmoteShown; bubbles ≤ 120 studs, 2.5 s; `muteEmotes` setting (schema v1 extension, default off). No free text anywhere. |
| Reactions | Perfect Dodge: server-judged pass of a sweeper/hammer with clearance ≤ 2.5 studs and no contact (SkillRules.DodgeStep + HazardSim.Clearance), commendation only (no Coins, no charge). Finish confetti (client, skipped on Reduced Motion / Low). |
| Podium & hub | Top three of each race as anchored display marbles with name tags + light on the hub podium until the next results. Hub decor: podium arch, showcase pedestal, 4 holo pylons (native parts, non-colliding). |
| Accessibility | Bumpers show "!" / "KICK" / "BOUNCY!" text; telegraphing tiles change material; fan arrows only while pushing; gamepad gets a selected button on Results / Settings / Loadout and none during races; buttons dip to 0.97 when pressed; results pop 0.25 s. |
| Cleanup | Per-player limiter entries forgotten on leave (round, social, settings); bots, poll, modifier and podium are round-scoped; VFX/emote bubbles self-expire. |

## Ledger
### Done (verified by tests that ran here)
- [x] A1: config ranges, smoothing, course generator/validator, floor geometry exactness (mutation-tested), steering-frame stability, route tracking, spawn clearance, hazard cycle, no invented ids
- [x] A2: transition graph (reachable, no dead ends, legal full cycle, no shortcuts to Racing)
- [x] A2: payload validation accepts only exact schemas; every client remote rate limited; no Set* remotes
- [x] A2: standings order incl. DNF and ordinal ties; near-simultaneous finish ordering; crossing interpolation
- [x] A2: grid shuffle deterministic permutation, varies per round; 16 grid slots validated (spacing, rails, behind gate)
- [x] A2: checkpoint judging with simulated samples — ordered CP1→CP3→finish, interpolated finish time, teleport jump rejected, corridor rejected, impossible split rejected, respawn never crosses, progress capped
- [x] A2: hub spawns spaced/inside rim, chute flush with hub edge, rim gap open, chute validates
- [x] A3: config values, cooldown readiness, charge (−1.5 s, clamp, 3 s lockout, no lockout when idle), non-stacking modifiers, hard cap, Pulse falloff/targets/bounds, loadout validation
- [x] A3: trick (early/late press, no press, flat lane, beside kicker, too slow, duplicate, no landing, respawn), slipstream (hold, single acquisition, grace, loss, no oscillation farming), near miss (once per pass, idle hazard, hit, boundary bobbing)
- [x] A3: malformed/out-of-range/NaN/inf/server-only requests rejected; every client argument bounded; no client remote names targets/positions/impulses/cooldowns
- [x] A4: Foundry validates with 0 errors; 16 modules, ports meet with same facing, metadata present, 1500–3500 studs, ordered checkpoints (max gap ≤ 650 studs), 16 grid slots, 4 gates, all 7 hazard kinds; ribbon never self-intersects; clear of the hub; 5 mutation tests caught (hammer out of lane, impassable tiles, unknown hazard, divider never rejoins, too few slots); split-lane progress unbiased
- [x] A4: hazard determinism (same seed + t identical; seeds differ; Params never mutates definitions), every kick ≤ cap, fan/conveyor only inside their zones and calm while off, sweeper/hammer visuals sit where contact is judged
- [x] A4: BotBrain steering, bumper/hammer/sweeper/tile avoidance, divider clearance, no hidden throttle above 1, deterministic RNG, ability choice only from ready slots; kinematic lane model over the whole Foundry (3 skills × 3 seeds × 3 runs): stays on course, never hits the divider, ≤ 4 hazard hits + tile drops per run at skill 1.0 (**model, not physics**)
- [x] A4: Chaos Gate tiers for 1/2/8/12 racers, one payout despite bouncing, lateral span enforced, reset per round, VFX per payout, no client claim remote; bot fill rule (0 humans → 0 bots, 1 → 7, 7 → 1, 8+ → 0, grid cap, kill switch)
- [x] A4 owner requests: free look (11 offline checks on the real CameraController), READY vote rules + RequestReady payloads (14)
- [x] A5: schema defaults deterministic + complete; migrations (nil, garbage, v0 partial, hostile NaN/inf/negative, duplicate loadout, newer schema read-only); setting sanitizing; PB keys separate variations/layouts
- [x] A5: ProfileStore — lock wait + takeover, older session can't overwrite, stale lock, bounded retries → Unsaved (never "saved"), recovery, load failure never writes defaults, newer schema never written, release on leave, same-server rejoin, mock label
- [x] A5: level curve (400/+80, cap 50, overflow/NaN safe), Coins for 1/2/3/4/8 + DNF + idle, interpolation, XP, breakdown sums, bot-practice 3/day then 60% + day reset, PB rules (first / faster / slower / other variation / implausible), level-up once, duplicate raceId pays nothing, ledger bounded, leave-at-results → rejoin pays once, raceIds unique per server
- [x] A5: UI state for every round situation, modal rules + auto-close, no dead buttons, no shop/Robux/capsule/season actions or UI strings, no MarketplaceService, settings stepping, loadout swap, PB lines
- [x] A6: vote eligibility, open timing (20 s spacing, enough time left, spectators + racers present, no overlap with an active modifier), one vote per poll, stale/closed/bad votes, ties, no votes, voter leaving; modifiers counter-steerable / within kick cap and only inside their window; Clearance agrees with the contact model; Perfect Dodge once per pass and never on contact; emote presets + bounded remotes; banner text
- [x] 81 files parse; place verified offline (79 scripts, every lookup resolves); Rojo builds it in CI

### Implemented, untested (needs Studio — TEST_PLAN sections 3 and 5)
- [ ] Everything engine-side from A1 (feel, camera, devices, UI)
- [ ] Round loop timing, snapshots on both clients, late joiner sync, 3 consecutive rounds
- [ ] Grid freeze/release, gate toggle, protection ghosting, marble bumps + limiter
- [ ] Checkpoint flashes, placement badge, standings, results, DNF, disconnect handling, spectate cycling
- [ ] Practice chute loop, hub board text

- [ ] A3 on the phone: every docs/ANDROID_PLAYTEST.md A3 item (feel of Boost/Shield, trick timing, near miss, VFX cleanup); Pulse and Slipstream need 2 players (TEST_PLAN §6)

- [ ] A4 on the phone / in Studio: every TEST_PLAN §7 item — real race time (90–150 s target), bots finishing/recovering with 1, 3, 8 racers, server p95 with 8 racers, 3-race leak check, hazards in sync on 2 clients
- [ ] Free look on the phone (finger drag beside the stick) and READY vote with a full race (needs 16 players or a CapacityOverride test build)

- [ ] A5 on the phone / in Studio: every TEST_PLAN §8 item — real DataStore only in a throwaway test universe (owner); 640x360 / console layout check

- [ ] A6 on the phone / in Studio: every TEST_PLAN §9 item — vote/emotes on 2 clients, podium, cues, gamepad focus, 15-minute soak, device emulator sizes

### Blocked
- [ ] **2-client network verification** — no Studio here. Steps + expected log order: TEST_PLAN §5.
- [ ] FPS/frame time — no device. F2 overlay + MicroProfiler procedure in TEST_PLAN §3G.

## Known risks
1. Never run in Studio; expect first-run errors (Output will name file and line).
2. Client-owned marbles colliding is resolved per-client; bumps may look asymmetric under latency.
3. Race length unproven: Foundry 1-D model ≈ 64 s perfect run vs the 90–150 s target (hazards, braking and recoveries add time, by how much is a playtest question). Lengthening is a data change.
6. Bots run the motor on the server at Heartbeat; 7 bots = 7 server-simulated spheres. Not profiled. `RaceConfig.Bots.FillTo` is the safety valve.
7. Sweeper/hammer contact for human marbles is judged on their own client (ownership); a modified client could ignore hazard kicks. Logged limitation, same as A3 Pulse.
4. A cheating client can still drive its own marble anywhere physically plausible (that is the ownership trade-off); impossible movement is rejected and logged.
5. Same-sample finish ordering assumes Heartbeat samples; extreme server hitches coarsen timing.

## Test ledger
| Date | Command | Result |
|---|---|---|
| 2026-11-19 | `texlua tools/offline/run_tests.lua .` (A1) | 26 files parse; 57 passed |
| 2026-11-21 | `texlua tools/offline/run_tests.lua .` (A1+A2) | 37 files parse; **83 passed, 0 failed** (A1 56 + A2 27) |
| 2026-11-21 | `python3 tools/build_rbxlx.py . TumbleCircuit.rbxlx` + XML parse | well-formed |
| 2026-11-22 | `texlua tools/offline/run_tests.lua .` (A1–A3, original A3 upload) | 47 files parse; **131 passed, 0 failed** |
| 2026-11-22 | `texlua tools/offline/run_tests.lua .` (A1–A4, original A4 upload) | 60 files parse; **193 passed, 0 failed** |
| 2026-11-22 | `texlua tools/offline/run_tests.lua .` (A1–A5) | 75 files parse; **273 passed, 0 failed** |
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
| 2026-11-25 | A3 merge + `luau_check` (44 files) + offline specs + offline place build + `verify_place.py` | 0 errors (3 unused-local warnings); **140 passed, 0 failed**; 58 instances, 44 scripts, all references resolve; smoothed heading defined on both routes (worst 0.75 / 0.92 °/stud) |
| 2026-11-25 | Cloud build run 45595559373 | **failed at Selene**: 2 `if_same_then_else` errors in `AbilitySecurity.spec.lua` (three branches all set `constrained = false`); folded into one condition, same meaning; nothing published |
| 2026-11-25 | GitHub Actions **Deploy** run 45595693660 (A3, commit f77686c: Rojo, Selene, Lune, 140 specs, publish) | **success**: Selene 0 errors; **version 9** published, visibility PRIVATE |
| 2026-11-25 | **A3 first phone playtest** (owner, v9, Roblox Android app) | **server never finished starting**: phone stuck on "Building the Orbital Garage...", then "Could not start: server remotes missing or protocol mismatch". Cause (found by reading the boot order): `MicroSkillService:Start()` did `workspace:WaitForChild("TumbleMarbles")` with no timeout, but that folder was only created by `MarbleCharacterService:Start()`, which ServerBootstrap runs after it → the boot script yielded forever (A3 upload bug; offline specs don't run services). Fix: folder created in `MarbleCharacterService.new`; MicroSkillService uses `marbles.folder`. New `luau_check` rule: server code may not `workspace:WaitForChild(x)` without a timeout (catches the original A3 file). Client failure message now names the real cause (missing remotes list / protocol versions / server not finished). All 60 client method calls and every A3 service dependency checked to exist. |
| 2026-11-25 | A3 phone re-test of v10 (owner) | **"All works fine now"** — A3 approved, go to A4 |
| 2026-11-25 | A4 merge + owner requests: `luau_check` (59 files) + offline specs + offline place build + `verify_place.py` | 0 errors (3 unused-local warnings); **227 passed, 0 failed** (A1–A4 202, READY 14, free look 11); 73 instances, 59 scripts, all references resolve; smoothed heading on the Foundry defined everywhere (worst 1.00 °/stud) |
| 2026-11-25 | GitHub Actions **Deploy** run 45599458818 (A4 + owner requests, commit a902103: Rojo, Selene, Lune, 227 specs, publish) | **success**: **version 11** published, visibility PRIVATE |
| 2026-11-25 | **A4 phone playtest** (owner, v11): you raced fine; **bots stayed at the start / vanished right at GO and all showed DNF** | Same pattern as the human GO bug (2026-11-23): `BotService:Release` unanchored the frozen grid bot ball in place. Fix: GO now respawns each bot as a fresh free marble on its slot (`Spawn(bot, Go)`), like humans. Also: each bot's step runs in `pcall` (one error used to abort the whole bot loop every frame — would also freeze bots and skip their stuck recovery); per-round diagnostics published as `Bots_Status` / `Bots_LastError` and shown as a BOTS line in the stats box (racing, moving, best checkpoint, falls/stuck/audit respawns, errors). New luau_check rule: server code may not set `<ball>.Anchored = false` (flags both original files). Root cause still unconfirmed in a runtime — the BOTS line will show it. |
| 2026-11-25 | GitHub Actions **Deploy** run 45601891384 (bot fix, commit 0827f2b) | **success**: version 12, PRIVATE |
| 2026-11-25 | A5 merge: `luau_check` (74 files) + offline specs + offline place build + `verify_place.py` | 0 errors (4 unused-local warnings); **307 passed, 0 failed**; 88 instances, 74 scripts, all references resolve |
| 2026-11-25 | GitHub Actions **Deploy** run 45602414831 (A5, commit e1d1a28: Rojo, Selene, Lune, 307 specs, publish) | **success**: **version 13** published, visibility PRIVATE |
| 2026-11-25 | **A5 + bot fix phone playtest** (owner, v13) | **"all is going as intended"** (bots race). One few-second freeze near checkpoint 2 (Bumper Field), once. Code review: nothing heavy runs on a checkpoint crossing or bumper hit (no instance creation, no saves on the client). Waiting for the stats box hitch line if it recurs |
| 2026-11-25 | A6 merge: `luau_check` (79 files) + offline specs + offline place build + `verify_place.py` | 0 errors (4 unused-local warnings); **332 passed, 0 failed**; 93 instances, 79 scripts, all references resolve |
| — | A6 first phone playtest | **pending owner** |
| — | 2-client network verification | **pending** (needs a second account) |
