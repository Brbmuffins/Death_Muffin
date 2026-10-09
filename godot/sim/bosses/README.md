# godot/sim/bosses: the seven boss brains

Pure GDScript brains (no nodes, no autoloads) for Prelate, Gravedigger King, Bone Abbess, Drowned Congregation, Plague Saint,
Cinder Regent and Mire Mother. Numbers come from `godot/data/content/bosses.json`, `fen.json`, `abilities.json`, `difficulty.json`.
The scene side is `godot/next/bosses/`.

| file | role |
|---|---|
| `boss_brain.gd` (`DmBossBrain`) | shared machinery: awaken, damage + Fracture + Withered, stagger clock, phases at 60% / 30%, telegraph + resolve loop, wipe reset, defeat, arena leash |
| `prelate_brain.gd` ... `mire_brain.gd` | one brain per boss (`_think`, `_resolve`, `_tick`, `_on_phase`) |
| `boss_brains.gd` (`DmBossBrains`) | `make(world, id)`, `make_all(world)`, `BOSS_IDS` |
| `boss_world.gd` (`DmBossWorld`) | the only view of the world a brain sees; the host subclasses it |
| `boss_geom.gd`, `boss_pending.gd` | angle / segment / box helpers, the `DmBossPending` telegraph record |

## The host side
`next/bosses/dm_boss.gd` builds a brain with `DmBossBrains.make(world, boss_id)`; `next/bosses/dm_boss_node_world.gd`
(`extends DmBossWorld`) is the live world view over the scene nodes. See `godot/next/bosses/README.md`.

`DmBossWorld` methods (defaults report "not implemented"): `now()`, `difficulty()`, `echoes()`, `rand()`, `area_level()`, `emit(ev)`,
`players()`, `player_count()`, `cover()`, `spawn_enemy()`, `enemy_get()`, `enemies()`, `set_enemy_hp()`, `remove_enemy()`, `thralls()`,
`damage_thrall()`, `corpses()`, `remove_corpse()`, `hostile_toxic_zones()`, `add_hostile_pool()`, `ember_pool()`. Read `boss_world.gd`
for exact signatures. Public brain API: `awaken(by, empowered)`, `damage(amount, by, fracture)`, `stagger(seconds)`, `update(dt)`,
`resume()`; Abbess also `niche_ids()` / `standing_niches()`, Congregation `covered(x, z)`.

## Tests
- `godot --headless --path godot --script res://tests/bosses/run.gd` replays 44 committed scenarios (`tests/bosses/fixtures/*.json.gz`,
  recorded, frozen: no generator) through the brains on `tests/bosses/fake_world.gd` and compares every tick within 1e-9.
- `tests/bosses/adapter_run.gd` and `mock_sim.gd` are stale (below); do not rely on them.
- Scene-level behaviour: `tests/next_bosses/`.

## Notes
- There is no enrage timer; the "faster" cadence is the per-phase `fast` multiplier.
- JS `Array.sort` stability is kept via `DmStableSort` (nearest-two Burial targets, Mire corpse order).

## Known gaps
- `tests/bosses/adapter_run.gd` references `res://sim/boss_controller.gd` and the deleted `DmBossFactory` / `DmWorldSim`; it skips itself. `mock_sim.gd` serves only it.
