# DmFx: visual effects (Godot port of Effects.ts + BinbunVFX + necroFx)

Phase 1 = faithful port "as is". Owner: the `godot/fx` track. Files: `godot/fx/`, `godot/assets/fx/`, `godot/tests/fx/`, `tools/godot/*fx*`.

## Integrator checklist

- **Autoload** (project.godot): `DmFx="*res://fx/dm_fx.gd"` (script class `DmFxRuntime`, node name `DmFx`). It must live under the 3D world (it is a `Node3D` that
  draws in world space at the origin): instance it as a child of the world scene instead of an autoload if you prefer: `add_child(DmFxRuntime.new())`.
- Keep three settings in sync with the web's `settings`: `DmFx.quality = "high"|"low"` (Low: no Binbun layer, bursts thinned to 75 %, motifs off),
  `DmFx.reduced_motion`, and `DmFx.hitstop_scale` (hitstop.scale; 1 = normal).
- A Camera3D must exist (`get_viewport().get_camera_3d()`): loopers are culled by distance (40 m + camera height) and frustum.
- Environment: effects are emission-heavy. The web runs with bloom; use a WorldEnvironment with glow. Native Binbun shaders render at the pack's own brightness
  (gain 1.0); the web multiplied by `BINBUN_GAIN` 0.5 + a soft knee. `DmFx.binbun.gain = 0.5` reproduces the web's level if the glow blows out.
- Decal render order = `render_priority` on the ShaderMaterial (friendly 2, hero 3, danger 4, particles 5, sprites/Binbun/beams 6). Do not give world
  transparent materials priorities above 1.
- Regenerate assets: `npx vite-node tools/godot/fx-binbun-rebuild.ts && npx vite-node tools/godot/export-fx.ts && node tools/godot/fx-sync-models.mjs`
  and (browser, under the lock) `flock -w 900 /home/ubuntu/death-muffin/qa-browser.lock node tools/godot/fx-textures.mjs`; then `godot --headless --path godot --import`.
  `node tools/godot/fx-callsites.mjs` rebuilds `CALLSITES.md`.
- Tests: `godot --headless --path godot --script res://tests/fx/run.gd` (631 checks). After adding a `class_name`, run `--import` once or other scripts will not see it.

## API (all on the `DmFx` node)

```gdscript
# Binbun scene (native GPUParticles3D / ShaderMaterial / AnimationPlayer). Returns a DmFxHandle (alive, kill(), move(Vector3), set_alpha(a)).
var h := DmFx.play("miasma_cloud", Vector3(x, 0, z), {
    "scale": r / 3.8, "alpha": 1.0, "rot": yaw, "dir": Vector3(dx, 0, dz),   # dir -> yaw
    "colors": [Color, Color, Color],        # primary, secondary, tertiary; default = FX_PRESETS colours (SPELL_FX), see DmFxData.spell(group, key)
    "follow": func(): return Vector3(...),  # or null to end the effect
    "duration": 4.0,                        # seconds; loopers otherwise run until killed
    "once": true, "y": 1.0, "raw": false,   # once defaults to "is an impact id"; y overrides preset height; raw ignores the preset
})
DmFx.stop(h)            # == h.kill(): fades out over 0.3 s
```
`play` applies `FX_PRESETS[id]` exactly like web `playFx` (colours, scale, y, alpha multiply the opts) and, while `DmFx.role == "other"`, the partner dim
(alpha x0.35, scale x0.75) exactly like `Effects.partnerBinbun`. A dead handle (`alive == false`) comes back for Low quality, an unknown id, or a dropped looper.

Procedural primitives, same option names as the web (`EmitOptions`, `DecalOptions`, ... with Callables for the closures; colours may be `Color` or `0xRRGGBB`;
textures by name: `glow ring disc sigil cone coneEdge bar smoke spark cracks lightPool` and the FX_IMAGES names `skull boneShard crescent wisp frostFan ...`):

| web | DmFx |
|---|---|
| `effects.emit(o)` / `emitSmoke(o)` | `DmFx.emit({x,y,z,count,color,spread,speed,up,life,size,gravity,drag,shrink,inward})` / `emit_smoke` |
| `effects.decal(o)` -> Handle | `DmFx.decal({tex:"disc", color, x, z, r, y, rot, duration, opacity, fadeIn, fadeOut, growFrom, spin, blending:"add"\|"mix", sx, sz, anchor, follow, pulse, delay, persistent, danger, hero, other})` (keys keep the web's camelCase) |
| `effects.danger(fn)` | `DmFx.danger(func(): ...)` |
| `effects.flash(o)` / `orbit(o)` | `DmFx.flash({x,y,z,color,size,duration,tex,rise,opacity})` / `DmFx.orbit({tex,color,count,radius,y,size,duration,speed,follow})` |
| `effects.beam(a, b, color, width, duration)` | `DmFx.beam(a: Vector3 \| Callable, b: Callable, color, width, duration)` |
| `effects.projectile(o)` | `DmFx.projectile({from, to: Callable, speed, color, kind:"needle"\|"orb"\|"sprite", tex, size, arc, on_arrive: Callable(Vector3), on_trail: Callable(Vector3)})` -> ref with `pos()` (null once landed) |
| `spikeRing / spikeLine / graveHands / boneOrbit` | `spike_ring(x,z,r,count,life)`, `spike_line(x,z,dx,dz,len,width,seq)`, `grave_hands(x,z,r,count,dur)`, `bone_orbit({..., fallbackTex, fallbackColor, funnel})` |
| `effects.lightFlash(...)` | `DmFx.light_flash(Vector3, Color, intensity, life)` (one shared OmniLight3D; Binbun one-shots call it for their first light) |
| `effects.particleScale`, `role`, `transientLoad`, `activeHandFields` | `DmFx.particle_scale`, `DmFx.role` ("self"\|"other"), `transient_load()`, `active_hand_fields()` |
| necroFx `boneSplinters(e, ...)` etc. | `DmFx.motifs.bone_splinters(x, y, z, {n, speed, color, origin})`, `grave_dirt`, `soul_motes`, `rot_spores`, `mist_whisper`, `skull_wisps`, `skull_ring`, `spirit_wisps`, `spectral_hands`, `cracked_ground`, `slash_mark` (same `origin:"thrall"` quieting, budgets and Low / reduced-motion gates; the `e` argument is gone) |

Colours: `DmFxData.spell("miasma", "rot")` is `SPELL_FX.miasma.rot` (exported from the TS, a test checks every value against `src/content/abilities.ts`);
`DmFxData.spell_group("miasma")` returns the whole group; `DmFxData.preset(id)` the FX_PRESETS entry.

## Caps and budgets (all read from the web source by `tools/godot/export-fx.ts`; a test pins them)

24 live one-shots (oldest evicted), 32 loopers (extra ones are dropped), 160 combat transients (decals, flashes, orbits, beams; oldest evicted; `persistent` decals
are outside it), 3500 additive + 900 smoke motes, 1 shared flash light, loopers culled beyond 40 m + camera height or off-screen, pool of 4 built instances per
id, Low = 0.75 of every burst and no Binbun/motifs, motif budget 240 particles + 14 sprites refilling at 260 / 9 per second, motif ceiling 100 transients,
partner effects at 0.35 alpha / 0.75 scale, partner decals 0.28 alpha outline-only.

## Web event -> effect id (Binbun). Per-line detail for every web call: `CALLSITES.md`

| event (web function) | id | notes |
|---|---|---|
| Needle crit (`launchNeedle`) | `crit_hit` | impact (`once`) |
| Soul Harvest (`soulRelease`) | `soul_harvest_pillar` | + procedural ring/emit/lightFlash/motes/skulls |
| Miasma lands (`miasma`) / creep zone (`zoneVisual`) | `miasma_cloud` | zone: `scale: r/3.8, duration, follow` |
| Plague Bloom, carrion seed (`onSeeded`, `onSeedBurst`) | `carrion_seed_armed`, `carrion_seed_burst`, `toxic_puddle` | |
| Corpse Explosion (`onDetonated`) | `corpse_explosion`, then `litany_pulse` on detonate chain | |
| Grave Frost (`frost`) | `grave_frost_mist`, `frost_shard_hit` | |
| Dirge zone (`zoneVisual`) | `dirge_area` | |
| Litany (`onDetonated`) | `litany_pulse` | |
| Exhume (`exhume`) | `exhume_lift` | |
| Grave Step (`step`), Veil Step (`veil`) | `grave_step_smoke`, `veil_step_trail` | |
| Wailing Skull leap (`skullLeap`) | `wailing_skull_projectile` | follows the procedural projectile (`projectile().pos()`) |
| Rally (`rally`) | `rally_area`, `rally_thrall_rim` | |
| Soul Siphon (`siphon`) | `soul_orb`, `soul_siphon_beam` | |
| Bone Prison / Storm / Hands | `bone_prison_burst`, `bone_storm_dust`, `grave_hands_pulse` | |
| Offering (`offering`) | `grave_offering_ripple`, `grave_offering_orb` | |
| Ivory cleave (`cleave`) / Grave Slam (`graveSlam`, `handleEventNow`) | `ivory_cleave_hit` / `rend_impact` | impacts |
| Archer thrall shot | `archer_flash` | impact |
| Thrall raised | `thrall_rise` | |
| Level up (`gainXp`) | `levelup_pillar` | |
| Censer pulse | `censer_incense` | |
| Plague doctor stink | `toxic_stink` | |
| Enemy breach | `enemy_breach_rim` | |
| Bell toll (boss/elite) | `bell_toll_ring` | |
| Choir scream telegraph | `choir_scream` | |
| Vengeful affix / death / area boss | `vengeful_burst`, `surge_eruption` | also `onSurge`: `crypt_mist` |
| Prelate slam (`onBossEvent`) | `prelate_impact` | |
| Waystones (`dressWaystones`) | `waystone_portal` | looper, `follow` not needed |
| Bonfire zone | `bonfire` | |
| Loot beams (`LootView`) | `loot_<rarity>` (the web maps legendary -> `loot_epic`; read `LootView.ts`) | loopers with `follow` |
| Soul shard marker (`LootView`) | `soul_orb` | colours `[0xb58cff, 0x7c3aed, 0x160a24]` |
| Not wired in the web yet (catalog only) | `interact_rim altar_beacon recall_portal brazier_fire kiln_fire nave_fog area_gate chapterhouse_candle rot_lance_projectile curse_bolt sanctify_beam exhume_beam bone_fan_hit needle_hit wall_raise boss_rain_orb carrion... ` | ready for the integrator |

The preloaded set (`WorldScene.GROUND_FX_PRELOAD`): call `DmFx.binbun.preload_ids([...])` for it at area start.

## What is native, what is approximated

- **Native (exact)**: all 67 Binbun scenes are rebuilt from the converted JSON as real Godot scenes: the original `ParticleProcessMaterial`s, meshes, curves,
  `FastNoiseLite` / `GradientTexture` resources, `AnimationPlayer` libraries and the original (include-expanded) gdshaders run unchanged; no three.js approximation.
  Spawn colours push into the same-named uniforms (`primary_color` ...), as `vfx_controller.gd` did. Particle lifetimes and animation lengths are checked against the JSON.
- **Rebuilt**: the vendor scripts were not vendored: `dm_fx_controller.gd` / `dm_fx_light.gd` / `dm_fx_rect.gd` replace them (property capture, `open_amount`/`shrink_amount`
  forwarding, `fade_mult`, light multiplier). Two hooks are injected at the end of every spatial fragment shader that writes ALPHA: `dm_fade` (spawn alpha / end fade) and `dm_gain`.
- **Procedural half of Effects.ts**: ported line by line (rings, decal layers with outline settling, flashes, orbits, beams, projectiles, spikes, hands, mantle shards). The
  sprites are the web's own pixels (baked from `fxTextures.ts`). Differences: motes/billboards are MultiMesh billboards instead of GL points (same world size), the three.js fog is
  not applied to sprites/beams, `Math.random` -> `randf`.
- **Dropped on purpose**: the pack's OmniLight3Ds (routed through the single flash light like the web), AudioStreamPlayer3D, `ShadowCaster` emitters (invisible shadow-only spheres),
  effect shadows. The Binbun world kits (`world_water_*`, `world_grass*`, `world_sky_dark`, `world_transition_*`) are converted as resources/scenes but not spawnable.

## gl_compatibility notes

All 67 effects compile and render on `gl_compatibility` (llvmpipe) with no shader errors. Observed/known: (1) an int Variant in a float uniform reads as 0 on this renderer, so the converter
writes float uniforms and animation values as floats (JSON lost int/float); (2) the portal `portal_stencil` pass has no stencil support here, so portals/gates (`area_gate`, `waystone_portal`,
`recall_portal`) draw as a clipped quad instead of a window; (3) `proximity_fade` (depth texture) is left on as authored and not visually verified; (4) GPUParticles3D trails and
sub-emitters (`TubeTrailMesh`, `trail_enabled`) are documented as unsupported by the compatibility renderer (not separately verified; fire sparks render as plain streaks); (5) the pack's glow assumes Forward+ tonemapping, so some cores bloom hot
(see gain above).

## Gallery

`godot --path godot res://fx/gallery.tscn` (Left/Right page, R replay). `fx/shoot.sh <page> <out.png> <t1,t2> [--kind=prims] [--ids=a,b] [--glow=0.8] [--gain=1]` captures under the renderer lock
at a fixed 30 fps. Web counterpart: `tools/godot/fx-web-gallery.cjs` (the web DEV `__cwDebug.vfxGallery(page)`). Screenshots are in `godot/shots/fx/` (gitignored).

## Phase 2: highest-impact upgrade ideas

1. Real depth soft-particles and the portal stencil window (portals read as doorways, smoke/mist stops clipping the floor).
2. Per-spell colour grading/tonemap pass for the gain/knee (match the web's calibrated brightness; fix blown cores like `toxic_puddle`, `dirge_area`).
3. Replace the dithered `alpha_mode` look with true alpha for hero effects (corpse explosion, bone prison); the dither reads noisy at 1080p.
4. GPUParticles trails for sparks/embers and soul wisps (needs Forward+ or a custom ribbon mesh in compat).
5. GPU-driven mote rings (GPUParticles3D bursts instead of a GDScript ring): frees ~3 ms in dense waves.
6. Ground-projected Decal nodes for telegraphs so rings follow terrain height and stairs.
7. Hit-flash / impact-frame layer (screen-space chromatic kick, radial blur) driven by `hitstop_scale`.
8. Dynamic spell-colour lights: a small pool of 2-3 flash lights with energy budget (the web has 1) once Godot light cost is measured.
9. Authored VFX for the enemies the web only covers with sprites (choir, tide hand, drowned) built on the same shader library.
10. Pool warm-up at area load (`preload_ids` + one pooled instance per id) to remove first-play hitches.

## Integrator notes
- Registered as the autoload **`Vfx`** (`Vfx="*res://fx/dm_fx.gd"`), not `DmFx`: the slice's `world/dm_fx.gd` already owns `class_name DmFx` until the game integration replaces it. Read `DmFx.x` in this README as `Vfx.x`.
