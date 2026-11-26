# Animation, UI and economy pass — baseline, contracts and migration plan

Brief: `docs/ANIMATION_UI_ECONOMY_BRIEF.md` (owner, 2026-11-26). Build before this pass: v31
(commit 44e78ff). Every milestone below is a separate commit and a separate private publish, so
each one can be rolled back on its own (rollback = `git revert <commit>` + run the deploy
workflow; the previous place version also stays in the experience's version history).

Publishing: the owner chose to keep private publishes per milestone (2026-11-26). No milestone
makes the experience public, lists a product or charges Robux.

## 1. Baseline (read from the code, v31)

### Round timing (RaceConfig.Timers, server authority: RoundService)
| State | Seconds | What happens |
| --- | --- | --- |
| Intermission | 15 | queue, ready vote, ballots |
| Preparing | 2 | ballots resolved, roster + bots fixed, every racer spawned **anchored** on its grid slot (`GetGridCFrame(slot)`, 16 slots = 4 x 4 on the StartPad), gate closed, hazard epoch = now + Preparing + Countdown |
| Countdown | 3 | 3-2-1 from the shared server clock |
| Racing | <= 180 | gate opens, balls unanchored, `raceStartedAt` = GetServerTimeNow() |
| Results | 12 | standings, rewards |

Snapshots carry `stateStartedAt` / `stateEndsAt` / `raceStartedAt` in server time.
v31 intro (`RaceIntroController`): grid marbles drop from above + camera swoop, client only.

### Coin sources (all server-side)
| Source | Amount | Code |
| --- | --- | --- |
| Race finish | 55 base + placement (125/100/80, then 60 -> 35) + 20 completion | `ProgressionConfig.RaceReward`, `RewardRules.Apply` (once per raceId) |
| Active DNF | 25 | same |
| Bot practice | x0.6 after 3 bot races / UTC day | same |
| Daily quests | 3 per day x 60 Coins (+100 XP) | `QuestConfig.Rewards`, `QuestService:Claim` |
| Weekly quests | 4 per week x 250 Coins (+400 XP) | same |
| Season free track | 60 Coins on 15 of the 30 levels (900 / season) | `SeasonConfig.Reward`, `SeasonService.ApplyReward` |
| Dev panel | Studio mock profiles only | `DevService` |

There are no login, streak or passive-timer Coins. A typical day (5 races, all quests) is
roughly 5 x ~155 + 180 + 1000/7 ~ **1,100 Coins**, ~75% of it from races.

### Coin sinks
- Capsules: Marble 600, Trail 450, Burst 350, Emote 300 (`CapsuleOdds.Boxes`).
- Ability unlock shortcut: 800 / 1200 / 1600 Coins (or reach the level, free).

### Other currencies
- **Shards**: only from duplicates (5/20/65/200/600 by rarity) and the season track; spent in
  the Shard Shop (60/180/600/1900/6000). Duplicates never pay Coins. This is the existing
  separate cosmetic-credit path the brief asks for.
- **Robux**: `ShopConfig.Offers` (7 direct cosmetics, Founder pass, Season 1 premium lane). All
  ids nil in `PLACEHOLDER_IDS.lua` = "Not on sale yet". One receipt handler
  (`ProductService.ProcessReceipt`) with a purchase-id journal written in the same profile
  mutation as the grant. `ENABLE_PAID_CAPSULES = false`, no paid random route exists.
  `ProductService:CheckPolicy` reads `ArePaidRandomItemsRestricted` and fails closed.

### Cosmetics
Catalog kinds Marble (35), Trail (12 + 2 exclusive), Burst (8 + 1), Emote (8 + 2). Everyone
owns and has equipped `trail_dust` from the start: the server builds it as a fixed Trail
between two attachments on the spinning ball (`MarbleLook.Apply`), so it twists with the spin
and its length does not follow speed. Profile schema v5.

### Screens (UIController)
Title, Lobby (hub card + MENU drawer + profile pill + practice strip), TimeTrial, Race (RaceHud
strip, abilities, touch), Spectate, Results; modals Settings (GAME / DISPLAY), Loadout,
Garage, Quests, Boards, Lab (capsules / Shard Shop / season), MapSelect, Shop.

### Flags found
- Stale label: `Catalog.HowToEarn` still says "Free Coin capsules & Shard Shop (coming in
  Phase C)".
- The v31 capsule reel shows item **names** on every tile; with emote names like "Wow!" and
  "Let's go!" it reads as filler words. Replaced by the silhouette spool (milestone 3).
- Hardcoded prices: capsule costs in `CapsuleOdds.Boxes`, ability Coin prices in
  `AbilityConfig`, Shard prices in `CapsuleOdds.ShardPrice` (all server-side shared modules,
  shown from the same tables). No client-side price is invented.
- Sounds: every sound id is nil (silent by default). A speed-driven roll sound needs an audio
  id from the owner (no ids are invented); the code reads `PlaceholderIds.Sounds.Roll`.
- Not measurable here: input latency, phone frame time, section splits (no Roblox runtime in
  this environment). The perf overlay (Settings, developers) records FPS / p95 / hitches on
  the phone; the owner's readings are the baseline.

## 2. Milestones
1. Baseline and contracts — this document.
2. Racing feel and launch — free speed trail, speed FOV, speed streaks, ramp launch intro,
   Launch Animations (Garage). Physics untouched (records stay comparable).
3. Case reveal — the racing spool with silhouettes, saved-result recovery.
4. Full UI — motorsport style, phase strip, Garage / Shop / Settings rework.
5. Economy — Coins from quests only, tiered case prices, gated Robux paths.

## 3. Save migration plan (filled in per milestone)
- M2: profile v5 -> v6 adds `cosmetics.equipped.launch` (default `launch_ramp`) and the
  `launch_ramp` starter; settings add `introSkip`, `trailVisibility`, `speedStreaks`. Old
  saves keep everything; unknown values fall back to defaults.
- M5: Coin balances and owned items are kept exactly. Only *new* Coins change source.
