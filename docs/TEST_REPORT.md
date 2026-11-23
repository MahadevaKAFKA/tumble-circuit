# Test report — Phase A1 mobile build (A1-mobile-1)

**Nothing in this build has run inside a Roblox runtime yet.** Everything below
was verified statically or by tests that run outside Roblox. Real gameplay must be
confirmed on your phone (checklist in ANDROID_PLAYTEST.md).

## Important: this is an A1-spec rebuild

The original Phase A1 files (delivered 19 Nov) were not reachable from this
session — not in Google Drive, not on GitHub, PC not connected. This build
implements the A1 spec (single marble physics, camera, compact practice course)
from scratch, structured so the originals can be merged in. Send the A1 zip and
its scripts take priority over these wherever they differ.

## Automated checks

| Check | How | Result |
| --- | --- | --- |
| Luau syntax (all 11 scripts) | `tools/luau_check.py` — Luau grammar parser | ✅ pass |
| Undefined / misspelled globals, accidental globals | same, lexical scope analysis | ✅ none |
| Module API references (`Module.fn` exists) | same, cross-reference | ✅ all resolve |
| Config keys (`Config.Movement.X` exists) | same | ✅ all resolve |
| Checker can detect real mistakes | run on deliberately broken samples | ✅ 10/10 caught |
| Place assembles | `tools/build_place.py` (offline) → `TumbleCircuit.rbxlx` | ✅ 22 instances |
| Required instances, classes, properties | `tests/verify_place.py` | ✅ pass |
| Every `WaitForChild`/`FindFirstChild` target exists | same | ✅ pass |
| External assets (images, meshes, sounds) | scan for asset IDs | ✅ none used — nothing can fail to load |
| Course geometry (69 checks) | `tests/test_course_layout.py` | ✅ pass |
| Geometry checks can fail | mutation test (5 deliberate errors) | ✅ 8 failures reported |
| Deploy script (10 scenarios) | `tests/test_publish.py` with a fake Open Cloud | ✅ pass |
| Workflow files are valid YAML | parsed | ✅ |
| Rojo build, Selene lint, Lune verify | `.github/workflows/build.yml` | ⏳ runs on first push to GitHub |

## Gameplay areas — what is verified and how

| Area | Static verification | Needs playtest |
| --- | --- | --- |
| Player spawning | `CharacterAutoLoads` off; server builds course, then spawns; spawn points sit on floors, inside their zones, clear of rails/edges | Marble appears on start pad |
| Marble physics & movement | Force model reviewed (ground/air accel, speed cap, turn assist, braking, slope following); ground probe reaches slopes (2.09 < 2.6 studs on the ramp) | Feel, speed, grip |
| Falling & collisions | Kill plane 26 studs under the lowest floor; rails 3 studs high; each bumper leaves a 10-stud passage | Bounces, no clipping |
| Abilities | A1 scope = **jump** only (buffer, coyote time, cooldown) plus respawn/restart. Boosts etc. are later phases | Jump height ~7 studs |
| Mobile touch controls | Uses Roblox's standard thumbstick + jump button; fallback stick/JUMP if they're missing | Both in app and Web Play |
| Checkpoints & respawn | 4 checkpoint zones + finish, none overlapping; restart can't be counted early | Strips turn green, respawn spot |
| Core loop | Ready → timer starts leaving start → checkpoints → finish time/best → restart | Full lap |
| UI scaling | Panels scale with screen (0.8–1.5×), buttons ≥ 52 px tall, kept off thumbstick/jump areas | Readability on S25 Ultra |
| Missing assets / broken refs | None used / all resolve | — |
| Finish gap | Clearable with a jump from the last checkpoint (28-stud range vs 8-stud gap) | Feels fair |

## Known issues / limitations

1. **Original A1 code not merged** (see above).
2. **Not yet run in Roblox.** Tuning numbers (`Config.luau`) are first-pass values.
3. **Web Play is a creators-only beta.** Roblox hasn't documented phone touch
   controls in Web Play; the fallback controls cover that, and the app is the reference.
4. **The marble shows rolling through its Marble material texture**; if it looks
   like it's sliding, a striped texture is an easy later tweak.
5. **Best times last for the session only** (no saving) — intentional for A1.
6. **Assets API publishing for places is marked beta by Roblox.** The deploy falls
   back to the classic Place Publishing API automatically.
7. Deploying **overwrites the target place** (version history keeps old versions).
