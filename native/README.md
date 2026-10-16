# The combat core (C++)

The combat core of the rebuilt client (ROADMAP "Now: the rebuild", DECISIONS B34, B42). It owns every enemy, thrall, corpse and
status in flat arrays and steps them once per 60 Hz tick; GDScript (`client/`) owns the hero, rites, bosses, rewards, HUD and flow.
Today's runtime it replaces is mapped in the private audit `~/vps-handoffs/DeathMuffin/audit/2026-10-16-combat-map.md`.

## Design (the contract every change keeps)

- **What the core owns:** enemies (stats, state machine, timers, targeting, movement, attacks), thralls (raise, brain, attacks,
  expiry), corpses (lay, expire, atomic consume), statuses and affixes on every entity, the spatial grid and the wave director's
  spawn bookkeeping. Heroes and bosses are **external entities**: GDScript writes their position, radius, alive flag and target
  weight each tick, so every query and target choice treats them like today (bosses edge-counted, heroes weight 1.0, shieldbearers
  0.55, thralls 1.1).
- **One step per tick:** `step()` runs, in today's order, heroes' pending commands, the director and every enemy in spawn-id order,
  corpses, then every thrall in raise order (combat map section 1). Ties break the same way (strict `<`, then that order). The thrall host's soft
  separation runs first with the heroes, on the positions the last tick left; enemies see the positions thralls ended the last tick with.
- **Commands from casts and bosses are synchronous:** rites stay GDScript and call `damage(id, amount, source) -> {dealt, killed}`,
  `enemies_in_radius` (the lane, the cone and the circle of a rite are GDScript on it, `client/next/rites/dm_rite_module.gd`), `apply_status`, `corpse_pick / corpse_consume`, `raise_thrall`, `remove_enemy` directly, and read the result at once,
  because today a kill resolves inside the caller (Wailing Skull's extra hop, Bone Prison skipping the dead). A kill inside such a
  call runs the core's own death work at once (director count, Vengeful, statuses cleared, corpse laid) and is handed to GDScript
  (rewards) before the call returns. Kills inside `step()` (thrall swings, DoT, hazards) come out in the event buffer, in order.
- **A living body can leave without dying (`remove_enemy`):** a boss's adds go with the boss (no death, no corpse, no kill credit, no Vengeful). The body is out of the table at
  once (later bodies keep their ids and order, the queries see it before the next step) and the buffer gets `EV_ENEMY_REMOVED` with one int, 1, where the removal of a dead body
  has none: the host must not count it among the dying (`DmCoreHost` does not), and a guest's core drops it on the same event. A dead or unknown id is refused (a dead body leaves
  by itself 4 s after it fell). The crowd fades a body that vanished alive (it never played a death).
- **No per-creature calls per tick:** per-creature work never crosses into GDScript during a tick. GDScript reads one ordered event
  buffer per tick (spawned, state edges, telegraphs, cues, damaged, died, thrall raised/died, corpse added/gone, status changes,
  zones) and bulk arrays for the HUD, minimap and auto combat. Cast-driven calls are bounded by casts, not by creature count.
- **Thralls and corpses (thralls.cpp, corpses.cpp):** a thrall is a flat-array body like an enemy, in raise order (dead bodies stay 1.4 s, then
  a removed event). `raise_thrall(stats, owner, pos, yaw, cap)` takes the stats GDScript computed (`DmThralls.raise_stats` and
  `colossus_stats` stay GDScript; the dictionary is today's `configure()` keys), crumbles the oldest ordinary thrall first (a Colossus last, weight
  2) to fit the cap, replaces an older Colossus, and returns the id. Hero blows on enemies and thralls' blows on enemies go through `damage` with the
  thrall's id as the source. An enemy blow on a thrall is applied inside the core (damage taken, barrier, death "killed"); a blow on a hero is still an
  `EV_TARGET_HIT`; a thrall's blow or burst on a boss (an external of kind 1) is `EV_THRALL_HIT_EXTERNAL`, for GDScript to give the brain. Thralls
  and enemies share one status implementation (`Body`): applying, stepping, DoT lumps, stun and the multipliers exist once.
  A corpse is laid in `kill()` after the statuses are cleared and before `EV_ENEMY_DIED` (today's listener order: director, affixes, statuses,
  corpse field, rewards); a toxic one bursts after 5 s into a hostile pool zone (per-zone pulse period, kind `ZONE_TOXIC`). `corpse_pick`,
  `corpses_in_radius` and `corpse_consume` are synchronous and atomic, so two casters on one corpse get one winner.
- **Affixes (affixes.cpp):** `DmAffixSet`'s rules run in the core: the director rolls (`DmAffixSet.roll` stays GDScript) and passes the list to
  `spawn_enemy`; the bell's ring and toll, Hungering's meals (the corpse field's atomic consume, reason `devoured`) and the shroud's 0.1 s check run
  after the body's move, paused while it rises, staggers or burrows (the shroud check excepted). The client draws them from `EV_AFFIX_MOMENT`
  (tell, toll, hungering, vengeful, unveil) and the toll `EV_TELEGRAPH`. Rites call `cover_miasma(id)` (a friendly Miasma covers the body) and
  `strip_shroud(id)` (Last Light, a Warden sweep). Vengeful runs inside `kill()` in today's listener order: its Risen get their ids, rolls and
  `EV_ENEMY_SPAWNED` there, but join the table in `flush_spawns()`, at the end of the tick or of the `DmCore` call that killed (a kill can happen
  while the caller holds a reference into the table: a DoT lump, a swing that kills a bursting thrall).
- **Numbers from data, not retyped:** `load_enemy_defs` / `load_tuning` (enemies.json), `load_status_defs`, `load_legion_tuning` (abilities RALLY, fen
  HAG_HEX, statuses PLAGUE_BURST, gameplay_legendary LEGEND, runes RUNE_TUNING.colossus, combat/enemies damage_scale) and `load_sim_consts` (the
  constants of `sim_consts.gd`, `dm_corpse_field.gd` and `dm_thrall.gd`, which `client/core/dm_core_data.gd` reads from those files).
  `DmCoreData.load_all` does all of it. The defaults compiled in are today's values, so a core that loads nothing still plays;
  `client/tests/core_thralls.gd` asserts the defaults equal the data (`DmCore.tuning()`).
- **Timers like today:** every "x seconds" timer accumulates or counts down in doubles exactly as the GDScript did, so 0.1 s still
  lands on tick 7 and a 0.3 s countdown on tick 19 (combat map section 12). Positions stay float32, scalars double.
- **Seeded randomness:** one PCG stream per entity, seeded from the director's seed and the entity id, so a seeded scenario replays
  bit for bit. Live play seeds from the clock, like today's `randomize()`.
- **Movement:** paths from `NavigationServer3D` (batched, cached per target cell), steering and separation in the core, positions
  clamped to the navmesh, heroes and walls pushed out as circles. This replaces Godot's RVO avoidance: crowds may flow slightly
  differently, a difference written down for Helix to judge (B42). No physics body per creature.
- **Drawing:** one MultiMesh per creature model, level of detail and shadow setting, transforms and animation data written in one buffer update per
  rendered frame, interpolated between ticks; animations play from baked vertex-animation textures. `DmCrowd` does it (`dm_crowd.*`, `core/crowd_view.*`): it reads the core's
  tables and damage events right after each step without consuming the events, and keeps every creature's view state (turn, legs, clip, blend, flash, knock, death) itself, so no
  presentation field lives in a world, enemy or thrall struct. Its input is a plain row per creature, hit and corpse (client/crowd/README.md "Driving the crowd"); a co-op
  guest's puppet core fills the same tables and damaged events, so `DmCrowd.sync(core)` draws it as it draws a host.
- **Co-op (host-authoritative, B28, B40):** the host core packs one compact snapshot at 20 Hz and the discrete events as reliable batches; a guest's core runs in
  puppet mode (`set_puppet(true)`): no brains and no rules, bodies that appear from spawn events, ease toward snapshots (today's puppet easing) and go on removal events,
  and an event buffer that carries what GDScript sees on the host, derived from state edges and hp drops where today's puppets derive it. Messages carry a version and a
  hash of the data tables, so a phone or a newer build refuses cleanly. Calls, byte layout, limits and cost: "Co-op" below.
- **Proof of "same game":** pure rules replay today's parity and golden fixtures; behaviour is compared with a seeded scenario
  (kills, damage, time to kill, thrall uptime) between today's game and the core within stated tolerances: "Proof of same game" below.

## Proof of same game

Two layers. The rules are replayed against today's code (`client/tests/core_*.gd`, `rites.gd`, `boss.gd`: bite timing, cones, clouds, corpses, statuses, thralls, every rite's formula). The behaviour that comes out of all of them
together is compared by playing one seeded scenario in both games and tabulating what happened. `node tools/rebuild/compare-scenarios.mjs` runs both sides (`godot/tests/parity/scenario.gd` for today's game,
`client/tools/parity_scenario.gd` for the rebuilt client), one Godot process at a time under `nice -n 10` with `--fixed-fps 60`, seed by seed, and prints the table. Seeds 1 to 5 take 5.7 minutes (today's game 44 s a run, the client 24 s);
`--seeds=1-20` takes 23 minutes and is the run that settles a close call (`--level=`, `--difficulty=`, `--seconds=` change the scenario on both sides; `--from=<dir>` tabulates an earlier run).

**The scenario:** the Hollow Graves, one Gravecaller (discipline 2) at level 10 on the kit's default loadout (every rite of it is unlocked; the signature, Command: Rend, comes at 10), Easy difficulty and Easy auto combat on (today's
`DmAutoCombat` / `DmAutoDodge` decisions, which walk the hero too), the director's normal waves (cap 28, 9 a wave every 6.5 s, elites at 3.5 %, processions), 180 s of game time, the director's stream and the global stream seeded, the in-memory mock
backend. The Graves' enemies are level 1 whatever the hero's level (the Graves have no level scaling). The hero cannot die: his health is refilled when a blow lands, and the blow is counted. Everything is read from the host's signals and
the caster's events (the director's, the enemies', the thralls', the hero's), the legion is sampled once a tick by the tool; the game scenes get no code for it.
- **Switched off in today's game** so both play the same rules (the client has none of these yet; "Differences from today's game"): the kill-credit consumers (XP and level-ups mid-run, Soul Harvest's free casts, the Kill Chain, loot), the weekly Omen,
  Grave Surges and the Bellringers' censer. Easy auto combat is ticked on the physics clock on both sides: today's input ticks it with the wall clock, which a faster-than-real-time run stretches (`DmNextAutoCombat.clock_ms`).
- **A stuck hero is set back at the door and counted.** Easy auto combat steers straight at the nearest enemy and has no path round the graves (`godot/next/feel/README.md`: no `DmNav`), so it parks the hero against pockets of tombstones, for good (around (6, -29), (-4, 1), (13, -23),
  (3.5, -4) and (4, -20)): a run that parked kills half as many as one that did not, which drowns every other difference. A hero who moved under 1 m and cast under 4 times in 10 s is put back at the door (a player would walk him out), and `unsticks` counts it.
  Both games park the hero at the same places and as often (1.6 and 1.4 times a run), which also says the area scene's colliders are today's.
- **A seed is not a replay.** Runs of one seed agree for the first seconds and then drift apart, in both games (the hero's walk through a crowd); so the table averages seeds, and says how loose the average still is (the noise column: two standard errors of the difference).

**Tolerances** (the means over the seeds; a change here is a change to `tools/rebuild/compare-scenarios.mjs` too):
- kills +-15 %: how many die is the pace of the fight, and more than a seventh is a fight a player would call different.
- hero damage dealt +-15 %: the rites' share of the work; it follows the kills, but a rite that hit too hard or too soft shows here first.
- thrall damage dealt +-20 %: the thralls fight on their own timing and places and a few blows swing a run, so they get more room.
- median time to kill +-20 %: spawn to death; most of a body's life is its walk to the fight, which the core's crowd spacing changes on purpose (B42), and the median ignores the tails.
- thrall uptime +-10 percentage points (live thralls over the cap, and the time at the cap): whether the legion is up is what the class is; 10 points is half a thrall of a cap of 5.
- damage taken by the hero and his thralls +-25 %: a few blows decide it. The hero alone is hit about twice a run (3.6 each, the thralls stand in front of him) and measures nothing; what the enemies do to the hero and the legion together is the number.

**Result** (2026-10-16, `origin/main` f5f9e758 with the scenario tools; no game file differs; Hollow Graves, level 10, Easy, 180 s, seeds 1 to 20, means; today / client):

| metric | today | client | difference | tolerance | noise (2 s.e.) |
|---|---|---|---|---|---|
| kills | 191.2 | 186.8 | -2.3 % | +-15 % | +-7.4 % |
| hero damage dealt | 10451 | 10143 | -3.0 % | +-15 % | +-9.0 % |
| thrall damage dealt | 2272 | 2125 | -6.5 % | +-20 % | +-16.7 % |
| median time to kill (s) | 11.42 | 11.42 | 0.0 % | +-20 % | +-14.6 % |
| thrall uptime (live / cap) | 95.1 % | 94.7 % | -0.4 pp | +-10 pp | +-1.0 pp |
| time at the thrall cap | 92.9 % | 92.3 % | -0.7 pp | +-10 pp | +-1.3 pp |
| damage taken, hero and thralls | 123 | 122 | -1.3 % | +-25 % | +-33.9 % |

Every metric is inside its tolerance. Underneath, too: the share killed and the median time to kill of each of the nine kinds (how many of each kind spawn is drawn at random and wanders, rats 8.7 / 14.1 a run), the casts of each rite (209 / 201 Bone Needles, 56 / 55 Marrow Spears, 9.6 / 9.7 Exhumes, 9.3 / 9.3 Miasmas a run), the
thralls raised (9.6 / 9.7) and lost (4.5 / 4.7, by the same enemies: ghoul 1.6 / 1.4, moth 0.7 / 0.7, penitent 0.9 / 1.1), and the blows on the thralls from each kind of enemy and from clouds and pools. Seeds 1 to 5 alone (5.7 minutes) are
too few for the last row: its noise band is +-47 %, and that sample read -32.5 % (164 / 110) with the others inside their tolerances; seeds 1 to 20 are the verdict. At level 1 (the first-hour hero, 100 hp) it agrees as well: ten seeds read kills +0.1 %, hero damage +3.1 %, thrall damage -5.9 %,
time to kill +2.8 %, uptime -0.1 pp, damage taken -8.8 %; an earlier twenty-seed run read damage taken +24.2 % (noise +-23.8 %), inside the tolerance and a repeat of seeds 1 to 10 the other way, which is the noise.

**No behaviour difference was found** in the metrics, so none is added to "Differences from today's game". What the scenario cannot see: the hero is almost never hit (the thralls and his range keep the enemies off), so the core's attacks on a hero are proved by
`client/tests/core_enemies.gd`, not by this table; bosses, rewards, loot and the other disciplines are not in it (their items bring their own comparisons).

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
| flags | 1 | bits 0-3 state (`EnemyState`), 4 elite, 5 dug in, 6 aim follows (ATTACK, ERUPT), 7 affix byte follows |
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
test's fight (`client/tests/core_coop.gd`), against about 180 bytes per enemy as dictionaries today.

**Reliable batch** (kind 2): header, number (u32), record count (varint), records. **Baseline** (kind 3): header, number, clock (f64), count, records. A record is a type byte and:
- 1..32, an event of the buffer GDScript reads: entity id (varint), counts (`ints << 4 | floats`), the ints (zigzag), the floats (f32). Three have a tail: spawned (1) and thrall
  raised (22) end with the body's state now, health (u16), yaw (u8) and time in state (u8) (22 adds the swing counter as a varint and a rally byte); status changed (14) ends
  with a count and 4 bytes per status in the `DmCore.statuses()` layout, the set as it is when the batch is made.
- 101, a name: table (0 area, 1 corpse reason), index, length, bytes. Areas and corpse reasons are numbers in events; the names go before their first use.
- 102, a thrall's new maximum health: id, f32 (`set_thrall_stats` with a `maxHp`); guests know health as a fraction of the maximum.

On the wire as events: spawned, died, removed, cue, zone, zone pulse, zone gone, statuses cleared, status changed, status dot, status expired, corpse added, consumed, gone and
ruptured, thrall raised, died, removed and status, affix moment, and the bell's toll telegraph. Derived on the guest from the snapshots (so its buffer has them, once per change
between two snapshots): enemy state, attack, the cone, slam, dust and erupt telegraphs (the place and aim of the snapshot, the wind-up less the age it showed, at least 0.05 s as in
`dm_enemy.gd`), damaged (the hp drop, and the rest of the health at a death), thrall state, swing and damaged. Host-only, never sent: a blow on a hero (`EV_TARGET_HIT`: the host
applies it to every member), a thrall's hit on a boss, Withered's spread, the plague pool and the bell's heal. A guest's buffer is for effects and the HUD: its GDScript must not
run rewards, loot or the kill report from `died`.

**A puppet core** (`set_puppet(true)`; switching clears every body) steps with `step(dt)`: a body eases toward its last snapshot by `1 - exp(-15 dt)` and snaps above 6 m, yaw
likewise, its ground speed is the eased motion smoothed at 10 per second (0 below 0.3 m/s), time in state counts up and is taken from a snapshot when it differs by more than
0.1 s, status chips count down. Queries (`enemies_in_radius`, `enemy_info`, `thralls_in_radius`, `thrall_*`, `corpse_*`, `statuses`) read the same tables as on the host. A puppet's
`enemy_info` has `net_pos` (where the last snapshot put the body). Commands the host owns (`spawn_enemy`, `remove_enemy`, `damage`, `stun`, `apply_status`, `remove_status`, `raise_thrall`,
`kill_thrall`, `sacrifice_thralls`, `rally_thralls`, `recall_thralls`, `set_legion_burst`, `set_thrall_*`, `curse_thrall`, `strip_shroud`, `cover_miasma`, `remove_enemy`, `corpse_add`,
`corpse_consume`, `snapshot`, `snapshot_parts`, `take_reliable`, `baseline`, `set_replication`) are refused: they return 0, false, nothing or (`damage`) `{dealt: 0, killed: false, refused: true}`, print
one error per command, and count in `replication_stats().commands_refused`. Heroes and bosses are brain input: `add_external` returns 0 and `set_external` does nothing on a puppet. `replication_stats()` counts both roles (messages built and applied,
stale snapshots, ids not yet met, desyncs, refusals, the sizes of the buffers on the per-tick path, which the test holds steady).

## Differences from today's game

Every place the core does not do exactly what today's GDScript does, so Helix can judge them in the test build (B42):
- **Crowd spacing:** Godot's RVO avoidance (applied a tick late) is replaced by the core's own: a moving body does not drive into a neighbour
  in its way (that part of its velocity is dropped, so a crowd queues and slides around; one blocked head-on sidesteps on its own flank side, without
  stepping into anyone else) and is steered away from it, and after the moves every
  overlapping pair, moving or standing, eases apart by 30% of its overlap per tick (at most 15 cm a tick, the bigger body giving way less).
  Forty bodies closing on one hero pack around him with no pair sunk into another, and a hound blocked head-on by a standing body goes around it
  (`client/tests/core_enemies.gd`, crowd spacing). The one
  planned difference in feel.
- **Walls and the hero:** today `move_and_slide` slides a body along walls and the hero's capsule; the core moves it, pushes it out
  of the hero's circle and snaps it back onto the navmesh. Close to today on open ground, may differ in corners.
- **No idle LOD:** today a far idle body thinks at 10 Hz; the core runs every body at 60 Hz (cheap enough in C++). Idle wander
  changes a little; nothing a player sees.
- **Brains first, then movement:** today each body thinks and moves before the next one thinks; the core runs every brain, then
  every move, the crowd spacing, then every affix. Bodies never read each other's positions in the same tick except for crowd spacing, which was
  a tick late anyway.
- **Thralls move like enemies do:** no `move_and_slide`; the core moves the body and snaps it back onto the navmesh (thralls pass through the hero
  and enemies today too: their mask is the world only). A thrall thinks and moves before the next one does, as today. The thrall agent's RVO is
  off by default today and is not ported; the host's soft separation (radius 0.4, push 6, per legion) is. Paths are followed at 1.0 m (the thrall
  agent's `path_desired_distance`), without the agent's re-path when 2 m off the line.
- **A thrall's 1.4 s linger is ticks:** today a scene-tree timer frees the dead body; the core counts 1.4 s of ticks, then sends `EV_THRALL_REMOVED`.
- **Bosses in a thrall's scan come after the enemies:** today they join the `dm_enemy` group when summoned, so they can come earlier in group
  order; only exact ties in distance could notice. A boss is an external: `alive` must be false while it cannot be hurt (Mire Mother sunk).
- **Status on a dead body:** a blow that kills (a wraith's chill, a bone mage's hex) still reports `status_applied`, but the dead body keeps
  no status (today the dead body's set takes it, unseen).
- **Hostile zones step with the enemies:** the toxic pool made by a bursting corpse steps in the enemy phase, before corpses and thralls. Today its
  place among the thrall bodies depends on when it was made, so a pulse can come one tick earlier or later relative to a thrall's brain.
- **Corpses:** the Veilwalker's echo corpses are not ported (they come with the Veilwalker). `corpses_in_radius` has no filter callback: GDScript
  filters the ids it returns. The extra "risen" corpses are not snapped to the navmesh, and the toxic pool's damage level is 1 unless GDScript calls
  `set_area_level` (today the field's `area_level` callback is never set, so pools hurt as level 1; kept).
- **Signals with no listener today stay events:** `plague_pool` (a fallen plague bearer's pool) and `bell_heal` are events for GDScript to act
  on; today nothing creates the pool or heals allies from them. The core creates no pool zone for it.
- **Thrall rolls are seeded:** a thrall's repath/scan phase, its status phase and the teleport offset come from its own PCG stream, as enemies'
  do, where today `randomize()` and global `randf()` are used.
- **`damage` on a thrall returns the health lost** (after damage taken and the barrier), not the raw amount.
- **Crowd drawing (`DmCrowd`):** the creatures are MultiMesh instances playing baked clips, so what lived on each creature's node today is not in this pass:
  the thralls'
  spirit rims, gear tint of kit armour and the kit weapon's tier colour on a thrall's prop (the props themselves are baked: `client/crowd/README.md` "Hand props"), the Mire Leech's wobble,
  the Gargoyle's dive (not in the core yet), the fade-out of a sinking body (it sinks the same 0.9 s but is not faded to transparent), the drawn-body crowd separation
  (`_separate_crowd`; the core separates bodies), fire and fen death effects, and the animation LOD (a far body
  updates at 24 or 10 Hz today; every drawn body updates every frame). Effects need the event consumer, which is its own item.
- **Crowd views take the live nodes' rules where they differ from `DmEntityViews`:** a flinch plays when the core enters HURT (`DmEnemy`), not on every flash; the flash decays by
  6 per second for an enemy and 5 for a thrall (`DmEnemy`, `DmThrall`), and the killing blow leaves no flash on the body; an enemy rises from 0.9 x its model's height below the ground
  (`DmEnemy`; `DmEntityViews` says 1.7 m); a recoil starts on every hit whose flash had fallen under 0.5, at any frame rate (today at 60 fps it depends on the frame time).
  Turn, speed smoothing, knock, settle, topple, corpse adoption and the shadow budget are `DmEntityViews`'. A fallen thrall plays its death and sinks after its 1.4 s (today the node is
  freed then).
- **Ground speed from the core:** the legs use the core's speed of the tick, smoothed (tau 0.18), where `DmEntityViews` measures the drawn displacement and `DmEnemy` the wanted velocity
  (snapped to 0.25 m/s); the displayed yaw turns toward the interpolated sim yaw. A body that moves more than 3 m in one tick is drawn at its new place (a new rule).
- **Dice:** the idle rate and start, the choice among `attack2`, `hurt3`, `death2` and the recoil's side come from each body's own seeded stream (today `randf` and `randi`).
- **Shadows:** the thralls always cast, as today (`DmCasterBudget`); with 32 thralls that is most of the shadow cost of a Full Party, to be measured on Helix's PC. Level-of-detail meshes
  by camera distance (32 m, 60 m) are new: today every creature is drawn at full detail.
- **Paths:** the core follows `NavigationServer3D` paths itself (24 points, advancing at 0.5 m like the agent's
  `path_desired_distance`) instead of a `NavigationAgent3D`.
- **Affixes:** a Miasma cover holds the shroud off for 0.35 s of game time (today 350 ms of wall-clock time, `dm_miasma_ms`). Vengeful's ring turn
  comes from the elite's own stream (today an unseeded `randf()`), and its Risen cannot be found by a query until the call or tick that killed the
  elite returns (they are rising, so nothing could hurt them anyway). The bell's ring and the burst use the body's position this tick, where today
  they read the drawn (interpolated) position. A body killed by its own toll's chain (the toll kills a bursting thrall whose burst kills the body)
  no longer eats a corpse in that same tick (today the dead body could heal).
- **The game scene on the core (`client/next`, the ports of today's files; `client/code.list` "Ported")**:
  - The hero is a circle in the core: the capsule collider his body had for the enemies is gone (the core pushes bodies out of him, "Walls and the hero"). He starts, and gets up after a
    death (4 s, as today), at the Graves' door: the Chapterhouse is not loaded yet.
  - The director makes only the defs the core runs (robber, hound, penitent, sac, moth, bat, ghoul, rat, risen); a roster entry outside the list is skipped, as one without a scene was. So the Bellringers'
    procession has no censer to lead it (penitents and robbers), and the Kennel is hounds and rats. It passes the level to the core as an integer. The affix roll is today's function with the director's own random stream.
  - A hero away from the area for 15 s no longer frees the area's living enemies (the core has no call that removes a body yet): the queued spawns are dropped, the bodies stay. Grave Surges are not ported.
  - The effects of a spawn (the rising dust and smoke, the elite's ring and sound) play when the host dispatches the spawn event, at the end of the tick that made the body; a swing's impact timer starts
    when its attack event is dispatched and runs on the rendered frame clock, as the node-based fx did from the state change.
  - The hover pick asks the core for the bodies within 4.5 m of where the cursor's ray crosses the plane 0.9 m above the ground and takes the one whose chest is nearest the cursor on screen within 46 px; today
    it measured every enemy. The same answer unless a tall body's chest is more than 4.5 m along the ray from that plane. A click on an enemy only names it until the rites come (no attack chase, no auto combat).
  - The enemy fx dropped, for the "Crowd effects" item: the shrouded body's fade (the crowd has no alpha), an elite's glow, the censer's incense, the Pyre's and the Fen's idle effects, the acolyte's
    reach ring (their defs are not on the core) and the Flagellant's frenzy motes. The status tells and the fliers' motes play near the hero on `DmEnemyFx`'s 5 Hz ambient tick at today's rates a second
    (today rolled them every rendered frame), for the bodies with a status (`status_changed`, read from `DmCore.statuses`) and the ones that fly. An elite keeps its ground ring, and an affixed one its affix marks and motes, following the drawn body; every thrall stands on today's ground ring (champion gold, an ally's dimmer); the corpses get today's rings and the toxic disc
    (`DmEnemyFx`), their cap counted by each ring's own end (today's counted handles that turn alive a frame late, so a wipe could pass it). The sac's toxic pool has no visual of its own, as today.
  - The core does not report what an enemy does to a hero besides damage (the Frost wraith's chill, the Drowned Sexton's hook with its root and pull): `DmHeroBody.dm_enemy_effect` is kept for them and nothing calls it yet.
  - The game reads the core's constants from this project's `data/` and `sim/`; the constants of `dm_corpse_field.gd` and `dm_thrall.gd`, whose files are not here, stay the compiled-in defaults (equal, asserted by `core_thralls`).
- **The front flow (`client/main`, `client/net`)**: login, register, the online gate and character select are today's code on the test server (`client/README.md` "The test server"). Not the same:
  there is no Log out or Switch character (the full HUD owns them), no automatic crash report and no
  update notice; a bag or progression the server fails to give sends the player back to the login screen with the server's words (today the
  game starts with an empty bag); the game starts only on the test server or the local mock. The hero is built from the server's bag and progression, read once at the start: nothing is saved or
  refreshed during the run; the Reaper has no model or rites yet (the four necromancers play).
- **Co-op messages:** one binary snapshot with every body, thralls included, at 20 Hz replaces today's dictionaries (enemies 6 to a packet at 20 Hz, thralls at 15 Hz plus a full
  reliable copy at 1 Hz). Values are quantized: positions to 1 cm, yaw to 1.4 degrees, health to 1/65535 of the maximum, time in state to 10 ms. The animation name is not sent
  (`anim` today): the crowd view picks clips from the state and the eased speed.
- **Snapshots are cut by body ranges, not fragmented:** the old code kept each packet under 1,392 B by sending 6 enemies a packet; the core's snapshot is `DmCore.snapshot_parts(tick, 1300)`
  (client/next/next_net.gd), one packet in a fight under 1,300 B and two at the Full Party's largest, each part applied by the guest as it arrives. Over the UDP lane a lost part loses
  only its bodies' 50 ms update; the WebSocket fallback loses nothing. Thralls went at 15 Hz with a reliable copy at 1 Hz and enemies' cues over their own reliable RPC: now all at 20 Hz in the one
  snapshot, and the cues are the core's events in the reliable batches.
- **What stays GDScript beside the core in co-op:** the hero positions (the session's own 20 Hz snapshot), hero vitals (`Net`, 20 Hz), the rites' events, states and gestures (DmRiteCaster) and the King's
  state at 20 Hz and events (DmBossHost) travel as today, by RPC over the same relay peer. A guest's hero is an external of the HOST's core (its id is told in a table), so enemies chase and hit it there and
  its thralls are the host's bodies; the guest's own core has no externals at all.
- **A guest sees a change between snapshots once:** a state that lasts less than one interval (50 ms) is never seen, and two hits between two snapshots are one damaged event with
  the sum, as today's puppet's hp difference is. A derived thrall swing has target 0 and damage 0 (the host's event knows both); a puppet's `enemy_info` has the def's damage and
  speed, not the body's rolled ones, and no target or cooldowns. The telegraph's place and aim are the snapshot's, its seconds the wind-up less the age the snapshot showed.
- **Deaths come as events, not as a state in a snapshot:** the body stops where the guest drew it (up to speed / 15 m behind the host), while its corpse lies exactly where the host laid
  it; the guest's buffer gets `damaged` with the health the last snapshot showed, then `state`, then `died`. A guest's corpses have no lifetime: they go when the host says so.
- **Order of a guest's buffer:** forwarded events in the host's order, the derived ones where the packet that caused them was applied; a death's state edge comes just before its `died`,
  after the corpse events (the host's comes first).
- **More reaches guests than today:** the slam, erupt and dig-in cues are on the wire (today only shield_block, sanctify and unbind replicate, so a guest saw no dust at a slam).
  A snap above 6 m is not counted as walking speed (today's puppet counts it, and its walk clip sprints for a moment).
- **Not replicated yet, stays GDScript:** bosses (state, phases, telegraphs, their statuses), hero vitals and positions (the session channel), rite events and the visuals they drive, ground drops,
  party calls and chat; guests still send their intents (move, cast requests) to the host as today. The per-kind extras of today's enemy snapshots (the deacon's `rz`, the gargoyle's
  `dv`, the sexton's `hk`) come with those kinds' ports to the core.
- **The Gravecaller's rites on the core (`client/next/rites`, the ports of today's files; `client/README.md` "The Gravecaller's rites")**: the rites are today's GDScript and call the core synchronously, so a kill still
  resolves inside the cast (Wailing Skull's extra leap, Bone Prison skipping the dead, the Litany's loops). What is not the same:
  - **Ossuary Wall is a core obstacle** (`DmCore.add_obstacle`: the same 7 m by 0.8 m box), where today it is a static body on the layer enemies collide with plus a navigation obstacle. The core keeps every
    enemy on the surface out of it (one standing where it rises is put out through the nearer side, as `move_and_slide`'s recovery does) and an enemy's steering does not drive into it, so a body slides along
    it toward its goal and presses there, as on today's collider; thralls and the hero pass. Not ported: the navigation obstacle's avoidance (RVO is not in the core), so a crowd does not curve around the
    wall's ends before reaching it.
  - **A boss is in the rites' queries since the Gravedigger King** (see "The Gravedigger King" below): the fan, the lance, the siphon, the skull, the Scythe's arc and Colossus Mantle's reflect reach it by its id.
  - **Withered's kill credit and its hand-on come from the event buffer**, so at the end of the tick that killed (today inside the kill): the DoT's `hit_resolved`, Contagion's and Plague Choir's spread to the neighbours,
    and the corpse-consumed beat of Requiem Wraiths' wisp. A rite's own blows are known at once (`killed` in the reply of `damage`), so nothing a player sees waits for it.
  - **A status on an enemy or thrall is the core's** (`apply_status`): the hero is its source, so the last stacker of a Withered owns the kill as today; the Miasma's lift of the Shrouded ward is `cover_miasma` (0.35 s of
    game time, see "Affixes"), asked for every enemy in a cloud (the core ignores a body without the ward); what an enemy node carried as meta (contagious, the Chain Plague gap) is kept by enemy id in the rite's
    memory and swept once the enemy is gone.
  - **Carrion Seed's fields live in the corpse field's notes** (`DmCoreCorpses.notes`, dropped with the corpse) and its arming and expiry run on the caster's clock in ms, where today they were on the corpse record and the
    field's clock. A seed ends with its corpse as before.
  - **Shots follow the simulation's position** of their target, where today they followed the drawn (interpolated) one.
  - **A blow of zero or less is refused** (`damage`, a boss's too); today `take_damage` applied it. No rite deals one.
  - **Spear rally's mark** is written to each thrall by the rite each tick while the mark lasts (`set_thrall_mark` from `thrall_info`'s target), not read by the thrall; legion size bounds the cost (Legion Champion 5 only).
  - **Not ported with the rites:** the Reaper's nine (they wait for the Reaper, `client/code.list`), the
    socketed runes and the weapon line of the bag (no bag yet: the rune and weapon variants are implemented and tested with the state set by hand), the kill-credit consumers (`DmSessionRewards`; the game scene emits
    `rite_hit` and the core's `enemy_died` carries the killer).

- **The Gravedigger King (`client/next/bosses`; `client/README.md` "The Gravedigger King")**: his brain is today's GDScript, replayed against today's recorded scenarios; his body is an external of kind 1. What is not the same:
  - **A thrall's blow on him lands when the tick's events are dispatched**, after every thrall and enemy has acted (`EV_THRALL_HIT_EXTERNAL`), where today it landed inside the thrall's swing. His brain runs once a tick before the core, so it sees
    every blow of tick N when it runs in tick N + 1 either way; the hits, their order and their credit (the thrall's owner) are the same.
  - **Enemies' support abilities do not reach him** (a Censer's aura, a Deacon's sanctify, a Seraph's ward): he is not in the core's table, where today he was in the `dm_enemy` group. The King's adds are ghouls and a robber, so none of these meets him; the later bosses' items decide it.
  - **His adds are core bodies drawn by the crowd**: the ghoul borrows the robber's model until the roster is baked. They leave with him (defeat or wipe) by `remove_enemy`; the crowd fades a body that vanished alive where the node popped out at once.
  - **A rite's Withered on him is not a `rite_hit` and has no `status_dot` event** (his status set is GDScript's, B42): the DoT lumps hurt him and the brain's credit is the caster as today, but the kill-credit consumers (off) will not see the lumps.
  - **The hero is hurt with his core id as the source** (`DmHeroBody.take_damage(dmg, boss.core_id)`), where today it was the node: the same place of blow, and Colossus Mantle's reflect finds him through `foe(id)`.
  - **No shard cost**: the summon is free in this build (no progression to take shards from); the other rules (`far`, `unknown`, `busy`, `dead`) are today's, and only the Hollow Graves' boss is served. No boss pools: the core makes no zone for a boss.
  - **No collider, agent or state machine on his body** (`DmBoss` is a `Node3D`): nothing read them but the old `DmEnemy` code (the labels are gone, the hover pick and the chase go through the host's queries).
- **The HUD on the core (`client/next/next_hud.gd`, `client/ui/hud`; `client/README.md` "The HUD on the core")**: the same layout, colours, fonts and numbers; drawn to fit 150 draw calls, which changes the
  pixels a little where the same shape is drawn another way. What a player could notice:
  - **Not there yet** (their systems are not in the game scene): the menu row, chat and the report button, the Empower / Quicken panel, party frames of other players, the belt, the Kill Chain, the Omen, the Depths readout, interaction prompts and the Next line. The Spellbook button is drawn and does nothing; the hotbar is the kit's, not the player's loadout. Gold and Soul Shards are the values
    the test server gave at the start; XP does not move (no rewards).
  - **Panels and borders** are pictures of the same fill, border and rounded corners (`DmHudAtlas.nine`, 16 samples a pixel) instead of `StyleBoxFlat` geometry: identical at the design size, and at other
    UI scales the 1 px borders and the 2 and 3 px corners are filtered a little differently. The hotbar's plate keeps its soft shadow (still a `StyleBoxFlat`).
  - **Icons** are scaled once, to at most twice the size they are shown at (ability art 256 to 128 px for a 62 px slot, portraits 480x640 to 96x128), with a Lanczos filter: slightly smoother than the file
    drawn at that size directly. A greyed slot icon (no essence, locked, no corpse) is the same formula as the old shader, baked.
  - **The orbs:** the dish, rings and gloss are the same discs (64 points); the liquid body has 20 steps along its arc where the polygon had 40 (0.2 px off the circle) and the surface ripple is a 2 px ribbon with a
    half pixel feather instead of an anti-aliased polyline, redrawn 15 times a second (30 before) while it moves 10 px a second.
  - **Cooldown sweeps** are exact to the slot's square (a fan of at most five triangles); the old fan of up to 50 chords cut the corners by a pixel.
  - **The minimap's dots** are 14-point discs (64 before); the area fills, edges and doors are drawn first and the hatching of a sealed area after them (before, each area's hatching came between its edge and
    the next area); a dead enemy is not a dot while the core still holds its body (4 s). Loaded areas count as unlocked and the doors between two loaded areas as open (today the world builder's).
  - **Floating numbers** have no 1 px shadow under their 3 px outline (the outline covers it; the dark rim is 85 % where it was 98 % beside the strokes), overlapping numbers draw in pool order rather than oldest
    first, and the thrall and DoT numbers come from the core's damage and DoT events at the enemy's position that tick. The caps (14 hit, 5 dot, 6 thrall, 22 in all) count in real milliseconds, as today.
  - **The target frame** reads the core's status bytes (a Withered pile past 255 stacks is read from `status_stacks`); a status the HUD has no icon for is not listed, as before.
  - **"N slain here"** counts every enemy that died in the area (no rewards yet: a solo hero's kills and his thralls', as the ledger will count them).
  - **Pieces:** every readout group can be moved and scaled (`DmHud.set_piece`, `set_layout`; `opts.hud_layout`) and the HUD scale setting is `opts.hud_scale`; with the defaults nothing moves.

- **Easy auto combat and the benchmark (`client/next/feel/dm_next_auto.gd`, `client/next/perf`; `client/README.md` "The benchmark")**: the decisions are today's code (`DmAutoCombat`, `DmAutoDodge`) and so are the intents it sends. What is not the same:
  - **It reads the core, not nodes:** the enemies by the bulk arrays (`enemy_ids`, `enemy_positions`, `enemy_states`) in spawn order, the corpses by `corpse_ids` and `corpse_positions`, within 40 m and at most 256 (today's list was every corpse; the decision
    only looks at those in range of a rite). What the arrays do not carry comes from tables its host signals keep, so it knows a body from the end of the tick that made or hurt it: the radius, elite flag, area and health (spawn and damaged
    events), a swing's wind-up (the attack event's seconds on the wall clock, as the boss telegraphs are) and a corpse's kind (the corpse event). A burrowed or erupting body is skipped (`DmFoe.hittable`).
  - **Its hazards are the core's zones:** the dust clouds and toxic pools from `zone` events (the group of `DmHostileZone` nodes is gone), padded by a hero's radius as before.
  - **Its gate is closed** in the rebuilt client until the settings exist (`gate_probe` opens it: the benchmark, the tests). **It runs on the physics clock** (`DmNextAutoCombat.clock_ms`, ticks at 60 a second), where today's reads the wall clock: the same
    cadence at real time, and the same fight when the game runs faster than real time (`--fixed-fps`, the headless processor test).
  - **The benchmark has the Hollow Graves and the Gravecaller only** (other rooms and classes are refused); its Standard setup is the Graves. The fight is today's (seed, health, counts, rules), held through the core: the count is trimmed with `remove_enemy` (a Vengeful
    Risen or a boss's add past the cap leaves like a node freed: no death, no corpse), the 32 thralls are raised into the core with no cap, the King is woken through the real summon (free, see above). **Not in the fight:** rewards, loot drops and the kill ledger
    (the "Loot" row reads 0), the panels (the HUD on the core is up and its share is measured), the graphics presets and the resolution governor (the report's preset is the settings file's and is not applied), so the fight is cheaper than today's by what those cost.
    The render breakdown's parts are Shadows, Creatures (the crowd and the boss, one MultiMesh per model not per kind), World, Effects and HUD.
  - **The warm-up is rehearsal rows,** not bodies: every crowd model at three levels of detail from rows fed to `DmCrowd.sync_rows` with the core's tick held (its sync would forget them), then cleared. It runs on request (`opts.warmup`, `--warmup`, the benchmark), not in play.

## Files

- `native/src/`: `dm_core.cpp` is the Godot-facing API (`DmCore`); `dm_crowd.cpp` the crowd's (`DmCrowd`: looks, the core's tables into rows, the RenderingServer);
  `register_types.cpp` registers them, entry symbol `dmcore_library_init` (`client/bin/dmcore.gdextension`).
- `native/src/core/`: the simulation, free of Godot types: `world` (tables, the enemy brain, damage and kills, queries, statuses on bodies),
  `thralls` (the thrall brain and the legion: raise, make_room, formation, separation, rally, deaths), `corpses` (the corpse field),
  `affixes` (the elite affixes), `body` (what a status set needs from its owner, shared by enemies and thralls), `thrall` and `corpse` (their records and enums), `status` (the status
  set, a port of DmStatusSet; its rule table comes from `client/core/dm_status_rules.gd`), `grid` (dense XZ grid rebuilt per tick by counting
  sort), `events` (the per-tick event buffer and its type numbers), `rng` (PCG32 per entity), `crowd_view` (the presentation of the crowd: one view per creature, fed plain rows,
  writing the MultiMesh buffers; a port of the view layer of `godot/game`, which does not touch the simulation), and the co-op pieces: `wire` (byte writer and bounds-checked reader), `replica`
  (the format's constants and a core's co-op counters), `snapshot` (the 20 Hz message, both ways), `reliable` (event batches and the baseline, both ways) and `puppet` (a guest's step, snapshot
  records and reliable records).
- Tests: `client/tests/core_smoke.gd` (loads, answers), `client/tests/core_api.gd` (queries in spawn order, synchronous kills,
  events, seeded stats, the rise and the 4 s body linger) and `client/tests/core_enemies.gd` (the Graves roster against today's
  rules: bite timing, cone, dust cloud, slam, hit-and-run, tunnel and eruption, leash, stagger, stun, crowd spacing), `client/tests/core_status.gd`
  (the 0.1 s step, DoT lumps, stacking and ownership, multipliers, stun, dig-in clear, Withered on death, wire bytes),
  `client/tests/core_corpses.gd` (kinds, the order in a death, extra corpses, the cap, lifetime, toxic rupture and its pool, the pick and consume
  rules) and `client/tests/core_thralls.gd` (the rise, caps and make_room, formation and leash, the scan and the boss edge rule, the swing and its
  multipliers, kinds, enemies choosing and hurting thralls, deaths and bursts, statuses on thralls, rally, separation, tick order),
  `client/tests/core_affixes.gd` (each affix against mirrors of today's timer arithmetic, the pause while staggered, Vengeful inside a call and inside a
  DoT tick), `client/tests/core_coop.gd` (two cores: a real fight, 20 Hz snapshots and batches into puppets, loss and reordering, a late guest and a lost batch,
  refusals, damaged messages, the commands and queries on a puppet, `DmCrowd` on one, the Full Party's size and cost, and `snapshot_parts`; `-- --verbose` lists every check) and
  `client/tests/coop.gd` (the game's half: a host and a guest game over a real local lobby and relay, client/README.md "Co-op on the core"),
  `client/tests/rites.gd` (the Gravecaller's rites on the core: every necromancer rite against today's formulas, the synchronous kills, the input, a full fight),
  `client/tests/boss.gd` (the Gravedigger King: his brain against today's scenarios, his fight by hand and on the real clock, the thralls, the rites, the defeat),
  `client/tests/benchmark.gd` (the benchmark: the Full Party fight held as its setup says, Easy auto combat on the core's arrays, the report and its budget section, real `--benchmark` launches, nothing sent but to the test API),
  `client/tests/crowd_view.gd` (the crowd's views against today's view code, and a Full Party driven by a real core) and `client/tests/game_scene.gd` (the game scene on
  the core: an offline run in the Graves, the director, the event signals, no node per creature, timings). Run
  `bash client/setup.sh` first in a fresh checkout: a script run in a
  project that was never imported hangs.
- `SConstruct`: builds into `client/bin/libdmcore.<platform>.<target>.<arch>.<ext>`.
- `build.sh`: links godot-cpp into `native/thirdparty/` (not committed) from one shared cache per commit
  (`~/death-muffin/native-cache/godot-cpp-<commit>`, cloned and compiled once) at the pinned commit (1e79263, built for `api_version=4.7`) and builds
  Linux `template_debug` (what the headless tests load) and Windows `template_release` (the test build; mingw-w64, C++ runtime linked
  statically so players need no extra files). Runs at `nice -n 10` with 4 jobs; the first build of godot-cpp takes about 6 minutes, later
  builds only recompile what changed, in any checkout or worktree (`SConstruct` keeps each directory's build records next to its files: godot-cpp's in the cache, a checkout's own in the checkout). Builds take turns on a lock next to the cache (`<cache>.lock`): two scons runs against the
  same godot-cpp break each other.

## Build machine (the VPS)

`g++` (system), SCons 4.11 (`python3 -m pip install --user scons`, `~/.local/bin/scons`) and `mingw-w64` (apt) switched to the posix
thread model (`update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix`, same for `gcc`), which the C++
standard thread types need.
