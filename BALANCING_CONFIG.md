# Balancing — where every number lives

All values are starting hypotheses; change them in one place, the specs re-check ranges.

| What | File | Key |
| --- | --- | --- |
| Marble movement, brake, air control, free roam | `src/ReplicatedStorage/Shared/PhysicsConfig.lua` | `Movement`, `Ball` |
| Camera, free look | `src/ReplicatedStorage/Shared/GameConfig.lua` | `Camera`, `Camera.FreeLook` |
| Round timers, bots, READY vote, grid | `src/ReplicatedStorage/Shared/RaceConfig.lua` | `Timers`, `Bots`, `Ready` |
| Abilities (cooldowns, values, unlock level / Coins) | `src/ReplicatedStorage/Shared/AbilityConfig.lua` | `Abilities.<Id>` |
| Tricks, slipstream, near miss, charge | `AbilityConfig.lua` | `MicroSkills` |
| Worlds, hazards, checkpoints, gates | `src/ReplicatedStorage/Shared/TrackDefinitions.lua` | `NeonFoundry`, `SkyCarnival`, `VolcanoVault` |
| Map vote window | `src/ServerScriptService/Services/MapVoteRules.lua` | `VoteSeconds`, `MinHumans` |
| Time Trial | `src/ReplicatedStorage/Shared/TimeTrialRules.lua` | `CountdownSeconds`, `MaxSeconds`, `GhostHz` |
| Coins / XP per race, levels | `src/ReplicatedStorage/Shared/ProgressionConfig.lua` | |
| Quests and rewards | `src/ReplicatedStorage/Shared/QuestConfig.lua` | `Daily`, `Weekly`, `Rewards`, `BotQuestRaces` |
| Cosmetics, level rewards | `src/ReplicatedStorage/Shared/Catalog.lua` | `LevelRewards` |
| Capsule odds, pity, cost, Shards | `src/ReplicatedStorage/Shared/CapsuleOdds.lua` | `Base`, `EpicPity`, `LegendaryPity`, `Cost`, `DuplicateShards`, `ShardPrice` |
| Season dates, XP, free track | `src/ReplicatedStorage/Shared/SeasonConfig.lua` | `Seasons`, `XpPerLevel`, `CosmeticRewards` |
| Optional shop offers (no prices) | `src/ReplicatedStorage/Shared/ShopConfig.lua` | `Offers`, `SeasonPremium` |
| Product / pass ids, paid capsule flag | `PLACEHOLDER_IDS.lua` | `Products`, `GamePasses`, `ENABLE_PAID_CAPSULES` |
| Anti-cheat thresholds | `src/ServerScriptService/Services/AntiCheatService.lua` | `Thresholds`, `HalfLifeSeconds` |

Changing odds: edit `CapsuleOdds` only — the Capsule Lab reads the same module, and the C specs
check the tables sum to 100%. Bump `CapsuleOdds.Version` so open clients refresh before opening.
