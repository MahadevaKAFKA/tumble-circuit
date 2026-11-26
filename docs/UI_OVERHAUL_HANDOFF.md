# Tumble Circuit: Chaos Drop

## UI and map environment overhaul

**Paste this entire file into the Claude conversation that holds the current Tumble Circuit build.** Attach the latest playtest screenshot if Claude has not seen it.

> Work directly in the latest playable Tumble Circuit: Chaos Drop build. Implement this overhaul in the existing project. Start by inspecting the actual UI, map registry, active phase, and preference code. Replace the player-facing HUD, add functional customization in Settings, and replace the black backdrop with a distinct environment for every implemented map. Start with Neon Foundry and Sky Carnival, then apply the same system to the other maps actually present in the project. Keep unsupported concepts off the playable rotation. If working in chat without project access, return a file-by-file patch against the current files Claude can verify, and name anything still needed. Preserve supported actions, authoritative mechanics, and the existing installation workflow. Show screenshots and list actual test results.

## Replace the HUD in place

The screenshot shows several issues that can be verified in Studio. The next race appears in two places, lobby buttons occupy a large area during movement, the player marble blends into the floor, and the track edges are much brighter than the track surface. Prove each improvement with the same camera angle, at phone-landscape scale.

| Screen | Default surface | Where secondary actions go |
| --- | --- | --- |
| Map hub | One map and queue card with the current hub, next race, countdown, and Join or Leave Queue. Keep Maps and Settings reachable. | Garage, quests, party, time trial, and emotes live in a hub drawer or contextual interaction. Profile, XP, and coins appear in a collapsed profile drawer. |
| Practice | Keep relevant movement, speed, and the practice objective. | A visible Exit Practice button restores the previous hub state and focus. |
| Countdown | One central readiness cue and the actual selected course. | Hide unnecessary lobby overlays. Respect the existing input lock. |
| Racing | Compact place, time, and checkpoint strip. Put movement on one side and Brake, Boost, Shield, and Trick on the other where those actions are supported. | Camera cycling and standings go in a small menu. Keep the existing deliberate reset action reachable and show its hold state. |
| Spectating and results | Spectate with clearly named target controls. Results show real placement and the next meaningful action. | Restore focus and camera on exit. Keep party, replay, and requeue behavior wired to their current services. |

Design the new UI around restrained surfaces, readable typography, and a single primary accent. Use spacing and weight to separate actions. Keep the race line and player marble unobscured. Honor Roblox reserved insets, touch targets and controller selection. Disable debug telemetry in the default player view and preserve the developer toggle where available. Keep the old HUD behind a local development flag until parity passes. Connect events once through the existing HUD controller. Avoid adding a second queue listener or a second ability remote.

## Add real player preferences

Add a Settings view reachable from every mode that safely allows menus. These are presentation-only settings. Use the existing profile/save path for independently validated individual preferences. Do not add an unrelated datastore if an existing settings store can be extended. Keep existing settings and progression data compatible. Preload sensible defaults, merge only recognized keys, clamp numeric values, and tolerate old or unavailable saves. Apply visual changes locally without waiting for a round restart. Debounce writes and make reset available with an obvious preview of the default layout.

| Setting | Default and acceptance |
| --- | --- |
| HUD size | 100%. Preview 85–125% in bounded steps. Keep controls within safe insets on phones. |
| Panel opacity | 95%. Keep essential race text legible throughout the 75–100% range and on bright skies. |
| Control layout | Use the current default. Mirror the touch control groups for left-handed mode while keeping Roblox system areas clear. |
| HUD density | Standard retains optional speed and labels. Compact preserves position, checkpoint, timer, and critical actions. |
| UI accent | Follow map, cyan, amber, violet, or neutral. Preserve collision, boost, route, and warning meanings through shape and labels. |
| High contrast | Increase panel separation and text readability without changing world logic. |
| Reduced motion | Remove optional HUD pulses, shake, and cinematic sweeps. Preserve hazard timing cues and camera controls. |
| Scenery detail | Low, Standard, High. Reduce distant decor, emitters, shadows and transparent layering first. Keep the route, lighting readability, and hazard tells consistent. |

Handle mobile cancellation, app focus loss, entering menus during a gesture, and resetting settings during any safe menu state. Make a controller and keyboard pass through Settings, Maps, race controls, and results. Confirm preferences persist after respawn and rejoin, and that two clients can choose different preferences in one race.

## Give each map its own backdrop

Use a map environment profile keyed by the existing map ID. Include the shared art direction for its hub and course, with separate local staging for each. Build sky, middle-distance landmarks and near-track framing as separate elements. Give the road a visible midtone, keep emission narrow, and use silhouettes and edge accents for depth. Leave the start approach, lanes, intersections and finish legible in the normal camera. Keep atmospheric and architectural decoration non-colliding, non-touching and out of race queries where supported. Keep dense background detail off Low while retaining each map’s signature landmark.

| Map | Hub landmark and practice framing | Course background |
| --- | --- | --- |
| Neon Foundry | Orbital Garage overlooks assembly arms and the main turbine. Make the deck and practice chute read as separate surfaces. | Cobalt dusk, layered factory silhouettes, suspended catwalks, and a cool-blue track face with narrow cyan guide lights. |
| Sky Carnival | Balloon Terminal has a ticket canopy and tethered balloons above the practice drum. | Peach daylight, floating islands, layered cumulus clouds and bunting, with clear sky behind each landing. |
| Volcano Vault, if implemented | Basalt Inspection Deck overlooks a vent field from a warm sheltered platform. | Smoky copper sky, stepped basalt ridges and distant lava channels. Preserve a neutral, contrasting race surface. |
| Tideworks | Dry Dock looks across booms, locks and a lowered basin. | Sea-glass water, cranes, distant breakwaters, and sunlit coastal structures. |
| Frostline Freight | Glacier Depot frames a timber shelter against a pine valley. | Pale alpine sky, fir silhouettes, layered snow peaks, and a visibly darker track. |
| Clockwork Canyon | Canyon Lift Station has a flywheel and suspended passenger platform. | Sandstone terraces, sunset haze, gear silhouettes, and distant lift lines. |
| Prism Gardens | Greenhouse Atrium is built around a specimen tree and glass ribs. | Sunlit greenhouse vaults and layers of foliage, with solid, clearly separated route panels. |
| Lunar Relay | Relay Hangar has a lit airlock and dish vista. | A blue-gray lunar ridge, distant antennas, soft silver light and a restrained planetary disk. |
| Pinball Metro | Terminal Arcade frames a station concourse and contained play lane. | Purple-hour skyline, transit trestles, cream station lighting and rose signage accents. |

Start with Neon Foundry and Sky Carnival. Wire other entries only when the corresponding map exists and passes its normal checks. Transition through a loading state if required. Every map change should release stale client-only visuals, sound, tweens and event connections. Confirm that visiting one hub does not switch lighting for other players in another hub or active race.

## Verify in Studio

1. Audit the current state, map IDs, UI entry points and preference schema. Capture untouched screenshots and measure frame time before changing anything.
2. Wire the new HUD and settings with the current world. Test Hub, Practice, Race, Spectate, Results, reset, late join, touch cancellation and respawn. Verify each visible control invokes its real handler once.
3. Add the two environment profiles and check settings at normal and low detail. Repeat map switching with two clients across different hubs. Check that settings, timing, route validation, camera and map vote survive the transitions.
4. Capture matched phone-landscape, desktop and controller screenshots. Include a bright background, a dark course, minimum and maximum HUD scale, and low detail. Report what ran and what remains unverified. Keep build migration reversible until the UI and maps pass together.
