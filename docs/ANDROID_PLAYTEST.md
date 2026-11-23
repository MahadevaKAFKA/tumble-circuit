# Playtesting A1 on Android (no Studio)

After a successful **Deploy** run (see [SETUP.md](SETUP.md)), use either method. The
experience stays private: only you, plus any collaborators you add, can join.

## Primary: Chrome → Play in Browser (Roblox Web Play beta)

Roblox opened Web Play to creators on 29 Oct 2026 as an early-access test in Chrome on
Windows, macOS and **Android**. It launches games you own or can edit.

1. On the phone, use **Chrome** (Roblox says other Chromium browsers can misbehave),
   updated to **v156 or newer**.
2. Open **https://create.roblox.com/dashboard/creations** → your experience.
3. On its **Overview**, tap **Play in Browser**. (Missing? Chrome ⋮ → **Desktop site**, reload.)
4. The first launch downloads the web client and is slow. Turn the phone sideways.

If it won't load: Chrome incognito, no extensions, reload — or use the app below.
"Error 256" / "Engine failed to load" are known beta issues on Roblox's side.

## Fallback: Roblox Android app

1. Roblox app installed and signed in to the **same account**.
2. In Chrome open `https://www.roblox.com/games/<PLACE_ID>` (the deploy summary prints
   this exact link) and tap **Play** — it opens the app and joins. Bookmark it.

## Touch controls (A1)

| Control | Where | What it does |
| --- | --- | --- |
| **Stick** | Touch anywhere in the lower-left area, then drag | Steer left/right; push up to roll faster, down to hold back |
| **BRAKE** | Big button, bottom right | Hold to slow down (each new press cuts ~35 % more) |
| **RESET** | Smaller button left of BRAKE | **Hold 1 second** (yellow bar fills) → back to the start pad |
| **CAM** | Above BRAKE | Switch Chase / Wide camera |

There is only ever one stick (Roblox's default stick and jump button are turned off). A1 has
no jump — the marble stays on the track.

## What to check (Phase A1)

- [ ] Night sky, neon course, title **TUMBLE CIRCUIT / CHAOS DROP** with **PLAY PRACTICE**.
- [ ] Tap PLAY PRACTICE → steering card. Drag left and right → both turn green, "Nice steering!" (or SKIP).
- [ ] Exactly one stick appears where your thumb lands; BRAKE / RESET / CAM on the right; nothing overlaps the timer (top) or speed (bottom).
- [ ] Stick left/right moves the marble left/right on screen; the coral/yellow stripes visibly roll.
- [ ] Roll through **START** → timer runs.
- [ ] S-turn: camera follows smoothly, never flips.
- [ ] Pulse bumper goes cyan → yellow → coral; touching it while coral kicks you away.
- [ ] Banked drop: camera tilts down to show the drop; BRAKE controls your speed.
- [ ] Cross **FINISH** → "FINISH!" with your time; **TRY AGAIN** restarts.
- [ ] Fall off → "Fell off - back to the start pad" after about 1 second.
- [ ] Hold RESET 1 s → back to the start pad; a short tap does nothing.
- [ ] Smoothness: if unsure, plug in a keyboard and press **F2** for the frame-time overlay, or use
      the Roblox menu → Settings → Performance Stats.

Write down anything odd, with the device and method (browser or app), in BUILD_STATUS.md's test ledger
or just tell Claude.

## Web Play vs the app

Roblox lists these as unavailable in the Web Play beta: voice chat, party/friends chat, dynamic
heads/self view, video playback, captures, **haptics**, switching avatars in-game. A1 uses none.
Graphics use WebGL, so lighting and bloom look simpler than in the app.

A1 draws its **own** touch stick and buttons from raw touch events instead of relying on
Roblox's default mobile controls, so it doesn't depend on how Web Play implements those. It also
switches to the touch layout the moment a finger touches the screen, in case Web Play misreports
the phone as a keyboard device. If the browser still feels wrong, the app is the reference.
