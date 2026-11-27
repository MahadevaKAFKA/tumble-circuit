# Shop and microtransactions (v42)

Source brief: *Tumble-Circuit-Shop-and-Microtransactions-Claude-Master-Prompt* (owner,
2026-11-26). **Paid offers are OFF.** Nothing can be bought with Robux until you approve the
prices and paid activation (the last section lists exactly what's needed).

## The launch catalog

| Offer (stable sku) | Grants | Section | Proposed price (preview only) |
|---|---|---|---|
| Gridline (`gridline`) | `plate_gridline`: results nameplate with a checkered corner accent | Driver Profile | 39 Robux |
| Reactor Glass (`reactor_glass`) | `reactor_glass`: dark blue glass shell, amber core | Marble | 79 Robux |
| Afterburn Ribbon (`afterburn_ribbon`) | `trail_afterburn`: thin orange twin ribbons that lengthen with speed | Trails | 79 Robux |
| Victory Pulse (`victory_pulse`) | `podium_victory_pulse`: a brief gold ring around the winning marble on the results podium | Celebrations | 99 Robux |
| Pit Crew Pack (`pit_crew_pack`) | Reactor Glass + Afterburn Ribbon + Gridline | Featured | 149 Robux |

All five are **permanent Game Passes** (one-time, durable): ownership is checked with Roblox on
join, after each prompt, and when the shop opens while a purchase is still verifying. Grants are
idempotent and never remove an item owned from another source. The ten D1 offers (Developer
Products, Founder's Pack pass, Season 1 lane) are unchanged and now sit in the matching sections.

Visual only, like every cosmetic: the marble's size, mass, grip and collision never change;
trails use the existing speed-driven trail (length reacts to speed; speed comes from the race);
Victory Pulse shows only on the results podium, never during a race.

## How the storefront works

- **MORE › SHOP** (hub) or **Garage › SHOP · MORE LOOKS** (opens on the matching section).
- Tabs: FEATURED · MARBLE · TRAILS · CELEBRATIONS · DRIVER PROFILE, then **CASES · COINS**
  (yellow, separate: earned-Coin cases with VIEW ODDS, unchanged). **OWNED** filter chip.
- Detail panel: what it grants (with [OWNED] marks), the price, ownership and equip state, and a
  preview: Reactor Glass in 3D (drag to rotate), Afterburn on a short loop (SPEED SLOW / FAST),
  Victory Pulse on a neutral backdrop, Gridline as the plate. **MOTION: OFF** stills them.
- Bundles show what you already own, the combined price of the missing standalone items when
  known, and a prominent "cheaper separately" route when it is. Savings are stated only when the
  prices shown to you prove them. Owning everything hides the purchase action.
- Button states: Loading price · Price unavailable (checkout disabled) · BUY · N Robux ·
  Verifying purchase · Owned · EQUIP · EQUIPPED · Not on sale yet · PREVIEW BUY (owner only).
- After a verified grant: a small receipt with **EQUIP** (EQUIP ALL for the pack) or LATER.
- The client only asks (`RequestShopPurchase`); the **server** checks the listing, ownership
  and pending state, then opens Roblox's own prompt. No prompt ever opens on its own
  (dismissals, races and respawns never reopen one), and none opens for an offer you own.

## Equip, races, results

- New equip slots: **Plate** (results nameplate) and **Podium** (podium effect); Garage gets
  PLATES and PODIUM tabs. Everyone owns the free Standard Plate and "No podium effect".
- At the start of each race the server takes a **validated snapshot** of every racer's equipped
  cosmetics (unowned or unknown ids fall back to the free default). Respawns keep that look; the
  results podium shows each racer's plate (Gridline's checkered corner) and the winner's Victory
  Pulse, for everyone watching. Reduced Motion shows one steady ring instead of two pulses.
- Other racers' trails follow the existing budget (distance, count, Low graphics) and the
  Driving setting **Trails: All / Mine / Off**.
- There is no replay system in the game yet, so "in replays" has nothing to attach to.

## Owner preview (works on your phone today, no Robux)

Because you don't use Studio, the preview purchase also works in the live private game for the
**account that owns the experience** (Studio would get it too). Nobody else sees it.

1. Open the private game on your phone → **MORE › SHOP** → FEATURED.
2. Pick an offer: the price line says *PREVIEW · proposed N Robux · not on sale*.
3. Tap **PREVIEW BUY · NO ROBUX** → the receipt appears → **EQUIP**.
4. Race: the look is snapshotted at the start; win a race to see Victory Pulse; your plate shows
   on the podium.
5. **RESET PREVIEW BUYS** (top of the shop) takes back exactly what previews added. Items you
   own from anything else stay.

If the experience is owned by a **group** rather than your account, the preview stays hidden
(the check is "creator is this user"). Tell me and I'll switch it to your user id.

## What you need to provide before paid activation

1. **Approve prices** (the 39 / 79 / 79 / 99 / 149 above are proposals).
2. In the Creator Dashboard → your experience (universe 10778638702) → **Monetization → Passes**,
   create five passes: Gridline, Reactor Glass, Afterburn Ribbon, Victory Pulse, Pit Crew Pack.
   Each needs a name, a short description, an **icon image** (512×512; I can make simple
   original icons if you want) and, once approved, a price with **On Sale** switched on.
   Optional: turn on **regional pricing** for each; the shop always shows Roblox's own price for
   the player.
3. Send me the five pass ids (they are not secrets) or paste them into `PLACEHOLDER_IDS.lua`
   → `GamePasses` (keys `Gridline`, `ReactorGlass`, `AfterburnRibbon`, `VictoryPulse`,
   `PitCrewPack`).
4. Tell me to switch **`ShopConfig.Flags.PaidOffers = true`**. From then on the owner preview
   turns off automatically and real checkout opens Roblox's purchase prompt.
5. Making the experience public is still a separate decision, only with your approval.

## Not built yet (slots designed, never listed)

Map collections (Foundry Shift, Sky Carnival enamel, Volcano obsidian), the one-time Supporter
Pack, replay card frames, visual-only boost flares. Paid random items stay disabled.

## Analytics (aggregate, existing telemetry)

`shop_view`, `checkout_start`, `purchase_confirmed`, `purchase_cancelled`, `purchase_failed`
(reason), `preview_grant`, `shop_item_equip`.
