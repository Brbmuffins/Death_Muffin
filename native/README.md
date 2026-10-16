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
  presentation field lives in a world, enemy or thrall struct. Its input is a plain row per creature, hit and corpse, which a co-op guest can fill from snapshots instead
  (client/crowd/README.md "Driving the crowd").
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
- **Crowd drawing (`DmCrowd`):** the creatures are MultiMesh instances playing baked clips, so what lived on each creature's node today is not in this pass:
  the base emissive glow (an elite's purple, the risen's green, a thrall's legion and champion glow, the Fen wisp's), the spectral wraith (translucent, pale-blue glow), the thralls'
  spirit rims, gear tint of kit armour and the hand props (swords, shields, bows, staffs), the moth's, bat's and seraph's wings, the burrowed ghoul's mound, the Mire Leech's wobble,
  the Gargoyle's dive (not in the core yet), the fade-out of a sinking body (it sinks the same 0.9 s but is not faded to transparent), the drawn-body crowd separation
  (`_separate_crowd`; the core separates bodies), the elite and affix rings, particles and status, fire and fen death effects, the landing dust, the corpse rings and the toxic decal, a shattered corpse (Corpse Explosion), and the animation LOD (a far body
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

## Files

- `native/src/`: `dm_core.cpp` is the Godot-facing API (`DmCore`); `dm_crowd.cpp` the crowd's (`DmCrowd`: looks, the core's tables into rows, the RenderingServer);
  `register_types.cpp` registers them, entry symbol `dmcore_library_init` (`client/bin/dmcore.gdextension`).
- `native/src/core/`: the simulation, free of Godot types: `world` (tables, the enemy brain, damage and kills, queries, statuses on bodies),
  `thralls` (the thrall brain and the legion: raise, make_room, formation, separation, rally, deaths), `corpses` (the corpse field),
  `affixes` (the elite affixes), `body` (what a status set needs from its owner, shared by enemies and thralls), `thrall` and `corpse` (their records and enums), `status` (the status
  set, a port of DmStatusSet; its rule table comes from `client/core/dm_status_rules.gd`), `grid` (dense XZ grid rebuilt per tick by counting
  sort), `events` (the per-tick event buffer and its type numbers), `rng` (PCG32 per entity), `crowd_view` (the presentation of the crowd: one view per creature, fed plain rows,
  writing the MultiMesh buffers; a port of the view layer of `godot/game`, which does not touch the simulation).
- Tests: `client/tests/core_smoke.gd` (loads, answers), `client/tests/core_api.gd` (queries in spawn order, synchronous kills,
  events, seeded stats, the rise and the 4 s body linger) and `client/tests/core_enemies.gd` (the Graves roster against today's
  rules: bite timing, cone, dust cloud, slam, hit-and-run, tunnel and eruption, leash, stagger, stun), `client/tests/core_status.gd`
  (the 0.1 s step, DoT lumps, stacking and ownership, multipliers, stun, dig-in clear, Withered on death, wire bytes),
  `client/tests/core_corpses.gd` (kinds, the order in a death, extra corpses, the cap, lifetime, toxic rupture and its pool, the pick and consume
  rules) and `client/tests/core_thralls.gd` (the rise, caps and make_room, formation and leash, the scan and the boss edge rule, the swing and its
  multipliers, kinds, enemies choosing and hurting thralls, deaths and bursts, statuses on thralls, rally, separation, tick order),
  `client/tests/core_affixes.gd` (each affix against mirrors of today's timer arithmetic, the pause while staggered, Vengeful inside a call and inside a
  DoT tick) and `client/tests/crowd_view.gd` (the crowd's views against today's view code, and a Full Party driven by a real core). Run
  `bash client/setup.sh` first in a fresh checkout: a script run in a
  project that was never imported hangs.
- `SConstruct`: builds into `client/bin/libdmcore.<platform>.<target>.<arch>.<ext>`.
- `build.sh`: links godot-cpp into `native/thirdparty/` (not committed) from one shared cache per commit
  (`~/death-muffin/native-cache/godot-cpp-<commit>`, cloned and compiled once) at the pinned commit (1e79263, built for `api_version=4.7`) and builds
  Linux `template_debug` (what the headless tests load) and Windows `template_release` (the test build; mingw-w64, C++ runtime linked
  statically so players need no extra files). Runs at `nice -n 10` with 4 jobs; the first build of godot-cpp takes about 6 minutes, later
  builds only recompile what changed, in any checkout or worktree (`SConstruct` keeps the build records next to the cache). Builds take turns on a lock next to the cache (`<cache>.lock`): two scons runs against the
  same godot-cpp break each other.

## Build machine (the VPS)

`g++` (system), SCons 4.11 (`python3 -m pip install --user scons`, `~/.local/bin/scons`) and `mingw-w64` (apt) switched to the posix
thread model (`update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix`, same for `gcc`), which the C++
standard thread types need.
