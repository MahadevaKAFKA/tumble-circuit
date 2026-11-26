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

## 3. Save migration plan
- **M2 (v32):** `cosmetics.equipped.launch` (default `launch_ramp`, a starter everyone owns);
  settings `introSkip`, `trailVisibility`, `speedEffects`. Sanitizers fill defaults.
- **M3 (v33):** capsule history entries gain `seen` (old entries count as seen).
- **M4 (v34):** settings `hudAlign`, `garageFilter`.
- **M5 (v35): profile schema v5 -> v6.**
  - Coins, Shards, XP, level, items, records, purchases journal: carried over **exactly**.
  - The old shared capsule guarantee counters become the **Skin case's** counters (same
    `epicMisses` / `legendaryMisses` fields), so nobody loses guarantee progress; the other
    cases start at 0 in `capsule.pity[caseId]`.
  - `quests.milestones` added (progress starts from 0; past races are not back-filled).
  - History lines from the removed v2 Burst / Emote capsules keep their names.
  - Season odd levels already claimed keep the Coins they paid; unclaimed ones now pay Shards.
  - Rollback: `git revert` the M5 commit and redeploy. A v6 profile opened by v5 code is
    read-only (the existing newer-schema guard), so nothing is overwritten; play on v6 again
    to make it writable.

## 4. Economy (M5)
**New Coins come only from completed quests.** Races, placement, wins, the season track and
logins pay no Coins (`ProgressionConfig.RaceCoins = false`; season odd levels pay 15 Shards).
Races still give XP, levels, records, PBs and quest progress. Duplicates already convert to
Shards (a separate cosmetic credit), unchanged.

| Quests | Coins | XP |
| --- | --- | --- |
| Daily (3 per UTC day) | 100 each | 100 |
| Weekly (4 per week, Monday UTC) | 400 each | 400 |
| Milestones (one time) | 150-1000 (4,050 total) | 100-500 |

Milestones: Finish your first race (150), Finish 10 races (300), Land 10 ramp tricks (300),
Collect 25 Chaos Gates (400), Finish 50 races (800); skill goals: Podium 5 times (400), Win a
race (300), Beat a personal best 5 times (400), Win 10 races (1000).
Claims: the claimed flag and the Coins are one profile mutation (a retry or a second server
sees "Already claimed"); a finished quest left unclaimed at a reset is paid automatically in
the rollover mutation; bot practice counts for quests 3 races a day.

| Case | Tier | Price | Daily-quest equivalents | Pool |
| --- | --- | --- | --- | --- |
| STARTER | basic | 250 | 2.5 | every kind, Common + Rare |
| TRAIL | specialist | 550 | 5.5 | every trail |
| SKIN | specialist | 650 | 6.5 | every marble skin |
| APEX | high tier | 1300 | 13 | every kind, Epic / Legendary / Mythic only |

Each case has its own guarantee counter (Epic+ on the 15th, Legendary+ on the 60th; a case
that can't drop the tier gives its best tier). The server checks the odds version, the case's
counters **and the price the player saw** before spending; any mismatch spends nothing.

### Model (`Shared/EconomyModel`, assumptions to be replaced by telemetry)
Active = every daily and weekly; Casual = 2/3 dailies, 2/4 weeklies, slower milestones. "Cases"
= how many of that one case those Coins would buy.

| Pattern | Day | Coins | Starter | Trail | Skin | Apex |
| --- | --- | --- | --- | --- | --- | --- |
| Active | 1 | 450 | 1 | 0 | 0 | 0 |
| Active | 7 | 5,150 | 20 | 9 | 7 | 3 |
| Active | 30 | 19,450 | 77 | 35 | 29 | 14 |
| Casual | 1 | 350 | 1 | 0 | 0 | 0 |
| Casual | 7 | 2,650 | 10 | 4 | 4 | 2 |
| Casual | 30 | 11,050 | 44 | 20 | 17 | 8 |

Before (v31, race Coins on): about 33,000 Coins in 30 days for an active player = 55 Marble
capsules at 600. Now: 29 Skin cases at 650 (about half as often), with a cheaper basic case
and a clearly stronger, pricier Apex case.

### Robux (suggested only; nothing is listed or enabled)
Guaranteed direct items, shown with Roblox's own localized price and native confirmation:

| Offer | Suggested price | Notes |
| --- | --- | --- |
| Spring Snap launch | 79 R$ | look only, same timing |
| Afterimage Drop launch | 99 R$ | look only, same timing |
| Polished Copper / Quantum Chrome / Phoenix Ember skins | 49 / 99 / 149 R$ | |
| Ember / Rainbow trails | 59 / 99 R$ | |
| Lightning finish, Rematch? emote | 49 / 25 R$ | |
| Founder's Style Pack (Game Pass) | 299 R$ | |
| Season 1 premium lane | 199 R$ | Season 1 only |

Paid random cases: **not recommended** and not built (`ENABLE_PAID_CAPSULES = false`, no
route). Quest Coins never mix with any Robux-linked currency. If you ever want them, it needs
your separate decision and the work listed in `MONETIZATION_COMPLIANCE.md`.

### Owner steps to turn on an approved direct item later
1. Approve the SKU list and prices above (or your own).
2. Creator Dashboard > your experience > Monetization > Developer Products: create one per
   approved offer at the approved price; copy each product id.
3. Paste the ids into `PLACEHOLDER_IDS.lua` under `Products` (e.g. `LaunchSpringSnap = 123`)
   and commit; I can do this step if you send the ids (product ids aren't secrets).
4. Update the experience questionnaire for monetization; make one real test purchase per
   product type and check a rejoin (the receipt journal grants exactly once).
