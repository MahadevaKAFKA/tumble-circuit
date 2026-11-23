# Tumble Circuit: Chaos Drop — Phase A1 (mobile playtest build)

A marble-racing Roblox game, built as a Rojo/Luau project and assembled entirely in
GitHub's cloud — no Roblox Studio or tools on your PC.

**Phase A1 scope:** one physics marble, the default Roblox camera, and a compact
practice course (start pad, bumpers, ramp, corner, spinning sweeper, jump gap, finish)
with checkpoints, respawning, a run timer and a best time.

## Play it on your phone

1. One-time setup (≈10 min, all from your phone): [docs/SETUP.md](docs/SETUP.md)
2. Deploy: **Actions → Deploy to Roblox (private playtest) → Run workflow**
3. Play: [docs/ANDROID_PLAYTEST.md](docs/ANDROID_PLAYTEST.md) — Chrome **Play in Browser**
   first, the Roblox app as the fallback.

The experience stays **private**: the deploy refuses to publish if the experience is
public unless you explicitly tick `allow_public`.

## Controls

| Action | Phone (touch) | Keyboard | Gamepad |
| --- | --- | --- | --- |
| Roll | Thumbstick (left side) | WASD / arrows | Left stick |
| Jump | Jump button (bottom right) | Space | A |
| Look around | Drag on the right side | Right-mouse drag | Right stick |
| Back to last checkpoint | **RESPAWN** button | R | Y |
| Restart the run | **RESTART** button | T | Select |

Falling off the course puts you back at your last checkpoint automatically.

## What's in the repo

```
default.project.json       Rojo project (what goes where in the place)
src/shared/                Config (all tuning numbers), CourseLayout.json, CourseData
src/server/                CourseBuilder, MarbleService, CheckpointService
src/client/                MarbleController (input + physics), Hud, TouchFallback
tests/                     Layout checks, deploy-script tests, place verifiers
tools/                     Offline Luau checker and place builder
scripts/publish.py         Open Cloud publisher used by the deploy workflow
.github/workflows/         build.yml (every push) and deploy.yml (manual)
docs/                      Setup, Android playtest, test report
```

## Tuning

Everything that affects feel is in `src/shared/Config.luau` (speed, acceleration,
jump height, camera zoom). The course is in `src/shared/CourseLayout.json`. Edit
either on GitHub (pencil icon), commit, then run the deploy workflow again.

## Status

See [docs/TEST_REPORT.md](docs/TEST_REPORT.md) for exactly what has been verified
automatically and what still needs a real playtest.
