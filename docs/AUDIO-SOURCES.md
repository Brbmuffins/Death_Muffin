# Audio sources

Every audio file the game ships, with its origin and licence. The masters are in `public/audio/`; `tools/godot/sync-audio-assets.sh` copies them into
`godot/assets/audio/` (Opus clips become WAV there because Godot cannot import Opus). Paths below are the `public/audio/` masters.

## Policy

Game sound comes from one licensed library: **Epic Stock Media "Fantasy Game"** (517 WAVs, 96 kHz / 24-bit). The
owner (Muffin Development) holds the royalty-free licence; the clips are used in-game only. **The source library is not
redistributed**: this repository contains only the short, trimmed, re-encoded clips the game plays (below), never the pack's
WAVs, images, documents or demo track, and never a full-length original. Anything the pack has no fit for stays on the
earlier sounds listed under "Kept" (Kenney CC0 bells, generated accents, WebAudio synthesis). Do not add other third-party
audio without recording its licence here.

## `public/audio/esm/` (the Epic Stock Media clips)

- **What plays when** is the audio map in `godot/audio/audio_map.gd` (see `godot/audio/README.md`). Clip names there are `folder/name` from the pack's own
  file list (`docs/audio/esm-fantasy-game-files.txt`, prefix stripped).
- **Built** from the owner's copy of the pack (`/home/ubuntu/death-muffin/audio-src/fantasy-game`) by a script that is no longer in this repo
  (`tools/audio/build-esm.mjs`, see git history before 2026-10-09). The shipped files are the clips the map names (318 clips for 181 sounds). Per clip: mono, 48 kHz; leading silence trimmed; cut to the longest length any
  sound using it needs; cast / hit clips start at their impact so the sound lands with the VFX release; fades; RMS-levelled per class
  (sfx / ui / footsteps / ambience) with a peak ceiling; **Ogg Opus, 48 kbps VBR**. Output `public/audio/esm/<folder>__<name>.opus`
  plus `manifest.json` (sizes, lengths, loudness). Re-runnable and deterministic for a given ffmpeg.
- **Format:** the masters are Ogg Opus; the Godot copies are mono 44.1 kHz WAV (imported QOA-compressed so a clip starts with no decoder set-up).

## Kept: not from the pack (no fitting clip in it)

| Files | Source | Used for |
|---|---|---|
| `public/audio/combat/boss_toll_1.ogg`, `boss_toll_2.ogg` | Kenney Impact Sounds `impactBell_heavy_000/001`, Sci-Fi `spaceEngineLow_000/001` (CC0), octave-down bell with a drone | Prelate's toll (the pack has no bell; the ESM metallic sting is layered on top) |
| `public/audio/world/amb_bell_1.ogg` .. `_3.ogg` | Kenney Impact `impactBell_heavy_000-002` (CC0), pitched down, low-passed, long echo | a bell far off (`distantBell`) |
| `public/audio/world/amb_gust_1.ogg`, `_2.ogg` | Generated in ffmpeg (brown noise, band-passed swell) | wind gust (the pack has no wind) |
| `public/audio/world/amb_ember_1.ogg` .. `_3.ogg` | Generated in ffmpeg (`aevalsrc` random impulses, filtered) | crackling embers |
| `public/audio/world/amb_moan_1.ogg`, `_2.ogg` | Generated in ffmpeg (pink noise, formant band-pass, vibrato, echo) | far-off murmuring |
| `public/audio/world/amb_crow_1.ogg`, `_2.ogg` | Generated in ffmpeg (`aevalsrc` swept harmonic buzz with rasp) | crow caw, under the pack's creature clip |

The Kenney clips are CC0 1.0 (credit not required; "Kenney (kenney.nl)" given anyway): Impact Sounds https://kenney.nl/assets/impact-sounds
(`public/audio/combat/LICENSE-kenney-impact-sounds.txt`), Sci-Fi Sounds https://kenney.nl/assets/sci-fi-sounds
(`public/audio/combat/LICENSE-kenney-sci-fi-sounds.txt`). They were built by `tools/audio/build-combat-samples.mjs` and
`tools/audio/build-world-samples.mjs`; those scripts also describe clips that are no longer shipped (replaced by the pack in
2026-10), so do not re-run them over `public/audio/`.

## `public/audio/ambience/` (zone bed loops)

The original five beds were generated in ffmpeg (no source recording): filtered noise,
equal-power crossfaded tail-to-head into a seamless 12 s loop, a periodic swell on top,
mono 24 kHz Ogg Vorbis. The engine varies loops per zone through playback rate, low-pass
and gain (`godot/audio/audio_ambience.gd`).

| File | Recipe |
|---|---|
| `bed_wind.ogg` | Brown noise, band-limited, slow swell |
| `bed_hollow.ogg` | Brown noise low-passed with two resonances (cave room tone) |
| `bed_water.ogg` | Pink noise, high-passed, rippling swell (trickle) |
| `bed_fire.ogg` | Brown/white noise with random crackle impulses |
| `bed_murmur.ogg` | Pink noise through a vocal-range band-pass, swell (crowd) |

`bed_rain.ogg` and `bed_flame.ogg` were generated for Death Muffin with ElevenLabs Sound Effects v2 on 2026-10-04 using the owner's paid Creator account. Their source MP3s and request metadata are kept privately under `/home/ubuntu/death-muffin/private/ambience-drafts/`; prompts are in `tools/audio/generate-eleven-ambience.mjs`. `tools/audio/prepare-eleven-ambience.mjs` makes compact 24 kHz mono Vorbis loops and limits peaks. Rain plays in the Graves, Cloister, and Fen; flames play at the Pyre and in the Alchemist's Wing. See the [Sound Effects API](https://elevenlabs.io/docs/api-reference/text-to-sound-effects/convert) and [ElevenLabs terms](https://elevenlabs.io/terms-of-use).

## `public/audio/music/` -> `godot/assets/audio/music/` (original game score)

Five original instrumental cues were generated for Death Muffin with Eleven Music v2.5 on 2026-10-04 using the owner's paid Creator account. The prompts are in `tools/audio/generate-eleven-music.mjs`; original MP3s and request metadata are private in `/home/ubuntu/death-muffin/private/music-drafts/`. `tools/audio/prepare-eleven-music.mjs` makes 160 kbps MP3 game loops with a 5 s overlap and a consistent loudness target. The game streams one cue at a time, crossfades on area or boss changes, and has a separate Music slider (`godot/audio/`).

| Shipped file | ElevenLabs song ID | Intended areas |
|---|---|---|
| `chapterhouse.mp3` | `qNwz58dJ7F2BFoJXBUqi` | Chapterhouse, Alchemist's Wing, Sexton's Acre |
| `graves.mp3` | `1bmgTc7bU1CSuymXPfpb` | Graves, Cloister, Fen, Coliseum |
| `ossuary.mp3` | `o7s6Pc2kwtsYqxzlZl9L` | Ossuary, Nave, Sanctum, Warren, Depths |
| `pyre.mp3` | `fqwplzeT2L60Ue3QymUx` | Cinder Pyre |
| `boss.mp3` | `EZ1tTGBF07v09eT3ApQP` | Active area boss |

The owner confirmed on 2026-10-04 that Death Muffin is not currently monetized. ElevenLabs' [Music Model-Specific Terms](https://elevenlabs.io/eleven-music-model-specific-terms) exclude monetized games offered on more than one platform from Creator media rights, and list Creator as an individual-use plan. Recheck the distribution plan and rights before monetizing the game or transferring its music to an entity.

## Removed: `public/audio/crossworlds/`

Three clips (`dark-magic-spell-1`, `dark-magic-spell-2`, `magic-cast-whoosh-2-1`)
were extracted from the Crossworlds Unity client archive, which carried no licence
or attribution file, so their redistribution rights were unclear. They are removed
and replaced (first by CC0 equivalents, now by the pack's `litany`, `exhume` and `veilRite`
clips). Do not add recordings of unclear origin.

## Synthesised sound

Sounds not listed above (fallbacks, tones, noise bursts, the low-health heartbeat) are generated at runtime by the audio engine in `godot/audio/`; there is no
source file.
