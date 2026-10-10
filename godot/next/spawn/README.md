# godot/next/spawn: DmWaveDirector

`DmWaveDirector` (`dm_wave_director.gd`, child `Waves` of `DmNextGame`) is the host-side enemy spawner for the hunting grounds and the
replication of the enemies themselves. Every enemy is a `DmEnemy` scene (`res://enemies/<id>.tscn`) created by a `MultiplayerSpawner`, so peers
and late joiners get the same bodies, solo included. Per-tick enemy state travels in `DmNextNet`.

- Pacing: a wave of `wave_size` every `wave_interval` s while a hero is in the area, up to `cap` alive; the first wave of a visit is 1.3x.
  `configure_area(id)` loads the area's roster / cap / size / interval; with `follow_areas` the director moves to the combat area a hero is in
  and clears the old area (`clear_area`). Global cap 72. Processions (`WAVE_THEMES`) and wave milestones (`milestone(id)`) change the picks.
- Wave bodies are queued by `spawn_wave` and instantiated `SPAWNS_PER_TICK` (3) per physics tick, so a wave never costs one hitch frame; ids, positions and scaling are fixed when the wave is decided, `spawn` called outside a wave builds at once and returns the body; `flush_spawns()` builds the queue now (tests).
- Spawn position: outside aggro range (`SPAWN_MIN` = aggro + 3 m, up to 30 m), snapped to the navmesh.
- Scaling: `DmEnemyStats` (area level, hp / damage per level, party hp) into `hp_mult` / `damage_mult`; `spawn(def, pos, heroes, elite, mult, over)`
  takes overrides (the Depths pass `area`, `depth`, `aggro`, `leash`, `affixes`).
- Seams: `enemies_in_radius`, `enemy_by_id`, `enemy_id`, `alive_count`; signals `enemy_spawned` (every peer), `enemy_died`, `wave_spawned`,
  `procession`, `area_followed`, `surge_event` (Grave Surges, see `areas/README.md`). Answers the acolyte's `unbind_rise` and the deacon's `raised` with a `risen`.
- Enemy simulation LOD (`DmEnemy._physics_process`, host side): an idle body (no target) farther than `IDLE_LOD_FAR` (24 m, or aggro + 9 m) from every `dm_target` runs its brain every 6th physics tick (10 Hz, staggered by instance id) with the accumulated time, moves by the skipped distance in one `move_and_slide`, and has crowd avoidance off. Chase, attack, hurt, return, flee and anything near a hero or thrall run at 60 Hz as before; the nearest-target distance comes free from the 4 Hz scan. Animation LOD (`DmCreature.lod_interval`, used by enemies and thralls) measures from the point the camera looks at: everything on screen animates every frame, the band outside ~30 Hz, the rest ~10 Hz.
- Only kinds that have a scene in `res://enemies/` are used.

## Tests
`tests/next_spawn_aggro/run.gd` (every fresh wave stands beyond aggro range, 9 areas x 12 waves), `tests/next_areas/run.gd` (rosters, caps, following,
processions, surges), `tests/next/run.gd`.

## Known gaps
- One director simulates one area (see `areas/README.md`). Waves spawn in a ring around the hero, not at breach points.
