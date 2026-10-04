# godot/audio: the audio engine (port of src/audio/)

## Install (integrator)
Add one autoload line to `godot/project.godot` under `[autoload]`:

```
AudioDirector="*res://audio/audio_director.gd"
```

The autoload builds its own buses at runtime (Master <- Combat, Enemies, Thralls, Ui, Ambience, Music; plus pooled `DmPan*` voice
buses and `DmBedLP*` low-pass buses), so no `default_bus_layout.tres` is needed. Nothing else must be registered.

## Settings
Call `AudioDirector.apply_settings(dict)` at startup and whenever a slider changes. Accepts the web Settings keys
(`volume`, `combatVolume`, `ambienceVolume`, `musicVolume`, `interfaceVolume`, 0..1) or the Godot settings panel's keys
(`vol_master`, `vol_combat`, `vol_amb`, `vol_music`, `vol_ui`); e.g. `AudioDirector.apply_settings(settings_panel.values)`.
Slider -> gain is the web's `pow(v, 1.5)`; per-bus trims (enemies 0.8, thralls 0.5, ui 0.9), master x0.9, music x0.72 are kept.
Combat slider also drives Enemies and Thralls (as the web does).

## API (all on the autoload)
| Call | Meaning |
| --- | --- |
| `play_sfx(id, pos = null, intensity = 1.0) -> bool` | Play a sound by Sfx id (`needleCast`, `hurt`, `coin`, `bossAwaken`, ...). `pos` is a `Vector3` (x,z used), a `Vector2` (x,z) or `null` for head-relative. True when a clip started. All web gating applies: map cooldown, culling by distance, partner rules, repeat attenuation, thinning, per-id and per-bus voice caps, priority. |
| `set_listener(x, z)` / `set_listener_pos(v3)` | Hero ground position (call each frame). Distance falloff and pan are relative to it. |
| `set_area(area_id)` / `stop_area()` | Enter an area (zone bed crossfade, area music, accents, area sample packs) / leave the world. |
| `set_boss_music(bool)` | Boss score on/off (web: `p.alive and boss.active and boss area == current area`). |
| `set_combat(bool)` | Optional override: pretend a heavy fight is on (ducks bed + music). Off by default; the web derives combat level from the sounds played and so does this. |
| `loop_sfx(id, ms, pos = null, follow = Callable()) -> int` / `stop_loop(handle)` | Rite beds (`miasmaLoop`, `siphonLoop`, ...): retrigger every map `loopMs` for `ms`. `follow` returns a Vector3/Vector2 or null (stops). |
| `hero_footfall(phase, x, z, area_id, wet = false, running = false)` / `hero_stopped()` | Per-frame footsteps from the walk loop phase (0..1, -1 if none); picks the area/wading surface and gain like WorldScene. |
| `footstep(step_id, pos, gain)` | One surface step (`stepStone` / `stepDirt` / `stepGrass` / `stepWater`). |
| `gather(skill, kind = "", pos = null)` | The work-cycle sound (`DmGatherSfx`). |
| `play_loot(rarities: Array)` | Highest rarity picks the loot sound. |
| `partner: bool` | Set true while handling a remote co-op player's events. |
| `apply_settings(dict)`, `seed_rng(int)`, `stats()`, `reset_stats()`, `music_cue()`, `current_area()`, `boss_bed_active()` | Settings, determinism for tests, QA snapshot. |
| signal `sfx_played(sfx_name)` | Emitted when a clip started. |

Event mapping from the web: `audio.play(name, x, z, intensity)` -> `play_sfx(name, Vector2(x, z), intensity)`;
`audio.setArea/stopArea/setBossMusic/setListener/loop/footstep` map 1:1 (see table). `bossAwaken` starts the boss war-drum
pulse and `bossDefeat` / `stop_area()` end it, as in the web.

## Files
- `audio_mixer.gd` `DmAudioMixer`: mixer.ts (buses, trims, PROFILES, slider/distance/pan/repeat maths, voice + id limiters, window counter, combat activity, duck curve).
- `audio_packs.gd` `DmAudioPacks`: packs.ts (pack groups, per-id bus, clip length caps, area packs).
- `audio_samples.gd` `DmSampleBank`: samples.ts (clip paths, LEGACY clips, pack load/release, seeded variant pick).
- `audio_ambience.gd` `DmAudioAmbience`: ambience.ts (zone beds, accents).
- `audio_music_state.gd` `DmMusicState`: the MusicDirector decisions as a pure state machine (cue per area/boss/volume, crossfade, loop self-handover).
- `audio_music.gd` `DmMusicDirector`: runs the state machine with players on the `Music` bus (crossfade tau FADE/3, combat duck, cue duck).
- `audio_footsteps.gd` `DmFootstepTracker`, `audio_gather_sfx.gd` `DmGatherSfx`: footsteps.ts, gatherSfx.ts.
- `audio_map.gd` `DmAudioMap`: typed access to `godot/data/content/audioMap.json` (the recorded-sound map).
- `audio_synth.gd` `DmAudioSynth`: procedural loops (zone drones, boss drum) generated at runtime.
- `audio_director.gd`: the autoload (Audio.ts AudioEngine).

## Assets (`godot/assets/audio/`, synced by `tools/godot/sync-audio-assets.sh`, `.import` files committed)
| Folder | Files | Size | Notes |
| --- | --- | --- | --- |
| `esm/` | 318 | 4.8 MB | one-shots; web ships Opus (3.1 MB), Godot cannot import Opus so they are re-encoded to Ogg Vorbis (mono, q3) |
| `music/` | 5 | 7.9 MB | the web's MP3s unchanged (Godot imports MP3; no generation loss) |
| `ambience/` | 7 | 0.5 MB | bed loops, Ogg as in the web; `.import` has `loop=true` |
| `world/`, `combat/` | 12 + 2 | 0.25 MB | legacy bells, gusts, crows, moans, embers, boss toll |

No generation, no API: only files already in `public/audio`.

## Differences from the web engine (placeholders)
- **No synthesised fallback voices.** The web layers hand-built oscillator/noise sounds under `partial` clips and plays them alone
  when a clip fails to load. Only the recorded layer is ported; `lowHealth` (a `keep` id with no clip and no legacy file) is
  therefore silent, and `partial` clips play alone instead of over a synth bed. The synthesised wind bed (loop-load fallback) is skipped too.
- Zone drones (two detuned saws) and the boss drum are regenerated procedurally (`DmAudioSynth`); the drone detune is snapped to a 0.1 Hz grid so the loop is seamless.
- Reverb: one `AudioEffectReverb` (wet 0.1) per category bus replaces the web's per-voice convolver send. Master has the same compressor (-18 dB, 3:1) then limiter (-3 dB).
- Pan: per-voice pan buses with `AudioEffectPanner` (world-x based, as the web), not 3D audio.
- MP3 music is not looped by the engine; `DmMusicState` hands over to a fresh copy `FADE + 0.25 = 3.25 s` before the end, like the web.
- Voice pool is 48 players (the web caps at 110 raw nodes); a clip never plays past its id's cap (tail fade).

## Tests
`godot --headless --path godot --script res://tests/audio/run.gd` (golden fixtures from the TS in `tests/audio/fixtures/`, regenerate with
`npx vite-node tools/godot/fixtures-audio.ts`). Covers mixer maths, profiles of every id, limiters, packs, ambience tables, footsteps,
music state machine + hand-over timing (also with real players via `seek`), seeded sample selection, asset resolution (every clip id in the map has
an imported file), and an `AudioDirector` integration run on the dummy driver.
