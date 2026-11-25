# Playtesting on Android (no Studio)

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

## Current build: A6 — the Phase A closing build

Everything from A5 still applies. A6 adds:
- **Spectator Chaos Vote:** once you've finished (or sit out), a vote panel appears during the
  race every ~20 s: **Turbo Fans** or **Bouncy Bumpers**. The winner changes the course for 8 s
  for whoever is still racing (bots included).
- **Quick emotes:** GG / Nice Save! / Oops! buttons in the lobby column; a bubble pops over your
  marble. You can mute them in SETTINGS.
- **Perfect Dodge** message when you skim past the sweeper or hammer without touching it, and
  finish confetti (off with Reduced Motion).
- **Hub podium:** the top three of the last race stand on the podium as marbles with name tags,
  plus a podium arch, a showcase pedestal and light pylons.
- Clearer hazard cues: bumpers show "!" / "KICK", falling tiles change look before they drop.

### What to check (A6, solo with bots)
- [ ] Finish first, then watch: the vote panel appears; tap an option; the banner says which
      won and bots react (faster fans or bouncier bumpers) for 8 s.
- [ ] Emote buttons work in the lobby; the bubble shows over your marble.
- [ ] After results, the podium in the hub shows the top three.
- [ ] Skim the sweeper or hammer → "Perfect Dodge".
- [ ] Nothing from A1–A5 broke (bots leave at GO, READY/"Waiting for players", look around,
      Coins saved after rejoin).

## A5 — UI flow, profile, Coins/XP, saving

Everything from A4 still applies. A5 adds:
- **Lobby column** (right side): your LEVEL and XP bar, Coins, races and wins, and whether your
  progress is saved; **LOADOUT** (choose your two abilities) and **SETTINGS** (reduced motion,
  camera, music/sound, steering sensitivity, graphics).
- **Results screen**: podium, your place and time, personal best, and the Coins/XP you earned.
  PLAY AGAIN or SIT OUT closes it. A bot that didn't finish shows how far it got (`DNF CP 3/8`).
- **Saving**: Coins, XP, level, settings and loadout are saved to your Roblox account. While the
  game is private, only your own progress is stored.
- Rewards need real input during the race (a marble left alone earns nothing); racing only with
  bots gives full Coins for 3 races a day, then a little less.
- The stats box has a **BOTS** line while bots race: how many are moving, the best checkpoint
  they reached, and why any respawned. If bots misbehave, a screenshot of that line says why.

### What to check (A5)
- [ ] Lobby: level/XP/Coins show and the save line says your progress is saved.
- [ ] LOADOUT and SETTINGS open and close; a change sticks after you leave and rejoin.
- [ ] Bots leave the grid at GO with you (BOTS line: "7 racing, 7 moving").
- [ ] Finish a race: results show your reward; Coins go up in the lobby; leave and rejoin → still there.
- [ ] READY / "Waiting for players" and looking around still work as in A4.

## A4 — Neon Foundry, hazards, bots, Chaos Gates

The race is now the full **Neon Foundry** (16 sections, see ROUTE_MAP.md): moving hazards
(bumpers, a rotating sweeper, fans, a trampoline, falling tiles, a swinging hammer, a conveyor),
a split lane, a drop shaft, and four **Chaos Gates** (half-lane arches: drive through for a speed
surge, bigger if you're behind). When you race alone, **7 bots** (`[BOT]` names) fill the grid.

Your two requests are in this build too:
- **Look around:** steer with your left thumb and drag anywhere else on the screen (not on a
  button) with your right thumb. The camera swings back behind the marble 1.5 s after you let go.
  Looking never changes where the marble goes.
- **READY vote:** while the race isn't full, the countdown runs with "Waiting for players (n/16)"
  under it. When every slot is taken, a **READY** button appears under SIT OUT; when everyone is
  READY the race starts straight away.

### What to check (A4, solo with bots)
- [ ] The grid has you + 7 `[BOT]` marbles; GO releases everyone and your marble moves at once.
- [ ] Ride the whole Foundry: does each hazard read clearly (colour warns before it acts)?
- [ ] Race time for 3 runs (target 90–150 s). Tell me if it's much shorter.
- [ ] Drive through a Chaos Gate → surge message; driving back through gives nothing more.
- [ ] Bots finish or recover; none sit stuck for long. After you finish, results come within ~10 s.
- [ ] Look around while racing (right thumb drag) — smooth, no fighting with the stick.
- [ ] Hub/HUD say "Waiting for players (1/16)" under the countdown; no READY button solo.
- [ ] Stats box: second line = server numbers; note FPS and hitches with 8 marbles.

## A3 — abilities and micro-skills

Everything from A2 still applies (hub, automatic rounds, results). A3 adds:

- **Two ability buttons** (above BRAKE, bottom right) during a race. You start with **BOOST**
  (+30% speed for 1.6 s, 20 s cooldown) and **SHIELD** (blocks one Pulse or bumper kick, 2.5 s,
  28 s cooldown). The dark fill drains as the cooldown runs out.
- **ABILITIES panel** in the hub (upper left on a phone): tap a slot to swap in **PULSE** (nudges
  rivals within 12 studs, 26 s cooldown). It is hidden during races.
- **TRICK button** (left of RESET, race only): jump the green kicker on the left half of the long
  straight and tap TRICK in the air → spin, "TRICK! +15% speed", and both cooldowns drop 1.5 s.
- Small speed rewards you earn by playing well: **NEAR MISS** (pass close to the bumper while it's
  yellow or coral without touching it) and **SLIPSTREAM** (follow another marble; needs two players).
- **REDUCED MOTION** switch in the ABILITIES panel turns off the camera widening and the trick spin.

### What to check (A3, solo)
- [ ] Hub: ABILITIES panel shows BOOST and SHIELD; tapping a slot cycles it; it doesn't get in the
      way of steering in the practice chute.
- [ ] Race: both ability buttons show READY after GO. BOOST visibly speeds you up, then the
      button counts down. SHIELD shows a violet shell; touching the coral bumper with it on → no
      kick, "Shield blocked it!".
- [ ] Tapping an ability on the grid, in the hub or after finishing → "Abilities work during a race".
- [ ] Trick ramp: jump + TRICK → reward. TRICK on flat ground → "Can't trick here".
- [ ] NEAR MISS appears once when you skim past the bumper.
- [ ] Three rounds in a row: no leftover trails, shells or speed at the next GO; abilities READY
      again each race.
- [ ] Stats box: no new hitches when using abilities.

Pulse and Slipstream need a second player to test properly; that can wait.

## A2 — multiplayer rounds

You join in the **Orbital Garage** hub (round glass platform). The **practice chute** loops back
to the hub so you can roll while you wait. Every round runs on its own, and one player is enough:

1. **NEXT RACE IN 15** on the hub board (intermission).
2. Everyone queued is placed on the start grid, frozen (2 s), then **3-2-1** and **GO!**: the
   coral gate opens.
3. Race the training course: three checkpoints flash as you pass them, with your place on screen.
   Falling off or holding RESET puts you back at your last checkpoint.
4. **RACE RESULTS** for 12 s, with **PLAY AGAIN** / **SIT OUT** (either one closes the panel), then
   back to the hub. The next race starts about 15 s later.

You're in every race unless you choose to sit out. The button at the top right always says what a
tap does: **SIT OUT** while you're in, **JOIN RACE** while you're sitting out.

Extra touch control in A2: **LIST** (above RESET) shows or hides the standings. When you sit out,
the **SPECTATE** and **< >** buttons let you watch someone else's marble.

The small stats box (top left) is on for private playtests. If its second line ever lists a
hitch, send a screenshot.

### What to check (A2)
- [ ] You spawn in the hub, the board counts down, the practice chute works and brings you back.
- [ ] Grid → 3-2-1 → GO: you can't move before GO and can move right after it.
- [ ] Each checkpoint flashes once, in order; the finish shows your time and place.
- [ ] Fall off / hold RESET mid-race → back at your last checkpoint (not the start).
- [ ] Right after GO the marble moves at once, with no reset needed.
- [ ] Results screen: PLAY AGAIN and SIT OUT each close the panel with a message; three rounds in a row with no stuck state.
- [ ] Hub: SIT OUT → button becomes JOIN RACE → tap → you race in the next round.
- [ ] LIST button shows the standings during a race.
- [ ] **Errors:** type `/console` in chat, open **Log**, and check **Client** and **Server**
      (you see the server log because you own the game). Screenshot any red lines.

Two-player checks (bumping, placement between players) need a second Roblox account that can
join the private experience. That can wait until later.

## A1 reference

## Touch controls (A1)

| Control | Where | What it does |
| --- | --- | --- |
| **Stick** | Touch anywhere in the lower-left area, then drag | Steer left/right; push up to roll faster, down to hold back |
| **BRAKE** | Big button, bottom right | Hold to slow down (each new press cuts ~35 % more) |
| **RESET** | Smaller button left of BRAKE | **Hold 1 second** (yellow bar fills) → back to the start pad |
| **CAM** | Above BRAKE | Switch Chase / Wide camera |

There is only ever one stick (Roblox's default stick and jump button are turned off). A1 has
no jump — the marble stays on the track.

## What to check (Phase A1, practice course only)

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
