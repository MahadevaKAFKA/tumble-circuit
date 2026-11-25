# Phase B–D build plan (from Build Pack v3, owner go-ahead 2026-11-25)

Owner, 2026-11-25: "After finishing those touches, you can proceed to the last phases, re-check if
everything from the A phases is in order, check the references and then proceed with BCD if
everything corresponds". The hub touches shipped as v15; the A re-check is in BUILD_STATUS.

Source of truth: `MASTER_REFERENCE_v3.md`, `ARCHITECTURE_DECISIONS.md` and
`PHASE_BCD/{B,C,D}*.md` from the pack. Each sub-gate ends with a private deploy and a
BUILD_STATUS entry, so the owner can play any of them; work carries on unless the owner says stop.

## Reference re-check (official Roblox docs, read 2026-11-25)
- Developer Products: `MarketplaceService.ProcessReceipt` is still the documented handler (one
  server script sets it). No `BindReceiptHandler` exists in the docs → D uses ProcessReceipt.
  `PromptProductPurchaseFinished` is not proof of purchase. Roblox keeps no per-user history for
  developer products → our own durable PurchaseId journal.
- Paid random items: list every outcome with numeric % (total 100%); applies to Robux-bought
  currency too. Free/earned random rewards need no disclosure (we show odds anyway).
  `PolicyService:GetPolicyInfoForPlayerAsync` → `ArePaidRandomItemsRestricted`,
  `IsPaidItemTradingAllowed`, `IsEligibleToPurchaseCommerceProduct`.
- Regional prices: `MarketplaceService:GetProductInfoAsync` (single) /
  `GetDeveloperProductsAsync`; never hard-code a price in UI.
- Parties / invites: `Player.PartyId`, `SocialService:GetPlayersByPartyId`,
  `CanSendGameInviteAsync` + `PromptGameInvite`.
- Analytics: Roblox `AnalyticsService` (`LogCustomEvent`, `LogFunnelStepEvent`,
  `LogEconomyEvent`, `LogProgressionEvent`). Our wrapper is **TelemetryService** — the pack's
  names `CollectionService` and `AnalyticsService` collide with built-in Roblox services, so the
  inventory service is **CosmeticService** and analytics is **TelemetryService**.

## B1 — worlds, map vote, Time Trial, Party
- Worlds: `TrackDefinitions.Worlds = { NeonFoundry, SkyCarnival, VolcanoVault }`, each 12–16
  segments, own `Origin`, `Theme` (palette + floor/rail material) and hazard `Style`. New hazards
  reuse the proven HazardSim kinds (same contact model, bots understand them):
  Sky Carnival — Balloon bumpers (PulseBumper), Flippers (Hammer), Bouncy drums (Trampoline),
  Wind lanes (Fan, no roof), Rotating rings (Sweeper), Pinball field. Volcano Vault — Geyser
  vents (Fan bursts), Pistons (Hammer), Rock falls (PulseBumper telegraph + falling rock visual),
  Crumbling basalt (Tiles), Stone spirals (geometry), glowing lava sheet below = fall/reset.
- All worlds built once (pooled). `TrainingTrackService:SetActiveWorld(id)` swaps the Race-zone
  layout and fires `WorldChanged`; services re-read the layout. Snapshot carries `worldId`.
- Map vote: first 8 s of Intermission when ≥ 2 queued humans; one vote per human; tie → lowest
  rotation index after the last world; no votes / 1 human → rotation. Pure `MapVote` rules.
- Time Trial: solo run on the active world for anyone not in the race; frozen start + 3 s, server
  checkpoints and time, ghost collision group (no contact with racers). PB key mode
  `TimeTrial`. Ghost = server-observed positions (5 Hz) of the PB run, stored per key; replayed
  as a non-colliding labelled ghost. Aborted (told why) if the course changes.
- Party: Roblox party (`PartyId`) members in this server, max 4, start on neighbouring grid
  slots; lobby PARTY card lists them; INVITE uses the native prompt when allowed.

## B2 — nine abilities (play-earned)
Frost Wake, Magnet, Phase, Grapple Spark, Bounce Burst, Gravity Glide, Reverse Jet, Decoy
Marble, Anchor — AbilityConfig values from the pack; unlock by level or Coins 800/1200/1600;
server cooldowns/caps; owner-motor modifiers; cleanup on respawn/round end.

## B3 — garage, cosmetics, progression, quests, leaderboards, telemetry
35 marbles (12/10/7/4/2), 12 trails, 8 finish bursts, 8 emotes, visual-only. Inventory with
schema v2 migration. Level rewards every 5 levels. 3 daily + 4 weekly quests (UTC), atomic claims.
Leaderboards (OrderedDataStore, human-only, budgeted). TelemetryService.

## C — free capsules, shards, free season
`CapsuleOdds` pure (55/30/11/3.5/0.5, pity 15/60 exact), 600-Coin free capsule, atomic open with
request id, history 20, duplicates → Shards, Shard Shop, 28-day / 30-level free season.

## D — optional commerce (all OFF), security, launch docs
Product IDs nil, prices only from GetProductInfoAsync, ProcessReceipt with a PurchaseId journal,
`ENABLE_PAID_CAPSULES = false`, PolicyService fail-closed, AntiCheatService aggregation, launch
docs. Nothing purchasable until the owner creates products and sets IDs.

## Done (2026-11-25)
B1 v16, B2 v17, B3 v18, C v19, D (this build). Details and the launch-risk report: BUILD_STATUS.

