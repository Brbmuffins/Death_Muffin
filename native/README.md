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
  corpses, then every thrall in raise order (combat map section 1). Ties break the same way (strict `<`, then that order).
- **Commands from casts and bosses are synchronous:** rites stay GDScript and call `damage(id, amount, source) -> {dealt, killed}`,
  `in_radius / lane / cone`, `apply_status`, `corpse_pick / corpse_consume`, `raise_thrall` directly, and read the result at once,
  because today a kill resolves inside the caller (Wailing Skull's extra hop, Bone Prison skipping the dead). A kill inside such a
  call runs the core's own death work at once (director count, Vengeful, statuses cleared, corpse laid) and is handed to GDScript
  (rewards) before the call returns. Kills inside `step()` (thrall swings, DoT, hazards) come out in the event buffer, in order.
- **No per-creature calls per tick:** per-creature work never crosses into GDScript during a tick. GDScript reads one ordered event
  buffer per tick (spawned, state edges, telegraphs, cues, damaged, died, thrall raised/died, corpse added/gone, status changes,
  zones) and bulk arrays for the HUD, minimap and auto combat. Cast-driven calls are bounded by casts, not by creature count.
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

## Files

- `native/src/`: the core. `register_types.cpp` registers the classes; entry symbol `dmcore_library_init` (`client/bin/dmcore.gdextension`).
- `SConstruct`: builds into `client/bin/libdmcore.<platform>.<target>.<arch>.<ext>`.
- `build.sh`: links godot-cpp into `native/thirdparty/` (not committed) from one shared cache per commit
  (`~/death-muffin/native-cache/godot-cpp-<commit>`, cloned and compiled once) at the pinned commit (1e79263, built for `api_version=4.7`) and builds
  Linux `template_debug` (what the headless tests load) and Windows `template_release` (the test build; mingw-w64, C++ runtime linked
  statically so players need no extra files). Runs at `nice -n 10` with 4 jobs; the first build of godot-cpp takes about 6 minutes, later
  builds only recompile what changed.

## Build machine (the VPS)

`g++` (system), SCons 4.11 (`python3 -m pip install --user scons`, `~/.local/bin/scons`) and `mingw-w64` (apt) switched to the posix
thread model (`update-alternatives --set x86_64-w64-mingw32-g++ /usr/bin/x86_64-w64-mingw32-g++-posix`, same for `gcc`), which the C++
standard thread types need.
