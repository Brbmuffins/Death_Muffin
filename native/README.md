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
  `in_radius / lane / cone`, `apply_status`, `corpse_pick / corpse_consume`, `raise_thrall` directly, and read the result at once,
  because today a kill resolves inside the caller (Wailing Skull's extra hop, Bone Prison skipping the dead). A kill inside such a
  call runs the core's own death work at once (director count, Vengeful, statuses cleared, corpse laid) and is handed to GDScript
  (rewards) before the call returns. Kills inside `step()` (thrall swings, DoT, hazards) come out in the event buffer, in order.
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
- **Drawing:** one MultiMesh per creature model, transforms and animation data written in one buffer update per rendered frame,
  interpolated between ticks; animations play from baked vertex-animation textures.
- **Co-op:** the host core packs one snapshot (position, yaw, state, hp, aim, time in state, kind extras) at 20 Hz; a guest core runs
  in puppet mode, eases toward snapshots and derives telegraph, attack and death events from state edges, as today's puppets do.
- **Proof of "same game":** pure rules replay today's parity and golden fixtures; behaviour is compared with seeded scenarios
  (kills, damage, time to kill, thrall uptime) between today's game and the core within stated tolerances.

## Differences from today's game

Every place the core does not do exactly what today's GDScript does, so Helix can judge them in the test build (B42):
- **Crowd spacing:** Godot's RVO avoidance (applied a tick late) is replaced by a push-apart between overlapping bodies. The one
  planned difference in feel.
- **Walls and the hero:** today `move_and_slide` slides a body along walls and the hero's capsule; the core moves it, pushes it out
  of the hero's circle and snaps it back onto the navmesh. Close to today on open ground, may differ in corners.
- **No idle LOD:** today a far idle body thinks at 10 Hz; the core runs every body at 60 Hz (cheap enough in C++). Idle wander
  changes a little; nothing a player sees.
- **Brains first, then movement:** today each body thinks and moves before the next one thinks; the core runs every brain, then
  every move. Bodies never read each other's positions in the same tick except for crowd spacing, which was a tick late anyway.
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
- **Paths:** the core follows `NavigationServer3D` paths itself (24 points, advancing at 0.5 m like the agent's
  `path_desired_distance`) instead of a `NavigationAgent3D`.

## Files

- `native/src/`: `dm_core.cpp` is the Godot-facing API (`DmCore`); `register_types.cpp` registers it, entry symbol `dmcore_library_init`
  (`client/bin/dmcore.gdextension`).
- `native/src/core/`: the simulation, free of Godot types: `world` (tables, the enemy brain, damage and kills, queries, statuses on bodies),
  `thralls` (the thrall brain and the legion: raise, make_room, formation, separation, rally, deaths), `corpses` (the corpse field),
  `body` (what a status set needs from its owner, shared by enemies and thralls), `thrall` and `corpse` (their records and enums), `status` (the status
  set, a port of DmStatusSet; its rule table comes from `client/core/dm_status_rules.gd`), `grid` (dense XZ grid rebuilt per tick by counting
  sort), `events` (the per-tick event buffer and its type numbers), `rng` (PCG32 per entity).
- Tests: `client/tests/core_smoke.gd` (loads, answers), `client/tests/core_api.gd` (queries in spawn order, synchronous kills,
  events, seeded stats, the rise and the 4 s body linger) and `client/tests/core_enemies.gd` (the Graves roster against today's
  rules: bite timing, cone, dust cloud, slam, hit-and-run, tunnel and eruption, leash, stagger, stun), `client/tests/core_status.gd`
  (the 0.1 s step, DoT lumps, stacking and ownership, multipliers, stun, dig-in clear, Withered on death, wire bytes),
  `client/tests/core_corpses.gd` (kinds, the order in a death, extra corpses, the cap, lifetime, toxic rupture and its pool, the pick and consume
  rules) and `client/tests/core_thralls.gd` (the rise, caps and make_room, formation and leash, the scan and the boss edge rule, the swing and its
  multipliers, kinds, enemies choosing and hurting thralls, deaths and bursts, statuses on thralls, rally, separation, tick order). Run `bash client/setup.sh` first in a fresh checkout: a script run in a
  project that was never imported hangs.
- `SConstruct`: builds into `client/bin/libdmcore.<platform>.<target>.<arch>.<ext>`.
- `build.sh`: links godot-cpp into `native/thirdparty/` (not committed) from one shared cache per commit
  (`~/death-muffin/native-cache/godot-cpp-<commit>`, cloned and compiled once) at the pinned commit (1e79263, built for `api_version=4.7`) and builds
  Linux `template_debug` (what the headless tests load) and Windows `template_release` (the test build; mingw-w64, C++ runtime linked
  statically so players need no extra files). Runs at `nice -n 10` with 4 jobs; the first build of godot-cpp takes about 6 minutes, later
  builds only recompile what changed. Builds take turns on a lock next to the cache (`<cache>.lock`): two scons runs against the
  same godot-cpp break each other.

## Build machine (the VPS)

`g++` (system), SCons 4.11 (`python3 -m pip install --user scons`, `~/.local/bin/scons`) and `mingw-w64` (apt) switched to the posix
thread model (`update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix`, same for `gcc`), which the C++
standard thread types need.
