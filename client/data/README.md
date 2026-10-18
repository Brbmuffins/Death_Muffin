# client/data: production game content

JSON read through ONE class, `DmDb` (`client/rules/core/dm_db.gd`, static, no autoload), which owns path, parse and cache. The per-domain
loaders are thin typed wrappers over it. Production code reads `res://data/` only through `DmDb`; the one exception is the combat core's loader
(`client/core/dm_core_data.gd`, used by `DmCoreHost`), which reads the files the core needs straight from disk so a test can point it at another folder.
Test and mock data does not live here.

The JSON here is the source of truth and is edited by hand. Keep each fact in one place.

## Datasets

| Dataset | Canonical file(s) | Accessor (wrapper) |
|---|---|---|
| Game content (one file per content module, `{ExportName: value}`, plus `computed.json` of baked function results and `manifest.json`) | `content/*.json` (77 files) | `DmDb.content(name)`, `DmDb.content_export(name, export)` (wrapper `DmContent`) |
| Combat tables (abilities, affixes, armor, brews, disciplines, enemies, necro_weapons, statuses) | `combat/*.json` | `DmDb.combat(name)` (wrapper `DmCombatData`) |
| Combat/progression facts | residual `combat/progression.json` (kit, new_blood) + composed from `content/upgrades`, `ascension`, `gameplay_killChain`, `gameplay_characterStats` | `DmDb.combat("progression")` |
| Gathering model (skills, nodes, recipes, items subset) | `gathering/gathering.json` | `DmDb.gathering()` (wrapper `DmGatherData`, ints normalised) |
| Covenant counsel tips | `onboarding/tips.json` | `DmDb.tips()` (wrapper `DmCounselData`) |
| Codex rows, Gear Atlas | `panels_a/codex_rows.json`, `panels_a/atlas.json` | `DmDb.panels_a(name)` (wrapper `DmPaData`) |
| Exact world sim (obstacles, sight blockers) | `sim/world.json` (`d:<hex>` doubles) | `DmDb.sim_world()` (decoded, fresh copy per call). The game reads its `cover` (the Congregation's pews, `DmBossNodeWorld`) and its `crypts` (the Grave Surges', `DmGraveSurge`, decoded once when the first director is made); its obstacles and nodes stay as generated (they lack the Acre herb spots below) |
| Slice view-models (world layout: the game's node placements; `acre_50`-`acre_53`, two Bog Myrtle and two Drowned Lotus spots in the Acre so every gathering tier has an AFK and laborer spot, are hand-added here and in `content/computed.json` `worldLayout1337` (2026-10-12), enemies, hero, npcs, asset list, `necro_gear.json`: which prop model shows which necromancer weapon kind, set mantle, helm tier and legendary set, with scale and grip hints) | `slice/*.json` | `DmDb.slice(name)` (wrapper `DmData`) |
| World FX tables | `world_fx/fx.json` | `DmDb.world_fx()` (wrapper `DmWfxData`) |
| Progression upgrade cost curves, start areas | `progression/extras.json` (the only progression-specific facts) | via `DmDb.progression_view()` |
| **Loot view** (areas' loot tables, enemy gold/xp, item meta, armour sets, rune pools, legendary, depths rosters) | NO FILE: projection of `content/*` | `DmDb.loot_view()` (wrapper `DmLootData`) |
| **Progression view** (areas/bosses/vows/boons/ascension/limits/chain/milestones/upgrades) | NO FILE: projection of `content/*` + `progression/extras.json` | `DmDb.progression_view()` (wrapper `DmProgContent`, ints normalised) |

## The combat core's numbers
No number is retyped in C++. `DmCoreData.load_all` (`client/core/dm_core_data.gd`) hands the core the enemy defs and tuning (`content/enemies.json`),
the status rules (`content/abilities.json`, `statuses.json`, `enemies.json`), the legion tuning (`abilities.json`, `fen.json`, `statuses.json`, `gameplay_legendary.json`,
`runes.json`, and `combat/enemies.json` for the damage scale) and the constants of `sim/sim_consts.gd`; the core's compiled-in defaults equal these files (native/README.md "Design",
"Numbers from data, not retyped"). The co-op messages carry a hash of the enemy defs and the numbers a puppet derives events from, so a guest on other data is refused
(native/README.md "Co-op: snapshots, events and the puppet core").

## Merged and overlapping data
- The loot and progression views are projected by `DmDb.loot_view()` / `DmDb.progression_view()` from `content/*` (plus `progression/extras.json`); `combat/progression.json` keeps only residual keys.
- Not merged: `combat/*.json`, `gathering/gathering.json`, `panels_a/*`, `slice/*` re-export subtrees that also exist in `content/*` in different
  shapes (snake_case keys, arrays vs maps). A change to one must be mirrored in the other until they are folded (a known duplication).

## Other JSON outside data/
`client/game/view_models.json` (creature model rows) and `client/assets/fx/fx_data.json` (effect tables).

## Tests
`client/tests/code_load.gd` parses every JSON file; `client/tests/core_thralls.gd` holds the core's compiled-in defaults to these files.
