# Tumble Circuit: Chaos Drop — Phase A3

A marble-racing Roblox game, built as a Rojo/Luau project.

- **A1** — "the marble must feel great": one marble, steering, braking, a chase camera and a short
  training course (start pad → straight ramp → banked S-turn → pulse bumper → 90° banked drop →
  finish basin). Played on the owner's phone, 2026-11-23: go.
- **A2** — fair multiplayer rounds: Orbital Garage hub with a practice chute, automatic rounds
  (intermission → frozen grid → 3-2-1 → GO → race → results), server-judged checkpoints and
  placings, spawn protection and bump limits, spectating. Played on the owner's phone: go
  (2026-11-25).
- **A3** — abilities and micro-skills: two ability slots (Boost, Shield, Pulse; server-owned
  cooldowns and effects), Ramp Trick, Slipstream, Near Miss, cooldown charge, hub loadout panel,
  Reduced Motion switch.

Two ways to work with it:

| You want to… | Use |
| --- | --- |
| Play it on your **phone**, no Studio, no PC tools | GitHub Actions builds and publishes it → [docs/SETUP.md](docs/SETUP.md), then [docs/ANDROID_PLAYTEST.md](docs/ANDROID_PLAYTEST.md) |
| Open it in **Roblox Studio** | [README_INSTALL.md](README_INSTALL.md) |

Status, decisions and the honest test ledger: [BUILD_STATUS.md](BUILD_STATUS.md).
Manual playtest checklist: [TEST_PLAN.md](TEST_PLAN.md).

## The cloud pipeline

- **Build** (`.github/workflows/build.yml`) — runs on every push. Checks every script
  (syntax, globals, module/config references), runs the project's own offline specs (140 for A1–A3),
  lints with Selene, builds the place with **Rojo**, verifies the built place with **Lune**,
  and attaches `TumbleCircuit.rbxl` / `.rbxlx` as a downloadable artifact. Publishes nothing.
- **Deploy to Roblox (private playtest)** (`.github/workflows/deploy.yml`) — started by hand
  from the Actions tab. Builds, then publishes to your existing experience with Roblox Open
  Cloud, waiting until Roblox confirms. It **refuses to publish if the experience is public**
  unless you tick `allow_public`, and never changes privacy settings.

Credentials live only in GitHub Secrets/Variables (`ROBLOX_API_KEY`, `ROBLOX_UNIVERSE_ID`,
`ROBLOX_PLACE_ID`) — never in the code, the artifacts or the logs.

## Tuning

- Marble feel: `src/ReplicatedStorage/Shared/PhysicsConfig.lua`
- Camera, UI sizes, timings: `src/ReplicatedStorage/Shared/GameConfig.lua`
- Course layout: `src/ReplicatedStorage/Shared/TrackDefinitions.lua`

Edit on GitHub (pencil icon) → commit → run **Deploy** again.
