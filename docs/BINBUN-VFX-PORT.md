# BinbunVFX → Three.js port (handoff for Codex / any agent)

Status 2026-09-27 (workstation session, Codex). **Research, vendoring and the portable conversion pass are
done; the Three.js runtime and game wiring are not.** `tools/binbun-port.mjs` converted the 22-effect selection
in `art-manifest/binbun-effects.json` into `public/fx/binbun/` (2.1 MB / 93 files). The output preserves the
resolved Godot resource graphs, source colours, sampled curves, baked gradients/noise, copied textures and
include-expanded Godot shaders, so runtime work can continue on a machine without `art-src/`. The machine-readable
source record is [`art-manifest/binbun-vfx.json`](../art-manifest/binbun-vfx.json).

## 0. What the owner asked for

> "I have lots of effects from 6/18 in F:\. Use those, move the files accordingly so our root stays consistent."
> "I've confirmed the licence is good because this is a non-profit game."

- **Licence:** the owner confirmed on 2026-09-27 that the Binbun packs are licensed for this non-profit
  game. No licence file ships inside the zips. Keep the confirmation in `art-manifest/binbun-vfx.json`.
- **Goal:** use the Binbun Godot 4 VFX library in the Three.js game and keep the repo layout consistent.
  That means raw sources in `art-src/`, optimized output in `public/`, records in `art-manifest/`,
  runtime in `src/graphics/`.
- **Project rules still apply** (`CLAUDE.md`):
  - Additive only: layer new effects on the existing ones, and don't delete the current particles or decals.
  - Spell colours carry meaning, so recolour every effect from `SPELL_FX` in `src/content/abilities.ts`.
  - Stage, don't commit.
  - Every player-facing change keeps its help up to date.

## 1. Where the files are

| What | Where | In git? |
|---|---|---|
| Original downloads (62 zips, all dated 2026-06-18) | `F:\` root, **left untouched** (copied, not moved, so nothing is lost) | no |
| The 22 chosen packs, copied as zips | `art-src/vendor/binbun/zips/<Pack>.zip` (14 MB) | no (`art-src/` is gitignored) |
| The same packs, extracted | `art-src/vendor/binbun/<Pack>/…` (42 MB, Godot project layout `assets/BinbunVFX/<pack>/…` + `shared/`) | no |
| Source record: md5s, chosen versions, licence note | `art-manifest/binbun-vfx.json` | **yes** |
| This plan | `docs/BINBUN-VFX-PORT.md` | **yes** |

**Codex on a different machine** won't have `art-src/`, which is workstation-only like the Tripo raws. The
owner needs to copy `art-src/vendor/binbun/zips/` (14 MB) over, or run the converter on the workstation.
Committing the raw third-party sources is the owner's call; don't do it unasked. Everything under `public/`
that the converter outputs **is** meant to be committed.

### Chosen versions (duplicates resolved)

The "(1)"/"(2)" copies on F:\ are byte-identical duplicates (same md5), except these, where the newest or the
superset was kept:

| Pack | Kept | Why |
|---|---|---|
| Beam | `GodotBeamVFX (1).zip` | newer `laser_vfx_07` + `beam_vfx_scene` (2026-03-28 vs 03-23); `GodotBeamVFXFree.zip` is a subset |
| Muzzle flash | `MuzzleFlashVFX.zip` | newer `flash_01_long` + `vfx_controller.gd` (2026-03-29 vs 03-02) |
| Loot | `GodotLootVFXExtra.zip` | superset of `GodotLootVFX.zip` (+ divine tier) |
| Magic projectiles | `GreenExtra.zip` | superset of `MagicProjectilesVFX.zip` (+ `_05` variants) |
| Portal | `PortalVFXFull.zip` | superset of `PortalVFX.zip` (free = 1 scene) |
| Transition kit | `Full (2).zip` | newer `transition.gdshader` than `Full (3).zip`; `SourceCode.zip` is the same shader |
| Grass | `GodotGrassFull.zip` | `SourceCode (3).zip` is its source subset |
| Toon | `UltimateToon.zip` | `SourceCode (2).zip` is its shader only |
| Card / Hologram | `…Full.zip` | the `…Source.zip` files are shader-only subsets |

**Not effects, so left on F:\ and not copied:**
- Food megapack (Free/Pro/Source), RPG weapons, Treasure (Free/Pro/Source)
- `Stylized Nature MegaKit[Standard].zip`, `RetroUrban.zip`
- `Full.zip` (690 "Retro" ground PBR textures) and `Full (1).zip` (300 "Teak" wood PBR textures)

They are stylized and low-poly, and may clash with the dark-fantasy art. They're worth a look later for
Cooking meals, props or ground textures.

## 2. What's in the library (effect scenes per pack)

| Pack | Effect scenes | Game fit |
|---|---|---|
| FireVFX | fire_01–10, fire_area_01–08, fire_ball_01–06, fire_candle, fire_forcefield_01–04, fire_trail | candles/braziers in Chapterhouse and Bell Sanctum, Corpse Explosion embers, Vengeful affix, burning |
| IceVFX | ice_area/ball/cloud/mist/shard ×4 | Grave Frost, Dirge, Chill status |
| PoisonVFX | poison_area/bubble/cloud/puddle, stink_big/small ×4 | Miasma, Plague Bloom, Rotweaver, toxic enemies |
| SmokeVFX | smoke / smoke_big / smoke_thin ×8 | Censer Bearer incense pulse, wraith dissolve, Grave Step mist |
| ImpactVFX | vfx_explosion ×6, vfx_hit ×8, vfx_impact ×6 | Corpse Explosion, boss slams, Grave Surge, crits |
| MagicAreaVFX | basic/lift/pillar/pulse/rim/ripple_area ×5 | Litany, Soul Harvest, Exhume, telegraphs, level-up |
| MagicOrbsVFX | orb basic/big/flare/flash/huge/small ×5 | soul/corpse pickups, Wailing Skull core, boss orbs |
| MagicProjectilesVFX | basic/javelin/wave ×5 | Wailing Skull, Marrow Spear, enemy casters (Lich Acolyte) |
| BeamVFX | beam ×8, laser ×8, blast_01 | Exhume/Litany/deacon tethers (upgrade `Effects.beam`) |
| PortalVFX | gate ×8, oval ×8, portal ×8, simple | area exits/gates, enemy breaches |
| LootVFX | floating + ground × common/uncommon/rare/epic/legendary/mythic/divine | `LootView` rarity beams |
| MuzzleFlashVFX | big/muzzle/short/wide flash ×6 | archer thrall shots (low priority) |
| Non-VFX shader packs | TransitionKit (screen transitions), Skies, Water (+toon), Grass, UltimateToon materials, GlassUI, CardFX, HologramFX, TriplanarSource | Transition on area change; Water for the Drowned Nave; Grass for Hollow Graves; the rest are low priority |

List any pack: `find art-src/vendor/binbun/<Pack> -path '*/effects/*' -name '*.tscn'`.

## 3. How a Binbun effect is built (verified by reading the files)

Every effect is a Godot 4 **text** scene (`.tscn`, `format=3`) with a consistent shape:

- **Root `Node3D`** with `vfx_controller.gd`. It exports `primary_color` / `secondary_color` /
  `tertiary_color` and pushes them into **every child material's** same-named uniform, so **recolouring is
  built in**. That's how `SPELL_FX` colours map in. It also has `speed_scale` (sets the `time_scale`
  uniform), `alpha_mode`, and a `Light` child.
- **Children:**

  | Node | Count | Notes |
  |---|---|---|
  | `GPUParticles3D` | 353 | Keys: `process_material`, `draw_pass_1` (a mesh drawn per particle), `material_override`, `amount`, `lifetime`, `one_shot`, `explosiveness`, `local_coords`, `transform_align`, `transform`, `preprocess`, `draw_order`, `sub_emitter`, `trail_lifetime`. `transform_align`: 1 = Z-billboard, 2 = Y to velocity, 3 = both |
  | `MeshInstance3D` | 652 | `mesh`, `material_override`, `transform` |
  | `OmniLight3D` | 183 | Map onto `Effects.lightFlash`. **Never add PointLights**, because Effects keeps a fixed light count to avoid shader recompiles |
  | `AudioStreamPlayer3D` | 51 | Ignore; the game has its own `Audio.ts` |
  | `Decal` | 12 | Map onto `Effects.decal` |
  | `AnimationPlayer` | — | Libraries `RESET`, `main` (loop) and `oneshot` |

- **Meshes** (sub_resources): `QuadMesh` (size, subdivide), `SphereMesh` (radius, height, radial_segments,
  rings, is_hemisphere), `CylinderMesh` (top/bottom radius, height, segments, cap flags), `PlaneMesh`,
  `TorusMesh`, `TubeTrailMesh` (5 uses; skip or approximate).
- **`ParticleProcessMaterial` keys**, with use counts:

  | Uses | Keys |
  |---|---|
  | 200–360 | `gravity`, `alpha_curve`, `scale_curve`, `scale_min/max`, `spread`, `initial_velocity_min/max`, `direction` |
  | 100–170 | `color_initial_ramp`, `angle_min/max`, `emission_shape` (0 point, 1 sphere, 2 sphere surface, 3 box, 6 ring), `emission_sphere_radius`, `particle_flag_rotate_y` |
  | 40–100 | `emission_shape_scale/offset`, `color_ramp`, `damping_min/max`, `particle_flag_align_y`, `orbit_velocity_min/max/curve`, `radial_accel_*`, `radial_velocity_*` |
  | rare | `tangential_accel_*`, `turbulence_*`, `emission_point_texture`, `sub_emitter_*`, `hue_variation_*`, `emission_box_extents`, `flatness` |

  Godot defaults apply when a key is absent: `gravity` (0,-9.8,0), `direction` (1,0,0), `spread` 45,
  `scale` 1, `lifetime` 1, `amount` 8, and `explosiveness` 0.

- **Animations** only touch a small set of properties:

  | Property | Uses | What it does |
  |---|---|---|
  | `material_override:shader_parameter/alpha_multiplier` | 1012 | the main fade |
  | `Light:light_multiplier` | 372 | light fade |
  | `emitting` | 366 | start/stop particles |
  | `shrink_amount` / `open_amount` / `fade_mult` / `depth_mult` | 100 each | portal script props |
  | `shader_parameter/decay`, `grow`, `mask2_strength`, `displacement_scale` | a few each | other shader params |
  | `emission_energy`, `albedo_mix` | 24 each | Decal properties |

  Track keys: `times`, `transitions`, `values`, `interp` (0 nearest, 1 linear, 2 cubic), `update` (1 = discrete).
  The `oneshot` animation is the one to play for spell hits; `main` loops (use it for persistent props like candles and portals).

- **Particle `COLOR`:**
  - `color_initial_ramp` often only carries a random `COLOR.r` seed. The shared shaders use `COLOR.r` as a
    per-particle UV offset: `mask(UV, COLOR.r)`.
  - `alpha_curve` drives `COLOR.a` over the particle's life.
  - `INSTANCE_CUSTOM.y` is life progress (0 to 1) and `.x` is the rotation angle.

### Materials and shaders

Materials are `ShaderMaterial` resources, either external `.tres` under `<pack>/src/material/…` or inline
sub_resources. Shader use across all material files:

- `transparent` 185, `particle` 56, `glow_fresnel` 38 and `opaque` 24 — all four in `shared/shader/`
- `smoke` 24; `main` 22 (Grass)
- `base` 20 and `glow` 14 (Muzzle)
- `water` 10

Effect scenes also reference per-pack shaders:

| Pack | Shaders |
|---|---|
| Fire | `flame_01`, `flame_core`, `fire_area_01`, `fire_ball_01/02/03/06`, `fire_candle_core`, `fire_forcefield_01`, `smoke_01` |
| Impact | `basic`, `basic_billboard`, `explosion_core(_particle)`, `explosion_smoke`, `explostion_ring` (sic), `glow`, `ground_impact`, `impact_streaks`, `sparks` |
| Loot | `billboard_flare`, `glow_core`, `glow_tube`, `particle_star` |
| Portal | `portal`, `portal_glow`, `portal_stencil` (needs a stencil pass; approximate) |
| Beam | `beam_ball`, `beam_core`, `beam_flare`, `beam_outer`, `glow_particle` |
| Smoke | `smoke` |

There are ~40 effect shaders in total (~2,900 lines), all small (10–160 lines).

**The shared shaders are the backbone.** Ice, Poison, MagicArea, MagicOrbs and MagicProjectiles run almost
entirely on `transparent` / `particle` / `glow_fresnel` / `opaque`, so port those four first:

- **`transparent` / `particle`:**
  1. Up to 3 scrolling/rotating/radial noise masks, combined with `blendf` modes 0–11.
  2. Colour = `mix(secondary, primary, pow(smoothstep(mask), 3))`, or tertiary→secondary when `use_tertiary`.
  3. `EMISSION = ALBEDO * emission_strength`.
  4. Alpha = `pow(min(0.5 + alpha_smoothness/2, mask), 3) * alpha_multiplier * COLOR.a`.
  5. Optional vertex displacement along the normal, optional billboard.
  6. `particle` adds the `COLOR.r` UV offset.
- **`glow_fresnel`:** a fresnel term through a 1D gradient, times an optional scrolling mask. It's unshaded.
- **Both:** `alpha_mode` 0 is smooth; 1–3 are dither/cut LODs, so always use 0. `proximity_fade` needs a
  depth texture, so treat it as off (or add a soft-particle depth pass later).

### Textures: almost all are procedural and must be baked

Across the `.tres` files there are 416 `NoiseTexture2D` (each wrapping a `FastNoiseLite`), 407
`GradientTexture2D` and 34 `GradientTexture1D`. Only a few PNGs exist (`shared/texture/flare|flash*|spirals|cracks`,
the loot icons and `SupporterExtraTextures/flare`). The shared noise library lives in
`shared/texture/noise/{cell,pingpong,warp,web}/*.tres` and the gradients in
`shared/texture/gradient/{circle,line,ring,square,up}/*.tres`.

**NoiseTexture2D → bake to a grayscale PNG** with a FastNoiseLite port. Use the official JS FastNoiseLite
(MIT, npm `fastnoise-lite`), or vendor the single file into `tools/vendor/`. The Godot mapping (Godot 4
source, `modules/noise/fastnoise_lite.*`):

- **Textures:** default size 512×512, `normalize = true` (stretch min/max to 0–1), `invert`,
  `seamless` + `seamless_blend_skirt` (default 0.1), optional `color_ramp` (a Gradient).
- **Seamless:** Godot renders `(w + w·skirt) × (h + h·skirt)` and cross-fades the skirt over the seam with
  `1 - smoothstep(0.1, 0.9, t)`. Any equivalent edge cross-fade that tiles is fine.
- **2D sampling:** `get_noise_2d(x, y)` adds `offset`, applies the domain warp if `domain_warp_enabled`, then samples.
  Coordinates are **pixels**, so `frequency` is per pixel.
- **Enum mappings:**

  | Godot property | Values (Godot → FastNoiseLite) |
  |---|---|
  | `noise_type` | 0 Simplex = OpenSimplex2, **1 SimplexSmooth = OpenSimplex2S (default)**, 2 Cellular, 3 Perlin, 4 ValueCubic, 5 Value |
  | `fractal_type` | 0 None, **1 FBm (default)**, 2 Ridged, 3 PingPong |
  | `cellular_distance_function` | **0 Euclidean (default)**, 1 EuclideanSq, 2 Manhattan, 3 Hybrid |
  | `cellular_return_type` | 0 CellValue, **1 Distance (default)**, 2 Distance2, 3 Add, 4 Sub, 5 Mul, 6 Div |
  | `domain_warp_type` | **0 OpenSimplex2 (default)**, 1 OpenSimplex2Reduced, 2 BasicGrid |
  | `domain_warp_fractal_type` | 0 None, **1 Progressive (default)**, 2 Independent |

- **Godot defaults** (absent keys use these):
  - `seed` 0, `frequency` 0.01
  - `fractal_octaves` 5, `fractal_lacunarity` 2, `fractal_gain` 0.5, `fractal_weighted_strength` 0, `fractal_ping_pong_strength` 2
  - `cellular_jitter` 1
  - `domain_warp_amplitude` 30, `domain_warp_frequency` 0.05, `domain_warp_fractal_octaves` 5, `…lacunarity` 6, `…gain` 0.5
  - The warp object uses the same seed.

**GradientTexture2D → bake to a PNG** (default 64×64):
- `fill`: 0 linear, 1 radial, 2 square.
- `fill_from` / `fill_to` are in UV space.
- `repeat`: 0 none, 1 repeat, 2 mirror.
- The Gradient has `offsets` (default `[0, 1]`) and `colors` (PackedColorArray RGBA); `interpolation_mode` is
  0 linear, 1 constant, 2 cubic.

**GradientTexture1D:** bake as a 256×1 PNG, or ship it as a uniform array.

**CurveTexture / Curve** (particle `alpha_curve`, `scale_curve`, etc.) → sample 32–64 floats into the JSON:
- `_data` is `[Vector2(x, y), left_tangent, right_tangent, left_mode, right_mode, …]` per point.
- Godot's per-segment rule: `d = (b.x - a.x) / 3`, `yac = a.y + d·a.right_tangent`, `ybc = b.y - d·b.left_tangent`, then
  `bezier_interpolate(a.y, yac, ybc, b.y, t)`.
- `CurveXYZTexture` has three curves.

**Dedup:** many materials reference the same shared noise, so hash the resolved definition and write one PNG per unique texture.

### gdshader → GLSL (WebGL2 / GLSL ES 3.00) translation rules

It's close enough to transpile mechanically in the converter, but review every output:

1. **Declarations:**
   - Drop `shader_type`, `group_uniforms`, and the hint after `:` (`source_color`, `hint_range`, `repeat_*`,
     `filter_*`, `hint_depth_texture`).
   - **Strip uniform initializers** (ES 3.00 forbids them) and send the defaults from JS instead.
   - Inline `#include "util/*.gdshaderinc"`.
2. **`render_mode`** maps onto the material:

   | Godot | three.js |
   |---|---|
   | `blend_mix` | Normal blending |
   | `blend_add` | Additive blending |
   | `unshaded` | no lighting |
   | `cull_disabled` | `DoubleSide` |
   | `depth_draw_never` | `depthWrite: false` |
   | `depth_test_disabled` | `depthTest: false` |

3. **Fragment built-ins:**

   | Godot | GLSL |
   |---|---|
   | `UV` | `vUv` |
   | `COLOR` | `vColor` (vec4) |
   | `TIME` | `uTime` |
   | `NORMAL` | view-space normal |
   | `VIEW` | `normalize(-vViewPos)` |
   | `VERTEX` | `vViewPos` |
   | `FRAGCOORD` | `gl_FragCoord` |
   | `SCREEN_UV` | `gl_FragCoord.xy / uResolution` |
   | `INV_PROJECTION_MATRIX` | `inverse(projectionMatrix)` |
   | `ALBEDO`, `EMISSION`, `ALPHA` | locals |

4. **Vertex built-ins:**
   - `VERTEX` / `NORMAL` are model-space.
   - `MODEL_MATRIX` = `modelMatrix * instanceMatrix`.
   - `VIEW_MATRIX` = `viewMatrix`; `MAIN_CAM_INV_VIEW_MATRIX` = `inverse(viewMatrix)`.
   - `MODELVIEW_MATRIX` is writable (billboards); compute `gl_Position` after the user code.
   - `INSTANCE_CUSTOM` is an instanced vec4 attribute.
5. **Output:** these VFX are emission-dominated, so write `gl_FragColor = vec4(ALBEDO * 0.25 + EMISSION, ALPHA)`
   for lit shaders and `vec4(ALBEDO, ALPHA)` for `unshaded`. Tune against the game's bloom.
6. **Colour spaces:**
   - `source_color` vec4 uniforms are sRGB in Godot. Pass them through `THREE.Color` (linear working space).
   - Baked mask PNGs are **data**, so set `NoColorSpace` / linear on them.

## 4. Build plan (conversion done; runtime starts at step 3)

1. ✅ **`tools/binbun-port.mjs`** (Node, same style as `tools/build-characters.mjs`):
   - Parse Godot text resources (`[gd_scene|gd_resource]`, `[ext_resource]`, `[sub_resource]`, `[node]`,
     `[resource]`; values: `Vector2/3/4`, `Color`, `Transform3D`, `Packed*Array`, `SubResource()`,
     `ExtResource()`, `NodePath()`, dictionaries).
   - For each effect in the selection file, resolve the whole graph and write `public/fx/binbun/<id>.json`:
     nodes, meshes, process-material params, sampled curves/gradients, material = `{shader, uniforms, textures}`,
     root colours, and the `main` and `oneshot` animations.
   - Bake textures to `public/fx/binbun/tex/<hash>.png` (use `sharp`, already a dependency).
   - Current output keeps include-expanded `.gdshader` source instead of emitting GLSL; translation belongs with
     the runtime pass so it can be verified against Three.js shader compilation.
   - FastNoiseLite definitions are retained verbatim. The committed preview masks use a deterministic value-noise
     approximation; replace the sampler with exact FastNoiseLite later without needing the raw packs.
2. ✅ **`art-manifest/binbun-effects.json`** selects 22 effects covering the wiring list's first useful slice,
   including all seven loot rarities. `npm run build:vfx` rebuilds them; `npm run test:vfx` checks the parser,
   curve sampling, selection completeness and every portable asset reference.
3. **Runtime `src/graphics/binbun/BinbunFX.ts`:**
   - Load the JSON with a `fetch` + cache, like `fxImages.ts`, including a preload.
   - **One `THREE.InstancedMesh` per particle node**, CPU-simulated like the existing `ParticleSystem`, with
     per-instance `aColor` (vec4) and `aCustom` (vec4) attributes and billboard/align-Y matrices built on the CPU.
   - Plain `Mesh` for `MeshInstance3D`.
   - A tiny animation player for the track types in §3.
   - Lights go to `effects.lightFlash`.
   - Expose `spawn(id, { x, y, z, scale, rot, colors: [primary, secondary, tertiary], anim, follow?, duration? }) → Handle`
     (the same `Handle` shape as `Effects`).
   - Owned by `Effects` (e.g. `effects.binbun`), updated in `Effects.update`, disposed in `Effects.dispose`.
   - Keep a cap like Effects' 160-transient ceiling, and pool meshes and materials per effect id.
   - **Preserve the shipped game first:** loading is non-blocking and fail-open, casts/sim events never await VFX,
     missing or rejected assets become a no-op, and the existing `Effects` calls remain the visible fallback until
     every wired effect passes gallery, combat-readability and dense-wave performance QA.
4. **DEV QA hook:** `__cwDebug.vfx(id, colors?)` spawns at the player. Add a DEV-only gallery that plays every
   converted id in a grid, so the owner can pick. Screenshots work after `__cwDebug.advance()`.
5. **Tests** (`src/graphics/__tests__/` or `tools/`):
   - The parser round-trips a real `.tscn` excerpt, and the curve sampler matches Godot's rule.
   - Every id in `binbun-effects.json` has a JSON file and every texture it references exists.
   - `npm run typecheck && npm test` stay green.
6. **Wire into the game** (§5), additive only. Then update the Codex entry and tips only if a mechanic's
   *meaning* changes (pure visuals need no tip), and update `docs/ART-BACKLOG.md`, `ASSET_PIPELINE.md` and `HANDOFF.md`.

## 5. Proposed wiring (recolour from `SPELL_FX`, layer on top, keep the existing calls)

| Game moment | Hook (file) | Binbun effect (suggested) | Colours |
|---|---|---|---|
| Miasma landing | `AbilitySystem.miasma` `onArrive` | `PoisonVFX/poison_cloud_vfx_01` oneshot, scaled to `r` | `SPELL_FX.miasma` rot / deep / spore |
| Plague Bloom (signature) | `AbilitySystem.signature` + sim event | `PoisonVFX/poison_area_*` or `stink_big_*` | `SPELL_FX.bloom` |
| Corpse Explosion | `AbilitySystem.onDetonated` | `ImpactVFX/explosion/vfx_explosion_0x` | `SPELL_FX.detonate` ember / hot / crimson |
| Grave Frost cone | `AbilitySystem.frost` | `IceVFX/ice_mist_*` along the cone; `ice_shard_*` on chilled hits | `SPELL_FX.frost` |
| Dirge (signature) | signature handler | `IceVFX/ice_area_*` | `SPELL_FX.dirge` |
| Litany | `AbilitySystem.onLitany` | `MagicAreaVFX/pulse_area_*` or `ripple_area_*` | `SPELL_FX.litany` |
| Soul Harvest / Exhume | `soulRelease`, `exhume` | `MagicAreaVFX/pillar_area_*` / `lift_area_*` | `SPELL_FX.souls` / `exhume` |
| Censer Bearer incense | `censerPulse` sim event (EntityViews / WorldScene) | `SmokeVFX/smoke_thin_*` | `SPELL_FX.enemy.toll` + grey |
| Grave Step | `AbilitySystem.step` | `SmokeVFX/smoke_*` | `SPELL_FX.step.mist` |
| Loot on the ground | `src/graphics/LootView.ts` | `LootVFX/ground/ground_loot_vfx_<rarity>` (`main`, looping) | Keep Binbun's rarity colours or map to the game's rarity palette |
| Candles / braziers | `src/graphics/WorldView.ts` (candle/lightPool code) | `FireVFX/fire_candle`, `fire_0x` (`main`) | warm ember; **perf-check**, since there are many candles (share one material, cap the count) |
| Area gates / exits | layout exits in `WorldView` | `PortalVFX/gate_*` or `oval_*` (`main`) | per-area colour |
| Enemy breaches | `WorldSim.spawnAtBreach` → view event | `MagicAreaVFX/rim_area_*` or `PortalVFX/simple` | `SPELL_FX.surge` |
| Boss slams (Prelate) | `BossBrain` events → WorldScene | `ImpactVFX/impact/vfx_impact_*` | `SPELL_FX.boss.bronze` |
| Area change | scene transition | `TransitionKit` shader as a full-screen pass | — |

**Performance budget:**
- Effects must hold 60 fps in dense co-op waves.
- Prefer `oneshot` + pooling, and cap concurrent Binbun instances (start at ~24).
- Never create PointLights.
- Share materials per effect id; per-spawn colours go in uniforms on a cloned material from a pool.

## 6. Verification recipe (from `CLAUDE.md`)

1. Run `npm run typecheck && npm test && npm run test:server`.
2. Start the dev server `crossworlds-web` (port 5188, or `crossworlds-web-alt` on 5198) at `/?offline`.
3. Drive QA through `__cwDebug`: `god()`, `goto(area)`, `ring(def, n, r)`, `cast(slot)`, `advance(s)`. Hidden
   panes throttle rAF, so step with `advance`.
4. Check the console for shader compile errors. Three.js logs the full GLSL on failure.
