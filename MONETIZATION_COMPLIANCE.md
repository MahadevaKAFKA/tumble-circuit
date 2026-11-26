# Monetization & compliance (Phase D)

Status as shipped: **nothing is purchasable.** Every product / Game Pass id in
`PLACEHOLDER_IDS.lua` is nil, `ENABLE_PAID_CAPSULES = false`, and paid random capsules have no
code path at all. The free competitive game never depends on the shop.

## What exists
| Feature | Paid? | How it is kept honest |
| --- | --- | --- |
| Race rewards, quests, season | Free | Server-verified events; atomic claims |
| Abilities | Free (level or earned Coins) | Never Robux (B2) |
| Free capsules | Earned Coins only: Marble 600, Trail 450, Burst 350, Emote 300 | One capsule per item kind; one odds function for roll + display; full tier and per-item odds (empty tiers removed and rescaled, shown that way) and the shared pity counters shown before every open; request-id replay safety (C) |
| Shard Shop | Earned Shards only | Direct choice, exact prices by rarity |
| Optional SHOP (D) | Robux, off | Direct choice of a named cosmetic; Roblox's own localized price or "Price unavailable"; lobby only; no timers, no strike-throughs, no pop-ups |
| Founder's Style Pack | Game Pass, off | Visual only; ownership re-checked with Roblox, never trusted from the client |
| Season premium lane | Season-keyed product, off | `SeasonPremium:S1` only works during Season 1 |

## Receipts (when a product is turned on)
- `MarketplaceService.ProcessReceipt` is assigned once, in `ProductService`.
- A receipt is granted inside one profile mutation that also writes its `PurchaseId` to
  `purchases.journal` (Roblox keeps no per-user developer product history, so we keep our own).
- `PurchaseGranted` is returned only after the profile save succeeds; otherwise
  `NotProcessedYet`, and the retry finds the journal entry and just saves.
- Player not in the server / profile loading / unknown product → `NotProcessedYet`.
- `PromptProductPurchaseFinished` only refreshes the display; it never grants.

## Before enabling anything paid — owner checklist
- [ ] Re-read Roblox's current developer product, Game Pass and paid-random-items documentation.
- [ ] Content maturity questionnaire updated for monetization.
- [ ] Prices set in the Creator Dashboard only; the UI fetches them.
- [ ] One real test purchase per product type by the owner; check rejoin and duplicate safety.
- [ ] Confirm that nothing sold affects speed, abilities, rewards, XP or matchmaking (it doesn't
      in code: catalog items are visual only, `MarbleLook` never changes ball physics).

## Paid random capsules — not built
If ever wanted, it needs: a separate owner decision with legal/policy review, new Developer
Products, PolicyService `ArePaidRandomItemsRestricted` checked on client AND server (fail
closed), the same `CapsuleOdds` shown before purchase including sequential pity for multi-draws,
and receipt handling that grants every draw exactly once. `ProductService:CheckPolicy` already
reads the policy each session and fails closed, but grants nothing because no such product exists.

## Responsible design rules kept
No pay-to-win, no loss-aversion copy, no fake countdowns or scarcity, no near-miss reels, no
forced shop pop-ups, no social-proof claims, no trading or cash-out, preset-text emotes only.

### The capsule opening reel (added 2026-11-26, earned-Coin capsules only)
The owner asked for a CS:GO-style opening. The server decides the item first; the reel is
only a display of that result. Filler tiles are independent draws from the same odds shown
before the open, and the three tiles on each side of the result are never rarer than the
result, so the reel never stages a "just missed a Legendary" moment. SKIP works at any time
and reduced motion shows the result at once. If paid capsules are ever considered, re-check
the reel against Roblox's paid-random-items policy before reusing it.
