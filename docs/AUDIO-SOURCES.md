# Audio sources

Every audio file the game ships, with its origin and licence. Only public-domain
(CC0) material is used for new sounds.

## Packs (all CC0 1.0)

| Pack | Author | URL | Licence file in repo |
|---|---|---|---|
| Impact Sounds | Kenney (kenney.nl) | https://kenney.nl/assets/impact-sounds | `public/audio/combat/LICENSE-kenney-impact-sounds.txt` |
| RPG Audio | Kenney | https://kenney.nl/assets/rpg-audio | `public/audio/combat/LICENSE-kenney-rpg-audio.txt`, `public/audio/kenney/LICENSE.txt` |
| Sci-Fi Sounds | Kenney | https://kenney.nl/assets/sci-fi-sounds | `public/audio/combat/LICENSE-kenney-sci-fi-sounds.txt` |

Credit is not required by CC0; "Kenney (kenney.nl)" is given here anyway.

## `public/audio/combat/` (combat sample layer)

Built by `node tools/audio/build-combat-samples.mjs <packs-dir>` from the unzipped
packs above: mono, 32 kHz Ogg Vorbis, trimmed, peak-normalised to -2 dBFS, and
darkened for the necromancer (pitched down, low-passed, reversed tails, layered,
echo). The script is the exact recipe for every file; edit it and re-run to change
a sound. Loaded lazily by `src/audio/samples.ts`; the synthesised sound plays alone
if a file fails to load.

| Files | Source clips | Treatment |
|---|---|---|
| `bone_hit_1.ogg`, `bone_hit_2.ogg`, `bone_hit_3.ogg` | Kenney Impact Sounds `impactWood_medium_000/003`, `impactPlank_medium_001`, `impactSoft_medium_000-002` | Bone crack over a soft flesh thud |
| `boss_awaken_1.ogg` | Kenney Impact `impactBell_heavy_002`; Sci-Fi `spaceEngineLow_002` | Very low bell and drone |
| `boss_slam_1.ogg`, `boss_slam_2.ogg` | Kenney Impact `impactMetal_heavy_000/001`, `impactPunch_heavy_002/003`; Sci-Fi `lowFrequency_explosion_000/001` | Pitched-down slam |
| `boss_toll_1.ogg`, `boss_toll_2.ogg` | Kenney Impact `impactBell_heavy_000/001`; Sci-Fi `spaceEngineLow_000/001` | Octave-down bell tell |
| `corpse_burst_1.ogg`, `corpse_burst_2.ogg`, `corpse_burst_3.ogg` | Kenney Sci-Fi `explosionCrunch_000-002`, `slime_000/001`, `lowFrequency_explosion_000/001` | Pitched-down wet crunch plus low boom |
| `elite_death_1.ogg`, `elite_death_2.ogg` | Kenney Impact `impactPunch_heavy_000/001`, `impactBell_heavy_000/001`; Sci-Fi `lowFrequency_explosion_000/001` | Heavy blow plus pitched-down bell |
| `enemy_death_1.ogg`, `enemy_death_2.ogg`, `enemy_death_3.ogg` | Kenney Impact `impactSoft_heavy_001-003`, `impactWood_light_000-002`; RPG Audio `dropLeather` | Flesh thud, bone snap, body drop |
| `exhume_1.ogg`, `exhume_2.ogg`, `exhume_3.ogg` | Kenney Impact `footstep_snow_001-003`, `footstep_grass_000-002`; Sci-Fi `slime_000/001`, `spaceEngineLow_000-002` | Pitched-down grave-dirt crunch, wet earth, sub rumble |
| `grave_step_1.ogg`, `grave_step_2.ogg` | Kenney Sci-Fi `thrusterFire_001/002`; RPG Audio `clothBelt`, `clothBelt2`; Impact `impactSoft_heavy_000/001` | Mist rush and re-form thud |
| `hurt_1.ogg`, `hurt_2.ogg`, `hurt_3.ogg` | Kenney Impact `impactPunch_medium_000-002`, `impactSoft_heavy_000-002` | Muffled body blow |
| `litany_1.ogg`, `litany_2.ogg` | Kenney Sci-Fi `forceField_001/002` (reversed), `lowFrequency_explosion_000/001`; Impact `impactBell_heavy_001/002` | Reversed inhale into a low boom with a pitched-down bell |
| `miasma_1.ogg`, `miasma_2.ogg` | Kenney Sci-Fi `slime_000/001`, `computerNoise_000/001` | Low-passed wet bubbling bed |
| `needle_cast_1.ogg`, `needle_cast_2.ogg`, `needle_cast_3.ogg` | Kenney RPG Audio `knifeSlice`, `knifeSlice2`, `drawKnife1`; Kenney Sci-Fi Sounds `thrusterFire_000-002` | Pitched up, high-passed, short whoosh layer |
| `needle_hit_1.ogg`, `needle_hit_2.ogg`, `needle_hit_3.ogg` | Kenney Impact Sounds `impactWood_light_000-002`, `impactGeneric_light_000-002` | Pitched up bone tick |
| `player_death_1.ogg` | Kenney Impact `impactBell_heavy_004`, `impactSoft_heavy_004` | Low bell and thud |
| `spear_1.ogg`, `spear_2.ogg` | Kenney Sci-Fi `thrusterFire_002/003`; Impact `impactWood_heavy_000/001`, `impactPunch_heavy_000-003` | Whoosh into heavy thud |
| `thrall_magic_1.ogg`, `thrall_magic_2.ogg` | Kenney Sci-Fi `forceField_001/002` | Bone mage / wraith bolt |
| `thrall_melee_1.ogg`, `thrall_melee_2.ogg`, `thrall_melee_3.ogg` | Kenney Impact `impactWood_light_001/003/004`, `impactSoft_medium_000-002` | Small dry bone knock (quiet by design) |
| `thrall_rise_1.ogg`, `thrall_rise_2.ogg` | Kenney Impact `impactWood_light_000-004`; RPG Audio `cloth2`, `cloth3` | Staggered bone clatter |
| `thrall_shot_1.ogg`, `thrall_shot_2.ogg` | Kenney RPG Audio `drawKnife2`, `knifeSlice2`; Impact `impactWood_light_003/004` | Archer release |
| `veil_whoosh_1.ogg` | Kenney Sci-Fi `thrusterFire_003`, `forceField_003` (reversed) | Replaces the Crossworlds "Magic Cast Whoosh" accent |
| `wail_1.ogg`, `wail_2.ogg`, `wail_3.ogg` | Generated in ffmpeg (`anoisesrc` noise, band-passed, tremolo/vibrato, echo); no source recording | Ghostly whisper; also used for the Curse sound at lower pitch |

## `public/audio/kenney/`

| File | Source |
|---|---|
| `footstep06.ogg`, `footstep09.ogg` | Kenney RPG Audio (CC0), licence `public/audio/kenney/LICENSE.txt` |

## Removed: `public/audio/crossworlds/`

Three clips (`dark-magic-spell-1`, `dark-magic-spell-2`, `magic-cast-whoosh-2-1`)
were extracted from the Crossworlds Unity client archive, which carried no licence
or attribution file, so their redistribution rights were unclear. They are removed
and replaced by CC0 equivalents: Black Litany now layers `litany_*`, Exhume layers
`exhume_*`, and Veil rite layers `veil_whoosh_1`. See `docs/CROSSWORLDS-AUDIO.md`.
If the original archive is ever cleared for redistribution, treat that as a
separate decision; do not add more files of that kind.

## Synthesised sound

Everything not listed above (bells, tones, noise bursts, ambience beds) is
generated at runtime by WebAudio in `src/audio/Audio.ts`; there is no source file.
