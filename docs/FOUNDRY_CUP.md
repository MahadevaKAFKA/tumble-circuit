# Foundry Cup — pilot design (staging, v40)

**Status: Staging.** Rules are fixed in `ReplicatedStorage/Shared/CupConfig.lua` and covered by
offline checks. Nothing in the live game runs a cup yet, and nothing is announced to players.

## Format

1. **Qualifier** – the Drop Shaft Weekly Challenge for the cup's week. Best valid,
   server-timed attempt per player (the weekly board that already exists). The top **12**
   qualify; ties go to whoever set the time first.
2. **Final** – three 3-lap races on the Neon Foundry circuit under the Ranked ruleset (no
   abilities, no bots, no comeback boosts). Points per race: 25 · 18 · 15 · 12 · 10 · 8 · 6 ·
   4 · 2 · 1; a DNF scores 0. Tiebreak: more wins, then the better best finish, then the
   qualifier time.
3. **Prizes** – none in the pilot. A cosmetic badge may be proposed later. No Robux, no paid
   entry, nothing purchasable. Any prize needs the owner's approval first.

## What a real final still needs (not built)

- A way to gather the 12 qualifiers at one time: a reserved server
  (`TeleportService:ReserveServer`) opened at a published time, with an allowlist of the
  qualifiers' user ids, plus a fallback for no-shows (run with whoever arrives; empty seats
  are not filled by bots).
- A scheduler (the owner's call on the day and time) and a notice in the hub.
- An admin view to start, pause or void a race (disconnects, a bug).
- The qualifier board needs the time a record was set to break ties; the current weekly board
  stores only the time (ties then fall back to user id).

## Why staging first

The weekly board has not been used by real players yet and the medal times are provisional.
The pilot should run only after a few weeks of real Drop Shaft times show the qualifier is
fair on phones as well as PCs.
