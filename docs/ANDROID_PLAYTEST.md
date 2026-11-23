# Playtesting on Android

After a successful **Deploy** run (see SETUP.md), use either method. The experience
stays private; only you (and any collaborators you add) can join.

## Primary: Chrome → Play in Browser (Roblox Web Play beta)

Roblox opened Web Play to creators on 29 Oct 2026 as an early-access test in Chrome
on Windows, macOS and **Android**. It launches games you own or can edit.

1. On the phone, open **Chrome** (not another browser; Roblox says Chrome-based
   browsers can misbehave). Update Chrome first — the beta wants **v156 or newer**.
2. Go to **https://create.roblox.com/dashboard/creations**, open your experience.
3. On its **Overview**, tap **Play in Browser**.
   (If it's missing, switch Chrome to **Desktop site** and reload.)
4. The first launch downloads the web client and is slow; later launches are faster.
5. Turn the phone sideways (landscape).

If it fails to load: try Chrome incognito with no extensions, reload, or fall back
to the app below. "Error 256" / "Engine failed to load" are known beta issues on
Roblox's side.

## Fallback: Roblox Android app

1. Make sure the Roblox app is installed and signed in to the **same account**.
2. In Chrome, open `https://www.roblox.com/games/<PLACE_ID>` (the deploy summary
   prints this exact link) and tap **Play** — it opens the app and joins.
   Tip: bookmark that link; it's the quickest way back in after each deploy.

## What to test (Phase A1 checklist)

- [ ] You appear as a blue marble on the start pad, timer reads `0:00.00`.
- [ ] Thumbstick rolls the marble in the direction you push, relative to the camera.
- [ ] Drag on the right half rotates the camera; pinch zooms (10–45 studs).
- [ ] Jump button hops the marble (about 7 studs); no double-jump in mid-air.
- [ ] Rolling off the start pad starts the timer.
- [ ] Orange bumpers bounce you; rails keep you on the lane.
- [ ] Checkpoint strips turn green and a banner appears at each checkpoint (4 total).
- [ ] Rolling off the edge returns you to the last checkpoint within ~1 second.
- [ ] RESPAWN button → last checkpoint. RESTART button → start pad, timer resets.
- [ ] The red sweeper arm spins and knocks the marble around.
- [ ] The jump gap before the finish can be cleared (jump at the edge).
- [ ] Crossing the gold strip shows `FINISH!` with your time; best time is kept for the session.
- [ ] HUD text is readable and buttons don't overlap the thumbstick or jump button.
- [ ] Frame rate feels smooth (Roblox menu → Settings → enable "Performance Stats" if unsure).

## Web Play vs the app — what differs

Roblox lists these as unavailable in the Web Play beta: voice chat, party/friends
chat, dynamic heads/self view, video playback, screenshots/captures, **haptics**,
and switching avatars in-game. Tumble Circuit A1 uses none of them.

Roblox has not documented how Web Play handles phone touch controls. The game uses
Roblox's standard thumbstick and jump button; if those don't appear in Web Play,
the game shows its **own** stick and JUMP button after ~4 seconds (TouchFallback).
If anything still feels wrong in the browser, test the same build in the app — it's
the reference platform.

Graphics in the browser use WebGL, so lighting/shadows look simpler than in the app.
