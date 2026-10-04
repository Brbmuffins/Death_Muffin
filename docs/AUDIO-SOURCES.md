# Audio sources

Every audio file the game ships, with its origin and licence.

## Policy

Game sound comes from one licensed library: **Epic Stock Media "Fantasy Game"** (517 WAVs, 96 kHz / 24-bit). The
owner (Muffin Development) holds the royalty-free licence; the clips are used in-game only. **The source library is not
redistributed**: this repository contains only the short, trimmed, re-encoded clips the game plays (below), never the pack's
WAVs, images, documents or demo track, and never a full-length original. Anything the pack has no fit for stays on the
earlier sounds listed under "Kept" (Kenney CC0 bells, generated accents, WebAudio synthesis). Do not add other third-party
audio without recording its licence here.

## `public/audio/esm/` (the Epic Stock Media clips)

- **What plays when** is the table `AUDIO_MAP` in `src/content/audioMap.ts` (design and rationale: `docs/audio/AUDIO-MAP.md`).
  Clip names there are `folder/name` from the pack's own file list (`docs/audio/esm-fantasy-game-files.txt`, prefix stripped).
- **Built by** `nice -n 19 node tools/audio/build-esm.mjs` from the owner's copy of the pack (default
  `/home/ubuntu/death-muffin/audio-src/fantasy-game`, or `--src` / `$ESM_SRC`). It reads the map, so the shipped files are exactly the
  clips the map names (318 clips for 181 sounds). Per clip: mono, 48 kHz; leading silence trimmed; cut to the longest length any
  sound using it needs; cast / hit clips start at their impact so the sound lands with the VFX release; fades; RMS-levelled per class
  (sfx / ui / footsteps / ambience) with a peak ceiling; **Ogg Opus, 48 kbps VBR**. Output `public/audio/esm/<folder>__<name>.opus`
  plus `manifest.json` (sizes, lengths, loudness). Re-runnable and deterministic for a given ffmpeg.
- **Objective check:** the same run writes `docs/audio/esm-sanity-report.txt`: length, loudness, true peak, leading silence, clipping
  and impact time per clip, with outliers flagged, because the map was made from file names and not by ear.
- **Format and support:** Opus in Ogg decodes through `decodeAudioData` in Chromium (Chrome, Edge, WebView2, the Windows launcher)
  and Firefox, and in Safari 18.4+. On an older Safari the clips fail to decode and the game falls back to its synthesised sounds
  (the same graceful path as any missing file), never to silence or an error.
- **Lazy loading** (`src/audio/packs.ts`): `core`, `ui`, `rites`, `world`, `amb` load once after the first click; each area adds its
  floor (`foot_*`), the wading sound, its dead's voices (`fam_*`) and, outside the hub, `boss`; they are released two areas later.

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

Generated in ffmpeg (no source recording): filtered noise, equal-power crossfaded tail-to-head
into a seamless 12 s loop, a periodic swell on top, mono 24 kHz Ogg Vorbis. The engine varies one
loop per zone through playback rate, low-pass and gain (`src/audio/ambience.ts`).

| File | Recipe |
|---|---|
| `bed_wind.ogg` | Brown noise, band-limited, slow swell |
| `bed_hollow.ogg` | Brown noise low-passed with two resonances (cave room tone) |
| `bed_water.ogg` | Pink noise, high-passed, rippling swell (trickle) |
| `bed_fire.ogg` | Brown/white noise with random crackle impulses |
| `bed_murmur.ogg` | Pink noise through a vocal-range band-pass, swell (crowd) |

## Removed: `public/audio/crossworlds/`

Three clips (`dark-magic-spell-1`, `dark-magic-spell-2`, `magic-cast-whoosh-2-1`)
were extracted from the Crossworlds Unity client archive, which carried no licence
or attribution file, so their redistribution rights were unclear. They are removed
and replaced (first by CC0 equivalents, now by the pack's `litany`, `exhume` and `veilRite`
clips). See `docs/CROSSWORLDS-AUDIO.md`.
If the original archive is ever cleared for redistribution, treat that as a
separate decision; do not add more files of that kind.

## Synthesised sound

Everything not listed above (the fallback for any pack clip that fails to load, bells, tones, noise bursts, the synthesised fallback beds, the low-health heartbeat) is
generated at runtime by WebAudio in `src/audio/Audio.ts`; there is no source file.
