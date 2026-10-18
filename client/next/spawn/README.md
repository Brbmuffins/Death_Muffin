# client/next/spawn: DmWaveDirector

`DmWaveDirector` (`dm_wave_director.gd`, child `Waves` of `DmNextGame`) is the host-side enemy spawner for the hunting grounds. Every enemy is a body of the combat core, made through `DmCoreHost.spawn_enemy` and drawn by the crowd: there is no scene,
node or `MultiplayerSpawner` per enemy, and a guest's bodies come from the wire (the director is off there; client/README.md "Co-op on the core"). The kinds it makes are the ones the core runs (`CORE_KINDS`); a roster entry outside that list is skipped.
Where it sits in the tick: client/README.md "The game scene and the dev entry".

- Pacing: a wave of `wave_size` every `wave_interval` s while a hero is in the area, up to `cap` alive; the first wave of a visit is 1.3x.
  `configure_area(id)` loads the area's roster / cap / size / interval; with `follow_areas` the director moves to the combat area a hero is in
  and clears the old area (`clear_area`: its living bodies are sent away through the core, no death, corpse or credit; also after 15 s with nobody in it). Global cap 72, counted from the core (the dead count for 4 s). Processions (`WAVE_THEMES`) and wave milestones (`milestone(id)`) change the picks.
- Wave bodies are queued by `spawn_wave` and made `SPAWNS_PER_TICK` (3) per physics tick, so a wave never costs one hitch frame; their scaling is fixed when the wave is decided, `spawn` called outside a wave builds at once and returns the core id; `flush_spawns()` builds the queue now (tests).
- Spawn position: outside aggro range (`SPAWN_MIN` = aggro + 3 m, up to `SPAWN_MAX` 30 m), snapped to the navmesh.
- Scaling: in a party the level comes from the host's hero only (`scaling_levels`); `DmEnemyStats` (area level, hp / damage per level, party hp) into the body's level, health and damage; `spawn(def, pos, heroes, elite, mult, over)` takes overrides
  (`over`: `area`, `depth`, `aggro`, `leash`, `affix_list`: the Depths' and a boss's adds). An elite rolls its affixes with `DmAffixRoll.roll` (`client/core/dm_affix_roll.gd`, from the director's random stream); the rules the affixes run by are the core's (native/README.md "Affixes").
  A Risen a deacon raises or an acolyte unbinds is made by the core itself, with its raiser's level and multipliers.
- Grave Surges: `director.surge` (`DmGraveSurge`, `client/next/areas/dm_grave_surge.gd`) is the director's own: it calls `surge.update(dt, heroes)` at the end of every physics tick and `surge.reset()` when no hero is in the area or when it follows the heroes. A surge's wave goes through
  the same queue (`begin_surge_wave`; each queued body carries the surge's serial and `_make_next` hands the surge its core id) and the director passes on every death of the core (`_on_enemy_died`). The rules and the numbers: client/README.md "Grave Surges".
- Seams: `alive_count`, `enemy_total`, `pending_count`; signals `wave_spawned`, `procession`, `area_followed` and `surge_event` (host: `surge`, `surgeCleared`, `surgeFailed`; `DmAreaFlow` draws them). `enemy_spawned` is the game scene's signal, from the core host (an id, not a node).
- There is no animation level of detail or lower rate for idle bodies: the core runs every body at 60 Hz (native/README.md "Design"), and the crowd's animation bands count from the camera (client/crowd/README.md "Crowd cost").

## Tests
`client/tests/game_scene.gd` (the director on the core: waves, the cap, the event signals), `client/tests/world.gd` (the waves following the hero from area to area, the later areas' rosters), `client/tests/depths.gd` (the Depths' spawns with their own aggro, leash and affixes), `client/tests/surge.gd` (a surge's waves through the director's own ticks) and `client/tests/core_kinds.gd`.

## Known gaps
- One director simulates one area (client/next/areas/README.md). Waves spawn in a ring around the hero, not at breach points (the Depths' floors do spawn at breaches).
