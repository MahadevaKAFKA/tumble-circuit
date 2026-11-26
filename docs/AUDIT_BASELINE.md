# Prompt 01 — Audit and baseline (2026-11-26)

Checkout: `MahadevaKAFKA/tumble-circuit` at 62a36e5 (v20, private). Phase: **D done**. The owner
reported on 2026-11-26 that v16–v20 "work as intended" on the Galaxy S25 Ultra. No promo-pack
prompt crosses an active phase gate: every phase A1–D is built. Prompt 07 gates the new hub, not
the race.

Evidence labels used below:
- **static** = Selene, luau_check, place assembly;
- **offline** = Lua 5.3 harness executing the real modules with a datatype shim;
- **runtime** = Roblox client or server. I have no Roblox runtime, so every runtime number is
  **pending** until the owner reads it off the phone overlay.

## 1. Player flow, with the code that owns each step

| Step | What happens | Owner (file) |
| --- | --- | --- |
| Spawn | Server builds every world + hub at boot, sets `TC_CourseReady`; client waits, generates the same layouts | `TrainingTrackService:Build`, `ClientBootstrap` (waitForWorld) |
| Orbital Garage | `ResolveSpawn` falls through to `NextHubSpawnCFrame()` (16-spot ring), Zone = `Hub` | `RoundService:ResolveSpawn`, `MarbleCharacterService`, `HubBuilder.SpawnCFrames` |
| Hub free roam | Flat-platform steering when inside `Hub.Radius` | `ClientBootstrap` (`onHubPlatform`, `HUB_DEF`) |
| Practice | Hub zone *is* the Practice Chute route; crossing its finish respawns you on the ring after 0.6 s | `RoundService:_onProgress` (Hub branch), `TrackDefinitions.PracticeChute` |
| Queue | JOIN → `RequestJoin` → `TryJoin`; READY votes; map vote with ≥ 2 humans | `MatchUIController`, `RoundService:TryJoin/TryReady/TryMapVote`, `MapVoteRules` |
| Grid | Preparing: `SetActiveWorld(winner)`, racers → `GetGridCFrame(slot)`, frozen; bots fill | `RoundService:_enterPreparing`, `BotService` |
| Countdown | 3 s, gate closed | `RoundService:_enterCountdown` |
| Race | Gate opens; `RacePhysicsService` tracks progress on the zone's layout; `CheckpointService` validates | `RacePhysicsService`, `CheckpointService`, `RouteTracker` |
| Results | 12 s; rewards, podium tags on the Garage podium | `RoundService:_enterResults`, `SocialService` (podium), `ResultsController` |
| Return | Cleanup respawns every racer with reason `ToHub` → hub ring | `RoundService:_enterCleanup` |

## 2. Where each concern is defined

- **Map id and route.** `TrackDefinitions.Worlds` holds the ids `NeonFoundry_A4`,
  `SkyCarnival_B1` and `VolcanoVault_B1`. Each id lives in its def's `Id` field. Best times are
  keyed by these ids.
- **World geometry.** `TrackDefinitions.Generate` and `TrainingTrackBuilder.ComputeSpecs/Build`.
  Every world is built once under `workspace.TrainingCourse/<id>`.
- **Theme.** The def's `Theme` field becomes `Builder.ThemePalette`, and the hazard `Style`
  decides how hazards look.
- **Lighting.** `TrainingTrackService:ApplyEnvironment` makes one global night profile, set by
  the server. There is no per-map or per-hub lighting.
- **Spawn transforms.**
  - Hub: `HubBuilder.SpawnCFrames(TrackDefinitions.Hub)`.
  - Grid: `layout.GridSlots`.
  - Respawns: `layout.Checkpoints[i].RespawnFrame`.
  - Time Trial: `GetTimeTrialStart`.
- **Practice chute.** `TrackDefinitions.PracticeChute`, built inside `workspace.OrbitalGarage`.
- **Progress, bots and input.**
  - Progress: `RacePhysicsService`, `CheckpointService`, `RouteTracker`.
  - Bots: `BotService` with `BotBrain`, rebound on `WorldChanged`.
  - Input overlay: `TouchControls`, `InputController`, `MatchUIController`.

## 3. Hardcoded single-hub / Neon Foundry references

| Where | Reference |
| --- | --- |
| `TrackDefinitions` | `Race = NeonFoundry`; `World(id)` falls back to NeonFoundry; `Hub`, `PracticeChute` singletons |
| `Protocol` | `HubModelName = "OrbitalGarage"` |
| `TrainingTrackService:Build` | one hub, one chute: `layouts[Hub]`, `killY[Hub]`, `hubSpawns` |
| `RoundService` | `NextHubSpawnCFrame()` (every hub return), `GetLayout(ZONES.Hub)` (practice loop) |
| `MarbleCharacterService` | fallback spawn `NextHubSpawnCFrame()` |
| `SocialService` | podium at `PodiumSpots(TrackDefinitions.Hub)` in `workspace.OrbitalGarage` |
| `AbilityService` | practice loadout uses `GetLayout(Hub)` |
| `ClientBootstrap` | "Building the Orbital Garage…" text; `layouts[Hub] = PracticeChute`; `HUB_DEF = TrackDefinitions.Hub`; next-race board found in `OrbitalGarage` |
| `HubBuilder` | board title "ORBITAL GARAGE" |

**Regression found (from B1, v16):** the chase camera's obstruction ray was meant to ignore
the race rails, decor, hazards, gates and features. It looked them up at the root of
`workspace.TrainingCourse`. B1 moved each world into its own subfolder, so the camera now
ignores none of the race parts and can pull in against them. Recovery: build that ignore list
from each world's folder. This is fixed in prompt 02, and it is the only intended camera
behaviour change.

## 4. Minimal seam for a registry and per-map hub loader

1. **`MapRegistry` (Shared, pure).**
   - Maps: id, display name, track def id, hub id, visual profile, preview, difficulty, blurb,
     status.
   - Hubs: id, display name, centre, radius, chute def, spawn ring, profile, status.
   - Validation and a Foundry / Orbital Garage fallback live here.
   - Geometry stays in `TrackDefinitions`. Ids do not change, so records stay compatible.
2. **`TrainingTrackService`.** Build hubs from the registry and key layouts, kill heights and
   spawns by hub id:
   - `GetLayout(zone, hubId)`, `GetKillY(zone, hubId)`, `NextHubSpawnCFrame(hubId)`;
   - the default hub id is `OrbitalGarage`.
3. **Per-player hub id** (player attribute `TC_Hub`). It is passed through `ResolveSpawn`, the
   practice loop and the client's `layouts[Hub]`.

Every step is additive: with only Orbital Garage registered, behaviour is unchanged.

## 5. Baseline numbers

### Offline (measured by executing the builders; not runtime)

| Section | Parts | Collidable | Route | Modules / CPs | 1-D model clean run |
| --- | --- | --- | --- | --- | --- |
| Neon Foundry | 2,050 | 1,270 | 2,931 studs | 16 / 8 | 64 s |
| Sky Carnival | 1,851 | 1,141 | 2,530 studs | 14 / 8 | 54 s |
| Volcano Vault | 1,807 | 1,127 | 2,300 studs | 14 / 8 | 49 s |
| Orbital Garage hub | 100 | — | — | — | — |
| Practice Chute | 187 | — | 174 studs | — | — |
| **Total built parts** | **5,995** | | | | |

Other offline results:
- Scripts in the place: 110. Offline specs: 526 passing.
- The "clean run" column is a model, not a measured time.

### Runtime — pending (owner, phone; no Studio needed)

The perf overlay (top left, on by default in private builds) now also shows:
- `inst`: the client's instance count;
- `respawn`: seconds from losing your marble to controlling the next one;
- `SERVER … inst`: the server's instance count.

Each screenshot captures one row of the table below.

| Case | Read from the overlay | Status |
| --- | --- | --- |
| Solo, hub idle 30 s | FPS, p95, mem, inst | pending |
| Solo, Foundry grid → mid race | FPS, p95, worst, inst, track visibility (screenshot) | pending |
| Solo, fall off on purpose | `respawn` value | pending |
| Two clients (phone + a second device) | both overlays during one race | pending, optional |
| Studio Start Server, 2 clients | — | not possible here (no Studio by owner choice) |

## 6. Plan for prompt 02 (smallest reversible changes)

1. **Add `MapRegistry.lua`** with three maps and one hub (Orbital Garage), plus
   `Validate`, `Map(id)` and `Hub(id)` with fallbacks, and an offline spec.
2. **Build through the registry in `TrainingTrackService`.** Each builder runs in a `pcall`.
   - A failing non-default map is dropped from rotation and named in `TC_CourseError` (not
     fatal).
   - Neon Foundry is the known-safe fallback.
3. **Key hub state by hub id.** The default call sites keep working unchanged.
4. **Client.** Map metadata comes from the registry, and the camera ignore list comes from
   each world's folder (the regression above).
5. **Rollback.** Revert the commit and redeploy. There are no data changes: profile v5 and
   protocol v11 stay the same.
