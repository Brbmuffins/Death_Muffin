# Blender / asset performance audit

Date 2026-10-02, branch `dm/blender-audit`. Audit and report only: no shipped model, texture or game source was changed.
Everything below was measured on this tree (dev server on :5383, headless Chromium with SwiftShader, headless Blender 4.5).
Scripts are in `tools/blender/audit/` and `tools/qa/scene-*.cjs`; raw data in `docs/blender-audit/data/`; images in `docs/blender-audit/`.

**What was and was not measured.** Triangle counts, draw calls, texture memory and file sizes are exact (`renderer.info`, glTF parsing).
GPU frame time on a real phone was *not* measured (SwiftShader is a CPU rasteriser), so "gain" below means triangles, draw calls, MB, not fps.
Triangle totals from `renderer.info` include the shadow pass on High (it renders the casters a second time).

> **Update 2 Oct 2026 (branch `dm/perf1`):** Phase 1 items #1 (spatial PropBatch chunking, 12 m cells) and #2 (decal layers: one InstancedMesh per texture + blend mode) are done; gold piles are single merged meshes; a `ResolutionGovernor` (src/app/framePacing.ts) lowers the pixel ratio under sustained slow frames.
> Re-measured with `fixed-fight-perf.cjs`, High / Low: nave 277 calls / 773k tris → 188 / 438k and 240 / 388k → 120 / 250k; graves 233 / 717k → 220 / 478k and 161 / 378k → 127 / 227k. Still open from Phase 1: #3 prune, #6 WebP, #7 clip trims.

> **Update 2 Oct 2026 (branch `dm/slim-assets`):** #3 prune, #7 clip trim, #5 texture downscale and #6 WebP are done (`tools/slim-models.mjs`, `tools/png-to-webp.mjs`, both idempotent).
> public/models GLBs 84.75 MB -> 64.04 MB (prune -8.0 MB, hero cast/dig trim -2.1 MB, textures -10.6 MB); public/art 17.83 MB PNG -> 2.41 MB WebP (22 MB dir -> ~7 MB with the SVGs).
> Decoded texture estimate (one copy of every model, w*h*4*1.33): 962 MB -> 490 MB. Hero/necromancer rigs, NPCs and the player's gear/tool props keep full size. Classes: horde enemies, thralls and clutter props 512 -> 256; bosses, elites (bone_golem, slag_brute, drowned_sexton) and landmark props 1024/512 -> 512.
> Only the player-avatar rigs (hero_*, necromancer) had `cast`/`dig` trimmed (1.4 s / 1.6 s; the game plays 1.1 / 1.3 s): enemy/boss `cast` windups, burrowing `dig` and looping laborer `dig` on thralls play whole clips, so they stay untrimmed. `clipTimings.json` regenerated. KTX2/Basis (#10) skipped: no `toktx`/`basisu` here.
> Before/after crops: `docs/screenshots/slim-assets/`.

## 1. Headlines

1. **The 552k triangles are mostly the world's props, not characters.** In the fixed nave fight on High (332 calls, 804k tris):
   instanced props are 247k tris in the main pass plus 279k in the shadow pass = **65% of all triangles**. All enemies together are 116k + 34k,
   the player 12k + 12k, thralls 23k + 22k, corpses 38k. Other areas show the same pattern (props 40-60%).
2. **The props are over-drawn about 5x.** `PropBatch` is one `InstancedMesh` per prop kind *per area*, so culling is per whole batch
   (one bounding sphere). Testing each instance against the real camera frustum, only **49k of the 245k drawn main-pass prop tris are inside the view**
   (-80%), and **117k of the ~279k drawn shadow tris are inside the shadow camera** (-58%). Chunking batches spatially removes ~40% of every frame's triangles on High
   and ~38% on Low (phones), with no art change.
3. **Draw calls are mostly decals.** 157-164 of ~283 main-pass calls (nave) are 2-triangle additive `PlaneGeometry` decals
   (spawn cracks, rings, auras, loot glows), each its own mesh and material. They total 328 triangles. (Partly inflated by the fixture, which spawns 47 enemies at once and so 28+ spawn-crack
   decals; steady state is lower, but every wave spawns ~10.) One instanced/pooled layer per texture would cut calls by ~40-50%.
4. **Corpses are full skinned clones.** `MAX_CORPSES = 45` in `WorldSim`; each one is a cloned skinned model (3.7-4.8k tris, 41 bones, own mixer, own material). 10 corpses = 37.5k tris and 10 calls;
   a heavy fight with 45 corpses is ~170k tris. They are frozen after `CORPSE_ANIM_S`, so they can become static meshes.
5. **Texture memory is the phone risk.** The nave scene references 313 textures = **~488 MB** of decoded RGBA8 + mips (props 240 MB / 162 tex, creatures 133 MB / 107 tex,
   architecture 75 MB, other 39 MB). 256 of them are 512x512 and 25 are 1024x1024. A horde enemy is ~100-160 px tall on screen, so its three 512 maps are heavily oversampled.
   (219 of the 313 are actually uploaded to the GPU at that moment; the rest are decoded but not yet drawn.)
6. **Free file-size win: every character GLB carries ~172 KB of orphan accessors** (119-122 unreferenced accessors; identical size in every character file).
   `prune()` removes them: 46 files x 172 KB = **7.5 MB of 84.7 MB (9%)**, zero visual risk. Re-serialising the grave robber goes 1.12 MB -> 0.94 MB.
7. **Blender's Decimate modifier is the wrong tool for these meshes.** Tripo meshes have split vertices at every UV seam; Blender collapse tears cracks in props
   (pillar, statue) and visibly damages characters at 35%. **meshoptimizer's attribute-aware simplify (glTF-Transform `weld` + `simplify`, already a dependency)** gives clean results:
   pillar 1505 -> 598 tris (-60%) looks identical; grave robber 3753 -> 2325 (-38%) and hero 11749 -> 8132 (-31%) look clean.
8. **PNG art is badly compressed.** `public/art` has 241 PNGs totalling 17.8 MB; lossy WebP q85 makes them **2.0 MB** (items 7.4 -> 0.5, abilities 6.9 -> 0.7). Item icons are 130 PNG + 150 SVG.
9. **The GLTFLoader has no decoders.** `AssetCache` uses a bare `new GLTFLoader()`: no Meshopt, Draco or KTX2. Models ship as WebP textures + KHR_mesh_quantization only (all 167 files).
   Adding a meshopt decoder is a few lines and unlocks vertex/animation compression.

## 2. Measured inventory

167 GLBs, 84.75 MB total: 46 `character.glb` (64.7 MB) + 121 props (20.0 MB). 591k triangles at rest (340k characters, 252k props). All are 1 primitive / 1 material
per mesh (so 1 draw call per instance, per pass), all WebP textures (420x 512^2, 66x 1024^2, 15x 256^2), 3 textures per material (base, normal, metallic-roughness), metallic and roughness factors = 1,
characters `doubleSided = true`, props single-sided, no Draco/meshopt/KTX2.

Where the bytes go (all 167 files): textures 22.6 MB (27%), animation samplers 18.8 MB (22%; rotation values 15.7 MB + times 3.2 MB), vertex attributes ~18.7 MB, indices 3.5 MB, **orphan accessors 7.5 MB (9%)**, glTF JSON chunks 9.6 MB (11%; ~260 KB of JSON per character from ~1,200 per-channel animation accessors/samplers, which also costs parse time on a phone; it gzips well, so check the server's compression) and ~4 MB alignment/other.
Full table: `docs/blender-audit/data/inventory.csv`.

### Top 20 by estimated on-screen cost

Cost = triangles x typical simultaneous count (main pass; High roughly doubles it with the shadow pass). Enemy counts are the per-area spawn `cap` split by roster weight, averaged over the 9 combat areas
(`data/spawn-mix.json`; caps are 26-34, waves 8-11). Prop counts are all placements in the world x 0.27, the measured fraction of prop triangles that survive today's per-batch culling in the nave.
Per-instance prop counts from `generateLayout()` (`data/prop-census.json`).

| # | Model | Kind | Tris | Bones | File MB | Typical count | Est. tris drawn (main) |
|---|---|---|---|---|---|---|---|
| 1 | corpses (full skinned clones of the dead enemy, cap 45) | corpse | 3,753 (robber) | 41 | - | 10 | 37,530 |
| 2 | props/pillar | prop | 1,505 | - | 0.09 | 88 in world, max 20/area | 35,759 |
| 3 | props/candles | prop | 1,324 | - | 0.14 | 65, max 13/area | 23,236 |
| 4 | thrall_* (legion) | thrall | 4,371 | 41 | 1.36 | 5 | 21,855 |
| 5 | props/dead_tree | prop | 2,591 | - | 0.28 | 25, max 11/area | 17,489 |
| 6 | grave_robber | enemy | 3,753 | 41 | 1.12 | 4.5 | 17,039 |
| 7 | props/bone_pile | prop | 2,114 | - | 0.21 | 25, max 5/area | 14,270 |
| 8 | props/statue | prop | 2,908 | - | 0.21 | 18, max 10/area | 14,133 |
| 9 | props/fence | prop | 1,143 | - | 0.15 | 41, max 33/area | 12,653 |
| 10 | hero_* (player; 9 models of 9.2-11.9k) | player | 11,749 | 41 | 2.15 | 1 | 11,749 |
| 11 | bone_hound | enemy | 3,523 | 38 | 0.39 | 3.2 | 11,344 |
| 12 | props/tombstone_round | prop | 811 | - | 0.14 | 46, max 35/area | 10,073 |
| 13 | props/grave_lantern | prop | 1,658 | - | 0.17 | 21, max 14/area | 9,401 |
| 14 | props/bone_candelabrum | prop | 2,246 | - | 0.21 | 15, max 8/area | 9,096 |
| 15 | penitent | enemy | 4,771 | 41 | 1.06 | 1.9 | 8,969 |
| 16 | props/brazier | prop | 1,418 | - | 0.11 | 21, max 6/area | 8,040 |
| 17 | carrion_sac | enemy | 3,905 | 41 | 1.01 | 2.0 | 7,966 |
| 18 | deacon | enemy | 4,756 | 41 | 1.06 | 1.5 | 7,039 |
| 19 | props/alch_reagent_shelf | prop | 2,710 | - | 0.18 | 9 (Alchemist's Wing only) | 6,585 |
| 20 | props/tombstone_cross | prop | 888 | - | 0.09 | 27, max 21/area | 6,474 |

Not in the table but relevant: bosses are the heaviest single models (boss_cinder_regent 14.0k, gravedigger_king 13.8k, mire_mother 13.6k, drowned_congregation 13.5k, abbess 11.9k, plague_saint 10.9k tris, all 1024^2 textures, ~2 MB each) and appear one at a time.
NPCs (sexton, prior, apothecary) are 7.8-7.9k tris each. Enemy polygon budgets are already sane (2.1-4.8k, bosses and heroes 9-14k); the cost is multiplicity and culling, not per-model weight.

### Animation data
Each biped carries 7-15 clips at 30 fps (idle is 15.4 s at 22 fps). Rotation tracks are 85% of the bytes. Notable:
- `dig` is **16.4 s / 472 keys** per model (16 models, 2.8 MB total), but `inPlaceAnimation.ts` plays only the first 1.3 s (`cast`: 1.1 s of a 5.4 s clip, 24 models, 1.7 MB). Trimming to the used length saves ~3-3.5 MB. Check whether the four thrall models (which also carry `dig` and a 6.6 s `chop`) use them.
- Clips are *not* byte-identical across models (only 1.4% duplicate), so there is no free shared-clip library; they are per-rig retargets of the same Tripo presets.
- Resampling walk/run from 30 to 20-24 fps and loosening the 1e-4 `resample` tolerance would cut rotation data a further 20-30%; meshopt compression of the sampler accessors typically 50%+.

## 3. Scene-level breakdown

Method (`tools/qa/scene-categories.cjs`, same fixed-fight fixture as `fixed-fight-perf.cjs`, 1280x800): hide one category at a time and read the `renderer.info` delta, with shadows off (main pass) and on (the difference is the shadow pass).
Nave, High (DPR 1.5 cap, shadows, bloom): **332 calls, 803,855 tris** (main 283 calls / 451,047 tris; shadow pass +49 calls / +352,808 tris).

| Category | Objects | Main calls | Main tris | Shadow calls | Shadow tris |
|---|---|---|---|---|---|
| World prop batches (instanced GLB props) | 129 batches / 603 instances | 22 | **246,695** | 24 | **279,416** |
| Enemies (47, skinned) | 47 | 28 | 116,160 | 8 | 33,851 |
| Corpses (10 full skinned clones) | 10 | 10 | 37,530 | 0 | 0 |
| Thralls (5) | 25 meshes | 25 | 23,035 | 5 | 21,855 |
| Player | 5 | 5 | 12,075 | 1 | 11,749 |
| Gather nodes | 84 | 2 | 4,408 | 1 | 2,958 |
| World architecture (floors, walls, gates) | 112 | 27 | 7,918 | 10 | 2,979 |
| Flames / mist points | 3 | 3 | 0 | 0 | 0 |
| **Effects, decals, rings, VFX** | 219 | **161** | 3,226 | 0 | 0 |

Other areas, High (`data/scene-categories-high-other-areas.json`):

| Area | Calls on/off shadows | Tris on/off | Prop tris main / shadow | Enemy tris main | Effect/decal calls |
|---|---|---|---|---|---|
| graves | 281 / 225 | 749k / 416k | 252k / 244k | 83k | 122 |
| ossuary | 233 / 185 | 652k / 358k | 164k / 232k | 113k | 76 |
| sanctum | 309 / 262 | 581k / 263k | 78k / 246k | 74k | 178 |
| cloister | 227 / 187 | 483k / 250k | 79k / 163k | 75k | 102 |
| pyre | 182 / 149 | 410k / 234k | 54k / 109k | 55k | 75 |
| fen | 174 / 137 | 531k / 256k | 134k / 221k | 48k | 70 |

In every area the shadow pass for props (110-280k) is as large as or larger than their main pass, because `PropBatch` marks every instanced prop taller than 1.5 m as a caster and the batch sphere is never culled by the 60x60 m shadow camera.
Low quality (phones: DPR 1, no shadows, no bloom, 844x390): **281 calls, 469k tris**, of which props are 273k and enemies 127k.
The user's "131 calls / 552k tris" is a lighter fixture of the same shape; ours add decals, so calls differ more than tris.

Per-instance culling potential (`tools/qa/scene-culling.cjs`, nave): 603 prop instances, 912k tris in the world; drawn today 245k main; **ideal 49k main** (28 instances in view) and 117k of 565k caster tris in the shadow frustum (63 instances).
Shadow camera: orthographic 60x60 m, far 90.

Other scene facts: 12 lights, 90-94 shader programs, 305-459 geometries, ~38 MB geometry memory, 235 GL textures. Creature materials are cloned per instance (`Creature.ts`), so skinned meshes can never batch.
`animSkip` already updates far animations every 3rd frame. Shadow casting skinned characters and `doubleSided = true` on all characters roughly double raster work for closed meshes (not measured).

## 4. Trial decimation (Blender 4.5 headless render, Cycles CPU, rest pose, original left / reduced right; top textured, bottom wireframe)

Wireframe spikes on the characters are artefacts of Blender's Wireframe modifier on thin skinned faces, not stray geometry. Rendered by `tools/blender/audit/decimate_trial.py`; meshopt copies come from `simplify_trial.mjs` (written to /tmp, not committed).

| Model | Method | Tris before -> after | Verdict | Image |
|---|---|---|---|---|
| grave_robber (most common enemy) | Blender Decimate collapse 50% (UV delimit) | 3,753 -> 1,876 (-50%) | acceptable at distance; face darkens, hem ragged | `docs/blender-audit/trial-grave_robber_blender50.webp` |
| grave_robber | Blender collapse 35% | 3,753 -> 1,313 (-65%) | face and hands damaged, too far | `docs/blender-audit/trial-grave_robber_blender35.webp` |
| grave_robber | **meshopt simplify** (ratio 0.5, error 0.02) | 3,753 -> 2,325 (-38%) | clean, silhouette and face kept | `docs/blender-audit/trial-grave_robber_meshopt.webp` |
| hero_gravecaller | Blender collapse 50% | 11,749 -> 5,874 (-50%) | good at hero size, slight shading shift | `docs/blender-audit/trial-hero_gravecaller_blender50.webp` |
| hero_gravecaller | meshopt (0.5, 0.02) | 11,749 -> 8,132 (-31%) | clean | `docs/blender-audit/trial-hero_gravecaller_meshopt.webp` |
| props/pillar (88 in world) | Blender collapse 40% | 1,505 -> 602 (-60%) | **cracks along the shaft and capital** | `docs/blender-audit/trial-pillar_blender40.webp` |
| props/pillar | **meshopt (0.4, 0.01)** | 1,505 -> 598 (-60%) | **indistinguishable from the original** | `docs/blender-audit/trial-pillar_meshopt.webp` |
| props/statue (18 in world) | Blender collapse 40% | 2,908 -> 1,163 (-60%) | **torn, holes in wings and hood** | `docs/blender-audit/trial-statue_blender40.webp` |
| props/statue | meshopt (0.4, 0.05) | 2,908 -> 2,112 (-27%) | clean (error cap stopped it; rest needs hand work) | `docs/blender-audit/trial-statue_meshopt.webp` |

Takeaways: (a) use meshopt simplify (weld first), not Blender's Decimate, for Tripo output; (b) props take 40-60% cuts safely, characters 30-40%, limited by the error budget (cloth hems and thin shells);
(c) simplified skinned models must still be checked in motion (weights are interpolated, the trial is rest pose only); (d) once culling is fixed, prop decimation is worth far less than it looks today
(the pillar's 36k "drawn" tris become ~7k), so do it for memory/load, not as the first fix. File size drops 10-20% with the geometry (robber 1.12 -> 0.89 MB, hero 2.15 -> 1.85 MB, partly the orphan prune).

Scene screenshot of the measured fixture: `docs/blender-audit/scene-high-nave.webp`.

## 5. Ranked opportunities

Gain is for the measured nave unless noted. Effort: S under half a day, M 1-2 days, L multi-day. Risk is visual or regression risk.

| # | Opportunity | Gain | Effort | Risk | Visual impact | Needs code? |
|---|---|---|---|---|---|---|
| 1 | **Spatial chunking of `PropBatch`** (e.g. 12-16 m cells, one InstancedMesh per prop kind per cell, keep `computeBoundingSphere`, keep `applyOcclusion`) | -200k main, -160k shadow tris (High 804k -> ~470k, Low 469k -> ~290k); calls ~neutral | M | Low | None | `WorldView.buildProps` |
| 2 | **Batch decals** (one pooled InstancedMesh or merged dynamic buffer per texture + blend mode; stop `mat.needsUpdate = true` per decal) | -100 to -150 draw calls (-40-50%) | M | Low-med (ordering with transparent sorting) | None | `Effects.decal` |
| 3 | `prune()` all 46 character GLBs | -7.5 MB (-9% of models), faster parse | S | None | None | build step only |
| 4 | **Corpses -> static meshes** (bake final pose; share per-type; or merge into one mesh per type) | -38k tris/10 calls now, up to -170k/45 calls in big fights; removes 45 skeletons/mixers/materials | M | Low-med (landing animation, tint, hover) | None if baked well | `EntityViews` corpse path |
| 5 | **Texture downscale by class** via the existing `build-characters.mjs` `size` option: horde enemies/thralls/small props 512 -> 256, bosses/NPC 1024 -> 512 (keep hero 1024) | VRAM/decoded texture memory ~-250 to -300 MB of ~488 MB (estimate), -4-5 MB files | S-M | Med: judge close-up props and hero | Slight softening on props in the centre of the screen | pipeline only |
| 6 | Convert 241 PNG art files to WebP | -15.8 MB (17.8 -> 2.0), faster first paint | S-M | Low: check ability icons for banding at q85 | None | 16 src files reference `.png` |
| 7 | **Trim `dig`/`cast` clips** to their used window (and verify `chop`/`dig` on thralls) | -3 to -3.5 MB | S | Low | None | build step |
| 8 | meshopt simplify: props 40-60%, enemies/thralls 30-40%, hero/boss 25-35%, per-model error cap, review in motion | -35-40% of the *remaining* character/prop tris (~-60k main, -25k shadow on the nave fixture after #1) | M | Med (silhouettes, weights) | Mild | pipeline only |
| 9 | Add `MeshoptDecoder` to `AssetCache` loader + compress vertex + animation data (`EXT_meshopt_compression`) | -40-50% of GLB bytes (84.7 MB -> ~45-50 MB), animation especially | M | Low (decoder is ~20 KB, supported by three) | None | `AssetCache.ts` + pipeline |
| 10 | **KTX2/Basis textures** (ETC1S for normal/MR, UASTC for base) | GPU memory 4-8x smaller on top of #5; needs `KTX2Loader` + transcoder, and `toktx`/`basisu` which is not installed here | L | Med (encoder quality, loader wiring, iOS formats) | Possible banding on normals | loader + pipeline |
| 11 | **Per-distance LOD for skinned enemies** (LOD1 ~1.2-1.8k tris past ~25 m, LOD2 billboard blob) | -30-50% of horde skinned tris when swarms are dense | L | Med (popping, shadow caster consistency) | Low if blended | `Creature`, `EntityViews` |
| 12 | Single-sided character materials + `shadowSide` tuning, test per model (closed meshes only; capes and hems need double-sided) | unmeasured raster/fill saving, free if it works | S | Med (holes in cloaks) | Risk of see-through cloth | `Creature` material setup |
| 13 | Skinned crowd instancing (vertex-animation textures / GPU skinning atlas) | up to -100 calls and CPU skinning for hordes | L | High | None | new renderer path |
| 14 | Baked AO / simpler materials (drop normal map from the smallest props, ORM->flat metalness) | shader/texture-sample cost on fill-limited phones; 3 samples per fragment today | M | Med | Slight flattening | material setup |
| 15 | **3D-rendered item icons** (Blender -> small WebP sprites) | Perf-neutral; better visual identity; replaces flat SVGs | M | Low | Positive | pipeline + icon refs |
| 16 | Environment kitbashing from existing meshes in Blender (merge a room's set dressing into one mesh with one atlas) | fewer batches/materials; lets multi-part set pieces ship as one draw | M-L | Low | Positive | pipeline |

### Visual-quality opportunities that are perf-neutral or positive
- **Item icons.** `docs/blender-audit/icons-blender-vs-svg.webp` is a proof of concept (`render_icon.py`): the shipped `gear_*` GLBs rendered at 256 px with a warm key and cool rim light (top row) against today's flat SVG tier icons (bottom row).
  They read as objects rather than glyphs, cost about 15-25 KB each as WebP, and render in ~5 s each headless. Caveats: the models need per-rarity grading (the SVGs encode iron/gold/bone/hell/moon in colour), long thin items such as the scythe need a better camera/roll
  (the scythe model renders as a thin vertical strip), and **armor pieces cannot be rendered this way** because worn armor is a body-region shader on the hero mesh, not separate meshes. For the 20 legendary armor icons the options are kitbashed
  chest/hand/leg/feet pieces cut from the hero sculpts (render with the set colour and emissive from `armorSets.ts`), or keep SVG for armor and use 3D for weapons and consumables first.
- **Consistent palette/edge treatment.** The Tripo bases differ in contrast (the grave robber is washed-out lilac skin, the gravecaller is deep purple). A Blender-side or glTF-Transform colour normalisation (tone-curve and saturation on baseColor per class) is cheap and perf-neutral,
  but needs an art review; do it with the texture downscale pass (#5) since the images are being re-encoded anyway.
- **Environment kitbashing.** Pillar, statue, candelabrum, fence, tombstone and dead tree meshes already exist; a Blender pass can assemble per-area set pieces (a row of pews and candles, a fence run, a crypt wall) as single merged meshes with one atlas, giving richer scenes with fewer instances.

## 6. Recommended plan

**Phase 1: biggest performance win, lowest visual risk (about 2-3 days).** No art is changed.
1. Chunk `PropBatch` spatially (#1). Expected: High nave 804k -> ~470k tris, Low 469k -> ~290k; shadow pass roughly halves. Verify with `scene-categories.cjs` / `fixed-fight-perf.cjs` before and after; ensure the occlusion shader patch and area-gated light sources still work.
2. Batch decals (#2) to cut ~100+ draw calls.
3. `prune()` characters (#3), trim dig/cast clips (#7), WebP the PNG art (#6): -26 MB of download without touching how anything looks (verify the WebP icons).
4. Re-run the same fixture and record the new numbers in this document.

**Phase 2: memory and load for phones (about 1 week).** Texture downscale by class with a visual review on a phone-size screenshot (#5); corpse baking (#4); add `MeshoptDecoder` and meshopt-compress GLBs (#9);
meshopt simplify of props and horde enemies with per-model review in motion (#8). Re-measure texture MB (target under ~200 MB in the nave) and total GLB bytes (target under ~50 MB).

**Phase 3: polish and heavier work.** 3D item icons for weapons/consumables (#15) and an armor-piece kit for the legendary icons, palette normalisation, environment kitbashing (#16), then LOD for skinned enemies (#11) and KTX2 (#10) only if phone measurements still demand them. Skinned crowd instancing (#13) is a last resort.

Guardrails from the owner principles: nothing here adds content; Phase 1 changes no visible asset; the necromancer hero models are kept at full quality in every phase (hero textures and tris are only touched after side-by-side review).

## 7. Uncertain / not measured
- No device GPU timing; use a real phone (or Chrome DevTools GPU profiling) to confirm that triangle reductions move frame time, and to find whether fill rate (bloom, DPR, transparent decals) is the real limit on Low.
- The decal count is inflated by the fixture's mass spawn; steady-state combat has fewer. Texture memory is "decoded + referenced", not a GPU residency readout (219 of 313 uploaded).
- Meshopt simplify results were judged in rest pose; skinning weights after simplification must be checked in animation.
- The `doubleSided` and `shadowSide` savings are guesses until A/B-tested.
- The 20 legendary armor SVGs live on another branch (`dm/legendary-release`) and were not inspected; the icon proof of concept uses the weapon gear GLBs present on this tree.
- Whether the production server gzips/brotlis GLB/WebP was not checked (affects the real download gain of #3, #7, #9).

## 8. Reproduce
```
node tools/blender/audit/inventory.mjs > /tmp/inv.json              # per-GLB inventory (tris, prims, bones, clips, textures, bytes)
node tools/blender/audit/bytes_breakdown.mjs public/models/*/character.glb   # where the bytes go
node tools/blender/audit/orphans.mjs <glb...>                       # dead accessors + what prune() saves
node tools/blender/audit/anim_stats.mjs <glb...>; node tools/blender/audit/anim_dupes.mjs
npx vite --host 127.0.0.1 --port 5383 --strictPort &                # then, with DM_PLAYWRIGHT_MODULE set:
node tools/blender/audit/spawn-census.cjs; node tools/blender/audit/prop-census.cjs /tmp/inv.json
node tools/qa/scene-categories.cjs   # DM_QA_AREAS=nave,graves DM_QA_QUALITY=low DM_QA_VIEWPORT=844x390
node tools/qa/scene-culling.cjs      # decal census, per-instance culling potential, texture MB by owner
node tools/blender/audit/rank.mjs /tmp/inv.json docs/blender-audit/data/spawn-mix.json docs/blender-audit/data/prop-census.json
blender -b --python tools/blender/audit/decimate_trial.py -- <glb> <ratio> <out_prefix> [tex|wire] [--yaw -90] [--right simplified.glb]
node tools/blender/audit/simplify_trial.mjs <in.glb> <ratio> <error> <out.glb>
blender -b --python tools/blender/audit/render_icon.py -- <glb> <out.png> 256
```
Headless Blender on this VPS has no EGL, so renders use Cycles on the CPU (Workbench/EEVEE do not start).
