# godot/data: production game content

Never hand-edited (today). Everything here is read through ONE class, `DmDb` (`godot/rules/core/dm_db.gd`, static, no autoload), which
owns path, parse and cache. The older per-domain loaders are thin typed wrappers over it; production code must not open `res://data/`
itself (`godot/tests/data/run.gd` fails if it does). Test/mock data does not live here (`godot/tests/`).

## Datasets

| Dataset | Canonical file(s) | Owner accessor (wrapper) | Exporter that writes it today |
|---|---|---|---|
| Game content (one file per `src/content/*` and `src/gameplay/*Rules` module, `{ExportName: value}`, plus `computed.json` of baked function results and `manifest.json`) | `content/*.json` (78 files) | `DmDb.content(name)`, `DmDb.content_export(name, export)` (wrapper `DmContent`) | `tools/godot/export-content.ts` |
| Combat tables (abilities, affixes, armor, brews, disciplines, enemies, necro_weapons, statuses) | `combat/*.json` | `DmDb.combat(name)` (wrapper `DmCombatData`) | `tools/godot/export-combat.ts` |
| Combat/progression facts | residual `combat/progression.json` (kit, new_blood) + composed from `content/upgrades`, `ascension`, `gameplay_killChain`, `gameplay_characterStats` | `DmDb.combat("progression")` | `export-combat.ts` (writes only the residual) |
| Gathering model (skills, nodes, recipes, items subset) | `gathering/gathering.json` | `DmDb.gathering()` (wrapper `DmGatherData`, ints normalised) | `tools/godot/export-gathering.ts` |
| Covenant counsel tips | `onboarding/tips.json` | `DmDb.tips()` (wrapper `DmCounselData`) | `tools/godot/fixtures-onboarding.ts` |
| Codex rows, Gear Atlas | `panels_a/codex_rows.json`, `panels_a/atlas.json` | `DmDb.panels_a(name)` (wrapper `DmPaData`) | `tools/godot/export-panels-a.ts` |
| Exact world sim (obstacles, sight blockers) | `sim/world.json` (`d:<hex>` doubles) | `DmDb.sim_world()` (decoded, fresh copy per call) | `tools/godot/export-sim.ts` |
| Slice view-models (world layout, enemies, hero, npcs, asset list) | `slice/*.json` | `DmDb.slice(name)` (wrapper `DmData`) | `tools/godot/export-slice.ts` |
| World FX tables | `world_fx/fx.json` | `DmDb.world_fx()` (wrapper `DmWfxData`) | `tools/godot/export-world-fx.ts` |
| Progression upgrade cost curves, start areas | `progression/extras.json` (the only progression-specific facts) | via `DmDb.progression_view()` | none (hand-maintained) |
| **Loot view** (areas' loot tables, enemy gold/xp, item meta, armour sets, rune pools, legendary, depths rosters) | NO FILE: projection of `content/*` | `DmDb.loot_view()` (wrapper `DmLootData`) | none (the old `loot/content.json` writer in `fixtures-loot.ts` was removed; the fixture copy stays as the test oracle) |
| **Progression view** (areas/bosses/vows/boons/ascension/limits/chain/milestones/upgrades) | NO FILE: projection of `content/*` + `progression/extras.json` | `DmDb.progression_view()` (wrapper `DmProgContent`, ints normalised) | none (hand-maintained `extras.json`) |

## Merged (one copy of each fact)

- `loot/content.json` (deleted): identical to `DmDb.loot_view()`, verified field-by-field and by digest (recorded in `tests/data/run.gd`).
- `progression/content.json` (deleted): identical to `DmDb.progression_view()` (after int normalisation). Upgrade cost curves and start
  areas are not in `content/` so they moved to `progression/extras.json`.
- `combat/progression.json`: lost the keys `content/` already owns; `DmDb.combat("progression")` composes them back.
- `panels_a/sheet_sample.json` moved to `tests/panels_a/` (dev gallery mock only).

## Known overlaps NOT merged (different shapes, still the same facts)

`combat/abilities|armor|brews|disciplines|enemies|necro_weapons|statuses.json`, `gathering/gathering.json` (skills, nodes, recipes, seeds,
processing/alchemy/reagent recipes, meals, items subset) and `panels_a/*`, `slice/*` re-export subtrees that also exist in `content/*`
(e.g. `combat/abilities.json` `abilities` == `content/abilities.json` `ABILITIES`; `gathering.json` `nodes[]` == `gameplay_gatheringRules` `NODES{}`).
They differ in layout (snake_case keys, arrays vs maps, extra fields), so folding them needs per-file projections plus tests; left for a follow-up.

## Exporters

The `tools/godot/*.ts` exporters retire with the web build. Changed so a re-export cannot resurrect duplicates: `fixtures-loot.ts` no
longer writes `loot/content.json`; `fixtures-progression.ts` no longer writes `progression/content.json` (extras.json is hand-maintained);
`export-combat.ts` writes only the residual `combat/progression.json`; `export-panels-a.ts` writes `sheet_sample.json` to `godot/tests/panels_a/`.
Outside `data/` but also generated: `godot/game/view_models.json` (`export-view-models.ts`), `godot/assets/fx/fx_data.json` (`export-fx.ts`).
