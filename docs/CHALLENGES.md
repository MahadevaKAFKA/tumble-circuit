# Challenges, mastery and race stories (brief 4, v40)

Source brief: *Tumble-Circuit-Challenges-Cups-and-Creator-Tools-Master-Prompt* (owner, 2026-11-26).
Status words: **Done** = built and covered by offline checks that actually ran ·
**Implemented, untested** = needs a Roblox runtime · **Not done** = said so plainly.

## The small loop: The Drop Shaft

| Piece | What it does | Status |
|---|---|---|
| Course | `TrackDefinitions.DropShaftChallenge` (layout v1): start pad → launch slope → brake zone with a right-side kicker (the precision entry) → lip → 16° shaft → wide landing with a QUALIFYING LINE sign → banked 150° split hairpin (inside fast, outside safe) → exit → finish basin. 785 studs, 3 gates. Built once on the server at (1300, 640, −200), away from the maps. | Done (generates + validates offline); **feel untested** |
| Entry | MORE › CHALLENGE opens the card. TRY places you frozen on the start (everyone gets the same spot, heading and slope), 3-2-1-GO, then a free marble. An attempt sits you out of the next race; JOIN RACE ends it. | Implemented, untested |
| Judging | The same server checkpoint judge as races (ordered gates, plausible sweeps), the server's own clock, the same monitor. The client only displays. | Done (mock attempt offline) |
| Retry | A fall, a reset, a missed gate or the 90 s limit ends the attempt ("Failed"); the marble waits frozen on the start. **RETRY** is one tap: a 2 s countdown, no hub trip. | Done (mock) |
| Records | Best time, best medal (never downgraded) and gate splits are saved in the profile under the challenge key `drop_shaft|r1|R1|s1`. A course or rule revision changes the key, so old times never mix with new ones. Times under 8 s are never a best. | Done (mock) |
| Medals | Gold 21.00 · Silver 24.00 · Bronze 28.00 s. **Provisional**: from the model (≈17 s flat-out) plus margins. They need real attempts before they mean anything. | Provisional |
| Splits | At each gate: the signed delta against your best run's gate time (green = ahead). | Done (mock) |
| PB ghost | The server's own samples of your best valid run (5 Hz) replay as a mint PB GHOST. Stored in the existing ghost store (DataStore `TumbleGhosts_v1`, memory in Studio). | Done (mock); playback untested |
| Friend ghost | Off by default. **SHARE MY GHOST** (card or result) marks your stored PB ghost as shared. A friend **in the same server** racing the same challenge version then sees it in yellow with your name. A new PB ghost starts unshared again. When there is none, the attempt says: "No friend here has shared a ghost for this version – racing your own best". Cross-server friend ghosts are **not done** (one DataStore read per friend; not worth it before real use). | Done (mock) – same-server only |
| Codes / invites | Card → CODE box → `DROP1` (case-insensitive). Join launch data with a code opens the card on arrival. Codes are routing hints resolved against the allowlist on the server – never a time, an entry or ownership. | Done (mock); launch data untested |
| Weekly Challenge | UTC weeks from Monday 2025-12-01; the rotation is the Drop Shaft until more challenges exist. Each week's board is an OrderedDataStore `TCChal_drop_shaft_r1_W<week>` (best time per player, ms ascending). The card shows the week, "ends in …" and the top 10. Studio / mock data shows "Weekly boards are live-server only". | Implemented, untested (live DataStore) |
| Result card | "THE DROP SHAFT · 24.81 s · SILVER", NEW BEST (was …), SIGNATURE LINE when earned, the share line "The Drop Shaft · 24.81 s · Beat my time (code DROP1)", SHARE MY GHOST, RETRY, QUIT. | Done (text); layout untested |
| Clean Capture | Card toggle. While you drive it hides the challenge buttons and the top HUD (touch controls stay), keeps a small timer (RETRY, QUIT and the result card come back when the attempt ends), and draws a **9:16 guide** (shaded side bands + a thin frame) for vertical clips. The game records nothing and posts nothing – you record with your phone. | Done (guide maths); look untested |

## Map mastery (Neon Foundry)

Three goals → **Foundry Exhaust** trail (Epic, mastery-exclusive), granted once.

| Goal | Evidence (server-side) |
|---|---|
| Clean Circuit | Finish all three laps of a Neon Foundry race with no reset, fall or movement rejection (RoundService counts recoveries per racer). |
| Fast Sector | A Drop Shaft finish at or under the gold time. |
| Signature Line | A Drop Shaft finish where the first landing after the lip is at or past the qualifying line (landing = first floor contact after being airborne past the lip). |

Sky Carnival and Volcano Vault have a Clean Circuit goal each and no reward yet (rewards wait
for their own validated goals).

## Rival gap and the race story (races, not challenges)

- **Signed gap at every gate:** the server keeps each gate's crossing order (interpolated times).
  You see "+0.84 to MIA (P2)" (coral) when you cross behind someone, "−1.20 SAM behind" (mint)
  when someone crosses behind you, "P1 AT THIS GATE" when you lead. A **RIVAL +0.84** tag sits
  on the marble just ahead of you for 6 s.
- **Story line** on your results card, built only from server data: e.g. "Climbed from P6 to
  P2 · clean race · best lap 1:04.2 (lap 2)", "Led every gate, start to finish", "Started P2,
  finished P7 – 3 recoveries cost you", "Out of time after 4 recoveries".

## Not done in this pass (said plainly)

- **Stunt Lab** (a free-play trick sandbox): not started. It needs its own space and trick
  scoring design; the challenge loop came first as the brief's delivery order asks.
- Cross-server friend ghosts; Sky Carnival / Volcano challenges; the Foundry Cup final (see
  docs/FOUNDRY_CUP.md – rules only, staging).
- The Time Trial weekly ghost/splits from brief 3 D are covered by the challenge loop for the
  Drop Shaft; the map-wide Time Trial keeps its own PB ghost as before.
