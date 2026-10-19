# client/sim: shared sim data classes and pure helpers

Pure classes `client/next/` uses: no nodes, no rendering. Positions are floats on the XZ plane. There are no per-creature records or enemy brains here: the combat core owns enemies, thralls, corpses and zones (native/README.md "Design").

| file | role |
|---|---|
| `nav.gd`, `nav_obstacle.gd` (`DmNav`, `DmNavObstacle`) | walkable rects + door corridors, obstacle push-out, A* last leg. Points are `[x, z]` Arrays. Still used by the Depths floor generator (obstacle bounds), the gather loop (through `NavShim` in `client/next/gathering/dm_next_gather.gd`, which answers from the world's navigation map) and the auto-combat decision code (which gets no `DmNav` in the game: client/next/feel/README.md); bodies walk on the navigation server's map and the core's own copy of it |
| `depths_floor.gd`, `sim_depths_rules.gd` | Catacomb Depths floor layout and the depth formulas (data in `client/data/content/depths.json`) |
| `sim_data.gd` (`DmSimData`) | shared content lookups used widely (enemy defs, areas, drops) |
| `sim_consts.gd` | constants (`BOSS_RADIUS`, `PLAYER_RADIUS`, `AGGRO_RANGE`, ...); `DmCoreData` reads the numeric ones for the combat core |
| `boss_state.gd` | the boss state record the brains and the host read 1:1 (field names are camelCase on purpose) |
| `fdlibm.gd`, `sim_math.gd`, `sim_exact.gd` | V8-exact trig / hypot and exact-double JSON loading (still used by the Depths floor generator, auto-combat and `DmDb`; see KNOWN-GAPS.md "Leftovers from the web era") |
| `bosses/` | the seven boss brains, see `bosses/README.md` |

Data: `client/data/sim/world.json` (nav colliders, crypts, nodes, pew cover). Load it with `DmSimExact.load_json`, not `JSON.parse_string`; the game reads its `cover` and its `crypts` (client/data/README.md).

## Why the numerics are odd (read before simplifying)
- `Math.hypot` and libm trig differ from V8's in the last bit; the brains compare distances and pick nearest/equal targets, so one ulp
  can flip a tie. `DmSimMath.hypot` and `DmFdlibm` reproduce V8.
- Do not use `Vector2` for sim data (float32).
- Godot's JSON parser and GDScript float literals are not correctly rounded past 12 significant digits. Exact doubles are stored as
  `"d:<16 hex digits>"` strings; `DmSimExact.decode` restores them.

## Tests
`client/tests/depths.gd` plays the Depths' rules without a game (floors per seed, quota, pacing, rosters) and its floors in the game scene; `client/tests/bosses/run.gd` replays the recorded scenarios of every boss through the brains.
