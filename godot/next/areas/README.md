# godot/next/areas: every area of the world on the rebuild

All thirteen areas live in `DmNextGame` (the Depths are the depths track's instance: `DmWaveDirector` skips `instance` areas). Nothing here re-implements a rule; it
wires the current game's content (`areas.json`, `enemies.json`, `DmSimData`) onto the slice's systems.

| Piece | Where | Notes |
|---|---|---|
| World, lighting, fog, streaming, navmesh per area + per door | `DmWorldBuilder` via `next_world.gd` (unchanged) | all areas are built at load (one bake of every area + door region ~120-135 ms, so no cache); `update_streaming` draws only areas within 95 m of the camera; sealed areas' navmesh regions are disabled until the seal breaks (`DmChapterhouse.apply_seals`) |
| Music + ambience bed + footsteps | `AudioDirector` / `DmAudioHooks` (unchanged) | follow `DmNextGame.area_id`; every area has a music cue and a `ZONE_BEDS` entry (tested) |
| Entry banner, Codex discovery, first-entry counsel | `dm_area_flow.gd` (`Areas`) | the current game's `_enter_area` (banner once per area per session, none for the Depths) |
| Rosters, caps, pacing, level scaling | `spawn/dm_wave_director.gd` | one director follows the hero: when nobody is in `area_id` it moves to the combat area a hero is in (`area_followed`), clearing the old area's enemies, `configure_area(id)` = the area's roster / cap / wave size / interval; level via `DmEnemyStats.area_level` (Cloister 20, Pyre 30, Fen 45 floors, hero-level scaled) |
| First wave 1.3 x, GLOBAL_ENEMY_CAP, eliteBonus | director | sim `spawn_wave(first)` / `GLOBAL_ENEMY_CAP` 72 / wave-tier elite bonus |
| Processions (`WAVE_THEMES`, from wave 2, 30 %) | director `_roll_theme`, signal `procession`; banner once per area in `DmAreaFlow` | themed roster, lead kind, size |
| Grave Surges | `dm_grave_surge.gd` (`director.surge`), presentation + reward in `DmAreaFlow` / `DmSessionRewards.on_surge_cleared` | first after 100 s of hero time in a combat area, then 90-150 s; crypt 9-30 m from the hero; 3 waves (1.5 / 7.5 / 13.5 s) of 1.2 x wave size; 80 % in 20 s = "Surge Quelled" + an item and gold; fails when time runs out or the area empties |
| Seals, doors, waystones, recall | `chapterhouse/dm_chapterhouse.gd` | the hub owns seals; `travel(area)` now serves every waystone whose seal is broken (`"<Area> is still sealed."` otherwise) |

## Not done / limits
- Gathering (Acre nodes, professions, laborers) is not wired: `DmGameGather` / `DmGatherLoop` are bound to the old `DmGame` + sim nodes; porting them is its own track.
- One director = one simulated area: a second player standing in a different combat area gets no waves until the host's area empties. (Party of 4 solo-first, D5.)
- Sim waves climb out of area `breaches`; the slice keeps its ring 9-14 m around the hero (snapped to the navmesh). Nightfall shroud / vanguard milestone variants are not ported.
- Bosses of the other areas are the bosses tracks'.

## Tests / perf
`godot --headless --path godot --script res://tests/next_areas/run.gd` (offline backend; ~1 minute). Rendered walk: `tests/next_areas/walk_probe.gd` (header has the lock command).
Headless walk through 12 areas twice with waves on: frame median ~7.4 ms (p95 ~8.3), worst ~35 ms, slowest frame after an entry ~20-35 ms, static memory +2 MB and node count flat over 24 entries.
