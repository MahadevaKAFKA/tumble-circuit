# Tumble Circuit: Chaos Drop

## Claude implementation prompts

Attach this file to Claude with the current project checkout. Start with **01**. After it reports the baseline, run **02–07 in order**, then choose an expansion map or polish prompt. Apply one prompt per runnable milestone. Prompts 08–15 describe distinct playable maps with separate hubs. Prompts 16–24 deepen effects, UI, performance, and launch presentation. Keep the existing phase checklist and call out any requested milestone that would cross a still-active phase gate.

### Shared implementation contract

> Work in the existing Roblox/Luau project. Start from the actual checkout and read its README, architecture notes, phase status, Rojo config or Studio workflow, and any local instructions. Use existing naming and services where viable. The playtest shows Orbital Garage, a practice chute, Neon Foundry, marble abilities, bots, and a mobile HUD. Verify which are wired in the current build. Keep the current marble rig, camera, race timing, checkpoints, finish validation, bots, profile data, and input controls working. Follow the existing server/client authority model. Keep physics and race rules deterministic where the current design requires them. Treat cosmetics and visual effects as presentation. Preserve the original playable build as the fallback. Use original or owner-approved assets, local source paths, and verified Roblox asset IDs only. Do not publish or add monetization.
>
> Each task ends with working project changes or an explicit blocker, a concise changed-file list, exact Studio test steps, actual test results, and a status entry in the existing build notes. Clearly distinguish Studio execution, device emulation, static checks, and tests still pending. Do not mark a map playable until a full human playthrough and a bot check succeed on its main route. Report regressions and recovery steps before moving to the next prompt.

## Foundation and first playable slice

### 01 · Audit and establish the baseline

> Inspect the real checkout. Trace spawn → Orbital Garage → practice → queue → grid → countdown → race → results → return. Find where the map ID, world geometry, lighting, spawn transforms, practice chute, progress, bots, and input overlay are defined. List hardcoded Neon Foundry references and identify the minimal seam for a map registry and per-map hub loader. Capture a repeatable baseline for Solo, Studio Start Server with two clients, and a phone test if accessible. Include track visibility, FPS/frame time, memory, respawn and loaded instance count. Report the actual phase and plan the smallest reversible changes for prompt 02. Change implementation only to repair a blocker that prevents measuring the baseline, then report it.

### 02 · Extract a map and hub registry

> Extract the current Neon Foundry and Orbital Garage definitions into the project’s existing configuration style. Every map entry must provide a stable ID, display name, map/route builder, matching hub builder, visual profile, default spawn, practice entry and return points, grid, finish, and preview metadata. Keep client-visible metadata separate from server-owned state and geometry. Validate duplicate IDs, missing builders, unreachable checkpoints and invalid transforms on load. Keep the old map ID and existing records compatible. Load Neon Foundry through the new path with identical race behavior and a fallback to the known-safe playable map if a new builder fails.

### 03 · Add map selection, voting, and queue transitions

> Build a three-action Map Selection flow available from the spawn hub and other hubs: **Visit Hub**, **Practice**, and **Vote for Next Race**. Use actual map names, preview stills only if available, difficulty, and a one-line obstacle description. Start with a single shared race queue so destinations do not split the player base. Visiting or practicing is a personal choice and must not change the server race map. At intermission the server resolves one eligible ballot per connected player, ignores duplicate/stale requests, counts only eligible maps and uses a deterministic tie-break. Solo can choose a validated course and start through the normal race flow. Handle joins during voting/countdown/racing, leaving mid-vote, the timer ending while the selection UI is open, rapid destination changes, reconnects, map load failure and party members arriving at different times. Reuse existing party behavior if implemented. Test with two clients making different personal choices and voting simultaneously.

### 04 · Build a distinct hub per map

> Implement a hub lifecycle independent of the global race state. Use separately authored safe hub zones/builders within the existing place for the first milestone, unless the current architecture already has a tested place-routing solution. One hub should not reset another player’s camera, spawn or environment. Each hub needs its own silhouette, materials, landmark, unique short practice obstacle, clear spawn-to-queue route, spawn-to-selector route, and readable view toward its map theme. Share interaction contracts for Map Selection, queue, and practice. Keep Orbital Garage as the default hub associated with Neon Foundry. Bring racers to the winning map’s grid through the normal flow, and return them to their chosen hub after results. If the chosen hub fails, land them at Orbital Garage and preserve race results. Verify visual profile changes only affect the correct client or zone and unwind on leaving.

### 05 · Rebuild the Neon Foundry visual language

> Keep the race line and existing checkpoint geometry. Give the track a dark-navy chassis, broad cool-blue rolling surface, crisp cyan rail insets, violet checkpoint frames, and an amber warning material with patterned edge marks. Add visible metal panel breaks, industrial spine supports, a distant turbine landmark, switchbacks revealed by depth lighting, and accessible lane arrows. Move strong emission to small surfaces so the marble stays readable against rails. Preserve the cobalt marble with coral and gold bands. Capture a gate, a wide descent, a hazard approach, and a tight turn from the ordinary player camera on low and high settings.

### 06 · Make Orbital Garage a real destination

> Turn the current circular platform into a foundry observation deck with a central violet ring, cyan edge lights, a track-facing window or overlook, a practice entrance, a map selector kiosk and a clear queue lane. Keep the existing garage, quests, party and time-trial entries discoverable where they already work. Place the selector near spawn, keep physical traversal short, provide a direct mobile button, and allow practice immediately while waiting. Use static hologram panels for navigation on low settings. Block race triggers inside the hub and test camera/input after repeatedly entering and leaving practice.

### 07 · Finish a two-map vertical slice

> Implement Sky Carnival (prompt 08) as a complete second-map proof. Ship it behind the existing development or feature gate until both hub and race pass the lifecycle tests. Demonstrate a player choosing Sky Carnival’s hub while a friend remains in Orbital Garage, both entering the same next race, and each returning to the expected hub afterward. Compare loading, frame times and memory to the single-map baseline. Test a failed theme load, disabled map card, missing practice spawn, and queue continuity when one client leaves. Keep the registry ready for additional maps without hand-editing unrelated services.

## Map briefs

Run one of these prompts at a time with the shared contract. Build each around a hand-authored main route, an optional shortcut with a readable tradeoff, and a recovery line. For main-route sections, connect validated ports and check clearance against the current four-stud marble diameter. Branches rejoin at the intended checkpoint and work for bots. Target the existing race-duration envelope and treat timings as playtest hypotheses. Each hub must present its map’s skill in a short, forgiving practice lane.

| Map | Dedicated hub | Main course skill | Palette |
| --- | --- | --- | --- |
| Neon Foundry | Orbital Garage | Banking and sweeper timing | `#10172D` navy, `#27D7F5` cyan, `#A078FF` violet, `#FFD45A` warning |
| Sky Carnival | Balloon Terminal | Bounce control and landing | `#28468D` blue, `#FFF2CB` cream, `#A0E9CE` mint, `#F08BAE` rose |
| Volcano Vault | Basalt Inspection Deck | Burst timing and braking | `#292329` basalt, `#FF7047` lava, `#FFBD5D` amber, `#DDE8F1` ash |
| Tideworks | Dry Dock | Lateral steering | `#123A54` ocean, `#43B9B2` teal, `#F9D5A0` sand, `#F57C70` coral |
| Frostline Freight | Glacier Depot | Grip management | `#16293E` indigo, `#9FDCF0` ice, `#F1F7F7` snow, `#F6B448` warning |
| Clockwork Canyon | Canyon Lift Station | Reading mechanical cycles | `#4C3028` rock, `#C8874A` copper, `#F3D293` sand, `#63C8BD` teal |
| Prism Gardens | Greenhouse Atrium | Choosing routes early | `#173D39` green, `#AADB7A` lime, `#E8A5CF` orchid, `#D8EFE8` glass |
| Lunar Relay | Relay Hangar | Carrying momentum over gaps | `#181C31` ink, `#D5D9E8` silver, `#6A9DFF` blue, `#F3A96A` amber |
| Pinball Metro | Terminal Arcade | Precision ricochets | `#20243A` slate, `#FF6D8A` rose, `#5CDDC4` mint, `#F9DC78` gold |

### 08 · Sky Carnival and Balloon Terminal

> Build an aerial carnival with cloud silhouettes, paper ribbons, balloon bumpers, bouncy drums and ring landmarks. Sequence the route from a broad canvas ramp into a drum field, around a banked pinball turn, across a controlled bounce and onto a striped finish deck. Provide a slower solid bridge next to the bounce shortcut. The hub is a brightly lit boarding terminal with canvas awnings, a tethered balloon landmark, and a wide target-landing practice drum. Use arrows plus landing targets. Keep airborne corrections within current control tuning and protect the first landing with roomy rails.

### 09 · Volcano Vault and Basalt Inspection Deck

> Build a descending obsidian spiral with basalt ribs, steam vents, a clearly telegraphed piston lane, staggered geysers, and an ash-lit finish mouth. Mark the safe line with chevrons and the risky fast route with repeated warning stripes. Use a steam puff and hazard motion before a lane changes state. Theme the hub as a high inspection deck with a furnace window, amber instrument panels and one slow demonstration piston. Make lava legible as a recovery boundary and use the established checkpoint reset flow. Avoid full-screen orange haze.

### 10 · Tideworks and Dry Dock

> Build stacked dry spillways, lock-gate ramps, a mild cross-current section and a wide wavebreak chicane. Give gates a visible hinge, a progress strip and a safe bypass. Keep scenic water distinct from collidable surfaces. Use the existing force model only if it can represent a gentle authored push; otherwise build the first version without a new physics rule. Build the hub around a dry basin, crane silhouettes and a low-speed side-push practice lane. The orange hull markers should read without transparency or reflections on low graphics.

### 11 · Frostline Freight and Glacier Depot

> Build a mountain freight run with an exposed slope, protected snow tunnels, clearly bounded low-grip ice runs and a rescue lane with ordinary grip. Use texture, chevron direction, and shard-edge markers to communicate surface transitions. Keep grip behavior tied to the existing material handling and configure per section rather than changing global marble tuning. Build a sheltered timber depot hub with a short braking lane, visible catch barrier, warm lighting, and a dispatch board. Prove players can stop on touch controls and recover before the first branching ice segment.

### 12 · Clockwork Canyon and Canyon Lift Station

> Build terraced sandstone chutes, a large skyline gear, counterweight gates, a timed gate straight, and a predictable descending corkscrew. Offer a wide exterior route with long sight lines and a narrow inner route with a faster cycle. The hub is a cliffside lift station with a stationary exposed flywheel, safe timing exhibit, and shaded departure lane. Hazard cadence comes from the server’s round clock. The first obstacle should teach a single pattern before the final route combines patterns.

### 13 · Prism Gardens and Greenhouse Atrium

> Build a glasshouse course with layered planters, prismatic arches, an S-turn through trellises and three visibly distinct lanes that rejoin at the same checkpoint. Use unique lane symbols and physical separation so colored glass cannot confuse path choice or hide collisions. Give each branch distinct corner radius and line difficulty. Build an atrium hub with a central specimen tree, sunlit map boards and a three-lane decision drill. On low graphics use tinted opaque surfaces and a simple sky instead of stacked transparency.

### 14 · Lunar Relay and Relay Hangar

> Build a ridge-side lunar transmission course with open skies, dish silhouettes, clean platform-to-platform gaps and a stable maintenance route alongside them. Add a marked take-off lane and wide landing receivers. Prefer authored ramps and present-day air control. If a low-gravity experiment is later approved, isolate it to the map’s supported mechanics and verify that all competitors use the same effective rules. The hub is an airlock hangar with striped bays, a dish vista, and a short first-jump lesson. Prove fallback behavior when the player misses the launch speed window.

### 15 · Pinball Metro and Terminal Arcade

> Build a subway-inspired arcade of switch ramps, visible bounce angles, rubber bumpers and a staggered bumper bank leading into a broad finish bend. Give the safer line a smooth bypass and the precision route useful ricochets without requiring pixel-perfect hits. Make the hub a terminal concourse with one contained bumper drill, platform signage and a central map-selection board. Keep active bumpers visually obvious from more than one approach direction. Enable clip-friendly sparks through the shared VFX system.

## Effects, color, presentation, and QA

### 16 · Build a reusable map color and lighting system

> Define a visual profile per map for sky, ambient, exposure, shadows, haze, surface materials, rails, checkpoints, safe line, warning and finish. Assign a consistent shape/icon language for safe, warning and boost across palettes. Load profiles on transitions without carrying old post effects, sky, audio, or lighting between hubs or races. Calibrate from ordinary player-camera footage on each quality tier. Use readable depth, surface detail, and strong silhouettes before adding more emission. Include a low-bloom profile and grayscale checks for active obstacles.

### 17 · Rebuild marble materials and player identification

> Upgrade surface finish with clean light response, highlights that follow lighting, recognizable band silhouettes, and a shadow or contact cue. Differentiate nearby rivals by palettes and patterns. Always preserve hitboxes, mass, friction, and ownership for every appearance. Make local player recognition work through silhouette, optional marker and cosmetic pattern. Thin out overlapping rival labels and hide distant labels. Keep clear BOT identification in results and use one concise label during races where readable.

### 18 · Add event-based race VFX

> Hook visual feedback into existing Boost, Shield, checkpoint, hard contact, trick landing, recovery, and finish events. Specify lifetime, priority and distance for each. Use short cyan streaks for Boost, violet segmented ring for Shield, a restrained checkpoint pulse, brief contact sparks, a landing ripple and a directionally readable recovery effect. Pool or reuse short-lived emitters and avoid per-frame allocation. Prefer client rendering, and preserve the authoritative ability/race state. Use tiny and bounded camera impulses or disable them in reduced-motion mode. Test eight crowded starts and rapid respawns for visual leaks.

### 19 · Improve hazard tells, cues, and sound

> Give every hazard a distinct silhouette and three readable phases: ready, warning, active. Communicate the hit region using striping, movement and a pre-impact sound. Keep an accessible visual tell when sound is muted. Keep timing aligned to the authoritative hazard phase, especially for late joiners. Avoid rapid flashes and persistent noise. Separate short effects from map ambiance and use verified or project-owned assets only. Test approach visibility on small touch displays and a high-speed line.

### 20 · Clean up the mobile HUD and map cards

> Use the provided playtest layout as the baseline and separate racing from hub UI. During races prioritize position, next checkpoint and time plus reachable Brake, Boost, Shield and recovery controls. Keep camera, lists, emotes and social features out of the steering lanes unless opened. In hubs show one clear Play/Join action and easy access to the map selector, practice, garage and quests. Keep controller focus predictable and use safe insets for system controls. Fix overlapping bot tags, keep debug telemetry developer-only, and use meaningful disabled states. Test small phone landscape, desktop and controller, plus reduced motion.

### 21 · Design entrances, race results, and spectator camera

> Give every map a distinct spawn reveal and a two-second optional pre-race camera framing. Keep switching and skipping safe for all inputs and return steering reliably. Build results around real placement, true checkpoint state and real participant type. Give each hub a themed podium view while preserving one shared results layout. Reuse the existing spectator path, avoid spoiling unvisited shortcuts during racing, and handle leave/disconnect and failure states gracefully. Keep transitions quick enough to repeat.

### 22 · Profile all quality tiers and map transitions

> Establish Low, Medium and High profiles with the same track surfaces, collision, tells and race timing. Reduce particle counts, trails, shadows and distant scenery first on Low. Use target-device profiling with a solo run and a crowded start, not Studio emulator alone. Use the baseline median and p95 frame times, memory at spawn and after repeated transitions, loaded instance counts, and peak particle load. Sweep hub visits, practice, race, reset, spectator, leave and return until stable. Document exact hardware and paths measured. If no device is accessible, mark the performance target unverified.

### 23 · Add a repeatable track and hub playtest matrix

> Extend existing validation to assert map IDs, spawn clearances, safe return transforms, reachable checkpoints, route rejoin timing, branch finish eligibility and bot waypoint reachability. Include cases for solo/two-client race, fast repeated map selection, leaving during countdown, stale vote, practice during an active race, checkpoint recovery, dirty visual state after map changes and rollback when assets fail. Add real Studio steps to the build notes and record each result by map. Track standard and shortcut runs separately, and keep any unfinished map off public rotation.

### 24 · Capture honest promotion and map select artwork

> Add a Studio-only capture workflow with debug HUD hidden, bounded camera presets and a consistent marble appearance. Recreate the current Neon Foundry race, its starting grid, and Orbital Garage practice entrance as real screenshots. Capture one clean hero image per completed map and one lower-resolution map card per validated route. For future-map concepts, keep files in a concept folder until the corresponding courses are playable. Keep the production game unaffected. Export originals and verify crop, readability, game title spelling, and asset ownership. Use 1920 × 1080 thumbnails and a square icon at least 512 × 512. See [Roblox thumbnail specifications](https://create.roblox.com/docs/production/publishing/thumbnails) and [Roblox icon specifications](https://create.roblox.com/docs/production/publishing/experience-icons).
