# Ranked Circuit — opt-in test (v39)

Code: `ReplicatedStorage/Shared/RankRules.lua` (model), `ServerScriptService/Services/RankService.lua`
(seal / finalize / persistence), `Controllers/RankController.lua` (MORE > RANKED card),
tests in `src/Tests/Unit/Ranked.spec.lua`.

## Rating model
* For every eligible player: Σ over the other eligible **humans** of (actual − expected), where
  actual = 1 ahead / 0 behind / 0.5 tie and expected = 1 / (1 + 10^((Rb − Ra)/400)), using one
  immutable snapshot of ratings taken when the roster is sealed (Preparing).
* Δ = K × Σ / (opponents) — normalized, so a field size never changes what a place is worth.
  K = 48 for the first 5 results (placement), then 24. Whole points. Start rating 1000.
* Tiers: Bronze < 900 ≤ Silver < 1050 ≤ Gold < 1200 ≤ Platinum < 1350 ≤ Diamond < 1500 ≤ Elite.
  Fewer than 5 results = "Placement n / 5".
* Never inputs: bots, purchases, Coins, cosmetics, level, races played, bot wins.
* Simulation (200 six-player races, skill 1–6 + noise): strongest ≈ 1400, weakest ≈ 600 —
  separates the field without running away.

## Eligibility and recovery
* A round is ranked only if Ranked is enabled, **every** queued human opted in, and there are
  **≥ 4** of them (tunable `RankRules.MinHumans`). Otherwise it is a normal Casual race and the
  card says why ("needs 4 ranked players (n queued) — Casual races continue").
* Ranked ruleset: no bot fill, no Chaos Gate comeback boosts, no abilities. Trails and launch
  animations stay visual only.
* DNF (timeout or quitting mid-race) ranks behind every finisher, tied with other DNFs.
* Fewer than 4 humans at the seal, or no finalized result → no rating change (neutral).
* Results apply per player **idempotently by match id** (`JobId:roundId`); a player who left
  gets the result applied on rejoin to this server; an unsaved result shows "pending", never a
  made-up number. Season `S1`; rollover = disclosed soft reset halfway to 1000.

## Limits of this test (known)
* Unsettled results live in the server's memory: a player who leaves and joins a *different*
  server before the round ends loses that round's result (neutral). A durable match record
  (DataStore / MemoryStore) is the next step if Ranked goes beyond a test.
* No cross-server matchmaking: Ranked rides the normal queue (no second always-open queue).

## Turning it on publicly (owner)
`RankService.Config.PublicDiscovery = true` only after: ≥ 4 concurrent opted-in players are
common at peak, 50+ ranked rounds were completed without a stuck or duplicate result, and the
tier spread looks sensible. Until then the card says "test".
