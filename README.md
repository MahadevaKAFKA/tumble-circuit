# Tumble Circuit: Chaos Drop — Phases A–D (launch candidate, private)

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
  Reduced Motion switch. Played on the owner's phone: go (2026-11-25).
- **A4** — the full Neon Foundry (16 modules, ROUTE_MAP.md), seeded moving hazards, bots that
  fill the grid to 8 racers, Chaos Gates, server performance numbers. Owner requests added on top:
  **free look** (right mouse / finger drag / right stick) and a **READY vote** that starts a full
  race without waiting for the timer. Bots fixed after the owner's phone run (stuck at GO).
- **A5** — UI flow (title, lobby column, race, spectate, results), profile with Coins/XP/level,
  personal bests, settings and loadout saved to the player's account (session-locked DataStore),
  idempotent race rewards, dev panel in Studio only. Played on the owner's phone: go.
- **A6** — spectator Chaos Vote, quick emotes, Perfect Dodge, finish confetti, hub podium and
  decor, accessibility cues. Closes Phase A (see PHASE_A_ACCEPTANCE_REPORT.md).
- **B1** — Sky Carnival and Volcano Vault worlds, map vote, Time Trial with PB ghost, Party Race.
- **B2** — nine more abilities, earned by level or Coins; try them in the hub.
- **B3** — garage (35 marbles, trails, bursts, emotes), level rewards, quests, leaderboards,
  telemetry.
- **C** — free capsules (earned Coins, published odds and pity), Shard Shop, free 28-day season.
- **D** — optional cosmetic shop (**everything off**: no product ids), receipt journal,
  anti-cheat aggregation, launch docs: [OWNER_SETUP_CHECKLIST.md](OWNER_SETUP_CHECKLIST.md),
  [MONETIZATION_COMPLIANCE.md](MONETIZATION_COMPLIANCE.md), [GAME_DESIGN.md](GAME_DESIGN.md),
  [BALANCING_CONFIG.md](BALANCING_CONFIG.md), [docs/LAUNCH_KIT.md](docs/LAUNCH_KIT.md).

Phases B–D were built in one go on the owner's go-ahead and are offline-verified and published
privately; **they have not been played in Roblox yet** (see BUILD_STATUS).

Two ways to work with it:

| You want to… | Use |
| --- | --- |
| Play it on your **phone**, no Studio, no PC tools | GitHub Actions builds and publishes it → [docs/SETUP.md](docs/SETUP.md), then [docs/ANDROID_PLAYTEST.md](docs/ANDROID_PLAYTEST.md) |
| Open it in **Roblox Studio** | [README_INSTALL.md](README_INSTALL.md) |

Status, decisions and the honest test ledger: [BUILD_STATUS.md](BUILD_STATUS.md).
Manual playtest checklist: [TEST_PLAN.md](TEST_PLAN.md).

## The cloud pipeline

- **Build** (`.github/workflows/build.yml`) — runs on every push. Checks every script
  (syntax, globals, module/config references), runs the project's own offline specs (332 for A1–A6),
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
