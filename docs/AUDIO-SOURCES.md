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

## `public/audio/world/` (second pass: gathering, rites, interface, ambient details)

Built by `node tools/audio/build-world-samples.mjs <packs-dir>` from the same three Kenney
packs (CC0; licence copies in the folder). Mono 32 kHz Ogg Vorbis, peak -2 dBFS, same treatment
vocabulary as above. Each clip is optional: the synthesised sound plays alone if it fails to load.
"Generated" means built in ffmpeg from synthetic noise or `aevalsrc`; there is no source recording.

| Files | Source clips | Treatment |
|---|---|---|
| `gather_chop_1.ogg`, `gather_chop_2.ogg`, `gather_chop_3.ogg` | RPG Audio `chop`; Impact `impactWood_heavy_000-002` | Axe knock into soft wood |
| `gather_mine_1.ogg`, `gather_mine_2.ogg`, `gather_mine_3.ogg` | Impact `impactMining_000-002`, `impactMetal_light_000-002` | Pick on rock with a faint ring |
| `gather_dig_1.ogg`, `gather_dig_2.ogg` | Impact `footstep_snow_001/002`, `footstep_grass_000/001`, `impactSoft_heavy_000/001` | Pitched-down spade scrape and soft thud |
| `gather_splash_1.ogg`, `gather_splash_2.ogg` | Sci-Fi `slime_000/001`; Impact `impactSoft_medium_000/001`; generated pink noise | Line cast splash |
| `gather_reel_1.ogg` | RPG Audio `metalClick`, Sci-Fi `slime_001`; generated pink noise | Ratchet clicks then a catch splash |
| `gather_saw_1.ogg`, `gather_saw_2.ogg` | RPG Audio `drawKnife1-3`; Impact `impactWood_light_001/002`; generated noise | Two slow pitched-down saw strokes and a plank knock (Sawpit) |
| `gather_kiln_1.ogg`, `gather_kiln_2.ogg` | Sci-Fi `thrusterFire_000/001`; Impact `impactWood_light_000-003`; generated crackle | Fire breath, bones dropped in (Bone Kiln) |
| `gather_cook_1.ogg`, `gather_cook_2.ogg` | RPG Audio `metalPot1/2`; generated sizzle | Pan sizzle (Cooking Fire) |
| `gather_grind_1.ogg`, `gather_grind_2.ogg` | Sci-Fi `spaceEngineSmall_000/001`; Impact `impactWood_light_000-004`, `footstep_concrete_000/001`; RPG Audio `metalLatch` | Low motor, bone crunch, latch (Bone Grinder) |
| `gather_craft_1.ogg`, `gather_craft_2.ogg` | Impact `impactMetal_light_001/002`, `impactWood_medium_000/001`; RPG Audio `metalClick` | Workbench tap |
| `gather_vault_open_1.ogg`, `gather_vault_close_1.ogg` | RPG Audio `doorOpen_1`, `doorClose_1`, `creak1`, `metalLatch`; Impact `impactPlate_heavy_001` | Heavy lid, pitched down |
| `rite_frost_1.ogg`, `rite_frost_2.ogg` | Impact `impactGlass_heavy_000/001` (reversed), `impactGlass_medium_001/002`; generated noise | Cold inhale into ice cracks (Grave Frost) |
| `rite_siphon_1.ogg`, `rite_siphon_2.ogg` | Sci-Fi `forceField_001/002`, `slime_000/001` | Pitched-down pulsing drain (Soul Siphon) |
| `rite_prison_1.ogg`, `rite_prison_2.ogg` | Impact `impactWood_heavy_000-004`, `impactPlate_heavy_000/001` | Staggered bone spikes and a low thud (Bone Prison) |
| `rite_hands_1.ogg`, `rite_hands_2.ogg` | Impact `footstep_snow_002/003`, `impactWood_light_000-004`; Sci-Fi `slime_000/001`; RPG Audio `cloth2` | Earth, clawing taps (Grave Hands) |
| `rite_storm_1.ogg`, `rite_storm_2.ogg` | Sci-Fi `thrusterFire_002/003`; Impact `impactWood_light_000-004` | Tremolo whirl with bone rattle (Bone Storm) |
| `rite_soul_1.ogg`, `rite_soul_2.ogg` | Sci-Fi `forceField_003/004` (reversed), `lowFrequency_explosion_000/001`; Impact `impactBell_heavy_002/003` | Rising pull into a bell and boom (Soul Harvest release) |
| `rite_wall_1.ogg` | Impact `impactPlate_heavy_002`, `footstep_concrete_003`; Sci-Fi `spaceEngineLow_003` | Stone slab (Ossuary Wall) |
| `rite_rend_1.ogg` | RPG Audio `knifeSlice`, `cloth3`; Impact `impactWood_light_002` | Rip (Command: Rend) |
| `rite_dirge_1.ogg` | Impact `impactBell_heavy_003`; Sci-Fi `forceField_000` | Low chill bell (Dirge) |
| `rite_bloom_1.ogg` | Sci-Fi `slime_000`, `computerNoise_002`; generated noise | Wet bloom (Plague Bloom) |
| `rite_chain_1.ogg`, `rite_chain_2.ogg` | Impact `impactMetal_light_000-004` | Pitched-up chain links |
| `rite_flail_1.ogg`, `rite_flail_2.ogg` | Sci-Fi `thrusterFire_000/001`; Impact `impactMetal_medium_000/001` | Swing and strike |
| `rite_palm_1.ogg` | Impact `impactPunch_heavy_001`, `impactBell_heavy_001` | Palm strike with a high bell |
| `rite_pyre_1.ogg` | Sci-Fi `thrusterFire_004`, `lowFrequency_explosion_001`; generated crackle | Fire rush |
| `rite_ward_1.ogg` | Impact `impactPlate_light_001`, `impactBell_heavy_002`; Sci-Fi `forceField_002` | Ward chime |
| `rite_choir_1.ogg` | Impact `impactBell_heavy_000-002` (three pitches); Sci-Fi `forceField_001` | Bell chord |
| `rite_blood_1.ogg` | Sci-Fi `slime_001`; Impact `impactPunch_medium_003` | Wet blow |
| `rite_spirit_1.ogg` | Sci-Fi `forceField_001`, `laserSmall_001` | Spirit bolt |
| `ui_open_1.ogg`, `ui_open_2.ogg` | RPG Audio `bookOpen`, `bookFlip1` | Short soft page sound (panel open) |
| `ui_close_1.ogg`, `ui_close_2.ogg` | RPG Audio `bookClose`, `bookPlace1` | Short soft thump (panel close) |
| `ui_equip_1.ogg`, `ui_equip_2.ogg` | RPG Audio `clothBelt`, `clothBelt2`; Impact `impactPlate_light_000/001` | Strap and plate |
| `ui_level_1.ogg` | Impact `impactBell_heavy_000-002` (three pitches); Sci-Fi `forceField_004` | Rising bell chord |
| `ui_loot_rare_1.ogg` | Impact `impactGlass_light_001`, `impactBell_heavy_000` | Glass chime |
| `ui_loot_epic_1.ogg` | Impact `impactBell_heavy_001`, `impactGlass_light_003`; Sci-Fi `forceField_003` | Bell with glass shimmer |
| `amb_bell_1.ogg`, `amb_bell_2.ogg`, `amb_bell_3.ogg` | Impact `impactBell_heavy_000-002` | Pitched down, low-passed, long echo: a bell far off |
| `amb_drip_1.ogg`, `amb_drip_2.ogg`, `amb_drip_3.ogg`, `amb_drip_4.ogg` | Impact `impactGlass_light_000/002`, `impactTin_medium_001/003` | Water drop in a cave |
| `amb_ember_1.ogg`, `amb_ember_2.ogg`, `amb_ember_3.ogg` | Generated (`aevalsrc` random impulses, filtered) | Crackling embers |
| `amb_bubble_1.ogg`, `amb_bubble_2.ogg`, `amb_bubble_3.ogg` | Sci-Fi `slime_000/001` | Slow low bog bubbles |
| `amb_dust_1.ogg`, `amb_dust_2.ogg` | Impact `impactGeneric_light_000-004` | Gravel trickling |
| `amb_moan_1.ogg`, `amb_moan_2.ogg` | Generated (pink noise, formant band-pass, vibrato, echo) | Far-off murmuring voices |
| `amb_gust_1.ogg`, `amb_gust_2.ogg` | Generated (brown noise, band-passed swell) | Wind gust |
| `amb_crow_1.ogg`, `amb_crow_2.ogg` | Generated (`aevalsrc` swept harmonic buzz with rasp) | Crow caw; no recording used |

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

Everything not listed above (bells, tones, noise bursts, the synthesised fallback beds) is
generated at runtime by WebAudio in `src/audio/Audio.ts`; there is no source file.
