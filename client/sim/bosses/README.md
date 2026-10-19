# client/sim/bosses: the seven boss brains

Pure GDScript brains (no nodes, no autoloads) for Prelate, Gravedigger King, Bone Abbess, Drowned Congregation, Plague Saint,
Cinder Regent and Mire Mother. Numbers come from `client/data/content/bosses.json`, `fen.json`, `abilities.json`, `difficulty.json`.
The scene side is `client/next/bosses/`. A brain does not know what a combat core is: it asks its `DmBossWorld` (the Plague Saint's asks for her doctors only, `enemies_of`).

| file | role |
|---|---|
| `boss_brain.gd` (`DmBossBrain`) | shared machinery: awaken, damage + Fracture + Withered, stagger clock, phases at 60% / 30%, telegraph + resolve loop, wipe reset, defeat, arena leash |
| `prelate_brain.gd` ... `mire_brain.gd` | one brain per boss (`_think`, `_resolve`, `_tick`, `_on_phase`) |
| `boss_brains.gd` (`DmBossBrains`) | `make(world, id)`, `make_all(world)`, `BOSS_IDS` |
| `boss_world.gd` (`DmBossWorld`) | the only view of the world a brain sees; the host subclasses it |
| `boss_geom.gd`, `boss_pending.gd` | angle / segment / box helpers, the `DmBossPending` telegraph record |

## The host side
`client/next/bosses/dm_boss.gd` builds a brain with `DmBossBrains.make(world, boss_id)`; `client/next/bosses/dm_boss_node_world.gd`
(`extends DmBossWorld`) is the live world view, answered from the combat core. See `client/next/bosses/README.md`.

`DmBossWorld` methods (defaults report "not implemented"): `now()`, `difficulty()`, `echoes()`, `rand()`, `area_level()`, `emit(ev)`,
`players()`, `player_count()`, `cover()`, `spawn_enemy()`, `enemy_get()`, `enemies()`, `set_enemy_hp()`, `remove_enemy()`, `thralls()`,
`damage_thrall()`, `party_hp_per_extra()`, `nav_active()` / `walk()` / `detour()` (the live host's navmesh hooks; the replay worlds are open rings), `corpses()`, `remove_corpse()`, `hostile_toxic_zones()`, `add_hostile_pool()`, `ember_pool()`. Read `boss_world.gd`
for exact signatures. The live host adds `enemies_of(def)` (the rows of one kind): `saint_brain.gd` asks for her Plague Doctors only when the world has it, where the old brain read every body of the world every tick (the same doctors in the same order). Public brain API: `awaken(by, empowered)`, `damage(amount, by, fracture)`, `stagger(seconds)`, `update(dt)`,
`resume()`; Abbess also `niche_ids()` / `standing_niches()`, Congregation `covered(x, z)`.

## Tests
- The recorded scenarios (44, frozen: no generator) are replayed through these brains on a fake world and compared tick by tick: all of them by `client/tests/bosses/run.gd` alone (the boss suites, `client/tests/boss.gd` and the six on `boss_base.gd`, test the scenes; client/README.md "The bosses"). They are recordings of the web game's brains,
  kept as test fixtures.
- Scene-level behaviour on the core: the same suites, `client/tests/core_boss.gd` and `client/tests/coop_bosses.gd`.

## Notes
- There is no enrage timer; the "faster" cadence is the per-phase `fast` multiplier.
- JS `Array.sort` stability is kept via `DmStableSort` (nearest-two Burial targets, Mire corpse order).
