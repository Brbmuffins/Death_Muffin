# client/next/areas: every area of the world on the rebuild

All thirteen areas live in `DmNextGame`: twelve area scenes (`client/areas/<id>.tscn`, client/README.md "Areas") and the Depths, the one area with no scene (`client/next/depths/`; `DmWaveDirector` skips `instance` areas).
Nothing here re-implements a rule; it wires the shared content (`areas.json`, `enemies.json`, `DmSimData`) onto DmNextGame's systems.

| Piece | Where | Notes |
|---|---|---|
| World, lighting, fog, navmesh per area + per door | `DmNextWorld` (`client/next/next_world.gd`) loads the area scenes | every area loads at start (`opts.areas` takes a shorter list); each area and each door has a baked navmesh region; a sealed door's gate is closed and its region off until the seal breaks (`DmChapterhouse`); the core keeps its own copy of the navmesh. No streaming and no see-through cutout yet |
| Music + ambience bed + footsteps | `AudioDirector` / `DmAudioHooks` | follow `DmNextGame.area_id`; every area has a music cue and a `ZONE_BEDS` entry |
| Entry banner, Codex discovery, first-entry counsel | `dm_area_flow.gd` (`Areas`) | banner once per area per session, none for the Depths |
| Rosters, caps, pacing, level scaling | `client/next/spawn/dm_wave_director.gd` | one director follows the hero: when nobody is in `area_id` it moves to the combat area a hero is in (`area_followed`), sending the old area's enemies away through the core (no death, corpse or credit), `configure_area(id)` = the area's roster (only the kinds the core runs) / cap / wave size / interval; level via `DmEnemyStats.area_level` (Cloister 20, Pyre 30, Fen 45 floors, hero-level scaled) |
| First wave 1.3 x, GLOBAL_ENEMY_CAP, eliteBonus | director | the first wave of a visit is 1.3 x the wave size; `GLOBAL_ENEMY_CAP` 72 (the dead count for 4 s); the wave-tier elite bonus |
| Processions (`WAVE_THEMES`, from wave 2, 30 %) | director `_roll_theme`, signal `procession`; banner once per area in `DmAreaFlow` | themed roster, lead kind, size |
| Grave Surges | `dm_grave_surge.gd` (`DmGraveSurge`, `director.surge`); the banner, the cracked crypt and the sounds in `DmAreaFlow`, the offering in `DmSessionRewards.on_surge_cleared` | host only. How one runs (the clock, the crypt, the three waves, quelled or failed, a party) and its numbers: client/README.md "Grave Surges" |
| Seals, doors, waystones, recall | `client/next/chapterhouse/dm_chapterhouse.gd` | the hub owns seals; `travel(area)` serves every waystone whose seal is broken (`"<Area> is still sealed."` otherwise) |

## Known gaps
- One director = one simulated area: a second player standing in a different combat area gets no waves until the host's area empties. (Party of 4 solo-first, D5.)
- Waves spawn in a ring around the hero, outside aggro range (18 to 30 m) and snapped to the navmesh, not at area breaches (the Depths' floors do spawn at breaches).
- Gathering is `client/next/gathering/` (`DmNextGather`, `DmNextAcre`); the bosses of the areas are `client/next/bosses/`.

## Tests
`client/tests/world.gd` plays the whole world: every area, seals and gates, walking from the Chapterhouse into the Warren, waystones, the recall, the later areas' rosters in the game scene, the waves following the hero from area to area
(`--fixed-fps 60`). `client/tests/areas.gd` checks every area scene against what `world.json` says, and `client/tests/surge.gd` plays the Grave Surges. Not covered in the client: every fresh wave standing beyond aggro range over nine areas and twelve waves,
and the wave milestones' banners and Nightfall light (the old game's spawn and milestone suites).

## Wave milestones (`dm_wave_milestones.gd`, child `Milestones`)
Elite Vanguard (tier 3), Restless Crypts (6), Nightfall (8): banner on crossing (`DmNextProgress.apply_progress` -> `on_tier`), a "fades" toast on dropping back, and the Nightfall light (moon x(1 - 0.6 k),
hemisphere x(1 - 0.3 k), eased at 0.8/s, scaled by ratio so other light writers compose; the Acre and the Alchemist's Wing stay lit). The lights are the world's (`DmNextWorld.builder` holds them), the banners go through `game_event`.
`_process` only runs while easing. The variants live in the director (`DmWaveDirector.milestone(id)` at the ramped tier): the Vanguard's first plain pick of every other wave is an elite, Nightfall makes half the common picks `shrouded`;
Restless Crypts shortens the next surge x0.6 (`DmGraveSurge`).
Not done: a joined client does not dim (the tier is host state); Nightfall dims only the real-time ambient, so lightmapped ground, walls and props keep their full ambient (KNOWN-GAPS "Look").
