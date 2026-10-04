# Boss hook: how the world sim and the bosses track fit together

The sim track ports `WorldSim.ts` to `godot/sim/` (class `DmWorldSim`, file `world_sim.gd`). The bosses track ports `BossBrain.ts`
(all seven brains) to `godot/sim/bosses/`. This file is the contract between them. It follows the TS exactly: a brain is handed the
sim and mutates it directly (the TS `BossBrain` does `this.sim.emit(...)`, `this.sim.spawnEnemy(...)`), so the hook is "a controller
object per boss id", not a decision list.

## What the bosses track provides

1. `godot/sim/bosses/boss_factory.gd`:

```gdscript
class_name DmBossFactory
extends RefCounted
## id -> DmBossController for all seven ids: prelate, gravedigger, abbess, congregation, saint, regent, mire.
static func make_all(sim) -> Dictionary:
```

   The sim loads it with `load("res://sim/bosses/boss_factory.gd")` if the file exists, otherwise it builds `DmBossStub` for every id
   (shared machinery only: awaken, damage + Fracture + Withered, phases, defeat, wipe reset, stagger clock; no attacks). Nothing else
   in `godot/sim/` needs to change when the factory appears. Each brain extends `DmBossController` (`godot/sim/boss_controller.gd`).

2. Brain API, called by the sim (mirrors the TS `BossBrain` public members):

| member | when the sim calls it |
|---|---|
| `setup(sim, id)` | once, right after construction (sets `sim`, `id`, `state.id`, parks `state.x/z` in the arena and sets `state.level` to the area level like the TS constructor; a subclass overrides it with `super.setup(sim, id)` first) |
| `state: DmBossState` | read every tick by the sim, thralls, snapshots; the brain mutates it (fields = TS `BossState`, TS names) |
| `awaken(by: String, empowered: bool)` | a `summonBoss` intent was accepted (no other boss awake) |
| `damage(amount, by, fracture)` | any hit on the boss (hit intent with `boss: true`, thrall blows, litany, detonate, signatures, plague/death bursts) |
| `stagger(seconds)` | Shield Bash |
| `update(dt)` | once per `sim.step(dt)`, after enemies, thralls and separation, before corpses (same order as `WorldSim.step`) |
| `resume()` | host migration only |

3. `DmBossState` (`godot/sim/boss_state.gd`) is the shared `BossState` type (TS field names: `hp`, `maxHp`, `phase`, `stateT`,
   `fracture`, `witheredDps`, ...). `to_dict()` / `from_dict()` exist for snapshots.

## What the sim provides to a brain (`sim` is a `DmWorldSim`)

Fields (TS names kept, on purpose, so a brain is a line-by-line port):

- `sim.time: float` (seconds of sim time), `sim.difficulty: String`, `sim.vowFx: Dictionary` (`DmVowsBoons.vow_effects`, key `echoes`, ...)
- `sim.players: Dictionary` String id -> `DmSimPlayer` (`id, x, z, alive, area, level, family`)
- `sim.enemies: Dictionary` int id -> `DmSimEnemy`, `sim.thralls` int -> `DmSimThrall`, `sim.corpses` int -> `DmSimCorpse`, `sim.zones` int -> `DmSimZone`
- `sim.cover: Array` of `{x0, z0, x1, z1}` (Drowned Congregation pews; `sim.set_cover(boxes)`)
- Dictionaries iterate in insertion order, like a JS `Map`. `.values()` returns a copy, so `[...map.values()]` in TS is just `.values()`.

Methods (TS camelCase -> snake_case):

- `sim.rand() -> float` (the seeded mulberry32 stream; use it for every random draw, in the same order as the TS)
- `sim.emit(ev: Dictionary)` events keep the TS shape and keys exactly (`{"t": "boss", "kind": "awaken", "x": .., "z": .., "phase": 1, "boss": id}`; `hurt` events carry `player`, `dmg`, `from`, `x`, `z`, optional `chillMs`)
- `sim.spawn_enemy(def, area, x, z, elite, rising = true, affix = "") -> DmSimEnemy`
- `sim.area_level(area) -> float`
- `sim.remove_corpse(c: DmSimCorpse, reason: String, by: String = "")`
- `sim.kill_thrall(t: DmSimThrall, reason: String)` ('killed' | 'sacrificed' | 'crumbled')
- `sim.add_hostile_pool(x, z, r, dps, seconds) -> DmSimZone` (rot pool, kind `toxic`), `sim.ember_pool(x, z, r, seconds, dps) -> DmSimZone`
- `sim.next_id() -> int` (= TS `sim.id()`), `sim.enemies.erase(id)` for dropping adds without a kill (boss add cleanup)
- `sim.arena_center()`

Constants: `DmSimConsts.BOSS_RADIUS` (1.6), `BOSS_RING_PAD` (0.4), `PLAYER_RADIUS`. Boss tables: `DmContent.boss(id)` and the
`bosses`/`fen` exports via `DmContent.get_export("bosses", "GRAVEDIGGER")`, `("fen", "FEN_HUMMOCKS")`, ... (godot/data/content).

## What the sim does with the boss (so the brain knows its responsibilities)

- `DmWorldSim.bosses: Dictionary` id -> controller; `sim.boss` is the awake one (or the last one summoned); `sim.bossId` its id.
- The wave director pauses in the awake boss's area (`DmContent.boss(bossId).area`) while `state.active`; Grave Surges never open there.
- Thralls attack the boss while `state.active and state.state != "sunk"` and the owner is within 16 m of it (radius `BOSS_RADIUS`).
- Shield Bash, Black Litany, Corpse Explosion, thrall death bursts, plague bursts, carrion seeds, Rend call `boss.damage(...)` themselves.
- Emitting `hurt` events is how a brain damages a player (players are simulated by their own client / the world scene).
- Hurting thralls: `t.hp -= ...; if t.hp <= 0: sim.kill_thrall(t, "killed")` (as `BossBrain.hurtThralls` does).

## Testing a brain before the sim lands in the integration branch

The sim branch is `godot/sim`. Until it is merged, a brain can be unit-tested against a mock exposing the members above
(`players`, `enemies`, `corpses`, `zones`, `thralls`, `cover`, `time`, `difficulty`, `vowFx`, `rand()`, `emit()`, `spawn_enemy()`, ...).
Fixtures for the real brains can be generated by running the real `WorldSim` in TS (`makeBossBrains` is created by its constructor)
with `apply({t: 'summonBoss', by, boss})` and scripted players, exactly like `tools/godot/fixtures-sim.ts` does for the rest of the sim.
