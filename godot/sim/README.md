# godot/sim: shared sim data classes and pure helpers

The headless WorldSim, caster, snapshot and mirror were deleted on 2026-10-09 with the old DmGame path. What stays are the pure
classes the rebuild (`godot/next/`) still uses. No nodes, no rendering. Positions are floats on the XZ plane.

| file | role |
|---|---|
| `nav.gd`, `nav_obstacle.gd` (`DmNav`, `DmNavObstacle`) | walkable rects + door corridors, obstacle push-out, A* last leg. Points are `[x, z]` Arrays |
| `depths_floor.gd`, `sim_depths_rules.gd` | Catacomb Depths floor layout and the depth formulas (data in `data/content/depths.json`) |
| `sim_data.gd` (`DmSimData`) | shared content lookups used widely (enemy defs, areas, drops) |
| `sim_consts.gd` | constants (`BOSS_RADIUS`, `PLAYER_RADIUS`, ...) |
| `sim_enemy.gd`, `sim_thrall.gd`, `sim_corpse.gd`, `sim_zone.gd`, `boss_state.gd` | plain entity records; field names are camelCase on purpose (the boss brains and the host read them 1:1) |
| `fdlibm.gd`, `sim_math.gd`, `sim_exact.gd` | V8-exact trig / hypot and exact-double JSON loading |
| `bosses/` | the seven boss brains, see `bosses/README.md` |

Data: `godot/data/sim/world.json` (nav colliders, crypts, nodes, pew cover). Load it with `DmSimExact.load_json`, not `JSON.parse_string`.

## Why the numerics are odd (read before simplifying)
- `Math.hypot` and libm trig differ from V8's in the last bit; the brains compare distances and pick nearest/equal targets, so one ulp
  can flip a tie. `DmSimMath.hypot` and `DmFdlibm` reproduce V8.
- Do not use `Vector2` for sim data (float32).
- Godot's JSON parser and GDScript float literals are not correctly rounded past 12 significant digits. Exact doubles are stored as
  `"d:<16 hex digits>"` strings; `DmSimExact.decode` restores them.

## Tests
`godot --headless --path godot --script res://tests/sim/run.gd` is meant to replay golden fixtures (`tests/sim/fixtures/*.json`, gitignored)
for `DmNav`, the depths floor and fdlibm. The fixture generators (`tools/godot/fixtures-sim.ts`, `gen-fixtures.sh`) were deleted, so on a clean
checkout the suite prints "fixtures missing" and exits 1. Needs fixing or removing; see KNOWN-GAPS.md.

## Known gaps
- No working sim suite (above).
- `sim_thrall.gd` and `sim_zone.gd` are only referenced by `game/dm_event_fx*.gd`.
