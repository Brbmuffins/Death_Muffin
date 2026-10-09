# godot/data: production game content

JSON read through ONE class, `DmDb` (`godot/rules/core/dm_db.gd`, static, no autoload), which owns path, parse and cache. The per-domain
loaders are thin typed wrappers over it; production code must not open `res://data/` itself (`tests/data/run.gd` fails if it does).
Test/mock data does not live here (`godot/tests/`).

The files were first exported from the web game's TypeScript (`src/content`, `src/gameplay`). Those exporters and the web source are gone from
`main` (history on `legacy-web`), so the JSON here is now the source of truth and is edited by hand. Keep each fact in one place.

## Datasets

| Dataset | Canonical file(s) | Accessor (wrapper) |
|---|---|---|
| Game content (one file per content module, `{ExportName: value}`, plus `computed.json` of baked function results and `manifest.json`) | `content/*.json` (78 files) | `DmDb.content(name)`, `DmDb.content_export(name, export)` (wrapper `DmContent`) |
| Combat tables (abilities, affixes, armor, brews, disciplines, enemies, necro_weapons, statuses) | `combat/*.json` | `DmDb.combat(name)` (wrapper `DmCombatData`) |
| Combat/progression facts | residual `combat/progression.json` (kit, new_blood) + composed from `content/upgrades`, `ascension`, `gameplay_killChain`, `gameplay_characterStats` | `DmDb.combat("progression")` |
| Gathering model (skills, nodes, recipes, items subset) | `gathering/gathering.json` | `DmDb.gathering()` (wrapper `DmGatherData`, ints normalised) |
| Covenant counsel tips | `onboarding/tips.json` | `DmDb.tips()` (wrapper `DmCounselData`) |
| Codex rows, Gear Atlas | `panels_a/codex_rows.json`, `panels_a/atlas.json` | `DmDb.panels_a(name)` (wrapper `DmPaData`) |
| Exact world sim (obstacles, sight blockers) | `sim/world.json` (`d:<hex>` doubles) | `DmDb.sim_world()` (decoded, fresh copy per call) |
| Slice view-models (world layout, enemies, hero, npcs, asset list) | `slice/*.json` | `DmDb.slice(name)` (wrapper `DmData`) |
| World FX tables | `world_fx/fx.json` | `DmDb.world_fx()` (wrapper `DmWfxData`) |
| Progression upgrade cost curves, start areas | `progression/extras.json` (the only progression-specific facts) | via `DmDb.progression_view()` |
| **Loot view** (areas' loot tables, enemy gold/xp, item meta, armour sets, rune pools, legendary, depths rosters) | NO FILE: projection of `content/*` | `DmDb.loot_view()` (wrapper `DmLootData`) |
| **Progression view** (areas/bosses/vows/boons/ascension/limits/chain/milestones/upgrades) | NO FILE: projection of `content/*` + `progression/extras.json` | `DmDb.progression_view()` (wrapper `DmProgContent`, ints normalised) |

## Merged and overlapping data
- `loot/content.json` and `progression/content.json` were removed: `DmDb.loot_view()` and `DmDb.progression_view()` project them from `content/*`
  (plus `progression/extras.json` for upgrade cost curves and start areas). `combat/progression.json` keeps only residual keys.
- Not merged: `combat/*.json`, `gathering/gathering.json`, `panels_a/*`, `slice/*` re-export subtrees that also exist in `content/*` in different
  shapes (snake_case keys, arrays vs maps). A change to one must be mirrored in the other until they are folded.

## Other generated JSON outside data/
`godot/game/view_models.json` (creature model rows), `godot/assets/fx/fx_data.json` (effect tables). Also hand-edited now.

## Tests
`godot --headless --path godot --script res://tests/data/run.gd`: every dataset loads, nothing under `data/` is unregistered, no duplicates, the
merged views still match recorded digests, and no production code reads `res://data/` outside `DmDb`.

## Known gaps
- The overlapping subtrees above are still duplicated.
