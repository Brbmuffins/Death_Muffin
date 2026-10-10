# godot/fx: Vfx, the visual effects runtime

Autoload `Vfx` (`project.godot`: `Vfx="*res://fx/dm_fx.gd"`, script class `DmFxRuntime`). Two layers:
- **Binbun scenes**: 64 native Godot scenes in `assets/fx/binbun/<id>.tscn` (GPUParticles3D, ShaderMaterial, AnimationPlayer), played with
  spawn colours, pooled per id. `fx/dm_fx_binbun.gd`; `dm_fx_controller.gd` / `dm_fx_light.gd` / `dm_fx_rect.gd` replace the vendor scripts.
- **Procedural primitives and motifs**: rings of motes, decals, flashes, orbits, beams, projectiles, spikes, hands (`dm_fx_prims.gd`,
  `dm_fx_ring.gd`, `dm_fx_layer.gd`) and the necromantic motifs (`dm_fx_motifs.gd`).
Tables (spell colours, presets, caps, catalog) are in `assets/fx/fx_data.json`, read through `DmFxData`.

## Wiring
- Callers: `DmRiteFx`, `next/enemy_fx`, `next/bosses/dm_boss_fx.gd`, `next/corpses`, `next/thralls`, `next/affixes`, `next/status` and others call `Vfx.*`.
- Quality is set by `next/perf/dm_next_perf.gd` from the graphics preset: `Vfx.quality = "high"|"low"` (Low: no Binbun, bursts thinned to 75 %,
  motifs off), `Vfx.binbun.enabled`. Also `Vfx.reduced_motion` and `Vfx.hitstop_scale`.
- A Camera3D must exist: loopers are culled by distance (40 m + camera height) and frustum.
- Effects are emission-heavy; the world uses a WorldEnvironment with glow. `Vfx.binbun.gain = 0.5` tones down blown cores.
- Decal render order = `render_priority` (friendly 2, hero 3, danger 4, particles 5, sprites/Binbun/beams 6). Do not give world transparent materials above 1.
- After adding a `class_name`, run `godot --headless --path godot --import` once.
- Regenerating Binbun scenes: `tools/godot/fx-binbun-rebuild.ts`, `fx-sync-models.mjs` (needs the private vendor packs, not in git).

## API (all on the `Vfx` node)

```gdscript
# Binbun scene (native GPUParticles3D / ShaderMaterial / AnimationPlayer). Returns a DmFxHandle (alive, kill(), move(Vector3), set_alpha(a)).
var h := Vfx.play("miasma_cloud", Vector3(x, 0, z), {
    "scale": r / 3.8, "alpha": 1.0, "rot": yaw, "dir": Vector3(dx, 0, dz),   # dir -> yaw
    "colors": [Color, Color, Color],        # primary, secondary, tertiary; default = FX_PRESETS colours (SPELL_FX), see DmFxData.spell(group, key)
    "follow": func(): return Vector3(...),  # or null to end the effect
    "duration": 4.0,                        # seconds; loopers otherwise run until killed
    "once": true, "y": 1.0, "raw": false,   # once defaults to "is an impact id"; y overrides preset height; raw ignores the preset
})
Vfx.stop(h)            # == h.kill(): fades out over 0.3 s
```
`play` applies `FX_PRESETS[id]` (colours, scale, y, alpha multiply the opts) and, while `Vfx.role == "other"`, the partner dim (alpha x0.35, scale x0.75). A dead handle (`alive == false`) comes back for Low quality, an unknown id, or a dropped looper.

Procedural primitives (option dictionaries; closures are Callables; colours may be `Color` or `0xRRGGBB`;
textures by name: `glow ring disc sigil cone coneEdge bar smoke spark cracks lightPool` and the FX_IMAGES names `skull boneShard crescent wisp frostFan ...`):

- `Vfx.emit({x,y,z,count,color,spread,speed,up,life,size,gravity,drag,shrink,inward})` / `emit_smoke`
- `Vfx.decal({tex:"disc", color, x, z, r, y, rot, duration, opacity, fadeIn, fadeOut, growFrom, spin, blending:"add"|"mix", sx, sz, anchor, follow, pulse, delay, persistent, danger, hero, other})` (camelCase keys)
- `Vfx.danger(func(): ...)`
- `Vfx.flash({x,y,z,color,size,duration,tex,rise,opacity})` / `Vfx.orbit({tex,color,count,radius,y,size,duration,speed,follow})`
- `Vfx.beam(a: Vector3 | Callable, b: Callable, color, width, duration)`
- `Vfx.projectile({from, to: Callable, speed, color, kind:"needle"|"orb"|"sprite", tex, size, arc, on_arrive: Callable(Vector3), on_trail: Callable(Vector3)})` -> ref with `pos()` (null once landed)
- `spike_ring(x,z,r,count,life)`, `spike_line(x,z,dx,dz,len,width,seq)`, `grave_hands(x,z,r,count,dur)`, `bone_orbit({..., fallbackTex, fallbackColor, funnel})`
- `Vfx.light_flash(Vector3, Color, intensity, life)` (one shared OmniLight3D; Binbun one-shots call it for their first light)
- `Vfx.particle_scale`, `Vfx.role` ("self"|"other"), `transient_load()`, `active_hand_fields()`
- `Vfx.motifs.bone_splinters(x, y, z, {n, speed, color, origin})`, `grave_dirt`, `soul_motes`, `rot_spores`, `mist_whisper`, `skull_wisps`, `skull_ring`, `spirit_wisps`, `spectral_hands`, `cracked_ground`, `slash_mark` (`origin:"thrall"` quiets them; budgets and Low / reduced-motion gates apply)

Colours: `DmFxData.spell("miasma", "rot")` is `SPELL_FX.miasma.rot` (from `assets/fx/fx_data.json`);
`DmFxData.spell_group("miasma")` returns the whole group; `DmFxData.preset(id)` the FX_PRESETS entry.

## Flipbook sheets
Animated sprite sheets from a licensed pack (ASSET_PIPELINE.md "Flipbook sheets"): greyscale intensity grids at
`assets/fx/sheets/<id>.png`, **not in git**. `bash tools/godot/fx-sheets-sync.sh [<checkout>]` copies them in from
`~/death-muffin/private/fx-sheets/` (run it once in a new worktree; `publish-godot-client.sh` runs it on its export and fails if one is
missing). Discord preview builds and CI have no sheets and draw the plain look.
- Grid, frames, fps, loop: `fx_data.json` `sheets`, read by `DmFxData.sheet(id)`. Use the id as a texture name: `Vfx.flash({"tex": "hit_flash", ...})`
  plays the frames once over the flash's life at full size (fades the last quarter); `Vfx.decal({"tex": "summon_circle", ...})` plays once or,
  for a looping sheet, loops at its fps. Same layers and caps as other textures; the frame is `INSTANCE_CUSTOM.z`; the sheet shaders tint by the
  instance colour and run the brightest pixels to white.
- Callers check `DmFxTex.has_sheet(id)` and keep their old look without it (`DmRiteFx.hit_flash`).
- In use: `hit_flash` (Bone Needle, pierce, Scythe hits), `crit_burst` (crits), `summon_circle` (under an exhumed corpse), `chain_arc`
  (Contagion thread, lying flat between the two bodies). Warmed with the other layers on the loading screen.

## Caps and budgets (pinned by `tests/fx/run.gd`)
24 live one-shots (oldest evicted), 32 loopers (extras dropped), 160 combat transients (persistent decals excluded), 3500 additive + 900 smoke
motes, 1 shared flash light, pool of 4 built instances per id, Low = 0.75 of every burst and no Binbun/motifs, motif budget 240 particles +
14 sprites, partner effects at 0.35 alpha / 0.75 scale.

## Native vs approximated
- Binbun scenes are real Godot resources (original ParticleProcessMaterials, meshes, curves, AnimationPlayer libraries, gdshaders). Two hooks
  are injected at the end of every spatial fragment shader that writes ALPHA: `dm_fade` and `dm_gain`.
- Motes/billboards are MultiMesh billboards. Pack OmniLight3Ds, AudioStreamPlayer3D and shadow-only emitters are dropped. World kits
  (`world_*` .tres/.tscn in `assets/fx/binbun/`) are resources only, not spawnable.

## gl_compatibility limits
All effects compile and render on `gl_compatibility`. Known: no stencil, so portals (`area_gate`, `waystone_portal`, `recall_portal`) draw as a
clipped quad; GPUParticles3D trails/sub-emitters are unsupported (fire sparks render as plain streaks); the pack's glow assumes Forward+
tonemapping; float uniforms must be written as floats (an int Variant reads as 0).

## Gallery and tests
- `godot --path godot res://fx/gallery.tscn` (Left/Right page, R replay). `fx/shoot.sh <page> <out.png> <t1,t2> [--kind=prims] [--ids=a,b]` captures at a fixed 30 fps.
- Test: `godot --headless --path godot --script res://tests/fx/run.gd` (effects instantiate, lengths match the converted JSON, caps hold, rings, roles, motif budget).
- Effect cost evaluation of the vendor packs: `EVAL.md`.

## Known gaps
- No depth soft-particles, no stencil portal window; dithered alpha reads noisy at 1080p on hero effects (`EVAL.md`).
- `tests/fx/` has leftover `load_all.gd.uid` / `smoke_tmp.gd.uid` with no script.
