# Monetization & compliance (Phase D)

Status as shipped: **nothing is purchasable.** Every product / Game Pass id in
`PLACEHOLDER_IDS.lua` is nil, `ENABLE_PAID_CAPSULES = false`, and paid random capsules have no
code path at all. The free competitive game never depends on the shop.

## What exists
| Feature | Paid? | How it is kept honest |
| --- | --- | --- |
| Race rewards, quests, season | Free | Server-verified events; atomic claims |
| Abilities | Free (level or earned Coins) | Never Robux (B2) |
| Cases | Earned Coins only (Coins come only from quests): Starter 250, Trail 550, Skin 650, Apex 1300 | One odds function for roll + display; every item and its chance shown before each open (tiers a case can't drop are removed and rescaled, shown that way); a guarantee counter per case; the server re-checks the odds version, the counters and the price you saw (any mismatch spends nothing); request-id replay safety |
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

### The capsule reveal: "racing spool" (2026-11-26, earned-Coin capsules only)
The server chooses the item and saves it (with the Coin debit, exactly once per request id)
before anything plays; the reveal only shows that saved result. Six masked marbles race on a
mini track and the chosen one crosses the reveal line first; only it is unmasked. Every
entrant is a neutral silhouette of its outline family (marble pattern, trail profile, burst,
emote): colours, materials, names and rarity are hidden, the same shape is the same mask at
every rarity, and fillers are independent draws from the odds shown before opening, so the
race can't stage a near-miss or hint that opening again changes anything. Timing, camera
cuts, SKIP, MUTE and the display RNG never touch the reward. Reduced motion shows the result
at once; Low graphics shows a single-camera ribbon of the same masks. A result whose reveal
wasn't shown (left the game, lost connection) is kept as "unseen" and plays, free, the next
time the Lab opens; marking it seen grants and charges nothing. If paid capsules are ever
considered, re-check this against Roblox's Paid Random Items rules first.
