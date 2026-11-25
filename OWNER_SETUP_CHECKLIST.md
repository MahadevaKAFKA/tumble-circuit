# Owner setup checklist (Phase D) — things only you can do

Everything below happens in the Roblox **Creator Dashboard** (create.roblox.com) or on GitHub,
from a browser or your phone. No Studio needed. Nothing here is done for you: the build ships
private, with **every product off**.

## A. Before anyone else plays (private testing — current state)
- [ ] Play builds 16–20 on your phone (B1, B2, B3, C, D) and report anything odd. BUILD_STATUS
      lists exactly what has and hasn't been run in Roblox.
- [ ] Two-account test: map vote, Party Race, Frost Wake / Magnet on a real rival, weekly-win
      leaderboard (needs 2 humans), receipts never needed here.
- [ ] Season dates: `src/ReplicatedStorage/Shared/SeasonConfig.lua` → `Seasons`. Season 1 is set
      to Mon 23 Nov – Mon 21 Dec 2026 (UTC). Change or add seasons there; ask me to deploy.

## B. Before making the game public
- [ ] **Experience Questionnaire / content maturity** (Creator Dashboard → your experience →
      Audience / Questionnaire). Answer for what is really in the game: cartoon marble racing, no
      violence, no chat beyond Roblox's own, preset-text emotes, **free random capsules bought with
      earned in-game Coins only**. Re-answer if you ever enable anything paid.
- [ ] **Policy / legal review of the free capsules** (Phase C). They cost earned Coins only and
      show full odds, but Roblox's rules and local laws on random rewards change — read the
      current Roblox paid-random-items page and your country's rules before launch.
- [ ] Privacy & age: the game stores Coins/XP/cosmetics/best times in DataStores and shows display
      names on leaderboards. No personal data is collected by us.
- [ ] Server size: the experience's max players. Keep it at what has been measured (see
      BUILD_STATUS performance); don't raise it to 20 without a 16+ player test.
- [ ] Thumbnails / icon / description: briefs and copy in `docs/LAUNCH_KIT.md` (make real
      screenshots from the game — none are invented).
- [ ] Visibility: only you switch the experience to Public (Creator Dashboard → Settings). After
      that, the Deploy workflow refuses to publish updates unless you tick `allow_public` when you
      run it — so an update never goes live by accident.

## C. Optional: turning on the cosmetic shop (only if you want it)
Nothing in the game needs it. Every offer stays "Not on sale yet" until you do this.
1. Creator Dashboard → your experience → **Monetization → Developer Products → Create**. One per
   offer you want (names below are suggestions; pick your own prices — the game shows Roblox's
   price, never one written in code):
   `MarblePolishedCopper`, `MarbleQuantumChrome`, `MarblePhoenixEmber`, `TrailEmber`,
   `TrailRainbow`, `BurstLightning`, `EmoteRematch`, `SeasonPremium_S1` (Season 1 only).
2. **Monetization → Passes → Create**: `FounderPack` (permanent; trail + 2 emotes + Founder tag).
3. Copy each new id (a number) into `PLACEHOLDER_IDS.lua` → `Products` / `GamePasses`
   (uncomment the line, e.g. `TrailEmber = 1234567890,`). Send me the ids or edit on GitHub;
   then Deploy.
4. Test one purchase yourself (it costs real Robux; a refund is your call) and confirm: the item
   appears, rejoining keeps it, buying again is impossible / shows OWNED.
5. A new season needs a NEW premium product (`SeasonPremium_S2` …) — the S1 product never
   unlocks later seasons.

## D. Never (not in this build, and not without a separate, informed decision)
- `ENABLE_PAID_CAPSULES` stays `false`. There is no paid random code in the game at all.
- No selling Coins or Shards for Robux, no trading, no cash-out.
