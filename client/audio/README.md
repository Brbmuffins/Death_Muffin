# client/audio: the audio engine

Autoload `AudioDirector` (`client/project.godot`: `AudioDirector="*res://audio/audio_director.gd"`). It builds its own buses at runtime (Master <- Combat,
Enemies, Thralls, Ui, Ambience, Music; plus pooled `DmPan*` voice buses and `DmBedLP*` low-pass buses), so no bus layout file is needed.
Game code does not call it directly for most cues: `client/main/audio_hooks.gd` (`DmAudioHooks`) holds the static one-liners, follows the hero as
listener, keeps the area bed and music in step, and drives footsteps. The systems under `client/next/` call `AudioDirector.play_sfx` and friends.
Which sound plays for which event of the combat core, and what each cue's code path is: "Sound" below.

## Settings
`AudioDirector.apply_settings(dict)` at startup and on every slider change. Accepts `volume`, `combatVolume`, `ambienceVolume`, `musicVolume`,
`interfaceVolume` (0..1) or the settings panel's keys (`vol_master`, `vol_combat`, `vol_amb`, `vol_music`, `vol_ui`). Slider to gain is `pow(v, 1.5)`;
per-bus trims (enemies 0.8, thralls 0.5, ui 0.9), master x0.9, music x0.72. The Combat slider also drives Enemies and Thralls.

## API (all on the autoload)
| Call | Meaning |
| --- | --- |
| `play_sfx(id, pos = null, intensity = 1.0) -> bool` | Play a sound by Sfx id (`needleCast`, `hurt`, `coin`, `bossAwaken`, ...). `pos` is a `Vector3` (x,z used), a `Vector2` (x,z) or `null` for head-relative. True when a clip started. Gating: map cooldown, culling by distance, partner rules, repeat attenuation, thinning, per-id and per-bus voice caps, priority. |
| `set_listener(x, z)` / `set_listener_pos(v3)` | Hero ground position (call each frame). Distance falloff and pan are relative to it. |
| `set_area(area_id)` / `stop_area()` | Enter an area (zone bed crossfade, area music, accents, area sample packs) / leave the world. |
| `set_boss_music(bool)` | Boss score on/off (on while a boss is awake in the current area). |
| `set_combat(bool)` | Optional override: pretend a heavy fight is on (ducks bed + music). Off by default; combat level is derived from the sounds played. |
| `loop_sfx(id, ms, pos = null, follow = Callable()) -> int` / `stop_loop(handle)` | Rite beds (`miasmaLoop`, `siphonLoop`, ...): retrigger every map `loopMs` for `ms`. `follow` returns a Vector3/Vector2 or null (stops). |
| `hero_footfall(phase, x, z, area_id, wet = false, running = false)` / `hero_stopped()` | Per-frame footsteps from the walk loop phase (0..1, -1 if none); picks the area/wading surface and gain. |
| `footstep(step_id, pos, gain)` | One surface step (`stepStone` / `stepDirt` / `stepGrass` / `stepWater`). |
| `gather(skill, kind = "", pos = null)` | The work-cycle sound (`DmGatherSfx`). |
| `play_loot(rarities: Array)` | Highest rarity picks the loot sound. |
| `partner: bool` | Remote-player rule (dims/limits). Only the event router (`DmEventFx`) sets it, around an effect that names another player. |
| `apply_settings(dict)`, `seed_rng(int)`, `stats()`, `reset_stats()`, `music_cue()`, `current_area()`, `boss_bed_active()` | Settings, determinism for tests, QA snapshot. |
| signal `sfx_played(sfx_name)` | Emitted when a clip started. |

## Files
- `audio_mixer.gd` `DmAudioMixer`: buses, trims, PROFILES, slider/distance/pan/repeat maths, voice + id limiters, window counter, combat activity, duck curve.
- `audio_packs.gd` `DmAudioPacks`: pack groups, per-id bus, clip length caps, area packs.
- `audio_samples.gd` `DmSampleBank`: clip paths, LEGACY clips, pack load/release, seeded variant pick.
- `audio_ambience.gd` `DmAudioAmbience`: zone beds, accents.
- `audio_music_state.gd` `DmMusicState`: the MusicDirector decisions as a pure state machine (cue per area/boss/volume, crossfade, loop self-handover).
- `audio_music.gd` `DmMusicDirector`: runs the state machine with players on the `Music` bus (crossfade tau FADE/3, combat duck, cue duck).
- `audio_footsteps.gd` `DmFootstepTracker`, `audio_gather_sfx.gd` `DmGatherSfx`: footstep tracking, gather sounds.
- `audio_map.gd` `DmAudioMap`: typed access to `client/data/content/audioMap.json` (the recorded-sound map).
- `audio_synth.gd` `DmAudioSynth`: procedural loops (zone drones, boss drum) generated at runtime.
- `audio_director.gd`: the autoload.

## Assets (`client/assets/audio/`, `.import` files committed)
| Folder | Files | Size | Notes |
| --- | --- | --- | --- |
| `esm/` | 318 | 35 MB | one-shots, WAV |
| `music/` | 5 | 7.9 MB | MP3 |
| `ambience/` | 7 | 0.5 MB | bed loops, Ogg; `.import` has `loop=true` |
| `world/`, `combat/` | 12 + 2 | 0.3 MB | bells, gusts, crows, moans, embers, boss toll |
| `eleven/` | 1 | 0.1 MB | sounds generated from Discord with ElevenLabs (ASSET_PIPELINE.md): sfx WAV mono 16-bit, music MP3; spec in `audio-manifest/eleven/<id>.json`. Only `chat_ding.wav` is here so far |

How a sound is made, levelled and recorded (its licence row is in docs/AUDIO-SOURCES.md): ASSET_PIPELINE.md "Audio generation". How the files reach
`client/assets/`: client/tools/ASSETS.md.

`eleven/chat_ding.wav` (a short bell ding) is not in the audio map: `DmGameUi._chat_ping` plays it on the `Ui` bus when another player's party chat line arrives.

## Behaviour worth knowing
- No synthesised fallback voices: `lowHealth` (no clip) is silent, and `partial` clips play alone. Zone drones and the boss drum are generated
  at runtime by `DmAudioSynth`.
- One `AudioEffectReverb` (wet 0.1) per category bus; Master has a compressor (-18 dB, 3:1) then a limiter (-3 dB).
- Pan is per-voice `AudioEffectPanner` (world-x based), not 3D audio. Voice pool is 48 players.
- MP3 music is not looped by the engine; `DmMusicState` hands over to a fresh copy 3.25 s before the end.
- The bus layout is edited only under the mixer's lock (client/core/THREADING.md).

## Sound

Sound is the `AudioDirector` autoload (`audio/`: its map, mixer, beds, music and footsteps; `audio/README.md`) and the cues the game plays through it. The cues of creatures come from the core's events, never from
a node per creature, through one router and the ids of the audio map:

| cue | where it plays |
|---|---|
| an elite rising within 40 m (`eliteAggro`), every telegraph (`tellStrike`; `tollSmall` for the cone and the toll; `raise`; `curse`), a swing landing (the attack voice within 18 m; `boneHit` for a slam), the ghoul's eruption (`burst`), a death (`enemyDeath` or `eliteDeath`; the death voice within 26 m) | `DmEnemyFx`, from the host's `enemy_spawned`, `telegraph`, `enemy_attack`, `enemy_state` and `enemy_died`, through `DmEventFx` |
| the affixes: the bell's toll (`toll`), a meal (`raise`), the vengeful's burst (`burst`) | `DmEnemyFx._on_affix_moment` |
| a thrall standing up (`thrallRise`), one killed (`thrallDeath`; not one that crumbled, was sacrificed or decayed) | `DmEnemyFx`, from `thrall_raised` and `thrall_died`; a guest's puppet core raises the same events |
| the hero hurt (`hurt`, `lowHealth` under 30 %), `buy`, the pickups | `DmNextUiHost`, `DmNextLoot` |
| the rites | `DmRiteFx`, through the caster |
| the listener, the area's bed and score, the hero's footsteps (the walk loop's phase, the area's surface, water where he wades), the gate | `DmAudioHooks` (a child of the game scene) |
| the boss score and the boss sounds | `DmBossHost`, `DmBossFx` |
| the panels, the counsel's card | `DmGameUi.sound`, connected to the director by the game scene |

The hooks' gate sound is the world's `door_opened` signal (a door rose: at the door's centre; silent for doors that rise while the world loads, before the hooks' first frame).
`DmEnemyFx` forgets a swing when its body leaves alive (a boss's adds go with him). Everything is gated by `opts.audio` (on in a player's window, off headless).
Every kind on the core has its sounds (the router plays the tells; the Templar's shield glance, `tollSmall`, and the Acolyte's Unbind, `raise`, are cue sounds of `DmEnemyFx._on_cue`). The Depths have no sounds of their own (`gate`, `chestOpen`, `levelUp`, `click` and `error` are existing ones).

`tests/sound.gd` puts a recording stand-in where the director is (every call logged, passed on to the real one where a check needs it) and plays a scripted fight in the Graves, the hero standing still and not able to
fall, and checks the cues played for the events the core raised, by name and count (a swing within two ticks of landing or of what ended it may count either way); then the thralls at their places and only the killed ones' death, and the hero's world on the real director: footsteps, the beds
and scores of four areas, the gate, the boss score with the King.

## Tests
- `client/tests/sound.gd`: the cues the combat core's events play, by name and count, the hero's footsteps, the area beds and scores, the gate and the boss
  score, on a recording stand-in for the director ("Sound" above).
- `client/tests/threads.gd` holds the bus-layout lock rule.

## Known gaps
- The score is five ElevenLabs music cues (`docs/AUDIO-SOURCES.md`): one boss cue for every boss, no per-boss scores yet.
  New cues: `tools/audio/generate-eleven-music.mjs` -> `tools/audio/prepare-eleven-music.mjs` (writes `public/audio/music/`) -> copied into `client/assets/audio/music/` by hand (ASSET_PIPELINE.md "Into the game").
