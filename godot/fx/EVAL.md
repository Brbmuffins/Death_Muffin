# BinbunVFX evaluation (Godot 4.7.2, gl_compatibility)

Goal: "medium quality, clearly better than basic", performance first, spell colours per `SPELL_FX`. Nothing in the game wiring changed; this is the
shortlist for owner approval. Vendor sources live only in `/home/ubuntu/death-muffin/private/binbun/` (mode 700); the eval projects are
`godot/vendor_eval/` (gitignored); contact sheets are `godot/shots/fx_eval/sheets/<Pack>/` (gitignored). Only tooling is committed.

## Tooling (all in git, no vendor content)
`tools/godot/fx-eval-setup.sh` (one Godot project per pack, symlinked assets, headless import) -> `fx-eval-patch.py` (private-copy fixes) ->
`fx-eval-run.sh static|perf|perfvar|shots|shaders|synth` (render modes take the renderer lock, xvfb, timeouts) -> `fx-eval-report.py` (merge JSON).
Harness: `godot/fx/eval/eval_fx.gd`. Data: `godot/shots/fx_eval/data/effects_tiered.json` (per-effect numbers).

## 1. Import result
- **275 effect scenes in 12 packs, 275 load, 0 hard failures.** 12 non-effect shaders (UltimateToon, HologramFX, CardFX, GlassUI, Grass x2, Water x2,
  Skies, Transition, a sky shader inside "Triplanar") all compile on gl_compatibility with no shader errors; SupporterExtraTextures is textures only.
- 1 scene is genuinely broken: `magic_orb_flash_vfx_03_demo` (inline shaders `#include res://assets/GodotVFX/...` plus a "freshnel" typo). It is a demo
  variant; skip it. `fire_area_02` prints a harmless "WaveMesh not found" from an editor-only setter.
- The vendor scripts ARE in the zips (`vfx_controller.gd` etc.), so eval used the originals, not `dm_fx_controller.gd`. Note: `one_shot` is an
  editor-only setter in the vendor script (no-op at runtime); play = `_reset_particles()` + `AnimationPlayer.play("oneshot"|"main")`, which `DmFxBinbun` already does.
- Fixes needed to load (private copy only, `fx-eval-patch.py`): (a) 16 scenes/materials embed a `CompressedTexture2D` sub-resource pointing at the author's
  `.godot/imported/*.s3tc.ctex` hash (ImpactVFX hits, one Orbs demo, all CardFX materials): rewritten to the source png; (b) FireVFX ships
  `fire_area.gd`/`fire_forcefield.gd` extending `VFXController` but not the script: copied from PoisonVFX; (c) stale `.import` files (s3tc, wrong hashes) were
  reset to lossless (VRAM numbers below are therefore not representative). Packs overlap with *different* `shared/` shader/gradient versions, so never merge packs
  into one `res://assets`: use the manifest's chosen version per pack (as the existing converter does).

### Degradations on gl_compatibility (seen in the renders)
| area | what happens |
|---|---|
| Portals (25 scenes: gate/oval/portal/simple) | use stencil (`portal_stencil`): no stencil here, they draw as a solid clipped quad, not a window. Pretty, but not a doorway. |
| Trails / sub-emitters (24 / 15 FireVFX scenes) | trail particles show as thin white lines (fire sparks); sub-emitters not verified. Fire body itself is fine. |
| Depth texture (`proximity_fade`, 188 scenes) | every particle/transparent shader declares `hint_depth_texture`, which makes the renderer copy depth each frame. Measured +~1.5 ms/frame (llvmpipe) when any is on screen, none at all if removed. Soft-edge clipping into the ground is visible (ice mist/shards, cloud bases are cut flat). Recommend a build flag that strips the proximity branch. |
| Screen texture (portals, GlassUI, Water) | works, forces a framebuffer copy: keep to 1 per scene. |
| SmokeVFX (24 scenes) | rendered raw (no spawn colours) they are flat opaque white silhouettes. The existing `DmFxBinbun` path (colours + `dm_fade`/`dm_gain` hooks) is required; do not use these without it. |
| Dither alpha | `alpha_mode` DITHER shows a visible stipple at 1080p on explosions/impacts (`vfx_explosion_02/04`, `vfx_impact_*`). Use SMOOTH for hero effects. |
| Glow | cores clip to white (`gain` 1.0); the existing `gain` 0.5 knee is still needed. |

## 2. Cost measurement
Method: each effect alone in a 800x450 gl_compatibility viewport on llvmpipe (relative numbers only; base frame ~9-11 ms), 40 frames after a 4-frame
warm-up, played x1 and x10 (ring, radius 2.2). `x10 ms` = mean frame time above the empty scene. Also recorded: draw calls, objects, primitives,
particle `amount`, emitters/mesh nodes, an alpha-quad area estimate (m2), lights, shader texture samples (static scan incl. `#include`s). Second pass
`perfvar` applies two mitigations (no lights; every Plane/Quad mesh subdivided <= 3x3, spheres <= 12 segments). Files: `data/*_perf.json`, `*_perfvar.json`.

Synthetic checks (same renderer, 10 quads of 4 m, `synth.json`): subdivision 32x32 vs 1x1 = **+4.4 ms and 21,700 vs 82 primitives**;
depth-texture read = +1.2 ms; two noise samples at 4 m = +0.2 ms (at 8 m +5.4 ms: fill-rate scales with area); 10 OmniLight3D over a lit floor = +1 ms (almost all
effect materials are unlit, so the 183 scenes with a light mostly pay for nothing).

**Main finding: the heavy tier is geometry, not shading.** Vendor meshes are 32x32-subdivided quads and 4 m+ spheres, particle beams are 150-560k tris. Cutting
subdivision and removing lights moves 59 heavy -> 4 heavy.

Tiers (raw / mitigated), thresholds on x10 ms, x1 prims, x1 draw calls; game budgets are 24 one-shots + 32 loopers live, so a tier is also a concurrency allowance:
- **cheap** (x10 <= 30 ms, <= 5k tris, <= 6 draws): fine with 8+ alive. 77 raw / **162 mitigated**.
- **medium** (<= 100 ms, <= 40k tris): <= 4 alive at once. 138 / 108.
- **heavy** (above): hero/one-at-a-time only. 59 / **4** (`poison_cloud_01-04` stay heavy: 136 ms mitigated, ~90k-tri sphere shells + 544 m2 of alpha).

Per family (x10 ms raw -> mitigated; tris x1; draws):
| family | x10 ms raw -> mit | tris | draws | tier raw/mit |
|---|---|---|---|---|
| Beam / laser / blast | 175-672 -> 25-71 | 150-560k | 7-8 | H/M |
| ice_ball / ice_shard | 305-514 -> 21-41 | 70-140k | 2-3 | H/M-C |
| ice_cloud / ice_mist 02-04 / smoke(s) | 25-239 -> 17-65 | 23-130k | 2 | H-M/M-C |
| poison_cloud | 383-397 -> 136 | 90k | 3 | H/H |
| poison_bubble/stink/puddle/area | 32-146 -> 10-20 | 5-52k | 2-4 | M-H/C |
| vfx_explosion / vfx_impact | 27-248 -> 7-58 | 4-95k | 3-6 | M-H/C-M |
| vfx_hit, muzzle/short/wide flash | 8-34 (flashes to 80) -> 0-14 | 0.7-16k | 2-4 | C-M/C |
| pulse / ripple / ice_area | 22-72 -> 8-13 | 4-6.5k | 2-3 | C-M/C |
| basic/lift/pillar/rim area | 41-104 -> 22-37 | 1.3-7.7k | 4-6 | M/C-M |
| magic_orb_*, projectiles | 13-68 -> 2-26 | 0.9-17k | 2-4 | C-M/C |
| portals | 45-98 -> 5-21 | 12k | 4 | M/M |
| loot_* | 6-20 -> 4-14 | 2-3k | 5-9 | C-M/C-M |
| fire / fire_area / candle / forcefield | 2-53 -> -2-45 | 0.04-6k | 1-8 | C-M |
Draw calls are a separate watch item: loot markers take 5-9 draws each and `fire_05` 8 (fine at 1-2, add up at 10).

## 3. Contact sheets
`godot/shots/fx_eval/sheets/<Pack>/<Pack>_NN.png`, 6 effects per image, dark floor, glow on. One-shots/short loopers (<2 s) are a long-exposure max composite of 6
frames (reveals the whole burst, brightness exaggerated); long loopers are single frames. Shader packs: `godot/shots/fx_eval/shaders/`.
I looked at every pack; the verdicts below come from those renders.
Defaults ship in warm yellow/orange/cyan/magenta: **all need recolouring** through `primary/secondary/tertiary_color` (the existing runtime does).

## 4. Needs mapping, shortlist (recolour per `SPELL_FX`; tier raw/mitigated; mitigation = no light + subdiv <= 3)
"Now" = current wiring (`binbun-effects.json` id, with the procedural sprite/decal layer that always sits under it).

| # | Need | Now | Swap to | Colours (SPELL_FX) | Tier | Budget per cast |
|---|---|---|---|---|---|---|
| 1 | **Black Litany** shockwave | `pulse_area_03` | `pulse_area_05` (broken glyph rings, reads "ritual") | litany core/hot/void | M/C | 1 alive, <= 12 ms x10 |
| 2 | **Corpse Explosion** | `explosion_04` (dither) | `vfx_impact_02` (fire fountain + sparks) +, for resonant/elite, `vfx_explosion_04` | detonate ember/hot/crimson | M/C | one-shot, <= 20 ms x10 mit |
| 3 | **Miasma** landing / zone | `poison_cloud_01` (HEAVY 394) | `poison_area_03` (ground cloud) + `stink_small_02` puffs; zone upkeep `poison_puddle_02` | miasma rot/deep/spore | M-C | <= 14 ms x10 each |
| 4 | **Plague Bloom** / carrion seed | `poison_area_03`, `poison_bubble_02` | keep area_03; bubble_02 mitigated (140 -> 16) | bloom petal/rot/spore | C | looper, 1 per bloom |
| 5 | **Grave Frost** cone + shatter | `ice_mist_02`, `ice_shard_02` (H) | `ice_mist_01` (64 tris, cheap) + `ice_shard_02` only mitigated | frost frost/deep/pale | C / M | shard 1 per Chilled kill, cap 3 |
| 6 | **Dirge** zone | `ice_area_03` | keep (59 -> 9 mitigated) | dirge frost/deep/pale | M/C | 1 |
| 7 | **Soul Harvest** release, level-up | `pillar_area_03` | keep; `lift_area_05` as inner vines (jade pattern fits) | souls jade/deep/pale | M | 1 hero, <= 31 ms x10 |
| 8 | **Exhume** lift / thrall rise | `lift_area_02/04` | `lift_area_05` (jade vines), tier already C-M | exhume spirit/deep/beam | M/C | 1-3 |
| 9 | **Bone Needle** hit / crit | `vfx_hit_01`, `hit_07` | keep; `vfx_hit_05` (streaks) for Ivory Cleave | needle core/impact | M/C | spam-safe cheap (7 ms x10 mit) |
| 10 | **Wailing Skull / Rot Lance / curse bolt** projectile | `mprojectile_basic_01`, `javelin_02` | keep, tinted (skull jade, lance rot-chartreuse, curse enemy.curse); `mprojectile_wave_01` for Bone Fan | skull/lance/enemy | M/C | <= 5 ms x10 mit |
| 11 | **Soul Siphon / Exhume / Sanctify tether** | `beam_vfx_03/05/07` | only mitigated (HEAVY 432 -> 41-52, 420k tris -> trimmed); else keep the procedural beam | siphon jade / enemy | H/M | 1 live beam at a time |
| 12 | **Loot beams** | `ground_loot_*` | keep (cheap-medium); biggest fix is draw calls (9) | rarity | M | cap 6 on screen |
| 13 | **Grave Offering / Rally** ring | `ripple_area_02`, `basic_area_02` | keep; `ripple_area_02` is the cheapest ring (23 ms x10, 6 tris) | rend jade / thrall | C | spam-safe |
| 14 | **Bell toll / Toll / Great Toll** | `pulse_area_01` | keep; Great Toll: `pulse_area_04` bronze ring | enemy.toll / monk bronze | C | spam-safe |
| 15 | **Prelate / boss slam, Surge eruption** | `vfx_impact_04`, `vfx_explosion_06` | `vfx_impact_04` (medium, reads heavy) ; surge: `vfx_impact_03` | boss bronze / surge crack | M | 1-2, hero |
| 16 | **Warden fire** (Cremate pillar, Burn the Dead, Last Light) | procedural only | Cremate `pillar_area_01` tinted fire; Burn the Dead `fire_ball_01` + `fire_area_01` (1.9 ms); Last Light `pillar_area_03` gold | warden fire/gold/ash | C-M | cheap, 3 pools max |
| 17 | **Braziers / bonfire / kiln / candles** | `fire_03/07/05`, `fire_candle` | keep; `fire_03` is 9 ms x10 (cheapest real fire), avoid `fire_05` (8 draws) | - | C | many OK |
| 18 | **Witch / Monk / Veil rites** (hex, knell, echo, veil tear) | decals + crows | hex/knell mark: `magic_orb_flare_03` (13 ms x10), echo: `magic_orb_small_02`; veil tear: `ripple_area` + `ice_mist_01` pale | witch hex/blood, monk sound, veil | C | cheap |
| 19 | **Thrall hit / archer shot** | `short_flash_02`, `archer_flash` | `short_flash`/`wide_flash` (12-27 ms x10) | thrall spark | C | spam-safe |
| 20 | **Interactables / rim auras** | `rim_area_01` | `rim_area_03` (cold, C mit) for non-gold stations | per function | M/C | loopers cap 6 |

Not shortlisted, but good: `magic_orb_big/huge` (cheap) for relic pickups; `basic_area_01` as level-up ring.

**Top-10 impact order** (best look gain for least cost): 1 Corpse Explosion (#2), 2 Miasma landing (#3, removes the worst offender), 3 Black Litany (#1),
4 Grave Frost (#5), 5 Soul Harvest (#7), 6 projectiles tinted (#10), 7 Warden fire (#16), 8 tethers when mitigated (#11), 9 Exhume/rise (#8), 10 hits (#9).

## 5. Do NOT use (as authored)
- `poison_cloud_01-04` (394 ms x10, 136 mitigated, 544 m2 overdraw, flat-cut at floor): replace as in #3.
- All `beam_*`/`laser_*`/`blast_*` unmitigated (150-560k tris per beam, 80 draws at x10). Needs a lighter mesh before any use.
- `ice_ball_*`, `ice_cloud_*`, `ice_shard_*` unmitigated (480-510 ms x10); `smoke_big/smoke` loopers (wide quads 1.8k-4.8k m2, white blobs without the colour path).
- Portals / gates: no stencil, draw as a coloured wall; fine as a glowing banner only, not as a doorway; `gate_portal_06` is shard-noisy.
- `vfx_explosion_01`, `vfx_impact_05` (95k / 91k tris, 200-250 ms x10), and any dithered explosion (`explosion_02/04`) on a hero cast at 1080p.
- `magic_orb_flash_vfx_03_demo` (broken); `fire_trail`/`fire_*` sparks that rely on trails (white lines); `fire_05` for crowds (8 draws).
- Off-style: saturated primary yellow/magenta/cyan variants (`*_01/_02/_04` in most packs) are off-palette until recoloured; the Muzzle `big_flash` family reads as gunfire, not necromancy.
- Non-effect shader packs (Card, Hologram, GlassUI, Water, Grass, Toon, Skies): compile fine, but none maps to a current need; Water/Grass need the world pass, and the Water shader reads screen+depth (21 score).

## 6. Recommended rules for the swap pass
1. Strip lights from all Binbun scenes (single shared flash light stays) and cap Quad/Plane subdivision at 3 (mesh cost is the heavy tier).
2. Strip the `proximity_fade`/depth branch behind a project flag; soft particles later if wanted.
3. Per-effect alive caps from the tier column; heavy = 1 alive. Re-measure on real GPU before trusting absolute ms (llvmpipe is relative only).
4. Switch hero effects to SMOOTH alpha (no dither) and keep `gain` 0.5.
5. Re-run `tools/godot/fx-eval-run.sh perf` after the swap to confirm each swap stays inside its budget.
