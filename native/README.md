# The combat core (C++)

The game's combat core (DECISIONS B34, B42, B50): a GDExtension (`DmCore.version()` is "dmcore 0.17") that owns every enemy, thrall, corpse and status in flat arrays and steps them once per 60 Hz tick; GDScript (`client/`) owns the hero, rites, bosses, rewards, HUD and flow.
Before launch the core was checked against the old per-creature game: its rules replayed against the old code, and its behaviour compared with seeded scenarios (kills, damage, time to kill, thrall uptime) within stated tolerances; DECISIONS B50 keeps the result.

## Design (the contract every change keeps)

- **What the core owns:** enemies (stats, state machine, timers, targeting, movement, attacks), thralls (raise, brain, attacks,
  expiry), corpses (lay, expire, atomic consume), statuses and affixes on every entity, the spatial grid and the wave director's
  spawn bookkeeping. Heroes and bosses are **external entities**: GDScript writes their position, radius, alive flag and target
  weight each tick, so every query and target choice treats them alike (bosses edge-counted, heroes weight 1.0, shieldbearers
  0.55, thralls 1.1).
- **One step per tick:** `step()` runs the heroes' pending commands, the director and every enemy in spawn-id order, corpses, then every thrall in raise order. Ties break the same way (strict `<`, then that order). Every brain runs, then every move, the crowd spacing
  and every affix, so bodies never read each other's positions in the same tick except for crowd spacing: a Deacon's support scan (raise, Sanctify), a Censer's pulse and a Lich Acolyte's claims run in their brains and measure from where the bodies stood before this tick's step (at most 3 cm of a walk).
  The thralls' soft separation (radius 0.4, push 6, per legion) runs first with the heroes, on the positions the last tick left; enemies see the positions thralls ended the last tick with; a thrall thinks and moves before the next one does. Hostile zones step with the enemies, before corpses and thralls: the toxic pool made by a bursting corpse, the moth's cloud and the Pyre's
  burning ground (a pool made in the enemy phase, a coal landing or a slam, takes its first step the same tick). Every body runs at 60 Hz: there is no idle level of detail (it is cheap enough in C++).
- **Commands from casts and bosses are synchronous:** rites stay GDScript and call `damage(id, amount, source) -> {dealt, killed}`,
  `enemies_in_radius` (the lane, the cone and the circle of a rite are GDScript on it, `client/next/rites/dm_rite_module.gd`), `foes_in_radius(pos, r)` (the living enemies `enemies_in_radius` finds, ten numbers each in doubles: id, x, z, radius, hp, state, elite, level, def, area; `DmCoreHost.foes_in_radius` builds the rites' snapshots from it),
  `apply_status`, `corpse_pick / corpse_consume`, `raise_thrall`, `remove_enemy` directly, and read the result at once,
  because a kill resolves inside the caller (Wailing Skull's extra hop, Bone Prison skipping the dead). A kill inside such a
  call runs the core's own death work at once (director count, Vengeful, statuses cleared, corpse laid) and is handed to GDScript
  (rewards) before the call returns. Kills inside `step()` (thrall swings, DoT, hazards) come out in the event buffer, in order. A blow of zero or less is refused (`damage`, a boss's too). `damage` on a thrall returns the health lost (after damage taken and the barrier), not the raw amount.
- **A living body can leave without dying (`remove_enemy`):** a boss's adds go with the boss (no death, no corpse, no kill credit, no Vengeful). The body is out of the table at
  once (later bodies keep their ids and order, the queries see it before the next step) and the buffer gets `EV_ENEMY_REMOVED` with one int, 1, where the removal of a dead body
  has none: the host must not count it among the dying (`DmCoreHost` does not), and a guest's core drops it on the same event. A dead or unknown id is refused (a dead body leaves
  by itself 4 s after it fell). The crowd fades a body that vanished alive (it never played a death).
- **No per-creature calls per tick:** per-creature work never crosses into GDScript during a tick. GDScript reads one ordered event
  buffer per tick (spawned, state edges, telegraphs, cues, damaged, died, thrall raised/died, corpse added/gone, status changes,
  zones) and bulk arrays for the HUD, minimap and auto combat. Cast-driven calls are bounded by casts, not by creature count.
- **Thralls and corpses (thralls.cpp, corpses.cpp):** a thrall is a flat-array body like an enemy, in raise order (dead bodies stay 1.4 s, counted in ticks, then
  a removed event). `raise_thrall(stats, owner, pos, yaw, cap)` takes the stats GDScript computed (`DmThralls.raise_stats` and
  `colossus_stats` stay GDScript), crumbles the oldest ordinary thrall first (a Colossus last, weight
  2) to fit the cap, replaces an older Colossus, and returns the id. Hero blows on enemies and thralls' blows on enemies go through `damage` with the
  thrall's id as the source. An enemy blow on a thrall is applied inside the core (damage taken, barrier, death "killed"); a blow on a hero is still an
  `EV_TARGET_HIT`; a thrall's blow or burst on a boss (an external of kind 1) is `EV_THRALL_HIT_EXTERNAL`, for GDScript to give the brain; a thrall's scan counts a boss after the enemies. Thralls
  and enemies share one status implementation (`Body`): applying, stepping, DoT lumps, stun and the multipliers exist once. A blow that kills (a wraith's chill, a bone mage's hex) still reports `status_applied`, but the dead body keeps no status.
  A corpse is laid in `kill()` after the statuses are cleared and before `EV_ENEMY_DIED` (the order of a death's consequences: director, affixes, statuses,
  corpse field, rewards); a toxic one bursts after 5 s into a hostile pool zone (per-zone pulse period, kind `ZONE_TOXIC`). `corpse_pick`,
  `corpses_in_radius` and `corpse_consume` are synchronous and atomic, so two casters on one corpse get one winner.
- **Affixes (affixes.cpp):** `DmAffixSet`'s rules run in the core: the director rolls (`DmAffixRoll.roll` stays GDScript) and passes the list to
  `spawn_enemy`; the bell's ring and toll, Hungering's meals (the corpse field's atomic consume, reason `devoured`) and the shroud's 0.1 s check run
  after the body's move, paused while it rises, staggers or burrows (the shroud check excepted). The client draws them from `EV_AFFIX_MOMENT`
  (tell, toll, hungering, vengeful, unveil) and the toll `EV_TELEGRAPH`. Rites call `cover_miasma(id)` (a friendly Miasma covers the body) and
  `strip_shroud(id)` (Last Light, a Warden sweep). Vengeful runs inside `kill()` in the order of a death's consequences: its Risen get their ids, rolls and
  `EV_ENEMY_SPAWNED` there, but join the table in `flush_spawns()`, at the end of the tick or of the `DmCore` call that killed (a kill can happen
  while the caller holds a reference into the table: a DoT lump, a swing that kills a bursting thrall).
- **What a boss asks of the core (boss.cpp, niche.cpp):** a hostile ground zone of its own (`add_zone(kind, pos, radius, seconds, dps, source)`: kinds dust, toxic and ember; the core pulses it once a second, dps x 1 s, on every hero
  and living thrall within radius + 0.45, hit kinds dust, toxic and burn, the boss's id as the source; `zones(kind)` lists the live ones as x, z, radius for the Plague Saint's "am I standing in rot"), and a body's health
  (`set_enemy_hp(id, hp, max_hp)`: the Abbess gives each Skull Niche a share of her own maximum; guests learn the maximum from a wire record). The Skull Niche is the `inert` def of enemies.json: it rises, then only stands.
- **Numbers from data, not retyped:** `load_enemy_defs` / `load_tuning` (enemies.json), `load_status_defs`, `load_legion_tuning` (abilities RALLY, fen
  HAG_HEX, statuses PLAGUE_BURST, gameplay_legendary LEGEND, runes RUNE_TUNING.colossus, combat/enemies damage_scale) and `load_sim_consts` (the
  numeric constants of `sim_consts.gd`, which `client/core/dm_core_data.gd` reads; the corpse field's and the thralls' constants are compiled in).
  `DmCoreData.load_all` does all of it. The defaults compiled in equal the data, so a core that loads nothing still plays;
  `client/tests/core_thralls.gd` asserts it (`DmCore.tuning()`).
- **Timers:** every "x seconds" timer accumulates or counts down in doubles, so 0.1 s lands on tick 7 and a 0.3 s countdown on tick 19.
  Positions stay float32, scalars double.
- **Seeded randomness:** one PCG stream per entity, seeded from the director's seed and the entity id (a thrall's repath and scan phase, its status phase and its teleport offset come from its own stream, as an enemy's do), so a seeded scenario replays
  bit for bit. Live play seeds from the clock.
- **Movement:** paths from `NavigationServer3D` (batched, cached per target cell; the core follows them itself, 24 points, advancing at 0.5 m for an enemy and 1.0 m for a thrall, with no re-path when a thrall is 2 m off the line), steering and separation in the core, positions
  kept on the navmesh by the core's own copy of it (`navgrid`: the enabled regions' triangles on a 2 m grid, about 0.7 us a body where the server's
  closest-point query walked every polygon of the map; `nav_replace_region` swaps one region's polygons, which is how a Depths floor changing leaves no old triangles behind), heroes and walls pushed out as circles.
  No creature moves with `move_and_slide`: the core moves a body, pushes it out of the hero's circle and snaps it back onto the navmesh (thralls pass through the hero and enemies: their mask is the world only). Because the core keeps bodies on the enabled regions only, a closed door's corridor and a sealed area are not walkable and
  a body stops at the corridor's mouth; with every region on, the core's closest point is the navigation server's to the millimetre (`client/tests/world.gd`).
  Every body notices a target at 15 m and strays 30 m from home; `set_enemy_aggro` gives one body its own (the Depths' hunters: 36 and 90), with the same drop rule (aggro x 1.5). (`dmcore 0.12`: `nav_replace_region`, `set_enemy_aggro` and `aggro` / `leash` in `enemy_info`; the wire layout is unchanged.)
  **Crowd spacing** replaces Godot's RVO avoidance, the one deliberate difference in feel (B42): a moving body does not drive into a neighbour in its way (that part of its velocity is dropped, so a crowd queues and slides around; one blocked head-on sidesteps on its own flank side, without stepping into anyone else) and is steered away from it,
  and after the moves every overlapping pair, moving or standing, eases apart by 30% of its overlap per tick (at most 15 cm a tick, the bigger body giving way less). Forty bodies closing on one hero pack around him with no pair sunk into another, and a hound blocked head-on by a standing body goes around it (`client/tests/core_enemies.gd`, crowd spacing). No physics body per creature.
- **Drawing:** one MultiMesh per creature model, level of detail and kind (plain, shadow, fade), transforms and animation data written in one buffer update per
  rendered frame, interpolated between ticks; animations play from baked vertex-animation textures. `DmCrowd` does it (`dm_crowd.*`, `core/crowd_view.*`): it reads the core's
  tables and damage events right after each step without consuming the events, and keeps every creature's view state (turn, legs, clip, blend, flash, knock, death) itself, so no
  presentation field lives in a world, enemy or thrall struct. Its input is a plain row per creature, hit and corpse (client/crowd/README.md "Driving the crowd"); a co-op
  guest's puppet core fills the same tables and damaged events, so `DmCrowd.sync(core)` draws it as it draws a host. The frame's cost is the view's to cut, in the one `draw` call: the camera's
  view-projection comes in with it (bodies outside it are not written), and a body far from the camera works its pose out less often, never the position (`client/crowd/README.md` "Crowd cost").
  A group (model, level of detail, kind) is drawn only while it holds instances: the renderer draws a MultiMesh with none all the same, so `draw` shows the group's `MultiMeshInstance3D` the frame it gets its first instance and
  hides it after half a second without one (`set_group_nodes`; `dmcore 0.14`, no enum or wire change; `client/README.md` "The draw budget"). A body that is not solid (it sinks away, or the Shrouded ward has it: body flag
  `BF_SHROUDED`, set from the affix and the `shrouded` status) is written to its model's fade group instead, drawn with the alpha shader, for as long as it is not (`add_model`'s and `set_group_nodes`' last argument, `buffer` and
  `instance_count`'s `fade`, `stats().faded`; `dmcore 0.15`, no enum or wire change; `client/crowd/README.md` "The alpha path").
- **Co-op (host-authoritative, B28, B40):** the host core packs one compact snapshot at 20 Hz and the discrete events as reliable batches; a guest's core runs in
  puppet mode (`set_puppet(true)`): no brains and no rules, bodies that appear from spawn events, ease toward snapshots and go on removal events,
  and an event buffer that carries what GDScript sees on the host, derived from state edges and hp drops. Messages carry a version and a
  hash of the data tables, so a phone or a newer build refuses cleanly. Calls, byte layout, limits and cost: "Co-op" below.

## Co-op: snapshots, events and the puppet core

The transport (lobby, relay) is not in the core: it moves three kinds of message between two `DmCore`s, one on the host and one in puppet mode on each guest.

```
host, each tick   core.step(dt);  crowd.sync(core);  events = core.take_events()            # as in solo play
host, every 3rd   parts = core.snapshot_parts(tick, 1300); for p in parts: send_unreliable(p); tick += parts.size()   # 20 Hz; the Full Party's ~1.2 KB is one packet, two past 1,300 B
host, each tick   b = core.take_reliable(); if not b.is_empty(): send_reliable(b)           # or every 3rd tick: batches simply hold more
host, guest joins core.set_replication(true) once; send_reliable(core.baseline()) to the new guest (the guests already in keep getting take_reliable())
guest, setup      DmCoreData.load_all(core); core.set_area_bounds(...) as on the host; core.set_puppet(true); a new area or a new host core = a new baseline
guest, on arrival core.apply_snapshot(bytes) / core.apply_reliable(bytes)                   # each snapshot part as it comes; false: core.replication_error() says why
guest, each tick  core.step(dt);  crowd.sync(core);  events = core.take_events()            # the same consumer code as the host
guest, a refused batch ("... ask the host for a baseline")  ->  ask for core.baseline() on the host, apply it, crowd.clear() first
```

- `take_reliable()` reads the same event buffer GDScript reads, from a cursor (like `DmCrowd`'s), and never consumes it: `take_events()` encodes what the cursor has
  not seen before it clears the buffer, so the order of the two calls does not matter. Nothing is collected until `set_replication(true)` (solo play pays nothing).
- Batches are numbered. A guest ignores a number it already has, refuses a number that skips ahead and then waits for a baseline. A baseline (`baseline()`) is the whole present
  as records (every live enemy and thrall as a spawn with what it is doing now, corpses, zones, statuses, the name tables); applying it replaces everything the guest knew,
  without removal events (the caller clears its own presentation), and carries the number of the last batch it already covers. It may be taken at any time between ticks: the
  events not yet handed out are sealed into the next batch, which the new guest ignores (the baseline's number covers it) and `take_reliable()` gives the guests already in.
- `snapshot_parts(tick, max_bytes)` is `snapshot(tick)` cut into packets: the live enemies in spawn order, then the live thralls in raise order, in as many messages as it takes to keep each at or
  under `max_bytes` (a UDP packet must stay under the path's MTU, 1,392 bytes in ENet, or its fragments are lost together; the Full Party's snapshot reaches 1.7 KB). Every part is a complete
  snapshot message of its own bodies (the same header, the counts of ITS records, ids as differences from 0, the same record bytes), so a guest applies each as it arrives: nothing is reassembled and no
  frame is waited for, and the wire format stays version 1. The parts of one call carry the ticks `tick`, `tick + 1` ... (the caller adds how many there were for the next call), which is also the frame id:
  a hole in the ticks a guest applied is a part the network lost, and the stale rule below makes an overtaken part cost nothing. A lost or late part leaves its bodies where the last
  snapshot put them for 50 ms (they keep easing); an empty world is one part that still carries the clock; a part always holds at least one record (about 48 B is the least `max_bytes` can mean).
- Snapshots are unreliable and carry only what changes (the table below). The spawn facts (def, level, area, kind, owner, maximum health) travel once, in the spawn event, so
  a snapshot record for an id the guest has not met yet is skipped (the two channels may overtake each other) and the next snapshot has it. A snapshot that is not newer than the
  last one is ignored (`true`, counted). A dead body is never in a snapshot: deaths are events, and a late snapshot cannot raise the dead.
- A guest is refused a message with another magic, version or data hash; `DmCore.wire_version()` is the number to put in the join handshake. Every read is bounds-checked: a cut
  or damaged message is refused and cannot make the guest read past the buffer, and a guest holds at most 4096 enemies, 1024 thralls and 512 corpses.

All numbers little-endian; `varint` is LEB128, `zigzag` a varint of a signed number. Header of every message (8 bytes): `"DM"`, kind (1 snapshot, 2 reliable batch, 3 baseline),
format version (`WIRE_VERSION`, now 1), content hash (u32, FNV-1a over the enemy defs and the numbers a puppet derives events from, the status rule names, thrall kinds and affixes).

**Snapshot** (kind 1): header, tick (u32, the caller's number), clock (f64), origin x and z (2 x f32, the middle of the area's bounds), enemy count and thrall count (varints),
then the enemy records in spawn order and the thrall records in raise order. Positions are i16 centimetres from the origin (+-327 m).

| enemy record | bytes | |
|---|---|---|
| id | 1-2 | zigzag, the difference from the previous record's id (3 bytes over a gap of 8,000 ids) |
| flags | 1 | bits 0-3 state (`EnemyState`), 4 elite, 5 dug in (a Deacon: its swing is a raise; a Gargoyle: its swing is a dive; a Drowned Sexton: its swing is the chain), 6 aim follows (ATTACK, ERUPT), 7 affix byte follows |
| affixes | 0-1 | one bit per `Affix` |
| x, z | 4 | i16 each |
| yaw | 1 | 256 steps of a turn (1.4 degrees) |
| health | 2 | 1..65535 of the maximum while alive |
| time in state | 1 | centiseconds, 255 = 2.55 s or more |
| aim x, z | 0 or 4 | i16 each |

| thrall record | bytes | |
|---|---|---|
| id | 1-2 | as above |
| flags | 1 | bits 0-2 state (`ThrallState`), 3 rally, 4 aim follows (ATTACK) |
| x, z, yaw, health, time in state | 8 | as for an enemy |
| swing counter | 1 | modulo 256 (the attack visual fires when it changes) |
| aim x, z | 0 or 4 | i16 each |

An enemy takes 10 bytes (up to 16 with affixes, an aim and a two-byte id), a thrall 11 (up to 16): the Full Party (72 enemies, 32 thralls) is at most 1.7 KB, 1.2-1.3 KB in the
test's fight (`client/tests/core_coop.gd`), against about 180 bytes per enemy as dictionaries in the old game.

**Reliable batch** (kind 2): header, number (u32), record count (varint), records. **Baseline** (kind 3): header, number, clock (f64), count, records. A record is a type byte and:
- 1..32, an event of the buffer GDScript reads: entity id (varint), counts (`ints << 4 | floats`), the ints (zigzag), the floats (f32). Three have a tail: spawned (1) and thrall
  raised (22) end with the body's state now, health (u16), yaw (u8) and time in state (u8) (22 adds the swing counter as a varint and a rally byte); status changed (14) ends
  with a count and 4 bytes per status in the `DmCore.statuses()` layout, the set as it is when the batch is made.
- 101, a name: table (0 area, 1 corpse reason), index, length, bytes. Areas and corpse reasons are numbers in events; the names go before their first use.
- 102, a thrall's new maximum health: id, f32 (`set_thrall_stats` with a `maxHp`); guests know health as a fraction of the maximum.
- 103, an enemy's new maximum health: id, f32 (`set_enemy_hp`: a boss gave its niche its share); the baseline names the present maximum in the body's spawn record.

On the wire as events: spawned, died, removed, cue, zone, zone pulse, zone gone, statuses cleared, status changed, status dot, status expired, corpse added, consumed, gone and
ruptured, thrall raised, died, removed and status, affix moment, and the bell's toll telegraph. Derived on the guest from the snapshots (so its buffer has them, once per change
between two snapshots): enemy state, attack, the cone, slam, dust, erupt, raise, curse, scream, dive, ember, hex, pulse and hook telegraphs (the place and aim of the snapshot, the wind-up less the age it showed, at least 0.05 s; a Deacon's swing is a raise or a curse, and a Gargoyle's a dive or a bite, by bit 5 of its record), damaged (the hp drop, and the rest of the health at a death), thrall state, swing and damaged. Host-only, never sent: a blow on a hero (`EV_TARGET_HIT`: the host
applies it to every member), what an enemy does to a hero besides (`EV_TARGET_EFFECT`: a chill, a root, a drag), a thrall's hit on a boss, Withered's spread, the plague pool and the bell's heal. A guest's buffer is for effects and the HUD: its GDScript must not
run rewards, loot or the kill report from `died`.

**A puppet core** (`set_puppet(true)`; switching clears every body) steps with `step(dt)`: a body eases toward its last snapshot by `1 - exp(-15 dt)` and snaps above 6 m, yaw
likewise, its ground speed is the eased motion smoothed at 10 per second (0 below 0.3 m/s), time in state counts up and is taken from a snapshot when it differs by more than
0.1 s, status chips count down. Queries (`enemies_in_radius`, `enemy_info` and its one-field reads `enemy_state` / `enemy_pos` / `enemy_radius` (`dmcore 0.17`, no enum or wire change), `thralls_in_radius`, `thrall_*`, `corpse_*`, `statuses`) read the same tables as on the host. A puppet's
`enemy_info` has `net_pos` (where the last snapshot put the body). Commands the host owns (`spawn_enemy`, `remove_enemy`, `damage`, `stun`, `apply_status`, `remove_status`, `raise_thrall`,
`kill_thrall`, `sacrifice_thralls`, `rally_thralls`, `recall_thralls`, `set_legion_burst`, `set_thrall_*`, `curse_thrall`, `strip_shroud`, `cover_miasma`, `remove_enemy`, `corpse_add`,
`corpse_consume`, `snapshot`, `snapshot_parts`, `take_reliable`, `baseline`, `set_replication`) are refused: they return 0, false, nothing or (`damage`) `{dealt: 0, killed: false, refused: true}`, print
one error per command, and count in `replication_stats().commands_refused`. Heroes and bosses are brain input: `add_external` returns 0 and `set_external` does nothing on a puppet. `replication_stats()` counts both roles (messages built and applied,
stale snapshots, ids not yet met, desyncs, refusals, the sizes of the buffers on the per-tick path, which the test holds steady).

**What a guest sees.** One binary snapshot with every body, thralls included, at 20 Hz carries the fight (the old game sent dictionaries: enemies 6 to a packet at 20 Hz, thralls at 15 Hz plus a full reliable copy at 1 Hz, and the cues over a reliable RPC of their own; now the cues are the core's events in the reliable batches).
Values are quantized: positions to 1 cm, yaw to 1.4 degrees, health to 1/65535 of the maximum, time in state to 10 ms. The animation name is not sent: the crowd view picks clips from the state and the eased speed. A snapshot is cut by body ranges, not fragmented (`DmCore.snapshot_parts(tick, 1300)`, `client/next/next_net.gd`): one packet in a fight under 1,300 B and two at the Full Party's largest, each part applied
by the guest as it arrives; over the UDP lane a lost part loses only its bodies' 50 ms update, and the WebSocket fallback loses nothing.
- **A change between snapshots is seen once:** a state that lasts less than one interval (50 ms) is never seen, and two hits between two snapshots are one damaged event with the sum. A derived thrall swing has target 0 and damage 0 (the host's event knows both); a puppet's `enemy_info` has the def's damage and speed, not the body's rolled ones, and no target or cooldowns. A telegraph's place and aim are the snapshot's, its seconds the wind-up less the age the snapshot showed.
- **Deaths come as events, not as a state in a snapshot:** the body stops where the guest drew it (up to speed / 15 m behind the host), while its corpse lies exactly where the host laid it; the guest's buffer gets `damaged` with the health the last snapshot showed, then `state`, then `died`. A guest's corpses have no lifetime: they go when the host says so.
- **Order of a guest's buffer:** forwarded events in the host's order, the derived ones where the packet that caused them was applied; a death's state edge comes just before its `died`, after the corpse events (the host's comes first).
- **Reaching a guest:** the slam, erupt, dig-in, scream and hook cues are on the wire. A burning pool (the Husk's embers, the coal's, the slam's) reaches a guest as the host's zone event, when the host made it, and a late joiner finds pools already burning (the baseline lists the zones). A snap above 6 m is not counted as walking speed. A guest's hero is an external of the HOST's core (its id is told in a table), so enemies chase and hit it there and its thralls are the host's bodies; the guest's own core has no externals at all.
- **Not carried by the core's messages:** the bosses' state, phases, telegraphs and statuses (the boss host's; their adds, niches and zones are the core's and ride the wire; a party fights all seven bosses, `client/tests/coop.gd` and `coop_bosses.gd`), the hero positions (the session's own 20 Hz snapshot) and vitals (`Net`, 20 Hz), the rites' events, states and gestures (`DmRiteCaster`), ground drops, party calls and chat. Guests send their intents (move, cast requests) to the host. The per-kind extras of an enemy snapshot are bit 5 of its record (the deacon's raise, the gargoyle's dive, the sexton's chain).
- A guest's window shows its hero's hurt and a DoT's lumps: the HUD binds the hero's `hurt` from the host's vitals and the status events of the reliable batches (client/README.md "The HUD on the core").

## The kinds of the other areas

The enemy kinds beyond the Hollow Graves' roster (`world.cpp`, `support.cpp`, `nave.cpp`, `cloister.cpp`, `pyre_fen.cpp`), checked by `client/tests/core_kinds.gd`: numbers come from the def and `enemies.json` / `fen.json`, the rest are constants in the source.
The Bone Golem is the sac's hazard on other numbers and runs on the generic hazard rules (its slam radius 2.8 m, 0.95 s wind-up, 2.7 s cooldown, 26 damage, three corpses).

### The Crypt Deacon (the Ossuary)
- **Its Risen are made by the core**, not by the wave director: at the end of the channel the corpse is consumed ("raised", by peer 1) and a Risen is made on the spot where it lay, rising, at the
  deacon's level, hp and damage multipliers (a plain body, not an elite), with its id and spawn event at once and its place in the table at the end of the tick (Vengeful's way). It belongs to the deacon's area, and a benchmark's fixed stats do not reach it (the benchmark has no deacons).
- **The corpse field is always there.**
- **A deacon needs `behavior: support` without `ward` or `inert`** to run the Deacon's rules (its raise and Sanctify scan); the Weeping Seraph (ward) keeps the Deacon's walk and has its own ward below, and the Skull Niche (inert) keeps the melee default.
- **On a guest** the telegraph of a raise or a curse is derived from the snapshot's ATTACK edge like the cone's (bit 5 of the record tells them apart); Sanctify's cue and status, the spent corpse and the Risen are the reliable events.
- Sanctify's range, duration and cooldown factor are read from `statuses.json` (`load_legion_tuning`); the scan period, the 8 m of the corpse and the keep-away distances are compiled-in constants, as the other states' are.

### The Drowned Nave's five (`nave.cpp`, `world.cpp`)
Numbers from the def and `enemies.json` (CENSER, SCREAM, TEMPLAR_SHIELD, UNBIND):
- **Censer Bearer** (a melee body whose incense is the `incensed` status): every second (the first tick it is not rising) every enemy not fallen within CENSER.radius takes the status for hasteS, itself and the rising too, a body made that
  tick included (x1.3 feet, x1.25 blows). The pulse measures from where the bodies stood before this tick's moves ("One step per tick"). The cloud (`censer_incense`) is `DmEnemyFx`'s, following the drawn body.
- **Lich Acolyte** (the cloister casters' walk: a kite, but a silenced body never starts a cast; the curse is a ring on the target and a blow at the current target within the reach, hit kind curse). Unbind:
  the acolyte connects to the thralls it has not seen every 0.5 s (a thrall that falls before its next look is not claimed) and hears the ones it saw die in the order it connected; a KILLED thrall within range, not claimed by another, with fewer
  than maxAlive claimed Risen alive or waiting and the cooldown over, is claimed (cue at the place); the Risen climbs out delayS later, **made by the core** like the deacon's (the level, hp and damage multipliers of the acolyte, a plain body in
  the acolyte's area, its id and spawn event at once and its place in the table at the end of the tick). A thrall of any owner counts. The acolyte's claims are
  beside the table (`DmCore.unbind_info` shows them to the tests). Its reach ring is drawn by `DmEnemyFx` from the core's living thralls within range.
- **Belfry Gargoyle** (a flanker with a dive): with the cooldown up and the target between minRange and range (both inclusive) it checks the sight line at most every 0.25 s and, if clear, dives: the mark is the target's place, it hangs still for the first half of
  the wind-up, drops along k squared, and everything within the radius of the mark takes the blow as it lands; it sits grounded for 0.3 s + groundedS; a stun ends the dive where it is. **The sight line** is not a ray: the core has no collision world, so a
  wall is an obstacle (the Ossuary Wall) across the straight line, or a stretch of the line more than 0.35 m off the navmesh (sampled every 0.4 m; the navmesh is cut round walls and what stands in the way). The old game's ray at a metre above the ground ignored
  low rubble that the navmesh cuts round and saw through a gap in the navmesh that has no collider; a gate that is shut is a wall in both. A test that needs a dive stands the hero on ground the line crosses cleanly (`game_scene.gd` uses the Graves' door: from a spot with a grave in the way the body walks the whole range and never dives). The body stays on the ground plane (`flying` is the view's); the crowd draws the climb and the
  drop and the dive clip ("What each creature does" in client/crowd/README.md). **On a guest** the dive is bit 5 of the record, the telegraph is derived from the ATTACK edge, and the landing (the grounded spell) is inferred from the host's restart of the swing's
  count; at worst the guest sits grounded a snapshot late or early.
- **Bell-Sworn Templar** (a melee body behind a shield): a blow from a body (a hero, a boss, a thrall or an enemy, found by its id) within halfArcDeg of where it faces passes `passThrough` of its damage, unless it is Fractured; a DoT tick, a blow with no
  source or from one that is gone is undirected. It works before the base's refusals: a rising templar takes nothing and still glances. The glance cue is rate-limited to one a quarter second of **game time**.
- **Choir Wraith** (the caster set: no silence check) sings a ring of SCREAM.radius at the aim fixed when the wind-up began; heroes and thralls inside it take the blow; the cue `scream` is told at the ring. It leaves no corpse. It hovers 0.45 m and thins to mist in the crowd, and `DmEnemyFx` plays its mist burst.
- A caster whose attack is `curse` or `flask` is the cloister's (it checks silence). The telegraphs (scream, dive), cues (shield_block, unbind, scream) and blows (curse, scream, dive) are in the name tables; the content hash covers the dive's radius, the scream's and the def flags.

### The Bell Sanctum's and Plague Cloister's three (`cloister.cpp`, `world.cpp`)
Numbers from the def and `enemies.json` (WARD, PLAGUE_FLASK, FRENZY). With them the Bell Sanctum, the Bone Coliseum and the Plague Cloister run their whole rosters on the core (`client/tests/world.gd`):
- **Weeping Seraph** (`behavior: support` with `ward`): it walks as the Deacon does (the cloister casters' state with the parameters [0, 0.5, 4, 0.7]: cast at attackRange, walk in beyond attackRange - 0.5,
  back off under 4 m at 0.7 x, silenced it never starts a cast) and its blow is the acolyte's curse (a ring on the target, the current target within the reach at the blow, hit kind curse); it has no Deacon scan (it neither raises nor scans for corpses) and
  rolls nothing more than the base. Its **ward** runs before the base's tick, on the cooldown the last tick left: with the cooldown up, the retry over and the body not winding up, flinching, fallen or rising, and not silenced, every
  living body but itself within WARD.range (fallen, rising and underground bodies skipped, any kind including another seraph, hurt or not) that is not blessed already is a candidate; they are put in order of health fraction, the most wounded first, and the
  first WARD.maxTargets get `sanctified` (the status rule's duration) and a `sanctify` cue at their place; the cooldown (the body's own, an elite's is x0.8) is spent. With no candidate it looks again WARD_RETRY_S (0.25 s) later. **The order of equal
  health** is Godot's: `Array.sort_custom` is stable up to sixteen candidates and not above, and which of the equals are blessed depends on it, so the core reproduces the engine's sort (`GodotSort` in `cloister.cpp`; `core_kinds.gd` compares it with the engine's own
  on forty lists of 5 to 56 candidates, most of them tied). Because the ward looks at the start of the tick and a curse starts the tick the cooldown runs out, a seraph with a target in reach curses first and never wards in that cooldown.
  The ward measures from where the bodies stood before this tick's moves ("One step per tick"). **On a guest** the curse's ring
  is derived from the ATTACK edge, and the cues and the blessings are the reliable events. **Not drawn:** the wing beat (the crowd bakes a rigged model's clips alone and adds no beat, so the seraph hovers with still wings).
- **Plague Doctor** (the cloister casters' walk, silence-aware, as the acolyte's): the flask is a ring of PLAGUE_FLASK.radius at the aim fixed when the wind-up began; at its end every hero and thrall within the radius of the aim takes the body's damage
  (hit kind toxic), however far from the body, a toxic pool stays there for poolS seconds and pulses every second (the dust cloud's clock: `ZONE_TOXIC`, source the doctor) for damage x poolDpsMult to everything within radius + 0.45, and the cue `flask` is told
  at the aim. Its corpse is toxic (the existing rupture). **On a guest** the ring is derived from the ATTACK edge (the blow `flask`), and the pool and the cue are the host's events. Neither the pool nor the flask's landing has a visual of its own
  (`DmEnemyFx` draws dust and ember zones only, and the flask's ring is the router's): a player sees the ring and then, for five seconds, only the damage. The pool steps in the enemy phase with the other hostile zones.
- **Flagellant:** nothing of its own in the brain. Its def's `frenzy` is the status set's: at its 0.1 s step, with the health strictly under FRENZY.atFrac of the maximum, the body has the status `frenzy` for good (x1.45 feet, x1.6
  blows, the cooldown running x1.6 as fast), and loses it above. `DmEnemyFx` sheds its blood motes (5 a second, near the hero) from the status.
- The telegraph, cue and blow `flask` are in the name tables; the content hash covers the seraph's `ward` flag and the flask's radius.

### The Cinder Pyre's and the Mourning Fen's eight (`pyre_fen.cpp`, `world.cpp`)
Numbers from the def, `enemies.json` (EMBER_BOLT, EMBER_DEATH, SLAG_POOL), `fen.json` (HAG_HEX, WISP_PULSE, SEXTON_HOOK, FEN_LURE) and literals in the source:
- **Burning ground is a zone of kind `ember`** (hurts as `burn`, once a second to every hero and thrall within its radius + 0.45 m, like the moth's cloud). The **Cinder Husk** leaves one where it falls (EMBER_DEATH: 1.6 m, 3 s,
  0.3 x its damage a second), told after `died` and not when it leaves alive (a boss's add); the **Pyre Priest**'s coal (a ring of EMBER_BOLT.radius on the aim fixed when the wind-up began: everything inside takes the blow as `ember`)
  leaves one on the aim (0.4 x the blow a second for 4 s); the **Slag Brute**'s slam leaves one of the slam's radius (SLAG_POOL: 0.3 x its damage, 4 s). The casters' and the chain's blows are the body's damage x its status set's damage dealt
  (Bone Hex softens them and the coal's pool), where the slam, the plain bites and the Husk's pool use the plain damage.
- **Bog Hag** (the caster set's walk, no silence check): the hex's ring is aimed at the thrall in the thickest knot (most living thralls within HAG_HEX.radius of it, itself included) among the ones within attackRange of the hag, the first
  in raise order on a tie, a far thrall counting as a neighbour but not as a candidate; with none, at its target. Everything inside takes 0.55 x the blow as `curse`; a thrall is cursed for 6 s (`cursed_t`, set unless the blow killed it, and
  already one tick down when the tick ends: it counts down in its own step), a hero is chilled for 1.8 s.
- **Fen Wisp** (the caster set, hovering 1.5 m): the pulse is a ring of WISP_PULSE.radius, damage as `dust`, a chill on heroes; it leaves no zone and no corpse. When its target is inside 3.5 m and the cast is not ready it backs off at 0.8 x its
  speed along 0.55 x away from the target + 0.45 x toward the open water (FEN_LURE), aimed 3 m ahead, where the others back straight away.
- **Drowned Sexton** (a hazard): a hero between SEXTON_HOOK.minRange and range away (both inclusive) with a clear line, when the swing's cooldown and the chain's own (6.5 s from the moment the wind-up begins, counted down every tick the
  body acts) are both up, gets the chain before the slam; a thrall never does. The chain is a telegraph along the line (its range long), the aim fixed at the start, and winds up for the def's `windupMs` like the slam (SEXTON_HOOK's own `windupMs` is not read); at the end of the wind-up every body in the strip (range + 0.6 m long, halfWidth +
  0.3 m either side) with a clear line takes 0.7 x the blow as melee, a hero is dragged 4.5 m toward the sexton (never closer than 1.6 m, nothing under 5 cm) and rooted 0.5 s, and the cue `hook` is told at the aim. A stun ends the chain and spends
  its cooldown; the next slam is a slam. **The clear line** is the Gargoyle's (above): an obstacle across the line, or a stretch of it more than 0.35 m off the navmesh (a prop cut out of it); the old game's ray at chest height met the world's
  colliders. It is looked at on every tick the chain could begin (the Sexton does not cache it, as the Gargoyle does) and once per body in the strip at the blow.
- **Cinderhound, Mire Leech** are the flank kinds on the generic rules (the leech's bite is `toxic`, it is tiny and leaves no corpse). The leech has no latch; its squash-and-sway wiggle is a view effect that the crowd does not draw
  (the model is an unrigged pose); the Wisp's glow and the fallback rigs are `crowd_looks.json`'s.
- **On a guest** the chain is bit 5 of the Sexton's record; the coal's, hex's, pulse's and chain's telegraphs are derived from the ATTACK edge like the others; the pools and the hook cue are reliable events; the chill, root and drag
  are the host's alone (`EV_TARGET_EFFECT`). The content hash covers the four flags (`emberDeath`, `slamPool`, `hook`, `lure`) and the four radii.
- The blows `ember`, `hex`, `pulse` and `hook` (and the same telegraphs), the cue `hook`, the zone kind `ember` and event 33 `EV_TARGET_EFFECT` (chill, root, pull) are in the name tables.

## Affixes, corpses and thralls

The elite affixes, the corpse field and the thralls run in the core ("Design" says what it owns).
Here is what each does, where its GDScript half is and what is still open. The numbers are the data files' (`DmCoreData.load_all`: `client/data/README.md`).

### Affixes (`affixes.cpp`)
An elite carries some of four affixes, a bit mask on its body (the spawn event carries it and the target frame's chips read it).
- **Rolling stays GDScript**: `DmAffixRoll.roll` (`client/core/dm_affix_roll.gd`), called by the director, which owns the random stream. An elite gets the Omen's affix when the Omen forces one (the Tolling: Bell-Tolled), else one of the four at random;
  in the Depths it also gets extras (`DmSimDepthsRules.pick_extra_affixes`: one more every 5 depths, at most 3 extra, all different; the Depths run passes its own list as `over.affix_list`, the Omen's first). A plain body gets Nightfall's shroud
  (`NIGHTFALL_SHROUD_CHANCE` 0.5, once per pick, so a whole pack) while that milestone is on.
- **Rules** (`AFFIX_TUNING`; they run after the body's move and only while it acts: not while it rises, is hurt or burrows; the shroud's 0.1 s check always runs). *Bell-Tolled*: every 6 s a ring (r 3) is shown for 0.9 s where the body stands (`EV_TELEGRAPH`, kind toll),
  then every hero and thrall inside takes the body's blow x 0.6 (hit kind toll). *Hungering*: every 4 s (retry after 0.5 s) while it is hurt, the nearest corpse within 5 m is eaten (reason `devoured`) and heals it 15 % of its maximum, at most what it lacks.
  *Shrouded*: the `shrouded` status (damage taken x 0.5, drawn at 0.38 opacity), lifted while a friendly Miasma covers the body (`cover_miasma`, 0.35 s of game time); `strip_shroud(id)` takes it off for good and no rite calls it yet (Last Light and the Warden's sweep are not in the game).
  *Vengeful*: on death three Risen climb out on a 1.4 m ring round the fall (its turn comes from the elite's own stream), as strong as the body (level, health and damage multipliers); a query cannot find them until the call or tick that killed the elite returns (they are rising, so nothing could hurt them anyway).
  The bell's ring and the burst use the body's position this tick; a body killed by its own toll's chain (the toll kills a bursting thrall whose burst kills the body) lays no corpse in that same tick.
- **The look** is the client's (`DmEnemyFx`, `client/next/enemy_fx/README.md`): the standing marks that follow the drawn body, the motes near the hero and the one-off beats from `EV_AFFIX_MOMENT` (tell, toll, hungering, vengeful, unveil). Hungering's meal shows no "+N" health number
  (the moment carries the place; the amount is the health change).
- Proof: `client/tests/core_affixes.gd` (each affix's timers, the pause while staggered, Vengeful inside a call and inside a DoT tick).

### Corpses (`corpses.cpp`)
- **The adapter**: `DmCoreCorpses` (`client/core/dm_core_corpses.gd`, the caster's `c.corpses()`) gives the rites the field's contract: `pick_corpse(aim, pick_r, max_range, from, area)` (the nearest to the aim within `pick_r` and within `max_range` of the caster, else the nearest to the caster within 7 m),
  `corpses_in_radius` (nearest first, ties by id; a filter runs in GDScript), `consume(id, by_peer, reason)` (atomic, one winner), `add_corpse`, `count`, and `notes(id)` (what a rite keeps on a corpse, gone with it: Carrion Seed's seed). A corpse is a `DmCoreCorpse` snapshot
  (`client/core/dm_core_corpse.gd`: id, x, z, kind, enemy, elite, facing, scale, area), so a rite reads what it needs before it consumes. Exhume's pick radius and range are `DmSimData.ABILITIES.exhume`'s.
- **Laying**: a death leaves a corpse of its def's kind at the body's feet (`normal`, `swift`, `resonant`, `toxic`; `none` for the Risen, rat, bat, wraith, niche, Mire Leech and Fen Wisp), plus the def's `deathCorpses` as "risen" corpses on a 1.6 m ring (the Bone Golem 3, the Drowned Sexton 2), which are not snapped to the navmesh.
  Other sources call `corpse_add` (a sacrificed thrall's, when Black Litany's `sacrificeLeavesCorpse` mod is set).
- **Why a corpse goes** (the reason names in its events, six built in): `expired`, `burst` (a toxic rupture, or a Corpse Explosion's blast), `consumed` (Exhume, Grave Offering, Bone Mantle, Plague Bloom, a raise), `litany`, `raised` (the Deacon's and the Drowned Rite's Risen), `devoured` (a hungry elite, the Abbess's Communion).
- **Numbers**: lifetime 26 s x the life multiplier (`set_corpse_life_mult`, 1 in the game: the vows and boons that moved it are Ascension's), at most 45 (the oldest goes first as `expired`), a toxic corpse bursts after 5 s into a pool (r 2.4 x its scale, 5 s, a pulse every 0.4 s for
  6 x `damage_scale(level)`; the level is the area's, 1 until GDScript calls `set_area_level`: `DmCoreHost` calls it from every enemy it sees made in the area, with the level that enemy was given, so a pool hurts as hard as the area's enemies do).
- **Cost**: expiry is event driven (the corpse clock is compared with the earliest due time and nothing is scanned until it is reached); queries scan the at most 45 records linearly.
- **The look** is the client's (`DmEnemyFx`): a pale ring under every fresh corpse (at most 8), a violet one under a resonant corpse, a green disc under a toxic one, the puff for why it went, and `DmCrowd.shatter` for the body a Corpse Explosion blows apart.
- Proof: `client/tests/core_corpses.gd`. Not done: `corpse_gone` has no sound; Plague Bloom's seeded corpses use the plain `consumed` look.

### Thralls (`thralls.cpp`)
- **The adapter**: a hero's legion is `DmCoreLegion` (`client/core/dm_core_legion.gd`, the caster's `c.thralls()`): the calls a cast makes, `raise(intent, aim) -> {ok, thralls, crumbled, why}`, `rally(secs, focus)`, `command_rend(point, leaps)`, `sacrifice(n)`, `refresh(hp, damage, speed)`, `recall()`, `kill(id, reason)`, `clear(reason)`,
  and the queries `list()`, `active()`, `count()`, `places_used()`, `info(id)`, `near(pos, r)`; signals `raised(thrall_id, corpse)` and `exhume_failed(why)`; `legend` (the worn legendary's mods, `championEvery` and `thrallDeathBurst`, kept current by the caster). A thrall is an id.
  `DmThralls.raise_stats / colossus_stats` stay GDScript and hand the core a raise's stats.
- **A raise**: `pick_corpse` -> read the record -> `consume(id, peer, "consumed")` (false = lost the race, why `gone`) -> the core makes room (the cap rules in "Design") -> the thrall rises at the corpse (0.9 s). Mass Grave consumes each corpse in its radius (the stat multiplier when more than one);
  a Bone Colossus takes the nearest corpses within its pick radius, all consumed, else `few`. `why`: `no_corpse`, `gone`, `few`, `owner_dead`.
- **The brain** (its numbers are constants in `thralls.cpp`). *Follow*: a seat on a 1.9 m ring round the owner, dealt by rank among the living, 1.35x pace when more than 6 m behind, and a jump next to the owner (target dropped) beyond 24 m.
  *Acquire*: the nearest enemy within 10 m of the thrall and 11 m of the owner (a target is dropped beyond 13 m of the owner), scanned every 0.25 s only while it has none (staggered); the path is asked for at most every 0.3 s and only when the goal moved more than 1 m (a goal under 3 m is walked straight).
  *Blow*: at the swing's start, damage x rally 1.4 x the Hag's hex 0.7 x the Spear rally's mark, every `attackInterval`, reach `range + the target's radius`.
- **Kinds**: the wraith chills what it hits (and signals `bell_heal`), the bone mage hexes, the Colossus cleaves 0.6x on every other enemy within 2.4 m of the one struck, a plague bearer bursts when it dies other than crumbling (2.5x damage within 2.6 m, and a pool event),
  and Legion of the Unburied's burst goes off when a thrall is killed. The core only tells the `bell_heal` and pool events (the thrall's id, the place, the numbers); `DmLegionEvents` (`client/next/rites/dm_legion_events.gd`, the host's) acts on them: a bell heal mends every living hero
  within the Mourning Bell's range of the wraith for the event's share of THEIR maximum health, and the pool becomes the owner's friendly rot cloud (`rite_miasma.gd` `plague_pool`), drawn on every peer. Proof: `client/tests/combat_odds/run.gd` (E).
- **Dying**: reasons `killed`, `crumbled` (over the cap, or its owner gone), `sacrificed`, `decayed`; the body lies 1.4 s; a thrall's blows credit its owner.
- **The look** is the client's: the crowd draws the thralls (`client/crowd/crowd_looks.json`: the legions' models and tints, the plague bearer's and the Colossus' larger rings), `DmEnemyFx` their ground rings and the rise and death sounds (`client/next/enemy_fx/README.md`).
- Proof: `client/tests/core_thralls.gd` (the rise, caps and make room, formation and leash, the scan and the boss edge rule, the swing, kinds, enemies choosing and hurting thralls, deaths and bursts, statuses on thralls, rally, separation, tick order).

## Files

- `native/src/`: `dm_core.cpp` is the Godot-facing API (`DmCore`); `dm_crowd.cpp` the crowd's (`DmCrowd`: looks, the core's tables into rows, the RenderingServer);
  `dm_motes.cpp` the effects' particle ring (`DmMotes`: a burst's random starts (`emit`: the global generator, the numbers drawn in a fixed order) and the per-frame
  loop in double precision, written straight to the ring's MultiMesh; `client/fx/dm_fx_ring.gd` drives it, about 0.06 ms for 3,000 motes where the GDScript loop it replaced took 2.8, and
  `client/tests/fx_motes.gd` holds every float of its buffer); `dm_decals.cpp` the ground decals (`DmDecals`: the decal half of
  `DmFxLayer.flush`: a record per decal, aged, shaped and placed, each layer's 20-float instances written straight to its MultiMesh and handed to the RenderingServer; a decal may follow a crowd body by id, asked of
  `DmCrowd.ground_at`, or call a GDScript callable; `client/fx/dm_fx_prims.gd` and `dm_fx_layer.gd` drive it, about 0.04 ms for 140 decals where the GDScript it replaced took 0.55, and `client/tests/fx_decals.gd`
  holds every drawn float); `register_types.cpp` registers them, entry symbol
  `dmcore_library_init` (`client/bin/dmcore.gdextension`).
- `native/src/core/`: the simulation, free of Godot types: `world` (tables, the enemy brain, damage and kills, queries, statuses on bodies), `niche` (the Bone Abbess's Skull Niche: the inert body's whole brain), `boss` (what a boss calls: a hostile zone, the zones of a kind, a body's health and its wire record),
  `thralls` (the thrall brain and the legion: raise, make_room, formation, separation, rally, deaths), `corpses` (the corpse field),
  `affixes` (the elite affixes), `support` (the Crypt Deacon's raise, Sanctify and curse), `nave` (the Censer Bearer's pulse, the Lich Acolyte's Unbind, the Templar's shield, the Gargoyle's sight line), `cloister` (the Weeping Seraph's ward with Godot's sort, the Plague Doctor's flask and pool), `pyre_fen` (the Cinder Pyre's and the Mourning Fen's burning ground, coal, hex, pulse, lure and chain), `body` (what a status set needs from its owner, shared by enemies and thralls), `thrall` and `corpse` (their records and enums), `status` (the status
  set, the same rules as `DmStatusSet`; its rule table comes from `client/core/dm_status_rules.gd`), `grid` (dense XZ grid rebuilt per tick by counting
  sort), `navgrid` (the navmesh's triangles on a grid, for keeping bodies on it; DmNextWorld gives it every region, switches them with the seals and swaps the Depths floor's polygons floor by floor), `events` (the per-tick event buffer and its type numbers), `rng` (PCG32 per entity), `crowd_view` (the presentation of the crowd: one view per creature, fed plain rows,
  writing the MultiMesh buffers; it does not touch the simulation), and the co-op pieces: `wire` (byte writer and bounds-checked reader), `replica`
  (the format's constants and a core's co-op counters), `snapshot` (the 20 Hz message, both ways), `reliable` (event batches and the baseline, both ways) and `puppet` (a guest's step, snapshot
  records and reliable records).
- Tests: the `core_*` suites, `crowd_view.gd`, `game_scene.gd` and the co-op suites (client/README.md "Set up and test"). Run
  `bash tools/check/prep.sh` first in a fresh checkout: a script run in a
  project that was never imported hangs.
- `SConstruct`: builds into `client/bin/libdmcore.<platform>.<target>.<arch>.<ext>`.
- `build.sh`: links godot-cpp into native's thirdparty folder (not committed) from one shared cache per commit
  (`~/death-muffin/native-cache/godot-cpp-<commit>`, cloned and compiled once) at the pinned commit (1e79263, built for `api_version=4.7`) and builds
  Linux `template_debug` (what the headless tests load) and Windows `template_release` (the game's export; mingw-w64, C++ runtime linked
  statically so players need no extra files). Runs at `nice -n 10` with 4 jobs; the first build of godot-cpp takes about 6 minutes, later
  builds only recompile what changed, in any checkout or worktree (`SConstruct` keeps each directory's build records next to its files: godot-cpp's in the cache, a checkout's own in the checkout). Builds take turns on a lock next to the cache (`<cache>.lock`): two scons runs against the
  same godot-cpp break each other.

## Crash notes

Godot's own crash log prints `???` for code it has no symbols for, so a crash inside the core used to arrive without a place. The core
writes a short note while the game crashes (`native/src/crash_note.cpp`): the build, what happened and, for each stack frame, the module and the
offset into it (`#0 libdmcore.windows.template_release.x86_64.dll+0x23a0`). The boot arms it once (`DmCore.arm_crash_note`, `client/main/main.gd`)
with `user://core_crash_note.txt`; the next start's automatic crash report (DmCrashWatch) puts the note first in its log and in `coreCrash`.
- Windows: an unhandled-exception filter chained to the one Godot set (its crash handler runs right after); it walks the stack from the
  crash's own context with the x64 unwind data every module carries, using static buffers only. Linux (headless tests): handlers for
  SIGSEGV, SIGBUS, SIGFPE and SIGILL that start at the crashing instruction and hand the signal on to Godot's handler.
- `native/build.sh` builds the Windows core with debug symbols and moves them into a symbols folder under native's build output (not committed) before the library ships (stripping
  moves no code, so the shipped size stays what it was); `publish-godot-client.sh` keeps them per build in `~/death-muffin/symbols/<version>/`
  (the newest 40). `node tools/crash/symbolize.mjs <bug report id>` turns a report's note into function names and source lines.
- Tested by `client/tests/crash_note.gd`: the format, a real crash inside the core in a child process (`DmCore.crash_for_test`), Godot's
  handler still running after the note, and the report carrying it. The Windows half has not crashed on a real Windows PC yet (KNOWN-GAPS).

## Build machine (the VPS)

`g++` (system), SCons 4.11 (`python3 -m pip install --user scons`, `~/.local/bin/scons`) and `mingw-w64` (apt) switched to the posix
thread model (`update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix`, same for `gcc`), which the C++
standard thread types need.
