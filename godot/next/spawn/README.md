# godot/next/spawn: DmWaveDirector

`DmWaveDirector` (`dm_wave_director.gd`, child `Waves` of `DmNextGame`) is the host-side enemy spawner for the hunting grounds and the
replication of the enemies themselves. Every enemy is a `DmEnemy` scene (`res://enemies/<id>.tscn`) created by a `MultiplayerSpawner`, so peers
and late joiners get the same bodies, solo included. Per-tick enemy state travels in `DmNextNet`.

- Pacing: a wave of `wave_size` every `wave_interval` s while a hero is in the area, up to `cap` alive; the first wave of a visit is 1.3x.
  `configure_area(id)` loads the area's roster / cap / size / interval; with `follow_areas` the director moves to the combat area a hero is in
  and clears the old area (`clear_area`). Global cap 72. Processions (`WAVE_THEMES`) and wave milestones (`milestone(id)`) change the picks.
- Spawn position: outside aggro range (`SPAWN_MIN` = aggro + 3 m, up to 30 m), snapped to the navmesh.
- Scaling: `DmEnemyStats` (area level, hp / damage per level, party hp) into `hp_mult` / `damage_mult`; `spawn(def, pos, heroes, elite, mult, over)`
  takes overrides (the Depths pass `area`, `depth`, `aggro`, `leash`, `affixes`).
- Seams: `enemies_in_radius`, `enemy_by_id`, `enemy_id`, `alive_count`; signals `enemy_spawned` (every peer), `enemy_died`, `wave_spawned`,
  `procession`, `area_followed`, `surge_event` (Grave Surges, see `areas/README.md`). Answers the acolyte's `unbind_rise` and the deacon's `raised` with a `risen`.
- Only kinds that have a scene in `res://enemies/` are used.

## Tests
`tests/next_spawn_aggro/run.gd` (every fresh wave stands beyond aggro range, 9 areas x 12 waves), `tests/next_areas/run.gd` (rosters, caps, following,
processions, surges), `tests/next/run.gd`.

## Known gaps
- One director simulates one area (see `areas/README.md`). Waves spawn in a ring around the hero, not at breach points.
