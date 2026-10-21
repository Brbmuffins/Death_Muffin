# Grave Surges

How a Grave Surge runs on the combat core. The areas and their nodes: [README.md](README.md).

A Grave Surge is an event of the wave director (`director.surge`, `next/areas/dm_grave_surge.gd`), host only: a crypt cracks open in the hero's combat area, three waves climb out, and
quelling most of them pays an offering. The rules and numbers are `SURGE` in `data/content/enemies.json`; it works on the core's ids.
- **The clock** (`surge_in`) runs only while a living hero stands in the director's combat area (not a hub or the Depths) and no boss is awake and hittable: the first surge opens after 100 s of that
  time, the next 90 to 150 s after one ends (0.6 x that from Wave Speed tier 6, Restless Crypts). It keeps its value while no hero is in a combat area. The director calls `update(dt, heroes)` at the end of
  every physics tick and `reset()` when no hero is in the area or when it follows the heroes to another one, which fails an open surge. Idle it costs a few comparisons a tick (the area's flags are
  worked out when the director moves, the bosses' list is read only while one stands, the crypts are decoded when the director is made).
- **Opening:** one of the area's crypts (`DmDb.sim_world()["crypts"]`: the Graves, the Ossuary, the Nave and the Warren have them) 9 to 30 m from EVERY hero, else a wave's spawn point.
  `surge_event` `surge`; `DmAreaFlow` draws it: the cracked crypt, the banner, the sound, the shake and the counsel's Surge tip (`surge_opened`).
- **Three waves** at 1.5, 7.5 and 13.5 s, each 1.2 x the area's wave size (times the Wave Speed tier's size), at most up to the global cap of 72 bodies (the dying and the queued count). A wave climbs out over a few ticks like an
  ordinary wave: it is queued through the director (`begin_surge_wave`, then `spawn_group`: 0.5 to 2.9 m around the crypt on the navmesh, rising, with the area's roster, elites and affixes as a wave's) and made `SPAWNS_PER_TICK` (3) bodies a tick,
  the surge's own update makes none. Each queued body carries the surge's serial (bumped by every `start`) and the director hands the surge its core id when it is made (`_make_next`, the one step of the tick's drain and of `flush_spawns`):
  the surge keeps it only while it is the open one, so a surge that ends with a wave still queued, and the surge after it, are not credited with those bodies. `spawned` counts a wave when it is decided, so the 80 % rule is measured against the whole wave, queued bodies included.
  The director hears every `DmCoreHost.enemy_died` and passes the id on (`DmWaveDirector._on_enemy_died`), so nothing runs per body in GDScript. A body that leaves alive (its area was left) never dies and counts for nothing, and
  `clear_area` drops the area's queued bodies too: a surge left open without them fails when its 20 s are up (the director fails it at once when it clears the area).
- **Quelled** when 80 % of what came is dead, once the third wave is out: `surgeCleared`, and `DmAreaFlow` calls `rewards.on_surge_cleared`, which gives every living member within 38 m of the crypt an item from its
  drop tape (the "surge" kind, [Value on the server](../rewards/AUTHORITY.md)) and bonus gold on the ground at the crypt. **Failed** after 20 s, or when no hero is left in the area (dead, gone to a hub, the Depths or another combat area):
  `surgeFailed`, the crypt seals and nothing is paid.
- **In a party** the host's director runs it and the host pays every member in range (a guest's drops reach it as a kill's do: [Value on the server](../rewards/AUTHORITY.md)). A guest sees the bodies climb out (the core's snapshot) and,
  when the host quells it, its offering; the banner, the cracked crypt, the sounds and the tip are the host's window only (KNOWN-GAPS "Party and online"). **One surge at a time, in the director's own area.** When members stand in different combat areas each area has its
  ordinary waves (`next/spawn/README.md` "Grounds"), but the clock, the crypt and the three waves belong to the area the director stands in: a surge counts only its own bodies, fails when nobody is left in its area, and the director then moves to a member's area,
  where the next one opens. (A surge in a member's area would double the burst on the shared cap, and that member's window would not see it.)
- The benchmark's fight sets `director.surge = null`: a surge would add bodies to the counts the fight holds.

`tests/surge.gd` plays it in the whole world on the local mock (about 25 s with `--fixed-fps 60`; it ends with a party apart: one surge, the member's ordinary waves, the follow): the rules by hand (no surge in a hub, an instance, with no hero or while the real Gravedigger King stands;
the first after 100 s, not before; a crypt 9 to 30 m from every one of two heroes, one 3 m from a crypt never getting it, a spawn point when none is fair; three waves at 1.5 / 7.5 / 13.5 s of 11, queued by the update and made three a tick, the Wave Speed tier's size and the
global cap; a death that is not the surge's is not counted; 80 % quells it with gold and a surge item at the crypt; 20 s fails it with nothing paid; the hero leaving, and the director following him to the Ossuary, fail it;
Restless Crypts; a surge that ends with a wave still queued, and the next surge, not credited with it; the Graves cleared under an open surge), then the whole chain through the director's own ticks (the clock, the surge, the waves three
bodies a tick, the core's deaths, the offering). It prints INFO lines: what a wave costs per tick (the surge's update, each tick that makes 3 bodies against an idle tick, the spawn events those ticks dispatch).
